# teleport-devenv

[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

A straightforward way to run a Teleport cluster locally for development.

Uses [devenv](https://devenv.sh) to provide a self-contained, reproducible
environment: the full build toolchain (Go, Rust, Node/pnpm, libfido2,
pkg-config, mkcert), a generated cluster config, and process supervision with
health checks via process-compose — no sudo, no `/var/lib/teleport`, no
hand-written config.

## Prerequisites

### Install Nix

Install Nix using the [Determinate Systems installer](https://github.com/DeterminateSystems/nix-installer)
(recommended — it handles macOS quirks and is easy to uninstall):

```sh
curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install
```

Or use the official installer: https://nixos.org/download

### Install devenv

```sh
nix-env --install --attr devenv -f https://github.com/NixOS/nixpkgs/tarball/nixpkgs-unstable
```

**Option B — Nix profile** (no Homebrew needed):

```sh
nix profile install nixpkgs#devenv
```

See the [devenv getting started guide](https://devenv.sh/getting-started/) for
other installation methods and shell integration (direnv).

### Other requirements

- On macOS: no Homebrew or Xcode Command Line Tools required for the build
  itself — the Go (CGO) and Rust toolchains, LLVM, and the Apple SDK all come
  from nix.
- A `teleport` checkout. By default it's expected as a sibling directory:

```
workspace/
├── teleport/          # github.com/gravitational/teleport
└── devenv.teleport/   # this repo
```

To point elsewhere, create a `devenv.local.nix`:

```nix
{ lib, ... }: { env.TPDEV_SRC = "/path/to/teleport"; }
```

## Quickstart (OSS)

```sh
devenv up          # builds teleport/tctl/tsh on first run, then starts everything

# In another terminal:
devenv shell       # enters the environment and makes the helper commands available
tp-bootstrap       # creates the 'dev' user and prints a signup link
tp-login           # after signup, logs in with tsh against the local proxy
```

`devenv up` starts the cluster and prints a banner with the URL and next steps
once it's healthy. The full web UI is served by teleport at
https://localhost:3080 — you don't need anything else to log in and explore.
In another terminal, run `devenv shell` once to enter the environment, then run
`tp-bootstrap` to create your user. It prints a one-time signup link — open it
to set a password and register a passkey or OTP (both enabled; OTP means
`tp-login` works without a hardware key).

`devenv up` also starts the Vite hot-reload dev server for frontend work. To
skip it:

```sh
TPDEV_WEB=0 devenv up
```

### Helper scripts

If you overuse Git Worktrees like me, it's not very convenient to keep pointing to different paths.
I use these scripts to get `devenv up` and `devenv shell` running from my current working directory:

```
tp-up() {
    src="$PWD"
    (
        cd <where you cloned this repo>
        devenv -O env.TPDEV_SRC:string "$src" up
     )
}

tp-shell() {
    src="$PWD"
    (
        cd <where you cloned this repo>
        devenv -O env.TPDEV_SRC:string "$src" shell -- \
          zsh -c 'cd "$TPDEV_SRC" && exec zsh'
     )
}
```

Note: the devenv state is shared between all runs, to reset it: `tp-reset` from within the devenv shell.

## Enterprise

```sh
export TPDEV_EDITION=ent   # or set it in devenv.local.nix
devenv up
```

This initializes the `e/` submodule if needed, builds from `e/`, and wires your
enterprise license (set `TPDEV_LICENSE` to the path of your `.pem` file) into
the generated config.

## Trusted TLS

`devenv up` automatically runs `tp-certs` the first time certs are missing.
This installs/trusts a local mkcert CA and writes localhost certs used by both
Teleport and the web dev server. To skip this automatic setup:

```sh
TPDEV_AUTO_CERTS=0 devenv up
```

To regenerate certs manually:

```sh
tp-certs           # mkcert local CA + certs for localhost
```

If you run `tp-certs` manually while Teleport is already running, restart the
teleport process to pick up the new certs. The `tsh` wrapper automatically drops
`--insecure` once certs exist.

## Day-to-day

| Command | What it does |
|---|---|
| `devenv up` | Start the cluster and web dev server (process-compose TUI) |
| `tp-build` | Rebuild binaries from `$TPDEV_SRC` (edition-aware) |
| `tp-bootstrap` | Create `$TPDEV_USER` and print a signup link |
| `tp-login` | Run `tsh login --proxy $TPDEV_PROXY --user $TPDEV_USER` |
| `tsh ...` / `tctl ...` | Wrappers pre-pointed at the local cluster; build missing local binaries on first use |
| `tbot ...` | Wrapper for the locally built `tbot` binary |
| `tp-tbot-init` | Ensure local bot exists and write tbot config (idempotent) |
| `TPDEV_TBOT=0 devenv up` | Skip the default local tbot process |
| `tctl users reset dev` | Reset user/MFA |
| `tp-reset` | Wipe all cluster state and start fresh |
| `TPDEV_LOG_LEVEL=DEBUG devenv up` | Verbose cluster logs |
| `TPDEV_AUTO_CERTS=0 devenv up` | Skip automatic mkcert provisioning |
| `helm version` | Show Helm version with unittest plugin installed |
| `helm plugin list` | List installed Helm plugins |
| `helm unittest --help` | Show help for the helm-unittest plugin |

After a rebuild, restart the `teleport` process from the process-compose TUI
(or `devenv processes restart teleport` if running detached).

## Web UI development

You do **not** need this to use the UI — teleport serves the full web UI on
https://localhost:3080 whenever the cluster is up. The `web` process is only
for **frontend development**: it runs the Vite dev server (`pnpm start-teleport`,
or `start-teleport-e` when `TPDEV_EDITION=ent`) with live reload for editing
`web/` code. It runs by default:

```sh
devenv up
```

To skip it, run `TPDEV_WEB=0 devenv up`.

The dev server's startup runs the ironrdp WASM build because Vite statically
imports the generated package. On macOS, devenv points Teleport's Makefile at
nix-provided LLVM through `MAKEFLAGS`, avoiding its Homebrew probe. After the
generated package exists, set `TPDEV_SKIP_WASM=1` to skip rebuilding it on
startup.

Teleport pins an exact Go patch version in `go.mod` and
`build.assets/versions.mk`. If nixpkgs lags by a patch release, devenv lets Go
download the required toolchain into `.devenv/state/go/` (`GOTOOLCHAIN=auto`),
which avoids repeated `go.mod requires go >= ...` warnings from the Makefile.

## Machine ID / tbot

The local `tbot` binary is built from `$TPDEV_SRC` alongside `teleport`, `tctl`,
and `tsh`. The process runs by default; to skip it:

```sh
TPDEV_TBOT=0 devenv up
```

tbot uses a bound-keypair join token and persists its private key and join state
across restarts. The stored state must remain paired with the bot resource in
the cluster, so it is removed only when the full environment is reset with
`tp-reset`.

`tp-tbot-init` (called automatically on startup) idempotently:
- Creates the bot resource (`TPDEV_BOT`, default: `local-bot`) if it doesn't exist
- Recreates the managed bot if its local bound-keypair state is missing
- Creates/updates the `time-service-access` role and assigns it to the bot
- Saves the initial bound-keypair joining URI
- Writes `tbot.yaml` pointing at that joining URI

State lives under:

```text
.devenv/state/teleport/tbot/tbot.yaml
.devenv/state/teleport/tbot/storage/   # persistent bound-keypair state
```

### Time service (application access)

`devenv up` always registers a Teleport app named `time-service`, starts a tiny
`nc`-based HTTP responder on `127.0.0.1:18080` that returns the current UTC time,
and starts `tbot` with an `application-tunnel` listener on `127.0.0.1:18081`.

Test through the tbot tunnel:

```sh
curl http://127.0.0.1:18081/
```

### Database service (Postgres)

A local PostgreSQL instance runs on port `15432` (to avoid conflicts with any
system-wide Postgres). Teleport's `db_service` registers it as `local-postgres`.

Connect through Teleport:

```sh
tsh db connect local-postgres --db-name=devdb --db-user=$USER
```

Useful overrides:

| Variable | Default | Purpose |
|---|---|---|
| `TPDEV_TBOT` | `1` | Set to `0` to skip the tbot process |
| `TPDEV_BOT` | `local-bot` | Bot resource name |
| `TPDEV_BOT_ROLES` | empty | Optional comma-separated roles assigned at bot creation |
| `TPDEV_TBOT_CONFIG` | `.devenv/state/teleport/tbot/tbot.yaml` | tbot config path |
| `TPDEV_APP_PORT` | `18080` | Time service app port |
| `TPDEV_APP_TUNNEL_PORT` | `18081` | Local tbot application-tunnel port |
| `TPDEV_DB_PORT` | `15432` | Local Postgres port |

## Cluster layout

A single `teleport` process running auth + proxy with
`proxy_listener_mode: multiplex` — everything goes through
`localhost:3080`. Built-in services: `app_service` (time-service),
`db_service` (local-postgres). A static join token (`local-dev-token`) is
preconfigured so extra local agents can be attached later; the plan is to
grow these as additional opt-in process-compose processes.

State lives under `.devenv/state/teleport/` and never touches
`/var/lib/teleport`.

## Troubleshooting

### All repo-level env vars use the `TPDEV_` prefix

Teleport interprets several `TELEPORT_*` environment variables itself — notably
`TELEPORT_CONFIG`, which it expects to contain *base64-encoded config YAML*.
To avoid ever colliding with teleport's own env parsing, everything this repo
defines lives under `TPDEV_*`.


### `brew: command not found` during the web dev server

The ironrdp WASM build (part of `pnpm start-teleport`) uses an upstream make
target, `ensure-llvm-macos`, that resolves LLVM via `$(shell brew --prefix ...)`.
make evaluates those assignments while parsing the Makefile, so plain exported
environment variables are not enough to override them. On macOS this devenv
injects `BREW_DIR`, `LLVM_PREFIX`, and `LLVM_DIR` through `MAKEFLAGS`, which make
treats as command-line variables, and points `LLVM_DIR` at nix-provided LLVM. If
you still see a brew probe, check that you're starting the UI through this devenv
environment (`devenv up`) rather than running `pnpm start-teleport`
directly in the Teleport checkout.

## Roadmap / open questions

- Pin Go/Rust/Node versions to `build.assets/versions.mk` exactly
- Prebuilt-binary mode (skip the source build for users who only need release
  binaries)
- Hot reload (CompileDaemon) as an alternative teleport process
- Opt-in extra processes: second node, local kind cluster for kube access,
  leaf cluster for trusted-cluster work
- Custom hosts-file names (e.g. `teleport.local`) + mkcert for non-localhost
  setups

## Test-suite tooling

The `devenv up` command installs several test dependencies, including:

- [Helm](https://helm.sh) with the [helm-unittest plugin](https://github.com/helm-unittest/helm-unittest) for testing Helm charts
- [Bats](https://github.com/bats-core/bats-core) for shell test suites

To run helm chart tests:
```sh
helm version
helm plugin list
helm unittest --help
```

Note: The helm-unittest plugin is installed with Helm, but due to the complexity of plugin installation in Nix environments, it may require manual installation via `helm plugin install` if not automatically detected.
