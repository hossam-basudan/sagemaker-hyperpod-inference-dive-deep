#!/usr/bin/env bash
# Prepares a SageMaker HyperPod EKS workshop cluster for the HyperPod inference dive deep:
#   - replaces a Helm-installed inference operator with the amazon-sagemaker-hyperpod-inference
#     EKS add-on, and creates the IAM roles and TLS bucket the add-on needs
#   - creates the model bucket (module 2), and the ECR repository and CodeBuild project (module 3)
#   - writes env.sh at the repository root with the variables the pages use
#   - frees pod slots on the GPU nodes (HyperPod allows 14 pods on an ml.g5.2xlarge): moves movable
#     controllers to the CPU instance group and deletes the workshop's training-image pre-pull
#   - installs the Bash Jupyter kernel that the notebooks/ of the GitHub version run in
# Safe to rerun: existing resources are reused, and an installed add-on is left as it is.
# Usage: scripts/setup.sh [-y]          (-y skips the confirmation prompt)
#        EKS_CLUSTER_NAME=<name> scripts/setup.sh   (when the Region has more than one cluster)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
ADDON=amazon-sagemaker-hyperpod-inference
ADDON_VERSION=${ADDON_VERSION:-v2.1.0-eksbuild.1}
HELM_RELEASE=hyperpod-inference-operator
OPERATOR_NS=hyperpod-inference-system
ECR_REPOSITORY=hyperpod-byoc-vllm
BUILD_PROJECT=hyperpod-byoc-vllm-build
AUTO_APPROVE=false
[[ "${1:-}" == "-y" ]] && AUTO_APPROVE=true

log() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

for t in aws kubectl jq; do
  command -v "$t" >/dev/null || die "missing required tool: $t"
done

log "Finding the cluster"
REGION=${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null || true)}}
[[ -n "$REGION" ]] || die "set AWS_REGION"
export AWS_DEFAULT_REGION=$REGION
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

HYPERPOD_CLUSTER_NAME=""
FOUND=0
for c in $(aws sagemaker list-clusters --query 'ClusterSummaries[].ClusterName' --output text); do
  eks=$(aws sagemaker describe-cluster --cluster-name "$c" --query 'Orchestrator.Eks.ClusterArn' --output text | cut -d/ -f2)
  [[ -z "$eks" || "$eks" == "None" ]] && continue
  if [[ -n "${EKS_CLUSTER_NAME:-}" && "$eks" != "$EKS_CLUSTER_NAME" ]]; then
    continue
  fi
  HYPERPOD_CLUSTER_NAME=$c
  EKS_CLUSTER_NAME=$eks
  FOUND=$((FOUND + 1))
done
(( FOUND > 0 )) || die "no HyperPod EKS cluster found in $REGION"
(( FOUND == 1 )) || die "found $FOUND HyperPod EKS clusters in $REGION; set EKS_CLUSTER_NAME to pick one"

DESC=$(aws sagemaker describe-cluster --cluster-name "$HYPERPOD_CLUSTER_NAME" --output json)
HYPERPOD_CLUSTER_ARN=$(jq -r .ClusterArn <<<"$DESC")
INSTANCE_TYPE=$(jq -r '[.InstanceGroups[].InstanceType | select(test("^ml\\.(g|p)[0-9]"))][0] // empty' <<<"$DESC")
[[ -n "$INSTANCE_TYPE" ]] || die "the cluster has no GPU instance group"
# HyperPod caps pods per node by one network interface's addresses (14 on ml.g5.2xlarge), and
# system DaemonSets fill most of that. Run the add-on's controllers on the CPU group to leave GPU
# nodes room for models; without a CPU group, the scheduler places them anywhere.
CPU_GROUP=$(jq -r '[.InstanceGroups[] | select(.InstanceType | test("^ml\\.(g|p)[0-9]") | not) | .InstanceGroupName][0] // empty' <<<"$DESC")
PLACEMENT=$(jq -cn --arg g "$CPU_GROUP" 'if $g == "" then {} else {"sagemaker.amazonaws.com/instance-group-name": $g} end')
PLACE="if $PLACEMENT == {} then . else .alb.nodeSelector = $PLACEMENT | .keda.nodeSelector = $PLACEMENT | .inferenceGateway.nodeSelector = $PLACEMENT end"

ISSUER=$(aws eks describe-cluster --name "$EKS_CLUSTER_NAME" --query cluster.identity.oidc.issuer --output text)
OIDC=${ISSUER#https://}
OIDC_ARN=arn:aws:iam::$ACCOUNT_ID:oidc-provider/$OIDC
aws eks update-kubeconfig --name "$EKS_CLUSTER_NAME" >/dev/null

HELM_INSTALLED=false
if kubectl -n kube-system get secret -l "owner=helm,name=$HELM_RELEASE" -o name 2>/dev/null | grep -q .; then
  HELM_INSTALLED=true
fi
ADDON_INSTALLED=false
aws eks describe-addon --cluster-name "$EKS_CLUSTER_NAME" --addon-name "$ADDON" >/dev/null 2>&1 && ADDON_INSTALLED=true

# Names are fixed by the add-on and its managed policy: the TLS bucket must start with hyperpod-tls,
# and the operator can only pass roles named SageMakerHyperPodInference* to SageMaker.
SHORT=${HYPERPOD_CLUSTER_NAME:0:30}
TLS_BUCKET=hyperpod-tls-$ACCOUNT_ID-$REGION
MODEL_BUCKET=hyperpod-models-$ACCOUNT_ID-$REGION
EXEC_ROLE_NAME=SageMakerHyperPodInference-$SHORT
KEDA_ROLE_NAME=hyperpod-dd-$SHORT-keda
ALB_ROLE_NAME=hyperpod-dd-$SHORT-alb
GATED_ROLE_NAME=hyperpod-dd-$SHORT-jumpstart-gated
BUILD_ROLE_NAME=hyperpod-dd-$SHORT-codebuild

cat <<EOF

Account          : $ACCOUNT_ID
Region           : $REGION
HyperPod cluster : $HYPERPOD_CLUSTER_NAME ($INSTANCE_TYPE)
Controllers on   : ${CPU_GROUP:-any node (no CPU instance group)} (inference add-on, metrics-server,
                   training operator, FSx CSI controller)
Deletes          : the workshop's prepull-esm DaemonSet, if present (training-image pre-pull)
EKS cluster      : $EKS_CLUSTER_NAME
Inference add-on : $($ADDON_INSTALLED && echo "installed, left as it is" || echo "will install $ADDON_VERSION")
Helm operator    : $($HELM_INSTALLED && echo "installed, will be removed" || echo "not installed")
Creates if missing:
  S3 buckets     : $TLS_BUCKET, $MODEL_BUCKET
  ECR repository : $ECR_REPOSITORY
  CodeBuild      : $BUILD_PROJECT (module 3 image build)
  IAM roles      : $EXEC_ROLE_NAME, $KEDA_ROLE_NAME, $ALB_ROLE_NAME, $GATED_ROLE_NAME,
                   $BUILD_ROLE_NAME
EOF
if ! $AUTO_APPROVE; then
  read -r -p "Continue? [y/N] " ans || ans=""
  [[ "$ans" =~ ^[Yy]$ ]] || die "aborted"
fi

log "S3 buckets and ECR repository"
ensure_bucket() {
  if aws s3api head-bucket --bucket "$1" --expected-bucket-owner "$ACCOUNT_ID" >/dev/null 2>&1; then
    echo "s3://$1 exists"
  elif [[ "$REGION" == us-east-1 ]]; then
    aws s3api create-bucket --bucket "$1" >/dev/null && echo "created s3://$1"
  else
    aws s3api create-bucket --bucket "$1" --create-bucket-configuration LocationConstraint="$REGION" >/dev/null \
      && echo "created s3://$1"
  fi
}
ensure_bucket "$TLS_BUCKET"
ensure_bucket "$MODEL_BUCKET"
if aws ecr describe-repositories --repository-names "$ECR_REPOSITORY" >/dev/null 2>&1; then
  echo "ECR repository $ECR_REPOSITORY exists"
else
  aws ecr create-repository --repository-name "$ECR_REPOSITORY" >/dev/null && echo "created ECR repository $ECR_REPOSITORY"
fi
ECR_REPOSITORY_URL=$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$ECR_REPOSITORY

log "CodeBuild project for module 3"
# Module 3 builds its image here: the workshop editor has no Docker. The build runs in the cluster's
# subnet so its Docker Hub pulls leave through this account's NAT gateway, not CodeBuild's shared addresses.
SUBNET_ID=$(jq -r '.VpcConfig.Subnets[0]' <<<"$DESC")
SECURITY_GROUP_ID=$(jq -r '.VpcConfig.SecurityGroupIds[0]' <<<"$DESC")
VPC_ID=$(aws ec2 describe-subnets --subnet-ids "$SUBNET_ID" --query 'Subnets[0].VpcId' --output text)
BUILD_POLICY=$(jq -cn --arg r "$REGION" --arg a "$ACCOUNT_ID" --arg p "$BUILD_PROJECT" --arg b "$MODEL_BUCKET" --arg repo "$ECR_REPOSITORY" '{
  Version: "2012-10-17",
  Statement: [
    {Effect: "Allow", Action: ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"],
     Resource: "arn:aws:logs:\($r):\($a):log-group:/aws/codebuild/\($p)*"},
    {Effect: "Allow", Action: ["s3:GetObject", "s3:GetObjectVersion"], Resource: "arn:aws:s3:::\($b)/codebuild/*"},
    {Effect: "Allow", Action: ["s3:GetBucketLocation", "s3:GetBucketAcl"], Resource: "arn:aws:s3:::\($b)"},
    {Effect: "Allow", Action: "ecr:GetAuthorizationToken", Resource: "*"},
    {Effect: "Allow", Action: ["ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart",
       "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"],
     Resource: "arn:aws:ecr:\($r):\($a):repository/\($repo)"},
    {Effect: "Allow", Action: ["ec2:CreateNetworkInterface", "ec2:DescribeDhcpOptions", "ec2:DescribeNetworkInterfaces",
       "ec2:DeleteNetworkInterface", "ec2:DescribeSubnets", "ec2:DescribeSecurityGroups", "ec2:DescribeVpcs"], Resource: "*"},
    {Effect: "Allow", Action: "ec2:CreateNetworkInterfacePermission", Resource: "arn:aws:ec2:\($r):\($a):network-interface/*",
     Condition: {StringEquals: {"ec2:AuthorizedService": "codebuild.amazonaws.com"}}}
  ]}')
if ! aws iam get-role --role-name "$BUILD_ROLE_NAME" >/dev/null 2>&1; then
  aws iam create-role --role-name "$BUILD_ROLE_NAME" --description "CodeBuild for the HyperPod inference dive deep, module 3" \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"codebuild.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
fi
aws iam put-role-policy --role-name "$BUILD_ROLE_NAME" --policy-name build --policy-document "$BUILD_POLICY"
BUILD_ROLE_ARN=$(aws iam get-role --role-name "$BUILD_ROLE_NAME" --query Role.Arn --output text)
BUILDSPEC='version: 0.2
phases:
  pre_build:
    commands:
      - aws ecr get-login-password | docker login --username AWS --password-stdin ${IMAGE_URI%%/*}
  build:
    commands:
      - docker build -t $IMAGE_URI .
      - docker push $IMAGE_URI
'
PROJECT=$(jq -cn --arg n "$BUILD_PROJECT" --arg src "$MODEL_BUCKET/codebuild/$BUILD_PROJECT.zip" --arg spec "$BUILDSPEC" \
  --arg role "$BUILD_ROLE_ARN" --arg vpc "$VPC_ID" --arg subnet "$SUBNET_ID" --arg sg "$SECURITY_GROUP_ID" '{
  name: $n, description: "Builds the module 3 vLLM image (HyperPod inference dive deep)",
  source: {type: "S3", location: $src, buildspec: $spec},
  artifacts: {type: "NO_ARTIFACTS"},
  environment: {type: "LINUX_CONTAINER", image: "aws/codebuild/amazonlinux-x86_64-standard:5.0",
                computeType: "BUILD_GENERAL1_LARGE", privilegedMode: true,
                environmentVariables: [{name: "DOCKER_BUILDKIT", value: "1"}]},
  serviceRole: $role, timeoutInMinutes: 60,
  vpcConfig: {vpcId: $vpc, subnets: [$subnet], securityGroupIds: [$sg]}}')
if [[ -n "$(aws codebuild batch-get-projects --names "$BUILD_PROJECT" --query 'projects[0].name' --output text 2>/dev/null | grep -v None)" ]]; then
  aws codebuild update-project --cli-input-json "$PROJECT" >/dev/null && echo "updated CodeBuild project $BUILD_PROJECT"
else
  # A new role can take a few seconds before CodeBuild may assume it
  for i in 1 2 3 4 5 6; do
    aws codebuild create-project --cli-input-json "$PROJECT" >/dev/null 2>&1 && break
    (( i == 6 )) && aws codebuild create-project --cli-input-json "$PROJECT" >/dev/null
    sleep 10
  done
  echo "created CodeBuild project $BUILD_PROJECT"
fi

log "IAM roles for the add-on"
if ! aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_ARN" >/dev/null 2>&1; then
  aws iam create-open-id-connect-provider --url "$ISSUER" --client-id-list sts.amazonaws.com >/dev/null
  echo "created the cluster's IAM OIDC provider"
fi
# trust <service-account subject> <StringEquals|StringLike> <also trust sagemaker.amazonaws.com: true|false>
trust() {
  jq -cn --arg arn "$OIDC_ARN" --arg k "$OIDC" --arg sub "$1" --arg op "$2" --argjson sm "$3" '{
    Version: "2012-10-17",
    Statement: ((if $sm then [{Effect: "Allow", Principal: {Service: "sagemaker.amazonaws.com"}, Action: "sts:AssumeRole"}] else [] end)
      + [{Effect: "Allow", Principal: {Federated: $arn}, Action: "sts:AssumeRoleWithWebIdentity",
          Condition: {($op): {($k + ":aud"): "sts.amazonaws.com", ($k + ":sub"): $sub}}}])}'
}
# ensure_role <name> <trust policy>: creates the role or resets its trust policy, prints its ARN
ensure_role() {
  if aws iam get-role --role-name "$1" >/dev/null 2>&1; then
    aws iam update-assume-role-policy --role-name "$1" --policy-document "$2"
  else
    aws iam create-role --role-name "$1" --assume-role-policy-document "$2" \
      --description "HyperPod inference add-on (HyperPod inference dive deep)" >/dev/null
  fi
  aws iam get-role --role-name "$1" --query Role.Arn --output text
}
EXEC_ROLE_ARN=$(ensure_role "$EXEC_ROLE_NAME" \
  "$(trust "system:serviceaccount:$OPERATOR_NS:hyperpod-inference-controller-manager" StringEquals true)")
aws iam attach-role-policy --role-name "$EXEC_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSageMakerHyperPodInferenceAccess

KEDA_ROLE_ARN=$(ensure_role "$KEDA_ROLE_NAME" \
  "$(trust "system:serviceaccount:$OPERATOR_NS:keda-operator" StringEquals false)")
aws iam put-role-policy --role-name "$KEDA_ROLE_NAME" --policy-name keda-metrics \
  --policy-document "file://$HERE/iam/keda-policy.json"

ALB_ROLE_ARN=$(ensure_role "$ALB_ROLE_NAME" \
  "$(trust "system:serviceaccount:$OPERATOR_NS:aws-load-balancer-controller" StringEquals false)")
ALB_POLICY_ARN=arn:aws:iam::$ACCOUNT_ID:policy/$ALB_ROLE_NAME
if ! aws iam get-policy --policy-arn "$ALB_POLICY_ARN" >/dev/null 2>&1; then
  aws iam create-policy --policy-name "$ALB_ROLE_NAME" \
    --policy-document "file://$HERE/iam/alb-controller-policy.json" >/dev/null
fi
aws iam attach-role-policy --role-name "$ALB_ROLE_NAME" --policy-arn "$ALB_POLICY_ARN"

GATED_ROLE_ARN=$(ensure_role "$GATED_ROLE_NAME" \
  "$(trust 'system:serviceaccount:*:hyperpod-inference-service-account*' StringLike true)")
aws iam attach-role-policy --role-name "$GATED_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSageMakerHyperPodGatedModelAccess
printf '%s\n' "$EXEC_ROLE_ARN" "$KEDA_ROLE_ARN" "$ALB_ROLE_ARN" "$GATED_ROLE_ARN"

if $HELM_INSTALLED; then
  log "Removing the Helm-installed inference operator"
  command -v helm >/dev/null || die "helm is required to remove the Helm release $HELM_RELEASE"
  # The release owns the inference CRDs, so uninstalling it deletes every deployment
  EXISTING=$(kubectl get inferenceendpointconfigs,jumpstartmodels -A --no-headers 2>/dev/null || true)
  [[ -z "$EXISTING" ]] || die "delete these inference deployments first, then rerun:
$EXISTING"
  helm list -n kube-system --filter "^$HELM_RELEASE\$"
  helm uninstall "$HELM_RELEASE" -n kube-system --wait --timeout 10m
  kubectl wait --for=delete crd/inferenceendpointconfigs.inference.sagemaker.aws.amazon.com --timeout=5m 2>/dev/null || true
fi

if ! kubectl get apiservice v1beta1.metrics.k8s.io >/dev/null 2>&1; then
  log "Installing the metrics-server add-on"
  aws eks create-addon --cluster-name "$EKS_CLUSTER_NAME" --addon-name metrics-server \
    --configuration-values "$(jq -cn --argjson ns "$PLACEMENT" '{replicas: 1, nodeSelector: $ns,
      tolerations: [{operator: "Exists", effect: "NoSchedule"}, {operator: "Exists", effect: "NoExecute"},
                    {operator: "Exists", effect: "PreferNoSchedule"}]} | if $ns == {} then del(.nodeSelector) else . end')" >/dev/null
  aws eks wait addon-active --cluster-name "$EKS_CLUSTER_NAME" --addon-name metrics-server
fi

if ! $ADDON_INSTALLED; then
  log "Installing the $ADDON add-on ($ADDON_VERSION, about 5 minutes)"
  CONFIG=$(jq -cn --arg exec "$EXEC_ROLE_ARN" --arg tls "$TLS_BUCKET" --arg hp "$HYPERPOD_CLUSTER_ARN" \
    --arg gated "$GATED_ROLE_ARN" --arg alb "$ALB_ROLE_ARN" --arg keda "$KEDA_ROLE_ARN" '{
      executionRoleArn: $exec, tlsCertificateS3Bucket: $tls, hyperpodClusterArn: $hp,
      jumpstartGatedModelDownloadRoleArn: $gated,
      alb: {enabled: true, serviceAccount: {create: true, roleArn: $alb}},
      keda: {enabled: true, auth: {aws: {irsa: {enabled: true, roleArn: $keda}}}}}' | jq -c "$PLACE")
  sleep 10   # new IAM roles take a few seconds to become usable
  aws eks create-addon --cluster-name "$EKS_CLUSTER_NAME" --addon-name "$ADDON" --addon-version "$ADDON_VERSION" \
    --configuration-values "$CONFIG" --resolve-conflicts OVERWRITE >/dev/null
else
  # Keep everything else (module 5 changes logging); only add the controller placement if it's missing
  CURRENT=$(aws eks describe-addon --cluster-name "$EKS_CLUSTER_NAME" --addon-name "$ADDON" \
    --query addon.configurationValues --output text)
  WANTED=$(jq -c "$PLACE" <<<"${CURRENT:-{\}}")
  if [[ "$(jq -S . <<<"$WANTED")" != "$(jq -S . <<<"${CURRENT:-{\}}")" ]]; then
    log "Moving the add-on's controllers to the CPU instance group"
    aws eks update-addon --cluster-name "$EKS_CLUSTER_NAME" --addon-name "$ADDON" \
      --configuration-values "$WANTED" --resolve-conflicts OVERWRITE >/dev/null
    sleep 10
  fi
fi
aws eks wait addon-active --cluster-name "$EKS_CLUSTER_NAME" --addon-name "$ADDON"
kubectl -n "$OPERATOR_NS" wait --for=condition=Available deploy --all --timeout=10m
# The add-on's own values win over the names above if it was installed earlier
CONFIG=$(aws eks describe-addon --cluster-name "$EKS_CLUSTER_NAME" --addon-name "$ADDON" \
  --query addon.configurationValues --output text)
TLS_BUCKET=$(jq -r .tlsCertificateS3Bucket <<<"$CONFIG")
EXEC_ROLE_ARN=$(jq -r .executionRoleArn <<<"$CONFIG")

log "Freeing pod slots on the GPU nodes"
if [[ "$PLACEMENT" != "{}" ]]; then
  # The training operator's add-on has a placement setting for its controller
  TRAINING_ADDON=amazon-sagemaker-hyperpod-training-operator
  if aws eks describe-addon --cluster-name "$EKS_CLUSTER_NAME" --addon-name "$TRAINING_ADDON" >/dev/null 2>&1; then
    CURRENT=$(aws eks describe-addon --cluster-name "$EKS_CLUSTER_NAME" --addon-name "$TRAINING_ADDON" \
      --query addon.configurationValues --output text)
    [[ -z "$CURRENT" || "$CURRENT" == None ]] && CURRENT='{}'
    WANTED=$(jq -c --argjson ns "$PLACEMENT" '.hpTrainingControllerManager.manager.nodeSelector = $ns' <<<"$CURRENT")
    if [[ "$(jq -S . <<<"$WANTED")" != "$(jq -S . <<<"$CURRENT")" ]]; then
      aws eks update-addon --cluster-name "$EKS_CLUSTER_NAME" --addon-name "$TRAINING_ADDON" \
        --configuration-values "$WANTED" --resolve-conflicts OVERWRITE >/dev/null
      sleep 10
      aws eks wait addon-active --cluster-name "$EKS_CLUSTER_NAME" --addon-name "$TRAINING_ADDON"
    fi
    echo "training operator controller: on $CPU_GROUP"
  fi
  # The FSx CSI controller comes from the workshop's Helm release, which nothing reconciles afterwards
  if kubectl -n kube-system get deploy fsx-csi-controller >/dev/null 2>&1; then
    kubectl -n kube-system patch deploy fsx-csi-controller --type merge \
      -p "$(jq -cn --argjson ns "$PLACEMENT" '{spec: {template: {spec: {nodeSelector: $ns}}}}')" >/dev/null
    kubectl -n kube-system rollout status deploy/fsx-csi-controller --timeout=5m >/dev/null
    echo "FSx CSI controller: on $CPU_GROUP"
  fi
fi
# The workshop pre-pulls its training image with a DaemonSet: one pod on every node, needed only
# before its training labs run
if kubectl -n kube-system get ds prepull-esm >/dev/null 2>&1; then
  kubectl -n kube-system delete ds prepull-esm >/dev/null && echo "deleted the workshop's prepull-esm DaemonSet"
fi

log "Writing $ROOT/env.sh"
cat > "$ROOT/env.sh" <<EOF
# Generated by scripts/setup.sh. Source it in every terminal: source $ROOT/env.sh
export REGION=$REGION
export ACCOUNT_ID=$ACCOUNT_ID
export EKS_CLUSTER_NAME=$EKS_CLUSTER_NAME
export HYPERPOD_CLUSTER_NAME=$HYPERPOD_CLUSTER_NAME
export HYPERPOD_CLUSTER_ARN=$HYPERPOD_CLUSTER_ARN
export INSTANCE_TYPE=$INSTANCE_TYPE
export NAMESPACE=default
export TLS_BUCKET=$TLS_BUCKET
export EXECUTION_ROLE_ARN=$EXEC_ROLE_ARN
export MODEL_BUCKET=$MODEL_BUCKET
export ECR_REPOSITORY_URL=$ECR_REPOSITORY_URL
export BUILD_PROJECT=$BUILD_PROJECT
EOF

log "Bash kernel for the notebooks"
# Usually installed already by scripts/install-kernel.sh; rerunning it is quick and harmless
if ! "$HERE/install-kernel.sh"; then
  echo "WARNING: could not install the Bash kernel; run the module pages in the terminal instead" >&2
fi

log "Status"
aws eks describe-addon --cluster-name "$EKS_CLUSTER_NAME" --addon-name "$ADDON" \
  --query 'addon.[addonName,addonVersion,status]' --output text
kubectl get crd inferenceendpointconfigs.inference.sagemaker.aws.amazon.com \
  -o jsonpath='model sources: {.spec.versions[?(@.name=="v1")].schema.openAPIV3Schema.properties.spec.properties.modelSourceConfig.properties.modelSourceType.enum}{"\n"}'
kubectl get nodes -L node.kubernetes.io/instance-type

cat <<EOF

Done. In every terminal: source $ROOT/env.sh
EOF
