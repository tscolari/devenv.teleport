#!/usr/bin/env bats

setup() {
  : "${TPDEV_CLUSTER_NAME:=teleport-local}"
  : "${TPDEV_MWI_ALPHA_DIAG_PORT:=18101}"
  : "${TPDEV_MWI_BETA_DIAG_PORT:=18102}"
  : "${TPDEV_MWI_APP_CLIENT_DIAG_PORT:=18103}"
}

@test "alpha host tbot is ready" {
  run curl -fsS "http://127.0.0.1:$TPDEV_MWI_ALPHA_DIAG_PORT/readyz"
  [ "$status" -eq 0 ]
}

@test "beta host tbot is ready" {
  run curl -fsS "http://127.0.0.1:$TPDEV_MWI_BETA_DIAG_PORT/readyz"
  [ "$status" -eq 0 ]
}

@test "alpha uses its virtual trust domain while beta uses the cluster trust domain" {
  local uid
  uid=$(id -u)

  run tp-mwi inspect host alpha
  [ "$status" -eq 0 ]
  [[ "$output" == *"spiffe://alpha.$TPDEV_CLUSTER_NAME/_/host/$uid/inspector"* ]]
  [[ "$output" == *"- alpha.$TPDEV_CLUSTER_NAME (#CAs:"* ]]
  [[ "$output" != *"eyJ"* ]]

  run tp-mwi inspect host beta
  [ "$status" -eq 0 ]
  [[ "$output" == *"spiffe://$TPDEV_CLUSTER_NAME/beta/_/host/$uid/inspector"* ]]
  [[ "$output" == *"- $TPDEV_CLUSTER_NAME (#CAs:"* ]]
  [[ "$output" != *"eyJ"* ]]
}

@test "global SPIFFE and OIDC endpoints are available" {
  run tp-mwi inspect endpoints
  [ "$status" -eq 0 ]
  [[ "$output" == *"# OIDC configuration"* ]]
  [[ "$output" == *"# JWT JWKS"* ]]
  [[ "$output" == *"# SPIFFE bundle"* ]]
}

@test "managed-mTLS app path presents the expected app client identity" {
  run curl -fsS "http://127.0.0.1:$TPDEV_MWI_APP_CLIENT_DIAG_PORT/readyz"
  [ "$status" -eq 0 ]

  run tp-mwi app test
  [ "$status" -eq 0 ]
  [[ "$output" == *"spiffe://_teleport_app.$TPDEV_CLUSTER_NAME/app/mwi-mtls-app"* ]]
  [[ "$output" == *"spiffe://alpha.$TPDEV_CLUSTER_NAME/_/app/server"* ]]
}
