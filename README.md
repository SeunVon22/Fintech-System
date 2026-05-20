# Payment Status Service

[![Build Status](https://img.shields.io/badge/build-passing-brightgreen)](https://jenkins.internal/job/payment-service)
[![Coverage](https://img.shields.io/badge/coverage-92%25-brightgreen)](https://sonarqube.internal/dashboard?id=payment-service)
[![Kubernetes](https://img.shields.io/badge/kubernetes-1.29-blue)](https://kubernetes.io)
[![Helm](https://img.shields.io/badge/helm-3.x-blue)](https://helm.sh)
[![Terraform](https://img.shields.io/badge/terraform-1.7-purple)](https://terraform.io)
[![License](https://img.shields.io/badge/license-MIT-lightgrey)](LICENSE)

A production-grade microservice for querying payment transaction status, built for deployment on **Azure Kubernetes Service (AKS)**. Includes a full CI/CD pipeline (Jenkins), Infrastructure-as-Code (Terraform), Helm packaging, Prometheus observability, and a hardened Docker image.

> Built as a hands-on portfolio project demonstrating Senior Cloud & DevOps Engineering practices aligned with a fintech production environment.

---

## Table of Contents

- [Architecture](#architecture)
- [Project Structure](#project-structure)
- [Prerequisites](#prerequisites)
- [Quick Start — Run Locally](#quick-start--run-locally)
- [Running Tests](#running-tests)
- [Docker Build & Scan](#docker-build--scan)
- [Infrastructure Provisioning (Terraform)](#infrastructure-provisioning-terraform)
- [Deploy to AKS (Helm)](#deploy-to-aks-helm)
- [CI/CD Pipeline (Jenkins)](#cicd-pipeline-jenkins)
- [Observability](#observability)
- [Operational Runbook](#operational-runbook)
- [Design Decisions](#design-decisions)
- [Contributing](#contributing)

---

## Architecture

```
Developer → GitHub (push) → Jenkins Pipeline
                                │
                    ┌───────────┴────────────┐
                    │                        │
               Test + Scan              Terraform Plan
                    │
              Docker Build
                    │
              Trivy CVE Scan
                    │
             Push to ACR
                    │
          Helm Deploy → Staging
                    │
           Smoke Tests pass?
                    │
         Manual Approval Gate
                    │
          Helm Deploy → Prod
                    │
           AKS (3+ replicas)
          ┌────────────────────┐
          │  Nginx Ingress     │
          │  Service (ClusterIP│
          │  Deployment        │
          │  HPA (3–10 pods)   │
          │  PodDisruptionBudget│
          │  ServiceMonitor    │
          └────────────────────┘
                    │
         Prometheus + Grafana
```

**Key components:**

| Layer | Technology | Purpose |
|---|---|---|
| API | FastAPI (Python) | Payment status REST API |
| Container | Docker (multi-stage) | Hardened, non-root image |
| Registry | Azure Container Registry | Private image store |
| Orchestration | AKS (Kubernetes 1.29) | Pod scheduling and scaling |
| Packaging | Helm 3 | Kubernetes manifest templating |
| Infrastructure | Terraform 1.7 | AKS, ACR, VNet provisioning |
| CI/CD | Jenkins (K8s agent) | 10-stage pipeline |
| Ingress | Nginx Ingress Controller | TLS termination, rate limiting |
| Autoscaling | HPA | CPU + memory-based pod scaling |
| Observability | Prometheus + Grafana | Metrics, dashboards, alerts |
| Security scanning | Trivy + SonarQube | CVE and SAST scanning |

---

## Project Structure

```
payment-service/
├── app/
│   ├── main.py                  # FastAPI application
│   ├── requirements.txt         # Python dependencies
│   └── tests/
│       └── test_main.py         # pytest integration tests
├── helm/
│   └── payment-service/
│       ├── Chart.yaml           # Helm chart metadata
│       ├── values.yaml          # Default configuration values
│       ├── values.prod.yaml     # Production overrides
│       └── templates/
│           ├── _helpers.tpl     # Helm helper functions
│           ├── deployment.yaml  # Deployment, security context, probes
│           └── service.yaml     # Service, Ingress, HPA, PDB, ServiceMonitor
├── terraform/
│   ├── main.tf                  # AKS, ACR, VNet, role assignments
│   ├── variables.tf             # Input variable definitions
│   ├── locals.tf                # Common tags and locals
│   ├── dev.tfvars               # Dev environment values
│   └── prod.tfvars              # Production environment values
├── jenkins/
│   ├── Jenkinsfile              # 10-stage declarative pipeline
│   └── SETUP.md                 # Jenkins credentials and plugin guide
├── deploy.sh                    # Full deployment and verification runbook
├── Dockerfile                   # Multi-stage, non-root, hardened
└── .dockerignore
```

---

## Prerequisites

| Tool | Version | Install |
|---|---|---|
| Python | 3.11+ | [python.org](https://python.org) |
| Docker | 24+ | [docker.com](https://docker.com/get-started) |
| Azure CLI | latest | `brew install azure-cli` |
| Terraform | 1.7+ | `brew install terraform` |
| kubectl | 1.29+ | `az aks install-cli` |
| Helm | 3.x | `brew install helm` |
| Trivy | latest | `brew install aquasecurity/trivy/trivy` |

---

## Quick Start — Run Locally

```bash
# 1. Clone the repo
git clone https://github.com/your-username/payment-service.git
cd payment-service

# 2. Create a virtual environment
python3 -m venv .venv
source .venv/bin/activate          # Windows: .venv\Scripts\activate

# 3. Install dependencies
pip install -r app/requirements.txt

# 4. Run the service
uvicorn app.main:app --reload --port 8000

# 5. Open the interactive API docs
open http://localhost:8000/docs
```

**Sample API calls:**

```bash
# Check service health
curl http://localhost:8000/healthz

# Get payment status
curl http://localhost:8000/api/v1/payments/TXN-001

# List all transactions
curl http://localhost:8000/api/v1/payments

# View Prometheus metrics
curl http://localhost:8000/metrics
```

**Available test transactions:**

| Transaction ID | Status | Amount (NGN) |
|---|---|---|
| TXN-001 | COMPLETED | 50,000.00 |
| TXN-002 | PENDING | 12,500.00 |
| TXN-003 | FAILED | 8,750.00 |
| TXN-004 | PROCESSING | 200,000.00 |
| TXN-005 | REVERSED | 35,000.00 |

---

## Running Tests

```bash
# Run all tests with coverage
pytest app/tests/ -v \
  --cov=app \
  --cov-report=term-missing \
  --cov-fail-under=80

# Run a single test
pytest app/tests/test_main.py::test_get_completed_payment -v
```

Tests cover: liveness/readiness probes, Prometheus metrics endpoint, all payment statuses, case-insensitive IDs, and 404 handling.

---

## Docker Build & Scan

```bash
# Build the image
docker build -t payment-service:local .

# Scan for vulnerabilities (must pass before pushing)
trivy image --severity CRITICAL,HIGH --ignore-unfixed payment-service:local

# Run the container locally
docker run -p 8000:8000 payment-service:local

# Inspect the image layers (validate multi-stage build size)
docker history payment-service:local
```

The Dockerfile uses a multi-stage build: a builder stage installs dependencies, and the final runtime stage copies only the installed packages — no build tools, no pip, no shell in the final image. The container runs as a non-root user (`uid=1001`).

---

## Infrastructure Provisioning (Terraform)

```bash
cd terraform

# 1. One-time: create remote state storage
az group create --name tfstate-rg --location westeurope
az storage account create --name moniepointtfstate \
    --resource-group tfstate-rg --sku Standard_LRS
az storage container create --name tfstate \
    --account-name moniepointtfstate

# 2. Initialise with remote backend
terraform init \
  -backend-config="resource_group_name=tfstate-rg" \
  -backend-config="storage_account_name=moniepointtfstate" \
  -backend-config="container_name=tfstate" \
  -backend-config="key=payment-service/terraform.tfstate"

# 3. Plan (dev environment)
terraform plan -var-file="dev.tfvars" -out=tfplan

# 4. Apply (~10 minutes)
terraform apply tfplan

# 5. View outputs
terraform output
```

Terraform provisions: Resource Group, Virtual Network, Azure Container Registry, AKS cluster (system + user node pools), Log Analytics Workspace, and all required role assignments (AcrPull, Network Contributor).

State is stored remotely in Azure Blob Storage with automatic locking — safe for team use.

---

## Deploy to AKS (Helm)

```bash
# 1. Get AKS credentials
az aks get-credentials \
  --name monie-dev-aks \
  --resource-group monie-dev-rg

# 2. Install Nginx Ingress Controller
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm upgrade nginx-ingress ingress-nginx/ingress-nginx \
  --install --namespace ingress-nginx --create-namespace --wait

# 3. Install Prometheus + Grafana
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm upgrade kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  --install --namespace monitoring --create-namespace \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --wait

# 4. Create namespace and secrets
kubectl create namespace payment-service
kubectl create secret generic payment-db-secret \
  --namespace payment-service \
  --from-literal=password="your-db-password"

# 5. Deploy the service
export IMAGE_TAG=$(git rev-parse --short HEAD)
export ACR_SERVER=$(terraform output -raw acr_login_server)

helm upgrade payment-service ./helm/payment-service \
  --install \
  --namespace payment-service \
  --values ./helm/payment-service/values.yaml \
  --set image.repository="${ACR_SERVER}/payment-service" \
  --set image.tag="${IMAGE_TAG}" \
  --atomic --timeout 5m --wait

# 6. Verify
kubectl get pods --namespace payment-service
kubectl get hpa  --namespace payment-service
kubectl get pdb  --namespace payment-service
```

For full step-by-step deployment including smoke tests and operational scenarios, see [`deploy.sh`](deploy.sh).

---

## CI/CD Pipeline (Jenkins)

The Jenkinsfile defines a 10-stage declarative pipeline:

| Stage | What it does | Fails pipeline if... |
|---|---|---|
| Checkout | Clone repo, capture git metadata | Repo unreachable |
| Test | pytest with 80% coverage threshold | Any test fails or coverage drops |
| Code Quality | SonarQube SAST scan | Quality Gate not met |
| Build & Push | Multi-stage Docker build → ACR | Build error |
| Security Scan | Trivy CVE scan | CRITICAL or HIGH CVE found |
| Terraform Plan | Show infra changes (no apply) | Plan syntax error |
| Deploy to Staging | Helm upgrade with `--atomic` | Pods fail readiness within 5min |
| Smoke Test | Hit /healthz, /readyz, API endpoint | Any curl returns non-200 |
| Approval Gate | Manual sign-off (platform leads only) | Approver selects Abort |
| Deploy to Prod | Helm upgrade with prod values | Pods fail readiness within 10min |

Setup instructions for Jenkins credentials and plugins: [`jenkins/SETUP.md`](jenkins/SETUP.md).

---

## Observability

**Prometheus metrics** (exposed at `/metrics`):

| Metric | Type | Description |
|---|---|---|
| `payment_requests_total` | Counter | Total requests by method, endpoint, status code |
| `payment_request_duration_seconds` | Histogram | Request latency per endpoint |
| `payment_status_lookups_total` | Counter | Payment lookups by result status |

**Useful PromQL queries:**

```promql
# Request rate
rate(payment_requests_total[5m])

# 99th percentile latency
histogram_quantile(0.99, rate(payment_request_duration_seconds_bucket[5m]))

# Error rate
rate(payment_requests_total{status_code!~"2.."}[5m])
```

**Access dashboards locally:**

```bash
# Grafana (admin / ChangeMe123!)
kubectl port-forward svc/kube-prometheus-stack-grafana \
  3000:80 --namespace monitoring

# Prometheus
kubectl port-forward svc/kube-prometheus-stack-prometheus \
  9090:9090 --namespace monitoring
```

---

## Operational Runbook

**Check pod health:**
```bash
kubectl get pods -n payment-service
kubectl describe pod <pod-name> -n payment-service
kubectl logs <pod-name> -n payment-service --tail=100
```

**Rolling update (new image):**
```bash
helm upgrade payment-service ./helm/payment-service \
  --namespace payment-service \
  --reuse-values \
  --set image.tag=<new-tag> \
  --atomic --timeout 5m
```

**Rollback to previous version:**
```bash
helm history payment-service --namespace payment-service
helm rollback payment-service 0 --namespace payment-service --wait
```

**Pod is stuck Pending — diagnose:**
```bash
kubectl describe pod <pod-name> -n payment-service
# Check Events section for: Insufficient CPU/memory, taint mismatch,
# PVC binding failure, or image pull error
kubectl get nodes
kubectl describe node <node-name> | grep -A5 "Allocated resources"
```

**Scale manually (bypass HPA temporarily):**
```bash
kubectl scale deployment payment-service-payment-service \
  --replicas=6 --namespace payment-service
```

---

## Design Decisions

**Why two node pools (system + user)?**
System pods (CoreDNS, metrics-server, CNI) run on a dedicated tainted pool. Application pods can never starve cluster infrastructure of resources — critical for network stability in a payment system.

**Why `--atomic` on Helm deploys?**
If new pods fail their readiness probe within the timeout, Helm automatically rolls back to the last good release. Without this, a bad deploy leaves the cluster in a half-upgraded state.

**Why git SHA as the image tag?**
Every running pod's image tag maps to an exact commit in GitHub. At 2am when something breaks in production, you know exactly what code is running and what changed.

**Why PodDisruptionBudget with `minAvailable: 2`?**
During node drain (cluster upgrades, spot evictions), Kubernetes checks the PDB before evicting pods. If eviction would drop below 2 running pods, it waits. Zero-downtime operations in a fintech cluster depend on this.

**Why managed identity instead of service principal?**
No credentials to rotate, no secrets to store, no expiry dates to track. The `AcrPull` role assignment on ACR lets AKS pull images automatically via Azure AD — no `imagePullSecrets` in manifests.

---

## Contributing

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/my-change`
3. Make your changes and ensure tests pass: `pytest app/tests/ -v`
4. Run Trivy scan: `trivy image --severity CRITICAL,HIGH payment-service:local`
5. Open a pull request — Jenkins will run the full pipeline on your PR

---

*Maintained by Oluwaseun Vaughan — pascalvaughan@gmail.com*
