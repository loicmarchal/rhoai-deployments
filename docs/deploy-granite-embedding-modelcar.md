# Deploying Granite Embedding on ROSA HCP via ModelCar

This guide documents the end-to-end deployment of the **IBM Granite Embedding English R2** model on a ROSA HCP (Hosted Control Plane) cluster using RHOAI 3.4 and the KServe ModelCar approach.

ModelCar packages the model as an OCI container image, eliminating the need for PersistentVolumeClaims and HuggingFace download jobs. The model is pulled directly from a container registry and mounted into the serving pod.

## Prerequisites

- ROSA HCP cluster with admin access
- `oc` CLI logged in as cluster-admin
- RHOAI 3.4 installed with KServe component in `Managed` state
- Brew registry credentials available in `~/.docker/config.json`
- Kyverno installed with brew pull secret sync policies

## Cluster Setup (optional)

> **Optional:** If your cluster already has a brew pull secret, Kyverno, and the secret sync / imagePullSecret injection policies configured, jump directly to [Model Deployment](#model-deployment).

### 1. Create the Brew Pull Secret

Create the pull secret in `openshift-config` from the local Docker config file:

```bash
oc create secret generic pull-secret-brew \
  --from-file=.dockerconfigjson=$HOME/.docker/config.json \
  --type=kubernetes.io/dockerconfigjson \
  -n openshift-config
```

### 2. Install Kyverno

Install Kyverno using `oc apply` with server-side apply to handle large CRDs:

```bash
oc create namespace kyverno
oc apply --server-side -f https://github.com/kyverno/kyverno/releases/latest/download/install.yaml
```

Wait for all controllers to be available:

```bash
oc wait deployment kyverno-admission-controller -n kyverno --for=condition=available --timeout=300s
oc wait deployment kyverno-background-controller -n kyverno --for=condition=available --timeout=300s
oc wait deployment kyverno-cleanup-controller -n kyverno --for=condition=available --timeout=300s
oc wait deployment kyverno-reports-controller -n kyverno --for=condition=available --timeout=300s
```

> **Note:** The standard `oc apply` (client-side) fails for the `clusterpolicies.kyverno.io` and `policies.kyverno.io` CRDs because the `kubectl.kubernetes.io/last-applied-configuration` annotation exceeds the 262,144-byte limit. Using `--server-side` avoids this issue.

### 3. Grant Kyverno RBAC for Secret Management

Kyverno's service accounts need explicit permissions to create and sync secrets across namespaces:

```bash
cat <<'EOF' | oc apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kyverno:secrets-management
rules:
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kyverno:secrets-management
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: kyverno:secrets-management
subjects:
- kind: ServiceAccount
  name: kyverno-admission-controller
  namespace: kyverno
- kind: ServiceAccount
  name: kyverno-background-controller
  namespace: kyverno
EOF
```

Without this step, the `sync-brew-pull-secret` ClusterPolicy will be rejected by the Kyverno admission webhook.

### 4. Create Kyverno ClusterPolicies

**Policy 1 — Sync brew pull secret to all namespaces:**

```bash
cat <<'EOF' | oc apply -f -
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: sync-brew-pull-secret
spec:
  generateExisting: true
  rules:
  - name: sync-secret
    match:
      any:
      - resources:
          kinds:
          - Namespace
    exclude:
      any:
      - resources:
          namespaces:
          - kube-system
          - kube-public
          - kube-node-lease
    generate:
      synchronize: true
      apiVersion: v1
      kind: Secret
      name: pull-secret-brew
      namespace: "{{request.object.metadata.name}}"
      clone:
        namespace: openshift-config
        name: pull-secret-brew
EOF
```

**Policy 2 — Inject imagePullSecrets into all pods:**

```bash
cat <<'EOF' | oc apply -f -
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: add-brew-imagepullsecret
spec:
  rules:
  - name: add-imagepullsecret
    match:
      any:
      - resources:
          kinds:
          - Pod
    mutate:
      patchStrategicMerge:
        spec:
          imagePullSecrets:
          - name: pull-secret-brew
EOF
```

These two policies are required on ROSA HCP because the platform-managed global pull secret is automatically reconciled and manual additions get reverted.

## Model Deployment

### 1. Create and Label the Namespace

```bash
oc create namespace llm
oc label namespace llm opendatahub.io/dashboard=true modelmesh-enabled=false --overwrite
```

The `opendatahub.io/dashboard=true` label makes the namespace visible in the RHOAI dashboard. The `modelmesh-enabled=false` label ensures KServe single-model serving mode is used instead of ModelMesh.

### 2. Resolve the vLLM CPU Runtime Image

The RHOAI operator ships runtime templates with pinned image references. Extract the vLLM CPU image from the operator template:

```bash
VLLM_IMAGE=$(oc get template vllm-cpu-x86-runtime-template -n redhat-ods-applications \
    -o jsonpath='{.objects[0].spec.containers[0].image}')
echo "vLLM CPU image: $VLLM_IMAGE"
```

If the template is not available, fall back to:

```bash
VLLM_IMAGE="registry.redhat.io/rhaiis/vllm-cpu-rhel9:latest"
```

For RHOAI 3.4 EA, the resolved image was:

```
registry.redhat.io/rhaii-early-access/vllm-cpu-rhel9@sha256:7e227326e7975818040fde0cfcaf2683fe4050558f36badcb826a9085ada7fca
```

### 3. Create the ServingRuntime

```bash
cat <<EOF | oc apply -f -
apiVersion: serving.kserve.io/v1alpha1
kind: ServingRuntime
metadata:
  name: vllm-granite-embedding
  namespace: llm
  labels:
    shepard.io/model-role: embedding
spec:
  annotations:
    prometheus.io/path: /metrics
    prometheus.io/port: "8000"
  containers:
    - name: kserve-container
      image: ${VLLM_IMAGE}
      args:
        - --model
        - /mnt/models
        - --served-model-name
        - "ibm-granite/granite-embedding-english-r2"
        - --port
        - "8000"
      env:
        - name: HF_HUB_CACHE
          value: /tmp
        - name: VLLM_CACHE_ROOT
          value: /tmp/vllm
        - name: HOME
          value: /tmp
        - name: VLLM_TARGET_DEVICE
          value: "cpu"
      ports:
        - containerPort: 8000
          protocol: TCP
      resources:
        requests:
          cpu: "1"
          memory: "4Gi"
        limits:
          cpu: "4"
          memory: "8Gi"
      volumeMounts:
        - name: shm
          mountPath: /dev/shm
  multiModel: false
  supportedModelFormats:
    - name: vLLM
      version: "1"
      autoSelect: true
  volumes:
    - name: shm
      emptyDir:
        medium: Memory
        sizeLimit: 2Gi
EOF
```

**Resource notes:**

| Field | Value | Notes |
|-------|-------|-------|
| `cpu` request | 1 | Minimum to schedule on a small cluster. Original config uses 4. |
| `cpu` limit | 4 | Allows bursting when CPU is available. |
| `memory` request | 4Gi | Original config uses 8Gi. |
| `memory` limit | 8Gi | Original config uses 16Gi. |

The `VLLM_TARGET_DEVICE=cpu` environment variable tells vLLM to use CPU inference instead of looking for GPUs.

### 4. Create the InferenceService

Wait for the KServe webhook to be ready before creating the InferenceService:

```bash
for i in {1..60}; do
    ENDPOINTS=$(oc get endpoints kserve-webhook-server-service -n redhat-ods-applications \
        -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || echo "")
    if [[ -n "$ENDPOINTS" ]]; then
        echo "KServe webhook is ready"
        break
    fi
    sleep 5
done
```

Create the InferenceService with the modelcar OCI storage URI:

```bash
cat <<'EOF' | oc apply -f -
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: granite-embedding
  namespace: llm
  labels:
    opendatahub.io/dashboard: "true"
    shepard.io/model-role: embedding
  annotations:
    openshift.io/display-name: "Granite Embedding English R2"
    serving.kserve.io/deploymentMode: RawDeployment
spec:
  predictor:
    model:
      modelFormat:
        name: vLLM
        version: "1"
      runtime: vllm-granite-embedding
      storageUri: oci://quay.io/redhat-ai-services/modelcar-catalog@sha256:359cdd40abee4f767002363dfb102e159c5653ba0b387db93142bd22544735cb
    minReplicas: 1
    maxReplicas: 1
    template:
      metadata:
        labels:
          app: granite-embedding
EOF
```

Key configuration choices:

- **`serving.kserve.io/deploymentMode: RawDeployment`** — Uses a standard Kubernetes Deployment instead of Knative Serving. Required on ROSA where Serverless/Knative is typically not available.
- **`storageUri: oci://...`** — The `oci://` prefix tells KServe to use the ModelCar mechanism: the model is fetched as an OCI image and mounted at `/mnt/models` via an init container.
- **`@sha256:...`** — Uses a digest reference for reproducibility rather than a mutable tag.

### 5. Create the ServiceAccount Token Secret

```bash
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: granite-embedding-sa
  namespace: llm
  labels:
    shepard.io/model-role: embedding
  annotations:
    kubernetes.io/service-account.name: default
type: kubernetes.io/service-account-token
EOF
```

### 6. Wait for the Model to Be Ready

```bash
oc wait pod -l serving.kserve.io/inferenceservice=granite-embedding \
  -n llm --for=condition=ready --timeout=600s
```

Verify the InferenceService is Ready:

```bash
oc get inferenceservice -n llm
```

Expected output:

```
NAME                URL                                                        READY
granite-embedding   http://granite-embedding-predictor.llm.svc.cluster.local   True
```

## Verification

### List Available Models

```bash
oc exec deploy/granite-embedding-predictor -n llm -c kserve-container -- \
  curl -s http://localhost:8000/v1/models | jq .
```

### Test Embedding Generation

```bash
oc exec deploy/granite-embedding-predictor -n llm -c kserve-container -- \
  curl -s http://localhost:8000/v1/embeddings \
    -H "Content-Type: application/json" \
    -d '{"model": "ibm-granite/granite-embedding-english-r2", "input": "What is Red Hat OpenShift AI?"}'
```

Expected response (truncated):

```json
{
  "model": "ibm-granite/granite-embedding-english-r2",
  "usage": {
    "prompt_tokens": 6,
    "total_tokens": 6
  },
  "embedding_length": 768
}
```

The model produces 768-dimensional embeddings with a maximum context length of 8192 tokens.

### Access from Other Pods

From any pod in the cluster, the model is reachable at:

```
http://granite-embedding-predictor.llm.svc.cluster.local:8000/v1/embeddings
```

### Access Locally via Port Forward

To query the model directly from your machine, forward the service port:

```bash
oc port-forward -n llm svc/granite-embedding-predictor 8000:8000
```

Then, in a separate terminal:

```bash
curl -s http://localhost:8000/v1/embeddings \
  -H "Content-Type: application/json" \
  -d '{"model": "ibm-granite/granite-embedding-english-r2", "input": "What is Red Hat OpenShift AI?"}' | jq .
```

## Resource Optimization for Small Clusters

On a small cluster (e.g. 2-node ROSA HCP with 2 x 3,500m CPU), if the deployment exceeds available capacity, the following changes can be applied to free resources:

### Disable Non-Essential DSC Components

```bash
oc patch datasciencecluster default-dsc --type merge -p '{
  "spec": {
    "components": {
      "workbenches": {"managementState": "Removed"},
      "aipipelines": {"managementState": "Removed"},
      "mlflowoperator": {"managementState": "Removed"},
      "modelregistry": {"managementState": "Removed"},
      "ray": {"managementState": "Removed"},
      "llamastackoperator": {"managementState": "Removed"},
      "feastoperator": {"managementState": "Removed"},
      "trustyai": {"managementState": "Removed"},
      "dashboard": {"managementState": "Removed"}
    }
  }
}'
```

This keeps only `kserve` as the active component, which is the minimum required for model serving.

### Scale Down the RHOAI Operator

```bash
oc scale deployment rhods-operator -n redhat-ods-operator --replicas=1
```

The operator defaults to 3 replicas (1,500m CPU total). A single replica is sufficient for non-production environments.

### Scale Down Dashboard Redirect

```bash
oc scale deployment dashboard-redirect -n redhat-ods-applications --replicas=1
```

### Resource Savings Summary

| Action | CPU Freed |
|--------|-----------|
| Remove 9 DSC components | ~1,230m |
| Scale operator 3 → 1 | ~1,000m |
| Scale dashboard-redirect 2 → 1 | ~50m |
| Reduce model CPU request 4 → 1 | ~3,000m (on scheduler) |
| **Total** | **~5,280m** |

## Model Configuration Reference

| Parameter | Value |
|-----------|-------|
| Model ID | `ibm-granite/granite-embedding-english-r2` |
| ModelCar image | `quay.io/redhat-ai-services/modelcar-catalog@sha256:359cdd40abee4f767002363dfb102e159c5653ba0b387db93142bd22544735cb` |
| Runtime | vLLM CPU |
| Embedding dimensions | 768 |
| Max context length | 8192 tokens |
| GPU required | No |
| API | OpenAI-compatible (`/v1/embeddings`) |
| Deployment mode | RawDeployment |
| Namespace | `llm` |
