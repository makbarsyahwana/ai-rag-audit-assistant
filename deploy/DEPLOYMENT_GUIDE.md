# AI RAG Audit Assistant — Deployment Guide

This guide covers local development, staging, and production deployments across Google Cloud Platform (GCP) and Amazon Web Services (AWS).  # noqa: E999

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Prerequisites](#prerequisites)
3. [Local Development (Docker Compose)](#local-development)
4. [Staging — GCP Cloud Run](#staging-gcp-cloud-run)
5. [Staging — AWS ECS Fargate](#staging-aws-ecs-fargate)
6. [Production — GKE Autopilot (Helm)](#production-gke-autopilot)
7. [Production — EKS (Helm)](#production-eks)
8. [CI/CD with Concourse](#cicd-with-concourse)
9. [Secrets Management](#secrets-management)
10. [Monitoring & Observability](#monitoring--observability)
11. [Rollback Procedures](#rollback-procedures)
12. [Troubleshooting](#troubleshooting)

---

## Architecture Overview

```
┌──────────────┐     ┌──────────────────┐     ┌──────────────────┐
│  UI (Next.js)│────▶│  API (NestJS)    │────▶│  RAG Engine      │
│  Port 3000   │     │  Port 8000       │     │  (FastAPI) 8100  │
└──────────────┘     └──────────────────┘     └──────────────────┘
                            │                        │
                            ▼                        ▼
                     ┌────────────┐          ┌──────────────┐
                     │ PostgreSQL │          │ Neo4j / Mongo│
                     │ Redis      │          │ MinIO / S3   │
                     └────────────┘          │ RabbitMQ     │
                                             └──────────────┘
                                                    │
                                             ┌──────────────┐
                                             │  Ingestion   │
                                             │  Worker      │
                                             └──────────────┘
```

### Services

| Service | Stack | Port | Role |
|---|---|---|---|
| `audit-assistant-api` | NestJS + Prisma | 8000 | REST API, LangGraph orchestration |
| `audit-rag-engine` | FastAPI + Python | 8100 | RAG retrieval, generation, ingestion |
| `audit-assistant-ui` | Next.js 14 | 3000 | Frontend dashboard |
| `ingestion-worker` | Python + RabbitMQ | — | Async document ingestion |

### Deployment Strategy by Environment

| Environment | Platform | Orchestrator |
|---|---|---|
| **Development** | Docker Compose | Local Docker |
| **Staging (GCP)** | Cloud Run | Serverless |
| **Staging (AWS)** | ECS Fargate | Serverless containers |
| **Production (GCP)** | GKE Autopilot | Kubernetes + Helm |
| **Production (AWS)** | EKS | Kubernetes + Helm |

---

## Prerequisites

### Common

- Docker ≥ 24.x & Docker Compose ≥ 2.20
- `helm` ≥ 3.12
- `kubectl` ≥ 1.28
- Git with submodule support
- Concourse CI `fly` CLI

### GCP-Specific

- `gcloud` CLI authenticated
- GCP project with Artifact Registry, Cloud Run, GKE enabled
- Service accounts with Workload Identity

### AWS-Specific

- `aws` CLI v2 configured
- ECR repositories created
- ECS cluster (staging) / EKS cluster (production)
- IAM roles for IRSA (EKS service accounts)

---

## Local Development

### 1. Clone and Initialize

```bash
git clone --recurse-submodules <repo-url>
cd ai-rag-audit-workflow/implementation
```

### 2. Environment Variables

```bash
cp .env.example .env
# Edit .env with your local secrets:
#   OPENAI_API_KEY, DATABASE_URL, NEO4J_URI, MONGODB_URI, etc.
```

### 3. Start Services

```bash
# Full stack (all infra + app services)
docker compose up -d

# With production overlay (resource limits, replicas)
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d
```

### 4. Verify

```bash
# API health
curl http://localhost:8000/health

# RAG engine health
curl http://localhost:8100/health

# UI
open http://localhost:3000
```

### 5. Stop

```bash
docker compose down        # stop containers
docker compose down -v     # stop + remove volumes
```

---

## Staging — GCP Cloud Run

### 1. Authenticate

```bash
gcloud auth login
gcloud config set project audit-ai-staging
gcloud auth configure-docker us-central1-docker.pkg.dev
```

### 2. Build & Push Images

```bash
REGION=us-central1
REPO=us-central1-docker.pkg.dev/audit-ai-staging/audit-repo
TAG=$(git rev-parse --short HEAD)

for svc in audit-assistant-api audit-rag-engine audit-assistant-ui ingestion-worker; do
  docker build -t ${REPO}/${svc}:${TAG} -f docker/${svc}/Dockerfile .
  docker push ${REPO}/${svc}:${TAG}
done
```

### 3. Deploy Services

```bash
# Replace IMAGE_TAG in Cloud Run YAML, then deploy
for svc in api rag-engine ui; do
  gcloud run services replace deploy/gcp/cloudrun/${svc}.yaml \
    --region ${REGION}
done

# Deploy worker as a Cloud Run Job
gcloud run jobs replace deploy/gcp/cloudrun/worker.yaml \
  --region ${REGION}
```

### 4. Smoke Test

```bash
API_URL=$(gcloud run services describe audit-assistant-api \
  --region ${REGION} --format 'value(status.url)')
curl ${API_URL}/health
```

### Config Files

| File | Purpose |
|---|---|
| `deploy/gcp/cloudrun/api.yaml` | API service definition |
| `deploy/gcp/cloudrun/rag-engine.yaml` | RAG engine definition |
| `deploy/gcp/cloudrun/ui.yaml` | UI service definition |
| `deploy/gcp/cloudrun/worker.yaml` | Worker job definition |
| `deploy/gcp/concourse/params-staging.yml` | Pipeline params |

---

## Staging — AWS ECS Fargate

### 1. Authenticate

```bash
aws ecr get-login-password --region ap-southeast-1 | \
  docker login --username AWS --password-stdin 123456789012.dkr.ecr.ap-southeast-1.amazonaws.com
```

### 2. Build & Push Images

```bash
ACCOUNT=123456789012
REGION=ap-southeast-1
TAG=$(git rev-parse --short HEAD)

for svc in audit-assistant-api audit-rag-engine audit-assistant-ui ingestion-worker; do
  docker build -t ${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com/${svc}:${TAG} \
    -f docker/${svc}/Dockerfile .
  docker push ${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com/${svc}:${TAG}
done
```

### 3. Register Task Definitions

```bash
for svc in api rag-engine ui worker; do
  aws ecs register-task-definition \
    --cli-input-json file://deploy/aws/ecs/task-def-${svc}.json
done
```

### 4. Update Services

```bash
CLUSTER=audit-staging-cluster

for svc in audit-assistant-api audit-rag-engine audit-assistant-ui; do
  aws ecs update-service \
    --cluster ${CLUSTER} \
    --service ${svc} \
    --task-definition ${svc} \
    --force-new-deployment
done
```

### Config Files

| File | Purpose |
|---|---|
| `deploy/aws/ecs/task-def-api.json` | API task definition |
| `deploy/aws/ecs/task-def-rag-engine.json` | RAG engine task definition |
| `deploy/aws/ecs/task-def-ui.json` | UI task definition |
| `deploy/aws/ecs/task-def-worker.json` | Worker task definition |
| `deploy/aws/ecs/service-discovery.json` | Service Connect + auto-scaling |
| `deploy/aws/concourse/params-staging.yml` | Pipeline params |

---

## Production — GKE Autopilot

### 1. Connect to Cluster

```bash
gcloud container clusters get-credentials audit-prod-gke \
  --region us-central1 \
  --project audit-ai-prod

kubectl create namespace audit-prod || true
```

### 2. Create Secrets

```bash
kubectl create secret generic audit-api-secrets -n audit-prod \
  --from-literal=database-url='postgresql://...' \
  --from-literal=jwt-secret='...' \
  --from-literal=openai-api-key='sk-...'

kubectl create secret generic audit-rag-secrets -n audit-prod \
  --from-literal=neo4j-uri='neo4j+s://...' \
  --from-literal=mongodb-uri='mongodb+srv://...' \
  --from-literal=openai-api-key='sk-...' \
  --from-literal=rabbitmq-url='amqps://...' \
  --from-literal=redis-url='redis://...' \
  --from-literal=s3-endpoint='https://...' \
  --from-literal=s3-access-key='...' \
  --from-literal=s3-secret-key='...'

kubectl create secret generic audit-ui-secrets -n audit-prod \
  --from-literal=nextauth-secret='...'
```

### 3. Deploy with Helm

```bash
# Deploy each service with GKE overrides
helm upgrade --install audit-api \
  ./deploy/helm/audit-assistant-api \
  -f ./deploy/helm/overrides/gke-production.yaml \
  -n audit-prod \
  --set image.tag=${TAG}

helm upgrade --install audit-rag \
  ./deploy/helm/audit-rag-engine \
  -f ./deploy/helm/overrides/gke-production.yaml \
  -n audit-prod \
  --set image.tag=${TAG}

helm upgrade --install audit-ui \
  ./deploy/helm/audit-assistant-ui \
  -f ./deploy/helm/overrides/gke-production.yaml \
  -n audit-prod \
  --set image.tag=${TAG}

helm upgrade --install audit-worker \
  ./deploy/helm/ingestion-worker \
  -f ./deploy/helm/overrides/gke-production.yaml \
  -n audit-prod \
  --set image.tag=${TAG}
```

### 4. Verify

```bash
kubectl get pods -n audit-prod
kubectl get hpa -n audit-prod
kubectl get ingress -n audit-prod
```

### Key Features

- **HPA**: CPU/memory-based autoscaling per service
- **PDB**: Minimum availability during node upgrades
- **Workload Identity**: GCP SA binding via `iam.gke.io/gcp-service-account`
- **GCE Ingress**: Managed TLS certificates via `networking.gke.io/managed-certificates`

---

## Production — EKS

### 1. Connect to Cluster

```bash
aws eks update-kubeconfig \
  --name audit-prod-eks \
  --region ap-southeast-1

kubectl create namespace audit-prod || true
```

### 2. Create Secrets

```bash
# Same pattern as GKE, or use AWS Secrets Manager + External Secrets Operator
kubectl create secret generic audit-api-secrets -n audit-prod \
  --from-literal=database-url='postgresql://...' \
  --from-literal=jwt-secret='...' \
  --from-literal=openai-api-key='sk-...'

kubectl create secret generic audit-rag-secrets -n audit-prod \
  --from-literal=neo4j-uri='neo4j+s://...' \
  --from-literal=mongodb-uri='mongodb+srv://...' \
  --from-literal=openai-api-key='sk-...' \
  --from-literal=rabbitmq-url='amqps://...' \
  --from-literal=redis-url='redis://...' \
  --from-literal=s3-endpoint='https://...' \
  --from-literal=s3-access-key='...' \
  --from-literal=s3-secret-key='...'

kubectl create secret generic audit-ui-secrets -n audit-prod \
  --from-literal=nextauth-secret='...'
```

### 3. Install AWS Load Balancer Controller

```bash
# Required for ALB Ingress
helm repo add eks https://aws.github.io/eks-charts
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=audit-prod-eks
```

### 4. Deploy with Helm

```bash
helm upgrade --install audit-api \
  ./deploy/helm/audit-assistant-api \
  -f ./deploy/helm/overrides/eks-production.yaml \
  -n audit-prod \
  --set image.tag=${TAG}

helm upgrade --install audit-rag \
  ./deploy/helm/audit-rag-engine \
  -f ./deploy/helm/overrides/eks-production.yaml \
  -n audit-prod \
  --set image.tag=${TAG}

helm upgrade --install audit-ui \
  ./deploy/helm/audit-assistant-ui \
  -f ./deploy/helm/overrides/eks-production.yaml \
  -n audit-prod \
  --set image.tag=${TAG}

helm upgrade --install audit-worker \
  ./deploy/helm/ingestion-worker \
  -f ./deploy/helm/overrides/eks-production.yaml \
  -n audit-prod \
  --set image.tag=${TAG}
```

### Key Features

- **ALB Ingress**: AWS Application Load Balancer with ACM TLS
- **IRSA**: IAM Roles for Service Accounts via `eks.amazonaws.com/role-arn`
- **HPA + PDB**: Same Kubernetes-native scaling & disruption budgets

---

## CI/CD with Concourse

### Pipeline Overview

```
git push → lint/test → build images → push to registry →
  deploy staging → smoke test → [manual gate] → deploy production
```

### Set Pipelines

```bash
# GCP pipeline
fly -t main set-pipeline -p audit-gcp \
  -c deploy/gcp/concourse/pipeline.yml \
  -l deploy/gcp/concourse/params-staging.yml

# AWS pipeline
fly -t main set-pipeline -p audit-aws \
  -c deploy/aws/concourse/pipeline.yml \
  -l deploy/aws/concourse/params-staging.yml
```

### Pipeline Jobs

| Job | Description |
|---|---|
| `lint-and-test` | Run linters and unit tests for all services |
| `build-and-push` | Multi-stage Docker build, push to registry |
| `deploy-staging` | Deploy to Cloud Run / ECS Fargate |
| `smoke-test` | Health check + basic API test on staging |
| `approval-gate` | Manual approval before production deploy |
| `deploy-production` | Helm upgrade on GKE / EKS |

### Trigger Production Deploy

```bash
# After smoke tests pass, manually approve:
fly -t main trigger-job -j audit-gcp/approval-gate
fly -t main trigger-job -j audit-aws/approval-gate
```

---

## Secrets Management

### Development

- `.env` file (gitignored) with local secrets

### Staging

| Platform | Mechanism |
|---|---|
| **GCP Cloud Run** | Secret Manager → mounted as env vars |
| **AWS ECS** | Secrets Manager → `secrets` in task definition |

### Production (Kubernetes)

| Approach | Description |
|---|---|
| **kubectl create secret** | Direct creation (shown above) |
| **External Secrets Operator** | Syncs from GCP Secret Manager / AWS Secrets Manager |
| **Sealed Secrets** | Encrypted secrets committed to Git |

Recommended: Use **External Secrets Operator** for production to keep secrets in the cloud provider's secret store and auto-sync to Kubernetes.

```bash
# Example: External Secrets Operator with GCP
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets -n external-secrets --create-namespace
```

---

## Monitoring & Observability

### Infrastructure (included in Docker Compose)

| Tool | Port | Purpose |
|---|---|---|
| Prometheus | 9090 | Metrics collection |
| Grafana | 3001 | Dashboards & alerting |

### Production Monitoring

- **GKE**: Cloud Monitoring + Cloud Logging (auto-enabled on Autopilot)
- **EKS**: CloudWatch Container Insights or Prometheus + Grafana stack

### Application Health Endpoints

```bash
# API
GET /health

# RAG Engine
GET /health

# UI
GET /
```

### Key Metrics to Monitor

- **API**: Request latency (p50/p95/p99), error rate, active connections
- **RAG Engine**: Retrieval latency, generation latency, queue depth
- **Worker**: Messages processed/sec, queue backlog, failure rate
- **Cluster**: Pod CPU/memory, HPA replica count, node utilization

---

## Rollback Procedures

### Helm Rollback (Production)

```bash
# List release history
helm history audit-api -n audit-prod

# Rollback to previous revision
helm rollback audit-api 1 -n audit-prod

# Rollback all services
for release in audit-api audit-rag audit-ui audit-worker; do
  helm rollback ${release} 0 -n audit-prod
done
```

### Cloud Run Rollback (Staging GCP)

```bash
# List revisions
gcloud run revisions list --service audit-assistant-api --region us-central1

# Route 100% traffic to previous revision
gcloud run services update-traffic audit-assistant-api \
  --to-revisions=<previous-revision>=100 \
  --region us-central1
```

### ECS Rollback (Staging AWS)

```bash
# Re-deploy previous task definition revision
aws ecs update-service \
  --cluster audit-staging-cluster \
  --service audit-assistant-api \
  --task-definition audit-assistant-api:<previous-revision> \
  --force-new-deployment
```

---

## Troubleshooting

### Common Issues

**Pod CrashLoopBackOff**
```bash
kubectl logs <pod-name> -n audit-prod --previous
kubectl describe pod <pod-name> -n audit-prod
```

**HPA not scaling**
```bash
kubectl describe hpa <hpa-name> -n audit-prod
# Check that metrics-server is running
kubectl top pods -n audit-prod
```

**Ingress not routing**
```bash
kubectl describe ingress -n audit-prod
# GKE: Check managed certificate status
# EKS: Check ALB controller logs
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
```

**Secret not found**
```bash
kubectl get secrets -n audit-prod
kubectl describe secret <secret-name> -n audit-prod
```

**RabbitMQ connection failures (Worker)**
```bash
# Check RabbitMQ pod/service
kubectl logs -l app=rabbitmq -n audit-prod
# Worker will retry with exponential backoff — check worker logs
kubectl logs -l app=ingestion-worker -n audit-prod
```

### Useful Commands

```bash
# Watch pod status
kubectl get pods -n audit-prod -w

# Port-forward for local debugging
kubectl port-forward svc/audit-api 8000:8000 -n audit-prod

# Exec into a running pod
kubectl exec -it <pod-name> -n audit-prod -- /bin/sh

# Check resource usage
kubectl top pods -n audit-prod
kubectl top nodes
```

---

## File Reference

```
deploy/
├── helm/
│   ├── audit-assistant-api/     # Helm chart: API
│   │   ├── Chart.yaml
│   │   ├── values.yaml
│   │   └── templates/
│   │       ├── deployment.yaml
│   │       ├── service.yaml
│   │       ├── hpa.yaml
│   │       ├── pdb.yaml
│   │       ├── ingress.yaml
│   │       └── configmap.yaml
│   ├── audit-rag-engine/        # Helm chart: RAG Engine
│   │   ├── Chart.yaml
│   │   ├── values.yaml
│   │   └── templates/
│   │       ├── deployment.yaml
│   │       ├── service.yaml
│   │       ├── hpa.yaml
│   │       ├── pdb.yaml
│   │       └── configmap.yaml
│   ├── audit-assistant-ui/      # Helm chart: UI
│   │   ├── Chart.yaml
│   │   ├── values.yaml
│   │   └── templates/
│   │       ├── deployment.yaml
│   │       ├── service.yaml
│   │       ├── hpa.yaml
│   │       └── pdb.yaml
│   ├── ingestion-worker/        # Helm chart: Worker
│   │   ├── Chart.yaml
│   │   ├── values.yaml
│   │   └── templates/
│   │       ├── deployment.yaml
│   │       ├── hpa.yaml
│   │       └── pdb.yaml
│   └── overrides/
│       ├── gke-production.yaml  # GKE Autopilot overrides
│       └── eks-production.yaml  # EKS overrides
├── gcp/
│   ├── concourse/
│   │   ├── pipeline.yml
│   │   ├── params-staging.yml
│   │   └── params-production.yml
│   └── cloudrun/
│       ├── api.yaml
│       ├── rag-engine.yaml
│       ├── ui.yaml
│       └── worker.yaml
└── aws/
    ├── concourse/
    │   ├── pipeline.yml
    │   ├── params-staging.yml
    │   └── params-production.yml
    └── ecs/
        ├── task-def-api.json
        ├── task-def-rag-engine.json
        ├── task-def-ui.json
        ├── task-def-worker.json
        └── service-discovery.json
```
