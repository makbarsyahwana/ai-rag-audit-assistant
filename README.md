# AI RAG Audit Assistant — Infrastructure & Orchestration

Shared infrastructure, observability, and deployment orchestration for the AI RAG Audit Assistant. The three service repositories are managed as Git submodules.

## Structure

```
├── docker-compose.yml              # Local infrastructure (PostgreSQL, Redis, MongoDB, Neo4j, MinIO, Prometheus, Grafana)
├── prometheus/
│   └── prometheus.yml              # Scrape configs for API + RAG Engine metrics
├── grafana/
│   ├── provisioning/
│   │   ├── datasources/            # Auto-provisioned Prometheus datasource
│   │   └── dashboards/             # Dashboard provisioning config
│   └── dashboards/                 # Pre-built Grafana dashboards
├── scripts/                        # Utility scripts
├── audit-assistant-api/            # [submodule] Backend API (NestJS + LangGraph.js)
├── audit-rag-engine/               # [submodule] RAG Engine (Python FastAPI + Docling + Neo4j)
└── audit-assistant-ui/             # [submodule] Frontend (Next.js + TailwindCSS)
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
- **Redis** (port 6379) — cache, sessions
- **MongoDB** (port 27017) — document store
- **Neo4j** (port 7474/7687) — unified vector + graph + fulltext
- **MinIO** (port 9000/9001) — S3-compatible object storage
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

# Frontend (in another terminal)
cd audit-assistant-ui
cp .env.example .env
npm install
npm run dev
```

### 4. Access

| Service | URL |
|---------|-----|
| **UI** | http://localhost:3000 |
| **API Docs** | http://localhost:8000/docs |
| **RAG Engine Docs** | http://localhost:8001/docs |
| **Neo4j Browser** | http://localhost:7474 |
| **MinIO Console** | http://localhost:9001 |
| **Prometheus** | http://localhost:9090 |
| **Grafana** | http://localhost:3001 |

## Submodule Workflows

### Update a submodule to latest

```bash
cd audit-rag-engine
git pull origin main
cd ..
git add audit-rag-engine
git commit -m "chore: update audit-rag-engine to latest"
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
| Grafana | admin | audit_grafana |

## License

[MIT](../LICENSE)
