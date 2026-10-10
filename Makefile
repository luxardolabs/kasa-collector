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
LUXARCH_VERSION  := 0.277.0
LUXARCH_IMAGE    ?= $(LUXARCH_REGISTRY)/luxardolabs/luxarch:$(LUXARCH_VERSION)

# Code-style + type guard (luxlint) — pinned; pulled via LUXLINT_REGISTRY (Makefile.local),
# same out-of-tree pattern as luxarch. Unset host → make lint/format skip gracefully.
LUXLINT_REGISTRY ?=
LUXLINT_VERSION  := 0.63.1
LUXLINT_IMAGE    ?= $(LUXLINT_REGISTRY)/luxardolabs/luxlint:$(LUXLINT_VERSION)
# The luxlint ref the emitted gitleaks block reads. Without the fleet registry it falls back
# to a local guard build (`luxlint:local`), and the block then pulls the public gitleaks image.
LUXLINT = $(if $(LUXLINT_REGISTRY),$(LUXLINT_IMAGE),luxlint:local)

# Dependency-vulnerability guard (luxaudit) — pinned; pulled via LUXAUDIT_REGISTRY (Makefile.local).
# Scans poetry.lock against the live OSV+PyPA feed. Unset host → `make audit` skips gracefully.
LUXAUDIT_REGISTRY ?=
LUXAUDIT_VERSION  := 0.13.2
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

# LOCAL test image — the Dockerfile's `test` stage, rebuilt from source by `make test-build`
# on every `make test` (luxarch's test block). BARE: never pushed, never a deploy tag.
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
        guard-clean-tree dev-deploy dev-pin harness-build release release-public gh-release buildx-setup \
        docker-inspect docker-clean \
        up down restart logs ps shell \
        dev-up dev-down dev-clean dev-logs dev-ps dev-shell \
        prod-up prod-down prod-restart prod-logs prod-ps \
        demo-up demo-down demo-clean demo-logs demo-ps \
        check-prod-node prod-init prod-sync prod-deploy prod-status prod-logs-remote prod-health prod-rollback \
        poetry-lock poetry-update poetry-install \
        guard-version-check guard-upgrade honest lint mypy format test-build test arch plan status audit test-e2e check onboard-check \
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
# luxarch:buildx-setup asset v2 - DO NOT edit this marker line; it is how repo.emitted_assets_current knows your copy is current. Re-emit with `luxarch --emit buildx-setup`.
BUILDX_BUILDER ?= luxardo-builder
buildx-setup:
	@mkdir -p $(HOME)/.docker
	@[ -f $(HOME)/.docker/buildkitd.toml ] || printf '[worker.oci]\n  gc = true\n  [[worker.oci.gcpolicy]]\n    keepBytes = "20GB"\n    all = true\n' > $(HOME)/.docker/buildkitd.toml
	@docker buildx inspect $(BUILDX_BUILDER) >/dev/null 2>&1 || \
	  docker buildx create --name $(BUILDX_BUILDER) --driver docker-container \
	    --buildkitd-config $(HOME)/.docker/buildkitd.toml --use
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
	docker run --rm -v $(CURDIR):/repo -v luxaudit-cache:/root/.cache/trivy -v "$$T":/candidate.tar:ro \
	  $(LUXAUDIT_IMAGE) --image-archive /candidate.tar --image-label $(2)
endef

dev-deploy: guard-clean-tree ## Build, SCAN, push THIS commit as :sha-<commit>, pin .env.dev to it, restart the dev stack
	docker build --load $(NO_CACHE_FLAG) --target base -f Dockerfile $(BUILD_ARGS) -t $(SHA_IMAGE) .
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
	@case "$(TAG)" in candidate-*) echo "REFUSING: $(TAG) is a release candidate, not a published build (it may have failed its scan)"; exit 1;; esac
	@docker manifest inspect $(IMAGE):$(TAG) >/dev/null 2>&1 || \
	  { echo "$(IMAGE):$(TAG) is not in the registry — publish it before pinning a stack to it"; exit 1; }
	@$(call pin_env_tag,.env.dev,$(TAG))
	$(DEV_DC) up -d

# The emulator is a TEST FIXTURE, never a released artifact: built locally under a BARE name and
# never pushed, so the demo and e2e stacks resolve it from the local store with no registry.
harness-build: ## Build the fake-device emulator image (compose never builds — it runs a tag)
	docker build --load $(NO_CACHE_FLAG) -t $(FAKE_IMAGE) ./harness
	@echo "built $(FAKE_IMAGE)"

# The cut release. Multi-arch (amd64 + arm64), so a local single-arch build is NOT the candidate:
# scanning one image and pushing another proves nothing about what ships (repo.release_scans_candidate).
# The candidate is pushed ONCE under a tag nothing pins, pulled back, saved and scanned; only then are
# the release tags created FROM it with `imagetools create`, so they name exactly the scanned bits.
# A released version is never re-pushed, not even from its own commit (prod pins it): bump VERSION.
CANDIDATE_IMAGE := $(IMAGE):candidate-$(COMMIT)
comma := ,
# One pull + scan per platform: a plain `docker pull` of the manifest list fetches the host's
# architecture only, so the other half of the release would ship unscanned.
define scan_platform
	docker pull --platform $(1) $(CANDIDATE_IMAGE)
	$(call scan_candidate,$(CANDIDATE_IMAGE),$(VERSION_IMAGE)@$(1))

endef

release: guard-clean-tree buildx-setup ## Build + scan + push :$(VERSION) + :sha-<commit> (multi-arch, alias :latest) to the private registry
	@if docker manifest inspect $(VERSION_IMAGE) >/dev/null 2>&1; then \
	  echo "REFUSING: $(VERSION_IMAGE) is already RELEASED. A released version is immutable: prod pins it. Bump VERSION."; \
	  exit 1; \
	fi
	@# Fails CLOSED: `manifest inspect` exits 1 for "no such manifest" AND for an unreachable
	@# registry, so only the registry's own not-found answer reads as unreleased.
	@out=$$(docker manifest inspect $(VERSION_IMAGE) 2>&1) || case "$$out" in \
	  *[Nn]"o such manifest"*|*"manifest unknown"*) ;; \
	  *) echo "REFUSING: cannot verify $(VERSION_IMAGE) is unreleased: $$out"; exit 1 ;; \
	esac
	@t=$$(git rev-parse -q --verify "refs/tags/v$(VERSION)^{commit}" 2>/dev/null); \
	if [ -n "$$t" ] && [ "$$t" != "$$(git rev-parse HEAD)" ]; then \
	  echo "REFUSING: v$(VERSION) is already tagged at $$t, not HEAD: bump VERSION."; exit 1; \
	fi
	docker buildx build $(NO_CACHE_FLAG) --target base --platform $(PLATFORMS) -f Dockerfile $(BUILD_ARGS) \
		-t $(CANDIDATE_IMAGE) --push .
	$(foreach p,$(subst $(comma), ,$(PLATFORMS)),$(call scan_platform,$(p)))
	docker buildx imagetools create -t $(VERSION_IMAGE) -t $(LATEST_ALIAS) $(CANDIDATE_IMAGE)
	@# :sha-<commit> is immutable too: `make dev-deploy` may already have published it for this
	@# commit (and .env.dev pins it), so it is created only when the registry does not hold it.
	@if docker manifest inspect $(SHA_IMAGE) >/dev/null 2>&1; then \
	  echo "$(SHA_IMAGE) already published; left as is"; \
	else docker buildx imagetools create -t $(SHA_IMAGE) $(CANDIDATE_IMAGE); fi
	@echo "Pushed $(VERSION_IMAGE) + $(LATEST_ALIAS) (+ $(SHA_IMAGE) if new), from the scanned $(CANDIDATE_IMAGE)"

# The public promotion copies the released manifest list by digest, so it ships the bits `release`
# scanned. It refuses a version GHCR already holds: a re-run would overwrite what users pulled.
release-public: guard-clean-tree ## Promote the released :$(VERSION) + :latest (multi-arch) to GHCR — run `make release` first
	@if docker manifest inspect $(PUBLIC_IMAGE):$(VERSION) >/dev/null 2>&1; then \
	  echo "REFUSING: $(PUBLIC_IMAGE):$(VERSION) is already published. A released version is immutable."; \
	  exit 1; \
	fi
	@out=$$(docker manifest inspect $(PUBLIC_IMAGE):$(VERSION) 2>&1) || case "$$out" in \
	  *[Nn]"o such manifest"*|*"manifest unknown"*) ;; \
	  *) echo "REFUSING: cannot verify $(PUBLIC_IMAGE):$(VERSION) is unpublished: $$out"; exit 1 ;; \
	esac
	@docker buildx imagetools inspect $(VERSION_IMAGE) >/dev/null 2>&1 \
		|| { echo "$(VERSION_IMAGE) not found — run 'make release' before 'make release-public'"; exit 1; }
	@# Everything gh-release needs, checked BEFORE the public push: once GHCR holds the version a
	@# re-run refuses, so a missing note or tag found afterwards could not be recovered by re-running.
	@test -f app/release_notes/$(VERSION).md \
	  || { echo "REFUSING: app/release_notes/$(VERSION).md missing — write it before publishing"; exit 1; }
	@git rev-parse -q --verify "refs/tags/v$(VERSION)" >/dev/null \
	  || { echo "REFUSING: tag v$(VERSION) does not exist — tag before publishing"; exit 1; }
	@command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1 \
	  || { echo "REFUSING: gh is not installed or not authenticated (gh auth login)"; exit 1; }
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

# luxarch:guard-upgrade asset v1 - DO NOT edit this marker line; it is how repo.emitted_assets_current knows your copy is current. Re-emit with `luxarch --emit guard-upgrade`.
guard-upgrade:  ## Bump every guard pin to the published latest (prints what newly bites)
	@for g in luxarch luxlint luxaudit; do \
	  docker pull -q $(REGISTRY)/luxardolabs/$$g:latest >/dev/null 2>&1 || true; \
	  latest=$$(docker run --rm $(REGISTRY)/luxardolabs/$$g:latest --version 2>/dev/null | awk '{print $$2}'); \
	  var=$$(echo $$g | tr a-z A-Z)_VERSION; \
	  old=$$(sed -n -E "s/^$$var[[:space:]]*:=[[:space:]]*//p" Makefile); \
	  if [ -z "$$old" ]; then echo "!! no $$var pin found in Makefile — NOT bumped"; continue; fi; \
	  if [ -z "$$latest" ]; then echo "!! could not read $$g:latest — $$var left at $$old"; continue; fi; \
	  checked=1; \
	  sed -i -E "s|^($$var[[:space:]]*:=[[:space:]]*).*|\\1$$latest|" Makefile; \
	  new=$$(sed -n -E "s/^$$var[[:space:]]*:=[[:space:]]*//p" Makefile); \
	  if [ "$$new" != "$$latest" ]; then echo "!! $$var did NOT change (still $$new)"; exit 1; fi; \
	  if [ "$$old" != "$$latest" ]; then echo "$$var $$old -> $$latest"; bumped=1; fi; \
	  [ "$$g" = luxarch ] && [ "$$old" != "$$latest" ] && docker run --rm -v $(PWD):/repo $(REGISTRY)/luxardolabs/luxarch:$$latest --new-rules --since $$old || true; \
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

# The test image: the Dockerfile's `test` stage (production's `base` + the dev group), built from
# THIS source every run, under a BARE name so it can never be pushed or mistaken for a deployable.
test-build: ## Build the LOCAL test image from source (never pushed, never a deploy tag)
	@docker build --load --target test --build-arg POETRY_VERSION=$(POETRY_VERSION) \
	  -f Dockerfile -t $(TEST_IMAGE) . >/dev/null

# Test-block settings: the suite writes to a REAL InfluxDB (compose profile `test`), the one
# backing service the deployed stack runs (repo.test_stack_parity). conftest.py only fills
# Config defaults, so these reach the code under test.
TEST_SERVICES := kasa_test_influxdb
TEST_ENV := -e KASA_COLLECTOR_INFLUXDB_URL=http://kasa_test_influxdb:8086 \
            -e KASA_COLLECTOR_INFLUXDB_TOKEN=kasa-test-token \
            -e KASA_COLLECTOR_INFLUXDB_ORG=kasa -e KASA_COLLECTOR_INFLUXDB_BUCKET=kasa

# luxarch:test-block asset v1 - DO NOT edit this marker line; it is how repo.emitted_assets_current knows your copy is current. Re-emit with `luxarch --emit test-block`.
# ── Test: THE suite, in the test image, against an isolated stack of real services ───────────────
# Emitted by `luxarch --emit test-block`; paste below the image block (it uses TEST_IMAGE and
# test-build from there). Enforced by `repo.test_block_wired`. Settings are `?=` defaults: set them
# above this block. What the suite can see, and what only `make smoke` sees: --doc
# FLEET-MAKEFILE-STANDARD §1.
#
# Before this block every repo wrote its own `make test`: four repos, four ways (a lint image with
# the source mounted, the dev image with pytest pip-installed at run time, a repo script, a test
# image), each with its own readiness loop and coverage wiring, and a coverage pipe under make's
# /bin/sh that hid pytest's failure. This is the documented practice of the tools instead:
#   - ISOLATED STACK (Docker Compose): the backing services run in a compose project of their own,
#     one per run (`-p`), so parallel runs never collide, the suite cannot reach the dev database or
#     cache at all (it is on another network), and teardown (`down --volumes --remove-orphans`)
#     removes exactly this run's containers and data, pass or fail, never the dev stack.
#   - READINESS from each service's own compose healthcheck (`up --wait`), not a sleep or a loop:
#     the service declares when it is ready. For Postgres, probe over TCP with the real role
#     (`pg_isready -h 127.0.0.1 -U <user> -d <db>`); over the socket it answers while initdb's
#     temporary server is still up. `repo.test_stack_parity` checks these are the services prod runs.
#   - Ctrl-C stops the suite (`--init` forwards the signal; a shell as PID 1 ignores it).
#   - THE TEST IMAGE built from this source (`test-build`, the image's `--with dev` stage), with the
#     fleet's pytest config (`luxlint --emit-config pytest`: -ra, strict markers and config,
#     warnings are errors), readable by the image's non-root user. The source is mounted read-only
#     and pytest writes no cache into it.
#   - COVERAGE with coverage.py itself, not pytest-cov: `coverage run --branch` under the sysmon
#     core (fast branch coverage on Python 3.14), data in /tmp, then `coverage report` judged by
#     `luxlint --coverage-ratchet` against `[test].coverage_min` (off until you set a floor; it
#     only ratchets up). `coverage` belongs in the dev dependency group.
#   - BOTH EXIT CODES reach make: pytest's and the ratchet's. No pipe carries either. The ratchet
#     reads coverage's own report file, never the suite's output (a printed `TOTAL … 100%` or
#     pytest's `[100%]` would otherwise pass for a measurement), and a report that measured nothing
#     fails.
#   - Each run's project is named from its own `mktemp -d` token, and refuses to run without one (a
#     PID repeats across containers and CI runners), and everything mounts the makefile's directory ($(CURDIR)), so `make -C` runs the
#     right suite.

# Setting: the compose command, and the profile holding the test services --------------------
TEST_COMPOSE ?= docker compose
TEST_PROFILE ?= test
# Setting: the env file compose interpolates the file with (it reads EVERY service, so an app
# service's `${TAG:?}` needs a value even when only the test services start) -----------------
TEST_ENV_FILE ?= $(firstword $(wildcard .env.test .env.dev .env.example))
# Setting: the backing services the suite needs (each with a healthcheck); empty: none -----------
TEST_SERVICES ?= db-test
# Setting: the suite's environment: the test services' URLs, by service name on the test network -
TEST_ENV ?= -e TEST_DATABASE_URL=postgresql+asyncpg://postgres:postgres@db-test:5432/postgres
# Setting: where the suite runs from (a monorepo's apps/backend), and every package coverage
# measures, comma-separated (`app,collector`): it replaces any [tool.coverage.run] source ---------
TEST_WORKDIR ?= .
TEST_COV ?= app
# Setting: NONE. For a one-off run only, on the command line: `make test PYTEST_ARGS='-k orders'`.
# A committed value narrows THE suite for everyone (`repo.test_block_wired` reds one) ---------
PYTEST_ARGS ?=

# One-off pytest arguments reach the container through the environment, never spliced into a quoted
# command line (`-k 'a or b'` would otherwise split it).
export PYTEST_ARGS

test: test-build ## THE suite: test image, an isolated stack of real services, coverage ratchet
	@set -u; \
	D=$$(mktemp -d); tok=$$(basename "$$D" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9'); \
	[ $${#tok} -ge 8 ] || { echo "REFUSING: could not make a unique name for this run"; rm -rf "$$D"; exit 2; }; \
	run="t$$(printf '%s' '$(notdir $(CURDIR))' | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '-')-test-$$tok"; \
	dc="$(TEST_COMPOSE) -p $$run $(if $(TEST_ENV_FILE),--env-file $(TEST_ENV_FILE)) --profile $(TEST_PROFILE)"; \
	chmod 777 "$$D"; \
	trap '$$dc down --volumes --remove-orphans >/dev/null 2>&1; rm -rf "$$D"' EXIT INT TERM; \
	net=; if [ -n "$(TEST_SERVICES)" ]; then \
	  $$dc up -d --wait --wait-timeout 120 $(TEST_SERVICES) \
	    || { echo "FAIL  the test services did not become healthy: $(TEST_SERVICES)"; exit 1; }; \
	  cid=$$($$dc ps -q $(firstword $(TEST_SERVICES))); net=; \
	  for n in $$(docker inspect -f '{{range $$k, $$v := .NetworkSettings.Networks}}{{$$k}} {{end}}' $$cid); do \
	    [ "$$(docker network inspect -f '{{index .Labels "com.docker.compose.project"}}' $$n)" = "$$run" ] && { net=$$n; break; }; done; \
	  [ -n "$$net" ] || { echo "FAIL  $(firstword $(TEST_SERVICES)) joined no network of this run's own project ($$run)"; exit 1; }; \
	  net="--network $$net"; fi; \
	docker run --rm -v $(CURDIR):/repo $(LUXLINT) --emit-config pytest > "$$D/pytest.ini" || exit 2; \
	chmod 644 "$$D/pytest.ini"; \
	docker run --rm --init $$net $(TEST_ENV) -e PYTEST_ADDOPTS="$${PYTEST_ARGS:-}" \
	  -e COVERAGE_CORE=sysmon -e COVERAGE_FILE=/out/.coverage -e PYTHONDONTWRITEBYTECODE=1 \
	  -v $(CURDIR):/repo:ro -v "$$D":/out -w /repo/$(TEST_WORKDIR) $(TEST_IMAGE) \
	  sh -c 'python -m coverage run --branch --source=$(TEST_COV) -m pytest -c /out/pytest.ini --rootdir=. -p no:cacheprovider; s=$$?; python -m coverage report --show-missing > /out/coverage.txt; echo $$? > /out/coverage.rc; cat /out/coverage.txt; exit $$s'; \
	rc=$$?; \
	[ "$$rc" = 0 ] || { echo "FAIL  the suite failed (exit $$rc)"; exit 1; }; \
	[ "$$(cat "$$D/coverage.rc" 2>/dev/null)" = 0 ] || { echo "FAIL  coverage measured nothing (coverage report: $$(tail -n 1 "$$D/coverage.txt" 2>/dev/null)): check TEST_COV names the package the suite imports"; exit 1; }; \
	docker run --rm -i -v $(CURDIR):/repo $(LUXLINT) --coverage-ratchet < "$$D/coverage.txt" > "$$D/ratchet.txt"; crc=$$?; \
	sed -n '/coverage ratchet/,$$p' "$$D/ratchet.txt"; \
	[ "$$crc" = 0 ] || { echo "FAIL  the coverage ratchet failed (its verdict is above): add tests, never lower the floor"; exit 1; }

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
	docker build --load $(NO_CACHE_FLAG) --target base -f Dockerfile $(BUILD_ARGS) -t $(E2E_IMAGE) .
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

# luxarch:gitleaks asset v12 - DO NOT edit this marker line; it is how repo.emitted_assets_current knows your copy is current. Re-emit with `luxarch --emit gitleaks`.
# ── The privacy gate: BOTH surfaces ─────────────────────────────────────────────────────────────
# Emitted by `luxarch --emit gitleaks`. Drop in verbatim.
#
# `gitleaks` scans DIFF CONTENT. A commit's author/committer address lives in the commit object
# HEADER and never appears in a patch, so no content rule can ever match it — it is a surface the
# scanner does not read. A repo reported `no leaks found` over 963 commits while 29 of them carried a
# personal address in both the author and committer fields, and it would have reported exactly the
# same thing after the scrub: identical output, opposite truth. Measured across the fleet, EIGHT
# repos carry a personal address in history and two of them are PUBLIC.

# Commit identities this repo accepts. The fleet account's `users.noreply.github.com` address, plus
# GitHub's own web-UI committer. Widen ONLY for a real outside contributor, with a comment saying who.
# NOT for the org account's real address: a role mailbox in commit metadata is published with every
# clone exactly like a personal one (six fleet repos carried it, one PUBLIC). Its
# omission here is the policy, not an oversight: the answer is the scrub printed below, and the
# repo's agent performs it once the OWNER approves the force-push.
# Anchored on the CLOSING BRACKET, because the compared line is `Name <email>` — not a bare
# address. The first cut allowed `^noreply@github.com$$`, which can NEVER match a
# `Name <email>` line, so the GitHub web-UI identity was silently DENIED and the canonical
# recipe would have refused on any repo carrying a web-UI commit. Measured across the fleet: it
# denied 4 of 6 distinct identity lines instead of the 3 real offenders.
# It was missed because the only repo it was tested on has no web-UI commits, so the broken
# branch never ran. The bracket also closes a substring hole: unanchored,
# `<x@users.noreply.github.com.attacker.test>` would have been allowed.
# v11: the noreply address is `<local@users.noreply.github.com>`, and the local part has no `@`. v10's
# `<[^>]*users…` admitted `<dev.real@gmail.com.users.noreply.github.com>`, a real address in the clear.
# v12: the fleet ACCOUNT, not any noreply address. v11 accepted `<anyone@users.noreply.github.com>`, so a
# stranger's (or a second account's) noreply committer passed. Measured: the fleet's whole history holds
# exactly two noreply identities, the fleet account and GitHub's web-UI committer.
GIT_IDENTITY_OK ?= <214140984\+luxardolabs@users\.noreply\.github\.com>$$|<noreply@github\.com>$$

# The secret scanner, PINNED and MIRRORED in the fleet registry. The fleet bans a moving tag
# everywhere it can see one, and this used to ship `ghcr.io/gitleaks/gitleaks:latest` inside the asset every
# repo adopts verbatim: the privacy gate could not run with ghcr unreachable or the local copy pruned, and
# nothing recorded which scanner said "no leaks found". New detection rules still arrive, through the fleet's
# own mechanism: luxarch bumps this pin in a release, and `repo.emitted_assets_current` tells you to re-emit.
# v5: the HOST is never written here. v4 inlined the private registry, so dropping
# this asset in "verbatim" put the host into a committed Makefile, and on a public repo the fleet's
# own gitleaks disclosure tier refused the commit. The mirror lives beside the guards, so the ref is
# derived from wherever this repo already pulls luxlint (`$(LUXLINT)`, which the scan below needs
# anyway). It works whichever variable holds your guard registry (REGISTRY, LUXARCH_REGISTRY, …).
# Recursive `=` so it resolves at use, whatever order LUXLINT is defined in.
# v9: PINNED BY DIGEST, and buildable off-network. The digest is the scanner's identity; the registry is
# only where it is fetched from. Beside a registry-qualified `$(LUXLINT)` it pulls the fleet mirror; with
# a local guard build (`luxlint:local`, on a machine with no access to the fleet registry, such as an
# airgapped laptop) it pulls the public image. v8 derived `./gitleaks:…` there, an unpullable reference, so the
# privacy gate could not run at all. The mirror and the public image share the digest, so both
# resolve to the same bits, and a tampered or re-tagged copy fails the pull instead of scanning.
GITLEAKS_IMAGE = $(if $(findstring /,$(LUXLINT)),$(dir $(LUXLINT)),zricethezav/)gitleaks:v8.30.1@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f

gitleaks: ## secret scan over FULL HISTORY + the commit-identity pass (the hooks cover commit/push)
	@set -e; C=$$(mktemp); trap 'rm -f "$$C"' EXIT INT TERM; \
	docker run --rm -v $(PWD):/repo $(LUXLINT) --emit-config gitleaks > "$$C"; \
	docker run --rm -v $(PWD):/repo -v "$$C":/gl.toml:ro -w /repo \
	  $(GITLEAKS_IMAGE) git /repo -c /gl.toml --redact -v --ignore-gitleaks-allow
	@# v12: what `gitleaks git` never reads. It scans git's PATCHES, and git prints no patch for a file it
	@# treats as binary: a NUL byte, UTF-16 (a `Localizable.strings`), or a `binary` / `-diff` attribute.
	@# A token in any of them reached the remote with "no leaks found". So every path git ever showed as
	@# binary is re-read as text, NULs stripped, and scanned by path (the config's path allowlists hold).
	@set -e; C=$$(mktemp); D=$$(mktemp -d); trap 'rm -rf "$$C" "$$D"' EXIT INT TERM; \
	docker run --rm -v $(PWD):/repo $(LUXLINT) --emit-config gitleaks > "$$C"; \
	git -c core.quotePath=false log --branches --tags HEAD --format= -p --no-ext-diff --no-textconv \
	  > "$$D/patches"; \
	sed -n 's|^Binary files .* and b/\(.*\) differ$$|\1|p' "$$D/patches" | sort -u > "$$D/binary"; \
	if [ -s "$$D/binary" ]; then \
	  mkdir "$$D/t" "$$D/none"; \
	  while IFS= read -r f; do \
	    mkdir -p "$$D/t/$$(dirname "$$f")"; \
	    git -c core.quotePath=false log --branches --tags HEAD --format= -p --text --no-ext-diff \
	      --no-textconv -- "$$f" > "$$D/p"; \
	    grep -a '^+' "$$D/p" | tr -d '\000' > "$$D/t/$$f"; \
	  done < "$$D/binary"; \
	  docker run --rm -v "$$D/t":/scan:ro -w /scan -v "$$D/none":/none:ro -v "$$C":/gl.toml:ro \
	    $(GITLEAKS_IMAGE) dir . -c /gl.toml --redact -v --ignore-gitleaks-allow \
	    --gitleaks-ignore-path /none; \
	fi
	@# The identity pass — the half gitleaks structurally cannot do. Cheap: one `git log`.
	@# Walks what THIS repo publishes (branches, tags, HEAD), NOT `--all`: a remote-tracking ref caches the
	@# remote's state, which during a scrub is by definition the un-rewritten history you are about to
	@# force-push over — `--all` refused the verified fix, and any `git fetch` re-armed it.
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
# v8: the denylist goes to a PER-RUN `mktemp` file, removed on exit. v7 wrote a fixed
# `/tmp/gl.toml` that outlived the run: on a host where commit and push run as different users, the
# next user's redirect was refused (`fs.protected_regular=1`, the Fedora default, blocks O_CREAT on
# another user's file in sticky /tmp even for root), so the privacy gate failed every commit or push
# after a user switch (2 of 2 measured). Two repos scanning at once also shared one file, so one could
# scan with the other's carve-outs. The full-history scan now also passes `-w /repo`, like the staged one.
# v12: the staged bytes are read on the HOST and scanned as files, by path. v11 ran `protect --staged`
# inside the container, which read `.git/index`, not the temporary index git hands the hook in
# `$$GIT_INDEX_FILE`: `git commit -a` and `git commit <path>` were never scanned. It also read git's
# patches, which skip binary, NUL, UTF-16 and `-diff` files, and it honoured a `# gitleaks:allow` on
# the secret's own line and a committed `.gitleaksignore`, so a commit's author could waive their own
# leak. New content gets no waiver: `.gitleaksignore` stays a ledger for the full-history scan only.
gitleaks-staged: ## secret scan of the STAGED changes (run by hooks/pre-commit)
	@set -e; C=$$(mktemp); D=$$(mktemp -d); trap 'rm -rf "$$C" "$$D"' EXIT INT TERM; \
	docker run --rm -v $(PWD):/repo $(LUXLINT) --emit-config gitleaks > "$$C"; \
	mkdir "$$D/t" "$$D/none"; \
	git -c core.quotePath=false diff --cached --name-only --diff-filter=ACMR -z > "$$D/names"; \
	tr '\000' '\n' < "$$D/names" | while IFS= read -r f; do \
	  [ -n "$$f" ] || continue; \
	  mkdir -p "$$D/t/$$(dirname "$$f")"; \
	  git -c core.quotePath=false diff --cached --text --no-ext-diff --no-textconv -U0 -- "$$f" \
	    > "$$D/p"; \
	  grep -a '^+' "$$D/p" | tr -d '\000' > "$$D/t/$$f"; \
	done; \
	docker run --rm -v "$$D/t":/scan:ro -w /scan -v "$$D/none":/none:ro -v "$$C":/gl.toml:ro \
	  $(GITLEAKS_IMAGE) dir . -c /gl.toml --redact -v --ignore-gitleaks-allow \
	  --gitleaks-ignore-path /none

##@ Utilities

clean: ## Clean python/test caches
	find . -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
	find . -type f -name "*.pyc" -delete 2>/dev/null || true
	rm -rf .pytest_cache/ .mypy_cache/ .ruff_cache/ .coverage htmlcov/

clean-all: clean docker-clean ## Clean caches + local docker image tags
