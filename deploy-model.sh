#!/usr/bin/env bash
set -euo pipefail

# Deploy Model on RHOAI using KServe InferenceService + vLLM
#
# Self-contained script — no external dependencies beyond oc, jq, and a .conf file.
# Supports both ModelCar (OCI image) and PVC (HuggingFace download) storage modes.
#
# Usage:
#   ./deploy-model.sh <config.conf> [fallback-config.conf]
#   ./deploy-model.sh -d <config.conf>
#   ./deploy-model.sh --help
#
# Examples:
#   ./deploy-model.sh models/granite-embedding-modelcar.conf
#   ./deploy-model.sh models/granite-3-3-8b-instruct.conf models/granite-3-3-2b-instruct-cpu.conf
#   ./deploy-model.sh -d models/granite-embedding-modelcar.conf
#
# Config selection logic:
#   CPU_ONLY=true  → only deploy if the config has GPU_REQUIRED=false,
#                     otherwise try the fallback config.
#   CPU_ONLY unset → auto-detect GPU availability on the cluster.
#                     If the preferred config needs a GPU type that isn't present,
#                     try the fallback. Error if neither is compatible.
#
# Environment variables:
#   MODEL_NAMESPACE   Target namespace (default: llm)
#   CPU_ONLY          Force CPU-only mode (default: false)
#   DEPLOY_OUTPUT_FILE  Write deployment info (CONFIG_FILE, MODEL_URL, MODEL_NAME) to this file

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

log_info()    { echo "[INFO] $1"; }
log_success() { echo "[SUCCESS] $1"; }
log_warning() { echo "[WARNING] $1"; }
log_error()   { echo "[ERROR] $1" >&2; }

die() { log_error "$1"; exit 1; }

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<'HELPEOF'
Usage: deploy-model.sh [options] <config.conf> [fallback-config.conf]

Deploys (or undeploys) a model on RHOAI using KServe InferenceService + vLLM.

Options:
  -d    Undeploy: delete all resources created by a previous deployment
        (InferenceService, ServingRuntime, Secret, and PVC/Job if applicable)

Reads all model parameters from the supplied .conf file.

Storage modes (auto-detected from config):
  ModelCar   Config sets MODELCAR_IMAGE  → model pulled as OCI container image
  PVC        Config sets PVC_NAME        → model downloaded from HuggingFace into a PVC

Config variables (set in .conf file):
  Required:
    MODEL_DISPLAY_NAME   Human-readable name
    MODEL_ID             HuggingFace model identifier
    ISVC_NAME            Kubernetes InferenceService name

  ModelCar mode:
    MODELCAR_IMAGE       OCI image URI (e.g. quay.io/org/repo@sha256:...)

  PVC mode:
    PVC_NAME             PersistentVolumeClaim name
    PVC_SIZE             PVC storage size (e.g. 10Gi)

  GPU (required when GPU_REQUIRED != "false"):
    GPU_TYPE             Node instance type (e.g. g5.2xlarge)
    GPU_COUNT            Number of GPUs (default: 1)
    TENSOR_PARALLEL      Tensor parallelism degree (default: 1)

  Resources:
    SR_CPU_REQ           CPU request (default: 100m)
    SR_CPU_LIMIT         CPU limit (default: 2)
    SR_MEM_REQ           Memory request (default: 2Gi)
    SR_MEM_LIMIT         Memory limit (default: 4Gi)
    SHM_SIZE             Shared memory size (default: 2Gi)

  Optional:
    GPU_REQUIRED         "false" for CPU-only (default: true)
    MODEL_ROLE           Label value: llm, embedding, model (default: model)
    VLLM_IMAGE           Override vLLM runtime image
    VLLM_EXTRA_ENV       Space-separated KEY=VALUE pairs for extra env vars
    MAX_MODEL_LEN        Maximum model context length
    MIN_REPLICAS         Minimum pod replicas (default: 1)
    DOWNLOAD_TIMEOUT     HuggingFace download timeout in seconds (default: 1200)

Environment variables:
  MODEL_NAMESPACE        Target namespace (default: llm)
  CPU_ONLY               Force CPU-only mode (default: false)
  DEPLOY_OUTPUT_FILE     Write deployment info to this file on completion
HELPEOF
    exit 0
fi

# ---------------------------------------------------------------------------
# Flag parsing
# ---------------------------------------------------------------------------

DELETE_MODE="false"
if [[ "${1:-}" == "-d" ]]; then
    DELETE_MODE="true"
    shift
fi

# ---------------------------------------------------------------------------
# Inlined utility functions (replaces _lib.sh dependency)
# ---------------------------------------------------------------------------

require_oc_login() {
    command -v oc &>/dev/null || die "oc command not found"
    oc whoami &>/dev/null    || die "Not logged into OpenShift — run 'oc login' first"
}

is_disconnected() {
    if oc get proxy cluster -o jsonpath='{.spec.httpProxy}' 2>/dev/null | grep -q .; then
        return 0
    fi
    if oc get imagecontentsourcepolicy 2>/dev/null | grep -q .; then
        return 0
    fi
    if oc get imagedigestmirrorset 2>/dev/null | grep -q .; then
        return 0
    fi
    return 1
}

is_anp_disconnected() {
    [[ "${ANP_DISCONNECTED:-}" == "true" ]]
}

# ---------------------------------------------------------------------------
# Config selection
# ---------------------------------------------------------------------------

PRIMARY_CONFIG="${1:-}"
FALLBACK_CONFIG="${2:-}"

[[ -z "$PRIMARY_CONFIG" ]] && die "Usage: $0 [-d] <config.conf> [fallback-config.conf]"

# is_config_deployable <config-file>
is_config_deployable() {
    local conf="$1"
    [[ ! -f "$conf" ]] && return 1

    local gpu_req gpu_type
    gpu_req=$(grep -E '^GPU_REQUIRED=' "$conf" | cut -d= -f2- | tr -d '"' || true)
    gpu_req="${gpu_req:-true}"

    [[ "$gpu_req" == "false" ]] && return 0

    if [[ "${CPU_ONLY:-false}" == "true" ]]; then
        return 1
    fi

    gpu_type=$(grep -E '^GPU_TYPE=' "$conf" | cut -d= -f2- | tr -d '"' || true)
    if [[ -z "$gpu_type" ]]; then
        return 1
    fi
    if oc get nodes -l "node.kubernetes.io/instance-type=$gpu_type" --no-headers 2>/dev/null | grep -q .; then
        return 0
    fi
    return 1
}

if [[ "$DELETE_MODE" == "true" ]]; then
    [[ ! -f "$PRIMARY_CONFIG" ]] && die "Config file not found: $PRIMARY_CONFIG"
    CONFIG_FILE="$PRIMARY_CONFIG"
    log_info "Delete mode — using config: $(basename "$CONFIG_FILE")"
else
    CONFIG_FILE=""
    if is_config_deployable "$PRIMARY_CONFIG"; then
        CONFIG_FILE="$PRIMARY_CONFIG"
        log_info "Using preferred config: $(basename "$PRIMARY_CONFIG")"
    elif [[ -n "$FALLBACK_CONFIG" ]] && is_config_deployable "$FALLBACK_CONFIG"; then
        CONFIG_FILE="$FALLBACK_CONFIG"
        log_warning "Preferred config $(basename "$PRIMARY_CONFIG") not compatible with this cluster"
        log_info "Using fallback config: $(basename "$FALLBACK_CONFIG")"
    elif [[ -n "$FALLBACK_CONFIG" ]]; then
        die "Neither config is compatible with this cluster:
  Preferred: $(basename "$PRIMARY_CONFIG")
  Fallback:  $(basename "$FALLBACK_CONFIG")"
    else
        die "Config $(basename "$PRIMARY_CONFIG") is not compatible with this cluster and no fallback provided"
    fi
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

# ---------------------------------------------------------------------------
# Detect deployment mode
# ---------------------------------------------------------------------------

IS_MODELCAR="false"
if [[ -n "${MODELCAR_IMAGE:-}" ]]; then
    IS_MODELCAR="true"
fi

# ---------------------------------------------------------------------------
# Apply defaults
# ---------------------------------------------------------------------------

NAMESPACE="${MODEL_NAMESPACE:-llm}"
GPU_COUNT="${GPU_COUNT:-1}"
TENSOR_PARALLEL="${TENSOR_PARALLEL:-1}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-}"
MIN_REPLICAS="${MIN_REPLICAS:-1}"
SHM_SIZE="${SHM_SIZE:-2Gi}"
DOWNLOAD_TIMEOUT="${DOWNLOAD_TIMEOUT:-1200}"
DL_MEM_REQ="${DL_MEM_REQ:-2Gi}"
DL_MEM_LIMIT="${DL_MEM_LIMIT:-4Gi}"
DL_CPU_REQ="${DL_CPU_REQ:-1}"
DL_CPU_LIMIT="${DL_CPU_LIMIT:-2}"
ENDPOINT_SCHEME="${ENDPOINT_SCHEME:-http}"
ENDPOINT_PORT="${ENDPOINT_PORT:-8000}"
GPU_REQUIRED="${GPU_REQUIRED:-true}"
SR_CPU_REQ="${SR_CPU_REQ:-100m}"
SR_CPU_LIMIT="${SR_CPU_LIMIT:-2}"
SR_MEM_REQ="${SR_MEM_REQ:-2Gi}"
SR_MEM_LIMIT="${SR_MEM_LIMIT:-4Gi}"
MODEL_ROLE="${MODEL_ROLE:-model}"

# ---------------------------------------------------------------------------
# Resolve vLLM image (deploy only)
# ---------------------------------------------------------------------------

if [[ "$DELETE_MODE" != "true" ]]; then
    if [[ "$IS_MODELCAR" == "true" ]]; then
        if [[ -z "${VLLM_IMAGE:-}" ]]; then
            if [[ "$GPU_REQUIRED" == "true" ]]; then
                _RUNTIME_TEMPLATE="vllm-cuda-runtime-template"
                _RUNTIME_IMAGE_DEFAULT="registry.redhat.io/rhaiis/vllm-cuda-rhel9:latest"
            else
                _RUNTIME_TEMPLATE="vllm-cpu-x86-runtime-template"
                _RUNTIME_IMAGE_DEFAULT="registry.redhat.io/rhaiis/vllm-cpu-rhel9:latest"
            fi
            VLLM_IMAGE=$(oc get template "$_RUNTIME_TEMPLATE" -n redhat-ods-applications \
                -o jsonpath='{.objects[0].spec.containers[0].image}' 2>/dev/null || echo "")
            if [[ -z "$VLLM_IMAGE" ]]; then
                VLLM_IMAGE="$_RUNTIME_IMAGE_DEFAULT"
                log_warning "Could not resolve vLLM image from RHOAI template — using default: $VLLM_IMAGE"
            fi
            log_info "Resolved vLLM image: $VLLM_IMAGE"
        fi
    else
        VLLM_IMAGE="${VLLM_IMAGE:-vllm/vllm-openai:latest}"
    fi
fi

# ---------------------------------------------------------------------------
# Validate required fields
# ---------------------------------------------------------------------------

MISSING=""
for VAR in MODEL_DISPLAY_NAME MODEL_ID ISVC_NAME; do
    if [[ -z "${!VAR:-}" ]]; then
        MISSING="$MISSING $VAR"
    fi
done
if [[ "$DELETE_MODE" != "true" ]]; then
    if [[ "$IS_MODELCAR" == "true" ]]; then
        [[ -z "${MODELCAR_IMAGE:-}" ]] && MISSING="$MISSING MODELCAR_IMAGE"
    else
        for VAR in PVC_NAME PVC_SIZE; do
            if [[ -z "${!VAR:-}" ]]; then
                MISSING="$MISSING $VAR"
            fi
        done
    fi
    if [[ "$GPU_REQUIRED" == "true" ]] && [[ -z "${GPU_TYPE:-}" ]]; then
        MISSING="$MISSING GPU_TYPE"
    fi
fi
[[ -n "$MISSING" ]] && die "Missing required config variables:$MISSING"

ISVC_LABEL="serving.kserve.io/inferenceservice=$ISVC_NAME"
SR_NAME="vllm-$ISVC_NAME"

# ---------------------------------------------------------------------------
# Build conditional YAML fragments (deploy only)
# ---------------------------------------------------------------------------

if [[ "$DELETE_MODE" != "true" ]]; then

# vLLM extra args
VLLM_EXTRA_ARGS=""
if [[ "$TENSOR_PARALLEL" -gt 1 ]]; then
    VLLM_EXTRA_ARGS="${VLLM_EXTRA_ARGS}
        - --tensor-parallel-size
        - \"$TENSOR_PARALLEL\""
fi
if [[ -n "$MAX_MODEL_LEN" ]]; then
    VLLM_EXTRA_ARGS="${VLLM_EXTRA_ARGS}
        - --max-model-len
        - \"$MAX_MODEL_LEN\""
fi

# Extra env vars from VLLM_EXTRA_ENV (space-separated KEY=VALUE pairs)
VLLM_EXTRA_ENV_YAML=""
for entry in ${VLLM_EXTRA_ENV:-}; do
    local_key="${entry%%=*}"
    local_val="${entry#*=}"
    VLLM_EXTRA_ENV_YAML="${VLLM_EXTRA_ENV_YAML}
        - name: ${local_key}
          value: \"${local_val}\""
done

# Scheduling and resource YAML
if [[ "$GPU_REQUIRED" == "true" ]]; then
    DL_SCHEDULING_YAML="      nodeSelector:
        node.kubernetes.io/instance-type: $GPU_TYPE
      tolerations:
      - key: nvidia.com/gpu
        operator: Exists
        effect: NoSchedule"
    SR_RESOURCES_YAML="      resources:
        limits:
          nvidia.com/gpu: \"$GPU_COUNT\"
        requests:
          nvidia.com/gpu: \"$GPU_COUNT\""
    ISVC_SCHEDULING_YAML="        nodeSelector:
          node.kubernetes.io/instance-type: $GPU_TYPE
        tolerations:
          - key: nvidia.com/gpu
            operator: Exists
            effect: NoSchedule"
else
    DL_SCHEDULING_YAML=""
    SR_RESOURCES_YAML="      resources:
        requests:
          cpu: \"$SR_CPU_REQ\"
          memory: \"$SR_MEM_REQ\"
        limits:
          cpu: \"$SR_CPU_LIMIT\"
          memory: \"$SR_MEM_LIMIT\""
    ISVC_SCHEDULING_YAML=""
fi

# Storage URI
if [[ "$IS_MODELCAR" == "true" ]]; then
    STORAGE_URI="oci://$MODELCAR_IMAGE"
else
    STORAGE_URI="pvc://$PVC_NAME"
fi

fi  # end deploy-only YAML fragments

# ---------------------------------------------------------------------------
# Endpoint discovery
# ---------------------------------------------------------------------------

discover_endpoint() {
    local svc_name="${ISVC_NAME}-predictor"
    ACTUAL_PORT=$(oc get svc "$svc_name" -n "$NAMESPACE" \
        -o jsonpath='{.spec.ports[0].targetPort}' 2>/dev/null || echo "")
    if [[ -n "$ACTUAL_PORT" ]]; then
        local container_args
        container_args=$(oc get pod -l "$ISVC_LABEL" -n "$NAMESPACE" \
            -o jsonpath='{.items[0].spec.containers[0].args}' 2>/dev/null || echo "")
        if echo "$container_args" | grep -q 'ssl-certfile'; then
            ACTUAL_SCHEME="https"
        else
            ACTUAL_SCHEME="http"
        fi
    else
        log_warning "Could not discover service — using config values"
        ACTUAL_PORT="$ENDPOINT_PORT"
        ACTUAL_SCHEME="$ENDPOINT_SCHEME"
    fi
    MODEL_ENDPOINT="${ACTUAL_SCHEME}://${svc_name}.${NAMESPACE}.svc.cluster.local:${ACTUAL_PORT}"
}

# ===========================================================================
#  Undeploy flow
# ===========================================================================

undeploy_model() {
    echo ""
    echo "==================================================================="
    echo "  Undeploy Model: $MODEL_DISPLAY_NAME"
    echo "==================================================================="
    echo ""
    echo "  Namespace: $NAMESPACE"
    echo "  ISVC:      $ISVC_NAME"
    echo ""

    require_oc_login
    log_success "Logged in as: $(oc whoami)"

    if oc get inferenceservice "$ISVC_NAME" -n "$NAMESPACE" &>/dev/null; then
        log_info "Deleting InferenceService '$ISVC_NAME'..."
        oc delete inferenceservice "$ISVC_NAME" -n "$NAMESPACE" --wait=false
        log_info "Waiting for model pods to terminate..."
        oc wait --for=delete pod -l "$ISVC_LABEL" -n "$NAMESPACE" --timeout=300s 2>/dev/null || true
        log_success "InferenceService deleted"
    else
        log_info "InferenceService '$ISVC_NAME' not found — skipping"
    fi

    if oc get servingruntime "$SR_NAME" -n "$NAMESPACE" &>/dev/null; then
        log_info "Deleting ServingRuntime '$SR_NAME'..."
        oc delete servingruntime "$SR_NAME" -n "$NAMESPACE"
        log_success "ServingRuntime deleted"
    else
        log_info "ServingRuntime '$SR_NAME' not found — skipping"
    fi

    if oc get secret "${ISVC_NAME}-sa" -n "$NAMESPACE" &>/dev/null; then
        log_info "Deleting ServiceAccount token secret..."
        oc delete secret "${ISVC_NAME}-sa" -n "$NAMESPACE"
        log_success "Secret deleted"
    else
        log_info "Secret '${ISVC_NAME}-sa' not found — skipping"
    fi

    if [[ "$IS_MODELCAR" != "true" ]]; then
        local job_name="${ISVC_NAME}-download"
        if oc get job "$job_name" -n "$NAMESPACE" &>/dev/null; then
            log_info "Deleting download Job '$job_name'..."
            oc delete job "$job_name" -n "$NAMESPACE"
            log_success "Job deleted"
        else
            log_info "Job '$job_name' not found — skipping"
        fi

        if oc get pvc "$PVC_NAME" -n "$NAMESPACE" &>/dev/null; then
            log_info "Deleting PVC '$PVC_NAME'..."
            oc delete pvc "$PVC_NAME" -n "$NAMESPACE"
            log_success "PVC deleted"
        else
            log_info "PVC '$PVC_NAME' not found — skipping"
        fi
    fi

    echo ""
    echo "==================================================================="
    log_success "Model Undeployed: $MODEL_DISPLAY_NAME"
    echo "==================================================================="
}

if [[ "$DELETE_MODE" == "true" ]]; then
    undeploy_model
    exit 0
fi

# ===========================================================================
#  Main deployment flow
# ===========================================================================

echo ""
echo "==================================================================="
echo "  Deploy Model: $MODEL_DISPLAY_NAME"
echo "==================================================================="
echo ""
echo "Configuration:"
echo "  Namespace:  $NAMESPACE"
echo "  Model ID:   $MODEL_ID"
if [[ "$IS_MODELCAR" == "true" ]]; then
    echo "  Mode:       ModelCar (OCI image)"
    echo "  Image:      $MODELCAR_IMAGE"
else
    echo "  Mode:       PVC (HuggingFace download)"
    echo "  PVC Size:   $PVC_SIZE"
fi
if [[ "$GPU_REQUIRED" == "true" ]]; then
    echo "  GPU:        $GPU_TYPE ($GPU_COUNT GPUs)"
else
    echo "  GPU:        none (CPU-only)"
fi
echo "  vLLM Image: $VLLM_IMAGE"
echo ""

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------

log_info "Checking prerequisites..."
require_oc_login
log_success "Logged in as: $(oc whoami)"

# Create namespace
if ! oc get namespace "$NAMESPACE" &>/dev/null; then
    log_info "Creating namespace $NAMESPACE..."
    if oc create namespace "$NAMESPACE" >/dev/null 2>&1; then
        log_success "Namespace created"
    else
        log_info "Namespace $NAMESPACE was created by another process"
    fi
else
    log_info "Namespace $NAMESPACE already exists"
fi

oc label namespace "$NAMESPACE" opendatahub.io/dashboard=true modelmesh-enabled=false --overwrite >/dev/null

# ---------------------------------------------------------------------------
# Check for existing deployment
# ---------------------------------------------------------------------------

if oc get inferenceservice "$ISVC_NAME" -n "$NAMESPACE" &>/dev/null 2>&1; then
    log_success "InferenceService '$ISVC_NAME' already exists"
    READY=$(oc get inferenceservice "$ISVC_NAME" -n "$NAMESPACE" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
    echo "  Status: Ready=$READY"

    discover_endpoint

    echo ""
    echo "Model Endpoint:"
    echo "  Internal URL: $MODEL_ENDPOINT"
    TOKEN=$(oc get secret "${ISVC_NAME}-sa" -n "$NAMESPACE" \
        -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || echo "N/A")
    echo "  Token: ${TOKEN:0:20}..."
    echo ""
    log_success "Model already deployed — skipping"
    if [[ -n "${DEPLOY_OUTPUT_FILE:-}" ]]; then
        cat > "${DEPLOY_OUTPUT_FILE}" <<OUTEOF
CONFIG_FILE=${CONFIG_FILE}
MODEL_URL=${MODEL_ENDPOINT}/v1
MODEL_NAME=${MODEL_ID}
OUTEOF
    fi
    exit 0
fi

log_info "InferenceService not found — proceeding with deployment"

# ---------------------------------------------------------------------------
# Disconnected cluster: ImageTagMirrorSet for ModelCar images
# ---------------------------------------------------------------------------

if [[ "$IS_MODELCAR" == "true" ]] && is_disconnected && ! is_anp_disconnected; then
    echo ""
    echo "==================================================================="
    echo "  Image Mirror Set (Disconnected)"
    echo "==================================================================="
    APPS_DOMAIN=$(oc get ingresses.config cluster -o jsonpath='{.spec.domain}')
    CLUSTER_DOMAIN="${APPS_DOMAIN#apps.}"
    BASTION_REGISTRY="${BASTION_REGISTRY:-bastion.${CLUSTER_DOMAIN}:8443}"

    log_info "Creating ImageTagMirrorSet for modelcar-catalog..."
    cat <<EOF | oc apply -f -
apiVersion: config.openshift.io/v1
kind: ImageTagMirrorSet
metadata:
  name: modelcar-catalog
spec:
  imageTagMirrors:
  - mirrorSourcePolicy: NeverContactSource
    mirrors:
    - ${BASTION_REGISTRY}/redhat-ai-services
    source: quay.io/redhat-ai-services
EOF
    log_success "ITMS created — modelcar images will pull from $BASTION_REGISTRY"
elif [[ "$IS_MODELCAR" == "true" ]] && is_disconnected && is_anp_disconnected; then
    log_info "[ANP_DISCONNECTED] Skipping modelcar ITMS creation"
fi

# ---------------------------------------------------------------------------
# PVC mode: create PVC and download model
# ---------------------------------------------------------------------------

if [[ "$IS_MODELCAR" != "true" ]]; then

echo ""
echo "==================================================================="
echo "  STEP 1: Create PVC for Model Storage"
echo "==================================================================="

if oc get pvc "$PVC_NAME" -n "$NAMESPACE" &>/dev/null 2>&1; then
    log_info "PVC '$PVC_NAME' already exists"
    PVC_STATUS=$(oc get pvc "$PVC_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}')
    echo "  Status: $PVC_STATUS"
else
    log_info "Creating PVC ($PVC_SIZE)..."
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $PVC_NAME
  namespace: $NAMESPACE
  labels:
    shepard.io/model-role: $MODEL_ROLE
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: $PVC_SIZE
  storageClassName: gp3-csi
EOF
    log_success "PVC created"
fi

echo ""
echo "==================================================================="
echo "  STEP 2: Download Model from HuggingFace"
echo "==================================================================="

JOB_NAME="${ISVC_NAME}-download"

if oc get job "$JOB_NAME" -n "$NAMESPACE" &>/dev/null 2>&1; then
    JOB_STATUS=$(oc get job "$JOB_NAME" -n "$NAMESPACE" \
        -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || echo "Unknown")

    if [[ "$JOB_STATUS" == "True" ]]; then
        log_success "Download job already completed"
    else
        ACTIVE=$(oc get job "$JOB_NAME" -n "$NAMESPACE" -o jsonpath='{.status.active}' 2>/dev/null || echo "0")
        FAILED=$(oc get job "$JOB_NAME" -n "$NAMESPACE" -o jsonpath='{.status.failed}' 2>/dev/null || echo "0")

        if [[ "$ACTIVE" -gt 0 ]]; then
            log_info "Download job is running — waiting for completion..."
            oc wait --for=condition=complete job/"$JOB_NAME" -n "$NAMESPACE" \
                --timeout="${DOWNLOAD_TIMEOUT}s" 2>&1 || {
                log_error "Download job failed or timed out"
                oc logs job/"$JOB_NAME" -n "$NAMESPACE" --tail=50
                exit 1
            }
            log_success "Download completed"
        elif [[ "$FAILED" -gt 0 ]]; then
            log_error "Download job failed"
            oc logs job/"$JOB_NAME" -n "$NAMESPACE" --tail=50
            exit 1
        fi
    fi
else
    log_info "Starting model download..."
    cat <<EOF | oc apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: $JOB_NAME
  namespace: $NAMESPACE
  labels:
    shepard.io/model-role: $MODEL_ROLE
spec:
  template:
    spec:
      serviceAccountName: default
$DL_SCHEDULING_YAML
      containers:
      - name: download
        image: registry.access.redhat.com/ubi9/python-311:latest
        command:
          - /bin/bash
          - -c
          - |
            pip install -q huggingface_hub
            hf download "\$MODEL_ID" --local-dir /mnt/models
        env:
        - name: MODEL_ID
          value: "$MODEL_ID"
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
            memory: "$DL_MEM_REQ"
            cpu: "$DL_CPU_REQ"
          limits:
            memory: "$DL_MEM_LIMIT"
            cpu: "$DL_CPU_LIMIT"
      volumes:
      - name: model-storage
        persistentVolumeClaim:
          claimName: $PVC_NAME
      restartPolicy: OnFailure
  backoffLimit: 3
EOF

    log_info "Waiting for download to complete..."
    log_info "Monitor progress: oc logs -f job/$JOB_NAME -n $NAMESPACE"
    oc wait --for=condition=complete job/"$JOB_NAME" -n "$NAMESPACE" \
        --timeout="${DOWNLOAD_TIMEOUT}s" 2>&1 || {
        log_error "Download job failed or timed out"
        oc logs job/"$JOB_NAME" -n "$NAMESPACE" --tail=50
        exit 1
    }
    log_success "Model downloaded"
fi

fi  # end PVC mode

# ---------------------------------------------------------------------------
# Create ServingRuntime
# ---------------------------------------------------------------------------

echo ""
echo "==================================================================="
echo "  STEP 3: Create ServingRuntime"
echo "==================================================================="

if oc get servingruntime "$SR_NAME" -n "$NAMESPACE" &>/dev/null 2>&1; then
    log_info "ServingRuntime '$SR_NAME' already exists"
else
    log_info "Creating ServingRuntime..."
    cat <<EOF | oc apply -f -
apiVersion: serving.kserve.io/v1alpha1
kind: ServingRuntime
metadata:
  name: $SR_NAME
  namespace: $NAMESPACE
  labels:
    shepard.io/model-role: $MODEL_ROLE
spec:
  annotations:
    prometheus.io/path: /metrics
    prometheus.io/port: "8000"
  containers:
    - name: kserve-container
      image: $VLLM_IMAGE
      args:
        - --model
        - /mnt/models
        - --served-model-name
        - "$MODEL_ID"
        - --port
        - "8000"$VLLM_EXTRA_ARGS
      env:
        - name: HF_HUB_CACHE
          value: /tmp
        - name: VLLM_CACHE_ROOT
          value: /tmp/vllm
        - name: HOME
          value: /tmp$VLLM_EXTRA_ENV_YAML
      ports:
        - containerPort: 8000
          protocol: TCP
$SR_RESOURCES_YAML
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
        sizeLimit: $SHM_SIZE
EOF
    log_success "ServingRuntime created"
fi

# ---------------------------------------------------------------------------
# Create InferenceService
# ---------------------------------------------------------------------------

echo ""
echo "==================================================================="
echo "  STEP 4: Create InferenceService"
echo "==================================================================="

log_info "Waiting for KServe webhook to be ready..."
for i in {1..60}; do
    ENDPOINTS=$(oc get endpoints kserve-webhook-server-service -n redhat-ods-applications \
        -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || echo "")
    if [[ -n "$ENDPOINTS" ]]; then
        log_success "KServe webhook is ready"
        break
    fi
    if [[ "$i" -eq 60 ]]; then
        die "KServe webhook not ready after 300s — cannot create InferenceService"
    fi
    sleep 5
done

log_info "Creating InferenceService..."
cat <<EOF | oc apply -f -
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: $ISVC_NAME
  namespace: $NAMESPACE
  labels:
    opendatahub.io/dashboard: "true"
    shepard.io/model-role: $MODEL_ROLE
  annotations:
    openshift.io/display-name: "$MODEL_DISPLAY_NAME"
    serving.kserve.io/deploymentMode: RawDeployment
spec:
  predictor:
    model:
      modelFormat:
        name: vLLM
        version: "1"
      runtime: $SR_NAME
      storageUri: $STORAGE_URI
    minReplicas: $MIN_REPLICAS
    maxReplicas: 1
    template:
      metadata:
        labels:
          app: $ISVC_NAME
      spec:
$ISVC_SCHEDULING_YAML
EOF
log_success "InferenceService created"

# ---------------------------------------------------------------------------
# Create ServiceAccount token secret
# ---------------------------------------------------------------------------

echo ""
if oc get secret "${ISVC_NAME}-sa" -n "$NAMESPACE" &>/dev/null; then
    log_info "ServiceAccount token secret already exists"
else
    log_info "Creating ServiceAccount token secret..."
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: ${ISVC_NAME}-sa
  namespace: $NAMESPACE
  labels:
    shepard.io/model-role: $MODEL_ROLE
  annotations:
    kubernetes.io/service-account.name: default
type: kubernetes.io/service-account-token
EOF
    log_success "ServiceAccount token secret created"
fi

# ---------------------------------------------------------------------------
# Wait for model readiness
# ---------------------------------------------------------------------------

echo ""
log_info "Waiting for model pod to be ready..."
sleep 30
oc wait --for=condition=ready pod -l "$ISVC_LABEL" -n "$NAMESPACE" --timeout=900s 2>&1 || {
    log_warning "Pod readiness check timed out — check pod status manually"
    echo "  oc get pods -n $NAMESPACE -l $ISVC_LABEL"
}

# ---------------------------------------------------------------------------
# Smoke test
# ---------------------------------------------------------------------------

discover_endpoint

CURL_FLAGS=(-s --max-time 30)
[[ "$ACTUAL_SCHEME" == "https" ]] && CURL_FLAGS+=(-k)
log_info "Smoke test: checking ${MODEL_ENDPOINT}/v1/models ..."

SMOKE_POD=$(oc get pod -l "$ISVC_LABEL" -n "$NAMESPACE" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [[ -n "$SMOKE_POD" ]]; then
    SMOKE_OUTPUT=$(oc exec "$SMOKE_POD" -n "$NAMESPACE" -c kserve-container -- \
        curl "${CURL_FLAGS[@]}" "http://localhost:8000/v1/models" 2>&1) || true
else
    SMOKE_OUTPUT=""
    log_warning "No running pod found for smoke test"
fi

if echo "$SMOKE_OUTPUT" | grep -q '"object"'; then
    log_success "Smoke test passed — model is serving"
    echo "$SMOKE_OUTPUT" | grep -o '"id":"[^"]*"' | head -1
else
    log_warning "Smoke test inconclusive — model may still be loading"
    echo "  Response: ${SMOKE_OUTPUT:0:200}"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo ""
echo "==================================================================="
log_success "Model Deployment Complete: $MODEL_DISPLAY_NAME"
echo "==================================================================="
echo ""
echo "Model Endpoint:"
echo "  Name:      $ISVC_NAME"
echo "  Namespace: $NAMESPACE"
echo "  URL:       $MODEL_ENDPOINT"

log_info "Waiting for ServiceAccount token..."
for i in {1..30}; do
    if oc get secret "${ISVC_NAME}-sa" -n "$NAMESPACE" &>/dev/null; then
        break
    fi
    [[ "$i" -eq 30 ]] && log_warning "ServiceAccount secret not found after 30s"
    sleep 1
done

TOKEN=$(oc get secret "${ISVC_NAME}-sa" -n "$NAMESPACE" \
    -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || echo "N/A")
echo "  Token:     ${TOKEN:0:20}..."
echo ""
echo "Check status:"
echo "  oc get inferenceservice $ISVC_NAME -n $NAMESPACE"
echo "  oc get pods -n $NAMESPACE -l $ISVC_LABEL"
echo ""

if [[ -n "${DEPLOY_OUTPUT_FILE:-}" ]]; then
    cat > "${DEPLOY_OUTPUT_FILE}" <<OUTEOF
CONFIG_FILE=${CONFIG_FILE}
MODEL_URL=${MODEL_ENDPOINT}/v1
MODEL_NAME=${MODEL_ID}
OUTEOF
fi
