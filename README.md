# AI RAG Audit Assistant — Infrastructure & Orchestration

Shared infrastructure, observability, and deployment orchestration for the AI RAG Audit Assistant. The three service repositories are managed as Git submodules.

## Structure

```
├── Makefile                        # Root dev orchestration — dev, build, test, lint, infra, backup
├── docker-compose.yml              # Local infrastructure (PostgreSQL, Redis, MongoDB, Neo4j, MinIO, RabbitMQ, Prometheus, Grafana)
├── docker-compose.prod.yml         # Production overlay (resource limits, replicas, ingestion-worker)
├── prometheus/
│   └── prometheus.yml              # Scrape configs for API + RAG Engine metrics
├── grafana/
│   ├── provisioning/
│   │   ├── datasources/            # Auto-provisioned Prometheus datasource
│   │   └── dashboards/             # Dashboard provisioning config
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
├── audit-rag-engine/               # [submodule] RAG Engine (Python FastAPI + Docling + Neo4j + RabbitMQ)
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

### 2. Start infrastructure

```bash
docker-compose up -d
```

This starts:
- **PostgreSQL** (port 5432) — users, engagements, audit trail, agent memory
- **Redis** (port 6379) — cache, sessions, rate limiting
- **MongoDB** (port 27017) — document store (chunks, metadata)
- **Neo4j** (port 7474/7687) — unified vector + graph + fulltext
- **MinIO** (port 9000/9001) — S3-compatible object storage
- **RabbitMQ** (port 5672/15672) — async ingestion message broker
- **Prometheus** (port 9090) — metrics collection
- **Grafana** (port 3001) — dashboards & visualization

### 3. Set up services

```bash
# Backend API
cd audit-assistant-api
cp .env.example .env
npm install
npx prisma migrate dev
npm run start:dev

# RAG Engine (in another terminal)
cd audit-rag-engine
cp .env.example .env
pip install -e ".[dev]"
python scripts/init_indexes.py
uvicorn src.main:app --reload --port 8001

# Ingestion worker (in another terminal — requires RabbitMQ running)
cd audit-rag-engine
python -m src.worker

# Frontend (in another terminal)
cd audit-assistant-ui
cp .env.example .env
npm install
npm run dev
```

> **Shortcut:** use `make install`, `make migrate`, `make dev`, and `make stop` instead of the above manual steps. Run `make help` to see all available targets.

### 4. Access

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

## Makefile Reference

Run `make help` to see all targets. Summary:

| Target | Description |
|--------|-------------|
| `make dev` | Start UI + API + RAG engine + ingestion worker in parallel |
| `make dev-ui` | Next.js only → localhost:3000 |
| `make dev-api` | NestJS only → localhost:8000 |
| `make dev-engine` | FastAPI only → localhost:8001 |
| `make dev-worker` | Ingestion worker (RabbitMQ consumer) |
| `make stop` | Kill all dev processes |
| `make infra-up` | `docker compose up -d` (all databases + broker + observability) |
| `make infra-down` | `docker compose down` |
| `make infra-logs` | Follow all infrastructure container logs |
| `make infra-ps` | Show running containers |
| `make install` | Install all dependencies (npm ci × 2 + pip install) |
| `make build` | Build UI + API for production |
| `make test` | Run all tests (Jest + pytest) in parallel |
| `make lint` | Lint all apps (ESLint + Ruff) |
| `make migrate` | Prisma migrate dev |
| `make db-seed` | Prisma seed |
| `make db-studio` | Open Prisma Studio in browser |
| `make submodule-update` | Pull latest from all submodule remotes |
| `make submodule-status` | Show submodule commit status |
| `make backup-postgres` | Run PostgreSQL backup script |
| `make backup-mongodb` | Run MongoDB backup script |
| `make backup-neo4j` | Run Neo4j backup script |

## Submodule Workflows

### Update a submodule to latest

```bash
cd audit-rag-engine
git pull origin main
cd ..
git add audit-rag-engine
git commit -m "chore: update audit-rag-engine to latest"
```

Or pull all submodules at once:

```bash
make submodule-update
```

### Push submodule changes

Always push submodules **before** committing updated pointers in this repo:

```bash
# 1. Push each submodule to its remote
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

## Default Credentials (local dev only)

| Service | User | Password |
|---------|------|----------|
| PostgreSQL | audit_user | audit_pass |
| MongoDB | audit_user | audit_pass |
| Neo4j | neo4j | audit_pass |
| MinIO | audit_minio | audit_minio_pass |
| RabbitMQ | audit_user | audit_pass |
| Grafana | admin | audit_grafana |

## Deployment

See [`deploy/DEPLOYMENT_GUIDE.md`](deploy/DEPLOYMENT_GUIDE.md) for full instructions covering:

- Local development (Docker Compose)
- Staging on GCP Cloud Run
- Staging on AWS ECS Fargate
- Production on GKE Autopilot (Helm)
- Production on EKS (Helm)
- CI/CD with Concourse

## License

[MIT](LICENSE)
