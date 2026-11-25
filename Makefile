# voice-agent developer tasks. Run from the repository root: `make help`.

SHELL := /bin/bash
.DEFAULT_GOAL := help

ROOT      := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
VENV      := $(ROOT)/backend/.venv
PY        := backend/.venv/bin/python
DASHBOARD := apps/dashboard
PY_SRC    := backend/app engine tests backend/tests
# Source trees scanned for secrets (skips node_modules, .venv and the local data directory).
SECRET_SCAN_PATHS := backend/app backend/tests engine tests scripts apps/dashboard/src apps/dashboard/e2e docs .github

.PHONY: help setup setup-models setup-all ollama dev start stop health backup build \
        test test-backend test-frontend test-real test-e2e \
        lint lint-backend lint-frontend typecheck typecheck-backend typecheck-frontend \
        migrations-check security format

help: ## Show this help
	@grep -E '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

# --- lifecycle ---------------------------------------------------------------

setup: ## Install system deps, backend venv and dashboard packages
	./scripts/setup-mac.sh

setup-models: ## Same as setup, plus download the speech models (~125 MB, asks first)
	./scripts/setup-mac.sh --models

setup-all: ## Everything: tools, speech models, Ollama and the default LLM (~2.5 GB, asks first)
	./scripts/setup-mac.sh --models --with-ollama

ollama: ## Only install Ollama and pull the default LLM (asks first)
	./scripts/setup-mac.sh --ollama-only

dev: ## Start all services with hot reload
	./scripts/start.sh --dev

start: ## Start all services (production build of the dashboard)
	./scripts/start.sh

stop: ## Stop the services voice-agent started
	./scripts/stop.sh

health: ## Check that every service is up
	./scripts/health-check.sh

backup: ## Create a backup of the data directory
	./scripts/backup.sh

build: ## Production build of the dashboard
	cd $(DASHBOARD) && npm run build

# --- tests -------------------------------------------------------------------

test: test-backend test-frontend ## Backend pytest + frontend vitest (real-model tests auto-skip when services are down)

test-backend: ## Backend + engine tests (pytest)
	$(PY) -m pytest backend/tests tests

test-frontend: ## Dashboard unit/component tests (vitest)
	cd $(DASHBOARD) && npx vitest run

test-real: ## Tests against the real local models (Ollama, whisper.cpp, Piper)
	$(PY) -m pytest tests/integration/test_real_providers.py -m "ollama or speech" -s

test-e2e: ## Playwright end-to-end tests (isolated instance on :8100/:3100)
	cd $(DASHBOARD) && npx playwright test

# --- quality -----------------------------------------------------------------

lint: lint-backend lint-frontend ## ruff + eslint

lint-backend:
	$(VENV)/bin/ruff check $(PY_SRC)

lint-frontend:
	cd $(DASHBOARD) && npx eslint src

typecheck: typecheck-backend typecheck-frontend ## mypy + tsc

typecheck-backend:
	cd backend && .venv/bin/mypy app ../engine

typecheck-frontend:
	cd $(DASHBOARD) && npx tsc --noEmit

migrations-check: ## Verify the models match the Alembic migrations (uses a throwaway database)
	@tmp=$$(mktemp -d); mkdir -p $$tmp/database; \
	cd backend && export VA_DATA_DIR=$$tmp PYTHONPATH=$(ROOT)/backend:$(ROOT); \
	.venv/bin/alembic upgrade head && .venv/bin/alembic check; status=$$?; rm -rf $$tmp; exit $$status

security: ## bandit, pip-audit, npm audit and gitleaks (if installed)
	$(VENV)/bin/bandit -c backend/pyproject.toml -r backend/app engine -q -ll
	@req=$$(mktemp); \
	(cd backend && uv export --frozen --format requirements-txt --no-hashes --no-emit-project --quiet) > $$req && \
	$(VENV)/bin/pip-audit -r $$req --no-deps --disable-pip --progress-spinner off; status=$$?; rm -f $$req; exit $$status
	cd $(DASHBOARD) && npm audit --omit=dev --audit-level=high
	@if command -v gitleaks >/dev/null 2>&1; then \
		for p in $(SECRET_SCAN_PATHS); do gitleaks dir "$$p" --no-banner --redact --log-level warn || exit 1; done; \
		echo "gitleaks: no secrets found in $(SECRET_SCAN_PATHS)"; \
	else \
		echo "gitleaks not installed; skipping secret scan (brew install gitleaks)"; \
	fi

format: ## Format backend code with ruff (and apply safe lint fixes)
	$(VENV)/bin/ruff format $(PY_SRC)
	$(VENV)/bin/ruff check --fix $(PY_SRC)
