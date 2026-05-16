# Deploying Granite 3.3 2B Instruct on ROSA HCP (CPU-Only, Minimal Resources)

This guide documents the end-to-end deployment of the **IBM Granite 3.3 2B Instruct** model on a ROSA HCP (Hosted Control Plane) cluster using RHOAI 3.4 and KServe, targeting small clusters with limited CPU headroom (e.g. 2x m5.xlarge).

Unlike the ModelCar approach, this deployment downloads the model from HuggingFace into a PersistentVolumeClaim (PVC). The model runs on CPU using a minimal vLLM configuration with reduced context length and memory footprint.

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

### 2. Create the PVC for Model Storage

Create a PersistentVolumeClaim to store the downloaded model weights:

```bash
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: granite-3-3-2b-instruct
  namespace: llm
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
  storageClassName: gp3-csi
EOF
```

### 3. Download the Model from HuggingFace

Create a Job that downloads the model into the PVC:

```bash
cat <<'EOF' | oc apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: granite-3-3-2b-instruct-download
  namespace: llm
spec:
  template:
    spec:
      containers:
      - name: download
        image: registry.access.redhat.com/ubi9/python-311:latest
        command:
          - /bin/bash
          - -c
          - |
            pip install -q huggingface_hub
            hf download "$MODEL_ID" --local-dir /mnt/models
        env:
        - name: MODEL_ID
          value: "ibm-granite/granite-3.3-2b-instruct"
        - name: HF_TOKEN
          valueFrom:
            secretKeyRef:
              name: huggingface-token
              key: token
              optional: true
        - name: HUGGING_FACE_HUB_TOKEN
          valueFrom:
            secretKeyRef:
              name: huggingface-token
              key: token
              optional: true
        - name: HF_HUB_DISABLE_XET
          value: "1"
        volumeMounts:
        - name: model-storage
          mountPath: /mnt/models
        resources:
          requests:
            cpu: "500m"
            memory: "1Gi"
          limits:
            cpu: "1"
            memory: "2Gi"
      volumes:
      - name: model-storage
        persistentVolumeClaim:
          claimName: granite-3-3-2b-instruct
      restartPolicy: OnFailure
  backoffLimit: 3
EOF
```

Wait for the download to complete:

```bash
oc wait --for=condition=complete job/granite-3-3-2b-instruct-download \
  -n llm --timeout=600s
```

> **Note:** The download takes a few minutes depending on network speed. Monitor progress with `oc logs -f job/granite-3-3-2b-instruct-download -n llm`.

### 4. Create the ServingRuntime

```bash
cat <<'EOF' | oc apply -f -
apiVersion: serving.kserve.io/v1alpha1
kind: ServingRuntime
metadata:
  name: vllm-granite-3-3-2b-instruct
  namespace: llm
spec:
  annotations:
    prometheus.io/path: /metrics
    prometheus.io/port: "8000"
  containers:
    - name: kserve-container
      image: quay.io/pierdipi/vllm-cpu:latest
      args:
        - --model
        - /mnt/models
        - --served-model-name
        - "ibm-granite/granite-3.3-2b-instruct"
        - --port
        - "8000"
        - --max-model-len
        - "4096"
      env:
        - name: HF_HUB_CACHE
          value: /tmp
        - name: VLLM_CACHE_ROOT
          value: /tmp/vllm
        - name: HOME
          value: /tmp
        - name: VLLM_CPU_KVCACHE_SPACE
          value: "1"
        - name: TORCH_COMPILE_DISABLE
          value: "1"
      ports:
        - containerPort: 8000
          protocol: TCP
      resources:
        requests:
          cpu: "500m"
          memory: "6Gi"
        limits:
          cpu: "2"
          memory: "7Gi"
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
| `cpu` request | 500m | Minimal footprint for constrained clusters |
| `cpu` limit | 2 | Allows bursting when CPU is available |
| `memory` request | 6Gi | Minimum for the 2B parameter model |
| `memory` limit | 7Gi | Tight cap to leave room for other workloads |

**Environment variables:**

| Variable | Value | Purpose |
|----------|-------|---------|
| `VLLM_CPU_KVCACHE_SPACE` | 1 | Limits KV cache to 1 GB to reduce memory usage |
| `TORCH_COMPILE_DISABLE` | 1 | Disables Torch compilation to reduce startup time and memory |

The `--max-model-len 4096` flag limits the context window (the model supports up to 128K tokens natively) to keep memory consumption low on small clusters.

### 5. Create the InferenceService

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

Create the InferenceService with PVC storage:

```bash
cat <<'EOF' | oc apply -f -
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: granite-3-3-2b-instruct
  namespace: llm
  labels:
    opendatahub.io/dashboard: "true"
  annotations:
    openshift.io/display-name: "Granite 3.3 2B Instruct (CPU)"
    serving.kserve.io/deploymentMode: RawDeployment
spec:
  predictor:
    model:
      modelFormat:
        name: vLLM
        version: "1"
      runtime: vllm-granite-3-3-2b-instruct
      storageUri: pvc://granite-3-3-2b-instruct
    minReplicas: 0
    maxReplicas: 1
    template:
      metadata:
        labels:
          app: granite-3-3-2b-instruct
EOF
```

Key configuration choices:

- **`serving.kserve.io/deploymentMode: RawDeployment`** — Uses a standard Kubernetes Deployment instead of Knative Serving. Required on ROSA where Serverless/Knative is typically not available.
- **`storageUri: pvc://...`** — The `pvc://` prefix tells KServe to mount the PVC at `/mnt/models` in the serving container.
- **`minReplicas: 0`** — Allows the model to scale to zero when idle, freeing cluster resources.

### 6. Create the ServiceAccount Token Secret

```bash
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: granite-3-3-2b-instruct-sa
  namespace: llm
  annotations:
    kubernetes.io/service-account.name: default
type: kubernetes.io/service-account-token
EOF
```

### 7. Wait for the Model to Be Ready

```bash
oc wait pod -l serving.kserve.io/inferenceservice=granite-3-3-2b-instruct \
  -n llm --for=condition=ready --timeout=600s
```

> **Note:** CPU-only vLLM startup is slower than GPU — the model loading phase can take several minutes.

Verify the InferenceService is Ready:

```bash
oc get inferenceservice -n llm
```

Expected output:

```
NAME                      URL                                                                  READY
granite-3-3-2b-instruct   http://granite-3-3-2b-instruct-predictor.llm.svc.cluster.local      True
```

## Verification

### List Available Models

```bash
oc exec deploy/granite-3-3-2b-instruct-predictor -n llm -c kserve-container -- \
  curl -s http://localhost:8000/v1/models | jq .
```

### Test Chat Completion

```bash
oc exec deploy/granite-3-3-2b-instruct-predictor -n llm -c kserve-container -- \
  curl -s http://localhost:8000/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{
      "model": "ibm-granite/granite-3.3-2b-instruct",
      "messages": [{"role": "user", "content": "What is Red Hat OpenShift AI?"}],
      "max_tokens": 100
    }'
```

### Access from Other Pods

From any pod in the cluster, the model is reachable at:

```
http://granite-3-3-2b-instruct-predictor.llm.svc.cluster.local:8000/v1/chat/completions
```

### Access Locally via Port Forward

To query the model directly from your machine, forward the service port:

```bash
oc port-forward -n llm svc/granite-3-3-2b-instruct-predictor 8000:8000
```

Then, in a separate terminal:

```bash
curl -s http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "ibm-granite/granite-3.3-2b-instruct",
    "messages": [{"role": "user", "content": "What is Red Hat OpenShift AI?"}],
    "max_tokens": 100
  }' | jq .
```

## Resource Optimization for Small Clusters

On a small cluster (e.g. 2-node ROSA HCP with 2x m5.xlarge), if the deployment exceeds available capacity, the following changes can be applied to free resources:

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

## Model Configuration Reference

| Parameter | Value |
|-----------|-------|
| Model ID | `ibm-granite/granite-3.3-2b-instruct` |
| Storage mode | PVC (HuggingFace download) |
| PVC size | 10Gi |
| Runtime | vLLM CPU (`quay.io/pierdipi/vllm-cpu:latest`) |
| Max context length | 4096 tokens (limited from 128K native) |
| GPU required | No |
| API | OpenAI-compatible (`/v1/chat/completions`) |
| Deployment mode | RawDeployment |
| Min replicas | 0 (scale to zero) |
| Namespace | `llm` |
