#!/bin/bash

################################################################################
# Red Hat OpenShift AI Installation Script for ROSA
#
# This script automates the installation of RHOAI on ROSA clusters using
# Kyverno for pull secret management.
#
# Usage:
#   ./install-rhoai.sh [OPTIONS]
#
# Options:
#   --catalog-image IMAGE    Custom catalog image (default: quay.io/rhoai/rhoai-fbc-fragment:rhoai-3.4)
#   --docker-config PATH     Path to docker config.json (default: ~/.docker/config.json)
#   --skip-kyverno          Skip Kyverno installation if already installed
#   --minimal               Install with minimal components (saves resources)
#   --wait                  Wait until DataScienceCluster is ready before exiting
#   --help                  Show this help message
#
# Example:
#   ./install-rhoai.sh
#   ./install-rhoai.sh --catalog-image quay.io/rhoai/rhoai-fbc-fragment:rhoai-3.5
#   ./install-rhoai.sh --minimal
#
################################################################################

set -e  # Exit on error
set -o pipefail  # Exit on pipe failure

################################################################################
# Configuration
################################################################################

# Default values
CATALOG_IMAGE="${CATALOG_IMAGE:-quay.io/rhoai/rhoai-fbc-fragment:rhoai-3.4}"
DOCKER_CONFIG="${DOCKER_CONFIG:-$HOME/.docker/config.json}"
SKIP_KYVERNO="${SKIP_KYVERNO:-false}"
MINIMAL_INSTALL="${MINIMAL_INSTALL:-false}"
WAIT_READY="${WAIT_READY:-false}"
OPERATOR_NAMESPACE="redhat-ods-operator"
PULL_SECRET_NAME="pull-secret-brew"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

################################################################################
# Helper Functions
################################################################################

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

usage() {
    grep '^#' "$0" | grep -v '#!/bin/bash' | sed 's/^# \?//'
    exit 0
}

check_command() {
    if ! command -v "$1" &> /dev/null; then
        log_error "Required command '$1' not found. Please install it and try again."
        exit 1
    fi
}

wait_for_condition() {
    local resource=$1
    local condition=$2
    local timeout=$3
    local namespace=$4

    log_info "Waiting for $resource to be $condition (timeout: ${timeout}s)..."

    local ns_flag=""
    if [ -n "$namespace" ]; then
        ns_flag="-n $namespace"
    fi

    if oc wait --for="$condition" $resource $ns_flag --timeout="${timeout}s" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

################################################################################
# Parse Arguments
################################################################################

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --catalog-image)
                CATALOG_IMAGE="$2"
                shift 2
                ;;
            --docker-config)
                DOCKER_CONFIG="$2"
                shift 2
                ;;
            --skip-kyverno)
                SKIP_KYVERNO=true
                shift
                ;;
            --minimal)
                MINIMAL_INSTALL=true
                shift
                ;;
            --wait)
                WAIT_READY=true
                shift
                ;;
            --help)
                usage
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                ;;
        esac
    done
}

################################################################################
# Step 1: Prerequisites Check
################################################################################

check_prerequisites() {
    log_info "Checking prerequisites..."

    # Check required commands
    check_command "oc"
    check_command "jq"

    # Check cluster access
    if ! oc whoami &> /dev/null; then
        log_error "Not logged into OpenShift cluster. Please run 'oc login' first."
        exit 1
    fi

    log_info "Logged in as: $(oc whoami)"

    # Check cluster admin permissions
    if ! oc auth can-i '*' '*' --all-namespaces &> /dev/null; then
        log_warn "You may not have cluster-admin permissions. Installation may fail."
    fi

    # Check docker config exists
    if [ ! -f "$DOCKER_CONFIG" ]; then
        log_error "Docker config not found at: $DOCKER_CONFIG"
        log_error "Please specify the correct path with --docker-config"
        exit 1
    fi

    # Check for existing installations
    log_info "Checking for existing RHOAI/ODH installations..."
    if oc get csv -A 2>/dev/null | grep -E 'opendatahub|rhods' | grep -v NAME; then
        log_error "Existing RHOAI/ODH installation found. Please remove it before proceeding."
        exit 1
    fi

    log_success "Prerequisites check passed"
}

################################################################################
# Step 2: Create Pull Secret
################################################################################

create_pull_secret() {
    log_info "Creating pull secret in openshift-config namespace..."

    # Check if secret already exists
    if oc get secret "$PULL_SECRET_NAME" -n openshift-config &> /dev/null; then
        log_warn "Pull secret already exists. Skipping creation."
        return 0
    fi

    oc create secret generic "$PULL_SECRET_NAME" \
        --from-file=.dockerconfigjson="$DOCKER_CONFIG" \
        --type=kubernetes.io/dockerconfigjson \
        -n openshift-config

    log_success "Pull secret created"
}

################################################################################
# Step 3: Install Kyverno
################################################################################

install_kyverno() {
    if [ "$SKIP_KYVERNO" = true ]; then
        log_info "Skipping Kyverno installation (--skip-kyverno specified)"
        return 0
    fi

    log_info "Installing Kyverno..."

    # Check if Kyverno is already installed
    if oc get namespace kyverno &> /dev/null; then
        log_warn "Kyverno namespace already exists. Skipping installation."
        return 0
    fi

    # Install Kyverno
    oc apply -f https://github.com/kyverno/kyverno/releases/latest/download/install.yaml 2>&1 | \
        grep -v "metadata.annotations: Too long" || true

    log_info "Creating minimal CRDs for ClusterPolicy and Policy..."

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

    # Wait for Kyverno pods to start
    log_info "Waiting for Kyverno pods to start..."
    sleep 15

    # Restart admission controller if it's crashing
    if oc get pods -n kyverno -l app.kubernetes.io/component=admission-controller 2>/dev/null | grep -q CrashLoopBackOff; then
        log_warn "Admission controller in CrashLoopBackOff. Restarting..."
        oc delete pod -n kyverno -l app.kubernetes.io/component=admission-controller
        sleep 10
    fi

    # Wait for all Kyverno pods to be ready
    if ! wait_for_condition "pod -l app.kubernetes.io/part-of=kyverno" "condition=ready" 120 "kyverno"; then
        log_warn "Some Kyverno pods may not be ready yet, but continuing..."
    fi

    log_success "Kyverno installed"
}

################################################################################
# Step 4: Configure Kyverno Policies
################################################################################

configure_kyverno_policies() {
    log_info "Configuring Kyverno RBAC and policies..."

    # Create RBAC for secret generation
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

    # Create secret sync policy
    cat << EOF | oc apply -f -
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
      name: $PULL_SECRET_NAME
      namespace: "{{request.object.metadata.name}}"
      synchronize: true
      clone:
        namespace: openshift-config
        name: $PULL_SECRET_NAME
EOF

    # Create imagePullSecret injection policy
    cat << EOF | oc apply -f -
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
          - name: $PULL_SECRET_NAME
EOF

    log_success "Kyverno policies configured"
}

################################################################################
# Step 5: Create CatalogSource
################################################################################

create_catalog_source() {
    log_info "Creating RHOAI CatalogSource with image: $CATALOG_IMAGE"

    # Create operator namespace
    if ! oc get namespace "$OPERATOR_NAMESPACE" &> /dev/null; then
        oc create namespace "$OPERATOR_NAMESPACE"
    fi

    # Manually copy secret to openshift-marketplace
    log_info "Copying pull secret to openshift-marketplace..."
    oc get secret "$PULL_SECRET_NAME" -n openshift-config -o yaml | \
        sed "s/namespace: openshift-config/namespace: openshift-marketplace/" | \
        oc apply -f - || true

    # Create CatalogSource
    cat << EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: rhoai-catalog
  namespace: openshift-marketplace
spec:
  sourceType: grpc
  image: $CATALOG_IMAGE
  displayName: Red Hat OpenShift AI
  publisher: Red Hat
  updateStrategy:
    registryPoll:
      interval: 10m
  secrets:
  - $PULL_SECRET_NAME
EOF

    log_info "Waiting for CatalogSource to be ready..."
    sleep 20

    # Wait for catalog to be ready
    if ! wait_for_condition "catalogsource/rhoai-catalog" "jsonpath={.status.connectionState.lastObservedState}=READY" 180 "openshift-marketplace"; then
        log_warn "CatalogSource may not be ready yet. Checking pod status..."
        oc get pods -n openshift-marketplace | grep rhoai-catalog || true
    fi

    log_success "CatalogSource created"
}

################################################################################
# Step 6: Install RHOAI Operator
################################################################################

install_rhoai_operator() {
    log_info "Installing RHOAI Operator..."

    # Create OperatorGroup and Subscription
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

    log_info "Waiting for operator CSV to be ready (this may take several minutes)..."

    # Wait for CSV to be created and succeed
    local timeout=600
    local elapsed=0
    local interval=10

    while [ $elapsed -lt $timeout ]; do
        if oc get csv -n "$OPERATOR_NAMESPACE" 2>/dev/null | grep -q rhods-operator; then
            log_info "CSV found, waiting for Succeeded phase..."
            if wait_for_condition "csv -l operators.coreos.com/rhods-operator.redhat-ods-operator" "jsonpath={.status.phase}=Succeeded" 300 "$OPERATOR_NAMESPACE"; then
                break
            fi
        fi
        sleep $interval
        elapsed=$((elapsed + interval))
        log_info "Still waiting for CSV... (${elapsed}s/${timeout}s)"
    done

    # Verify installation
    local csv_name=$(oc get csv -n "$OPERATOR_NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -n "$csv_name" ]; then
        local version=$(oc get csv "$csv_name" -n "$OPERATOR_NAMESPACE" -o jsonpath='{.spec.version}')
        log_success "RHOAI Operator installed: $csv_name (version: $version)"
    else
        log_error "Failed to install RHOAI Operator"
        exit 1
    fi
}

################################################################################
# Step 7: Create DataScienceCluster
################################################################################

create_datasciencecluster() {
    log_info "Creating DataScienceCluster..."

    if [ "$MINIMAL_INSTALL" = true ]; then
        log_info "Creating minimal configuration (Dashboard, KServe, Workbenches only)..."

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
      managementState: Removed
    dashboard:
      managementState: Managed
    feastoperator:
      managementState: Removed
    kserve:
      managementState: Managed
      nim:
        managementState: Managed
      wva:
        managementState: Removed
    kueue:
      managementState: Removed
    llamastackoperator:
      managementState: Removed
    mlflowoperator:
      managementState: Removed
    modelregistry:
      managementState: Removed
    ray:
      managementState: Removed
    sparkoperator:
      managementState: Removed
    trainer:
      managementState: Removed
    trainingoperator:
      managementState: Removed
    trustyai:
      managementState: Removed
    workbenches:
      managementState: Managed
EOF
    else
        log_info "Creating full configuration with all components..."

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
    fi

    log_success "DataScienceCluster created"
}

################################################################################
# Step 8: Wait for Components
################################################################################

wait_for_components() {
    log_info "Waiting for RHOAI components to deploy..."

    # Give components time to start deploying
    sleep 30

    # Reduce resource usage in minimal mode
    if [ "$MINIMAL_INSTALL" = true ]; then
        log_info "Reducing resource usage (minimal mode)..."

        # Scale operator to 1 replica
        oc scale deployment rhods-operator -n "$OPERATOR_NAMESPACE" --replicas=1

        # Wait for dashboard deployment to be created
        local wait_elapsed=0
        while [ $wait_elapsed -lt 120 ]; do
            if oc get deployment rhods-dashboard -n redhat-ods-applications &> /dev/null; then
                break
            fi
            sleep 10
            wait_elapsed=$((wait_elapsed + 10))
        done

        if oc get deployment rhods-dashboard -n redhat-ods-applications &> /dev/null; then
            log_info "Scaling dashboard to 1 replica..."
            oc scale deployment rhods-dashboard -n redhat-ods-applications --replicas=1

            log_info "Reducing dashboard container resource requests..."
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
        fi
    fi

    log_info "Current pod status:"
    oc get pods -n redhat-ods-applications 2>/dev/null || log_warn "No pods found yet in redhat-ods-applications"

    if [ "$WAIT_READY" = true ]; then
        log_info "Waiting for DataScienceCluster to be ready (timeout: 600s)..."
        local wait_elapsed=0
        local timeout=600
        while [ $wait_elapsed -lt $timeout ]; do
            local phase=$(oc get datasciencecluster default-dsc -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
            if [ "$phase" = "Ready" ]; then
                log_success "DataScienceCluster is ready!"
                return 0
            fi
            sleep 15
            wait_elapsed=$((wait_elapsed + 15))
            log_info "DataScienceCluster phase: $phase (${wait_elapsed}s/${timeout}s)"
        done
        log_error "DataScienceCluster did not become ready within ${timeout}s"
        oc get datasciencecluster default-dsc -o jsonpath='{range .status.conditions[?(@.status=="False")]}{.type}: {.message}{"\n"}{end}' 2>/dev/null
        exit 1
    else
        local phase=$(oc get datasciencecluster default-dsc -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
        log_info "DataScienceCluster phase: $phase"
        if [ "$phase" = "Ready" ]; then
            log_success "All components are ready!"
        else
            log_warn "DataScienceCluster is not fully ready yet."
            log_info "Run with --wait to wait for readiness, or monitor with:"
            echo "  oc get pods -n redhat-ods-applications -w"
        fi
    fi
}

################################################################################
# Step 9: Display Results
################################################################################

display_results() {
    echo ""
    echo "============================================"
    echo "RHOAI Installation Complete"
    echo "============================================"
    echo ""

    # Get operator version
    local csv_name=$(oc get csv -n "$OPERATOR_NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "Unknown")
    local version=$(oc get csv -n "$OPERATOR_NAMESPACE" -o jsonpath='{.items[0].spec.version}' 2>/dev/null || echo "Unknown")

    echo "Operator: $csv_name"
    echo "Version: $version"
    echo "Catalog Image: $CATALOG_IMAGE"
    echo ""

    # Display component status
    echo "Component Status:"
    oc get datasciencecluster default-dsc -o jsonpath='{.status.phase}' 2>/dev/null | \
        awk '{print "  DataScienceCluster: " $0}' || echo "  DataScienceCluster: Unknown"

    echo ""
    echo "Running Pods:"
    oc get pods -n redhat-ods-applications 2>/dev/null | grep -E "NAME|Running" || echo "  No running pods yet"

    # Check for dashboard route
    echo ""
    if oc get route rhods-dashboard -n redhat-ods-applications &> /dev/null; then
        local dashboard_url=$(oc get route rhods-dashboard -n redhat-ods-applications -o jsonpath='{.spec.host}')
        echo "Dashboard URL: https://$dashboard_url"
    else
        echo "Dashboard: Not yet available"
    fi

    echo ""
    echo "Kyverno Policies:"
    oc get clusterpolicy 2>/dev/null || echo "  No policies found"

    echo ""
    echo "============================================"
    echo "Useful Commands:"
    echo "============================================"
    echo "  # Watch pod deployment"
    echo "  oc get pods -n redhat-ods-applications -w"
    echo ""
    echo "  # Check DataScienceCluster status"
    echo "  oc get datasciencecluster default-dsc"
    echo ""
    echo "  # View operator logs"
    echo "  oc logs -n $OPERATOR_NAMESPACE deployment/rhods-operator -f"
    echo ""
    echo "  # Check component conditions"
    echo "  oc get datasciencecluster default-dsc -o yaml | grep -A 5 conditions"
    echo ""

    if [ "$MINIMAL_INSTALL" = true ]; then
        echo "Note: Minimal installation was performed."
        echo "To enable additional components, edit the DataScienceCluster:"
        echo "  oc edit datasciencecluster default-dsc"
        echo ""
    fi
}

################################################################################
# Main Execution
################################################################################

main() {
    echo ""
    echo "============================================"
    echo "RHOAI Installation Script for ROSA"
    echo "============================================"
    echo ""

    # Parse command line arguments
    parse_args "$@"

    # Display configuration
    log_info "Configuration:"
    echo "  Catalog Image: $CATALOG_IMAGE"
    echo "  Docker Config: $DOCKER_CONFIG"
    echo "  Skip Kyverno: $SKIP_KYVERNO"
    echo "  Minimal Install: $MINIMAL_INSTALL"
    echo "  Wait for Ready: $WAIT_READY"
    echo ""

    # Execute installation steps
    check_prerequisites
    create_pull_secret
    install_kyverno
    configure_kyverno_policies
    create_catalog_source
    install_rhoai_operator
    create_datasciencecluster
    wait_for_components
    display_results

    echo ""
    log_success "Installation process completed!"
    echo ""
}

# Run main function
main "$@"
