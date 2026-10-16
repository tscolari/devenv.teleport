#!/usr/bin/env bash

set -euo pipefail
umask 077

MWI_ROOT="${TPDEV_MWI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
REPO_ROOT=$(cd "$MWI_ROOT/.." && pwd)

: "${TPDEV_SRC:=$REPO_ROOT/../teleport}"
: "${TPDEV_STATE:=$REPO_ROOT/.devenv/state/teleport}"
: "${TPDEV_CONFIG:=$TPDEV_STATE/teleport.yaml}"
: "${TPDEV_PROXY:=localhost:3080}"
: "${TPDEV_WEB_PORT:=3080}"
: "${TPDEV_CLUSTER_NAME:=teleport-local}"
: "${TPDEV_JOIN_TOKEN:=local-dev-token}"
: "${TPDEV_LOG_LEVEL:=INFO}"
: "${TPDEV_EDITION:=oss}"
: "${TPDEV_MWI_DIR:=$TPDEV_STATE/mwi}"
: "${TPDEV_MWI_ALPHA_DIAG_PORT:=18101}"
: "${TPDEV_MWI_BETA_DIAG_PORT:=18102}"
: "${TPDEV_MWI_APP_CLIENT_DIAG_PORT:=18103}"
: "${TPDEV_MWI_APP_NAME:=mwi-mtls-app}"
: "${TPDEV_MWI_APP_PORT:=18110}"
: "${TPDEV_MWI_APP_TUNNEL_PORT:=18111}"
: "${TPDEV_MWI_CONTAINER_RELAY_PORT:=18112}"
: "${TPDEV_MWI_KIND_CLUSTER:=teleport-mwi}"
: "${TPDEV_MWI_TBOT_IMAGE:=teleport-mwi-tbot}"
: "${TPDEV_MAKE:=make}"

export TPDEV_CLUSTER_NAME TPDEV_JOIN_TOKEN TPDEV_LOG_LEVEL TPDEV_MWI_APP_NAME
export TPDEV_MWI_APP_PORT TPDEV_MWI_APP_TUNNEL_PORT TPDEV_MWI_TBOT_IMAGE TPDEV_PROXY

if [ "$TPDEV_EDITION" = ent ]; then
  MWI_BUILD_DIR="$TPDEV_SRC/e/build"
else
  MWI_BUILD_DIR="$TPDEV_SRC/build"
fi

KUBE_CONTEXT="kind-$TPDEV_MWI_KIND_CLUSTER"

info() {
  printf 'tp-mwi: %s\n' "$*"
}

die() {
  printf 'tp-mwi: ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command '$1' is not available"
}

local_tctl() {
  [ -x "$MWI_BUILD_DIR/tctl" ] || die "local tctl not found at $MWI_BUILD_DIR/tctl; run tp-build"
  "$MWI_BUILD_DIR/tctl" -c "$TPDEV_CONFIG" "$@"
}

local_tbot() {
  [ -x "$MWI_BUILD_DIR/tbot" ] || die "local tbot not found at $MWI_BUILD_DIR/tbot; run tp-build"
  "$MWI_BUILD_DIR/tbot" "$@"
}

require_cluster() {
  [ -f "$TPDEV_CONFIG" ] || die "Teleport config not found at $TPDEV_CONFIG; start devenv first"
  local output
  if ! output=$(local_tctl status 2>&1); then
    printf '%s\n' "$output" >&2
    die "the local Teleport cluster is not reachable"
  fi
}

ensure_state_dir() {
  mkdir -p "$1"
  chmod 700 "$1"
}

render_template() {
  local source=$1
  local destination=$2

  require_command envsubst
  ensure_state_dir "$(dirname "$destination")"
  envsubst < "$source" > "$destination"
  chmod 600 "$destination"
}

tenant_value() {
  local tenant=$1
  local alpha_value=$2
  local beta_value=$3

  case "$tenant" in
    alpha) printf '%s\n' "$alpha_value" ;;
    beta) printf '%s\n' "$beta_value" ;;
    *) die "tenant must be 'alpha' or 'beta', got '$tenant'" ;;
  esac
}

tenant_state_dir() {
  printf '%s/tenants/%s\n' "$TPDEV_MWI_DIR" "$1"
}

tenant_storage_has_identity() {
  local storage
  storage="$(tenant_state_dir "$1")/storage"
  [ -s "$storage/id_bkp" ] || [ -s "$storage/key" ]
}

scoped_resource_exists() {
  local kind=$1
  local ref=$2
  local_tctl get "$kind" "$ref" --format=json >/dev/null 2>&1
}

scoped_bot_exists() {
  local tenant=$1
  local name="mwi-$tenant"
  local_tctl get bot --format=json 2>/dev/null \
    | jq -e --arg scope "/$tenant" --arg name "$name" \
      '.[] | select(.scope == $scope and .metadata.name == $name)' \
      >/dev/null 2>&1
}

remove_scoped_token() {
  local ref=$1
  if scoped_resource_exists scoped_token "$ref"; then
    local_tctl rm scoped_token "$ref" >/dev/null
  fi
}

scoped_registration_secret() {
  local ref=$1
  local_tctl get scoped_token "$ref" --with-secrets --format=json \
    | jq -er '.[0].status.usage.bound_keypair.registration_secret // .[0].status.bound_keypair.registration_secret // ""'
}

render_tenant_config() {
  local tenant=$1
  local registration_secret=$2
  local state_dir storage socket_dir template

  state_dir=$(tenant_state_dir "$tenant")
  storage="$state_dir/storage"
  # macOS limits Unix socket paths to 104 bytes. Use a short path under /tmp.
  socket_dir="/tmp/tpdev-mwi-$tenant"
  template="$MWI_ROOT/tbot/$tenant.yaml.tmpl"

  ensure_state_dir "$state_dir"
  ensure_state_dir "$storage"
  mkdir -p "$socket_dir"

  export REGISTRATION_SECRET="$registration_secret"
  export TBOT_STORAGE="$storage"
  export WORKLOAD_SOCKET="$socket_dir/workload.sock"
  export TBOT_DIAG_PORT
  TBOT_DIAG_PORT=$(tenant_value "$tenant" "$TPDEV_MWI_ALPHA_DIAG_PORT" "$TPDEV_MWI_BETA_DIAG_PORT")
  export APP_SVID_DIR="$state_dir/app-server"
  ensure_state_dir "$APP_SVID_DIR"

  render_template "$template" "$state_dir/tbot.yaml"
  if [ -z "$registration_secret" ]; then
    yq -i 'del(.onboarding.bound_keypair.registration_secret)' "$state_dir/tbot.yaml"
  fi
}

init_tenant() {
  local tenant=$1
  local state_dir storage bot_ref token_ref resource_file token_file bot_existed=0 token_existed=0

  require_cluster
  require_command jq
  require_command yq
  tenant_value "$tenant" true true >/dev/null

  state_dir=$(tenant_state_dir "$tenant")
  storage="$state_dir/storage"
  bot_ref="/$tenant::mwi-$tenant"
  token_ref="/$tenant::mwi-$tenant-host"
  resource_file="$MWI_ROOT/teleport/$tenant.yaml"
  token_file="$MWI_ROOT/teleport/$tenant-host-token.yaml"

  if scoped_bot_exists "$tenant"; then
    bot_existed=1
  fi
  if scoped_resource_exists scoped_token "$token_ref"; then
    token_existed=1
  fi

  if tenant_storage_has_identity "$tenant" && { [ "$bot_existed" = 0 ] || [ "$token_existed" = 0 ]; }; then
    info "$tenant bot resources no longer match local state; discarding only the $tenant bot state"
    rm -rf "$storage"
  fi

  local_tctl create --force "$resource_file" >/dev/null

  if ! tenant_storage_has_identity "$tenant" && scoped_resource_exists scoped_token "$token_ref"; then
    info "$tenant bound-keypair state is absent; recreating its host join token"
    remove_scoped_token "$token_ref"
  fi
  if ! scoped_resource_exists scoped_token "$token_ref"; then
    local_tctl create "$token_file" >/dev/null
  fi

  local secret
  secret=$(scoped_registration_secret "$token_ref")
  if ! tenant_storage_has_identity "$tenant" && [ -z "$secret" ]; then
    die "the $tenant host token has no registration secret"
  fi

  render_tenant_config "$tenant" "$secret"
  info "prepared $tenant host tbot config at $state_dir/tbot.yaml"
}

app_client_storage_has_identity() {
  local storage="$TPDEV_MWI_DIR/app-client/storage"
  [ -s "$storage/id_bkp" ] || [ -s "$storage/key" ]
}

init_app_client() {
  local state_dir="$TPDEV_MWI_DIR/app-client"
  local storage="$state_dir/storage"
  local join_uri_file="$state_dir/join_uri"
  local bot_exists=0

  require_cluster
  require_command jq

  local_tctl create --force "$MWI_ROOT/teleport/app-client.yaml" >/dev/null

  if local_tctl bots ls --format=json 2>/dev/null \
    | jq -e '.[] | select(.metadata.name == "mwi-app-client")' >/dev/null 2>&1; then
    bot_exists=1
  fi

  if [ "$bot_exists" = 1 ] && { ! app_client_storage_has_identity || [ ! -s "$join_uri_file" ]; }; then
    info "app-client Bot has incomplete local state; recreating it"
    local_tctl bots rm mwi-app-client >/dev/null
    rm -rf "$storage"
    rm -f "$join_uri_file"
    bot_exists=0
  fi

  ensure_state_dir "$state_dir"
  ensure_state_dir "$storage"

  if [ "$bot_exists" = 1 ]; then
    local_tctl bots update mwi-app-client --add-roles mwi-app-client >/dev/null
  else
    local output join_uri token_id
    output=$(local_tctl bots add \
      --format=json \
      --roles=mwi-app-client \
      mwi-app-client)
    join_uri=$(jq -r '.join_uri // empty' <<< "$output")
    if [ -z "$join_uri" ]; then
      token_id=$(jq -er '.token_id' <<< "$output")
      join_uri="tbot+proxy+token://$token_id@localhost:$TPDEV_WEB_PORT"
    fi
    printf '%s\n' "$join_uri" > "$join_uri_file"
    chmod 600 "$join_uri_file"
  fi

  [ -s "$join_uri_file" ] || die "app-client join URI is missing"
  export JOIN_URI
  JOIN_URI=$(< "$join_uri_file")
  export TBOT_STORAGE="$storage"
  export TBOT_DIAG_PORT="$TPDEV_MWI_APP_CLIENT_DIAG_PORT"
  render_template "$MWI_ROOT/tbot/app-client.yaml.tmpl" "$state_dir/tbot.yaml"
  info "prepared app-client tbot config at $state_dir/tbot.yaml"
}



redact_spiffe_output() {
  local line
  while IFS= read -r line; do
    case "$line" in
      *"- Value: "*) printf '%s\n' '  - Value: [redacted]' ;;
      *) printf '%s\n' "$line" ;;
    esac
  done
}

inspect_host() {
  local tenant=$1
  local socket
  tenant_value "$tenant" true true >/dev/null
  socket="/tmp/tpdev-mwi-$tenant/workload.sock"
  [ -S "$socket" ] || die "$tenant Workload API socket is not ready at $socket"
  local_tbot spiffe-inspect --path "unix://$socket" | redact_spiffe_output
}

inspect_endpoints() {
  local proxy="https://$TPDEV_PROXY"
  require_command curl
  require_command jq

  printf '# OIDC configuration\n'
  curl -fsSk "$proxy/workload-identity/.well-known/openid-configuration" \
    | jq '{issuer, jwks_uri, id_token_signing_alg_values_supported}'
  printf '# JWT JWKS\n'
  curl -fsSk "$proxy/workload-identity/jwt-jwks.json" \
    | jq '{key_count: (.keys | length), key_ids: [.keys[].kid]}'
  printf '# SPIFFE bundle\n'
  curl -fsSk "$proxy/webapi/spiffe/bundle.json" \
    | jq '{key_count: (.keys | length), key_ids: [.keys[].kid]}'
}

test_app() {
  local response expected_client expected_server
  expected_client="spiffe://_teleport_app.$TPDEV_CLUSTER_NAME/app/$TPDEV_MWI_APP_NAME"
  expected_server="spiffe://$TPDEV_CLUSTER_NAME/alpha/_/app/server"

  if curl -fsSk "https://127.0.0.1:$TPDEV_MWI_APP_PORT/" >/dev/null 2>&1; then
    die "the upstream accepted a direct connection without a managed client certificate"
  fi

  response=$(curl -fsS --retry 10 --retry-delay 1 "http://127.0.0.1:$TPDEV_MWI_APP_TUNNEL_PORT/")
  jq -e \
    --arg client "$expected_client" \
    --arg server "$expected_server" \
    '.status == "ok" and .client_spiffe_id == $client and .server_spiffe_id == $server' \
    <<< "$response" >/dev/null \
    || die "managed-mTLS response did not contain the expected SPIFFE identities"
  jq . <<< "$response"
}

detect_container_provider() {
  local start_machine=${1:-false}

  if [ -n "${TPDEV_MWI_CONTAINER_PROVIDER:-}" ]; then
    case "$TPDEV_MWI_CONTAINER_PROVIDER" in
      podman|docker) printf '%s\n' "$TPDEV_MWI_CONTAINER_PROVIDER"; return ;;
      *) die "TPDEV_MWI_CONTAINER_PROVIDER must be 'podman' or 'docker'" ;;
    esac
  fi

  if command -v podman >/dev/null 2>&1 && podman machine inspect >/dev/null 2>&1; then
    if [ "$start_machine" = true ]; then
      local state
      state=$(podman machine inspect | jq -r '.[0].State')
      if [ "$state" != running ]; then
        info "starting Podman machine" >&2
        podman machine start >&2
      fi
    fi
    printf '%s\n' podman
    return
  fi

  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    printf '%s\n' docker
    return
  fi

  die "no usable Podman machine or Docker daemon was found"
}

engine_for_provider() {
  case "$1" in
    podman) printf '%s\n' podman ;;
    docker) printf '%s\n' docker ;;
  esac
}

host_name_for_provider() {
  case "$1" in
    podman) printf '%s\n' host.containers.internal ;;
    docker) printf '%s\n' host.docker.internal ;;
  esac
}

container_can_reach_proxy() {
  local engine=$1
  local address=$2
  # Use --max-redirect=0: Teleport redirects requests whose Host header doesn't
  # match public_addr. We only need to confirm the TCP+TLS connection succeeds.
  "$engine" run --rm --add-host=host.docker.internal:host-gateway \
    alpine:3.20 sh -c \
    "wget --no-check-certificate --max-redirect=0 -q -O /dev/null \"https://$address/webapi/ping\" 2>/dev/null; [ \$? -le 8 ]" \
    >/dev/null 2>&1
}

resolve_host_gateway_ip() {
  local engine=$1
  "$engine" run --rm --add-host=host.docker.internal:host-gateway \
    alpine:3.20 sh -c 'getent hosts host.docker.internal | awk "{print \$1}"' 2>/dev/null
}

resolve_container_proxy() {
  local provider=$1
  local engine=$2
  local host_ip

  # Resolve the host gateway IP from inside a container. Use the IP directly
  # to avoid Teleport redirecting based on hostname mismatch with public_addr.
  host_ip=$(resolve_host_gateway_ip "$engine")

  if [ -n "$host_ip" ]; then
    if container_can_reach_proxy "$engine" "$host_ip:$TPDEV_WEB_PORT"; then
      printf '%s:%s\n' "$host_ip" "$TPDEV_WEB_PORT"
      return
    fi
    if container_can_reach_proxy "$engine" "$host_ip:$TPDEV_MWI_CONTAINER_RELAY_PORT"; then
      printf '%s:%s\n' "$host_ip" "$TPDEV_MWI_CONTAINER_RELAY_PORT"
      return
    fi
  fi

  die "containers cannot reach Teleport at $host_ip. Ensure the host relay is running (TPDEV_MWI_CONTAINER_RELAY=1) or check container networking"
}

kind_cluster_exists() {
  local cluster
  while IFS= read -r cluster; do
    [ "$cluster" = "$TPDEV_MWI_KIND_CLUSTER" ] && return 0
  done < <(kind get clusters 2>/dev/null)
  return 1
}

ensure_kind_cluster() {
  local previous_context=""
  previous_context=$(kubectl config current-context 2>/dev/null || true)

  if ! kind_cluster_exists; then
    info "creating kind cluster $TPDEV_MWI_KIND_CLUSTER"
    kind create cluster \
      --name "$TPDEV_MWI_KIND_CLUSTER" \
      --config "$MWI_ROOT/kubernetes/kind.yaml"
  else
    info "reusing kind cluster $TPDEV_MWI_KIND_CLUSTER"
  fi

  kubectl --context "$KUBE_CONTEXT" wait \
    --for=condition=Ready node --all --timeout=120s >/dev/null

  if [ -n "$previous_context" ] && kubectl config get-contexts "$previous_context" >/dev/null 2>&1; then
    kubectl config use-context "$previous_context" >/dev/null
  fi
}

build_tbot_image() {
  local engine=$1
  local arch build_dir
  arch=$(kubectl --context "$KUBE_CONTEXT" get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}')
  [ -n "$arch" ] || die "could not determine the kind node architecture"
  build_dir="$TPDEV_MWI_DIR/kubernetes/build/linux-$arch"
  ensure_state_dir "$build_dir"

  info "building local tbot for linux/$arch"
  # Build directly with go build to avoid Makefile BUILDDIR path mangling
  # (the enterprise Makefile prepends e/ to BUILDDIR, breaking absolute paths).
  (cd "$TPDEV_SRC" && \
    GOOS=linux GOARCH="$arch" CGO_ENABLED=0 go build \
      -tags "grpcnotrace kustomize_disable_go_plugin_support" \
      -o "$build_dir/tbot" \
      -ldflags '-w -s' \
      -trimpath \
      ./tool/tbot)

  info "building $TPDEV_MWI_TBOT_IMAGE:dev"
  "$engine" build \
    --platform "linux/$arch" \
    --file "$MWI_ROOT/kubernetes/Dockerfile.tbot" \
    --tag "$TPDEV_MWI_TBOT_IMAGE:dev" \
    "$build_dir"

  kind load docker-image "$TPDEV_MWI_TBOT_IMAGE:dev" \
    --name "$TPDEV_MWI_KIND_CLUSTER"
}

render_kube_token() {
  local tenant=$1
  local jwks=$2
  local destination="$TPDEV_MWI_DIR/kubernetes/$tenant-token.yaml"
  export TENANT="$tenant"
  render_template "$MWI_ROOT/teleport/kube-token.yaml.tmpl" "$destination"
  JWKS="$jwks" yq -i '.spec.kubernetes.static_jwks.jwks = strenv(JWKS)' "$destination"
  local_tctl create --force "$destination" >/dev/null
}

render_kube_values() {
  local tenant=$1
  local proxy_address=$2
  local destination="$TPDEV_MWI_DIR/kubernetes/$tenant-values.yaml"
  export TENANT="$tenant"
  export CONTAINER_PROXY_ADDRESS="$proxy_address"
  render_template "$MWI_ROOT/kubernetes/values.yaml.tmpl" "$destination"
  printf '%s\n' "$destination"
}

deploy_kubernetes_lab() {
  local proxy_address=$1
  local jwks chart values tenant workloads
  chart="$TPDEV_SRC/examples/chart/tbot-spiffe-daemon-set"
  [ -f "$chart/Chart.yaml" ] || die "tbot SPIFFE DaemonSet chart not found at $chart"

  local_tctl create --force "$MWI_ROOT/teleport/alpha.yaml" >/dev/null
  local_tctl create --force "$MWI_ROOT/teleport/beta.yaml" >/dev/null

  jwks=$(kubectl --context "$KUBE_CONTEXT" get --raw /openid/v1/jwks)
  [ -n "$jwks" ] || die "kind returned an empty JWKS"

  ensure_state_dir "$TPDEV_MWI_DIR/kubernetes"
  for tenant in alpha beta; do
    render_kube_token "$tenant" "$jwks"
    values=$(render_kube_values "$tenant" "$proxy_address")
    helm upgrade --install "mwi-$tenant-tbot" "$chart" \
      --kube-context "$KUBE_CONTEXT" \
      --namespace mwi-system \
      --create-namespace \
      --values "$values" >/dev/null
    kubectl --context "$KUBE_CONTEXT" --namespace mwi-system \
      rollout restart "daemonset/mwi-$tenant-tbot" >/dev/null
  done

  workloads="$TPDEV_MWI_DIR/kubernetes/workloads.yaml"
  render_template "$MWI_ROOT/kubernetes/workloads.yaml.tmpl" "$workloads"
  kubectl --context "$KUBE_CONTEXT" apply -f "$workloads" >/dev/null
  kubectl --context "$KUBE_CONTEXT" --namespace mwi-alpha rollout restart deployment/inspector >/dev/null
  kubectl --context "$KUBE_CONTEXT" --namespace mwi-beta rollout restart deployment/inspector >/dev/null

  for tenant in alpha beta; do
    kubectl --context "$KUBE_CONTEXT" --namespace mwi-system \
      rollout status "daemonset/mwi-$tenant-tbot" --timeout=180s
    kubectl --context "$KUBE_CONTEXT" --namespace "mwi-$tenant" \
      rollout status deployment/inspector --timeout=120s
  done
}

kube_up() {
  local provider engine proxy_address
  require_cluster
  for command in kind kubectl helm jq yq envsubst; do
    require_command "$command"
  done

  provider=$(detect_container_provider true)
  engine=$(engine_for_provider "$provider")
  require_command "$engine"
  "$engine" info >/dev/null
  export KIND_EXPERIMENTAL_PROVIDER="$provider"
  info "using $provider for kind"

  proxy_address=$(resolve_container_proxy "$provider" "$engine")
  info "containers will reach Teleport at $proxy_address"
  ensure_kind_cluster
  build_tbot_image "$engine"
  deploy_kubernetes_lab "$proxy_address"
  info "Kubernetes MWI lab is ready in context $KUBE_CONTEXT"
}

kube_down() {
  local provider
  provider=$(detect_container_provider false)
  export KIND_EXPERIMENTAL_PROVIDER="$provider"
  if kind_cluster_exists; then
    kind delete cluster --name "$TPDEV_MWI_KIND_CLUSTER"
  else
    info "kind cluster $TPDEV_MWI_KIND_CLUSTER does not exist"
  fi
}

inspect_kube() {
  local tenant=$1
  tenant_value "$tenant" true true >/dev/null
  kubectl --context "$KUBE_CONTEXT" --namespace "mwi-$tenant" \
    exec deployment/inspector -- \
    tbot spiffe-inspect --path "unix:///run/spiffe/mwi-$tenant.sock" \
    | redact_spiffe_output
}

inspect_kube_cross_tenant_denial() {
  local output status
  set +e
  output=$(kubectl --context "$KUBE_CONTEXT" --namespace mwi-beta \
    exec deployment/inspector -- \
    tbot spiffe-inspect --path unix:///run/spiffe/mwi-alpha.sock 2>&1)
  status=$?
  set -e
  redact_spiffe_output <<< "$output"
  if [ "$status" -eq 0 ]; then
    die "beta unexpectedly obtained an identity from the alpha Workload API"
  fi
  info "beta was correctly denied by the alpha WorkloadIdentity rules"
}

show_status() {
  local tenant port
  printf '%-20s %s\n' COMPONENT STATUS
  for tenant in alpha beta; do
    port=$(tenant_value "$tenant" "$TPDEV_MWI_ALPHA_DIAG_PORT" "$TPDEV_MWI_BETA_DIAG_PORT")
    if curl -fsS "http://127.0.0.1:$port/readyz" >/dev/null 2>&1; then
      printf '%-20s %s\n' "host-$tenant" ready
    else
      printf '%-20s %s\n' "host-$tenant" unavailable
    fi
  done
  if curl -fsS "http://127.0.0.1:$TPDEV_MWI_APP_CLIENT_DIAG_PORT/readyz" >/dev/null 2>&1; then
    printf '%-20s %s\n' app-client ready
  else
    printf '%-20s %s\n' app-client unavailable
  fi
  if kubectl --context "$KUBE_CONTEXT" get --raw=/readyz >/dev/null 2>&1; then
    printf '%-20s %s\n' kubernetes ready
  else
    printf '%-20s %s\n' kubernetes unavailable
  fi
}

doctor() {
  local failed=0 command
  for command in teleport curl jq yq envsubst go helm kind kubectl; do
    if command -v "$command" >/dev/null 2>&1; then
      printf 'ok      %s\n' "$command"
    else
      printf 'missing %s\n' "$command"
      failed=1
    fi
  done

  for command in tctl tbot; do
    if [ -x "$MWI_BUILD_DIR/$command" ]; then
      printf 'ok      %s (%s)\n' "$command" "$MWI_BUILD_DIR/$command"
    else
      printf 'missing %s (%s)\n' "$command" "$MWI_BUILD_DIR/$command"
      failed=1
    fi
  done

  if [ -f "$TPDEV_CONFIG" ] && local_tctl status >/dev/null 2>&1; then
    printf 'ok      Teleport cluster (%s)\n' "$TPDEV_CLUSTER_NAME"
  else
    printf 'missing local Teleport cluster\n'
    failed=1
  fi
  if [ -f "$TPDEV_SRC/examples/chart/tbot-spiffe-daemon-set/Chart.yaml" ]; then
    printf 'ok      tbot SPIFFE DaemonSet chart\n'
  else
    printf 'missing tbot SPIFFE DaemonSet chart in TPDEV_SRC\n'
    failed=1
  fi

  printf 'source  %s\n' "$TPDEV_SRC"
  printf 'state   %s\n' "$TPDEV_MWI_DIR"
  return "$failed"
}

run_tests() {
  local suite=${1:-all}
  require_command bats
  case "$suite" in
    host) bats "$MWI_ROOT/tests/host.bats" ;;
    kube|kubernetes) bats "$MWI_ROOT/tests/kubernetes.bats" ;;
    all)
      bats "$MWI_ROOT/tests/host.bats"
      bats "$MWI_ROOT/tests/kubernetes.bats"
      ;;
    *) die "test suite must be host, kube, or all" ;;
  esac
}

usage() {
  cat <<'EOF'
Usage: tp-mwi <command>

Host lab (start with TPDEV_MWI=1 devenv up):
  doctor                         Check local prerequisites and cluster access
  status                         Show host and Kubernetes component readiness
  inspect host <alpha|beta>      Safely inspect a host Workload API
  inspect endpoints              Inspect global SPIFFE/OIDC/JWKS endpoints
  app test                       Test the managed-mTLS application path
  test <host|kube|all>           Run Bats smoke tests

Kubernetes lab:
  kube up                        Create/reconcile kind, tbot, and workloads
  kube down                      Delete only the dedicated kind cluster
  inspect kube <alpha|beta>      Safely inspect an in-cluster workload
  inspect kube-cross             Verify beta cannot use alpha's socket

Internal process commands:
  host-init <alpha|beta>
  app-client-init
  app-agent-config
EOF
}

main() {
  local command=${1:-help}
  case "$command" in
    doctor) shift; doctor "$@" ;;
    status) shift; show_status "$@" ;;
    host-init) shift; [ "$#" -eq 1 ] || die "host-init requires a tenant"; init_tenant "$1" ;;
    app-client-init) shift; [ "$#" -eq 0 ] || die "app-client-init takes no arguments"; init_app_client ;;
    app-agent-config) die "app-agent-config is no longer needed; the MWI app is in the main teleport config" ;;
    app)
      shift
      [ "${1:-}" = test ] || die "usage: tp-mwi app test"
      shift
      [ "$#" -eq 0 ] || die "usage: tp-mwi app test"
      test_app
      ;;
    inspect)
      shift
      case "${1:-}" in
        host) [ "$#" -eq 2 ] || die "usage: tp-mwi inspect host <alpha|beta>"; inspect_host "$2" ;;
        kube) [ "$#" -eq 2 ] || die "usage: tp-mwi inspect kube <alpha|beta>"; inspect_kube "$2" ;;
        kube-cross) [ "$#" -eq 1 ] || die "usage: tp-mwi inspect kube-cross"; inspect_kube_cross_tenant_denial ;;
        endpoints) [ "$#" -eq 1 ] || die "usage: tp-mwi inspect endpoints"; inspect_endpoints ;;
        *) die "unknown inspect target '${1:-}'" ;;
      esac
      ;;
    kube)
      shift
      case "${1:-}" in
        up) shift; [ "$#" -eq 0 ] || die "usage: tp-mwi kube up"; kube_up ;;
        down) shift; [ "$#" -eq 0 ] || die "usage: tp-mwi kube down"; kube_down ;;
        *) die "usage: tp-mwi kube <up|down>" ;;
      esac
      ;;
    test) shift; run_tests "${1:-all}" ;;
    help|-h|--help) usage ;;
    *) die "unknown command '$command'; run 'tp-mwi help'" ;;
  esac
}

main "$@"
