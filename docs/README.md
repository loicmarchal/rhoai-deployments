# RHOAI Deployments Documentation

This repository contains guides for installing Red Hat OpenShift AI (RHOAI) on ROSA HCP clusters and deploying models using KServe.

All guides target ROSA HCP (Hosted Control Plane) clusters and include workarounds for platform-specific constraints such as pull secret reconciliation (solved via Kyverno) and the absence of Knative/Serverless (solved via RawDeployment mode).

## Installing RHOAI on ROSA

Step-by-step installation of the RHOAI operator, Kyverno-based pull secret management, and DataScienceCluster configuration. Covers both full and resource-constrained setups, including dashboard feature flags and troubleshooting (CatalogSource ImagePullBackOff, Kyverno CrashLoopBackOff, pending pods).

- **Platform**: ROSA HCP
- **Key components**: Kyverno, RHOAI Operator, CatalogSource, DataScienceCluster
- **Cluster requirements**: 2+ worker nodes (4 vCPU / 16 GB each minimum)

> **Full guide**: [RHOAI-ROSA-Installation-Guide.md](RHOAI-ROSA-Installation-Guide.md)

## Deploying Granite 3.3 2B Instruct (CPU, PVC Mode)

Deploys the IBM Granite 3.3 2B Instruct chat model on CPU-only clusters by downloading weights from HuggingFace into a PVC. Optimized for minimal resource footprint (context window capped at 4 096 tokens, KV cache limited to 1 GB).

- **Model**: `ibm-granite/granite-3.3-2b-instruct`
- **Storage**: PVC (10 Gi, HuggingFace download)
- **Runtime**: vLLM CPU
- **API**: OpenAI-compatible `/v1/chat/completions`
- **GPU required**: No

> **Full guide**: [deploy-granite-3-3-2b-instruct-cpu.md](deploy-granite-3-3-2b-instruct-cpu.md)

## Deploying Granite Embedding via ModelCar

Deploys the IBM Granite Embedding English R2 model using the KServe ModelCar approach, which packages model weights as an OCI container image. No PVC or download job needed — the model is pulled directly from a container registry.

- **Model**: `ibm-granite/granite-embedding-english-r2`
- **Storage**: OCI image (ModelCar)
- **Runtime**: vLLM CPU
- **API**: OpenAI-compatible `/v1/embeddings`
- **Embedding dimensions**: 768
- **GPU required**: No

> **Full guide**: [deploy-granite-embedding-modelcar.md](deploy-granite-embedding-modelcar.md)
