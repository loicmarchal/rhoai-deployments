# Red Hat OpenShift AI Installation Guide for ROSA

This guide provides detailed instructions for installing Red Hat OpenShift AI (RHOAI) on a Red Hat OpenShift Service on AWS (ROSA) cluster.

## Choosing a Version

The RHOAI version is determined by the **CatalogSource image tag** used in [Step 5](#step-5-create-rhoai-catalogsource). The image follows the pattern:

```
quay.io/rhoai/rhoai-fbc-fragment:rhoai-<VERSION>
```

For example:
- `quay.io/rhoai/rhoai-fbc-fragment:rhoai-3.4` for RHOAI 3.4
- `quay.io/rhoai/rhoai-fbc-fragment:rhoai-3.5` for RHOAI 3.5

Replace the image tag in Step 5 with the version you want to install. The rest of the installation steps remain the same regardless of version.

> **Note**: The examples in this guide use RHOAI **3.4** as a reference.

## Table of Contents

- [Choosing a Version](#choosing-a-version)
- [Prerequisites](#prerequisites)
- [Architecture Overview](#architecture-overview)
- [Installation Steps](#installation-steps)
  - [Step 1: Verify Cluster Access](#step-1-verify-cluster-access)
  - [Step 2: Create Pull Secret for Brew Registry](#step-2-create-pull-secret-for-brew-registry)
  - [Step 3: Install Kyverno Policy Engine](#step-3-install-kyverno-policy-engine)
  - [Step 4: Configure Kyverno Policies](#step-4-configure-kyverno-policies)
  - [Step 5: Create RHOAI CatalogSource](#step-5-create-rhoai-catalogsource)
  - [Step 6: Install RHOAI Operator](#step-6-install-rhoai-operator)
  - [Step 7: Create DataScienceCluster](#step-7-create-datasciencecluster)
  - [Step 8: Configure Components](#step-8-configure-components)
  - [Step 9: Wait for DataScienceCluster Readiness](#step-9-wait-for-datasciencecluster-readiness)
  - [Step 10: Enable Dashboard Features](#step-10-enable-dashboard-features)
- [Verification](#verification)
- [Troubleshooting](#troubleshooting)
- [Resource Requirements](#resource-requirements)
- [Post-Installation](#post-installation)

---

## Prerequisites

### Required Tools

- `oc` CLI (OpenShift command-line tool)
- `jq` (JSON processor)
- Cluster admin access to a ROSA cluster

### Cluster Requirements

- **Minimum Resources**:
  - 2 worker nodes with 4 vCPU and 16 GB RAM each
  - For full installation including dashboard: 3+ worker nodes with 8 vCPU each recommended
  
- **OpenShift Version**: 4.14+ recommended

### Credentials Required

- Docker configuration file with registry credentials at `~/.docker/config.json`
  - Must include credentials for:
    - `brew.registry.redhat.io`
    - `quay.io`
    - `registry.redhat.io`

---

## Architecture Overview

RHOAI on ROSA requires special handling for image pull secrets because ROSA HCP's platform-managed pull secret gets periodically reconciled (reverted). The solution uses Kyverno to:

1. Sync brew registry credentials across all namespaces
2. Automatically inject imagePullSecrets into pods cluster-wide

**Key Components**:
- **Kyverno**: Policy engine for secret distribution
- **RHOAI Operator**: Manages DataScienceCluster lifecycle
- **CatalogSource**: Provides RHOAI operator packages
- **DataScienceCluster**: Custom resource defining enabled components

---

## Installation Steps

### Step 1: Verify Cluster Access

First, verify you have cluster admin access and check for existing installations.

```bash
# Verify cluster connectivity
oc whoami
oc cluster-info

# Check platform type
oc get infrastructure cluster -o json | jq -r '.status.platformStatus.type'

# Verify no existing RHOAI/ODH installations
oc get csv -A | grep -E 'opendatahub|rhods' || echo "No existing installations found"
```

**Expected Output**: Should confirm you're logged in as `cluster-admin` and no existing RHOAI installations are present.

---

### Step 2: Create Pull Secret for Brew Registry

Create a pull secret in the `openshift-config` namespace using your Docker credentials.

```bash
# Create the pull secret from your Docker config
oc create secret generic pull-secret-brew \
  --from-file=.dockerconfigjson=~/.docker/config.json \
  --type=kubernetes.io/dockerconfigjson \
  -n openshift-config
```

**Verification**:
```bash
oc get secret pull-secret-brew -n openshift-config
```

---

### Step 3: Install Kyverno Policy Engine

Install the latest version of Kyverno using the official installation manifest.

```bash
# Install Kyverno
oc apply -f https://github.com/kyverno/kyverno/releases/latest/download/install.yaml
```

**Note**: You may see errors about CRDs with annotations being too long. These can be safely ignored as we'll create minimal CRDs next.

#### Create Required CRDs

If the ClusterPolicy CRDs fail to install, create minimal versions:

```bash
# Create ClusterPolicy CRD
cat << 'EOF' | oc apply -f -
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: clusterpolicies.kyverno.io
  labels:
    app.kubernetes.io/part-of: kyverno
spec:
  group: kyverno.io
  names:
    kind: ClusterPolicy
    listKind: ClusterPolicyList
    plural: clusterpolicies
    shortNames:
    - cpol
    singular: clusterpolicy
    categories:
    - kyverno
  scope: Cluster
  versions:
  - name: v1
    served: true
    storage: true
    schema:
      openAPIV3Schema:
        type: object
        x-kubernetes-preserve-unknown-fields: true
    subresources:
      status: {}
EOF

# Create Policy CRD
cat << 'EOF' | oc apply -f -
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: policies.kyverno.io
  labels:
    app.kubernetes.io/part-of: kyverno
spec:
  group: kyverno.io
  names:
    kind: Policy
    listKind: PolicyList
    plural: policies
    shortNames:
    - pol
    singular: policy
    categories:
    - kyverno
  scope: Namespaced
  versions:
  - name: v1
    served: true
    storage: true
    schema:
      openAPIV3Schema:
        type: object
        x-kubernetes-preserve-unknown-fields: true
    subresources:
      status: {}
EOF
```

#### Restart Admission Controller

If the Kyverno admission controller is in CrashLoopBackOff, restart it:

```bash
# Delete the pod to trigger restart
oc delete pod -n kyverno -l app.kubernetes.io/component=admission-controller

# Wait for pods to be ready
sleep 15
oc wait --for=condition=ready pod -l app.kubernetes.io/component=admission-controller -n kyverno --timeout=90s
```

**Verification**:
```bash
# All Kyverno pods should be Running
oc get pods -n kyverno

# Expected output:
# NAME                                            READY   STATUS    RESTARTS   AGE
# kyverno-admission-controller-xxxxx              1/1     Running   0          2m
# kyverno-background-controller-xxxxx             1/1     Running   0          2m
# kyverno-cleanup-controller-xxxxx                1/1     Running   0          2m
# kyverno-reports-controller-xxxxx                1/1     Running   0          2m
```

---

### Step 4: Configure Kyverno Policies

Create RBAC permissions and policies for Kyverno to manage secrets.

#### Create RBAC for Secret Generation

```bash
cat << 'EOF' | oc apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kyverno:generate-secrets
rules:
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get", "list", "create", "update", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kyverno:generate-secrets
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: kyverno:generate-secrets
subjects:
- kind: ServiceAccount
  name: kyverno-admission-controller
  namespace: kyverno
- kind: ServiceAccount
  name: kyverno-background-controller
  namespace: kyverno
EOF
```

#### Create Secret Sync Policy

This policy clones the brew secret to all namespaces:

```bash
cat << 'EOF' | oc apply -f -
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: sync-brew-secret
spec:
  background: true
  rules:
  - name: sync-secret-to-namespaces
    match:
      any:
      - resources:
          kinds:
          - Namespace
    generate:
      apiVersion: v1
      kind: Secret
      name: pull-secret-brew
      namespace: "{{request.object.metadata.name}}"
      synchronize: true
      clone:
        namespace: openshift-config
        name: pull-secret-brew
EOF
```

#### Create ImagePullSecret Injection Policy

This policy adds the pull secret to all pods:

```bash
cat << 'EOF' | oc apply -f -
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: add-brew-imagepullsecret
spec:
  background: false
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

**Verification**:
```bash
# Check policies are created
oc get clusterpolicy

# Expected output:
# NAME                       AGE
# add-brew-imagepullsecret   1m
# sync-brew-secret           1m
```

---

### Step 5: Create RHOAI CatalogSource

Create the namespace and catalog source for RHOAI operators.

```bash
# Create the operator namespace
oc create namespace redhat-ods-operator

# Create the CatalogSource
cat << 'EOF' | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: rhoai-catalog
  namespace: openshift-marketplace
spec:
  sourceType: grpc
  image: quay.io/rhoai/rhoai-fbc-fragment:rhoai-3.4
  displayName: Red Hat OpenShift AI 3.4
  publisher: Red Hat
  updateStrategy:
    registryPoll:
      interval: 10m
  secrets:
  - pull-secret-brew
EOF
```

#### Manually Copy Secret to openshift-marketplace

The Kyverno policy may not sync the secret to openshift-marketplace immediately:

```bash
oc get secret pull-secret-brew -n openshift-config -o yaml | \
  sed 's/namespace: openshift-config/namespace: openshift-marketplace/' | \
  oc apply -f -
```

#### Wait for CatalogSource to be Ready

```bash
# Wait up to 2 minutes for the catalog to become ready
oc wait --for=jsonpath='{.status.connectionState.lastObservedState}'=READY \
  catalogsource/rhoai-catalog \
  -n openshift-marketplace \
  --timeout=120s
```

**Verification**:
```bash
# Check catalog status
oc get catalogsource -n openshift-marketplace rhoai-catalog

# Check catalog pod is running
oc get pods -n openshift-marketplace | grep rhoai-catalog

# Verify RHOAI packages are available
oc get packagemanifest -n openshift-marketplace -o json | \
  jq -r '.items[] | select(.status.catalogSource=="rhoai-catalog") | .metadata.name' | \
  grep rhods
```

---

### Step 6: Install RHOAI Operator

Create the OperatorGroup and Subscription to install the RHOAI operator.

```bash
cat << 'EOF' | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: redhat-ods-operator-group
  namespace: redhat-ods-operator
spec:
  targetNamespaces: []
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhods-operator
  namespace: redhat-ods-operator
spec:
  channel: beta
  installPlanApproval: Automatic
  name: rhods-operator
  source: rhoai-catalog
  sourceNamespace: openshift-marketplace
EOF
```

#### Wait for Operator Installation

```bash
# Wait for CSV to succeed (up to 10 minutes)
oc wait --for=jsonpath='{.status.phase}'=Succeeded \
  csv -l operators.coreos.com/rhods-operator.redhat-ods-operator \
  -n redhat-ods-operator \
  --timeout=600s
```

**Verification**:
```bash
# Check operator is installed
oc get csv -n redhat-ods-operator

# Expected output:
# NAME                          DISPLAY                   VERSION      PHASE
# rhods-operator.3.4.0-ea.2     Red Hat OpenShift AI      3.4.0-ea.2   Succeeded
```

---

### Step 7: Create DataScienceCluster

Create the DataScienceCluster custom resource to deploy RHOAI components.

```bash
cat << 'EOF' | oc apply -f -
apiVersion: datasciencecluster.opendatahub.io/v2
kind: DataScienceCluster
metadata:
  labels:
    app.kubernetes.io/name: datasciencecluster
  name: default-dsc
spec:
  components:
    aipipelines:
      managementState: Managed
    dashboard:
      managementState: Managed
    feastoperator:
      managementState: Managed
    kserve:
      managementState: Managed
      nim:
        managementState: Managed
      wva:
        managementState: Removed
    kueue:
      managementState: Removed
    llamastackoperator:
      managementState: Managed
    mlflowoperator:
      managementState: Managed
    modelregistry:
      managementState: Managed
      registriesNamespace: rhoai-model-registries
    ray:
      managementState: Managed
    sparkoperator:
      managementState: Removed
    trainer:
      managementState: Removed
    trainingoperator:
      managementState: Removed
    trustyai:
      managementState: Managed
    workbenches:
      managementState: Managed
EOF
```

**Note**: This configuration enables most components. See [Step 8](#step-8-configure-components) for resource-constrained configurations.

---

### Step 8: Configure Components

For resource-constrained clusters, disable non-essential components:

```bash
oc patch datasciencecluster default-dsc --type=merge -p '{
  "spec": {
    "components": {
      "aipipelines": {
        "managementState": "Removed"
      },
      "feastoperator": {
        "managementState": "Removed"
      },
      "llamastackoperator": {
        "managementState": "Removed"
      },
      "mlflowoperator": {
        "managementState": "Removed"
      },
      "modelregistry": {
        "managementState": "Removed"
      },
      "ray": {
        "managementState": "Removed"
      },
      "trustyai": {
        "managementState": "Removed"
      }
    }
  }
}'
```

This keeps only:
- Dashboard
- KServe (model serving)
- Workbenches (notebooks)

#### Reduce Resource Usage (Optional)

If resources are very limited, you can further reduce CPU/memory consumption by scaling down replicas and lowering container resource requests.

**Scale the operator to a single replica:**

```bash
oc scale deployment rhods-operator -n redhat-ods-operator --replicas=1
```

**Scale the dashboard to a single replica:**

```bash
oc scale deployment rhods-dashboard -n redhat-ods-applications --replicas=1
```

**Lower dashboard container resource requests:**

The dashboard deployment runs 9 containers with high default resource requests. On constrained clusters, reduce them:

```bash
oc patch deployment rhods-dashboard -n redhat-ods-applications --type='json' -p='[
  {"op": "replace", "path": "/spec/template/spec/containers/0/resources/requests/cpu", "value": "100m"},
  {"op": "replace", "path": "/spec/template/spec/containers/1/resources/requests/cpu", "value": "100m"},
  {"op": "replace", "path": "/spec/template/spec/containers/2/resources/requests/cpu", "value": "10m"},
  {"op": "replace", "path": "/spec/template/spec/containers/2/resources/requests/memory", "value": "64Mi"},
  {"op": "replace", "path": "/spec/template/spec/containers/3/resources/requests/cpu", "value": "10m"},
  {"op": "replace", "path": "/spec/template/spec/containers/3/resources/requests/memory", "value": "64Mi"},
  {"op": "replace", "path": "/spec/template/spec/containers/4/resources/requests/cpu", "value": "10m"},
  {"op": "replace", "path": "/spec/template/spec/containers/4/resources/requests/memory", "value": "64Mi"},
  {"op": "replace", "path": "/spec/template/spec/containers/5/resources/requests/cpu", "value": "10m"},
  {"op": "replace", "path": "/spec/template/spec/containers/5/resources/requests/memory", "value": "64Mi"},
  {"op": "replace", "path": "/spec/template/spec/containers/6/resources/requests/cpu", "value": "10m"},
  {"op": "replace", "path": "/spec/template/spec/containers/6/resources/requests/memory", "value": "64Mi"},
  {"op": "replace", "path": "/spec/template/spec/containers/7/resources/requests/cpu", "value": "10m"},
  {"op": "replace", "path": "/spec/template/spec/containers/7/resources/requests/memory", "value": "64Mi"},
  {"op": "replace", "path": "/spec/template/spec/containers/8/resources/requests/cpu", "value": "10m"},
  {"op": "replace", "path": "/spec/template/spec/containers/8/resources/requests/memory", "value": "64Mi"}
]'
```

**Verification**:
```bash
# Check component status
oc get datasciencecluster default-dsc -o jsonpath='{.status.phase}'

# View deployed pods
oc get pods -n redhat-ods-applications
```

---

### Step 9: Wait for DataScienceCluster Readiness

After creating the DataScienceCluster, you can monitor its status until all components are deployed:

```bash
# Poll until the phase becomes "Ready" (check every 15 seconds, up to 10 minutes)
while true; do
  phase=$(oc get datasciencecluster default-dsc -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
  echo "DataScienceCluster phase: $phase"
  [ "$phase" = "Ready" ] && break
  sleep 15
done
```

If the cluster does not reach the `Ready` phase, inspect the failing conditions:

```bash
oc get datasciencecluster default-dsc -o jsonpath='{range .status.conditions[?(@.status=="False")]}{.type}: {.message}{"\n"}{end}'
```

---

### Step 10: Enable Dashboard Features

Enable advanced features in the RHOAI dashboard:

```bash
# Wait for OdhDashboardConfig to be created
sleep 30

# Enable feature flags
oc patch odhdashboardconfig odh-dashboard-config \
  -n redhat-ods-applications \
  --type=merge \
  -p '{
    "spec": {
      "dashboardConfig": {
        "disableModelMesh": false,
        "disableKServe": false,
        "disableProjects": false
      },
      "notebookController": {
        "enabled": true
      }
    }
  }'
```

**Note**: If the OdhDashboardConfig doesn't exist yet, this step can be done after the dashboard is running.

---

## Verification

### Check Overall Status

```bash
# Check DataScienceCluster
oc get datasciencecluster default-dsc

# Check operator
oc get csv -n redhat-ods-operator

# Check all components
oc get pods -n redhat-ods-applications

# Check Kyverno policies
oc get clusterpolicy
```

### Access the Dashboard

If the cluster has sufficient resources and the dashboard is running:

```bash
# Get the dashboard route
oc get route rhods-dashboard -n redhat-ods-applications

# Example output:
# NAME              HOST/PORT
# rhods-dashboard   rhods-dashboard-redhat-ods-applications.apps.<cluster-domain>
```

Access the dashboard URL in your browser.

---

## Troubleshooting

### CatalogSource ImagePullBackOff

**Symptom**: Catalog pod shows ImagePullBackOff

**Solution**:
```bash
# Verify secret exists in openshift-marketplace
oc get secret pull-secret-brew -n openshift-marketplace

# If missing, manually copy it
oc get secret pull-secret-brew -n openshift-config -o yaml | \
  sed 's/namespace: openshift-config/namespace: openshift-marketplace/' | \
  oc apply -f -

# Restart catalog pods
oc delete pod -n openshift-marketplace -l olm.catalogSource=rhoai-catalog
```

### Kyverno Admission Controller CrashLoopBackOff

**Symptom**: Kyverno admission controller fails to start with error about missing CRDs

**Solution**:
```bash
# Create minimal CRDs (see Step 3)
# Then delete the pod to restart
oc delete pod -n kyverno -l app.kubernetes.io/component=admission-controller
```

### Dashboard Pods Pending

**Symptom**: Dashboard pods stuck in Pending state with "Insufficient CPU" or "Insufficient memory"

**Root Cause**: Cluster has insufficient resources

**Solutions**:

1. **Scale the cluster** (recommended):
   - Add more worker nodes
   - Upgrade to larger instance types

2. **Reduce dashboard replicas**:
   ```bash
   oc scale deployment rhods-dashboard -n redhat-ods-applications --replicas=1
   ```

3. **Disable dashboard entirely**:
   ```bash
   oc patch datasciencecluster default-dsc --type=merge -p '{
     "spec": {
       "components": {
         "dashboard": {
           "managementState": "Removed"
         }
       }
     }
   }'
   ```

### Check Component Readiness

```bash
# View detailed status
oc get datasciencecluster default-dsc -o yaml | grep -A 5 "conditions:"

# Check specific component status
oc get datasciencecluster default-dsc -o jsonpath='{.status.conditions[?(@.type=="KserveReady")]}'
```

---

## Resource Requirements

### Minimum Configuration (Core Components Only)

- **Nodes**: 2 worker nodes
- **CPU**: 4 vCPU per node (3.5 allocatable)
- **Memory**: 16 GB per node
- **Components**: KServe, Workbenches, Model Controller

**Resource Usage**:
- CPU: ~95% utilization
- Memory: ~70% utilization
- **Dashboard**: Cannot run (insufficient resources)

### Recommended Configuration (Full Installation)

- **Nodes**: 3+ worker nodes
- **CPU**: 8 vCPU per node
- **Memory**: 32 GB per node
- **Components**: All enabled (Dashboard, KServe, Workbenches, Ray, MLflow, etc.)

**Resource Breakdown**:
- Dashboard: ~4 CPU cores (9 containers)
- KServe: ~500m CPU
- Service Mesh: ~500m CPU
- Auth Proxy: ~500m CPU
- Other RHOAI components: ~2 CPU cores
- Platform services: ~2 CPU cores

---

## Post-Installation

### Configure Default Notebook Images

```bash
# List available notebook images
oc get imagestreams -n redhat-ods-applications
```

### Create a Data Science Project

```bash
# Create a namespace for your project
oc create namespace my-datascience-project

# Label it as a data science project
oc label namespace my-datascience-project \
  opendatahub.io/dashboard=true \
  modelmesh-enabled=true
```

### Deploy a Model with KServe

```bash
# Example: Deploy a simple model
cat << 'EOF' | oc apply -f -
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: example-model
  namespace: my-datascience-project
spec:
  predictor:
    model:
      modelFormat:
        name: sklearn
      storageUri: s3://my-bucket/my-model
EOF
```

### Monitor Installation

```bash
# Watch all RHOAI pods
watch oc get pods -n redhat-ods-applications

# Monitor DataScienceCluster events
oc get events -n redhat-ods-applications --sort-by='.lastTimestamp'

# Check operator logs
oc logs -n redhat-ods-operator deployment/rhods-operator
```

### Upgrade Path

To upgrade to a newer version:

```bash
# Update the subscription channel
oc patch subscription rhods-operator -n redhat-ods-operator \
  --type=merge \
  -p '{"spec":{"channel":"stable-3.x"}}'
```

---

## Additional Resources

- [RHOAI Official Documentation](https://access.redhat.com/documentation/en-us/red_hat_openshift_ai_self-managed)
- [Kyverno Documentation](https://kyverno.io/docs/)
- [KServe Documentation](https://kserve.github.io/website/)
- [OpenShift CLI Reference](https://docs.openshift.com/container-platform/latest/cli_reference/openshift_cli/getting-started-cli.html)

---

## Summary

This guide walked through installing RHOAI on ROSA using:

1. **Kyverno** for automatic pull secret distribution
2. **Custom CatalogSource** pointing to the desired RHOAI version (see [Choosing a Version](#choosing-a-version))
3. **DataScienceCluster** for component configuration

Key considerations:
- ROSA HCP requires Kyverno for persistent pull secret management
- Resource requirements vary based on enabled components
- Dashboard requires significant CPU resources (~4 cores)
- Core functionality available without dashboard via CLI/API

For production deployments, ensure adequate cluster resources and consider enabling additional components based on your use case.
