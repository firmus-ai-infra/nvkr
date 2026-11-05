# Packer toolchain Docker builder

`toolchains/nvkr-packer/build.sh` builds the Packer toolchain image with Docker Buildx. This page explains the builder that build uses, the pinned BuildKit image, and how the Ubuntu 24 node-image launcher pulls it through Harbor. What the toolchain contains is described in the [Packer toolchain README](../toolchains/nvkr-packer/README.md).

## Why a private builder

The build exports the image with `--output type=docker,dest=-,rewrite-timestamp=true`. The exporter's timestamp rewrite keeps the image deterministic. Buildx's default `docker` driver accepts that exporter only when the Docker daemon uses the containerd image store. On the CircleCI runner the daemon does not, so the build failed with `Docker exporter is not supported for the docker driver` before any build step ran.

`build.sh` therefore creates a `docker-container` builder for each invocation. That driver accepts the exporter on any daemon, so the build no longer depends on the host's image-store setting.

## What build.sh does

- Creates `nvkr-packer-<pid>` with `--driver docker-container`, `--driver-opt image=<locked BuildKit image>`, `--driver-opt restart-policy=no`, and `--bootstrap`. It does not pass `--use`, so the host's default builder is unchanged.
- Passes `--builder nvkr-packer-<pid>` to the `buildx build` that performs the export. The export arguments are unchanged.
- Removes the builder with `buildx rm --force` on every exit path, including after a failed export. If removal fails after a successful build, the invocation fails.

Two environment variables control the builder:

| Variable | Purpose |
|---|---|
| `NVKR_PACKER_BUILDKIT_IMAGE` | Changes only the registry name of the BuildKit image. It must keep the locked digest. |
| `NVKR_BUILDKIT_CONFIG` | A BuildKit configuration file passed to builder creation. It must be a regular file. |

Direct local runs, such as `scripts/nvke-os-local.sh` and `scripts/prepare-native-toolchains.sh`, also use the builder. They pull the locked BuildKit digest from Docker Hub unless `NVKR_PACKER_BUILDKIT_IMAGE` is set.

## Pinned BuildKit image

`toolchains/nvkr-packer/toolchain.lock.json` records the image in `buildkitImage`:

```text
moby/buildkit@sha256:c5f8862f52499773af85bc07695b2379ef08e8002352b0df2c4864c91d78dabe
```

This is the index digest of `moby/buildkit:buildx-stable-1`, the image that Buildx 0.37.1 uses by default. It was resolved on 2026-11-05 and includes `linux/amd64` and `linux/arm64`. The tag can move, so the digest is the authority.

To refresh the pin:

1. Run `docker buildx imagetools inspect moby/buildkit:buildx-stable-1`.
2. Confirm that the index digest lists `linux/amd64` and `linux/arm64`.
3. Update `buildkitImage` in the lock. `toolchains/nvkr-packer/build.sh --check` validates its format.
4. Run the toolchain tests.

## Harbor launcher

`scripts/nvke-os-local-harbor.sh` pulls from the Harbor mirror rather than Docker Hub. For the toolchain build it:

- sets `NVKR_PACKER_BUILDKIT_IMAGE` to `harbor.cbr01.in.firmus.co/dockerhub/` followed by the locked digest;
- requires the system CA bundle `/etc/ssl/certs/ca-certificates.crt` to be a readable file, and stops before the build if it is not;
- writes a `buildkitd.toml` into the attempt's private temporary directory. It trusts that bundle for both `harbor.cbr01.in.firmus.co` and `harbor.cbr01.co`, and passes the file as `NVKR_BUILDKIT_CONFIG`;
- concatenates every `*.crt` under `/usr/local/share/ca-certificates`, in path order, into the attempt's private temporary directory and passes that file as `NVKR_TOOLCHAIN_TRUST_CA`. It stops before the build if the directory holds no `*.crt`.

Harbor's certificate comes from a private CA. The host's checks and the Docker daemon trust it because the CA is installed on the host, but the builder's container does not inherit host trust. Without the bundle, BuildKit uses only the public CAs in its image and the base image pull fails with `x509: certificate signed by unknown authority`. Buildx reads the bundle where `build.sh` runs and copies it into the builder.

The finished toolchain image does not inherit host trust either. NVKE's vendoring runs crane inside it and pulls Calico images through `harbor.cbr01.in.firmus.co/dockerhub`. Without the Firmus CAs in the image's own store, every pull fails with the same `x509` error and NVKE falls back to anonymous Docker Hub, which then hits the pull rate limit. `NVKR_TOOLCHAIN_TRUST_CA` installs the host's locally added CAs, which on the runner are the Firmus root and issuing CAs, into the image's system store. Any other CA an operator has added to that directory is trusted in the image as well.

`NVKR_HARBOR_CA_BUNDLE` replaces the bundle path and `NVKR_HARBOR_TRUST_CA_DIR` replaces the CA directory. The contract tests use them with synthetic files. Do not set them on the runner.

### Before the next CircleCI run

Run these checks on the runner as the runner account, in the environment where the job's commands run.

Confirm that the system bundle trusts Harbor. Both hosts must report `Verify return code: 0 (ok)`:

```sh
for host in harbor.cbr01.in.firmus.co harbor.cbr01.co; do
  printf '%s: ' "$host"
  openssl s_client -connect "$host:443" -servername "$host" \
    -CAfile /etc/ssl/certs/ca-certificates.crt -no-CApath -no-CAstore \
    </dev/null 2>/dev/null | grep 'Verify return code'
done
```

Check Buildx and the BuildKit pull through Harbor:

```sh
docker buildx version
docker pull harbor.cbr01.in.firmus.co/dockerhub/moby/buildkit@sha256:c5f8862f52499773af85bc07695b2379ef08e8002352b0df2c4864c91d78dabe
```

Reproduce the builder's base image pull with the same BuildKit configuration as the launcher, then remove the builder:

```sh
cat >/tmp/nvkr-buildkitd.toml <<'EOF'
[registry."harbor.cbr01.in.firmus.co"]
  ca = ["/etc/ssl/certs/ca-certificates.crt"]

[registry."harbor.cbr01.co"]
  ca = ["/etc/ssl/certs/ca-certificates.crt"]
EOF
docker buildx create --name nvkr-packer-check --driver docker-container \
  --driver-opt image=harbor.cbr01.in.firmus.co/dockerhub/moby/buildkit@sha256:c5f8862f52499773af85bc07695b2379ef08e8002352b0df2c4864c91d78dabe \
  --driver-opt restart-policy=no --buildkitd-config /tmp/nvkr-buildkitd.toml --bootstrap
printf 'FROM harbor.cbr01.in.firmus.co/dockerhub/library/ubuntu@sha256:da6fc2be547864451aa253836dd926da33623312df4a9a243e35dc877c378a78\n' \
  | docker buildx build --builder nvkr-packer-check -
docker buildx rm --force nvkr-packer-check
```

The build must resolve the Ubuntu image without an `x509` error. A warning that no output is specified is expected.

## Privileged BuildKit container

Buildx runs the `docker-container` driver's BuildKit privileged, and it has no option to avoid that. The exposure is limited to the lifetime of one invocation. `restart-policy=no`, the per-process builder name, and removal on exit keep the container from persisting on the runner.

## Verification status

- `toolchains/nvkr-packer/build_test.go` covers the builder's creation flags, the pinned image, the config binding, ordering of create, build, and removal, creation failure, removal failure, and the rejection of invalid overrides. These tests use fake `docker` programs.
- `toolchains/nvkr-packer/build_test.go` also covers trust-CA admission (only PEM `CERTIFICATE` blocks, checked before any runtime call), its secret and build-arg binding, and the native-validation mount. `cmd/nvkr/nvke_os_script_test.go` covers the launcher's CA collection and its refusal to build without one. The final-stage install and the validation check were also run outside a Dockerfile build, against throwaway CAs, in a Debian Go image with no network. A server certificate signed by those CAs then verified through Go's system pool.
- Not yet exercised: a real export on the CircleCI runner, a pull of the BuildKit digest through Harbor, a Harbor-backed build with the system CA bundle, and a toolchain image built with the runner's Firmus CAs vendoring Calico through Harbor. Record those in the reconciliation ledger when they run.
