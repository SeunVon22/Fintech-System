#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# Payment Service — Full Deployment & Verification Runbook
# ═══════════════════════════════════════════════════════════════════════════════
#
# Prerequisites:
#   - Azure CLI        : brew install azure-cli  / apt install azure-cli
#   - Terraform        : brew install terraform   / tfenv install 1.7.0
#   - kubectl          : az aks install-cli
#   - Helm             : brew install helm
#   - Docker           : docker.com/get-started
#   - Trivy            : brew install aquasecurity/trivy/trivy
#
# Run sections in order — each section depends on the previous one.
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail   # exit on error, undefined var, or pipe failure

# ── 0. CONFIGURATION ──────────────────────────────────────────────────────────
# Edit these values before running

export PREFIX="monie"
export ENVIRONMENT="dev"                          # dev | staging | prod
export LOCATION="westeurope"
export ACR_NAME="${PREFIX}${ENVIRONMENT}acr"      # must be globally unique
export AKS_NAME="${PREFIX}-${ENVIRONMENT}-aks"
export RESOURCE_GROUP="${PREFIX}-${ENVIRONMENT}-rg"
export K8S_NAMESPACE="payment-service"
export HELM_RELEASE="payment-service"
export IMAGE_TAG=$(git rev-parse --short HEAD)    # uses your current git SHA


# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 1 — AZURE LOGIN & SUBSCRIPTION
# ═══════════════════════════════════════════════════════════════════════════════

echo "▶ Logging in to Azure..."
az login

# List available subscriptions and pick the right one
az account list --output table

# Set your target subscription (replace with your subscription ID)
az account set --subscription "b74d9869-b31c-4a6f-b855-2643b03300ac"

# Confirm active subscription
az account show --output table


# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 2 — TERRAFORM: PROVISION INFRASTRUCTURE
# ═══════════════════════════════════════════════════════════════════════════════

echo "▶ Provisioning infrastructure with Terraform..."
cd payment-service-complete/payment-service/terraform/

# 2a. Create remote state storage (one-time setup — skip if already exists)
az group create \
    --name "tfstate-rg" \
    --location "${LOCATION}"

az storage account create \
    --name "moniepointtfstate" \
    --resource-group "tfstate-rg" \
    --location "${LOCATION}" \
    --sku Standard_LRS \
    --encryption-services blob

az storage container create \
    --name "tfstate" \
    --account-name "moniepointtfstate"

echo "✓ Remote state storage created"

# 2b. Initialise Terraform with remote backend
terraform init \
    -backend-config="resource_group_name=tfstate-rg" \
    -backend-config="storage_account_name=moniepointtfstate" \
    -backend-config="container_name=tfstate" \
    -backend-config="key=payment-service/terraform.tfstate"

# 2c. Validate configuration — catch syntax errors before touching Azure
terraform validate
echo "✓ Terraform configuration is valid"

# 2d. Plan — review what will be created (no changes yet)
terraform plan \
    -var-file="${ENVIRONMENT}.tfvars" \
    -out=tfplan

# !! REVIEW THE PLAN OUTPUT BEFORE PROCEEDING !!
# Check: correct resource names, sizes, CIDRs, and no unexpected destroys

# 2e. Apply — creates AKS cluster, ACR, VNet, role assignments (~10 min)
terraform apply tfplan

# 2f. Capture outputs for use in later sections
export ACR_LOGIN_SERVER=$(terraform output -raw acr_login_server)
export AKS_NAME=$(terraform output -raw aks_cluster_name)
export RESOURCE_GROUP=$(terraform output -raw aks_resource_group)

echo "✓ Infrastructure provisioned"
echo "  ACR: ${ACR_LOGIN_SERVER}"
echo "  AKS: ${AKS_NAME} in ${RESOURCE_GROUP}"

cd ..


# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 3 — BUILD & PUSH DOCKER IMAGE TO ACR
# ═══════════════════════════════════════════════════════════════════════════════

echo "▶ Building and pushing Docker image..."

# 3a. Login to ACR using managed identity (no username/password needed)
az acr login --name "${ACR_NAME}"

# 3b. Build the image (multi-stage build — final image is slim)
export FULL_IMAGE="${ACR_LOGIN_SERVER}/payment-service:${IMAGE_TAG}"

docker build \
    --tag "${FULL_IMAGE}" \
    --tag "${ACR_LOGIN_SERVER}/payment-service:latest" \
    --label "git-commit=${IMAGE_TAG}" \
    --label "build-date=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    .

echo "✓ Image built: ${FULL_IMAGE}"

# 3c. Run tests inside the image before pushing
# This catches any dependency issues in the built image itself
docker run --rm "${FULL_IMAGE}" \
    sh -c "pip install pytest httpx pytest-asyncio -q && pytest app/tests/ -v"

echo "✓ Tests passed inside container"

# 3d. Scan for vulnerabilities with Trivy before pushing
trivy image \
    --exit-code 1 \
    --severity CRITICAL,HIGH \
    --ignore-unfixed \
    "${FULL_IMAGE}"

echo "✓ No critical vulnerabilities found"

# 3e. Push to ACR
docker push "${FULL_IMAGE}"
docker push "${ACR_LOGIN_SERVER}/payment-service:latest"

echo "✓ Image pushed to ACR"

# 3f. Verify the image is in ACR
az acr repository list \
    --name "${ACR_NAME}" \
    --output table

az acr repository show-tags \
    --name "${ACR_NAME}" \
    --repository "payment-service" \
    --output table


# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 4 — CONNECT TO AKS
# ═══════════════════════════════════════════════════════════════════════════════

echo "▶ Connecting to AKS cluster..."

# 4a. Download kubeconfig and merge into ~/.kube/config
az aks get-credentials \
    --name "${AKS_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --overwrite-existing

# 4b. Verify cluster connectivity
kubectl cluster-info
kubectl get nodes -o wide

# Expected output: all nodes in Ready state
# NAME                                STATUS   ROLES    AGE   VERSION
# aks-system-xxxxx-vmss000000         Ready    <none>   5m    v1.29.x
# aks-user-xxxxx-vmss000000           Ready    <none>   4m    v1.29.x

# 4c. Check system pods are healthy
kubectl get pods --namespace kube-system

echo "✓ Connected to AKS cluster"


# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 5 — INSTALL CLUSTER DEPENDENCIES
# ═══════════════════════════════════════════════════════════════════════════════

echo "▶ Installing cluster-level dependencies..."

# 5a. Add Helm repos
helm repo add ingress-nginx    https://kubernetes.github.io/ingress-nginx
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# 5b. Install Nginx Ingress Controller
helm upgrade nginx-ingress ingress-nginx/ingress-nginx \
    --install \
    --namespace ingress-nginx \
    --create-namespace \
    --set controller.replicaCount=2 \
    --set controller.nodeSelector."kubernetes\.io/os"=linux \
    --wait

echo "✓ Nginx Ingress installed"

# 5c. Install kube-prometheus-stack (Prometheus + Grafana + AlertManager)
helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
    --install \
    --namespace monitoring \
    --create-namespace \
    --set grafana.adminPassword="ChangeMe123!" \
    --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
    --wait

echo "✓ Prometheus + Grafana installed"

# 5d. Get the Ingress Controller external IP (may take 2-3 min to provision)
kubectl get service nginx-ingress-ingress-nginx-controller \
    --namespace ingress-nginx \
    --watch


# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 6 — DEPLOY PAYMENT SERVICE WITH HELM
# ═══════════════════════════════════════════════════════════════════════════════

echo "▶ Deploying payment service..."

# 6a. Create namespace
kubectl create namespace "${K8S_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# 6b. Create the DB secret (in production this comes from Vault — this is for dev)
kubectl create secret generic payment-db-secret \
    --namespace "${K8S_NAMESPACE}" \
    --from-literal=password="dev-password-change-in-prod" \
    --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic payment-api-secret \
    --namespace "${K8S_NAMESPACE}" \
    --from-literal=api-key="dev-api-key-change-in-prod" \
    --dry-run=client -o yaml | kubectl apply -f -

# 6c. Helm upgrade / install
helm upgrade "${HELM_RELEASE}" ./helm/payment-service \
    --install \
    --namespace "${K8S_NAMESPACE}" \
    --values ./helm/payment-service/values.yaml \
    --set image.repository="${ACR_LOGIN_SERVER}/payment-service" \
    --set image.tag="${IMAGE_TAG}" \
    --atomic \
    --timeout 5m \
    --wait

echo "✓ Payment service deployed"

# 6d. Check Helm release status
helm status "${HELM_RELEASE}" --namespace "${K8S_NAMESPACE}"
helm history "${HELM_RELEASE}" --namespace "${K8S_NAMESPACE}"


# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 7 — VERIFY THE DEPLOYMENT
# ═══════════════════════════════════════════════════════════════════════════════

echo "▶ Verifying deployment..."

# 7a. Check all pods are Running (should see 3 replicas)
kubectl get pods \
    --namespace "${K8S_NAMESPACE}" \
    --selector "app=payment-service" \
    -o wide

# Expected:
# NAME                               READY   STATUS    RESTARTS   AGE
# payment-service-6d8f9c7b4-abc12    1/1     Running   0          2m
# payment-service-6d8f9c7b4-def34    1/1     Running   0          2m
# payment-service-6d8f9c7b4-ghi56    1/1     Running   0          2m

# 7b. Check Deployment rollout status
kubectl rollout status deployment/"${HELM_RELEASE}-payment-service" \
    --namespace "${K8S_NAMESPACE}"

# 7c. Check all resources in the namespace
kubectl get all --namespace "${K8S_NAMESPACE}"

# 7d. Check HPA is active
kubectl get hpa --namespace "${K8S_NAMESPACE}"

# Expected:
# NAME              REFERENCE                     TARGETS         MINPODS   MAXPODS
# payment-service   Deployment/payment-service    22%/70%, 18%/80%   3        10

# 7e. Check PodDisruptionBudget
kubectl get pdb --namespace "${K8S_NAMESPACE}"

# Expected:
# NAME              MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS
# payment-service   2               N/A               1

# 7f. Check Ingress has an address
kubectl get ingress --namespace "${K8S_NAMESPACE}"

echo "✓ All Kubernetes resources look healthy"


# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 8 — SMOKE TEST THE API
# ═══════════════════════════════════════════════════════════════════════════════

echo "▶ Running smoke tests..."

# 8a. Port-forward for local testing (alternative to hitting the Ingress)
kubectl port-forward \
    svc/"${HELM_RELEASE}-payment-service" 8080:80 \
    --namespace "${K8S_NAMESPACE}" &
PF_PID=$!
sleep 3
echo "Port-forward running (PID: ${PF_PID})"

# 8b. Test liveness probe
echo "Testing /healthz..."
curl --fail --silent --show-error http://localhost:8080/healthz | python3 -m json.tool
# Expected: {"status": "ok", "version": "1.0.0", "timestamp": "..."}

# 8c. Test readiness probe
echo "Testing /readyz..."
curl --fail --silent --show-error http://localhost:8080/readyz | python3 -m json.tool
# Expected: {"status": "ready", "version": "1.0.0", "timestamp": "..."}

# 8d. Test the payment API — completed transaction
echo "Testing completed payment..."
curl --fail --silent --show-error \
    http://localhost:8080/api/v1/payments/TXN-001 | python3 -m json.tool
# Expected: {"transaction_id": "TXN-001", "status": "COMPLETED", "amount": 50000.0, ...}

# 8e. Test the payment API — pending transaction
echo "Testing pending payment..."
curl --fail --silent --show-error \
    http://localhost:8080/api/v1/payments/TXN-002 | python3 -m json.tool

# 8f. Test 404 for unknown transaction
echo "Testing 404 for unknown transaction..."
curl --silent --show-error \
    http://localhost:8080/api/v1/payments/TXN-INVALID
# Expected: {"detail": "Transaction TXN-INVALID not found"}

# 8g. Test Prometheus metrics endpoint
echo "Testing /metrics..."
curl --silent http://localhost:8080/metrics | grep payment_requests_total
# Expected: payment_requests_total{...} N

# 8h. Kill port-forward
kill $PF_PID
echo "✓ All smoke tests passed"


# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 9 — OBSERVABILITY VERIFICATION
# ═══════════════════════════════════════════════════════════════════════════════

echo "▶ Verifying observability..."

# 9a. Check ServiceMonitor was created (Prometheus will auto-discover this)
kubectl get servicemonitor \
    --namespace "${K8S_NAMESPACE}"

# 9b. Access Grafana dashboard locally
kubectl port-forward \
    svc/kube-prometheus-stack-grafana 3000:80 \
    --namespace monitoring &
echo "Grafana: http://localhost:3000 (admin / ChangeMe123!)"

# 9c. Access Prometheus UI locally
kubectl port-forward \
    svc/kube-prometheus-stack-prometheus 9090:9090 \
    --namespace monitoring &
echo "Prometheus: http://localhost:9090"

# 9d. Useful PromQL queries to run in Prometheus UI:
cat <<'EOF'

── PromQL queries for the payment service ────────────────────────────────────

# Request rate (requests per second over last 5 min)
rate(payment_requests_total[5m])

# 99th percentile latency
histogram_quantile(0.99, rate(payment_request_duration_seconds_bucket[5m]))

# Error rate (non-2xx responses)
rate(payment_requests_total{status_code!~"2.."}[5m])

# Payment status breakdown
payment_status_lookups_total

# Pod CPU usage
rate(container_cpu_usage_seconds_total{namespace="payment-service"}[5m])

# Pod memory usage
container_memory_working_set_bytes{namespace="payment-service"}

───────────────────────────────────────────────────────────────────────────────
EOF


# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 10 — SIMULATE REAL SCENARIOS (INTERVIEW GOLD)
# ═══════════════════════════════════════════════════════════════════════════════

echo "▶ Simulating real operational scenarios..."

# ── Scenario A: Rolling update (new image version) ────────────────────────────
echo "Scenario A: Rolling update..."
export NEW_TAG="v1.0.1"

helm upgrade "${HELM_RELEASE}" ./helm/payment-service \
    --namespace "${K8S_NAMESPACE}" \
    --reuse-values \
    --set image.tag="${NEW_TAG}" \
    --atomic \
    --timeout 5m

# Watch the rolling update happen in real time
kubectl rollout status deployment/"${HELM_RELEASE}-payment-service" \
    --namespace "${K8S_NAMESPACE}"

# ── Scenario B: Rollback ──────────────────────────────────────────────────────
echo "Scenario B: Rollback to previous version..."

# View history
helm history "${HELM_RELEASE}" --namespace "${K8S_NAMESPACE}"

# Roll back to previous release
helm rollback "${HELM_RELEASE}" 0 \
    --namespace "${K8S_NAMESPACE}" \
    --wait

# Verify rollback
kubectl get pods --namespace "${K8S_NAMESPACE}"

# ── Scenario C: Simulate node drain (tests PDB) ───────────────────────────────
echo "Scenario C: Node drain — verifying PDB protects the service..."

# Get a worker node name
NODE=$(kubectl get nodes --selector '!node-role.kubernetes.io/control-plane' \
    -o jsonpath='{.items[0].metadata.name}')

echo "Draining node: ${NODE}"

# Drain the node (PDB will ensure minAvailable=2 pods stay running)
kubectl drain "${NODE}" \
    --ignore-daemonsets \
    --delete-emptydir-data \
    --grace-period=30

# Check pods redistributed to remaining nodes
kubectl get pods --namespace "${K8S_NAMESPACE}" -o wide

# Uncordon the node after verification
kubectl uncordon "${NODE}"

# ── Scenario D: Check pod logs ────────────────────────────────────────────────
echo "Scenario D: Viewing structured logs..."

# Stream logs from all pods in the deployment
kubectl logs \
    --selector "app=payment-service" \
    --namespace "${K8S_NAMESPACE}" \
    --follow \
    --tail=50

# ── Scenario E: Exec into a pod for debugging ─────────────────────────────────
echo "Scenario E: Interactive debugging..."

POD=$(kubectl get pods \
    --selector "app=payment-service" \
    --namespace "${K8S_NAMESPACE}" \
    -o jsonpath='{.items[0].metadata.name}')

# Note: readOnlyRootFilesystem=true means you can't write to disk
# but you can still inspect the running process
kubectl exec -it "${POD}" \
    --namespace "${K8S_NAMESPACE}" \
    -- sh -c "ps aux && env | grep -v SECRET"


# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 11 — CLEANUP (run when done to avoid Azure costs)
# ═══════════════════════════════════════════════════════════════════════════════

cleanup() {
    echo "▶ Cleaning up resources..."

    # Remove Helm release
    helm uninstall "${HELM_RELEASE}" --namespace "${K8S_NAMESPACE}"

    # Destroy all Azure infrastructure
    cd terraform
    terraform destroy \
        -var-file="${ENVIRONMENT}.tfvars" \
        -auto-approve
    cd ..

    echo "✓ All resources destroyed"
}

# Uncomment to run cleanup:
# cleanup

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  Deployment complete! Your service is running on AKS."
echo "  Image: ${FULL_IMAGE}"
echo "  Namespace: ${K8S_NAMESPACE}"
echo "═══════════════════════════════════════════════════════════"
