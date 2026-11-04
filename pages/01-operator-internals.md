# 1. Inference Operator internals

The HyperPod Inference Operator is a Kubernetes controller. You describe a model deployment as a custom resource, and the operator turns it into pods, a load balancer, a TLS certificate, and (optionally) a SageMaker AI endpoint. Knowing which object does what makes most deployment failures quick to diagnose.

## What the add-on installs

The `amazon-sagemaker-hyperpod-inference` EKS add-on installs everything into the `hyperpod-inference-system` namespace:

| Component | Role |
|---|---|
| Inference operator controller manager | Reconciles the custom resources below. Validating webhook on port 9443, health probes on 8081, metrics on 8443 |
| AWS Load Balancer Controller | Creates the Application Load Balancer for each endpoint (disable with `"alb": {"enabled": false}` if you already run one) |
| KEDA | Pod autoscaling from CloudWatch and Prometheus metrics (disable with `"keda": {"enabled": false}`) |
| Inference Gateway (add-on v2.0.0+) | Optional gateway-based routing |

It depends on four EKS add-ons that must already be installed. The operator's init container checks for them and refuses to start without them:

| Dependency | Why |
|---|---|
| `aws-mountpoint-s3-csi-driver` | Mounts model weights from S3 |
| `aws-fsx-csi-driver` | Mounts model weights from FSx for Lustre |
| `cert-manager` | Issues the endpoint's TLS certificate |
| `metrics-server` | Resource metrics |

Look at what is running on your cluster:

```bash
kubectl get deploy,pods -n hyperpod-inference-system
kubectl get crd | grep inference.sagemaker.aws.amazon.com
kubectl get csidriver
```

### The custom resources

| Kind | You write it? | Purpose |
|---|---|---|
| `InferenceEndpointConfig` | Yes | Deploy any model from S3, FSx, Hugging Face, or a Kubernetes volume with any container image |
| `JumpStartModel` | Yes | Deploy a SageMaker JumpStart model. The operator picks the image and weights |
| `SageMakerEndpointRegistration` | No, generated | Tracks the SageMaker AI endpoint that fronts your deployment |
| `ModelImageCache` (`mic`) | No, generated | Pre-pulls a serving image onto nodes when image caching is on |
| `ModelWeightsCacheConfig` | Usually generated | Pre-stages weights on node-local NVMe when weights caching is on |
| `InferenceGatewayConfig` | Optional | Configures the Inference Gateway (add-on v2.0.0+), an alternative routing layer to the per-endpoint ALB |

All of them serve `v1` (storage version) and `v1alpha1`. Always author `v1`, because `v1alpha1` lacks Hugging Face sources, multiple instance types, and most newer features.

### The IAM identities

The add-on uses four IAM roles, each assumed by a different service account through IRSA:

| Role | Assumed by | Used to |
|---|---|---|
| Execution role (name must start with `SageMakerHyperPodInference`) | Operator controller, and `sagemaker.amazonaws.com` | Create the SageMaker model/endpoint, import certificates into ACM, write certificates to the TLS bucket, describe EKS/EC2/FSx. Managed policy: `AmazonSageMakerHyperPodInferenceAccess` |
| ALB controller role | `hyperpod-inference-system:aws-load-balancer-controller` | Create and manage load balancers |
| KEDA role | `hyperpod-inference-system:keda-operator` | Read CloudWatch metrics and query Amazon Managed Service for Prometheus |
| JumpStart gated-model role | `*:hyperpod-inference-service-account*` | Get presigned URLs for gated JumpStart models |

See which role each service account maps to:

```bash
kubectl get sa -n hyperpod-inference-system \
  -o custom-columns='NAME:.metadata.name,ROLE:.metadata.annotations.eks\.amazonaws\.com/role-arn'
```

> [!WARNING]
> The execution role's trust policy must name the operator's exact service account in its `sub` condition. With the EKS add-on it is `hyperpod-inference-system:hyperpod-inference-controller-manager`; the Helm chart install uses `hyperpod-inference-operator-controller-manager`. Copy it from the output above. A mismatch shows up as `Not authorized to perform sts:AssumeRoleWithWebIdentity` in the operator logs.

## Follow a deployment end to end

When you apply an `InferenceEndpointConfig`, the operator does the following:

```text
InferenceEndpointConfig (your YAML)
  │
  ├─► Deployment ──► Pods
  │                   ├─ init container (downloads weights when prefetchEnabled: true)
  │                   ├─ model server (your worker.image)
  │                   ├─ sidecar-reverse-proxy (nginx: metrics, request limits)
  │                   └─ otel-collector
  ├─► Service <name>-routing-service + Ingress alb-<name> ──► internal Application Load Balancer (HTTPS 443)
  ├─► TLS certificate ──► written to the TLS S3 bucket and imported into ACM
  └─► SageMakerEndpointRegistration ──► SageMaker AI Model, EndpointConfig, Endpoint
                                        (only when spec.endpointName is set)
```

### Lab: deploy and watch every object appear

Create the endpoint that the later modules reuse. It serves TinyLlama from Hugging Face with upstream vLLM on one GPU:

```bash
export ENDPOINT_NAME=tinyllama-dd

cat > tinyllama-dd.yaml <<EOF
apiVersion: inference.sagemaker.aws.amazon.com/v1
kind: InferenceEndpointConfig
metadata:
  name: ${ENDPOINT_NAME}
  namespace: ${NAMESPACE}
spec:
  modelName: tinyllama-1-1b-chat
  endpointName: ${ENDPOINT_NAME}
  instanceType: ${INSTANCE_TYPE}
  invocationEndpoint: v1/chat/completions
  replicas: 1
  modelSourceConfig:
    modelSourceType: huggingface
    prefetchEnabled: true
    huggingFaceModel:
      modelId: TinyLlama/TinyLlama-1.1B-Chat-v1.0
  loadBalancer:
    healthCheckPath: /health
  metrics:
    enabled: true
    modelMetrics:
      port: 8000      # vLLM serves /metrics on its API port (default 8080)
      path: /metrics
  worker:
    image: vllm/vllm-openai:v0.19.1
    modelInvocationPort:
      containerPort: 8000
      name: http
    modelVolumeMount:
      name: model-weights
      mountPath: /opt/ml/model
    resources:
      requests:
        nvidia.com/gpu: "1"
        cpu: "4"
        memory: 16Gi
      limits:
        nvidia.com/gpu: "1"
        cpu: "4"
        memory: 16Gi
    args:
      - "--model"
      - "/opt/ml/model"
      - "--port"
      - "8000"
      - "--served-model-name"
      - "tinyllama"
    environmentVariables:
      - name: VLLM_REQUEST_TIMEOUT
        value: "600"
EOF

kubectl apply -f tinyllama-dd.yaml
```

Three fields deserve attention:

- **`endpointName`**: leave it out and no SageMaker AI endpoint is created. You can still reach the model through the ALB.
- **`invocationEndpoint`**: the path after `http://<host>:<port>/` that the ALB and the SageMaker endpoint forward requests to. It defaults to `invocations`. OpenAI-compatible servers need `v1/chat/completions` (or `v1/completions`).
- **`loadBalancer.healthCheckPath`**: the ALB target-group health check. It defaults to `/ping`, but vLLM answers on `/health`.

Watch the operator work through its states (`DeploymentPending` → `DeploymentInProgress` → `DeploymentComplete`). This takes 5–10 minutes the first time, mostly image pull and ALB provisioning. The loop prints each change of the operator state and the SageMaker endpoint state, and stops when both are done (or on a failure, or after 20 minutes):

```bash
LAST=
for i in $(seq 120); do
  NOW=$(kubectl get inferenceendpointconfig $ENDPOINT_NAME -n $NAMESPACE --no-headers \
    -o custom-columns='STATE:.status.state,SAGEMAKER:.status.endpoints.sagemaker.state')
  [ "$NOW" != "$LAST" ] && echo "$(date +%T)  $NOW" && LAST=$NOW
  case "$NOW" in *Failed*|*DeploymentComplete*CreationCompleted*) break ;; esac
  sleep 10
done
```

List everything the operator created for you:

```bash
kubectl get deploy,pods,svc,ingress,sagemakerendpointregistration -n $NAMESPACE | grep -E "NAME|$ENDPOINT_NAME"
```

Look inside the pod. You'll find containers you never declared:

```bash
POD=$(kubectl get pods -n $NAMESPACE -l app=$ENDPOINT_NAME -o jsonpath='{.items[0].metadata.name}')
echo "init:       $(kubectl get pod $POD -n $NAMESPACE -o jsonpath='{.spec.initContainers[*].name}')"
echo "containers: $(kubectl get pod $POD -n $NAMESPACE -o jsonpath='{.spec.containers[*].name}')"
```

You should see the init container `hf-model-downloader` and three containers: the model server (named after the endpoint), `sidecar-reverse-proxy`, and `otel-collector`.

Check the TLS certificate the operator generated and where it stored it:

```bash
kubectl get inferenceendpointconfig $ENDPOINT_NAME -n $NAMESPACE -o jsonpath='{.status.tlsCertificate}' | jq
aws s3 ls s3://$TLS_BUCKET --recursive | grep -i $ENDPOINT_NAME
```

### Call the model three ways

Each path tests a different layer, which is how you isolate a failure.

<details open>
<summary><b>1. Pod directly</b></summary>

Bypasses the load balancer and SageMaker. If this fails, the problem is the model server itself.

```bash
kubectl port-forward pod/$POD 8000:8000 -n $NAMESPACE >/dev/null & PF=$!
until curl -s -o /dev/null localhost:8000/health; do sleep 1; done
curl -s localhost:8000/v1/chat/completions -H 'Content-Type: application/json' -d '{
  "model": "tinyllama",
  "messages": [{"role": "user", "content": "What is Amazon SageMaker HyperPod?"}],
  "max_tokens": 128
}' | jq -r '.choices[0].message.content'
kill $PF
```

</details>

<details>
<summary><b>2. Application Load Balancer</b></summary>

Tests the Ingress, ALB, and certificate. The ALB is **internal** (reachable only inside the VPC) and listens on HTTPS 443 with a self-signed certificate, unless you configured `tlsConfig.customCertificateConfig`. From outside the VPC, call it from a short-lived pod in the cluster; `-k` skips certificate verification.

```bash
ALB=$(kubectl get ingress alb-$ENDPOINT_NAME -n $NAMESPACE -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo $ALB

kubectl run alb-test --rm -i --restart=Never -n $NAMESPACE \
  --image=public.ecr.aws/docker/library/alpine:3.20 --command -- sh -c "
  apk add -q curl >/dev/null
  curl -sk https://$ALB/v1/chat/completions -H 'Content-Type: application/json' \
    -d '{\"model\":\"tinyllama\",\"messages\":[{\"role\":\"user\",\"content\":\"Give me one fun fact about GPUs.\"}],\"max_tokens\":64}'"
```

The ALB forwards only the invocation path, so other paths such as `/health` return 404 through it.

</details>

<details>
<summary><b>3. SageMaker AI endpoint</b></summary>

Tests the full managed path: IAM-authenticated invocation, SageMaker → ALB → pod. This is what applications usually use.

```bash
aws sagemaker describe-endpoint --endpoint-name $ENDPOINT_NAME --region $REGION \
  --query EndpointStatus --output text

aws sagemaker-runtime invoke-endpoint \
  --endpoint-name $ENDPOINT_NAME \
  --content-type application/json \
  --body '{"model":"tinyllama","messages":[{"role":"user","content":"Explain KV cache in one sentence."}],"max_tokens":64}' \
  --cli-binary-format raw-in-base64-out \
  --region $REGION \
  response.json >/dev/null && jq -r '.choices[0].message.content' response.json
```

</details>


## Reading status and logs

| What | Command |
|---|---|
| Overall state and conditions | `kubectl describe inferenceendpointconfig $ENDPOINT_NAME -n $NAMESPACE` |
| SageMaker endpoint side | `kubectl describe sagemakerendpointregistration $ENDPOINT_NAME -n $NAMESPACE` |
| Model server logs | `kubectl logs $POD -n $NAMESPACE -c $ENDPOINT_NAME` |
| Weight download logs | `kubectl logs $POD -n $NAMESPACE -c hf-model-downloader` |
| SageMaker endpoint logs | `aws logs tail /aws/sagemaker/Endpoints/$ENDPOINT_NAME --region $REGION --since 30m` |
| Operator logs | See below |

```bash
OPERATOR=$(kubectl get deploy -n hyperpod-inference-system -o name | grep controller-manager)
kubectl logs -n hyperpod-inference-system $OPERATOR --tail=100 | grep -i $ENDPOINT_NAME
```

## Troubleshooting reference

| Symptom | Likely cause and fix |
|---|---|
| Operator pod stuck in `Init`; log says `S3 CSI driver not installed` / `FSx CSI driver not installed` / `Missing required CRD: certificaterequests.cert-manager.io` | Install the missing dependency add-on (`aws-mountpoint-s3-csi-driver`, `aws-fsx-csi-driver`, `cert-manager`) |
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | Execution role trust policy: OIDC provider or service account `sub` is wrong |
| Model pod `Pending` with `Insufficient nvidia.com/gpu` | No free GPUs of `instanceType`. Check `kubectl describe node`; under task governance, check `kubectl get workloads` (module 7) |
| Init container `Init:CrashLoopBackOff` | Weight download failed: Hugging Face token or egress, or S3 permissions (module 4) |
| Model server restarts during load | Out of GPU memory, or slow startup killed by probes (module 5) |
| ALB targets unhealthy | `loadBalancer.healthCheckPath` doesn't match the server, for example `/ping` on vLLM |
| SageMaker endpoint `Failed`: *did not pass the ping health check*; endpoint logs show `Error downloading CA certificate: Connect timeout on endpoint URL` | The SageMaker endpoint runs in the **EKS cluster subnets** and must reach S3 to fetch its CA certificate. Associate the S3 gateway VPC endpoint with those subnets' route tables (the workshop Terraform does this), then delete and re-create the endpoint |
| `...sufficient permissions for creating an endpoint variant within a VPC` | Add `ec2:CreateNetworkInterfacePermission` and `ec2:DeleteNetworkInterfacePermission` to the execution role |
| Long generations cut off at 60 s | Raise `loadBalancer.idleTimeoutSeconds` (1–4000) |
| CRDs missing after reinstalling the add-on | Leftover custom resources with finalizers. Delete endpoints **before** removing the add-on |
| Imported certificate left in ACM after you delete an endpoint; operator logs show `failed to delete ACM cert ... ResourceInUseException` | The operator tried to delete the certificate while the ALB still used it, and doesn't retry. Once the ALB is gone, delete it with `aws acm delete-certificate`. It's tagged `CreatedBy=HyperPodInference`, and its domain is the old ALB hostname |

> [!NOTE]
> Keep `tinyllama-dd` running. Modules 2 and 3 use it. To remove it later, run `kubectl delete inferenceendpointconfig tinyllama-dd -n $NAMESPACE`, which also deletes the SageMaker endpoint and the ALB.
