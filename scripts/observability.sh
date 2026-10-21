#!/usr/bin/env bash
# Optional, for module 4's Prometheus trigger and module 5's metrics in Prometheus:
# creates an Amazon Managed Service for Prometheus workspace and installs the HyperPod observability
# EKS add-on that scrapes the cluster into it. No Grafana: Workshop Studio accounts can't use
# IAM Identity Center, which Amazon Managed Grafana needs for sign-in.
# Safe to rerun. Run scripts/setup.sh first. Usage: scripts/observability.sh [-y]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
ADDON=amazon-sagemaker-hyperpod-observability
AUTO_APPROVE=false
[[ "${1:-}" == "-y" ]] && AUTO_APPROVE=true

log() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

[[ -f "$ROOT/env.sh" ]] || die "run scripts/setup.sh first"
# shellcheck source=/dev/null
source "$ROOT/env.sh"
export AWS_DEFAULT_REGION=$REGION
EKS_CLUSTER_ARN=$(aws eks describe-cluster --name "$EKS_CLUSTER_NAME" --query cluster.arn --output text)
ALIAS=hyperpod-dd-${HYPERPOD_CLUSTER_NAME:0:30}
ROLE_NAME=hyperpod-dd-${HYPERPOD_CLUSTER_NAME:0:30}-observability

cat <<EOF

Account     : $ACCOUNT_ID
Region      : $REGION
EKS cluster : $EKS_CLUSTER_NAME
Creates if missing: Prometheus workspace $ALIAS, IAM role $ROLE_NAME, EKS add-on $ADDON
Prometheus bills for ingested samples and storage while the add-on runs.
EOF
# The add-on runs three system-node-critical DaemonSet pods on every node. HyperPod caps pods per
# node (14 on ml.g5.2xlarge), and on a full node those pods preempt whatever runs there, models included.
if ! aws eks describe-addon --cluster-name "$EKS_CLUSTER_NAME" --addon-name "$ADDON" >/dev/null 2>&1; then
  GPU_NODES=$(kubectl get nodes -o json | jq -r '.items[] | select(.status.allocatable["nvidia.com/gpu"] != null) | .metadata.name')
  for n in $GPU_NODES; do
    cap=$(kubectl get node "$n" -o jsonpath='{.status.allocatable.pods}')
    used=$(kubectl get pods -A --field-selector "spec.nodeName=$n,status.phase!=Succeeded,status.phase!=Failed" --no-headers | wc -l | tr -d ' ')
    if (( cap - used < 3 )); then
      echo "WARNING: $n runs $used of $cap pods; the add-on's 3 pods per node will preempt workloads there."
      echo "         Run scripts/setup.sh first (it moves controllers off GPU nodes), or delete inference deployments."
    fi
  done
fi
if ! $AUTO_APPROVE; then
  read -r -p "Continue? [y/N] " ans || ans=""
  [[ "$ans" =~ ^[Yy]$ ]] || die "aborted"
fi

aws eks describe-addon --cluster-name "$EKS_CLUSTER_NAME" --addon-name eks-pod-identity-agent >/dev/null 2>&1 \
  || die "the add-on uses EKS Pod Identity; install the eks-pod-identity-agent add-on first"

log "Prometheus workspace"
WS_ID=$(aws amp list-workspaces --alias "$ALIAS" --query 'workspaces[0].workspaceId' --output text)
if [[ "$WS_ID" == "None" || -z "$WS_ID" ]]; then
  WS_ID=$(aws amp create-workspace --alias "$ALIAS" --query workspaceId --output text)
  echo "created $WS_ID"
fi
aws amp wait workspace-active --workspace-id "$WS_ID"
WS=$(aws amp describe-workspace --workspace-id "$WS_ID" --output json)
WS_ARN=$(jq -r .workspace.arn <<<"$WS")
WS_ENDPOINT=$(jq -r .workspace.prometheusEndpoint <<<"$WS")
echo "$WS_ENDPOINT"

log "IAM role for the add-on's collector"
TRUST=$(jq -cn --arg a "$ACCOUNT_ID" --arg c "$EKS_CLUSTER_ARN" '{Version: "2012-10-17", Statement: [{
  Effect: "Allow", Principal: {Service: "pods.eks.amazonaws.com"}, Action: ["sts:AssumeRole", "sts:TagSession"],
  Condition: {StringEquals: {"aws:SourceAccount": $a, "aws:SourceArn": $c}}}]}')
POLICY=$(jq -cn --arg r "$REGION" --arg a "$ACCOUNT_ID" '{Version: "2012-10-17", Statement: [
  {Effect: "Allow", Action: ["aps:RemoteWrite"], Resource: "arn:aws:aps:\($r):\($a):workspace/*"},
  {Effect: "Allow", Action: ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:DescribeLogGroups", "logs:DescribeLogStreams",
     "logs:PutLogEvents", "logs:GetLogEvents", "logs:FilterLogEvents", "logs:GetLogRecord", "logs:StartQuery",
     "logs:StopQuery", "logs:GetQueryResults"],
   Resource: ["arn:aws:logs:\($r):\($a):log-group:/aws/sagemaker/Clusters/*",
              "arn:aws:logs:\($r):\($a):log-group:/aws/sagemaker/Clusters/*:log-stream:*"]}]}')
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  aws iam update-assume-role-policy --role-name "$ROLE_NAME" --policy-document "$TRUST"
else
  aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document "$TRUST" \
    --description "HyperPod observability add-on (HyperPod inference dive deep)" >/dev/null
fi
aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name observability --policy-document "$POLICY"
ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query Role.Arn --output text)
echo "$ROLE_ARN"

if aws eks describe-addon --cluster-name "$EKS_CLUSTER_NAME" --addon-name "$ADDON" >/dev/null 2>&1; then
  log "$ADDON is already installed; leaving it as it is"
else
  log "Installing $ADDON (about 3 minutes)"
  # Key names follow the add-on's current schema (metricsProvider.clusterMetrics, metricsProvider.logging)
  CONFIG=$(jq -cn --arg e "$WS_ENDPOINT" --arg a "$WS_ARN" '{
    ampWorkspace: {prometheusEndpoint: $e, arn: $a},
    metricsProvider: {
      trainingMetrics: {level: "BASIC", scrapeInterval: 30},
      inferenceMetrics: {level: "BASIC", scrapeInterval: 30},
      taskGovernanceMetrics: {level: "DISABLED", scrapeInterval: 30},
      scalingMetrics: {level: "BASIC", scrapeInterval: 30},
      clusterMetrics: {level: "BASIC", scrapeInterval: 30},
      nodeMetrics: {level: "BASIC", scrapeInterval: 30},
      acceleratedComputeMetrics: {level: "BASIC", scrapeInterval: 30},
      networkMetrics: {level: "DISABLED", scrapeInterval: 30},
      logging: {enabled: false}}}')
  sleep 10   # a new IAM role takes a few seconds to become usable
  aws eks create-addon --cluster-name "$EKS_CLUSTER_NAME" --addon-name "$ADDON" \
    --configuration-values "$CONFIG" --resolve-conflicts OVERWRITE \
    --pod-identity-associations "serviceAccount=hyperpod-observability-operator-otel-collector,roleArn=$ROLE_ARN" >/dev/null
fi
aws eks wait addon-active --cluster-name "$EKS_CLUSTER_NAME" --addon-name "$ADDON"
aws eks describe-addon --cluster-name "$EKS_CLUSTER_NAME" --addon-name "$ADDON" \
  --query 'addon.[addonName,addonVersion,status]' --output text

cat <<EOF

Done. Metrics reach the workspace a few minutes after the add-on is ACTIVE.
Prometheus query URL: ${WS_ENDPOINT}api/v1/query
EOF
