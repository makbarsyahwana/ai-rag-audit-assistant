# AI RAG Audit Assistant — Infrastructure & Orchestration

Shared infrastructure, observability, deployment configurations, and developer tooling for the AI RAG Audit Assistant. The three service repositories are managed as Git submodules.

## Structure

```
├── Makefile                        # Root orchestration — dev, build, test, lint, infra
├── docker-compose.yml              # Local infrastructure (all databases + message broker + observability)
├── docker-compose.prod.yml         # Production overlay (resource limits, replicas)
├── prometheus/
│   └── prometheus.yml              # Scrape configs for API + RAG Engine metrics
├── grafana/
│   ├── provisioning/               # Auto-provisioned datasources + dashboard config
│   └── dashboards/                 # Pre-built Grafana dashboards
├── nginx/
│   └── nginx.conf                  # Reverse proxy / load balancer config
├── scripts/                        # Backup scripts (postgres, mongodb, neo4j) + data retention
├── deploy/
│   ├── DEPLOYMENT_GUIDE.md         # Full deployment reference (local → staging → production)
│   ├── dockerfiles/                # Production Dockerfiles (api, rag-engine, ui, worker)
│   ├── helm/                       # Helm charts (api, rag-engine, ui, ingestion-worker, overrides)
│   ├── aws/
│   │   ├── ecs/                    # ECS task definitions (api, rag-engine, ui, worker)
│   │   └── concourse/              # AWS Concourse CI/CD pipeline
│   └── gcp/
│       ├── cloudrun/               # GCP Cloud Run service manifests
│       └── concourse/              # GCP Concourse CI/CD pipeline
├── audit-assistant-api/            # [submodule] Backend API (NestJS + Prisma + LangGraph.js)
├── audit-rag-engine/               # [submodule] RAG Engine (FastAPI + Docling + Neo4j + RabbitMQ)
└── audit-assistant-ui/             # [submodule] Frontend (Next.js 14 + TailwindCSS + shadcn/ui)
```

## Quick Start

### 1. Clone with submodules

```bash
git clone --recurse-submodules git@github.com:makbarsyahwana/audit-infra-workflow.git
cd audit-infra-workflow
```

If already cloned without submodules:

```bash
git submodule update --init --recursive
```

### 2. Install dependencies

```bash
make install
```

This runs `npm ci` for the API and UI, and creates a Python venv + installs deps for the RAG engine.

> For the RAG engine only, copy `.env.example` to `.env` first and configure your API keys:
> ```bash
> cp audit-rag-engine/.env.example audit-rag-engine/.env
> cp audit-assistant-api/.env.example audit-assistant-api/.env
> cp audit-assistant-ui/.env.example audit-assistant-ui/.env
> ```

### 3. Start infrastructure

```bash
make infra-up
```

This starts:
- **PostgreSQL** (port 5432) — users, engagements, audit trail, agent memory
- **Redis** (port 6379) — cache, sessions, rate limiting
- **MongoDB** (port 27017) — document store (chunks, metadata)
- **Neo4j** (port 7474/7687) — unified vector + graph + fulltext search
- **MinIO** (port 9000/9001) — S3-compatible object storage
- **RabbitMQ** (port 5672/15672) — async ingestion message broker
- **Prometheus** (port 9090) — metrics collection
- **Grafana** (port 3001) — dashboards & visualization

### 4. Run database migrations

```bash
make migrate
```

### 5. Start all services

```bash
make dev
```

Starts all four processes in parallel: UI (3000), API (8000), RAG engine (8001), ingestion worker.

### 6. Access

| Service | URL |
|---------|-----|
| **UI** | http://localhost:3000 |
| **API Docs** | http://localhost:8000/docs |
| **RAG Engine Docs** | http://localhost:8001/docs |
| **Neo4j Browser** | http://localhost:7474 |
| **MinIO Console** | http://localhost:9001 |
| **RabbitMQ Management** | http://localhost:15672 |
| **Prometheus** | http://localhost:9090 |
| **Grafana** | http://localhost:3001 |

To stop all dev processes:

```bash
make stop
```

## Makefile Reference

```
make help               Show all available targets

# Dev
make dev                Start all 4 services in parallel
make dev-ui             Next.js only             → localhost:3000
make dev-api            NestJS only              → localhost:8000
make dev-engine         FastAPI only             → localhost:8001
make dev-worker         Ingestion worker only    (RabbitMQ consumer)
make stop               Kill all dev processes

# Infrastructure
make infra-up           docker compose up -d
make infra-down         docker compose down
make infra-logs         Follow all container logs
make infra-ps           Show running containers

# Code quality
make build              Build UI + API
make test               Run all tests (Jest + pytest) in parallel
make lint               Lint all apps (ESLint + Ruff)

# Database
make migrate            Prisma migrate dev
make db-seed            Prisma seed
make db-studio          Open Prisma Studio

# Submodules
make submodule-update   Pull latest from all submodule remotes
make submodule-status   Show submodule commit status

# Backups
make backup-postgres
make backup-mongodb
make backup-neo4j
```

## Submodule Workflows

### Pull latest from all submodule remotes

```bash
make submodule-update
```

Or manually for a single submodule:

```bash
cd audit-rag-engine
git pull origin main
cd ..
git add audit-rag-engine
git commit -m "chore: update audit-rag-engine to latest"
```

### Push submodule changes

Always push submodules **before** committing updated pointers in this repo:

```bash
# 1. Push each submodule
cd audit-assistant-ui  && git push origin main && cd ..
cd audit-assistant-api && git push origin main && cd ..
cd audit-rag-engine    && git push origin main && cd ..

# 2. Commit updated pointers in the parent repo
git add audit-assistant-ui audit-assistant-api audit-rag-engine
git commit -m "chore: update submodule pointers to latest main"
git push origin main
```

### Service teams work independently

Each submodule is a fully independent repo — branch, commit, push, and PR as normal.

## Deployment

See [`deploy/DEPLOYMENT_GUIDE.md`](deploy/DEPLOYMENT_GUIDE.md) for full instructions covering:

- Local development (Docker Compose)
- Staging on GCP Cloud Run
- Staging on AWS ECS Fargate
- Production on GKE Autopilot (Helm)
- Production on EKS (Helm)
- CI/CD with Concourse

## Default Credentials (local dev only)

| Service | User | Password |
|---------|------|----------|
| PostgreSQL | audit_user | audit_pass |
| MongoDB | audit_user | audit_pass |
| Neo4j | neo4j | audit_pass |
| MinIO | audit_minio | audit_minio_pass |
| RabbitMQ | audit_user | audit_pass |
| Grafana | admin | audit_grafana |

## License

[MIT](LICENSE)
