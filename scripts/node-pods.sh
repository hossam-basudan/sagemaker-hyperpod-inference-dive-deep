#!/usr/bin/env bash
# Prints how full each node is: pods used of the node's pod limit, free pod slots, GPUs requested of
# the GPUs it has, and (unless -s) its pods by namespace, split into DaemonSet pods (one per node, they
# can't move) and the rest (which the scheduler could place on another node). HyperPod limits pods per node (14 on an
# ml.g5.2xlarge), so a pod can stay Pending with "Too many pods" even when a GPU is free.
# Read-only. Needs kubectl and jq.
# Usage: scripts/node-pods.sh [-s]          (-s: one line per node, no namespace breakdown)
set -euo pipefail

SUMMARY=false
[[ "${1:-}" == "-s" ]] && SUMMARY=true

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
kubectl get nodes -o json > "$TMP/nodes.json"
kubectl get pods -A --field-selector=status.phase!=Succeeded,status.phase!=Failed -o json > "$TMP/pods.json"

jq -r --argjson summary "$SUMMARY" --slurpfile pods "$TMP/pods.json" '
  def pad($n): tostring | if length < $n then . + (" " * ($n - length)) else . end;
  def gpus: [.spec.containers[]?.resources.requests["nvidia.com/gpu"] // "0" | tonumber] | add // 0;
  ($pods[0].items | group_by(.spec.nodeName // "") | map({key: (.[0].spec.nodeName // ""), value: .}) | from_entries) as $by_node
  | "\("NODE" | pad(32)) \("GROUP" | pad(30)) \("INSTANCE TYPE" | pad(15)) \("PODS" | pad(7)) \("FREE" | pad(5)) GPUS",
    (.items
     | sort_by(.metadata.labels["sagemaker.amazonaws.com/instance-group-name"] // "", .metadata.name)
     | .[]
     | .metadata.name as $n
     | ($by_node[$n] // []) as $p
     | (.status.allocatable.pods | tonumber) as $cap
     | (.status.allocatable["nvidia.com/gpu"] // "0" | tonumber) as $gpu
     | ($p | length) as $used
     | "\($n | pad(32)) \(.metadata.labels["sagemaker.amazonaws.com/instance-group-name"] // "-" | pad(30)) \(.metadata.labels["node.kubernetes.io/instance-type"] // "-" | pad(15)) \("\($used)/\($cap)" | pad(7)) \($cap - $used | pad(5)) \(if $gpu > 0 then "\($p | map(gpus) | add // 0)/\($gpu)" else "-" end)\(if $cap - $used <= 0 then "   FULL" else "" end)",
       (if $summary then empty else
          ($p | group_by(.metadata.namespace)
           | map({ns: .[0].metadata.namespace, n: length,
                  ds: (map(select(.metadata.ownerReferences[0].kind? == "DaemonSet")) | length)})
           | sort_by(-.n, .ns)
           | .[] | "    \(.n | tostring | if length < 3 then (" " * (3 - length)) + . else . end) \(.ns | pad(28))\(
                   if .ds == .n then "DaemonSet (one per node)" elif .ds == 0 then "can run on another node"
                   else "\(.ds) DaemonSet, \(.n - .ds) can run on another node" end)")
        end),
       (if $summary then empty else "" end))
  ' "$TMP/nodes.json"

pending=$(jq '[.items[] | select(.status.phase == "Pending" and (.spec.nodeName // "") == "")] | length' "$TMP/pods.json")
if (( pending > 0 )); then
  echo "Pending pods not yet placed on a node: $pending (kubectl get pods -A --field-selector=status.phase=Pending)"
fi
