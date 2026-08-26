#!/usr/bin/env bats
# SDS (Secret Discovery Service) integration tests for VTD support.
# Validates that tbot's SDS endpoint correctly serves VTD trust bundles
# and SVIDs using the envoy xDS/SDS protocol.
#
# Prerequisites: TPDEV_MWI=1 devenv up (alpha tbot must be running)

setup() {
  : "${TPDEV_CLUSTER_NAME:=teleport-local}"
  : "${TPDEV_MWI_ROOT:=$BATS_TEST_DIRNAME/..}"
  MWI_ROOT="$TPDEV_MWI_ROOT"
  ALPHA_SOCKET="/tmp/tpdev-mwi-alpha/workload.sock"
}

sds_client() {
  go run "$MWI_ROOT/sds-client" \
    -socket "$ALPHA_SOCKET" \
    -vtd-trust-domain "alpha.$TPDEV_CLUSTER_NAME" \
    -cluster-trust-domain "$TPDEV_CLUSTER_NAME" \
    -json
}

@test "alpha SDS socket is available" {
  [ -S "$ALPHA_SOCKET" ]
}

@test "SDS serves VTD and cluster bundles in ALL response" {
  result=$(sds_client)
  echo "$result" | jq -e '.results[] | select(.name == "ALL contains VTD and cluster trust domains") | .pass == true'
}

@test "SDS serves specific VTD bundle by spiffe:// ID" {
  result=$(sds_client)
  echo "$result" | jq -e '.results[] | select(.name == "specific VTD bundle request") | .pass == true'
}

@test "SDS ROOTCA returns only cluster trust domain (not VTD)" {
  result=$(sds_client)
  echo "$result" | jq -e '.results[] | select(.name == "ROOTCA returns only cluster trust domain") | .pass == true'
}

@test "SDS serves a default SVID" {
  result=$(sds_client)
  echo "$result" | jq -e '.results[] | select(.name == "default SVID is served") | .pass == true'
}

@test "SDS empty resource names returns VTD SVID and bundles" {
  result=$(sds_client)
  echo "$result" | jq -e '.results[] | select(.name == "empty resource names returns VTD SVID and bundles") | .pass == true'
}

@test "SDS VTD SVID is requestable by specific SPIFFE ID" {
  result=$(sds_client)
  echo "$result" | jq -e '.results[] | select(.name == "VTD SVID requestable by SPIFFE ID") | .pass == true'
}
