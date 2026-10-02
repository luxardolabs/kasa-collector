# =============================================================================
# kasa-collector — fleet build/deploy Makefile
# Source of truth for the version is the VERSION file at the repo root.
# Compose never builds; the Makefile builds the image + pushes it to the registry,
# and the dev/prod stacks pull it. Mirrors the bb-boutique fleet standard, trimmed
# for a single-service collector (host networking, no db/redis/nginx/css).
# =============================================================================

VERSION := $(shell cat VERSION 2>/dev/null || git -c safe.directory=$(CURDIR) describe --tags --always 2>/dev/null || echo "0.0.0-dev")
# Human-facing name in the GitHub Release title, e.g. "Kasa Collector 2026.09.0".
APP_TITLE := Kasa Collector
TIMESTAMP := $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
COMMIT := $(shell git -c safe.directory=$(CURDIR) rev-parse --short HEAD 2>/dev/null || echo 'local')

# The private-registry host is kept OUT of this public tree — set it in an untracked
# Makefile.local (see Makefile.local.example). Included FIRST so its values win over the
# empty defaults below. Without it, the local/e2e stacks still build; only the targets
# that pull from the private registry (dev-deploy / release / prod / lint / arch / audit)
# need it. Lint/type/test are decoupled from :dev per FLEET-BUILD-DEPLOY-STANDARD — ruff AND
# mypy are mount-only luxlint (the repo installs nothing), pytest is a lock-keyed image.
-include Makefile.local

# Registry / images. REGISTRY comes from Makefile.local or the CLI; empty by default so no
# internal hostname is committed. `make dev-deploy REGISTRY=...` still overrides.
#
# The NAME declares what an image IS (luxarch --doc FLEET-BUILD-DEPLOY-STANDARD, image block):
#   registry-qualified -> a DEPLOY artifact, built AND pushed by the same target
#   bare               -> a LOCAL artifact, built from source, never pushed
#   :$(VERSION) / :sha-<commit> -> IMMUTABLE, the only tags a stack may pin (TAG= in .env.<env>)
#   :dev / :latest              -> moving ALIASES for a human; nothing pins them or builds FROM them
REGISTRY ?=
IMAGE_NAME := luxardolabs/kasa-collector
# BASE — no tag; every tag composes from it. Comments sit ABOVE assignments: GNU make keeps
# the whitespace before an inline `#`, which would make every composed tag an invalid reference.
IMAGE         := $(REGISTRY)/$(IMAGE_NAME)
VERSION_IMAGE := $(IMAGE):$(VERSION)
SHA_IMAGE     := $(IMAGE):sha-$(COMMIT)
DEV_ALIAS     := $(IMAGE):dev
LATEST_ALIAS  := $(IMAGE):latest
# LOCAL verification images for the hardware-free stacks — BARE on purpose, so they cannot be
# pushed by accident or mistaken for a deployable, and a clean clone needs no registry.
E2E_IMAGE  := kasa-collector:test
FAKE_IMAGE := kasa-collector-fake:test
# Public OSS image on GitHub Container Registry (the fleet's external registry,
# not Docker Hub). EXTERNAL_REGISTRY overridable.
EXTERNAL_REGISTRY ?= ghcr.io
PUBLIC_IMAGE := $(EXTERNAL_REGISTRY)/$(IMAGE_NAME)

# Architecture guard (luxarch) — pinned; pulled via LUXARCH_REGISTRY (Makefile.local).
# Bump LUXARCH_VERSION when adopting new rules. Unset host → `make arch` skips gracefully.
LUXARCH_REGISTRY ?=
LUXARCH_VERSION  := 0.249.3
LUXARCH_IMAGE    ?= $(LUXARCH_REGISTRY)/luxardolabs/luxarch:$(LUXARCH_VERSION)

# Code-style + type guard (luxlint) — pinned; pulled via LUXLINT_REGISTRY (Makefile.local),
# same out-of-tree pattern as luxarch. Unset host → make lint/format skip gracefully.
LUXLINT_REGISTRY ?=
LUXLINT_VERSION  := 0.60.1
LUXLINT_IMAGE    ?= $(LUXLINT_REGISTRY)/luxardolabs/luxlint:$(LUXLINT_VERSION)
# The luxlint ref the emitted gitleaks block reads. Without the fleet registry it falls back
# to a local guard build (`luxlint:local`), and the block then pulls the public gitleaks image.
LUXLINT = $(if $(LUXLINT_REGISTRY),$(LUXLINT_IMAGE),luxlint:local)

# Dependency-vulnerability guard (luxaudit) — pinned; pulled via LUXAUDIT_REGISTRY (Makefile.local).
# Scans poetry.lock against the live OSV+PyPA feed. Unset host → `make audit` skips gracefully.
LUXAUDIT_REGISTRY ?=
LUXAUDIT_VERSION  := 0.13.0
LUXAUDIT_IMAGE    ?= $(LUXAUDIT_REGISTRY)/luxardolabs/luxaudit:$(LUXAUDIT_VERSION)
PLATFORMS ?= linux/amd64,linux/arm64

BUILD_ARGS := --build-arg BUILD_VERSION=$(VERSION) \
              --build-arg BUILD_TIMESTAMP=$(TIMESTAMP) \
              --build-arg BUILD_COMMIT=$(COMMIT)

# Cache busting: `make dev-deploy NOCACHE=1`
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
# POETRY_VIRTUALENVS_IN_PROJECT=false is load-bearing, not hygiene. The repo is mounted at
# /work, and Poetry silently ADOPTS an existing ./.venv when it finds one — so a stray local
# venv becomes the resolution environment inside the container. That is not theoretical: it
# made `poetry update --dry-run` report NO changes while 11 packages were actually behind
# (the truth only appeared when resolving in a throwaway copy). A container that reads host
# state through the mount isn't hermetic, and a lock tool that lies about "nothing to do" is
# the worst kind of quiet. Any venv Poetry needs (poetry-install) now lands in the cache under
# HOME=/tmp, ephemeral with the container. The fleet rule is no local .venv — everything in
# Docker; a .venv is at most a gitignored editor convenience and never an execution path.
POETRY_RUN := docker run --rm -u $(REPO_UID):$(REPO_GID) -e HOME=/tmp \
              -e POETRY_VIRTUALENVS_IN_PROJECT=false -e POETRY_VIRTUALENVS_CREATE=true \
              -v $(PWD):/work -w /work python:3.14-slim sh -c
POETRY_PIP := python -m venv /tmp/v && /tmp/v/bin/pip install -q --root-user-action=ignore $(POETRY_SPEC)

# Compose stacks (all .yml, short-form volumes). Four flavors:
#   compose.yml       THE one compose file. Stacks are PROFILES of it:
#     collector         the real collector, HOST network (prod + dev)
#     bundled           + bundled InfluxDB & Grafana (dev)
#     demo              fake devices + bundled stack, no hardware -> `make demo-up`
#     e2e               fakes + throwaway InfluxDB          -> `make test-e2e`
# ONE compose.yml (fleet standard): the STACK is the --profile and the ENVIRONMENT is
# the --env-file. The fake-device stacks need a bridge network so the collector can
# resolve the emulators by service name, which host networking cannot do — so they are
# separate SERVICES gated by profile, not separate files.
RUN_DC  := docker compose --env-file .env.prod
PROD_DC := docker compose --env-file .env.prod
DEV_DC  := docker compose --env-file .env.dev
DEMO_DC := docker compose --env-file .env.demo

# Remote prod deploy over SSH. The collector runs on a host with LAN access to the
# Kasa devices; set the node explicitly (no fleet default — this app is not bb01).
#   make prod-deploy PROD_NODE=collector01.example.com
PROD_NODE ?=
PROD_USER ?= root
PROD_DIR  ?= /opt/kasa-collector
PROD_SSH  := ssh -o BatchMode=yes $(PROD_USER)@$(PROD_NODE)

.PHONY: help version \
        guard-clean-tree dev-deploy dev-pin harness-build release-scan release release-public gh-release buildx-setup \
        docker-inspect docker-clean \
        up down restart logs ps shell \
        dev-up dev-down dev-clean dev-logs dev-ps dev-shell \
        prod-up prod-down prod-restart prod-logs prod-ps \
        demo-up demo-down demo-clean demo-logs demo-ps \
        check-prod-node prod-init prod-sync prod-deploy prod-status prod-logs-remote prod-health prod-rollback \
        poetry-lock poetry-update poetry-install \
        guard-version-check guard-upgrade honest lint mypy format test arch plan status audit test-e2e check onboard-check \
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
	@echo "Build:     $(SHA_IMAGE)  (alias $(DEV_ALIAS))"
	@echo "Release:   $(VERSION_IMAGE)  +  $(SHA_IMAGE)  (alias $(LATEST_ALIAS))"
	@echo "Public:    $(PUBLIC_IMAGE):$(VERSION)"

##@ Docker — Build & Registry

# ONE shared fleet buildx builder — never a per-project one. Each per-project builder holds a
# completely separate cache (no base-layer/pip dedup, unbounded growth) plus an idle buildkit
# daemon; ten of them measured ~72G, deduplicating to ~10-15G on a single shared builder, which
# also buys cross-project cache hits. The buildkitd GC policy is the required second half
# (repo.buildx_builder_gc_capped) — a canonical name says nothing about whether it self-prunes.
# See luxarch --doc FLEET-BUILD-DEPLOY-STANDARD ("One shared buildx builder").
# The buildkitd GC policy is written here when absent (the emitted block assumes it exists);
# the rest of the recipe is the emitted asset.
# luxarch:buildx-setup asset v1 - DO NOT edit this marker line; it is how repo.emitted_assets_current knows your copy is current. Re-emit with `luxarch --emit buildx-setup`.
BUILDX_BUILDER ?= luxardo-builder
BUILDKITD_CONFIG ?= $(HOME)/.docker/buildkitd.toml
buildx-setup: ## Ensure the SHARED fleet buildx builder exists, GC-capped (multi-arch release builds)
	@if [ ! -f "$(BUILDKITD_CONFIG)" ]; then \
	  mkdir -p $$(dirname $(BUILDKITD_CONFIG)); \
	  printf '[worker.oci]\n  gc = true\n  [[worker.oci.gcpolicy]]\n    keepBytes = "20GB"\n    all = true\n' > $(BUILDKITD_CONFIG); \
	  echo "wrote default GC-capped buildkitd config -> $(BUILDKITD_CONFIG)"; \
	fi
	@docker buildx inspect $(BUILDX_BUILDER) >/dev/null 2>&1 || \
	  docker buildx create --name $(BUILDX_BUILDER) --driver docker-container \
	    --buildkitd-config $(BUILDKITD_CONFIG) --use
	@docker buildx use $(BUILDX_BUILDER)
	@strays=$$(docker buildx ls 2>/dev/null | awk '$$2=="docker-container"{print $$1}' \
	  | grep -v '^\\_' | sed 's/\*$$//' | grep -vxF "$(BUILDX_BUILDER)" | tr '\n' ' '); \
	if [ -n "$$strays" ] && [ -z "$(ALLOW_STRAY_BUILDERS)" ]; then \
	  echo "REFUSING: stray per-project buildx builders are running: $$strays"; \
	  echo "Remove them:  docker buildx rm $$strays"; \
	  exit 1; \
	fi

# A `sha-<commit>` (or version) tag is immutable only if the bits ARE that commit: a build from a
# dirty tree publishes HEAD's name over different contents, indistinguishable afterwards from a
# truthful one. Untracked files count — they are in the build context. Commit first.
guard-clean-tree:
	@if [ -n "$$(git status --porcelain 2>/dev/null)" ]; then \
	  echo "REFUSING: the working tree is dirty, so sha-$(COMMIT) would not describe these bits:"; \
	  git status --short | sed 's/^/    /'; \
	  echo "Commit first, then deploy what you pushed."; \
	  exit 1; \
	fi

# Every build of the runtime stage gets its permanent `:sha-<commit>` name; `:dev` is only a
# label moved onto it afterwards. Single-arch (the dev node's); `release` is the multi-arch path.
# SCAN THE CANDIDATE, THEN PUSH (luxaudit >= 0.13.0 `--image-archive`, image-block v5): the exact
# bits just built are scanned mount-only, and any fixable HIGH/CRITICAL refuses the push. `make
# audit`'s image leg only reports what the registry ALREADY holds, so it cannot gate a release.
define scan_candidate
	@set -e; T=$$(mktemp); trap 'rm -f "$$T"' EXIT INT TERM; \
	docker save $(1) -o "$$T"; chmod 644 "$$T"; \
	docker run --rm -v $(PWD):/repo -v luxaudit-cache:/root/.cache/trivy -v "$$T":/candidate.tar:ro \
	  $(LUXAUDIT_IMAGE) --image-archive /candidate.tar --image-label $(2)
endef

dev-deploy: guard-clean-tree ## Build, SCAN, push THIS commit as :sha-<commit>, pin .env.dev to it, restart the dev stack
	docker build $(NO_CACHE_FLAG) --target base -f Dockerfile $(BUILD_ARGS) -t $(SHA_IMAGE) .
	$(call scan_candidate,$(SHA_IMAGE),$(SHA_IMAGE))
	docker push $(SHA_IMAGE)
	docker tag $(SHA_IMAGE) $(DEV_ALIAS) && docker push $(DEV_ALIAS)
	@$(MAKE) --no-print-directory dev-pin TAG=sha-$(COMMIT)

# The tag is PERSISTED into .env.<env> (compose reads ${TAG:?}), so the stack comes back after a
# reboot. Exactly ONE line of that gitignored, secret-bearing file is rewritten; nothing else is
# read, printed or reordered.
TAG ?= sha-$(COMMIT)

define pin_env_tag
	f='$(1)'; t='$(2)'; \
	[ -f "$$f" ] || { echo "$$f is missing — copy .env.example and fill it in first"; exit 1; }; \
	tmp=$$(mktemp); trap 'rm -f "$$tmp"' EXIT; \
	if grep -qE '^[[:space:]]*TAG=' "$$f"; then \
	  awk -v t="$$t" '/^[[:space:]]*TAG=/ && !d {print "TAG=" t; d=1; next} {print}' "$$f" > "$$tmp"; \
	else \
	  cp "$$f" "$$tmp" && printf 'TAG=%s\n' "$$t" >> "$$tmp"; \
	fi; \
	[ -s "$$tmp" ] || { echo "refusing to write an empty $$f"; exit 1; }; \
	o=$$(wc -l < "$$f"); n=$$(wc -l < "$$tmp"); \
	[ "$$n" -ge "$$o" ] || { echo "refusing: rewriting $$f lost lines ($$o -> $$n)"; exit 1; }; \
	cat "$$tmp" > "$$f"; \
	echo "$$f: TAG=$$t"
endef

# The rollback path, and the only one that does not build: name a tag already published. The
# registry is checked FIRST — a stack pinned to a name the registry never held fails only at the
# next restart, when there is nothing to re-pull.
dev-pin: ## Point the dev stack at an ALREADY-PUBLISHED tag and restart it (rollback path)
	@docker manifest inspect $(IMAGE):$(TAG) >/dev/null 2>&1 || \
	  { echo "$(IMAGE):$(TAG) is not in the registry — publish it before pinning a stack to it"; exit 1; }
	@$(call pin_env_tag,.env.dev,$(TAG))
	$(DEV_DC) up -d

# The emulator is a TEST FIXTURE, never a released artifact: built locally under a BARE name and
# never pushed, so the demo and e2e stacks resolve it from the local store with no registry.
harness-build: ## Build the fake-device emulator image (compose never builds — it runs a tag)
	docker build $(NO_CACHE_FLAG) -t $(FAKE_IMAGE) ./harness
	@echo "built $(FAKE_IMAGE)"

# The multi-arch buildx push cannot be `docker save`d, so the candidate is the same runtime stage
# built locally (host arch) under the BARE verification name, scanned before anything is pushed —
# the shape luxarch, luxlint and luxaudit use for their own multi-arch releases.
release-scan: ## Build + scan the release candidate for fixable HIGH/CRITICAL before anything is pushed
	docker build $(NO_CACHE_FLAG) --target base -f Dockerfile $(BUILD_ARGS) -t $(E2E_IMAGE) .
	$(call scan_candidate,$(E2E_IMAGE),$(VERSION_IMAGE))

# The cut release: multi-arch, the immutable :$(VERSION) and :sha-<commit>, plus the :latest
# alias the public GHCR promotion copies. prod pins :$(VERSION) in .env.prod.
release: guard-clean-tree release-scan buildx-setup ## Build + push :$(VERSION) + :sha-<commit> (multi-arch, alias :latest) to the private registry
	docker buildx build $(NO_CACHE_FLAG) --target base --platform $(PLATFORMS) -f Dockerfile $(BUILD_ARGS) \
		-t $(VERSION_IMAGE) -t $(SHA_IMAGE) -t $(LATEST_ALIAS) --push .
	@echo "Pushed $(VERSION_IMAGE) + $(SHA_IMAGE) + $(LATEST_ALIAS)"

release-public: ## Promote the released :$(VERSION) + :latest (multi-arch) to GHCR — run `make release` first
	@docker buildx imagetools inspect $(VERSION_IMAGE) >/dev/null 2>&1 \
		|| { echo "$(VERSION_IMAGE) not found — run 'make release' before 'make release-public'"; exit 1; }
	docker buildx imagetools create \
		-t $(PUBLIC_IMAGE):$(VERSION) -t $(PUBLIC_IMAGE):latest \
		$(VERSION_IMAGE)
	@echo "Promoted $(VERSION_IMAGE) -> $(PUBLIC_IMAGE):$(VERSION) + :latest (same digest)"
	@$(MAKE) --no-print-directory gh-release

gh-release: ## Publish the GitHub Release for v$(VERSION) from its release notes
	@test -f app/release_notes/$(VERSION).md \
	  || { echo "app/release_notes/$(VERSION).md missing — write it before releasing"; exit 1; }
	@git rev-parse -q --verify "refs/tags/v$(VERSION)" >/dev/null \
	  || { echo "tag v$(VERSION) does not exist — tag before publishing the release"; exit 1; }
	@if gh release view v$(VERSION) >/dev/null 2>&1; then \
	  echo "GitHub Release v$(VERSION) already exists — leaving it alone"; \
	else \
	  gh release create v$(VERSION) --title "$(APP_TITLE) $(VERSION)" \
	    --notes-file app/release_notes/$(VERSION).md --latest \
	  && echo "Published GitHub Release v$(VERSION)"; \
	fi

docker-inspect: ## Inspect release image metadata
	@docker inspect $(VERSION_IMAGE) --format='Version: {{index .Config.Labels "org.opencontainers.image.version"}}' 2>/dev/null || echo "Image not built"
	@docker inspect $(VERSION_IMAGE) --format='Built:   {{index .Config.Labels "org.opencontainers.image.created"}}' 2>/dev/null || true
	@docker inspect $(VERSION_IMAGE) --format='Commit:  {{index .Config.Labels "org.opencontainers.image.revision"}}' 2>/dev/null || true

docker-clean: ## Remove local image tags (this commit's :sha, :$(VERSION), the aliases, the bare test images)
	docker rmi $(SHA_IMAGE) $(VERSION_IMAGE) $(DEV_ALIAS) $(LATEST_ALIAS) $(E2E_IMAGE) $(FAKE_IMAGE) 2>/dev/null || true

##@ Collector-only — plug into your existing InfluxDB/Grafana (compose.yml, .env.prod)

up: ## Start the collector against YOUR external InfluxDB (runs the TAG pinned in .env.prod)
	$(RUN_DC) up -d
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

# Runs whatever .env.dev pins. To run new code: commit, then `make dev-deploy` (build + push
# :sha-<commit>, pin, restart). `make dev-pin TAG=…` rolls back to an already-published tag.
dev-up: ## Start the full dev stack at the TAG pinned in .env.dev (Grafana on GRAFANA_PORT)
	$(DEV_DC) up -d
	@echo "kasa-collector [dev] — Grafana on the port set by GRAFANA_PORT in .env.dev (admin/admin)"

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

##@ Prod — local stack (pulls the :$(VERSION) pinned in .env.prod)

prod-up: ## Pull the pinned release + start prod stack
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

prod-sync: check-prod-node ## Push compose.yml + .env.prod to the node (repo is source of truth)
	rsync -az --chown=1000:1000 compose.yml .env.prod $(PROD_USER)@$(PROD_NODE):$(PROD_DIR)/
	@printf "✓ synced config to $(PROD_NODE):$(PROD_DIR)\n"

prod-deploy: check-prod-node ## Pull the pinned release + recreate the collector on the node (run release first)
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

demo-up: harness-build ## Bring up the demo stack — FAKE devices + auto-provisioned InfluxDB + Grafana
	$(DEMO_DC) up -d
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
# compare. FATAL: a pin behind the published latest FAILS `make check` (exit 1) — a
# warn-only check is the exact hole that let an agent work off a stale guard and delete
# code the current rules would have told it to ASK about (luxarch 0.97.0). Clear it with
# `make guard-upgrade`. Skips only when the registry host is unset (nothing to compare).
define _guard_check
	if [ -n "$(2)" ]; then \
	  docker pull -q $(2)/luxardolabs/$(1):latest >/dev/null 2>&1 || true; \
	  latest=$$(docker run --rm $(2)/luxardolabs/$(1):latest --version 2>/dev/null | awk '{print $$2}'); \
	  if [ -n "$$latest" ] && [ "$$latest" != "$(3)" ]; then \
	    printf "✗ %s pinned %s, latest %s — behind. Preview: --new-rules --since %s; then 'make guard-upgrade'\n" "$(1)" "$(3)" "$$latest" "$(3)"; \
	    exit 1; \
	  fi; \
	fi
endef

guard-version-check: ## FATAL: fail if any guard pin is behind :latest — pulls first, so it can't lie
	@rc=0; \
	( $(call _guard_check,luxarch,$(LUXARCH_REGISTRY),$(LUXARCH_VERSION)) ) || rc=1; \
	( $(call _guard_check,luxlint,$(LUXLINT_REGISTRY),$(LUXLINT_VERSION)) ) || rc=1; \
	( $(call _guard_check,luxaudit,$(LUXAUDIT_REGISTRY),$(LUXAUDIT_VERSION)) ) || rc=1; \
	exit $$rc

# Per-guard registry variables are this repo's edit to the emitted asset (the guard hosts live in
# Makefile.local); the rest is the asset.
# luxarch:guard-upgrade asset v1 - DO NOT edit this marker line; it is how repo.emitted_assets_current knows your copy is current. Re-emit with `luxarch --emit guard-upgrade`.
guard-upgrade: ## Bump every guard pin to the published latest (prints what newly bites)
	@for g in luxarch luxlint luxaudit; do \
	  reg=$$(case $$g in luxarch) echo "$(LUXARCH_REGISTRY)";; luxlint) echo "$(LUXLINT_REGISTRY)";; luxaudit) echo "$(LUXAUDIT_REGISTRY)";; esac); \
	  if [ -z "$$reg" ]; then echo "!! $$g registry unset — NOT bumped"; continue; fi; \
	  docker pull -q $$reg/luxardolabs/$$g:latest >/dev/null 2>&1 || true; \
	  latest=$$(docker run --rm $$reg/luxardolabs/$$g:latest --version 2>/dev/null | awk '{print $$2}'); \
	  var=$$(echo $$g | tr a-z A-Z)_VERSION; \
	  old=$$(sed -n -E "s/^$$var[[:space:]]*:=[[:space:]]*//p" Makefile); \
	  if [ -z "$$old" ]; then echo "!! no $$var pin found in Makefile — NOT bumped"; continue; fi; \
	  if [ -z "$$latest" ]; then echo "!! could not read $$g:latest — $$var left at $$old"; continue; fi; \
	  checked=1; \
	  sed -i -E "s|^($$var[[:space:]]*:=[[:space:]]*).*|\\1$$latest|" Makefile; \
	  new=$$(sed -n -E "s/^$$var[[:space:]]*:=[[:space:]]*//p" Makefile); \
	  if [ "$$new" != "$$latest" ]; then echo "!! $$var did NOT change (still $$new)"; exit 1; fi; \
	  if [ "$$old" != "$$latest" ]; then echo "$$var $$old -> $$latest"; bumped=1; fi; \
	  [ "$$g" = luxarch ] && [ "$$old" != "$$latest" ] && docker run --rm -v $(PWD):/repo $$reg/luxardolabs/luxarch:$$latest --new-rules --since $$old || true; \
	done; \
	if [ -n "$$bumped" ]; then echo "pins bumped — re-run make check"; \
	elif [ -n "$$checked" ]; then echo "all pins already at latest"; \
	else echo "!! could not reach the registry — NO pin was checked; currency NOT established"; exit 1; fi

lint: ## luxlint — ruff/format/docs/secret checks (canonical config, mount-only)
	@if [ -z "$(LUXLINT_REGISTRY)" ]; then \
	  echo "luxlint: LUXLINT_REGISTRY unset (see Makefile.local.example) — skipping"; \
	else docker run --rm -v $(PWD):/repo $(LUXLINT_IMAGE); fi

# mypy runs MOUNT-ONLY inside the luxlint image, exactly like ruff — the repo installs
# nothing. The old in-repo tail (a bare python:3.14-slim + pip install mypy) ran WITHOUT the
# app's deps, so every py.typed library degraded to Any and `strict` checked almost nothing:
# a hollow-green type checker. luxlint bakes the fleet's typed dependency union
# (standards/mypy-libs.txt), so imports resolve and the check is real. If a red concentrates
# on one import of a TYPED lib, that lib is missing from the baked set — ESCALATE to luxlint
# to add it; never add a local mypy config or a # type: ignore. See luxlint 0.24.0 ONBOARDING.
mypy: ## mypy (fleet typed deps baked, mount-only)
	@if [ -z "$(LUXLINT_REGISTRY)" ]; then \
	  echo "luxlint: LUXLINT_REGISTRY unset (see Makefile.local.example) — skipping"; \
	else docker run --rm -v $(PWD):/repo $(LUXLINT_IMAGE) --mypy; fi

# THE canonical fixer — `luxlint --format` (the only luxlint mode that writes). It applies
# the autofix + formatter legs with the SAME config the checker reads, and formats Markdown
# through the image's mdformat + mdformat-gfm, so fixer and checker can never diverge.
# Do NOT hand-roll this. The previous recipe pip-installed the formatter UNPINNED into a
# throwaway venv, so it could drift from the pinned checker's version; and invoking the
# host tool directly applies its DEFAULT width to a repo that deliberately carries no local
# config, which rewrote ~1000 files wrong in one fleet repo. A bare `mdformat` without the
# GFM plugin also COLLAPSES tables. See luxlint 0.11.0 / 0.12.0 and luxarch 0.21.3.
# (Wording note: this comment avoids the literal two-word formatter invocation on purpose —
# onboard-check greps the whole Makefile for it and cannot mask comments, so prose
# describing the standard would otherwise fail the probe forever. See luxarch 0.21.9,
# which hit exactly this self-match in its own recipe.)
format: ## Auto-fix + format Python and Markdown via the canonical luxlint fixer (writes back)
	@if [ -z "$(LUXLINT_REGISTRY)" ]; then \
	  echo "luxlint: LUXLINT_REGISTRY unset (see Makefile.local.example) — skipping"; \
	else docker run --rm --user $(REPO_UID):$(REPO_GID) -e HOME=/tmp -v $(PWD):/repo $(LUXLINT_IMAGE) --format; fi

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
	docker image inspect $(TEST_IMAGE) >/dev/null 2>&1 || { echo "test image absent (pruned) — rebuilding"; rm -f .test-image.stamp; $(MAKE) --no-print-directory .test-image.stamp || exit 1; }; \
	docker run --rm -v $(PWD):/repo $(LUXLINT_IMAGE) --emit-config pytest > .luxlint.pytest.ini; \
	docker run --rm -v $(PWD):/w -w /w $(TEST_IMAGE) \
	  pytest -c .luxlint.pytest.ini -p no:cacheprovider; test=$$?; \
	rm -f .luxlint.pytest.ini; \
	exit $$test

arch: ## Architecture conformance via luxarch (pinned; reads .luxarch.toml)
	@if [ -z "$(LUXARCH_REGISTRY)" ]; then \
	  echo "luxarch: LUXARCH_REGISTRY unset (see Makefile.local.example) — skipping"; \
	else docker run --rm -v $(PWD):/repo $(LUXARCH_IMAGE); fi

# Committed guard-status files, so the fleet can answer "who's red on what" by READING each
# repo instead of re-running every guard everywhere. The design is a LOCKFILE, not a cache:
# guard-generated (never hand-edited), stamped with the commit it was computed at, and
# freshness-verified on read — `fleet-status.py` marks a row STALE when HEAD has moved past
# the recorded SHA, so a committed green that no longer reflects the code cannot masquerade
# as current. The guards stay READ-ONLY on /repo (load-bearing: a guard must never mutate the
# code it judges), so `--json` is a pure stdout primitive and THIS recipe does the stamping.
# `|| true` because --json exits non-zero on a red repo — the verdict is IN the JSON, and a
# red repo still has a valid, committable status. `set -e` so a failed/empty stamp ABORTS
# rather than printing a false "wrote". See luxarch --doc FLEET-STATUS.
GUARD_RUN = docker run --rm -v $(PWD):/repo
# STAMP refuses a document that is not the expected guard's own (`"guard"` in every --json), so a
# crossed or empty file can never be committed as this repo's record.
STAMP = python3 -c 'import json,sys,os; d=json.load(open(sys.argv[1])); g=d.get("guard"); g==sys.argv[3] or sys.exit(f"status: {sys.argv[1]} holds {g!r} output, expected {sys.argv[3]!r}; refusing to stamp"); d["commit"]=os.environ["SHA"]; d["generated_at"]=os.environ["TS"]; json.dump(d,open(sys.argv[2],"w"),indent=2)'

# `mktemp`: a per-run file, never a fixed /tmp path every repo and user on the host shares.
# `-e LUXARCH_STATUS_WRITE=1` on the luxarch run ONLY: it tells repo.guard_status_current that this
# run is replacing the files, so the snapshot does not record a verdict on its own predecessors.
status: ## Regenerate the committed guard-status files (.lux*-status.json) — commit them
	@if [ -z "$(LUXARCH_REGISTRY)" ] || [ -z "$(LUXLINT_REGISTRY)" ] || [ -z "$(LUXAUDIT_REGISTRY)" ]; then \
	  echo "guard registry unset (see Makefile.local.example) — cannot generate status"; exit 1; \
	fi
	@set -e; export SHA=$$(git rev-parse HEAD) TS=$$(date -u +%FT%TZ); \
	J=$$(mktemp); trap 'rm -f "$$J"' EXIT INT TERM; \
	$(GUARD_RUN) $(LUXLINT_IMAGE)  --json > "$$J" || true; $(STAMP) "$$J" .luxlint-status.json luxlint; \
	$(GUARD_RUN) -e LUXARCH_STATUS_WRITE=1 $(LUXARCH_IMAGE) --json > "$$J" || true; $(STAMP) "$$J" .luxarch-status.json luxarch; \
	$(GUARD_RUN) $(LUXAUDIT_IMAGE) --json > "$$J" || true; $(STAMP) "$$J" .luxaudit-status.json luxaudit; \
	echo "wrote .lux*-status.json at $$SHA — commit them"

plan: ## The full red board — every arch red at once, phase-ordered + file-clustered
	@if [ -z "$(LUXARCH_REGISTRY)" ]; then \
	  echo "luxarch: LUXARCH_REGISTRY unset (see Makefile.local.example) — skipping"; \
	else docker run --rm -v $(PWD):/repo $(LUXARCH_IMAGE) --plan; fi

audit: ## Scan pinned deps against the live vulnerability feed (luxaudit)
	@if [ -z "$(LUXAUDIT_REGISTRY)" ]; then \
	  echo "luxaudit: LUXAUDIT_REGISTRY unset (see Makefile.local.example) — skipping"; \
	else docker run --rm -v $(PWD):/repo $(LUXAUDIT_IMAGE); fi

# The e2e stack runs the runtime stage built from CURRENT source, under the BARE verification
# name `$(E2E_IMAGE)` — never pushed, so a clean clone runs the hardware-free test with no
# registry and no pull. Compose never builds; it runs that tag (repo.compose_conventions).
test-e2e: harness-build ## Hardware-free end-to-end test: fake Kasa devices -> collector -> InfluxDB
	docker build $(NO_CACHE_FLAG) --target base -f Dockerfile $(BUILD_ARGS) -t $(E2E_IMAGE) .
	./scripts/e2e-test.sh

# THE fleet gate — byte-identical composition across every app repo. Five different `check`
# targets is five different answers to "is this repo green," and the drift hides holes: a gate
# that quietly drops mypy, or arch, or the secret scan reads exactly as green as one that runs
# them. Order: pin drift -> ruff -> types -> tests -> architecture -> dependency CVEs -> secrets.
# `check` is a GATE, not a report: Make stops at the FIRST failing step. For the full red board
# (every red at once, phase-ordered + file-clustered) run `make plan`.
# See luxarch --doc FLEET-MAKEFILE-STANDARD.
check: guard-version-check honest lint mypy test arch audit gitleaks ## THE fleet gate — run before every commit

# A green check must MEAN nothing was silently unchecked. `--assert-scans` fails only when a
# rule family inspected ZERO files (a dir it points at is empty/absent) — never on reds — and
# `--preflight` fails when the mypy run isn't honest. Both probes already lived in
# onboard-check, but that target isn't the daily gate: luxarch 0.114.0 closed exactly that
# loophole after a repo certified 8/9 green for two days with two blind rule families,
# because nothing turned the scanned-nothing footer into an exit code. Placed early in
# `check` so a later red step can't skip it.
honest: ## a green check must mean nothing was silently unchecked
	@if [ -z "$(LUXARCH_REGISTRY)" ] || [ -z "$(LUXLINT_REGISTRY)" ]; then \
	  echo "guard registry unset (see Makefile.local.example) — cannot verify honesty"; exit 1; \
	fi
	@docker run --rm -v $(PWD):/repo $(LUXARCH_IMAGE) --assert-scans
	@docker run --rm -v $(PWD):/repo $(LUXLINT_IMAGE) --preflight

# The machine gate for "is this repo ONBOARDED" — wiring + honesty, deliberately distinct
# from findings red/green. Passing means the SIGNALS ARE TRUSTWORTHY, so the reds it leaves
# are real and can be burned down with confidence; it says nothing about how many there are.
# `--assert-scans` is the hollow-green net: a rule family that inspected ZERO files (a dir it
# points at is empty/absent) is a false green, which the standard calls worse than a red.
# The full-history gitleaks leg matters because the pre-commit hook only sees STAGED diffs —
# a leak untouched since an old commit passes every commit yet stays in history.
# See luxarch --doc FLEET-ONBOARDING-STANDARD §5.
onboard-check: ## Prove the repo is onboarded: all three guards on + honest + privacy wired
	@set +e; fail=0; \
	if [ -z "$(LUXARCH_REGISTRY)" ] || [ -z "$(LUXLINT_REGISTRY)" ] || [ -z "$(LUXAUDIT_REGISTRY)" ]; then \
	  echo "guard registry unset (see Makefile.local.example) — cannot verify onboarding"; exit 1; \
	fi; \
	docker run --rm -v $(PWD):/repo $(LUXARCH_IMAGE)  --version      >/dev/null || { echo "luxarch not wired";  fail=1; }; \
	docker run --rm -v $(PWD):/repo $(LUXLINT_IMAGE)  --version      >/dev/null || { echo "luxlint not wired";  fail=1; }; \
	docker run --rm -v $(PWD):/repo $(LUXAUDIT_IMAGE) --version      >/dev/null || { echo "luxaudit not wired"; fail=1; }; \
	docker run --rm -v $(PWD):/repo $(LUXARCH_IMAGE)  --assert-scans >/dev/null 2>&1 || { echo "luxarch: a rule family scanned NOTHING (hollow green) — point it at real code or remove the surface"; fail=1; }; \
	docker run --rm -v $(PWD):/repo $(LUXLINT_IMAGE)  --preflight    >/dev/null || { echo "mypy run NOT honest (luxlint --preflight)"; fail=1; }; \
	docker run --rm -v $(PWD):/repo $(LUXAUDIT_IMAGE) 2>&1 | grep -q "scan could not run" && { echo "luxaudit can't scan — supply-chain blind"; fail=1; }; \
	[ -f hooks/pre-commit ] || { echo "secret git-hooks NOT wired (luxlint --emit-hooks | sh, commit hooks/)"; fail=1; }; \
	[ ! -d .github/workflows ] || { echo "public CI present — make check is the sole gate (remove .github/workflows)"; fail=1; }; \
	! grep -qE 'ruff[[:space:]]+format' Makefile 2>/dev/null || { echo "Makefile shells the formatter directly (wrong width) — use 'luxlint --format'"; fail=1; }; \
	$(MAKE) -s gitleaks >/dev/null 2>&1 || { echo "gitleaks found secrets in FULL history — the pre-commit hook only sees staged diffs; scrub before onboarding is complete"; fail=1; }; \
	[ $$fail -eq 0 ] && echo "onboard-check: all three guards on + honest + privacy wired + history clean ✓" || { echo "onboard-check FAILED"; exit 1; }

hooks: ## Install the committed git hooks (pre-commit + pre-push run the gitleaks scan)
	git config core.hooksPath hooks
	@printf "✓ core.hooksPath -> hooks (pre-commit + pre-push secret scan active)\n"

# luxarch:gitleaks asset v9 - DO NOT edit this marker line; it is how repo.emitted_assets_current knows your copy is current. Re-emit with `luxarch --emit gitleaks`.
# ── The privacy gate: BOTH surfaces ─────────────────────────────────────────────────────────────
# Emitted by `luxarch --emit gitleaks`. Drop in verbatim.
#
# `gitleaks` scans DIFF CONTENT. A commit's author/committer address lives in the commit object
# HEADER and never appears in a patch, so no content rule can ever match it — it is a surface the
# scanner does not read. A repo reported `no leaks found` over 963 commits while 29 of them carried a
# personal address in both the author and committer fields, and it would have reported exactly the
# same thing after the scrub: identical output, opposite truth. Measured across the fleet, EIGHT
# repos carry a personal address in history and two of them are PUBLIC (LUXTASTE-339).
#
# FLEET-ONBOARDING-STANDARD §2 uses one of those very addresses as its worked example of a leak the
# full-history scan exists to catch. The standard named the leak and the gate could not see it.

# Commit identities this repo accepts. The fleet account's `users.noreply.github.com` address, plus
# GitHub's own web-UI committer. Widen ONLY for a real outside contributor, with a comment saying who.
# NOT for the org account's real address: a role mailbox in commit metadata is published with every
# clone exactly like a personal one (six fleet repos carried it, one PUBLIC; OPENCLAIM-359). Its
# omission here is the policy, not an oversight: the answer is the scrub printed below, and the
# repo's agent performs it once the OWNER approves the force-push.
# Anchored on the CLOSING BRACKET, because the compared line is `Name <email>` — not a bare
# address. The first cut allowed `^noreply@github.com$$`, which can NEVER match a
# `Name <email>` line, so the GitHub web-UI identity was silently DENIED and the canonical
# recipe would have refused on any repo carrying a web-UI commit. Measured across the fleet: it
# denied 4 of 6 distinct identity lines instead of the 3 real offenders (LUXTRMNL-21).
# It was missed because the only repo it was tested on has no web-UI commits, so the broken
# branch never ran. The bracket also closes a substring hole: unanchored,
# `<x@users.noreply.github.com.attacker.test>` would have been allowed.
GIT_IDENTITY_OK ?= <[^>]*users\.noreply\.github\.com>$$|<noreply@github\.com>$$

# The secret scanner, PINNED and MIRRORED in the fleet registry (LUXASIF-29). The fleet bans a moving tag
# everywhere it can see one, and this used to ship `ghcr.io/gitleaks/gitleaks:latest` inside the asset every
# repo adopts verbatim: the privacy gate could not run with ghcr unreachable or the local copy pruned, and
# nothing recorded which scanner said "no leaks found". New detection rules still arrive, through the fleet's
# own mechanism: luxarch bumps this pin in a release, and `repo.emitted_assets_current` tells you to re-emit.
# v5: the HOST is never written here (LUXSTATS-115). v4 inlined the private registry, so dropping
# this asset in "verbatim" put the host into a committed Makefile, and on a public repo the fleet's
# own gitleaks disclosure tier refused the commit. The mirror lives beside the guards, so the ref is
# derived from wherever this repo already pulls luxlint (`$(LUXLINT)`, which the scan below needs
# anyway). It works whichever variable holds your guard registry (REGISTRY, LUXARCH_REGISTRY, …).
# Recursive `=` so it resolves at use, whatever order LUXLINT is defined in.
# v9: PINNED BY DIGEST, and buildable off-network. The digest is the scanner's identity; the registry is
# only where it is fetched from. Beside a registry-qualified `$(LUXLINT)` it pulls the fleet mirror; with
# a local guard build (`luxlint:local`, on a machine with no access to the fleet registry, such as the
# GTM laptop) it pulls the public image. v8 derived `./gitleaks:…` there, an unpullable reference, so the
# privacy gate could not run at all. The mirror and the public image share the digest, so both
# resolve to the same bits, and a tampered or re-tagged copy fails the pull instead of scanning.
GITLEAKS_IMAGE = $(if $(findstring /,$(LUXLINT)),$(dir $(LUXLINT)),zricethezav/)gitleaks:v8.30.1@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f

gitleaks: ## secret scan over FULL HISTORY + the commit-identity pass (the hooks cover commit/push)
	@set -e; C=$$(mktemp); trap 'rm -f "$$C"' EXIT INT TERM; \
	docker run --rm -v $(PWD):/repo $(LUXLINT) --emit-config gitleaks > "$$C"; \
	docker run --rm -v $(PWD):/repo -v "$$C":/gl.toml:ro -w /repo \
	  $(GITLEAKS_IMAGE) git /repo -c /gl.toml --redact -v
	@# The identity pass — the half gitleaks structurally cannot do. Cheap: one `git log`.
	@# Walks what THIS repo publishes (branches, tags, HEAD), NOT `--all`: a remote-tracking ref caches the
	@# remote's state, which during a scrub is by definition the un-rewritten history you are about to
	@# force-push over — `--all` refused the verified fix, and any `git fetch` re-armed it (BOUTIQUE-577).
	@bad=$$(git log --branches --tags HEAD --pretty='%an <%ae>%n%cn <%ce>' 2>/dev/null | sort -u \
	  | grep -vE '$(GIT_IDENTITY_OK)' || true); \
	if [ -n "$$bad" ]; then \
	  echo "REFUSING: a non-fleet identity appears in commit METADATA (author/committer):"; \
	  echo "$$bad" | sed 's/^/    /'; \
	  echo "gitleaks cannot see this — it scans diffs, not commit headers, so it reported no leaks."; \
	  echo "An address here is attached to every affected commit forever, not to one line of one file."; \
	  echo "Scrub per FLEET-ONBOARDING-STANDARD §2: mirror backup -> git filter-repo -> re-verify with"; \
	  echo "  git log --branches --tags HEAD --pretty='%an <%ae>%n%cn <%ce>' | sort -u"; \
	  echo "-> ask the OWNER to approve the force-push, then do it yourself. Never force-push unapproved."; \
	  exit 1; \
	fi

# v6: the STAGED scan the commit hook calls (`hooks/pre-commit` → `make gitleaks-staged`) is part of the
# asset now. v5 shipped only the full-history half, so 9 of 10 adopting repos hand-wrote this target
# and the tenth had none, leaving its pre-commit hook pointing at a missing recipe. If your Makefile
# carries its own `gitleaks-staged`, delete it when you re-emit: this one replaces it.
# v7: `-w /repo` is LOAD-BEARING. Without it git runs outside the repo, falls back to `git diff
# --no-index`, rejects `--staged`, and gitleaks EXITS 0: v6 let a staged secret through while printing
# a git error (measured on a planted GitHub token: v6 exit 0, v7 "leaks found: 1" exit 1).
# v8: the denylist goes to a PER-RUN `mktemp` file, removed on exit (LUXHELIX-128). v7 wrote a fixed
# `/tmp/gl.toml` that outlived the run: on a host where commit and push run as different users, the
# next user's redirect was refused (`fs.protected_regular=1`, the Fedora default, blocks O_CREAT on
# another user's file in sticky /tmp even for root), so the privacy gate failed every commit or push
# after a user switch (2 of 2 measured). Two repos scanning at once also shared one file, so one could
# scan with the other's carve-outs. The full-history scan now also passes `-w /repo`, like the staged one.
gitleaks-staged: ## secret scan of the STAGED changes (run by hooks/pre-commit)
	@set -e; C=$$(mktemp); trap 'rm -f "$$C"' EXIT INT TERM; \
	docker run --rm -v $(PWD):/repo $(LUXLINT) --emit-config gitleaks > "$$C"; \
	docker run --rm -v $(PWD):/repo -v "$$C":/gl.toml:ro -w /repo \
	  $(GITLEAKS_IMAGE) protect --staged /repo -c /gl.toml --redact -v

##@ Utilities

clean: ## Clean python/test caches
	find . -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
	find . -type f -name "*.pyc" -delete 2>/dev/null || true
	rm -rf .pytest_cache/ .mypy_cache/ .ruff_cache/ .coverage htmlcov/

clean-all: clean docker-clean ## Clean caches + local docker image tags
