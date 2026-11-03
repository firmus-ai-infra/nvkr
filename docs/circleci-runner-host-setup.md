# CircleCI runner host setup

The self-hosted runner for resource class `firmus/nvkr` is an Ubuntu 24.04
amd64 machine. The default CircleCI pipeline builds and publishes the Ubuntu
24.04.5 AMD64 node image. That job expects the programs below to exist before
a task starts. Go, Packer, QEMU, crane, and Helm run inside the toolchain
image; this host install does not replace them.

The workspace must have at least 64 GiB free. Registering the CircleCI Runner
service and its launch token is separate from these packages. After a checkout
cannot be removed, use
[CircleCI runner workspace recovery](circleci-runner-workspace-recovery.md).

## Install the host packages

`docker-buildx` is the Ubuntu archive plugin used by the Packer toolchain
build. `qemu-kvm` supplies `/dev/kvm` and the `kvm` group. The node-image job
requires that device to be readable and writable by the runner account.

```sh
sudo apt-get update
sudo apt-get install -y \
  ca-certificates \
  curl \
  git \
  jq \
  python3 \
  docker.io \
  docker-buildx \
  qemu-kvm
```

Ubuntu 24.04 Git is newer than the 2.38 floor used by the other pipeline jobs.
If this host already uses Docker Engine from Docker's own repository, install
`docker-ce` and `docker-buildx-plugin` instead of `docker.io` and
`docker-buildx`.

Load the KVM module that matches the CPU. `kvm_intel` is for Intel and
`kvm_amd` is for AMD.

```sh
sudo modprobe kvm
sudo modprobe kvm_intel
```

## Identify the runner account

Read the account from the running process. The account name is not fixed by
this repository.

```sh
ps -o user=,uid=,gid=,cmd= -C circleci-runner
```

When the service is stopped, read it from the unit:

```sh
systemctl cat circleci-runner | grep -E '^User=|^Group='
```

The commands below use `RUNNER_ACCOUNT` for that name.

## Install the MinIO client

Admission and the node-image upload call `mc`. Install the pinned community
binary and place it on the command name `mc`. The Ubuntu package named `mc` is
Midnight Commander. The MinIO `.deb` from this release installs `mcli`.

```sh
curl -fL -o /tmp/mc \
  https://github.com/minio/mc/releases/download/RELEASE.2025-08-13T08-35-41Z/mc.linux-amd64.RELEASE.2025-08-13T08-35-41Z
echo "01f866e9c5f9b87c2b09116fa5d7c06695b106242d829a8bb32990c00312e891  /tmp/mc" | sha256sum -c -
sudo install -m 0755 /tmp/mc /usr/local/bin/mc
mc --version
```

`sha256sum -c` prints `OK` before `install`. `/usr/local/bin/mc` stays ahead of
`/usr/bin/mc` when Midnight Commander is also installed. `mc --version` reports
`RELEASE.2025-08-13T08-35-41Z`.

## Grant the runner account device access

Add the runner account to `docker` and `kvm`, then restart the service so the
running process receives those groups. `docker info` and `/dev/kvm` are then
available to the task without sudo.

```sh
sudo usermod -aG docker,kvm RUNNER_ACCOUNT
sudo systemctl restart circleci-runner
```

## Confirm the task identity

Run the admission checks as the runner account. `uname -m` is `x86_64`.
`docker info` succeeds. `/dev/kvm` is a character device the account can open
for read and write. `jq` and `/usr/local/bin/mc` resolve. Free space on
`/var/lib/circleci-runner/workdir` is at least 67108864 KiB.

```sh
sudo -u RUNNER_ACCOUNT bash -lc '
set -x
uname -m
docker info >/dev/null
test -c /dev/kvm && test -r /dev/kvm && test -w /dev/kvm
exec 3<>/dev/kvm
exec 3>&-
command -v jq
command -v mc
mc --version
df -Pk /var/lib/circleci-runner/workdir
'
```

During the build, NVKR also admits the host from
`inputs/environments/local-linux-amd64-kvm.yaml`: at least 8 vCPU, 10240 MiB
memory, and 65536 MiB free workspace.

## Toolchain build cache

Local toolchain builds run as the runner account, with `--userns=host` and
`--user` set to that account's uid and gid. The toolchain image has no passwd
entry for that uid. Each build therefore mounts a private tmpfs and points Go
at it:

```text
--tmpfs /tmp:rw,nosuid,nodev,mode=1777
HOME=/tmp/home
TMPDIR=/tmp
GOCACHE=/tmp/go-build
GOPATH=/tmp/go
GOMODCACHE=/tmp/go/pkg/mod
```

`go build` writes `/tmp/go-build` inside that container. The runner account
does not need a host Go installation or a home-directory build cache. The
node-image job compiles this behavior from its checkout before it builds the
image, so the checkout has to contain it. Nested BuildKit, used for the OVN
image, keeps the separate certificate setup below.

## Trust Harbor for host Docker pulls

`scripts/nvke-os-local-harbor.sh` rewrites Docker Hub references that the host
daemon pulls to `harbor.cbr01.in.firmus.co/dockerhub`. A mirror or
`hosts.toml` on this machine can dial `harbor.cbr01.co` while the image name
stays on `harbor.cbr01.in.firmus.co`. Docker matches the certificate directory
to the host in the request URL, so both names need the same issuing CA.

The file is the issuer PEM, including any intermediate the server omits from
the handshake. Its subject is the issuer printed below. Docker reads the copy
named `ca.crt`. The system store reads a `.crt` file under
`/usr/local/share/ca-certificates`.

```sh
echo | openssl s_client -connect harbor.cbr01.co:443 \
  -servername harbor.cbr01.co -showcerts 2>/dev/null \
  | openssl x509 -noout -issuer -subject -ext subjectAltName
```

`subjectAltName` must include `harbor.cbr01.co` when that is the dialed host.
Repeat the command with `-connect harbor.cbr01.in.firmus.co:443` and
`-servername harbor.cbr01.in.firmus.co` before trusting the long name.

```sh
sudo cp HARBOR_CA.crt /usr/local/share/ca-certificates/harbor-cbr01.crt
sudo update-ca-certificates
sudo mkdir -p \
  /etc/docker/certs.d/harbor.cbr01.co \
  /etc/docker/certs.d/harbor.cbr01.in.firmus.co
sudo cp /usr/local/share/ca-certificates/harbor-cbr01.crt \
  /etc/docker/certs.d/harbor.cbr01.co/ca.crt
sudo cp /usr/local/share/ca-certificates/harbor-cbr01.crt \
  /etc/docker/certs.d/harbor.cbr01.in.firmus.co/ca.crt
sudo systemctl restart docker
```

Save the leaf from the same handshake and check it against that CA. This
prints `OK`:

```sh
echo | openssl s_client -connect harbor.cbr01.co:443 \
  -servername harbor.cbr01.co 2>/dev/null \
  | openssl x509 > /tmp/harbor-leaf.pem
openssl verify -CAfile /etc/docker/certs.d/harbor.cbr01.co/ca.crt /tmp/harbor-leaf.pem
rm -f /tmp/harbor-leaf.pem
```

Then pull the pinned Ubuntu base through Harbor as the runner account:

```sh
sudo -u RUNNER_ACCOUNT docker pull \
  harbor.cbr01.co/dockerhub/library/ubuntu@sha256:da6fc2be547864451aa253836dd926da33623312df4a9a243e35dc877c378a78
```

Look for a Docker Hub mirror before expecting that pull to stay on Docker Hub:

```sh
test -f /etc/docker/daemon.json && cat /etc/docker/daemon.json
ls /etc/containerd/certs.d/docker.io/hosts.toml \
  /etc/containerd/certs.d/harbor.cbr01.co/hosts.toml \
  /etc/containerd/certs.d/harbor.cbr01.in.firmus.co/hosts.toml \
  /etc/buildkit/buildkitd.toml 2>/dev/null || true
```

## Leave the OVN Ubuntu base on Docker Hub

The OVN image build runs `buildctl-daemonless.sh` inside `moby/buildkit`. That
process trusts the CA bundle in the BuildKit image and a `buildkitd.toml`
mounted into that container. `/etc/docker/certs.d` and
`update-ca-certificates` on the runner apply to the host daemon.

`scripts/nvke-os-local-harbor.sh` therefore leaves this pin on Docker Hub:

`docker.io/library/ubuntu@sha256:da6fc2be547864451aa253836dd926da33623312df4a9a243e35dc877c378a78`

Keep `docker.io` off the Harbor mirror so that pull uses the public
certificates already in the BuildKit image. A mirror that rewrites it to
`https://harbor.cbr01.co/v2/dockerhub/...` needs the Harbor issuing CA inside
the nested BuildKit, for both `harbor.cbr01.co` and
`harbor.cbr01.in.firmus.co`:

```toml
[registry."harbor.cbr01.co"]
  ca = ["/certs/harbor-ca.crt"]

[registry."harbor.cbr01.in.firmus.co"]
  ca = ["/certs/harbor-ca.crt"]
```

A successful `docker pull` of the Harbor name shows that the host daemon
trusts the CA. The OVN step still needs the unmirrored Docker Hub pin, or
that in-container `buildkitd.toml`, before it can fetch the same digest.

## Packages the other workflows add

`build_nvkectl`, `build_controller_image`, and `build_charts` are off in the
default pipeline. Turning one on also requires `make`:

```sh
sudo apt-get install -y make
```

Those jobs download Go 1.27.3 and, when publishing to Harbor, ORAS 1.3.3.
The Ubuntu `golang-go` package is not the pinned toolchain.
