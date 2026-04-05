# AI RAG Audit Assistant — Root Makefile
# Orchestrates all three submodule apps and local infrastructure.
#
# Quick start:
#   make infra-up   → start all databases / infra (docker-compose)
#   make dev        → start UI + API + RAG engine + ingestion worker
#   make stop       → kill all dev processes
#
# Prerequisites: node/npm, python 3.11+, docker

.PHONY: help \
        dev dev-ui dev-api dev-engine dev-worker stop \
        infra-up infra-down infra-logs infra-ps \
        install install-ui install-api install-engine \
        build build-ui build-api \
        test test-api test-engine \
        lint lint-ui lint-api lint-engine \
        migrate db-seed db-studio \
        submodule-update submodule-status \
        backup-postgres backup-mongodb backup-neo4j

# ── Colours ────────────────────────────────────────────────────────────────────
CYAN   := \033[0;36m
GREEN  := \033[0;32m
YELLOW := \033[0;33m
RED    := \033[0;31m
BOLD   := \033[1m
RESET  := \033[0m

# ── Directories ────────────────────────────────────────────────────────────────
UI_DIR     := audit-assistant-ui
API_DIR    := audit-assistant-api
ENGINE_DIR := audit-rag-engine

# ── Default target ─────────────────────────────────────────────────────────────
.DEFAULT_GOAL := help

help: ## Show this help message
	@echo ""
	@echo "  $(BOLD)AI RAG Audit Assistant — Makefile$(RESET)"
	@echo ""
	@echo "  $(CYAN)Dev$(RESET)"
	@echo "    make infra-up       Start all infrastructure services (docker-compose)"
	@echo "    make dev            Start UI + API + RAG engine + worker (parallel)"
	@echo "    make stop           Kill all dev processes"
	@echo ""
	@echo "  $(CYAN)Individual services$(RESET)"
	@echo "    make dev-ui         Next.js          → http://localhost:3000"
	@echo "    make dev-api        NestJS            → http://localhost:8000"
	@echo "    make dev-engine     FastAPI           → http://localhost:8001"
	@echo "    make dev-worker     Ingestion worker  (RabbitMQ consumer)"
	@echo ""
	@echo "  $(CYAN)Setup$(RESET)"
	@echo "    make install        Install all dependencies"
	@echo "    make build          Build UI + API"
	@echo "    make test           Run all tests"
	@echo "    make lint           Lint all apps"
	@echo ""
	@echo "  $(CYAN)Database$(RESET)"
	@echo "    make migrate        Prisma migrate dev"
	@echo "    make db-seed        Prisma seed"
	@echo "    make db-studio      Prisma Studio (browser)"
	@echo ""
	@echo "  $(CYAN)Submodules$(RESET)"
	@echo "    make submodule-update   Pull latest from all submodule remotes"
	@echo "    make submodule-status   Show submodule commit status"
	@echo ""
	@echo "  $(CYAN)Backups$(RESET)"
	@echo "    make backup-postgres / backup-mongodb / backup-neo4j"
	@echo ""

# ── Infrastructure ─────────────────────────────────────────────────────────────
infra-up: ## Start all infrastructure services (postgres, redis, mongo, neo4j, minio, rabbitmq, prometheus, grafana)
	@echo "$(CYAN)Starting infrastructure...$(RESET)"
	docker compose up -d
	@echo "$(GREEN)Infrastructure is up.$(RESET)"
	@echo "  PostgreSQL  → localhost:5432"
	@echo "  Redis       → localhost:6379"
	@echo "  MongoDB     → localhost:27017"
	@echo "  Neo4j       → localhost:7474 (browser) / 7687 (bolt)"
	@echo "  MinIO       → localhost:9000 (API) / 9001 (console)"
	@echo "  RabbitMQ    → localhost:5672 (AMQP) / 15672 (management)"
	@echo "  Prometheus  → localhost:9090"
	@echo "  Grafana     → localhost:3001"

infra-down: ## Stop and remove infrastructure containers
	@echo "$(YELLOW)Stopping infrastructure...$(RESET)"
	docker compose down

infra-logs: ## Follow logs from all infrastructure containers
	docker compose logs -f

infra-ps: ## Show running infrastructure containers
	docker compose ps

# ── Dev: all apps ──────────────────────────────────────────────────────────────
dev: ## Start all apps in parallel (UI + API + RAG engine + ingestion worker)
	@echo "$(CYAN)$(BOLD)Starting all services in parallel...$(RESET)"
	@echo "$(YELLOW)Make sure infrastructure is running: make infra-up$(RESET)"
	@$(MAKE) dev-engine & \
	 $(MAKE) dev-worker & \
	 $(MAKE) dev-api    & \
	 $(MAKE) dev-ui     & \
	 wait

# ── Dev: individual ────────────────────────────────────────────────────────────
dev-ui: ## Start Next.js dev server (localhost:3000)
	@echo "$(CYAN)Starting audit-assistant-ui...$(RESET)"
	cd $(UI_DIR) && npm run dev

dev-api: ## Start NestJS dev server with watch (localhost:8000)
	@echo "$(CYAN)Starting audit-assistant-api...$(RESET)"
	cd $(API_DIR) && npm run start:dev

dev-engine: ## Start FastAPI dev server with reload (localhost:8001)
	@echo "$(CYAN)Starting audit-rag-engine...$(RESET)"
	cd $(ENGINE_DIR) && .venv/bin/uvicorn src.main:app --host 0.0.0.0 --port 8001 --reload

dev-worker: ## Start ingestion worker (RabbitMQ consumer, requires infra-up)
	@echo "$(CYAN)Starting ingestion worker...$(RESET)"
	cd $(ENGINE_DIR) && .venv/bin/python -m src.worker

stop: ## Kill all dev processes (UI, API, RAG engine, worker)
	@echo "$(YELLOW)Stopping all dev processes...$(RESET)"
	@pkill -f "next dev"      || true
	@pkill -f "nest start"    || true
	@pkill -f "uvicorn"       || true
	@pkill -f "src.worker"    || true
	@echo "$(GREEN)All dev processes stopped.$(RESET)"

# ── Install ────────────────────────────────────────────────────────────────────
install: install-ui install-api install-engine ## Install dependencies for all apps

install-ui: ## Install Next.js dependencies
	@echo "$(CYAN)Installing audit-assistant-ui dependencies...$(RESET)"
	cd $(UI_DIR) && npm ci

install-api: ## Install NestJS dependencies
	@echo "$(CYAN)Installing audit-assistant-api dependencies...$(RESET)"
	cd $(API_DIR) && npm ci

install-engine: ## Create Python venv and install dependencies
	@echo "$(CYAN)Installing audit-rag-engine dependencies...$(RESET)"
	cd $(ENGINE_DIR) && python3 -m venv .venv
	cd $(ENGINE_DIR) && .venv/bin/pip install --upgrade pip
	cd $(ENGINE_DIR) && .venv/bin/pip install -e ".[dev]"
	@echo "$(GREEN)Python venv ready at $(ENGINE_DIR)/.venv$(RESET)"

# ── Build ──────────────────────────────────────────────────────────────────────
build: build-ui build-api ## Build all JS/TS apps (Python has no build step)

build-ui: ## Build Next.js for production
	@echo "$(CYAN)Building audit-assistant-ui...$(RESET)"
	cd $(UI_DIR) && npm run build

build-api: ## Build NestJS for production
	@echo "$(CYAN)Building audit-assistant-api...$(RESET)"
	cd $(API_DIR) && npm run build

# ── Test ───────────────────────────────────────────────────────────────────────
test: ## Run all tests in parallel (Jest × 2 + pytest)
	@echo "$(CYAN)Running all tests...$(RESET)"
	@$(MAKE) test-api    & \
	 $(MAKE) test-engine & \
	 wait

test-api: ## Run NestJS Jest tests
	@echo "$(CYAN)Testing audit-assistant-api...$(RESET)"
	cd $(API_DIR) && npm run test

test-engine: ## Run FastAPI pytest suite
	@echo "$(CYAN)Testing audit-rag-engine...$(RESET)"
	cd $(ENGINE_DIR) && .venv/bin/pytest tests/ -v

# ── Lint ───────────────────────────────────────────────────────────────────────
lint: lint-ui lint-api lint-engine ## Lint all apps (ESLint × 2 + Ruff)

lint-ui: ## Lint Next.js with ESLint
	@echo "$(CYAN)Linting audit-assistant-ui...$(RESET)"
	cd $(UI_DIR) && npm run lint

lint-api: ## Lint NestJS with ESLint
	@echo "$(CYAN)Linting audit-assistant-api...$(RESET)"
	cd $(API_DIR) && npm run lint

lint-engine: ## Lint Python with Ruff
	@echo "$(CYAN)Linting audit-rag-engine...$(RESET)"
	cd $(ENGINE_DIR) && .venv/bin/ruff check src/

# ── Database ───────────────────────────────────────────────────────────────────
migrate: ## Run Prisma migrations (requires postgres running)
	@echo "$(CYAN)Running Prisma migrations...$(RESET)"
	cd $(API_DIR) && npx prisma migrate dev

db-seed: ## Seed the database with dev data
	@echo "$(CYAN)Seeding database...$(RESET)"
	cd $(API_DIR) && npx prisma db seed

db-studio: ## Open Prisma Studio in browser
	@echo "$(CYAN)Opening Prisma Studio...$(RESET)"
	cd $(API_DIR) && npx prisma studio

# ── Submodules ─────────────────────────────────────────────────────────────────
submodule-update: ## Pull latest commits from all submodule remotes
	@echo "$(CYAN)Updating all submodules...$(RESET)"
	git submodule update --remote --merge
	@echo "$(GREEN)Submodules updated.$(RESET)"

submodule-status: ## Show current commit for each submodule
	git submodule status

# ── Backups ────────────────────────────────────────────────────────────────────
backup-postgres: ## Run PostgreSQL backup script
	@echo "$(CYAN)Backing up PostgreSQL...$(RESET)"
	bash scripts/backup-postgres.sh

backup-mongodb: ## Run MongoDB backup script
	@echo "$(CYAN)Backing up MongoDB...$(RESET)"
	bash scripts/backup-mongodb.sh

backup-neo4j: ## Run Neo4j backup script
	@echo "$(CYAN)Backing up Neo4j...$(RESET)"
	bash scripts/backup-neo4j.sh
