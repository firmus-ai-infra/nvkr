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

- sets `NVKR_PACKER_BUILDKIT_IMAGE` to `harbor.cbr01.in.firmus.co/dockerhub/` followed by the locked digest.

The launcher passes no CA to the builder. The host Docker daemon pulls the BuildKit image with its own trust settings. Inside the builder, BuildKit pulls the Ubuntu and curl base images from Harbor using the public CA bundle shipped in the BuildKit image. The build therefore depends on Harbor presenting a certificate from a publicly trusted CA. If Harbor moves to a private CA, BuildKit rejects its certificate and the build fails during the base image pull. `build.sh` still accepts `NVKR_BUILDKIT_CONFIG` for that case.

### Before the next CircleCI run

Run these checks on the runner host as the runner account.

Confirm that Harbor's certificate verifies against a public CA bundle. The pinned curl image carries only public CAs, so it does not see any private CA installed on the host:

```sh
docker run --rm \
  harbor.cbr01.in.firmus.co/dockerhub/curlimages/curl@sha256:935d9100e9ba842cdb060de42472c7ca90cfe9a7c96e4dacb55e79e560b3ff40 \
  -sS -o /dev/null -w '%{http_code}\n' https://harbor.cbr01.in.firmus.co/v2/
```

A `200` or `401` status means TLS succeeded. An error such as `SSL certificate problem` means Harbor's certificate is not publicly trusted.

Show the chain Harbor presents and its expiry:

```sh
openssl s_client -connect harbor.cbr01.in.firmus.co:443 \
  -servername harbor.cbr01.in.firmus.co </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -enddate
```

Check Buildx and the BuildKit pull through Harbor:

```sh
docker buildx version
docker pull harbor.cbr01.in.firmus.co/dockerhub/moby/buildkit@sha256:c5f8862f52499773af85bc07695b2379ef08e8002352b0df2c4864c91d78dabe
```

Optionally, create a builder with the same options as `build.sh`, then remove it:

```sh
docker buildx create --name nvkr-packer-check --driver docker-container \
  --driver-opt image=harbor.cbr01.in.firmus.co/dockerhub/moby/buildkit@sha256:c5f8862f52499773af85bc07695b2379ef08e8002352b0df2c4864c91d78dabe \
  --driver-opt restart-policy=no --bootstrap
docker buildx inspect nvkr-packer-check
docker buildx rm --force nvkr-packer-check
```

## Privileged BuildKit container

Buildx runs the `docker-container` driver's BuildKit privileged, and it has no option to avoid that. The exposure is limited to the lifetime of one invocation. `restart-policy=no`, the per-process builder name, and removal on exit keep the container from persisting on the runner.

## Verification status

- `toolchains/nvkr-packer/build_test.go` covers the builder's creation flags, the pinned image, the config binding, ordering of create, build, and removal, creation failure, removal failure, and the rejection of invalid overrides. These tests use fake `docker` programs.
- Not yet exercised: a real export on the CircleCI runner, a pull of the BuildKit digest through Harbor, and a Harbor-backed build that relies on Harbor's public certificate. Record those in the reconciliation ledger when they run.
