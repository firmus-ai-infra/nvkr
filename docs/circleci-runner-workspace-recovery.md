# CircleCI runner workspace recovery

The self-hosted runner retains its checkout at
`/var/lib/circleci-runner/workdir`. Docker containers must use the invoking
numeric user for bind-mounted workspace paths. A root-owned file alone does not
block checkout cleanup; an inaccessible parent directory does.

`scripts/circleci-runner-workspace-preflight.sh` repairs existing `.nvkr`
directories before a task starts. It deliberately leaves file ownership alone:
once the runner owns each directory and each directory has owner `rwx`, it can
unlink stale files without a root operation following hard links out of the
workspace.

## Recover a runner that cannot start a task

On the runner host, identify the account that starts `circleci-runner` and run
the script as root. Substitute the actual numeric account values; do not assume
that the account is named `circleci`.

```sh
runner_uid="$(id -u RUNNER_ACCOUNT)"
runner_gid="$(id -g RUNNER_ACCOUNT)"
sudo install -m 0755 scripts/circleci-runner-workspace-preflight.sh \
  /usr/local/libexec/nvkr-circleci-workspace-preflight
sudo /usr/local/libexec/nvkr-circleci-workspace-preflight \
  --workspace /var/lib/circleci-runner/workdir \
  --owner "${runner_uid}:${runner_gid}"
```

This is a recovery operation. It does not delete build outputs, credentials, or
the checkout.

## Make the recovery run before every task

Install the script on the runner VM and configure the runner deployment's
task-launch hook or wrapper to invoke it immediately before it starts a CircleCI
task:

```sh
cd /usr/local/share/nvkr-ca
cp firmus-dev-issuing-ca.crt firmus_root_ca.crt /usr/local/share/ca-certificates/
update-ca-certificates
/usr/local/libexec/nvkr-circleci-workspace-preflight \
  --workspace /var/lib/circleci-runner/workdir \
  --owner RUNNER_UID:RUNNER_GID
exec /path/to/circleci-runner "$@"
```

`/usr/local/share/nvkr-ca` holds `firmus-dev-issuing-ca.crt` and
`firmus_root_ca.crt`. The copy and `update-ca-certificates` run as root. The
runner account has no passwordless sudo, and a job step starts after CircleCI
has already launched the task.

Use the runner platform's per-task hook, not a CircleCI job step. A job command
is too late: the runner clears the working directory before it can execute
`.circleci/config.yml`. If the deployment starts one fresh runner process per
task, a systemd `ExecStartPre` wrapper is equivalent; otherwise it only runs
once when the long-lived service starts and is insufficient.

## Prevention and verification

NVKR's ordinary local container-build, Packer toolchain bootstrap, and
boot-smoke paths now use Docker `--userns=host` with `--user UID:GID` for
writable workspace bind mounts. This avoids Docker user-namespace translation
to a subordinate host ID. After updating the runner checkout, validate the
behavior with a node-image job and inspect the retained workspace:

```sh
find /var/lib/circleci-runner/workdir/.nvkr -xdev -type d \
  \( ! -user RUNNER_ACCOUNT -o ! -group RUNNER_GROUP \) -print
```

The command must produce no output after the job's reclamation step. This is
local filesystem evidence only; it does not prove CircleCI scheduling or hosted
runner lifecycle behavior.
