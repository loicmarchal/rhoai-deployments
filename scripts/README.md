# RHOAI Installation & Model Deployment Guide

## 1. Installing RHOAI (`install-rhoai.sh`)

Automates the full RHOAI installation on a ROSA cluster: prerequisites check, pull secret creation, Kyverno setup, CatalogSource, operator installation, and DataScienceCluster creation.

### Prerequisites

- `oc` and `jq` installed
- Logged into an OpenShift cluster with cluster-admin permissions (`oc login`)
- A Docker config file with credentials for pulling RHOAI images (defaults to `~/.docker/config.json`)
- No existing RHOAI/ODH installation on the cluster

### Basic Usage

```bash
./install-rhoai.sh
```

### Options

| Flag | Description |
|------|-------------|
| `--catalog-image IMAGE` | Custom catalog image (default: `quay.io/rhoai/rhoai-fbc-fragment:rhoai-3.4`) |
| `--docker-config PATH` | Path to docker config.json (default: `~/.docker/config.json`) |
| `--skip-kyverno` | Skip Kyverno installation (if already installed) |
| `--minimal` | Install only Dashboard, KServe, and Workbenches (saves resources) |
| `--wait` | Block until the DataScienceCluster reaches `Ready` state |
| `--help` | Show help |

All flags can also be set via environment variables: `CATALOG_IMAGE`, `DOCKER_CONFIG`, `SKIP_KYVERNO`, `MINIMAL_INSTALL`, `WAIT_READY`.

### Examples

```bash
# Default install
./install-rhoai.sh

# Minimal install with a specific catalog image, wait for readiness
./install-rhoai.sh --minimal --wait --catalog-image quay.io/rhoai/rhoai-fbc-fragment:rhoai-3.5

# Skip Kyverno (already installed), custom docker config
./install-rhoai.sh --skip-kyverno --docker-config /path/to/config.json
```

### What It Does (Step by Step)

1. **Prerequisites check** — verifies `oc`/`jq` are available, cluster access, admin permissions, no prior RHOAI install
2. **Pull secret** — creates `pull-secret-brew` in `openshift-config` from your docker config
3. **Kyverno** — installs Kyverno and creates CRDs for ClusterPolicy/Policy
4. **Kyverno policies** — sets up RBAC and two policies: secret sync (copies the pull secret to every namespace) and imagePullSecret injection (adds the secret to every pod)
5. **CatalogSource** — creates an `rhoai-catalog` CatalogSource in `openshift-marketplace`
6. **Operator** — creates an OperatorGroup and Subscription in `redhat-ods-operator`, waits for the CSV to succeed
7. **DataScienceCluster** — creates `default-dsc` with all components managed (or minimal subset with `--minimal`)
8. **Wait & optimize** — in `--minimal` mode, scales down replicas and reduces resource requests; optionally waits for readiness
9. **Summary** — prints operator version, pod status, dashboard URL, and useful commands

---

## 2. Deploying a Model (`deploy-model.sh`)

Deploys a model on RHOAI using KServe InferenceService + vLLM. Supports two storage modes and includes automatic GPU detection and fallback config support.

### Prerequisites

- `oc` and `jq` installed
- Logged into an OpenShift cluster (`oc login`)
- RHOAI already installed (KServe must be available)
- A `.conf` file describing the model (see below)

### Basic Usage

```bash
./deploy-model.sh <config.conf>
```

### Options

| Flag | Description |
|------|-------------|
| `-d` | **Undeploy**: delete all resources created by a previous deployment |
| `--help` | Show help |

A second positional argument can be passed as a **fallback config** — used if the primary config is not compatible with the cluster (e.g., requires a GPU type not available).

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `MODEL_NAMESPACE` | Target namespace | `llm` |
| `CPU_ONLY` | Force CPU-only mode | `false` |
| `DEPLOY_OUTPUT_FILE` | Write deployment info (CONFIG_FILE, MODEL_URL, MODEL_NAME) to this file | — |

### Storage Modes

The mode is auto-detected from the config file:

- **ModelCar** — Config sets `MODELCAR_IMAGE`. The model is pulled as an OCI container image. Uses `oci://` storage URI.
- **PVC** — Config sets `PVC_NAME` and `PVC_SIZE`. The model is downloaded from HuggingFace into a PersistentVolumeClaim using a download Job.

### Config File Reference

Config files are shell-sourced `.conf` files. Required and optional variables:

**Required:**
- `MODEL_DISPLAY_NAME` — Human-readable name
- `MODEL_ID` — HuggingFace model identifier (e.g., `ibm-granite/granite-3.3-8b-instruct`)
- `ISVC_NAME` — Kubernetes InferenceService name

**ModelCar mode:**
- `MODELCAR_IMAGE` — OCI image URI

**PVC mode:**
- `PVC_NAME` — PVC name
- `PVC_SIZE` — Storage size (e.g., `30Gi`)

**GPU settings** (required when `GPU_REQUIRED` is not `false`):
- `GPU_TYPE` — Node instance type (e.g., `g5.2xlarge`)
- `GPU_COUNT` — Number of GPUs (default: `1`)
- `TENSOR_PARALLEL` — Tensor parallelism degree (default: `1`)

**Resources:**
- `SR_CPU_REQ` / `SR_CPU_LIMIT` — CPU request/limit (defaults: `100m` / `2`)
- `SR_MEM_REQ` / `SR_MEM_LIMIT` — Memory request/limit (defaults: `2Gi` / `4Gi`)
- `SHM_SIZE` — Shared memory size (default: `2Gi`)

**Optional:**
- `GPU_REQUIRED` — Set to `false` for CPU-only (default: `true`)
- `MODEL_ROLE` — Label value: `llm`, `embedding`, or `model` (default: `model`)
- `VLLM_IMAGE` — Override vLLM runtime image
- `VLLM_EXTRA_ENV` — Space-separated `KEY=VALUE` pairs for extra env vars
- `MAX_MODEL_LEN` — Maximum model context length
- `MIN_REPLICAS` — Minimum pod replicas (default: `1`)
- `DOWNLOAD_TIMEOUT` — HuggingFace download timeout in seconds (default: `1200`)

### Examples

```bash
# Deploy a GPU model
./deploy-model.sh models/granite-3-3-8b-instruct.conf

# Deploy with a CPU fallback (if the cluster has no matching GPU)
./deploy-model.sh models/granite-3-3-8b-instruct.conf models/granite-3-3-2b-instruct-cpu.conf

# Force CPU-only mode
CPU_ONLY=true ./deploy-model.sh models/granite-3-3-2b-instruct-cpu.conf

# Deploy to a custom namespace
MODEL_NAMESPACE=my-models ./deploy-model.sh models/granite-3-3-8b-instruct.conf

# Undeploy a model (removes InferenceService, ServingRuntime, Secret, PVC/Job)
./deploy-model.sh -d models/granite-3-3-8b-instruct.conf
```

### Example Config File (GPU — PVC mode)

```conf
MODEL_DISPLAY_NAME="Granite 3.3 8B Instruct"
MODEL_ID="ibm-granite/granite-3.3-8b-instruct"
ISVC_NAME="granite-3-3-8b-instruct"
PVC_NAME="granite-3-3-8b-instruct"
PVC_SIZE="30Gi"
GPU_TYPE="g5.2xlarge"
GPU_COUNT="1"
TENSOR_PARALLEL="1"
MAX_MODEL_LEN="4096"
MIN_REPLICAS="0"
SHM_SIZE="2Gi"
DOWNLOAD_TIMEOUT="1200"
```

### Example Config File (CPU — PVC mode)

```conf
MODEL_DISPLAY_NAME="Granite 3.3 2B Instruct (CPU)"
MODEL_ID="ibm-granite/granite-3.3-2b-instruct"
ISVC_NAME="granite-3-3-2b-instruct"
PVC_NAME="granite-3-3-2b-instruct"
PVC_SIZE="10Gi"
GPU_REQUIRED="false"
VLLM_IMAGE="quay.io/pierdipi/vllm-cpu:latest"
SR_CPU_REQ="2"
SR_CPU_LIMIT="6"
SR_MEM_REQ="8Gi"
SR_MEM_LIMIT="20Gi"
MAX_MODEL_LEN="4096"
MIN_REPLICAS="0"
SHM_SIZE="2Gi"
DOWNLOAD_TIMEOUT="600"
```

### What It Does (Step by Step)

1. **Config selection** — auto-detects GPU availability, picks primary or fallback config
2. **Namespace** — creates the target namespace (default `llm`) with required labels
3. **Skip if exists** — if the InferenceService already exists, prints its status and exits
4. **(PVC mode) Create PVC** — provisions storage for the model
5. **(PVC mode) Download model** — runs a Job to download the model from HuggingFace into the PVC
6. **ServingRuntime** — creates a vLLM-based ServingRuntime with the configured resources and GPU/CPU settings
7. **InferenceService** — creates the KServe InferenceService in `RawDeployment` mode
8. **ServiceAccount token** — creates a token secret for authentication
9. **Wait for readiness** — waits up to 15 minutes for the model pod to be ready
10. **Smoke test** — calls `/v1/models` on the running pod to verify the model is serving
11. **Summary** — prints the model endpoint URL, auth token, and useful commands
