# 1. Inference Operator internals

The HyperPod Inference Operator is a Kubernetes operator: a controller that watches custom resources (object types an add-on adds to Kubernetes) and creates the objects they describe. You describe a model deployment in one custom resource, and the operator turns it into pods, a load balancer, a TLS certificate, and, optionally, a SageMaker AI endpoint (a managed SageMaker HTTPS endpoint that applications call with IAM credentials).

In this lab you look at what the add-on installs, deploy one model and watch every object the operator creates, and call the model three ways. Knowing which object does what is how you diagnose most deployment failures.

Before you start, finish [0. Set up your environment](00-setup.md). If you work in a new terminal, load the variables first with `source ~/hyperpod-inference-dive-deep/env.sh`. This lab uses one of your two GPUs.

## What the add-on installs

The `amazon-sagemaker-hyperpod-inference` EKS add-on installs the operator and its helpers into the `hyperpod-inference-system` namespace. The two tables below are for reference; the commands after them show the same things on your cluster.

What the add-on runs:

| Component | Role |
|---|---|
| Inference operator controller manager | Reconciles the custom resources below. Validating webhook on port 9443, health probes on 8081, metrics on 8443 |
| AWS Load Balancer Controller | Creates an Application Load Balancer (ALB, an AWS layer-7 HTTP/HTTPS load balancer) for each endpoint. Disable it with `"alb": {"enabled": false}` in the add-on configuration if you already run one |
| KEDA (Kubernetes event-driven autoscaling) | Scales pods on CloudWatch and Prometheus metrics (lab 2). Disable it with `"keda": {"enabled": false}` |
| Inference Gateway (add-on v2.0.0 and later) | Optional gateway-based routing, an alternative to the per-endpoint ALB |

The add-on needs four other EKS add-ons. The workshop cluster already has them. The operator's init container (a container that runs before the main one) checks for them, and the operator doesn't start without them:

| Dependency | Why |
|---|---|
| `aws-mountpoint-s3-csi-driver` | Mounts model weights from S3 |
| `aws-fsx-csi-driver` | Mounts model weights from FSx for Lustre |
| `cert-manager` | Issues the endpoint's TLS certificate |
| `metrics-server` | CPU and memory metrics for pods (`scripts/setup.sh` installs it if missing) |

The commands below list the add-on's deployments and pods, the inference custom resource definitions (CRDs, the schemas of the custom resources), and the CSI drivers (storage plugins) that mount model weights.

```bash
kubectl get deploy,pods -n hyperpod-inference-system
kubectl get crd | grep inference.sagemaker.aws.amazon.com
kubectl get csidriver
```

Expected:

- The deployments include the operator's `hyperpod-inference-controller-manager`, the `aws-load-balancer-controller`, and the KEDA deployments, all with every replica ready (for example `1/1`), and their pods `Running`.
- The CRD list includes `inferenceendpointconfigs`, `jumpstartmodels`, and `sagemakerendpointregistrations`, each ending in `.inference.sagemaker.aws.amazon.com`.
- The CSI drivers include `s3.csi.aws.com` and `fsx.csi.aws.com`.

### The custom resources

For reference; nothing to run. These are the custom resources the operator acts on. You write the first two; the operator creates the others.

| Kind | You write it? | Purpose |
|---|---|---|
| `InferenceEndpointConfig` | Yes | Deploy any model from S3, FSx for Lustre, Hugging Face, or a Kubernetes volume, with any container image. This lab uses it |
| `JumpStartModel` | Yes | Deploy a SageMaker JumpStart model (a model from the SageMaker catalog). The operator picks the image and weights. Lab 4 uses it |
| `SageMakerEndpointRegistration` | No, generated | Tracks the SageMaker AI endpoint that fronts your deployment |
| `ModelImageCache` (short name `mic`) | No, generated | Pre-pulls a serving image onto nodes when image caching is on (labs 4 and 6) |
| `ModelWeightsCacheConfig` | Usually generated | Copies weights in advance to the node's local NVMe disk when weights caching is on (labs 4 and 6) |
| `InferenceGatewayConfig` | Optional | Configures the Inference Gateway (add-on v2.0.0 and later) |

Each kind has two API versions, `v1` and `v1alpha1`. Always write `v1` (`apiVersion: inference.sagemaker.aws.amazon.com/v1`): `v1alpha1` lacks Hugging Face sources, multiple instance types, and most newer features.

### The IAM identities

For reference: the add-on uses four IAM roles. `scripts/setup.sh` created them for you. Each role is assumed by a Kubernetes service account through IRSA (IAM roles for service accounts, which maps a service account to an IAM role).

| Role | Assumed by | Used to |
|---|---|---|
| Execution role (name must start with `SageMakerHyperPodInference`) | Operator controller, and `sagemaker.amazonaws.com` | Create the SageMaker model/endpoint, import certificates into ACM, write certificates to the TLS bucket, describe EKS/EC2/FSx. Managed policy: `AmazonSageMakerHyperPodInferenceAccess` |
| ALB controller role | `hyperpod-inference-system:aws-load-balancer-controller` | Create and manage load balancers |
| KEDA role | `hyperpod-inference-system:keda-operator` | Read CloudWatch metrics and query Amazon Managed Service for Prometheus |
| JumpStart gated-model role | `*:hyperpod-inference-service-account*` | Get presigned URLs for gated JumpStart models |

The command below lists the service accounts in the add-on's namespace and the IAM role each one maps to.

```bash
kubectl get sa -n hyperpod-inference-system \
  -o custom-columns='NAME:.metadata.name,ROLE:.metadata.annotations.eks\.amazonaws\.com/role-arn'
```

Expected: `hyperpod-inference-controller-manager` maps to a role named `SageMakerHyperPodInference-...`, `aws-load-balancer-controller` to `hyperpod-dd-...-alb`, and `keda-operator` to `hyperpod-dd-...-keda`. Service accounts that don't call AWS show `<none>`.

> [!WARNING]
> For reference, if you create the execution role yourself (`scripts/setup.sh` already did it here): its trust policy must name the operator's exact service account in its `sub` condition. With the EKS add-on that's `hyperpod-inference-system:hyperpod-inference-controller-manager`; a Helm chart install uses `hyperpod-inference-operator-controller-manager`. Take the name from the output above. A mismatch shows up as `Not authorized to perform sts:AssumeRoleWithWebIdentity` in the operator logs.

## Follow a deployment end to end

When you apply an `InferenceEndpointConfig`, the operator creates the objects below. For reference; you create them in the next section and then list them.

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

Here you create `tinyllama-dd`, the endpoint that labs 2 and 3 reuse. It serves the small TinyLlama chat model, downloaded from Hugging Face, with vLLM (an open-source LLM serving engine with an OpenAI-compatible API) on one GPU.

The command below writes the `InferenceEndpointConfig` to `tinyllama-dd.yaml` in the current directory and applies it.

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

Expected: `inferenceendpointconfig.inference.sagemaker.aws.amazon.com/tinyllama-dd created`. The operator starts working in the background.

Three fields in the YAML matter most:

- **`endpointName`**: the name of the SageMaker AI endpoint to create. Leave it out and no SageMaker AI endpoint is created; you can still reach the model through the ALB.
- **`invocationEndpoint`**: the path on the model server (after `http://<host>:<port>/`) that the ALB and the SageMaker AI endpoint forward requests to. It defaults to `invocations`. OpenAI-compatible servers such as vLLM need `v1/chat/completions` (or `v1/completions`).
- **`loadBalancer.healthCheckPath`**: the path the ALB calls to check that a pod is healthy. It defaults to `/ping`, but vLLM answers on `/health`.

The `metrics.modelMetrics.port: 8000` line overrides the operator's default metrics port (8080), because vLLM serves `/metrics` on its API port, 8000.


Next, watch the operator work through its states: `DeploymentPending` → `DeploymentInProgress` → `DeploymentComplete`. The command below checks every 10 seconds and prints a line each time the operator state (first column) or the SageMaker AI endpoint state (second column) changes. It stops when both are done, on a failure, or after 20 minutes.

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

Expected (5–10 minutes the first time, mostly the image pull and the ALB setup): the last line shows `DeploymentComplete` and `CreationCompleted`. While the SageMaker AI endpoint is still being created, the second column may show `<none>` or an in-progress state. If a line shows `Failed`, see [Reading status and logs](#reading-status-and-logs) and the troubleshooting table at the end of this page.

The command below lists every object the operator created for the endpoint.

```bash
kubectl get deploy,pods,svc,ingress,sagemakerendpointregistration -n $NAMESPACE | grep -E "NAME|$ENDPOINT_NAME"
```

Expected, matching the diagram above: a deployment with `1/1` ready, one `Running` pod, the `tinyllama-dd-routing-service` service, the `alb-tinyllama-dd` ingress with an ALB hostname in its `ADDRESS` column, and a `tinyllama-dd` SageMaker endpoint registration.

Now look inside the pod. The operator adds containers you never declared. The command below saves the pod name in `POD` (the next steps use it) and prints the pod's init containers and containers.

```bash
POD=$(kubectl get pods -n $NAMESPACE -l app=$ENDPOINT_NAME -o jsonpath='{.items[0].metadata.name}')
echo "init:       $(kubectl get pod $POD -n $NAMESPACE -o jsonpath='{.spec.initContainers[*].name}')"
echo "containers: $(kubectl get pod $POD -n $NAMESPACE -o jsonpath='{.spec.containers[*].name}')"
```

Expected: the init container `hf-model-downloader` (it downloaded the weights from Hugging Face) and three containers: the model server (named `tinyllama-dd`, after the endpoint), `sidecar-reverse-proxy` (an nginx proxy for metrics and request limits, lab 3), and `otel-collector` (sends metrics, lab 3).

The operator also generated a TLS certificate (the certificate the ALB presents for HTTPS). The command below prints the certificate details from the endpoint's status, then lists the files the operator stored in the TLS S3 bucket for this endpoint.

```bash
kubectl get inferenceendpointconfig $ENDPOINT_NAME -n $NAMESPACE -o jsonpath='{.status.tlsCertificate}' | jq
aws s3 ls s3://$TLS_BUCKET --recursive | grep -i $ENDPOINT_NAME
```

Expected: a JSON object describing the certificate, then one or more certificate files in the bucket whose paths contain `tinyllama-dd`.

### Call the model three ways

Now send a chat request to the model through each of the three layers. Each path tests a different layer, so when one fails and the one before it works, you know where the problem is. Run all three tabs, in order.

<details open>
<summary><b>1. Pod directly</b></summary>

This path skips the ALB and SageMaker. If it fails, the problem is the model server itself.

The command below forwards local port 8000 to the pod in the background, waits until the server answers, sends a chat request, prints the answer, and stops the port forward.

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

Expected: a few sentences about SageMaker HyperPod, generated by TinyLlama (a small model, so the content may be inaccurate).

</details>

<details>
<summary><b>2. Application Load Balancer</b></summary>

This path tests the Ingress (the Kubernetes object that defines the ALB), the ALB, and the certificate.

The ALB is **internal**: you can reach it only from inside the cluster's VPC. It listens on HTTPS port 443 with a self-signed certificate (unless you set `tlsConfig.customCertificateConfig`). So the command below prints the ALB hostname, then sends the request from a short-lived pod in the cluster, which is deleted afterward. `curl -k` skips certificate verification, because the certificate is self-signed.

```bash
ALB=$(kubectl get ingress alb-$ENDPOINT_NAME -n $NAMESPACE -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo $ALB

kubectl run alb-test --rm -i --restart=Never -n $NAMESPACE \
  --image=public.ecr.aws/docker/library/alpine:3.20 --command -- sh -c "
  apk add -q curl >/dev/null
  curl -sk https://$ALB/v1/chat/completions -H 'Content-Type: application/json' \
    -d '{\"model\":\"tinyllama\",\"messages\":[{\"role\":\"user\",\"content\":\"Give me one fun fact about GPUs.\"}],\"max_tokens\":64}'"
```

Expected: the ALB hostname (ending in `elb.amazonaws.com`), then a JSON chat completion with a fun fact in `choices[0].message.content`, followed by a line such as `pod "alb-test" deleted`. The first run takes up to a minute while the pod pulls the image and installs `curl`.

The ALB forwards only the invocation path (`invocationEndpoint`), so other paths such as `/health` return 404 through it.

</details>

<details>
<summary><b>3. SageMaker AI endpoint</b></summary>

This path tests the full managed route: the AWS CLI signs the request with your IAM credentials, and SageMaker forwards it to the ALB, which forwards it to the pod. Applications usually call the model this way.

The command below prints the SageMaker AI endpoint status, then invokes the endpoint, saves the response to `response.json`, and prints the answer.

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

Expected: `InService`, then a one-sentence explanation of KV cache.

</details>


## Reading status and logs

When a deployment doesn't reach `DeploymentComplete`, or a call fails, these commands show why. For reference; run them when you need them. They use the `ENDPOINT_NAME` and `POD` variables from the steps above.

| What | Command |
|---|---|
| Overall state and conditions | `kubectl describe inferenceendpointconfig $ENDPOINT_NAME -n $NAMESPACE` |
| SageMaker endpoint side | `kubectl describe sagemakerendpointregistration $ENDPOINT_NAME -n $NAMESPACE` |
| Model server logs | `kubectl logs $POD -n $NAMESPACE -c $ENDPOINT_NAME` |
| Weight download logs | `kubectl logs $POD -n $NAMESPACE -c hf-model-downloader` |
| SageMaker endpoint logs | `aws logs tail /aws/sagemaker/Endpoints/$ENDPOINT_NAME --region $REGION --since 30m` |
| Operator logs | The command below |

The command below finds the operator's deployment and prints its recent log lines that mention your endpoint.

```bash
OPERATOR=$(kubectl get deploy -n hyperpod-inference-system -o name | grep controller-manager)
kubectl logs -n hyperpod-inference-system $OPERATOR --tail=100 | grep -i $ENDPOINT_NAME
```

Expected: log lines from the operator's reconcile loop (the loop that compares the custom resource with what exists and fixes the difference) that mention `tinyllama-dd`. If it prints nothing, none of the last 100 log lines mention the endpoint, which is normal once it has been stable for a while.

## Troubleshooting reference

For reference; nothing to run. Common symptoms, their likely cause, and the fix.

| Symptom | Likely cause and fix |
|---|---|
| Operator pod stuck in `Init`; log says `S3 CSI driver not installed` / `FSx CSI driver not installed` / `Missing required CRD: certificaterequests.cert-manager.io` | Install the missing dependency add-on (`aws-mountpoint-s3-csi-driver`, `aws-fsx-csi-driver`, `cert-manager`) |
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | Execution role trust policy: OIDC provider or service account `sub` is wrong |
| Model pod `Pending` with `Insufficient nvidia.com/gpu` | No free GPUs of `instanceType`. Check `kubectl describe node`; under task governance, check `kubectl get workloads` (lab 7) |
| Init container `Init:CrashLoopBackOff` | Weight download failed: Hugging Face token or egress, or S3 permissions (lab 4) |
| Model server restarts during load | Out of GPU memory, or slow startup killed by probes (lab 5) |
| ALB targets unhealthy | `loadBalancer.healthCheckPath` doesn't match the server, for example `/ping` on vLLM |
| SageMaker endpoint `Failed`: *did not pass the ping health check*; endpoint logs show `Error downloading CA certificate: Connect timeout on endpoint URL` | The SageMaker endpoint runs in the **EKS cluster subnets** and must reach S3 to fetch its CA certificate. Associate the S3 gateway VPC endpoint with those subnets' route tables (the workshop Terraform does this), then delete and re-create the endpoint |
| `...sufficient permissions for creating an endpoint variant within a VPC` | Add `ec2:CreateNetworkInterfacePermission` and `ec2:DeleteNetworkInterfacePermission` to the execution role |
| Long generations cut off at 60 s | Raise `loadBalancer.idleTimeoutSeconds` (1–4000) |
| CRDs missing after reinstalling the add-on | Leftover custom resources with finalizers. Delete endpoints **before** removing the add-on |
| Imported certificate left in ACM after you delete an endpoint; operator logs show `failed to delete ACM cert ... ResourceInUseException` | The operator tried to delete the certificate while the ALB still used it, and doesn't retry. Once the ALB is gone, delete it with `aws acm delete-certificate`. It's tagged `CreatedBy=HyperPodInference`, and its domain is the old ALB hostname |

> [!NOTE]
> Keep `tinyllama-dd` running: labs 2 and 3 use it, so don't delete it now. When you no longer need it, run `kubectl delete inferenceendpointconfig tinyllama-dd -n $NAMESPACE`, which also deletes its SageMaker AI endpoint and ALB.
