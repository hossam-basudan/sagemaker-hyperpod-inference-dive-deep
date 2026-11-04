#!/usr/bin/env bash
# Frees the GPU nodes: deletes what the labs (and the base workshop's training labs) leave on them, so
# the cluster is back to the state a lab expects at its start:
#   - every InferenceEndpointConfig and JumpStartModel, in all namespaces (with their SageMaker
#     endpoints and load balancers)
#   - training jobs: lab 7's Jobs in hyperpod-ns-team-a/b, and HyperPodPyTorchJobs in all namespaces
#   - lab 4's fsx-model-copy pod, lab 6's image and weights caches
#   - lab 6's tiered storage (the ai-toolkit daemons), if it's on
# It doesn't remove add-ons (inference, observability, task governance) or anything setup.sh created.
# Safe to rerun.
# Usage: scripts/reset-gpus.sh [-y]          (-y skips the confirmation prompt)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
AUTO_APPROVE=false
[[ "${1:-}" == "-y" ]] && AUTO_APPROVE=true

log() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

[[ -f "$ROOT/env.sh" ]] || die "run scripts/setup.sh first"
# shellcheck source=/dev/null
source "$ROOT/env.sh"
export AWS_PAGER=""

# get <kubectl get args...>: names of what exists, one per line; nothing if the resource type isn't installed
get() { kubectl get "$@" --no-headers -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name' 2>/dev/null \
          | awk '{print "  " $1 "/" $2}' || true; }

MODELS=$(get inferenceendpointconfig,jumpstartmodel -A)
JOBS=$( (get job -n hyperpod-ns-team-a; get job -n hyperpod-ns-team-b; get hyperpodpytorchjob -A) )
HELPERS=$( (get pod fsx-model-copy -n default; get modelimagecache,modelweightscacheconfig -A) )
TIERED=$(aws sagemaker describe-cluster --cluster-name "$HYPERPOD_CLUSTER_NAME" --region "$REGION" \
           --query TieredStorageConfig.Mode --output text 2>/dev/null || echo unknown)

cat <<EOF

Cluster : $HYPERPOD_CLUSTER_NAME ($REGION)
Deletes:
Models (and their SageMaker endpoints and load balancers):
${MODELS:-  none}
Training jobs:
${JOBS:-  none}
Helper pods and caches:
${HELPERS:-  none}
Tiered storage: $TIERED$([[ "$TIERED" == Enable ]] && echo " (will be turned off)")
EOF

if [[ -z "$MODELS$JOBS$HELPERS" && "$TIERED" != Enable ]]; then
  echo
  echo "Nothing to delete."
else
  if ! $AUTO_APPROVE; then
    read -r -p "Continue? [y/N] " ans || ans=""
    [[ "$ans" =~ ^[Yy]$ ]] || die "aborted"
  fi
  log "Deleting"
  kubectl delete inferenceendpointconfig,jumpstartmodel --all -A --ignore-not-found 2>/dev/null || true
  for ns in hyperpod-ns-team-a hyperpod-ns-team-b; do
    kubectl delete job --all -n "$ns" --ignore-not-found 2>/dev/null || true
  done
  kubectl delete hyperpodpytorchjob --all -A --ignore-not-found 2>/dev/null || true
  kubectl delete pod fsx-model-copy -n default --ignore-not-found 2>/dev/null || true
  kubectl delete modelimagecache,modelweightscacheconfig --all -A --ignore-not-found 2>/dev/null || true
  if [[ "$TIERED" == Enable ]]; then
    aws sagemaker update-cluster --cluster-name "$HYPERPOD_CLUSTER_NAME" --region "$REGION" \
      --tiered-storage-config Mode=Disable >/dev/null && echo "tiered storage: turning off"
  fi

  log "Waiting for the model and job pods to stop (up to 5 minutes)"
  for _ in $(seq 30); do
    left=$( (kubectl get pods -A -l deploying-service=hyperpod-inference --no-headers 2>/dev/null
             kubectl get pods -n hyperpod-ns-team-a --no-headers 2>/dev/null
             kubectl get pods -n hyperpod-ns-team-b --no-headers 2>/dev/null) | grep -c . || true)
    [[ "$left" -eq 0 ]] && break
    echo "  $left pods still stopping"
    sleep 10
  done
fi

log "Nodes"
"$HERE/node-pods.sh"
cat <<EOF

Done. The GPU nodes should now show 0 GPUs requested and only system pods: DaemonSets in
kube-system and aws-hyperpod, plus hyperpod-observability if that add-on is installed.
EOF
