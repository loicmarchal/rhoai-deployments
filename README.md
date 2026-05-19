# RHOAI Deployments

Automation and documentation for installing [Red Hat OpenShift AI](https://www.redhat.com/en/technologies/cloud-computing/openshift/openshift-ai) (RHOAI) on ROSA HCP clusters and deploying models using KServe.

## Quick Start

```bash
# Install RHOAI on your cluster
./scripts/install-rhoai.sh

# Deploy a model
./scripts/deploy-model.sh scripts/models/granite-3-3-8b-instruct.conf
```

## Repository Structure

```
scripts/
  install-rhoai.sh          # Automated RHOAI installation
  deploy-model.sh           # Model deployment (GPU/CPU, PVC/ModelCar)
  models/                   # Ready-to-use model configuration files
docs/
  RHOAI-ROSA-Installation-Guide.md
  deploy-granite-3-3-2b-instruct-cpu.md
  deploy-granite-embedding-modelcar.md
```

## Scripts

### `install-rhoai.sh`

Automates the full RHOAI installation: pull secret creation, Kyverno setup for secret distribution, CatalogSource, operator installation, and DataScienceCluster creation.

```bash
# Minimal install (Dashboard + KServe + Workbenches only)
./scripts/install-rhoai.sh --minimal --wait

# Specific RHOAI version
./scripts/install-rhoai.sh --catalog-image quay.io/rhoai/rhoai-fbc-fragment:rhoai-3.5
```

### `deploy-model.sh`

Deploys a model via KServe InferenceService + vLLM. Supports PVC-based storage (downloads from HuggingFace) and ModelCar (OCI image). Automatically detects GPU availability and can fall back to an alternative config.

```bash
# Deploy with GPU fallback to CPU
./scripts/deploy-model.sh scripts/models/granite-3-3-8b-instruct.conf scripts/models/granite-3-3-2b-instruct-cpu.conf

# Undeploy
./scripts/deploy-model.sh -d scripts/models/granite-3-3-8b-instruct.conf
```

See [scripts/README.md](scripts/README.md) for the full reference (all flags, environment variables, config file format, and examples).

## Available Model Configs

| Config | Model | Mode | GPU |
|--------|-------|------|-----|
| `granite-3-3-8b-instruct.conf` | Granite 3.3 8B Instruct | PVC | Yes |
| `granite-3-3-2b-instruct-cpu.conf` | Granite 3.3 2B Instruct | PVC | No |
| `granite-3-3-2b-instruct-cpu-minimal.conf` | Granite 3.3 2B Instruct (minimal) | PVC | No |
| `granite-embedding.conf` | Granite Embedding English R2 | PVC | Yes |
| `granite-embedding-cpu.conf` | Granite Embedding English R2 | PVC | No |
| `granite-embedding-modelcar.conf` | Granite Embedding English R2 | ModelCar | No |
| `llama-3-3-70b.conf` | Llama 3.3 70B | PVC | Yes |
| `llama-3-1-8b-modelcar.conf` | Llama 3.1 8B | ModelCar | No |
| `llama-3-2-1b-cpu.conf` | Llama 3.2 1B | PVC | No |
| `opt-125m-cpu.conf` | OPT 125M | PVC | No |

## Documentation

Step-by-step guides covering manual installation and deployment procedures are available in the [docs/](docs/) directory.

## Prerequisites

- ROSA HCP cluster with cluster-admin access
- `oc` and `jq` installed
- Docker config with registry credentials at `~/.docker/config.json`
