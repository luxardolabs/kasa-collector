# =============================================================================
# kasa-collector — fleet build/deploy Makefile
# Source of truth for the version is the VERSION file at the repo root.
# Compose never builds; the Makefile builds the image + pushes it to the registry,
# and the dev/prod stacks pull it. Mirrors the bb-boutique fleet standard, trimmed
# for a single-service collector (host networking, no db/redis/nginx/css).
# =============================================================================

VERSION := $(shell cat VERSION 2>/dev/null || git -c safe.directory=$(CURDIR) describe --tags --always 2>/dev/null || echo "0.0.0-dev")
TIMESTAMP := $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
COMMIT := $(shell git -c safe.directory=$(CURDIR) rev-parse --short HEAD 2>/dev/null || echo 'local')

# The private-registry host is kept OUT of this public tree — set it in an untracked
# Makefile.local (see Makefile.local.example). Included FIRST so its values win over the
# empty defaults below. Without it, the local/e2e stacks still build; only the targets
# that pull from the private registry (dev-build-push / release / prod / lint / arch / audit)
# need it. Lint/type/test are decoupled from :dev per FLEET-BUILD-DEPLOY-STANDARD — ruff is
# mount-only luxlint, mypy is python:3.14-slim + fresh pip, pytest is a lock-keyed image.
-include Makefile.local

# Registry / images. REGISTRY comes from Makefile.local or the CLI; empty by default so no
# internal hostname is committed. `make dev-build-push REGISTRY=...` still overrides.
REGISTRY ?=
IMAGE_NAME := luxardolabs/kasa-collector
DEV_IMAGE     := $(REGISTRY)/$(IMAGE_NAME):dev
VERSION_IMAGE := $(REGISTRY)/$(IMAGE_NAME):$(VERSION)
IMAGE         := $(REGISTRY)/$(IMAGE_NAME):latest
# Locally-built runtime image for the local stacks (up / dev / demo) — no registry needed.
LOCAL_IMAGE   := kasa-collector:local
# Public OSS image on GitHub Container Registry (the fleet's external registry,
# not Docker Hub). EXTERNAL_REGISTRY overridable.
EXTERNAL_REGISTRY ?= ghcr.io
PUBLIC_IMAGE := $(EXTERNAL_REGISTRY)/$(IMAGE_NAME)

# Architecture guard (luxarch) — pinned; pulled via LUXARCH_REGISTRY (Makefile.local).
# Bump LUXARCH_VERSION when adopting new rules. Unset host → `make arch` skips gracefully.
LUXARCH_REGISTRY ?=
LUXARCH_VERSION  ?= 0.19.0

# Code-style + type guard (luxlint) — pinned; pulled via LUXLINT_REGISTRY (Makefile.local),
# same out-of-tree pattern as luxarch. Unset host → make lint/format skip gracefully.
LUXLINT_REGISTRY ?=
LUXLINT_VERSION  ?= 0.9.0
LUXLINT_IMAGE    ?= $(LUXLINT_REGISTRY)/luxardolabs/luxlint:$(LUXLINT_VERSION)

# Dependency-vulnerability guard (luxaudit) — pinned; pulled via LUXAUDIT_REGISTRY (Makefile.local).
# Scans poetry.lock against the live OSV+PyPA feed. Unset host → `make audit` skips gracefully.
LUXAUDIT_REGISTRY ?=
LUXAUDIT_VERSION  ?= 0.1.8
PLATFORMS ?= linux/amd64,linux/arm64

BUILD_ARGS := --build-arg BUILD_VERSION=$(VERSION) \
              --build-arg BUILD_TIMESTAMP=$(TIMESTAMP) \
              --build-arg BUILD_COMMIT=$(COMMIT)

# Cache busting: `make dev-build-push NOCACHE=1`
NOCACHE ?=
NO_CACHE_FLAG := $(if $(NOCACHE),--no-cache,)

# ANSI colors for `make help`
BLUE := \033[0;34m
GREEN := \033[0;32m
YELLOW := \033[0;33m
CYAN := \033[0;36m
NC := \033[0m
BOLD := \033[1m

# Lean pytest image — built from poetry.lock (NOT FROM :dev), rebuilt only when the lock
# changes (the .test-image.stamp target below keys on it). Source is over-mounted at run
# time. See Dockerfile.test and FLEET-BUILD-DEPLOY-STANDARD ("Lint & test images").
TEST_IMAGE := kasa-collector-test

# Poetry-in-docker — the build hosts carry no host poetry. A throwaway
# python:3.14-slim installs poetry into a /tmp venv with the repo mounted so the
# regenerated poetry.lock is written back to the host as the checkout owner.
REPO_UID := $(shell stat -c %u . 2>/dev/null || echo 1000)
REPO_GID := $(shell stat -c %g . 2>/dev/null || echo 1000)
# Pin Poetry for the poetry-in-docker targets to match the Dockerfile's POETRY_VERSION
# (overridable: `make poetry-lock POETRY_VERSION=x.y.z`). Keep in sync with the Dockerfile.
POETRY_VERSION ?= 2.4.1
POETRY_SPEC := poetry$(if $(POETRY_VERSION),==$(POETRY_VERSION),)
POETRY_RUN := docker run --rm -u $(REPO_UID):$(REPO_GID) -e HOME=/tmp -v $(PWD):/work -w /work python:3.14-slim sh -c
POETRY_PIP := python -m venv /tmp/v && /tmp/v/bin/pip install -q --root-user-action=ignore $(POETRY_SPEC)

# Compose stacks (all .yml, short-form volumes). Four flavors:
#   compose.yml       collector-only -> your external InfluxDB/Grafana (.env.dev / :dev)
#   compose.prod.yml  collector-only -> external, prod (.env.prod / :latest)
#   compose.dev.yml   full LOCAL dev stack: your real devices + bundled InfluxDB+Grafana
#   compose.demo.yml  DEMO: fake devices + bundled InfluxDB+Grafana (no hardware)
#   compose.e2e.yml   hardware-free e2e test (fakes + ephemeral InfluxDB) -> `make test-e2e`
RUN_DC  := docker compose -f compose.yml --env-file .env.dev
PROD_DC := docker compose -f compose.prod.yml --env-file .env.prod
DEV_DC  := docker compose -f compose.dev.yml --env-file .env.demo
DEMO_DC := docker compose -f compose.demo.yml --env-file .env.demo

# Remote prod deploy over SSH. The collector runs on a host with LAN access to the
# Kasa devices; set the node explicitly (no fleet default — this app is not bb01).
#   make prod-deploy PROD_NODE=collector01.example.com
PROD_NODE ?=
PROD_USER ?= root
PROD_DIR  ?= /opt/kasa-collector
PROD_SSH  := ssh -o BatchMode=yes $(PROD_USER)@$(PROD_NODE)

.PHONY: help version \
        dev-build-push build-local version-build-push release release-public buildx-setup \
        docker-inspect docker-clean \
        up down restart logs ps shell \
        dev-up dev-down dev-clean dev-logs dev-ps dev-shell \
        prod-up prod-down prod-restart prod-logs prod-ps \
        demo-up demo-down demo-clean demo-logs demo-ps \
        check-prod-node prod-init prod-sync prod-deploy prod-status prod-logs-remote prod-health prod-rollback \
        poetry-lock poetry-update poetry-install \
        guard-version-check lint format test arch audit test-e2e check \
        gitleaks gitleaks-staged hooks clean clean-all

.DEFAULT_GOAL := help

##@ General

help: ## Show this grouped command help
	@printf "\n$(BOLD)$(CYAN)kasa-collector$(NC)  $(YELLOW)v$(VERSION) ($(COMMIT))$(NC)\n"
	@awk 'BEGIN {FS = ":.*?## "} \
		/^##@/ { printf "\n$(BOLD)$(BLUE)%s$(NC)\n", substr($$0, 5); next } \
		/^[a-zA-Z0-9_-]+:.*?## / { printf "  $(GREEN)%-24s$(NC) %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@printf "\n"

version: ## Show version / build info
	@echo "Version:   $(VERSION)"
	@echo "Commit:    $(COMMIT)"
	@echo "Timestamp: $(TIMESTAMP)"
	@echo "Dev:       $(DEV_IMAGE)"
	@echo "Release:   $(VERSION_IMAGE)  +  $(IMAGE)"
	@echo "Public:    $(PUBLIC_IMAGE):$(VERSION)"

##@ Docker — Build & Registry

buildx-setup: ## Ensure a buildx builder exists (multi-arch release builds)
	@docker buildx inspect kasa-builder >/dev/null 2>&1 \
		|| docker buildx create --name kasa-builder --use
	@docker buildx use kasa-builder

dev-build-push: ## Build + push :dev ONLY (tooling stage: dev deps + tests baked)
	docker build $(NO_CACHE_FLAG) --target dev -f Dockerfile $(BUILD_ARGS) -t $(DEV_IMAGE) .
	docker push $(DEV_IMAGE)
	@echo "Pushed $(DEV_IMAGE)"

build-local: ## Build the runtime image from CURRENT source as a local tag (no push, no registry)
	docker build $(NO_CACHE_FLAG) --target base -f Dockerfile $(BUILD_ARGS) -t $(LOCAL_IMAGE) .

version-build-push: ## Build + push :$(VERSION) ONLY (runtime base stage) to the private registry
	docker build $(NO_CACHE_FLAG) --target base -f Dockerfile $(BUILD_ARGS) -t $(VERSION_IMAGE) .
	docker push $(VERSION_IMAGE)
	@echo "Pushed $(VERSION_IMAGE)"

release: buildx-setup ## Build + push :$(VERSION) AND :latest (multi-arch) to the private registry
	docker buildx build $(NO_CACHE_FLAG) --target base --platform $(PLATFORMS) -f Dockerfile $(BUILD_ARGS) \
		-t $(VERSION_IMAGE) -t $(IMAGE) --push .
	@echo "Pushed $(VERSION_IMAGE) + $(IMAGE)"

release-public: ## Promote the released :$(VERSION) + :latest (multi-arch) to GHCR — run `make release` first
	@docker buildx imagetools inspect $(VERSION_IMAGE) >/dev/null 2>&1 \
		|| { echo "$(VERSION_IMAGE) not found — run 'make release' before 'make release-public'"; exit 1; }
	docker buildx imagetools create \
		-t $(PUBLIC_IMAGE):$(VERSION) -t $(PUBLIC_IMAGE):latest \
		$(VERSION_IMAGE)
	@echo "Promoted $(VERSION_IMAGE) -> $(PUBLIC_IMAGE):$(VERSION) + :latest (same digest)"

docker-inspect: ## Inspect release image metadata
	@docker inspect $(IMAGE) --format='Version: {{index .Config.Labels "org.opencontainers.image.version"}}' 2>/dev/null || echo "Image not built"
	@docker inspect $(IMAGE) --format='Built:   {{index .Config.Labels "org.opencontainers.image.created"}}' 2>/dev/null || true
	@docker inspect $(IMAGE) --format='Commit:  {{index .Config.Labels "org.opencontainers.image.revision"}}' 2>/dev/null || true

docker-clean: ## Remove local image tags (:dev, :$(VERSION), :latest)
	docker rmi $(DEV_IMAGE) $(VERSION_IMAGE) $(IMAGE) 2>/dev/null || true

##@ Collector-only — plug into your existing InfluxDB/Grafana (compose.yml, .env.dev)

up: build-local ## Build locally + start the collector against YOUR external InfluxDB (edit .env.dev)
	KASA_IMAGE=$(LOCAL_IMAGE) $(RUN_DC) up -d
	@echo "kasa-collector $(VERSION) running (collector only, host network)"

down: ## Stop the collector
	$(RUN_DC) down

restart: ## Restart the collector
	$(RUN_DC) restart

logs: ## Follow collector logs
	$(RUN_DC) logs -f

ps: ## Collector status
	$(RUN_DC) ps

shell: ## Shell into the collector container
	$(RUN_DC) exec kasa-collector /bin/bash

##@ Dev — full LOCAL stack (your real devices + bundled InfluxDB + Grafana)

dev-up: build-local ## Build locally + start the full dev stack (real devices; Grafana http://localhost:3000)
	KASA_IMAGE=$(LOCAL_IMAGE) $(DEV_DC) up -d
	@echo "kasa-collector [dev] — Grafana http://localhost:3000 (admin/admin)"

dev-down: ## Stop the dev stack (keep data volumes)
	$(DEV_DC) down

dev-clean: ## Stop the dev stack AND delete its data volumes
	$(DEV_DC) down -v

dev-logs: ## Follow dev stack logs
	$(DEV_DC) logs -f

dev-ps: ## Dev stack status
	$(DEV_DC) ps

dev-shell: ## Shell into the collector container
	$(DEV_DC) exec kasa-collector /bin/bash

##@ Prod — local stack (pulls :latest, .env.prod)

prod-up: ## Pull :latest + start prod stack
	$(PROD_DC) pull
	$(PROD_DC) up -d

prod-down: ## Stop prod stack
	$(PROD_DC) down

prod-restart: ## Restart prod stack
	$(PROD_DC) restart

prod-logs: ## Follow prod logs
	$(PROD_DC) logs -f

prod-ps: ## Prod container status
	$(PROD_DC) ps

##@ Prod — remote deploy (set PROD_NODE=<host>)

check-prod-node:
	@test -n "$(PROD_NODE)" || { echo "Set PROD_NODE=<host> (e.g. make prod-deploy PROD_NODE=collector01.example.com)"; exit 1; }

prod-init: check-prod-node ## One-time: create the output data dir on the node (owned by appuser:1000)
	$(PROD_SSH) 'mkdir -p $(PROD_DIR)/output && chown -R 1000:1000 $(PROD_DIR)/output'
	@printf "✓ output dir created on $(PROD_NODE)\n"

prod-sync: check-prod-node ## Push compose.prod.yml + .env.prod to the node (repo is source of truth)
	rsync -az --chown=1000:1000 compose.prod.yml .env.prod $(PROD_USER)@$(PROD_NODE):$(PROD_DIR)/
	@printf "✓ synced config to $(PROD_NODE):$(PROD_DIR)\n"

prod-deploy: check-prod-node ## Pull :latest + recreate the collector on the node (run release first)
	$(PROD_SSH) 'cd $(PROD_DIR) && $(PROD_DC) pull && $(PROD_DC) up -d'
	@printf "✓ deployed to $(PROD_NODE)\n"

prod-status: check-prod-node ## Container status on the node
	$(PROD_SSH) 'cd $(PROD_DIR) && $(PROD_DC) ps'

prod-logs-remote: check-prod-node ## Follow collector logs on the node
	$(PROD_SSH) 'cd $(PROD_DIR) && $(PROD_DC) logs --tail=100 -f'

prod-health: check-prod-node ## Run the in-container health check on the node
	$(PROD_SSH) 'cd $(PROD_DIR) && $(PROD_DC) exec -T kasa-collector python3 -m app.health.check'

prod-rollback: check-prod-node ## List image tags cached on the node for rollback
	$(PROD_SSH) 'docker images $(REGISTRY)/$(IMAGE_NAME) --format "table {{.Tag}}\t{{.CreatedAt}}"'

##@ Demo / quickstart (self-contained: collector + InfluxDB + Grafana)

demo-up: build-local ## Bring up the demo stack — FAKE devices + auto-provisioned InfluxDB + Grafana
	KASA_IMAGE=$(LOCAL_IMAGE) $(DEMO_DC) up -d --build
	@echo "Grafana:  http://localhost:3000  (admin/admin)  — dashboards populate from fake devices"
	@echo "InfluxDB: http://localhost:8086"

demo-down: ## Stop the demo stack (keep data volumes)
	$(DEMO_DC) down

demo-clean: ## Stop the demo stack AND delete its data volumes
	$(DEMO_DC) down -v

demo-logs: ## Follow demo stack logs
	$(DEMO_DC) logs -f

demo-ps: ## Demo stack status
	$(DEMO_DC) ps

##@ Dependencies (poetry in docker — no host poetry required)

poetry-lock: ## Generate/refresh poetry.lock from pyproject.toml (docker, no install)
	$(POETRY_RUN) '$(POETRY_PIP) && /tmp/v/bin/poetry lock'

poetry-update: ## Update deps to latest allowed + rewrite poetry.lock (docker)
	$(POETRY_RUN) '$(POETRY_PIP) && /tmp/v/bin/poetry update --lock'

poetry-install: ## Verify deps resolve + install cleanly from poetry.lock (docker, throwaway venv)
	$(POETRY_RUN) '$(POETRY_PIP) && /tmp/v/bin/poetry install --no-root --only main'

##@ Quality (lint · types · tests · secrets)

# $(call _guard_check,<name>,<registry>,<pin>) — pull :latest FIRST (a locally-cached
# :latest reports a stale version, so an agent "confirms latest" while behind), then
# compare. Non-fatal: prints a nudge, never fails the build. Skips if the host is unset.
define _guard_check
	if [ -n "$(2)" ]; then \
	  docker pull -q $(2)/luxardolabs/$(1):latest >/dev/null 2>&1 || true; \
	  latest=$$(docker run --rm $(2)/luxardolabs/$(1):latest --version 2>/dev/null | awk '{print $$2}'); \
	  if [ -n "$$latest" ] && [ "$$latest" != "$(3)" ]; then \
	    printf "⚠ %s pinned %s, latest %s — bump the pin (preview: --new-rules --since %s)\n" "$(1)" "$(3)" "$$latest" "$(3)"; \
	  fi; \
	fi
endef

guard-version-check: ## Warn (non-fatal) if any guard pin is behind :latest — pulls first, so it can't lie
	@$(call _guard_check,luxarch,$(LUXARCH_REGISTRY),$(LUXARCH_VERSION))
	@$(call _guard_check,luxlint,$(LUXLINT_REGISTRY),$(LUXLINT_VERSION))
	@$(call _guard_check,luxaudit,$(LUXAUDIT_REGISTRY),$(LUXAUDIT_VERSION))

lint: guard-version-check ## luxlint (ruff, mount-only) + mypy tail — ONE recipe; fails if either fails
	@set +e; \
	if [ -z "$(LUXLINT_REGISTRY)" ]; then \
	  echo "luxlint: LUXLINT_REGISTRY unset (see Makefile.local.example) — skipping"; exit 0; \
	fi; \
	docker run --rm -v $(PWD):/repo $(LUXLINT_IMAGE); ruff=$$?; \
	docker run --rm -v $(PWD):/repo $(LUXLINT_IMAGE) --emit-config mypy > .luxlint.mypy.ini; \
	docker run --rm -v $(PWD)/.luxlint.mypy.ini:/cfg/mypy.ini:ro -v $(PWD):/w -w /w -e MYPYPATH=/w python:3.14-slim \
	  sh -c 'pip install -q "mypy>=2.3" && mypy --config-file /cfg/mypy.ini app'; mypy=$$?; \
	rm -f .luxlint.mypy.ini; \
	if [ $$ruff -ne 0 ] || [ $$mypy -ne 0 ]; then \
	  echo "lint FAILED (luxlint=$$ruff mypy=$$mypy)"; exit 1; \
	fi

format: ## Auto-fix + format with the canonical luxlint ruff config (writes back)
	@set +e; \
	if [ -z "$(LUXLINT_REGISTRY)" ]; then \
	  echo "luxlint: LUXLINT_REGISTRY unset (see Makefile.local.example) — skipping"; exit 0; \
	fi; \
	docker run --rm -v $(PWD):/repo $(LUXLINT_IMAGE) --emit-config ruff > .ruff.local.toml; \
	docker run --rm --user $(REPO_UID):$(REPO_GID) -e HOME=/tmp -v $(PWD):/w -w /w python:3.14-slim \
	  sh -c 'python -m venv /tmp/v && /tmp/v/bin/pip install -q ruff && { /tmp/v/bin/ruff check --fix --config .ruff.local.toml app; /tmp/v/bin/ruff format --config .ruff.local.toml app; }'

# Rebuild the lean test image ONLY when deps change — the stamp is keyed on the lock +
# Dockerfile.test (per FLEET-BUILD-DEPLOY-STANDARD: deps from the lock, rebuilt on lock
# change; NOT FROM :dev). A source edit never triggers a rebuild (source is over-mounted).
.test-image.stamp: Dockerfile.test poetry.lock pyproject.toml
	DOCKER_BUILDKIT=1 docker build $(NO_CACHE_FLAG) -f Dockerfile.test \
	  --build-arg POETRY_VERSION=$(POETRY_VERSION) -t $(TEST_IMAGE) .
	@touch $@

test: .test-image.stamp ## Run the pytest suite via the canonical luxlint pytest config (in-repo tail)
	@set +e; \
	if [ -z "$(LUXLINT_REGISTRY)" ]; then \
	  echo "luxlint: LUXLINT_REGISTRY unset (see Makefile.local.example) — skipping unit tests; use 'make test-e2e'"; exit 0; \
	fi; \
	docker run --rm -v $(PWD):/repo $(LUXLINT_IMAGE) --emit-config pytest > .luxlint.pytest.ini; \
	docker run --rm -v $(PWD):/w -w /w $(TEST_IMAGE) \
	  pytest -c .luxlint.pytest.ini -p no:cacheprovider; test=$$?; \
	rm -f .luxlint.pytest.ini; \
	exit $$test

arch: ## Architecture conformance via luxarch (pinned; reads .luxarch.toml)
	@if [ -z "$(LUXARCH_REGISTRY)" ]; then \
	  echo "luxarch: LUXARCH_REGISTRY unset (see Makefile.local.example) — skipping"; \
	else docker run --rm -v $(PWD):/repo $(LUXARCH_REGISTRY)/luxardolabs/luxarch:$(LUXARCH_VERSION); fi

audit: ## Scan pinned deps against the live vulnerability feed (luxaudit)
	@if [ -z "$(LUXAUDIT_REGISTRY)" ]; then \
	  echo "luxaudit: LUXAUDIT_REGISTRY unset (see Makefile.local.example) — skipping"; \
	else docker run --rm -v $(PWD):/repo $(LUXAUDIT_REGISTRY)/luxardolabs/luxaudit:$(LUXAUDIT_VERSION); fi

# Built and consumed locally by the e2e harness (never pushed) — no registry needed.
E2E_IMAGE := kasa-collector:e2e
test-e2e: ## Hardware-free end-to-end test: fake Kasa devices -> collector -> InfluxDB
	docker build $(NO_CACHE_FLAG) --target base -f Dockerfile $(BUILD_ARGS) -t $(E2E_IMAGE) .
	KASA_IMAGE=$(E2E_IMAGE) ./scripts/e2e-test.sh

check: lint arch audit test gitleaks ## Run lint + arch + audit + test + secret scan

hooks: ## Install the repo git hooks (pre-commit runs gitleaks-staged)
	git config core.hooksPath .githooks
	@printf "✓ core.hooksPath -> .githooks (pre-commit secret scan active)\n"

# gitleaks uses the canonical fleet config (defaults + org denylist), EMITTED by luxlint
# at scan time and mounted OUTSIDE the /repo scan root — never committed (a committed
# config would carry the very denylist strings it forbids). Per luxlint --doc ONBOARDING §4a.
gitleaks: ## Scan full history for secrets + org denylist (canonical luxlint config)
	@set +e; \
	if [ -z "$(LUXLINT_REGISTRY)" ]; then \
	  echo "luxlint: LUXLINT_REGISTRY unset (see Makefile.local.example) — skipping"; exit 0; \
	fi; \
	docker run --rm -v $(PWD):/repo $(LUXLINT_IMAGE) --emit-config gitleaks > .luxlint.gitleaks.toml; \
	docker run --rm -v $(PWD):/repo -w /repo -v $(PWD)/.luxlint.gitleaks.toml:/cfg/gitleaks.toml:ro \
	  ghcr.io/gitleaks/gitleaks:latest detect --source /repo --config /cfg/gitleaks.toml --redact -v; gl=$$?; \
	rm -f .luxlint.gitleaks.toml; \
	exit $$gl

gitleaks-staged: ## Pre-commit secret scan of staged changes (canonical luxlint config)
	@set +e; \
	if [ -z "$(LUXLINT_REGISTRY)" ]; then \
	  echo "luxlint: LUXLINT_REGISTRY unset (see Makefile.local.example) — skipping"; exit 0; \
	fi; \
	docker run --rm -v $(PWD):/repo $(LUXLINT_IMAGE) --emit-config gitleaks > .luxlint.gitleaks.toml; \
	docker run --rm -v $(PWD):/repo -w /repo -v $(PWD)/.luxlint.gitleaks.toml:/cfg/gitleaks.toml:ro \
	  ghcr.io/gitleaks/gitleaks:latest protect --staged --source /repo --config /cfg/gitleaks.toml --redact -v; gl=$$?; \
	rm -f .luxlint.gitleaks.toml; \
	exit $$gl

##@ Utilities

clean: ## Clean python/test caches
	find . -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
	find . -type f -name "*.pyc" -delete 2>/dev/null || true
	rm -rf .pytest_cache/ .mypy_cache/ .ruff_cache/ .coverage htmlcov/

clean-all: clean docker-clean ## Clean caches + local docker image tags
