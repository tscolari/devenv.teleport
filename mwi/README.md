# Machine & Workload Identity Lab

This directory contains an opt-in local lab for Teleport Machine & Workload
Identity, SPIFFE, scoped administration, Kubernetes workload attestation, and
managed-mTLS Application Access.

The lab deliberately models two tenants, `/alpha` and `/beta`. With Teleport's
current identity model they have independent scoped administration but still
share the cluster trust domain and SPIFFE CA.

## Quickstart

Start the host lab with the Teleport edition and source checkout you want to
test. Enterprise is recommended: scoped administration is an Enterprise feature.

```sh
TPDEV_EDITION=ent TPDEV_MWI=1 TPDEV_WEB=0 devenv up
```

In another shell:

```sh
devenv shell
tp-mwi doctor
tp-mwi status
tp-mwi inspect host alpha
tp-mwi inspect host beta
tp-mwi inspect endpoints
tp-mwi app test
tp-mwi test host
```

Generated credentials, configs, sockets, and local bot storage are written to
`.devenv/state/teleport/mwi/`. Nothing sensitive is written below this tracked
directory.

## Host Scenarios

The host lab starts three independent bots:

| Bot | Scope | Purpose |
|---|---|---|
| `mwi-alpha` | `/alpha` | Host Workload API plus the managed-mTLS server SVID |
| `mwi-beta` | `/beta` | Host Workload API |
| `mwi-app-client` | unscoped | Application tunnel used to test the app without an interactive login |

The host WorkloadIdentity resources require Unix workload attestation and use
the connecting process UID in the SPIFFE path:

```text
spiffe://teleport-local/alpha/_/host/<uid>/inspector
spiffe://teleport-local/beta/_/host/<uid>/inspector
```

Alpha and beta both resolve under the shared cluster trust domain, scoped by
their own `/alpha` or `/beta` path prefix.

`tp-mwi inspect` removes the JWT-SVID value printed by `tbot spiffe-inspect`.
Do not invoke the underlying command directly in automation unless retaining a
short-lived bearer credential in logs is acceptable.

## Managed-mTLS App

The app scenario connects these components:

```text
app-client tbot tunnel
        -> Teleport Proxy
        -> local App Service
        -> managed client certificate
        -> alpha HTTPS workload
```

Alpha's tbot writes a server SVID and a bundle containing the additional
`app_client` trust domain. The Go test server reloads these files for every TLS
handshake, validates the client chain, and only accepts this exact identity:

```text
spiffe://_teleport_app.teleport-local/app/mwi-mtls-app
```

The App Service independently verifies the upstream server identity:

```text
spiffe://teleport-local/alpha/_/app/server
```

`tp-mwi app test` first proves that a direct request without a client
certificate fails, then checks the complete tunnel and both SPIFFE IDs.

The `_teleport_app.<cluster>` domain is an existing internal trust domain. It is
useful implementation precedent.

## Kubernetes Lab

The Kubernetes path uses a dedicated kind cluster and the
`tbot-spiffe-daemon-set` chart from the active `$TPDEV_SRC` checkout. It builds a
Linux tbot binary from that same checkout, wraps it in a local image, and loads
the image into kind. Released tbot images are not used.

Start it after the host Teleport cluster is healthy:

```sh
tp-mwi kube up
tp-mwi inspect kube alpha
tp-mwi inspect kube beta
tp-mwi inspect kube-cross
tp-mwi test kube
```

Clean up only the dedicated kind cluster:

```sh
tp-mwi kube down
```

The command detects Podman or Docker. Set
`TPDEV_MWI_CONTAINER_PROVIDER=podman` or `docker` to override detection. When
Podman is selected, `kube up` starts an existing stopped Podman machine but
`kube down` does not stop it.

Each tenant has its own scoped Kubernetes join token, tbot DaemonSet, Workload
API socket, namespace, and service account. The resulting identities are:

```text
spiffe://teleport-local/alpha/_/k8s/mwi-alpha/mwi-workload
spiffe://teleport-local/beta/_/k8s/mwi-beta/mwi-workload
```

The cross-tenant check runs the beta workload against alpha's socket. The alpha
WorkloadIdentity rules must reject beta's namespace and service account.

### Container Networking

On macOS, `kube up` first tests the runtime's `host.containers.internal` or
`host.docker.internal` route to Teleport's loopback listener. If that route is
not available, restart the host lab with the explicit relay:

```sh
TPDEV_EDITION=ent \
TPDEV_MWI=1 \
TPDEV_MWI_CONTAINER_RELAY=1 \
TPDEV_WEB=0 \
devenv up
```

The fallback relay binds the Teleport proxy to all host interfaces on port
`18112`. It is intentionally never enabled automatically. Use it only on a
trusted network and stop it when the Kubernetes test is complete.

## Resource Map

| Path | Purpose |
|---|---|
| `teleport/alpha.yaml` | Alpha Bot, scoped role, role assignment, and WorkloadIdentities |
| `teleport/beta.yaml` | Beta Bot, scoped role, role assignment, and WorkloadIdentities |
| `teleport/*-host-token.yaml` | Persistent bound-keypair host joins |
| `teleport/kube-token.yaml.tmpl` | Kubernetes static-JWKS scoped join token |
| `tbot/*.yaml.tmpl` | Host Workload API and app tunnel configurations |
| `app/teleport.yaml.tmpl` | Separate local App Service registration |
| `app/server.go` | Rotating SPIFFE-aware managed-mTLS upstream |
| `kubernetes/` | kind, Helm values, image, and workload fixtures |
| `tests/` | Bats end-to-end smoke checks |

## State and Rebuilds

Bound-keypair state must remain paired with its Bot and join token. `tp-mwi`
preserves healthy state and only recreates a tenant's token when that tenant's
local private state is missing. `tp-reset` removes all host MWI state along with
the Teleport backend. It does not delete the kind cluster; use
`tp-mwi kube down` for that.

The existing devenv only builds missing host binaries automatically. After
changing Teleport source, run `tp-build` and restart the Teleport and MWI
processes. `tp-mwi kube up` always rebuilds and reloads the Linux tbot image.

All worktrees still share this repository's `.devenv` state. Check `$TPDEV_SRC`
with `tp-mwi doctor` before interpreting results from another worktree.
