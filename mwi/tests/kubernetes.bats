#!/usr/bin/env bats

setup() {
  : "${TPDEV_CLUSTER_NAME:=teleport-local}"
  : "${TPDEV_MWI_KIND_CLUSTER:=teleport-mwi}"
  : "${TPDEV_MWI_TBOT_IMAGE:=teleport-mwi-tbot}"
  KUBE_CONTEXT="kind-$TPDEV_MWI_KIND_CLUSTER"
}

@test "dedicated kind cluster is ready" {
  run kubectl --context "$KUBE_CONTEXT" get --raw=/readyz
  [ "$status" -eq 0 ]
}

@test "kind uses the tbot image built from the local Teleport checkout" {
  local tenant image
  for tenant in alpha beta; do
    image=$(kubectl --context "$KUBE_CONTEXT" --namespace mwi-system \
      get "daemonset/mwi-$tenant-tbot" \
      -o jsonpath='{.spec.template.spec.containers[0].image}')
    [ "$image" = "$TPDEV_MWI_TBOT_IMAGE:dev" ]
  done
}

@test "Kubernetes workloads receive attested tenant identities" {
  run tp-mwi inspect kube alpha
  [ "$status" -eq 0 ]
  [[ "$output" == *"spiffe://alpha.$TPDEV_CLUSTER_NAME/_/k8s/mwi-alpha/mwi-workload"* ]]
  [[ "$output" == *"- $TPDEV_CLUSTER_NAME (#CAs:"* ]]
  [[ "$output" != *"eyJ"* ]]

  run tp-mwi inspect kube beta
  [ "$status" -eq 0 ]
  [[ "$output" == *"spiffe://$TPDEV_CLUSTER_NAME/beta/_/k8s/mwi-beta/mwi-workload"* ]]
  [[ "$output" == *"- $TPDEV_CLUSTER_NAME (#CAs:"* ]]
  [[ "$output" != *"eyJ"* ]]
}

@test "beta cannot obtain an identity from the alpha Workload API" {
  run tp-mwi inspect kube-cross
  [ "$status" -eq 0 ]
  [[ "$output" == *"correctly denied"* ]]
}
