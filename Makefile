# =============================================================================
# kasa-collector — fleet build/deploy Makefile
# Source of truth for the version is the VERSION file at the repo root.
# Compose never builds; the Makefile builds the image + pushes it to the registry,
# and the dev/prod stacks pull it. Mirrors the bb-boutique fleet standard, trimmed
# for a single-service collector (host networking, no db/redis/nginx/css).
# =============================================================================

VERSION := $(shell cat VERSION 2>/dev/null || git -c safe.directory=$(CURDIR) describe --tags --always 2>/dev/null || echo "0.0.0-dev")
TIMESTAMP := $(shell date -u +%Y-%m-%dT%H:%M:%SZ)

# The private-registry host is kept OUT of this public tree — set it in an untracked
# Makefile.local (see Makefile.local.example). Included FIRST so its values win over the
# empty defaults below. Without it, the local/e2e stacks still build; only the targets
# that pull from the private registry (dev-deploy / release / prod / lint / arch / audit)
# need it. Lint/type/test are decoupled from :dev per FLEET-BUILD-DEPLOY-STANDARD — ruff AND
# mypy are mount-only luxlint (the repo installs nothing), pytest is a lock-keyed image.
-include Makefile.local

# Registry / images. REGISTRY comes from Makefile.local or the CLI; empty by default so no
# internal hostname is committed. Every tag (`:sha-<commit>`, `:$(VERSION)`, the `:dev` alias, the
# bare `:test` suite image) is composed by luxarch's image block below, from these settings.
REGISTRY ?=
IMAGE_NAME := luxardolabs/kasa-collector
# The released image is public too: `make release-public` copies the released, rescanned digest
# to GHCR (the fleet's external registry, not Docker Hub).
PUBLIC_REGISTRY ?= ghcr.io
# The public `:latest` moves with each release (owner's call): users pull it, so `release-public`
# moves it to the released digest too, and only when VERSION is origin's newest release.
PUBLIC_LATEST := 1
# The dev stack runs on the fleet's dev host, an ssh alias every coding machine resolves, so no
# internal host name is committed (FLEET-BUILD-DEPLOY-STANDARD, "The dev host"). `dev-pin` and
# `smoke` reach its docker over ssh, and so do the dev-* targets below. It is on the same LAN as
# the plugs, so the host-networked collector's discovery broadcast reaches them from there.
DEV_HOST := devhost
# LOCAL verification images for the hardware-free stacks — BARE on purpose, so they cannot be
# pushed by accident or mistaken for a deployable, and a clean clone needs no registry. The
# e2e image (the `production` stage) has its own `<repo>-<role>:test` name, so it never shares
# a tag with the image block's TEST_IMAGE (`<repo>:test`, the `test` stage `make test` builds).
E2E_IMAGE  := kasa-collector-e2e:test
FAKE_IMAGE := kasa-collector-fake:test

# Architecture guard (luxarch) — pinned; pulled via LUXARCH_REGISTRY (Makefile.local).
# Bump LUXARCH_VERSION when adopting new rules. Unset host → `make arch` skips gracefully.
LUXARCH_REGISTRY ?=
LUXARCH_VERSION  := 0.375.0
LUXARCH_IMAGE    ?= $(LUXARCH_REGISTRY)/luxardolabs/luxarch:$(LUXARCH_VERSION)

# Code-style + type guard (luxlint) — pinned; pulled via LUXLINT_REGISTRY (Makefile.local),
# same out-of-tree pattern as luxarch. Unset host → make lint/format skip gracefully.
LUXLINT_REGISTRY ?=
LUXLINT_VERSION  := 0.83.0
LUXLINT_IMAGE    ?= $(LUXLINT_REGISTRY)/luxardolabs/luxlint:$(LUXLINT_VERSION)
# The luxlint ref the emitted gitleaks and test blocks read. Without the fleet registry it is the
# same pinned version from the local image store, never an unversioned build.
LUXLINT = $(if $(LUXLINT_REGISTRY),$(LUXLINT_IMAGE),luxlint:$(LUXLINT_VERSION))

# Dependency-vulnerability guard (luxaudit) — pinned; pulled via LUXAUDIT_REGISTRY (Makefile.local).
# Scans poetry.lock against the live OSV+PyPA feed. Unset host → `make audit` skips gracefully.
LUXAUDIT_REGISTRY ?=
LUXAUDIT_VERSION  := 0.22.0
LUXAUDIT_IMAGE    ?= $(LUXAUDIT_REGISTRY)/luxardolabs/luxaudit:$(LUXAUDIT_VERSION)
# The public image runs on other people's hardware (Raspberry Pis included), so every published
# build is multi-arch: the image block builds the candidate once per platform and scans each.
PLATFORMS ?= linux/amd64,linux/arm64

# Recursive (`=`): COMMIT is the image block's, defined below this line.
BUILD_ARGS = --build-arg BUILD_VERSION=$(VERSION) \
              --build-arg BUILD_TIMESTAMP=$(TIMESTAMP) \
              --build-arg BUILD_COMMIT=$(COMMIT)

# ANSI colors for `make help`
BLUE := \033[0;34m
GREEN := \033[0;32m
YELLOW := \033[0;33m
CYAN := \033[0;36m
NC := \033[0m
BOLD := \033[1m

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
# The collector-only stack names its profile here, so a .env.prod copied from .env.example
# (whose COMPOSE_PROFILES is the dev stack's) starts the collector alone and never the dev
# pair, which needs the dev host's network.
RUN_DC  := docker compose --env-file .env.prod --profile collector
PROD_DC := docker compose --env-file .env.prod --profile collector
# The dev stack is on the dev host: compose there sends this checkout's path, which the dev
# host mounts at the same place.
DEV_DC  = DOCKER_HOST=ssh://$(DEV_HOST) docker compose --env-file .env.dev
DEMO_DC := docker compose --env-file .env.demo
# Your real devices + a bundled InfluxDB and Grafana on THIS machine, ports published: the
# stack for anyone running the collector from a clone. Its profiles are named here, so a
# `.env.local` copied from .env.example (whose COMPOSE_PROFILES is the dev stack's) still
# starts this one and never the dev pair.
LOCAL_DC := docker compose --env-file .env.local --profile collector --profile local

# Remote prod deploy over SSH. The collector runs on a host with LAN access to the
# Kasa devices; set the node explicitly (no fleet default — this app is not bb01).
#   make prod-deploy PROD_NODE=collector01.example.com
PROD_NODE ?=
PROD_USER ?= root
PROD_DIR  ?= /opt/kasa-collector
PROD_SSH  := ssh -o BatchMode=yes $(PROD_USER)@$(PROD_NODE)
# Compose on the node is handed its project directory, file and env file on the command
# itself, so what it interpolates does not depend on the directory the ssh shell starts in.
PROD_REMOTE_DC = docker compose --project-directory $(PROD_DIR) -f $(PROD_DIR)/compose.yml --env-file $(PROD_DIR)/.env.prod --profile collector

.PHONY: help version \
        publish-sha dev-deploy dev-pin harness-build release release-public gh-release buildx-setup smoke \
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
	@echo "Release:   $(VERSION_IMAGE)"
	@echo "Public:    $(PUBLIC_IMAGE)"

##@ Docker — Build & Registry

# ONE shared fleet buildx builder — never a per-project one. Each per-project builder holds a
# completely separate cache (no base-layer/pip dedup, unbounded growth) plus an idle buildkit
# daemon; ten of them measured ~72G, deduplicating to ~10-15G on a single shared builder, which
# also buys cross-project cache hits. The buildkitd GC policy is the required second half
# (repo.buildx_builder_gc_capped) — a canonical name says nothing about whether it self-prunes.
# See luxarch --doc FLEET-BUILD-DEPLOY-STANDARD ("One shared buildx builder").
# luxarch:buildx-setup asset v3 - DO NOT edit this marker line; it is how repo.emitted_assets_current knows your copy is current. Re-emit with `luxarch --emit buildx-setup`.
BUILDX_BUILDER ?= luxardo-builder
# v3: every value this target splices into its shell goes through `bx_sq` (one single-quoted word),
# and BUILDX_BUILDER must be one plain name: v2 spliced $(HOME) and $(BUILDX_BUILDER) bare, and it
# runs before the image block's own checks. Its own copy of the quoting, because a repo may use this
# target without the image block.
define bx_newline


endef
bx_sq = $(if $(findstring $(bx_newline),$(1)),$(error REFUSING: a value buildx-setup splices into its recipe holds a newline),'$(subst ','\'',$(1))')
buildx-setup:
	@set -f; case $(call bx_sq,$(BUILDX_BUILDER)) in ''|-*|*[!A-Za-z0-9_.-]*) echo "REFUSING: BUILDX_BUILDER is one builder name ([A-Za-z0-9_.-]), not "$(call bx_sq,$(BUILDX_BUILDER)); exit 1;; esac
	@set -f; mkdir -p $(call bx_sq,$(HOME)/.docker)
	@set -f; [ -f $(call bx_sq,$(HOME)/.docker/buildkitd.toml) ] || printf '[worker.oci]\n  gc = true\n  [[worker.oci.gcpolicy]]\n    keepBytes = "20GB"\n    all = true\n' > $(call bx_sq,$(HOME)/.docker/buildkitd.toml)
	@set -f; docker buildx inspect $(call bx_sq,$(BUILDX_BUILDER)) >/dev/null 2>&1 || \
	  docker buildx create --name $(call bx_sq,$(BUILDX_BUILDER)) --driver docker-container \
	    --buildkitd-config $(call bx_sq,$(HOME)/.docker/buildkitd.toml) --use
	@set -f; docker buildx use $(call bx_sq,$(BUILDX_BUILDER))
	@set -f; strays=$$(docker buildx ls 2>/dev/null | awk '$$2=="docker-container"{print $$1}' \
	  | grep -v '^\\_' | sed 's/\*$$//' | grep -vxF $(call bx_sq,$(BUILDX_BUILDER)) | tr '\n' ' '); \
	if [ -n "$$strays" ] && [ -z $(call bx_sq,$(ALLOW_STRAY_BUILDERS)) ]; then \
	  echo "REFUSING: stray per-project buildx builders are running: $$strays"; \
	  echo "Remove them:  docker buildx rm $$strays"; \
	  exit 1; \
	fi

# luxarch:build-core asset v1 - DO NOT edit this marker line; it is how repo.emitted_assets_current knows your copy is current. Re-emit with `luxarch --emit build-core`.
# ── Build core: the image names, where each is built from, and the quoting every block splices with ──
# Emitted by `luxarch --emit build-core`. Paste it into the Makefile ABOVE the image block and the test
# block, with your settings (IMAGE_NAME, IMAGES, BUILD_CONTEXT, DOCKERFILE, …) above it: both blocks
# build with it. Until v1 these lines were part of the image block (v17), so a repo whose images are
# built and published elsewhere (`[build].evidence`: an external CI) had to paste the whole image block
# to get `make test`, and then carried a `dev-deploy` / `dev-pin` lane that cannot run there (REGISTRY
# empty) and two rules red over it. With the core alone the test block runs, and the rules about
# publishing and deploying have nothing to judge (N/A).
# Same makefile, directly above the image block: that block's inline publish guard reads this core's
# lines (from this marker to the core's end marker) as its own, and refuses a name defined anywhere
# else. Each `vN:` below is the image block version in which that line came in. The core defines no
# target; a value it splices still goes through `sq` / `sqw`, and BUILD_ARGS stays the repo's own.
# First, before anything runs a shell (REPO_SLUG's `$(shell git …)` below): a shell startup file
# (BASH_ENV, ENV) and SHELLOPTS / BASHOPTS (a tracing `xtrace`) never reach a shell make starts,
# at make time or in a recipe. The image block kept this line until v17; below the core, a `$(shell)`
# here ran with them.
unexport BASH_ENV ENV SHELLOPTS BASHOPTS
# v12: the repo's NAME, from its git remote, not the checkout directory. v11 used `$(notdir $(CURDIR))`, so a
# repo cloned into another directory (checked out under a shorter name on a build host) built and
# pushed an image nothing pulls, and the deploy reported success. With no remote it falls back to the
# directory. A repo whose image is named otherwise sets `IMAGE_NAME := luxardolabs/<name>` above the block.
override REPO_SLUG     := $(basename $(notdir $(shell git config --get remote.origin.url 2>/dev/null)))
IMAGE_NAME    ?= luxardolabs/$(or $(REPO_SLUG),$(notdir $(CURDIR)))

# v16: one repo, one VERSION, one release, MORE THAN ONE image. v1-v15 published exactly one image per
# makefile, so a repo shipping two (a server and its agent, both built from the root with different
# Dockerfiles and both run by compose from one `TAG=`) could not adopt the block: two copies collide,
# and one makefile per image splits the release and pins `.env.dev`'s TAG twice. EMPTY, the default,
# is v15's one image (IMAGE_NAME, DOCKERFILE, BUILD_CONTEXT) and the same commands. Set, list the
# images above the block and give each its settings there, as `?=`:
#   IMAGES                 ?= backend agent
#   backend_IMAGE_NAME     ?= luxardolabs/backend
#   backend_DOCKERFILE     ?= Dockerfile
#   backend_BUILD_CONTEXT  ?= .
#   agent_IMAGE_NAME       ?= luxardolabs/agent
#   agent_DOCKERFILE       ?= agent/Dockerfile
#   agent_BUILD_CONTEXT    ?= .
#   agent_TARGET           ?= production
# `<name>_BUILD_CONTEXT` defaults to `.`, `<name>_DOCKERFILE` to `<context>/Dockerfile`, `<name>_TARGET`
# to `production`; `<name>_IMAGE_NAME` is required. `release` and `publish-sha` build and scan EVERY
# image before they push ANY: one failing scan and nothing is pushed, so a release ships whole or not
# at all. Every image gets the same `:$(VERSION)` and `:sha-<commit>`, and `dev-pin` checks each is in
# the registry before it writes the one shared `TAG=` once. The FIRST image is the one the single-image
# names below (IMAGE, VERSION_IMAGE, SHA_IMAGE, TEST_IMAGE) mean, so the suite, smoke and prod-deploy
# read it. A name is a shell word (letters, digits, `_`).
IMAGES        ?=
override IMAGE_LIST    := $(strip $(IMAGES))
override IMAGE_PRIMARY := $(firstword $(IMAGE_LIST))
# One image's settings and tags, `$(call img_<x>,<name>)`. An EMPTY name is the one image of IMAGES
# empty, so each value is exactly the single-image variable it stands beside.
override img_name       = $(if $(1),$($(1)_IMAGE_NAME),$(IMAGE_NAME))
override img_context    = $(if $(1),$(or $($(1)_BUILD_CONTEXT),.),$(BUILD_CONTEXT))
override img_dockerfile = $(if $(1),$(or $($(1)_DOCKERFILE),$(call img_context,$(1))/Dockerfile),$(DOCKERFILE))
override img_target     = $(or $(if $(1),$($(1)_TARGET)),production)
override img_test       = $(if $(1),$(notdir $(call img_name,$(1))):test,$(TEST_IMAGE))

# LOCAL verification image — BARE on purpose: it cannot be pushed by accident and cannot be
# mistaken for a deployable. Rebuilt from source every run, so the suite never inherits a stale
# interpreter or stale deps. It is NOT `:dev`; a repo that tested on `:dev` kept failing correct
# code against a 13-day-old Python 3.13 image after the tree had moved to 3.14.
override TEST_IMAGE    := $(notdir $(if $(IMAGE_PRIMARY),$($(IMAGE_PRIMARY)_IMAGE_NAME),$(IMAGE_NAME))):test

# Where the image is built from. v9: v1-v8 built `.` with `./Dockerfile`, so a monorepo whose app builds
# from `apps/backend/` could only adopt the block by editing it. Set these above the block when the app
# is not at the root, e.g. `BUILD_CONTEXT := apps/backend`. Keep the context as narrow as the app: in a
# repo that holds data which must never ship, a narrow context is what keeps that data out of every
# image, structurally, rather than one `.dockerignore` pattern away.
BUILD_CONTEXT ?= .
DOCKERFILE    ?= $(BUILD_CONTEXT)/Dockerfile

override define IB_NL


endef
# v17: every make value that lands in a recipe's shell text goes through `sq`, which makes it ONE
# single-quoted shell word whatever it holds (a `'` inside is written `'\''`), so no value is ever shell
# syntax: not `;`, not `$(…)`, not a glob, not a space. Five rounds of listing the variables to check
# each missed one (a command-line `IMAGE=…;touch …`, a `DOCKERFILE := Dockerfile --push`, a committed
# directory named into RELEASE_NOTES); quoting at the splice is the property, and
# test_every_spliced_make_value_is_quoted reads both assets and refuses any `$(…)` in shell text that
# is not. `sqw` quotes each word of a list (BUILD_ARGS, RELEASE_NOTES, the profiles). Every recipe also
# starts `set -f`. A newline in a value would split the recipe itself (make runs each line as a command,
# `-i` or not), so `sq` refuses one at make time, before anything runs. The block cannot defend against its own Makefile: a recursive `BUILD_ARGS = …`
# whose expansion runs `$(eval …)` or `$(shell …)` is the repo's code running at make time.
override sq = $(if $(findstring $(IB_NL),$(1)),$(error REFUSING: a value a block splices into a recipe holds a newline. The recipe would split there and run what follows as commands. Remove it. The value is not printed because it may be a secret),'$(subst ','\'',$(1))')
override sqw = $(foreach w,$(1),$(call sq,$(w)))
# luxarch:build-core end - DO NOT edit this marker line: the image block's runtime guard reads its range.

# luxarch:image-block asset v29 - DO NOT edit this marker line; it is how repo.emitted_assets_current knows your copy is current. Re-emit with `luxarch --emit image-block`.
# ── Images: ONE naming scheme, and the NAME declares what the image IS ──────────────────────────
# Emitted by `luxarch --emit image-block`. Two axes, both readable from the name alone:
#
#   Registry-qualified  ->  DEPLOY artifact  ->  built AND PUSHED
#   Bare (no registry)  ->  LOCAL artifact   ->  built from source every run, NEVER pushed
#
#   Immutable tag (:$(VERSION), :sha-…)  ->  a stack MAY pin it
#   Moving tag (:dev, :latest)           ->  a human alias; NOTHING pins it, NOTHING builds FROM it
#
# Immutable tags are the point: a moving tag (`:dev` rolls as `:latest` does) cannot be a deployment
# record, and a local-only image must not wear a registry name (repo.image_name_declares_provenance).
# The why: --doc FLEET-BUILD-DEPLOY-STANDARD.

# v24: the GitHub Release is the gh-release block's (`luxarch --emit gh-release`): paste it directly
# BELOW this block, in the same makefile. `release` and `release-public` run its macros, every target
# refuses without it, and the inline guard checks its lines as the block's own.
# v18: the image names, build inputs, TEST_IMAGE and the quoting (`sq`, `sqw`) are the build core's
# (`luxarch --emit build-core`): paste it directly ABOVE this block, in the same makefile. Every target
# refuses without it, and the inline guard checks the core's lines as the block's own.
# v14: the registry HOST is set ABOVE the block, never here: a private repo in its Makefile
# (`REGISTRY := <host>:<port>`), a public one in its gitignored `Makefile.local`. Empty, every target
# that pushes or pins refuses.
REGISTRY      ?=
# v17, optional: `PRIVATE_REGISTRY := <host>:<port>` declares the private registry. Set, REGISTRY (and
# RELEASE_REGISTRY when it is REGISTRY) must be it; unset, REGISTRY is still never a public registry
# service (v21), and a RELEASE_REGISTRY on another host than REGISTRY requires it.
PRIVATE_REGISTRY ?=
# v13: the registry the RELEASE goes to, the one prod pulls from. Set it above the block when prod
# pulls elsewhere (`RELEASE_REGISTRY := registry.example.com`); one registry for both needs nothing.
RELEASE_REGISTRY ?= $(REGISTRY)
# One image's tags, `$(call img_<x>,<name>)`. With an EMPTY name each is the single-image VARIABLE
# itself, so the ref checked is the ref pushed. None may be set from outside the makefile.
override img_base       = $(if $(1),$(REGISTRY)/$(call img_name,$(1)),$(IMAGE))
override img_release    = $(if $(1),$(RELEASE_REGISTRY)/$(call img_name,$(1)),$(RELEASE_IMAGE))
override img_version    = $(if $(1),$(call img_release,$(1)):$(VERSION),$(VERSION_IMAGE))
override img_sha        = $(if $(1),$(call img_base,$(1)):sha-$(COMMIT),$(SHA_IMAGE))
override img_alias      = $(if $(1),$(call img_base,$(1)):dev,$(DEV_ALIAS))
override img_candidate  = $(if $(1),$(call img_base,$(1)):candidate-$(COMMIT),$(CANDIDATE))
override img_public     = $(if $(1),$(PUBLIC_REGISTRY)/$(call img_name,$(1)):$(VERSION),$(PUBLIC_IMAGE))
# `$(call image_block_each,<macro>,<separator>)`: the macro once per image, in IMAGES order, joined by
# the separator; with IMAGES empty, once for the one image. It is why `make -n` prints each image's
# own commands.
override image_block_each = $(call $(1),$(firstword $(IMAGE_LIST)))$(foreach i,$(wordlist 2,$(words $(IMAGE_LIST)),$(IMAGE_LIST)),$(2) $(call $(1),$(i)))

# BASE — no tag; every tag composes from it. A comment sits ABOVE a value, never after it: make keeps
# the spaces before an inline `#` in the value (test_emitted_makefiles_have_no_inline_comment_on_an_assignment).
override IMAGE         := $(REGISTRY)/$(if $(IMAGE_PRIMARY),$($(IMAGE_PRIMARY)_IMAGE_NAME),$(IMAGE_NAME))
override RELEASE_IMAGE := $(RELEASE_REGISTRY)/$(if $(IMAGE_PRIMARY),$($(IMAGE_PRIMARY)_IMAGE_NAME),$(IMAGE_NAME))
override COMMIT        := $(shell git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)

# IMMUTABLE deploy tags — the ONLY tags a stack may pin (`TAG=` in .env.<env>).
#   VERSION_IMAGE = cut releases, in the registry prod pulls from;  SHA_IMAGE = every other build,
#   addressable, no ceremony, in the dev registry.
override VERSION_IMAGE := $(RELEASE_IMAGE):$(VERSION)
override SHA_IMAGE     := $(IMAGE):sha-$(COMMIT)

# MOVING alias — for a human reading `docker images`. Never pinned by a stack, never a build input,
# never a base. If you delete this line nothing breaks; that is the test of an alias.
override DEV_ALIAS     := $(IMAGE):dev

# v14: the architectures a release builds. EMPTY (the default) builds the host's one architecture with
# `docker build --load`. Set it, as buildx's comma list above the block, only for an image someone ELSE
# runs elsewhere (`PLATFORMS := linux/amd64,linux/arm64`): `release` and `publish-sha` then build every
# platform once on the shared builder (`luxarch --emit buildx-setup`) under a `candidate-<commit>` tag,
# scan EACH platform, and only then point the immutable tag at it (`imagetools create`).
# --doc FLEET-BUILD-DEPLOY-STANDARD, "Architectures".
PLATFORMS ?=
override IMAGE_BLOCK_COMMA := ,
override PLATFORM_LIST := $(subst $(IMAGE_BLOCK_COMMA), ,$(strip $(PLATFORMS)))
# v14: a multi-arch candidate is pushed to REGISTRY, the private one, ALWAYS: a rejected candidate must
# never be public. `imagetools create` copies the scanned digest into RELEASE_REGISTRY afterwards.
override CANDIDATE     := $(IMAGE):candidate-$(COMMIT)

# ── Deploy: build AND push, always together (a registry tag built and not pushed names nothing) ──
# v14: every target that pushes or pins is ONE `set -e` shell (refusals, build, scan, push), so
# `make -i`, a `-i` in MAKEFLAGS or `.IGNORE:` cannot carry on past a refusal. The pieces below are
# shell text joined into that one line; never give one a recipe line of its own. The cut target is
# `release`, the name the release skill, the standard and repo.github_release_wired use.

# v17: the registries are the makefile's: each of REGISTRY, RELEASE_REGISTRY and PUBLIC_REGISTRY comes
# from a makefile (`:=` in the Makefile or Makefile.local), and REGISTRY, where every candidate and
# `:sha` goes, is never the public registry. Hosts compare lowercased, without :443, loopback forms as
# localhost and docker hub's names as docker.io (not folded: 127.1, 2130706433, 0x7f.1).
# v17: every ref the block pushes is DERIVED (`:=` in the block); one set from outside refuses.
# v17: the make INVOCATION is judged too. Every name the block sets is `override`, so a command-line
# value of one (silently ignored) refuses, as do `make -e`, `--eval`, MAKEFILES and MAKEFILE_LIST from
# outside; and the makefile make read FIRST must be this directory's default one (no `-f <wrapper>`).
# A makefile reading a file through HOME or PATH reads it in the clean evaluation too.
override define require_make_inputs
$(strip $(foreach w,$(MAKEOVERRIDES),$(if $(filter override,$(origin $(firstword $(subst :, ,$(subst =, ,$(w)))))),echo "REFUSING: $(firstword $(subst :, ,$(subst =, ,$(w)))) is set from the command line but the makefile defines it itself (an override): the image block refuses a value it would ignore"; exit 1; )))$(if $(filter-out --%,$(firstword $(MAKEFLAGS))),$(if $(findstring e,$(firstword $(MAKEFLAGS))),echo "REFUSING: make -e lets the environment override the makefile's own values: run make without -e"; exit 1; ))$(if $(filter --eval=%,$(MAKEFLAGS)),echo "REFUSING: make was run with --eval: it adds makefile text nobody committed. Run it without"; exit 1; )$(if $(filter-out file,$(origin MAKEFILE_LIST)),echo "REFUSING: MAKEFILE_LIST is set from outside the makefile"; exit 1; )\
[ -z $(call sq,$(strip $(MAKEFILES))) ] || { \
  echo "REFUSING: MAKEFILES is set, so make read makefiles before this one that nobody committed or named: unset it"; exit 1; }; \
ib_dm=; for m in GNUmakefile makefile Makefile; do if [ -f $(call sq,$(CURDIR))/"$$m" ]; then ib_dm=$$m; break; fi; done; \
[ -n "$$ib_dm" ] && [ $(call sq,$(abspath $(firstword $(MAKEFILE_LIST)))) = $(call sq,$(CURDIR))/"$$ib_dm" ] || { \
  echo "REFUSING: make read "$(call sq,$(firstword $(MAKEFILE_LIST)))" first, not this directory's default makefile ($${ib_dm:-none}): run make without -f, so what it reads is what a clean evaluation reads"; exit 1; }
endef

override IB_DERIVED_REFS = IMAGE RELEASE_IMAGE CANDIDATE SHA_IMAGE DEV_ALIAS VERSION_IMAGE PUBLIC_IMAGE PUBLIC_LATEST_IMAGE MIRROR_IMAGE TEST_IMAGE
override define require_registry
$(require_make_inputs); $(if $(filter-out file override,$(origin REGISTRY)),echo "REFUSING: REGISTRY comes from the shell or the command line and not a makefile: set it above the image block with := (a public repo: in Makefile.local) and do not pass or export it. A registry taken from the shell is how an unscanned candidate reaches a public registry."; exit 1; )$(if $(filter-out file override,$(origin RELEASE_REGISTRY)),echo "REFUSING: RELEASE_REGISTRY comes from the shell or the command line and not a makefile: set it above the image block with := (a public repo: in Makefile.local) and do not pass or export it. A registry taken from the shell is how an unscanned candidate reaches a public registry."; exit 1; )$(if $(filter-out file override,$(origin PUBLIC_REGISTRY)),echo "REFUSING: PUBLIC_REGISTRY comes from the shell or the command line and not a makefile: set it above the image block with := (a public repo: in Makefile.local) and do not pass or export it. A registry taken from the shell is how an unscanned candidate reaches a public registry."; exit 1; )\
[ -n $(call sq,$(strip $(REGISTRY))) ] && [ -n $(call sq,$(strip $(RELEASE_REGISTRY))) ] || { \
  echo "REFUSING: REGISTRY is empty. Set it above the image block (a public repo: in Makefile.local)"; exit 1; }; \
ib_host() { printf '%s\n' "$$1" | sed -e 's|/.*||' | tr 'A-Z' 'a-z' | sed -e 's/:443$$//' -e 's/^127\.[0-9]*\.[0-9]*\.[0-9]*\(:\|$$\)/localhost\1/' -e 's/^0\.0\.0\.0\(:\|$$\)/localhost\1/' -e 's/^\[::1\]\(:\|$$\)/localhost\1/' -e 's/^\(index\|registry-1\)\.docker\.io$$/docker.io/' -e 's/^registry\.hub\.docker\.com$$/docker.io/'; }; \
rh=$$(ib_host $(call sq,$(strip $(REGISTRY)))); ph=$$(ib_host $(call sq,$(strip $(PUBLIC_REGISTRY)))); \
[ -z "$$ph" ] || [ "$$rh" != "$$ph" ] || { \
  echo "REFUSING: REGISTRY is PUBLIC_REGISTRY (one host: compared lowercased, without the default port :443, localhost and 127.0.0.1 alike). REGISTRY holds every candidate before its scan and every sha- build; the public registry gets only a released, rescanned version (make release-public)"; exit 1; }; \
$(if $(filter-out file override,$(origin PRIVATE_REGISTRY)),echo "REFUSING: PRIVATE_REGISTRY comes from the shell or the command line and not a makefile: declare it above the image block as a literal"; exit 1; )\
pv=$$(ib_host $(call sq,$(strip $(PRIVATE_REGISTRY)))); lh=$$(ib_host $(call sq,$(strip $(RELEASE_REGISTRY)))); \
[ -z "$$pv" ] || [ "$$rh" = "$$pv" ] || { \
  echo "REFUSING: REGISTRY is host $$rh, not PRIVATE_REGISTRY's $$pv, the registry this repo declares private: every candidate and every sha- build goes to REGISTRY"; exit 1; }; \
[ -z "$$pv" ] || [ "$$lh" != "$$rh" ] || [ "$$lh" = "$$pv" ] || { \
  echo "REFUSING: RELEASE_REGISTRY is REGISTRY (host $$lh) but not PRIVATE_REGISTRY's $$pv"; exit 1; }; \
case "$$rh" in localhost|localhost:*|*.*|*:*) ;; *) \
  echo "REFUSING: REGISTRY's first part $$rh has no . or :, so docker reads it as a Docker Hub namespace (docker.io/$$rh/…), a public registry. Give the private registry's host (<host>:<port>)"; exit 1 ;; esac; \
case "$$rh" in docker.io|ghcr.io|quay.io|public.ecr.aws|gcr.io|*.gcr.io|*.pkg.dev|registry.gitlab.com|mcr.microsoft.com) \
  echo "REFUSING: REGISTRY is $$rh, a public registry service: REGISTRY holds every candidate before its scan and every sha- build, so it is the private registry. Prod pulling from $$rh is RELEASE_REGISTRY := $$rh; REGISTRY stays private"; exit 1 ;; esac; \
[ "$$lh" = "$$rh" ] || [ -n "$$pv" ] || { \
  echo "REFUSING: RELEASE_REGISTRY (host $$lh) is not REGISTRY (host $$rh), so this repo releases somewhere other than where its candidates are built: declare REGISTRY's host private above the block (PRIVATE_REGISTRY := <host>:<port>), which the block then holds REGISTRY to"; exit 1; }; \
$(require_derived_refs)
endef

# v17: the FACT behind the origin checks above. Every ref the block pushes must be its own formula
# over the makefile's values (IMAGE is REGISTRY/IMAGE_NAME, SHA_IMAGE is IMAGE:sha-COMMIT, …): an
# `override IMAGE :=` or an `override define IMAGE` in Makefile.local, or in a file MAKEFILES names,
# has an origin of `override` and a value that is not the derivation. MAKEFILES itself refuses: it
# reads makefiles nobody committed or named, before this one. And the values the refs are derived
# from (the registries, the names, PLATFORMS, COMMIT) must be the ones a CLEAN evaluation of these
# makefiles gives: make re-reads them under `env -i` (PATH and HOME only) with no command-line
# variables, and any difference refuses. That is what `REGISTRY := $(LUX_REGISTRY)` or
# `REGISTRY ?= $(SOME_REGISTRY)` inherited from a shell variable or the command line, which no origin
# check of REGISTRY itself can see. Makefile.local (gitignored, the public repos' home for REGISTRY)
# is read by the clean evaluation as by this one.
# the make binary running this one (MAKE_COMMAND), for the clean evaluation: a `$(MAKE)` in a recipe
# would run that line under `make -n`, and the line is the whole publish
override IB_MAKE := $(MAKE_COMMAND)
override IB_NAME = $(if $(IMAGE_PRIMARY),$($(IMAGE_PRIMARY)_IMAGE_NAME),$(IMAGE_NAME))
# v21: the scanner that decides whether a candidate is pushed (LUXAUDIT_IMAGE or LUXAUDIT) is the
# makefile's too. Set on the command line or composed from a command-line registry, it differed from the
# clean evaluation and chose the scan's verdict.
override IB_EVAL_VARS = REGISTRY RELEASE_REGISTRY PUBLIC_REGISTRY PRIVATE_REGISTRY IMAGE_NAME IMAGES PLATFORMS COMMIT VERSION \
  MIRROR_VERSION MIRROR_IMAGE_NAME LUXAUDIT_IMAGE LUXAUDIT $(foreach i,$(IMAGE_LIST),$(i)_IMAGE_NAME) $(IB_DERIVED_REFS)
# v21: a recipe line is expanded whole before it runs, so a `$(eval)` inside a variable the block
# expands late in it (BUILD_ARGS = $(eval REGISTRY := $(X))) re-set a value every check above had
# approved. Each guarded recipe starts with ib_run_snap (the values as its expansion begins) and ends
# with ib_unchanged, expanded last, which refuses before the line runs if any of them moved.
override ib_now_vars = $(foreach v,$(IB_EVAL_VARS),$(v)=$(strip $($(v)))|)
override define ib_run_snap
$(eval override IB_RUN_SNAP := $(subst $$,$$$$,$(ib_now_vars)))
endef
override define ib_unchanged
$(if $(and $(findstring |$(IB_RUN_SNAP)|,|$(ib_now_vars)|),$(findstring |$(ib_now_vars)|,|$(IB_RUN_SNAP)|)),,$(error REFUSING: a value the image block checked (a registry, an image name, the scanner) changed while make expanded the recipe, through a $$(eval) in a variable the block expands: nothing was built or pushed))
endef
override define require_derived_refs
ib_bad=; \
[ $(call sq,$(IMAGE)) = $(call sq,$(REGISTRY)/$(IB_NAME)) ] || ib_bad="$$ib_bad IMAGE"; \
[ $(call sq,$(RELEASE_IMAGE)) = $(call sq,$(RELEASE_REGISTRY)/$(IB_NAME)) ] || ib_bad="$$ib_bad RELEASE_IMAGE"; \
[ $(call sq,$(SHA_IMAGE)) = $(call sq,$(IMAGE):sha-$(COMMIT)) ] || ib_bad="$$ib_bad SHA_IMAGE"; \
[ $(call sq,$(DEV_ALIAS)) = $(call sq,$(IMAGE):dev) ] || ib_bad="$$ib_bad DEV_ALIAS"; \
[ $(call sq,$(CANDIDATE)) = $(call sq,$(IMAGE):candidate-$(COMMIT)) ] || ib_bad="$$ib_bad CANDIDATE"; \
[ $(call sq,$(VERSION_IMAGE)) = $(call sq,$(RELEASE_IMAGE):$(VERSION)) ] || ib_bad="$$ib_bad VERSION_IMAGE"; \
[ $(call sq,$(PUBLIC_IMAGE)) = $(call sq,$(PUBLIC_REGISTRY)/$(IB_NAME):$(VERSION)) ] || ib_bad="$$ib_bad PUBLIC_IMAGE"; \
[ $(call sq,$(PUBLIC_LATEST_IMAGE)) = $(call sq,$(PUBLIC_REGISTRY)/$(IB_NAME):latest) ] || ib_bad="$$ib_bad PUBLIC_LATEST_IMAGE"; \
[ $(call sq,$(MIRROR_IMAGE)) = $(call sq,$(REGISTRY)/$(MIRROR_IMAGE_NAME):$(MIRROR_VERSION)) ] || ib_bad="$$ib_bad MIRROR_IMAGE"; \
[ $(call sq,$(TEST_IMAGE)) = $(call sq,$(notdir $(IB_NAME)):test) ] || ib_bad="$$ib_bad TEST_IMAGE"; \
[ -z "$$ib_bad" ] || { \
  echo "REFUSING:$$ib_bad is not the image block's derivation of it (an override, a define, or a setting placed below the block): every ref the block pushes is derived from REGISTRY and the image name, set above the block"; exit 1; }; \
ib_now=$(call sq,$(foreach v,$(IB_EVAL_VARS),$(v)=$(strip $($(v)))|)); \
ib_out=$$(cd $(call sq,$(CURDIR)) && env -i PATH="$$PATH" HOME="$$HOME" $(call sq,$(IB_MAKE)) -s --no-print-directory -f "$$ib_dm" '--eval=ib-clean-eval: ; @$$(info IB_CLEAN $$(foreach v,$$(IB_EVAL_VARS),$$(v)=$$(strip $$($$(v)))|)):' ib-clean-eval 2>&1) || true; \
ib_clean=$$(printf '%s\n' "$$ib_out" | sed -n 's/^IB_CLEAN //p'); \
[ -n "$$ib_clean" ] || { echo "REFUSING: the image block could not re-read this makefile in a clean environment (env -i, no command-line variables), so nothing proves its registries and names are the makefile's. make said: $$(printf '%s\n' "$$ib_out" | grep -v '^IB_CLEAN' | tail -n 3 | tr '\n' ' ')"; exit 1; }; \
[ "$$ib_now" = "$$ib_clean" ] || { \
  ib_diff=$$(awk -v a="$$ib_now" -v b="$$ib_clean" 'function load(s, M,   n, i, k, v, P) { n = split(s, P, "|"); for (i = 1; i <= n; i++) { k = P[i]; sub(/^ +/, "", k); if (k == "") continue; v = k; sub(/=.*/, "", k); sub(/^[^=]*=/, "", v); M[k] = v } } BEGIN { load(a, A); load(b, B); for (k in A) if (!(k in B) || A[k] != B[k]) printf "%s ", k; for (k in B) if (!(k in A)) printf "%s ", k }'); \
  echo "REFUSING: $${ib_diff:-the variable list itself (IMAGES or another setting it is built from) }differ(s) from a clean evaluation of this makefile (env -i, no command-line variables): a value the block pushes with comes from the shell or the command line, directly or through a helper variable (REGISTRY := \$$(OTHER)). Write each registry as a literal above the block (REGISTRY := <host>:<port>, a public repo in Makefile.local)."; exit 1; }
endef

# v5: the scanner every push is gated by (luxaudit >= 0.13.0 in LUXAUDIT_IMAGE or LUXAUDIT), checked
# before anything is built.
override define require_scanner
[ -n $(call sq,$(or $(LUXAUDIT_IMAGE),$(LUXAUDIT))) ] || { \
  echo "REFUSING: set LUXAUDIT_IMAGE to the pinned luxaudit; the candidate must be scanned before it is pushed"; exit 2; }
endef

# v16: every image IMAGES lists is named, by a shell word, and no two publish to one name.
override define require_images
$(if $(IMAGE_LIST),for i in $(call sqw,$(IMAGE_LIST)); do case "$$i" in (''|[0-9]*|*[!A-Za-z0-9_]*) \
  echo "REFUSING: IMAGES entry '$$i' is not a shell word ([A-Za-z_][A-Za-z0-9_]*)"; exit 1 ;; esac; done; \
$(foreach i,$(IMAGE_LIST),[ -n $(call sq,$(strip $($(i)_IMAGE_NAME))) ] || { \
  echo "REFUSING: IMAGES lists "$(call sq,$(i))" but "$(call sq,$(i)_IMAGE_NAME)" is empty: set it above the image block"; exit 1; }; )\
[ $(words $(IMAGE_LIST) $(foreach i,$(IMAGE_LIST),$($(i)_IMAGE_NAME))) -eq $(words $(sort $(IMAGE_LIST)) $(sort $(foreach i,$(IMAGE_LIST),$($(i)_IMAGE_NAME)))) ] || { \
  echo "REFUSING: IMAGES names one image twice or gives two images one IMAGE_NAME"; exit 1; }; )
endef

# A `sha-<commit>` tag is immutable only if the bits ARE that commit. `git rev-parse HEAD` says nothing
# about the working tree: build with uncommitted changes and the registry holds an image named after
# commit X that contains X plus whatever was dirty, which is indistinguishable afterwards from a
# truthful one and worse than `:dev`, which is at least honestly ambiguous. One repo published
# `sha-b55e9a7b25ed` carrying a lockfile that commit does not have: bump deps, `make dev-build` to see
# it works, commit after. That is the routine order, and this recipe invited it. Untracked
# files count, because they are in the build context. No escape hatch: every fleet repo builds and PUSHES,
# and a stack runs what was pushed, so commit first. `make test-build` is for the TEST suite, not the stack.
# v14: a FAILED `git status` refuses. v13 tested `[ -n "$$(git status --porcelain 2>/dev/null)" ]`,
# and in a checkout git does not trust (owned by another user, no `safe.directory`) git exits 128 and
# prints nothing, which read as a clean tree: the dirty tree was built, labelled HEAD and pushed.
# v17: a tracked file git was told to stop checking refuses too. `git status` does not report a file
# whose index entry is marked skip-worktree or assume-unchanged (`git update-index --skip-worktree`),
# even after it is edited, and the edit is still in the build context: v16 read that tree as clean and
# pushed `sha-<commit>` with bytes the commit does not have. `git ls-files -v` tags those entries (`S`
# skip-worktree, a lowercase tag assume-unchanged), and any one of them refuses, because nothing then
# proves its bytes are the commit's. A sparse checkout marks every file it leaves out, and those are
# missing from the build context, so it refuses as well. Clear the mark, commit what it hid, publish.
# v17: `git status` is asked without the local settings that hide things from it: an fsmonitor hook
# reporting nothing changed, `status.showUntrackedFiles=no`, `submodule.<n>.ignore=all` or
# `diff.ignoreSubmodules`. These refusals are the early, readable message; what makes the image the
# commit is that it is BUILT from the commit (export_head below), not from this working tree.
override define refuse_dirty_tree
set -e; s=$$(git -c core.fsmonitor=false status --porcelain --untracked-files=all --ignore-submodules=none) || { \
  echo "REFUSING: git status failed, so nothing proves the working tree is clean (see git's error above)"; exit 1; }; \
if [ -n "$$s" ]; then \
  echo "REFUSING: the working tree is dirty, so sha-"$(call sq,$(COMMIT))" would not describe these bits:"; \
  printf '%s\n' "$$s" | sed 's/^/    /'; \
  echo "Commit first, then deploy what you pushed (make dev-deploy). make test-build is for the TEST suite only; it cannot run the stack."; \
  exit 1; \
fi; \
v=$$(git -c core.fsmonitor=false ls-files -v) || { \
  echo "REFUSING: git ls-files -v failed, so nothing proves no tracked file is hidden from git status"; exit 1; }; \
h=$$(printf '%s\n' "$$v" | grep -E '^([a-z]|S) ' || true); \
if [ -n "$$h" ]; then \
  echo "REFUSING: tracked files are marked skip-worktree/assume-unchanged, so git status cannot see an edit to them and sha-"$(call sq,$(COMMIT))" would not describe these bits:"; \
  printf '%s\n' "$$h" | sed 's/^/    /'; \
  echo "Clear the mark (git update-index --no-skip-worktree / --no-assume-unchanged <file>), commit what it hid, then publish."; \
  exit 1; \
fi
endef

# Refuse $(1) when the registry already holds it; $(2) says what to do instead. Fails CLOSED:
# `manifest inspect` exits 1 for "no such manifest" AND for an unreachable registry, so only the
# registry's own not-found answer reads as unpublished (a DNS blip must not let a re-push through).
override define refuse_published
if docker manifest inspect $(call sq,$(1)) >/dev/null 2>&1; then \
  echo "REFUSING: "$(call sq,$(1))" is already PUBLISHED. It is immutable: something pins it."; \
  echo $(call sq,$(2)); \
  exit 1; \
fi; \
out=$$(docker manifest inspect $(call sq,$(1)) 2>&1) || case "$$out" in \
  *[Nn]"o such manifest"*|*"manifest unknown"*) ;; \
  *) echo "REFUSING: cannot verify "$(call sq,$(1))" is unpublished: $$out"; exit 1 ;; \
esac
endef

# v17: every value the block splices into a docker command line is checked before anything runs, by
# make itself (it never reaches a shell): no shell metacharacter ; & | ( ) $ < > # \ ` or newline in
# BUILD_ARGS, PLATFORMS, BUILD_CONTEXT, DOCKERFILE, IMAGE_NAME, the registries, VERSION, COMMIT or any
# image's `<name>_IMAGE_NAME` / `_BUILD_CONTEXT` / `_DOCKERFILE` / `_TARGET`. A `; set --` in BUILD_ARGS
# ended the allowlist's word list, and a `_TARGET` was never checked at all. The one-word values (the
# targets, PLATFORMS, the names, registries and VERSION) also hold no quote or space; a target is one
# stage name ([A-Za-z0-9_.-]) and PLATFORMS a comma list of os/arch[/variant]. Then BUILD_ARGS goes
# through its allowlist (export_build_args).
override IB_LP := (
override IB_RP := )
override IB_HASH := \#
override IB_BS := $(strip \ )
override IB_DOLLAR := $$
override IB_META := ; & | $(IB_LP) $(IB_RP) < > $(IB_HASH) $(IB_BS) ` $(IB_DOLLAR)
# (a newline is reported as the WORD `newline`: `$(strip)` would erase the character itself, and did)
override ib_meta = $(strip $(foreach c,$(IB_META),$(findstring $(c),$(1))) $(if $(findstring $(IB_NL),$(1)),newline))
override IB_WORDS = PLATFORMS BUILD_CONTEXT DOCKERFILE IMAGE_NAME REGISTRY RELEASE_REGISTRY VERSION COMMIT \
  $(foreach i,$(IMAGE_LIST),$(i)_IMAGE_NAME $(i)_TARGET $(i)_BUILD_CONTEXT $(i)_DOCKERFILE) \
  MIRROR_VERSION MIRROR_IMAGE_NAME MIRROR_TARGET MIRROR_BUILD_CONTEXT MIRROR_DOCKERFILE
override IB_SPLICED = BUILD_ARGS $(IB_WORDS)
override ib_word_bad = $(or $(findstring ',$(1)),$(findstring ",$(1)),$(filter-out 0 1,$(words $(1))))
override define require_build_inputs
$(foreach v,$(IB_SPLICED),$(if $(call ib_meta,$($(v))),$(error REFUSING: $(v) holds a shell metacharacter (one of ; & | $(IB_LP) $(IB_RP) $(IB_DOLLAR) < > $(IB_HASH) backslash backtick or a newline). The image block splices it into the docker command line and checks every such value before anything runs)))$(foreach v,$(IB_WORDS),$(if $(call ib_word_bad,$($(v))),$(error REFUSING: $(v) must be one word with no quote or space: it is spliced into the docker command line)))$(if $(or $(findstring ',$(BUILD_ARGS)),$(findstring ",$(BUILD_ARGS))),$(error REFUSING: BUILD_ARGS holds a quote: each of its words is passed to docker as one argument as written))\
for t in $(foreach i,$(or $(IMAGE_LIST),_),$(call sq,$(call img_target,$(filter-out _,$(i))))); do case "$$t" in ''|*[!A-Za-z0-9_.-]*) \
  echo "REFUSING: a build target is one stage name ([A-Za-z0-9_.-]), not '$$t'"; exit 1 ;; esac; done; \
for p in $(call sqw,$(PLATFORM_LIST)); do printf '%s\n' "$$p" | grep -Eq '^[a-z0-9]+/[a-z0-9_]+(/[a-z0-9]+)?$$' || { \
  echo "REFUSING: PLATFORMS is a comma list of os/arch[/variant] (linux/amd64,linux/arm64), and '$$p' is not one"; exit 1; }; done;
endef

# v17: every image `release` and `publish-sha` push is BUILT FROM THE COMMIT, not from this working
# tree. v16 refused a dirty tree and then built `.`, so whatever `git status` could not see shipped
# under `sha-<commit>`: an edit hidden by a clean filter or an fsmonitor hook, a skip-worktree or
# assume-unchanged file (in a submodule too), a submodule set to `ignore=all`, untracked files under
# `status.showUntrackedFiles=no`, and every gitignored file `.dockerignore` does not exclude (docker
# sends them all). A status check can only enumerate what it was told to look for; the export IS the
# commit. HEAD is cloned (`--shared`, so no object is copied) into a temporary directory and checked
# out there, with none of this checkout's local config, attributes or hooks, and with git's own
# environment cleared first (GIT_DIR, GIT_WORK_TREE, GIT_INDEX_FILE and the object-store variables,
# and config injected by a parent `git -c …`: GIT_CONFIG_PARAMETERS, GIT_CONFIG_COUNT/KEY_n/VALUE_n,
# GIT_TEMPLATE_DIR, GIT_ATTR_SOURCE), so the repository is the one this makefile is in; HEAD must be
# the COMMIT make tagged the image with. The clone and checkout read NO config but their own: system
# and global config are off (GIT_CONFIG_NOSYSTEM, and GIT_CONFIG_GLOBAL pointed at an empty file the
# export creates, which also drops the XDG config; not /dev/null, which a host can have replaced with
# a regular file, and one did) and so is the global attributes file, so only the commit's own .gitattributes apply and
# no filter driver is defined: the bytes are the commit's (system attributes, GIT_ATTR_NOSYSTEM, too:
# an `/etc/gitattributes` `eol=crlf` rewrote line endings). No filter runs, so git-lfs smudging is NOT
# done: a file in the export whose content is an lfs pointer refuses, and so does any tracked path the
# commit assigns a `filter=` (git-crypt, transcrypt: the image would hold ciphertext). git itself
# answers which paths those are (`git check-attr filter` over every tracked path, per submodule), so
# macros, quoted patterns and nested .gitattributes are read as git reads them.
# Each initialized
# submodule, recursively, is cloned the same way at the commit its superproject's tree records. The
# builds run in that copy, at this makefile's place in it, so BUILD_CONTEXT, DOCKERFILE and any
# relative path in BUILD_ARGS mean what they mean here, resolved inside the commit. A context or a
# Dockerfile whose real path leaves the commit (a committed symlink to a directory outside it, an
# absolute path) refuses: docker follows it, and the image would hold bytes no commit has.
# Build caching is unchanged: BuildKit and the classic builder key a COPY on file content, not on the
# path or mtime of the context, so an unchanged layer still hits the cache. The cost is one checkout
# of the tree per publish, in TMPDIR.
# Every temporary file or directory the block makes is removed by an EXIT trap, and that trap and each
# HUP/INT/TERM trap first set those three signals to ignored. make passes a signal it gets on to the
# recipe shell, so a signal to the whole process group (a Ctrl-C, a `kill` of the group) reaches the
# shell twice, and the second can land while it handles the first; left trapped, it runs `exit` again
# inside the cleanup and the shell ends before removing anything. The ignore is inherited, so the
# `rm` the cleanup starts is not killed by it either.
override define export_tree
for v in $$(env | sed -n -e 's/^\(GIT_CONFIG_KEY_[0-9][0-9]*\)=.*/\1/p' -e 's/^\(GIT_CONFIG_VALUE_[0-9][0-9]*\)=.*/\1/p'); do unset "$$v"; done; \
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE \
  GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT GIT_TEMPLATE_DIR GIT_ATTR_SOURCE; \
top=$$(git -C $(call sq,$(CURDIR)) rev-parse --show-toplevel) && pre=$$(git -C $(call sq,$(CURDIR)) rev-parse --show-prefix) && \
head=$$(git -C $(call sq,$(CURDIR)) rev-parse --verify HEAD) && short=$$(git -C $(call sq,$(CURDIR)) rev-parse --short=12 HEAD) || { \
  echo "REFUSING: git cannot name this checkout's commit, so there is nothing to build from"; exit 1; }; \
[ "$$short" = $(call sq,$(COMMIT)) ] || { \
  echo "REFUSING: this checkout is at $$short, but the image would be tagged sha-"$(call sq,$(COMMIT))": $(if $(filter command line environment%,$(origin COMMIT)),COMMIT="$(call sq,$(COMMIT))" was set $(if $(findstring command,$(origin COMMIT)),on the command line,in the environment); do not set it,a GIT_DIR / GIT_WORK_TREE (or another GIT_*) variable pointed make at another repository; unset it). sha-<commit> names the commit it is built from."; exit 1; }; \
ctxdir=$$(mktemp -d); trap 'trap "" HUP INT TERM; [ -z "$$ctxdir" ] || rm -rf "$$ctxdir"' EXIT; trap 'trap "" HUP INT TERM; exit 1' HUP INT TERM; \
: > "$$ctxdir/empty"; \
xgit() { GIT_CONFIG_NOSYSTEM=1 GIT_ATTR_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$$ctxdir/empty" git -c core.attributesFile="$$ctxdir/empty" -c core.hooksPath="$$ctxdir/no-hooks" -c advice.detachedHead=false "$$@"; }; \
xgit clone -q --no-checkout --shared "$$top" "$$ctxdir/src" && \
xgit -C "$$ctxdir/src" checkout -q --detach "$$head" || { \
  echo "REFUSING: could not check out $$head into a clean copy to build from"; exit 1; }; \
subs=$$(git -C "$$top" submodule foreach --quiet --recursive 'printf "%s|%s\n" "$$displaypath" "$$sm_path"') || { \
  echo "REFUSING: git submodule foreach failed, so the submodules cannot be exported"; exit 1; }; \
printf '%s\n' "$$subs" | while IFS='|' read -r p s; do [ -n "$$p" ] || continue; \
  sup=$${p%"$$s"}; sup=$${sup%/}; \
  sha=$$(xgit -C "$$ctxdir/src/$$sup" rev-parse --verify "HEAD:$$s") && \
  xgit clone -q --no-checkout --shared "$$top/$$p" "$$ctxdir/src/$$p" && \
  xgit -C "$$ctxdir/src/$$p" checkout -q --detach "$$sha" || { \
    echo "REFUSING: could not export submodule $$p at the commit $$head records for it"; exit 1; }; \
done; \
flt=$$( { printf '.\n'; printf '%s\n' "$$subs" | cut -d'|' -f1; } | while IFS= read -r m; do [ -n "$$m" ] || continue; \
  d="$$ctxdir/src/$$m"; \
  if [ "$$(xgit -C "$$d" ls-files -z | tr -cd '\n' | wc -c)" -ne 0 ]; then echo "$$m: a tracked path holds a newline"; continue; fi; \
  xgit -C "$$d" ls-files -z | xgit -C "$$d" check-attr -z --stdin filter | tr '\0' '\n' | \
  awk -v m="$$m" 'NR % 3 == 1 { p = $$0 } NR % 3 == 0 && $$0 != "unspecified" && $$0 != "unset" && $$0 != "set" { print (m == "." ? "" : m "/") p " (filter=" $$0 ")" }'; done); \
nlp=$$(printf '%s\n' "$$flt" | grep 'holds a newline' | head -n 1 || true); \
if [ -n "$$nlp" ]; then echo "REFUSING: $$nlp: the image block reads git's path lists one path per line and cannot read that one. No fleet repo has such a path; rename it."; exit 1; fi; \
[ -z "$$flt" ] || { echo "REFUSING: the commit assigns a filter driver: $$(printf '%s' "$$flt" | tr '\n' ' '). The image is built from the commit's stored bytes with no filter run, so a filtered file (git-crypt or transcrypt ciphertext, a git-lfs pointer) would ship as stored."; exit 1; }; \
lfs=$$(find "$$ctxdir/src" -name .git -prune -o -type f -size -2k -print 2>/dev/null | while IFS= read -r x; do if [ "$$(head -n 1 "$$x" 2>/dev/null)" = 'version https://git-lfs.github.com/spec/v1' ]; then printf '%s ' "$${x#$$ctxdir/src/}"; fi; done); \
[ -z "$$lfs" ] || { echo "REFUSING: the commit stores git-lfs pointers ($$lfs): the image is built from the commit's own bytes with no filter run, so the pointer would ship in place of the file. git-lfs is not supported by the image block."; exit 1; }; \
root=$$(cd "$$ctxdir/src" && pwd -P); cd "$$ctxdir/src/$$pre"
endef

# v21: the clean copy, then what the app images build from. `publish-mirror` takes the copy and checks
# only the mirror's own context and Dockerfile, so a makefile that publishes nothing but a tool mirror
# (no app `./Dockerfile`) can publish it.
override define export_head
$(export_tree); \
$(call image_block_each,export_contained,;); \
$(export_build_args)
endef

# v17: BUILD_ARGS is an ALLOWLIST, because what it hands docker is part of the build. Three rounds of
# a denylist leaked a new spelling each (`--push=true`, a combined `-qo`, a `type=env` secret with no
# variable name that buildx then read as a FILE, a `file://` context buildx stats as a local path).
# Allowed, and nothing else (any other word refuses, named):
#   --build-arg K=V (a K=V pair: a bare `--build-arg VAR` reads the environment; K not BUILDKIT_*,
#     which reconfigures the builder, e.g. BUILDKIT_SYNTAX swaps the frontend)
#   --label K=V   --target T   --progress P   (each also as `--opt=value`)   --pull   --no-cache
#   --build-context <name>=<src>: a path that resolves inside the commit (relative to this Makefile),
#     or `docker-image://<ref>@sha256:<digest>`, pinned by digest. Nothing fetched by name or over the
#     network (https, git, ssh, an unpinned image) is the commit's bytes.
#   --secret: from the ENVIRONMENT only, read as buildx reads it (CSV fields, keys in any case):
#     `env=<VAR>`, or `type=env` with `src=<VAR>`; VAR a variable name. Never a file, never an id
#     standing in for one: inside the commit a file secret is a committed secret, outside it is
#     working-tree bytes. An environment secret is allowed by design: a secret is a build input, not
#     image content, unless the Dockerfile writes it into a layer.
# Not --platform: PLATFORMS is the one home for architectures, because only PLATFORMS' platforms are
# scanned before the digest is promoted (a `--platform` here added an unscanned image to the index).
override define export_build_args
( set -f; set -- $(call sqw,$(BUILD_ARGS)); \
  bad() { echo "REFUSING: BUILD_ARGS passes $$1, which is not in the image block's BUILD_ARGS allowlist: $$2"; exit 1; }; \
  dash() { case "$$2" in -*) bad "$$1 $$2" "a value that starts with - is read as another option" ;; esac; }; \
  while [ $$# -gt 0 ]; do o=$$1; shift; \
  case "$$o" in \
    --pull|--no-cache) continue ;; \
    --*=-*) bad "$$o" "a value that starts with - is read as another option" ;; \
    --platform|--platform=*) bad "$$o" "set PLATFORMS above the image block instead: only PLATFORMS' platforms are scanned before the image is promoted" ;; \
    --build-arg=?*) a=$${o#*=} ;; \
    --build-arg) [ $$# -gt 0 ] || bad "$$o" "it needs K=V"; dash "$$o" "$$1"; a=$$1; shift ;; \
    --label=?*|--target=?*|--progress=?*) continue ;; \
    --label|--target|--progress) [ $$# -gt 0 ] || bad "$$o" "it needs a value"; dash "$$o" "$$1"; shift; continue ;; \
    --build-context|--secret) [ $$# -gt 0 ] || bad "$$o" "it needs a value"; dash "$$o" "$$1"; v=$$1; shift ;; \
    --push|--push=*|--output|--output=*|-o|-o?*|--load=*) bad "$$o" "it publishes or writes the image before it is scanned; the block pushes after the scan" ;; \
    --build-context=?*|--secret=?*) v=$${o#*=}; o=$${o%%=*} ;; \
    *) bad "$$o" "the allowed words are --build-arg K=V --label --target --pull --no-cache --progress, a --build-context in the commit or docker-image://<ref>@sha256:<digest>, and a --secret from the environment (id=<id>,env=<VAR>)" ;; \
  esac; \
  case "$$o" in --build-arg*) \
    case "$$a" in \
      BUILDKIT_*) bad "--build-arg $$a" "a BUILDKIT_ argument reconfigures the builder itself (BUILDKIT_SYNTAX swaps the frontend)" ;; \
      [A-Za-z_]*=*) k=$${a%%=*}; case "$$k" in *[!A-Za-z0-9_]*) bad "--build-arg $$a" "the name is [A-Za-z_][A-Za-z0-9_]*" ;; esac; continue ;; \
      *) bad "--build-arg $$a" "it is K=V: a bare name reads the value from the environment of whoever runs make" ;; \
    esac ;; \
  esac; \
  if [ "$$o" = --secret ]; then \
    printf '%s\n' "$$v" | awk '{ s = $$0; n = 0; f = ""; q = 0; for (i = 1; i <= length(s); i++) { c = substr(s, i, 1); if (q) { if (c == "\"") { if (substr(s, i + 1, 1) == "\"") { f = f c; i++ } else q = 0 } else f = f c } else if (c == "\"") q = 1; else if (c == ",") { F[++n] = f; f = "" } else f = f c } F[++n] = f; ty = ""; ev = ""; sr = ""; for (k = 1; k <= n; k++) { j = index(F[k], "="); key = tolower(j ? substr(F[k], 1, j - 1) : F[k]); val = j ? substr(F[k], j + 1) : ""; if (key == "type") ty = tolower(val); else if (key == "env") ev = val; else if (key == "src" || key == "source") sr = val } name = "^[A-Za-z_][A-Za-z0-9_]*$$"; if (ev != "") exit !(ev ~ name && (ty == "" || ty == "env")); exit !(ty == "env" && sr ~ name) }' && continue; \
    bad "--secret $$v" "a secret comes from the environment only, never a file: --secret id=<id>,env=<VARIABLE>"; \
  fi; \
  case "$$v" in ?*=*) ;; *) bad "--build-context $$v" "it is <name>=<source>" ;; esac; \
  p=$${v#*=}; \
  case "$$p" in \
    docker-image://*) printf '%s\n' "$$p" | grep -Eq '^docker-image://[^@[:space:]]+@sha256:[0-9a-f]{64}$$' && continue; \
      bad "--build-context $$v" "an image context is pinned by digest: docker-image://<ref>@sha256:<digest>" ;; \
    *://*|git@*|github.com/*|target:*) bad "--build-context $$v" "a context is a path in the commit or docker-image://<ref>@sha256:<digest>; a source fetched by name or over the network is not the commit's bytes" ;; \
  esac; \
  if [ -e "$$p" ] && r=$$(realpath -- "$$p" 2>/dev/null) && case "$$r/" in "$$root/"*) true ;; *) false ;; esac; then continue; fi; \
  bad "--build-context $$v" "$$p is not in commit "$(call sq,$(COMMIT))", so docker would build bytes the commit does not hold; give a path inside the repository, relative to this Makefile"; \
done )
endef

override define export_contained
for p in $(call sq,$(call img_context,$(1))) $(call sq,$(call img_dockerfile,$(1))); do \
  [ -e "$$p" ] && r=$$(realpath -- "$$p" 2>/dev/null) || { echo "REFUSING: $$p is not in commit "$(call sq,$(COMMIT))" (it is what "$(call sq,$(or $(1),the image))" builds from)"; exit 1; }; \
  case "$$r/" in "$$root/"*) ;; *) echo "REFUSING: $$p resolves to $$r, outside the repository: docker would follow it and build bytes commit "$(call sq,$(COMMIT))" does not hold"; exit 1 ;; esac; \
done
endef

# Back to this makefile's directory once every image is built and pushed, and the copy removed.
override define export_leave
cd $(call sq,$(CURDIR)); rm -rf "$$ctxdir"; ctxdir=
endef

# The candidate gate, used by every target that pushes: scan the exact bits just built, mount-only,
# and refuse the push on any fixable HIGH/CRITICAL (luxaudit >= 0.13.0 in LUXAUDIT_IMAGE or LUXAUDIT).
# `make audit`'s image leg reads what the registry already holds, so it can only clear AFTER a release;
# as the gate it deadlocked. This is the gate. (v5)
# v14: `/repo` is `$(CURDIR)`, this makefile's directory, never `$(PWD)`. luxaudit reads the repo's
# `.luxaudit.toml` from `/repo`, and `$(PWD)` is the CALLER's shell directory: `make -C <repo> release`
# run from another repo scanned with THAT repo's `[[ignore]]` list and passed what this one refuses.
override define scan_candidate
set -e; ref=$(call sq,$(or $(LUXAUDIT_IMAGE),$(LUXAUDIT))); \
if [ -z "$$ref" ]; then echo "REFUSING: set LUXAUDIT_IMAGE to the pinned luxaudit; the candidate must be scanned before it is pushed"; exit 2; fi; \
T=$$(mktemp); trap 'trap "" HUP INT TERM; rm -f "$$T"; [ -z "$${ctxdir:-}" ] || rm -rf "$$ctxdir"' EXIT; trap 'trap "" HUP INT TERM; exit 1' HUP INT TERM; \
docker save $(call sq,$(1)) -o "$$T"; chmod 644 "$$T"; \
docker run --rm -v $(call sq,$(CURDIR)):/repo -v luxaudit-cache:/root/.cache/trivy -v "$$T":/candidate.tar:ro \
  "$$ref" --image-archive /candidate.tar --image-label $(call sq,$(1))
endef

# v14: promote a PUSHED image by the digest that was scanned, never by its tag. A tag can move
# between the scan and the promotion (another push of the same name), and `imagetools create` from the
# tag would then publish bits nothing scanned. So ONE shell reads the image's digest once, refuses an
# empty or malformed one, pulls and scans EACH platform by `<repo>@sha256:<digest>`, and creates the
# immutable tags from that same `<repo>@sha256:<digest>`. Any finding stops it before the promotion.
#   $(1) the pushed ref  $(2) its repository (no tag)  $(3) the `-t <tag>` list to create
# `pull --platform` fetches one platform's image (an arm64 image is pulled and saved on an x86 host,
# never run) and `docker save --platform` (Docker >= 28) writes exactly that one. The local copy is
# removed before each pull: the classic image store refuses a second platform under one digest.
# v16: in two halves, so every image is scanned before any is promoted: `promote_pin_scan` pins and
# scans ($(3) the shell variable holding the digest, `h` when empty), `promote_create` promotes.
# With more than one image each pins its own digest variable (`h_<name>`) and, once scanned, drops
# its local copy and its archive (the trap only cleans up after the last).
#   promote_pin_scan: $(1) the pushed ref  $(2) its repository (no tag)  $(3) the digest variable
#   promote_create:   $(1) the repository  $(2) the `-t <tag>` list to create  $(3) the digest variable
override define promote_pin_scan
set -e; ref=$(call sq,$(or $(LUXAUDIT_IMAGE),$(LUXAUDIT))); \
if [ -z "$$ref" ]; then echo "REFUSING: set LUXAUDIT_IMAGE to the pinned luxaudit; the image must be scanned before it is promoted"; exit 2; fi; \
$(or $(3),h)=$$(docker buildx imagetools inspect $(call sq,$(1)) --format '{{.Manifest.Digest.Encoded}}'); \
case "$$$(or $(3),h)" in ''|*[!0-9a-f]*) echo "REFUSING: could not read the digest of "$(call sq,$(1))"; nothing is promoted"; exit 1 ;; esac; \
pr=$(call sq,$(2)); T=$$(mktemp); trap 'trap "" HUP INT TERM; rm -f "$$T"; [ -z "$${ctxdir:-}" ] || rm -rf "$$ctxdir"; ( trap - HUP INT TERM; exec docker image rm "$$pr@sha256:$$$(or $(3),h)" ) >/dev/null 2>&1 || true' EXIT; trap 'trap "" HUP INT TERM; exit 1' HUP INT TERM; \
$(foreach p,$(or $(PLATFORM_LIST),host),docker image rm $(call sq,$(2))@sha256:$$$(or $(3),h) >/dev/null 2>&1 || true; docker pull -q $(if $(filter-out host,$(p)),--platform $(call sq,$(p)) )$(call sq,$(2))@sha256:$$$(or $(3),h); docker save $(if $(filter-out host,$(p)),--platform $(call sq,$(p)) )$(call sq,$(2))@sha256:$$$(or $(3),h) -o "$$T"; chmod 644 "$$T"; docker run --rm -v $(call sq,$(CURDIR)):/repo -v luxaudit-cache:/root/.cache/trivy -v "$$T":/candidate.tar:ro "$$ref" --image-archive /candidate.tar --image-label $(call sq,$(1) ($(p))); )$(if $(3),rm -f "$$T"; docker image rm $(call sq,$(2))@sha256:$$$(3) >/dev/null 2>&1 || true; )
endef

override define promote_create
docker buildx imagetools create $(foreach t,$(2),-t $(call sq,$(t))) $(call sq,$(1))@sha256:$$$(or $(3),h)
endef
# v23: the public copy is a carbon copy (`--prefer-index=false`): buildx otherwise wraps a single image
# in a new index, another digest than the one prod pins. Arguments as promote_create's.
override define promote_copy
docker buildx imagetools create --prefer-index=false $(foreach t,$(2),-t $(call sq,$(t))) $(call sq,$(1))@sha256:$$$(or $(3),h)
endef

# v11: every build names its output (`--load`). On the fleet's shared builder (`buildx-setup`, driver
# `docker-container`) a build with no output writes only to the build cache: it warns, exits 0, and
# the tag the next line scans, pushes or runs does not exist. `--load` is a no-op on the `docker` driver.
# Every commit's deployable: build, scan, push `:sha-<commit>` (what a dev/demo stack pins) and move the
# `:dev` alias. NEVER the version tag. v6: v5's `dev-deploy` ran `release`, which pushed `:$(VERSION)`
# on every run, so the first dev deploy after a version shipped overwrote that RELEASED tag with
# unreleased code (in one repo, prod's `:2026.09.0` silently became another
# commit's bits, caught by hand before the next prod pull).
# v14, PLATFORMS set: the candidate is pushed, its digest pinned, every platform scanned by that digest,
# then `:sha-<commit>` and the alias both point at that one scanned digest.
# v14: `:sha-<commit>` is published ONCE. v13 rebuilt and re-pushed it on every run, and no two builds
# are the same bytes (BUILD_TIMESTAMP, the runtime's package upgrade), so a second `dev-deploy` of one
# commit replaced the image a running stack pins, and one after a multi-arch publish replaced its
# scanned index with a single-arch rebuild. Already in the registry, it is deployed as it is.
# One image ($(1) its name, empty for the one image of IMAGES empty): build + scan, then push.
override define publish_sha_build
docker build --load --target $(call sq,$(call img_target,$(1))) $(call sqw,$(BUILD_ARGS)) -f $(call sq,$(call img_dockerfile,$(1))) -t $(call sq,$(call img_sha,$(1))) $(call sq,$(call img_context,$(1))); \
$(call scan_candidate,$(call img_sha,$(1)))$(if $(1),; rm -f "$$T")
endef

override define publish_sha_push
docker push $(call sq,$(call img_sha,$(1))); \
docker tag $(call sq,$(call img_sha,$(1))) $(call sq,$(call img_alias,$(1))); docker push $(call sq,$(call img_alias,$(1)))
endef

override define publish_sha_multi_build
docker buildx build --platform $(call sq,$(PLATFORMS)) --push --target $(call sq,$(call img_target,$(1))) $(call sqw,$(BUILD_ARGS)) -f $(call sq,$(call img_dockerfile,$(1))) -t $(call sq,$(call img_candidate,$(1))) $(call sq,$(call img_context,$(1))); \
$(call promote_pin_scan,$(call img_candidate,$(1)),$(call img_base,$(1)),$(if $(1),h_$(1)))
endef

override define publish_sha_multi_push
$(call promote_create,$(call img_base,$(1)),$(call img_sha,$(1)) $(call img_alias,$(1)),$(if $(1),h_$(1)))
endef

override define publish_sha_single
$(call publish_sha_build,); \
$(call publish_sha_push,)
endef

override define publish_sha_multi
$(call publish_sha_multi_build,)\
$(call publish_sha_multi_push,)
endef

# IMAGES empty: the one image, and already published it is deployed as it is.
override define publish_sha_one
if docker manifest inspect $(call sq,$(SHA_IMAGE)) >/dev/null 2>&1; then \
  echo $(call sq,$(SHA_IMAGE))" is already published: one commit is one image, deployed as it is (not rebuilt)"; \
  exit 0; \
fi; \
out=$$(docker manifest inspect $(call sq,$(SHA_IMAGE)) 2>&1) || case "$$out" in \
  *[Nn]"o such manifest"*|*"manifest unknown"*) ;; \
  *) echo "REFUSING: cannot verify "$(call sq,$(SHA_IMAGE))" is unpublished: $$out"; exit 1 ;; \
esac; \
$(export_head); \
$(if $(PLATFORM_LIST),$(publish_sha_multi),$(publish_sha_single)); \
$(export_leave)
endef

# v16, IMAGES set: an image whose `:sha-<commit>` is already published is skipped and deployed as it
# is (a run interrupted between two pushes resumes, never re-pushes). Every other image is built and
# scanned, and only when every scan has passed is any of them pushed.
override define publish_sha_todo
if docker manifest inspect $(call sq,$(call img_sha,$(1))) >/dev/null 2>&1; then \
  echo $(call sq,$(call img_sha,$(1)))" is already published: one commit is one image, deployed as it is (not rebuilt)"; \
else \
  out=$$(docker manifest inspect $(call sq,$(call img_sha,$(1))) 2>&1) || case "$$out" in \
    *[Nn]"o such manifest"*|*"manifest unknown"*) ;; \
    *) echo "REFUSING: cannot verify "$(call sq,$(call img_sha,$(1)))" is unpublished: $$out"; exit 1 ;; \
  esac; \
  todo="$$todo "$(call sq,$(1)); \
fi
endef

override image_block_todo = case " $$todo " in *" "$(call sq,$(1))" "*) $(call $(2),$(1)) ;; esac
override publish_sha_each_build = $(call image_block_todo,$(1),$(if $(PLATFORM_LIST),publish_sha_multi_build,publish_sha_build))
override publish_sha_each_push = $(call image_block_todo,$(1),$(if $(PLATFORM_LIST),publish_sha_multi_push,publish_sha_push))

override define publish_sha_images
todo=; \
$(call image_block_each,publish_sha_todo,;); \
if [ -z "$$todo" ]; then echo "every image of sha-"$(call sq,$(COMMIT))" is already published: deployed as they are"; exit 0; fi; \
$(export_head); \
$(call image_block_each,publish_sha_each_build,;); \
$(call image_block_each,publish_sha_each_push,;); \
$(export_leave)
endef

# v17: every target that pushes, pins or publishes STARTS with one inline guard, written into its
# recipe and not in a macro, because a macro is what code elsewhere can redefine (a goal-conditional
# include, a second `-f`, an untracked GNUmakefile). It uses only make's built-in functions and its
# own MAKE_COMMAND / MAKEFILE_LIST / MAKECMDGOALS (each origin-checked), and checks the FACT: make's
# own database (`make -pq` with the same goals, in a clean environment, on the tracked default
# makefile) defines every name the block sets INSIDE the block's lines (from its marker to its end
# marker) or the build core's (v18: its marker to its end marker, above the block, same file;
# each marker and end marker exactly once in the file, a marker only with its version digit:
# a decoy pair of comment lines above the real core once made the core's range empty), no target- or pattern-specific value of one exists, no registry is re-set for a target the
# block runs, the recipe make runs is the block's, and make read no makefile the clean evaluation
# does not. SHELL / .SHELLFLAGS from outside and a tracing `-x` refuse, and BASH_ENV, ENV, SHELLOPTS and BASHOPTS never
# reach a recipe shell (`unexport`).
publish-sha: $(if $(PLATFORM_LIST),buildx-setup) ## Build + scan + PUSH this commit as :sha-<commit> (and move the :dev alias) — never the version
	@$(ib_run_snap)$(if $(and $(value sq),$(value sqw),$(value img_dockerfile)),,$(error REFUSING: the image block (v18) builds with the build core's quoting and image helpers (sq, sqw, img_*), which this makefile does not define. Paste `luxarch --emit build-core` directly above the image block))$(if $(value gh_release_publish),,$(error REFUSING: the image block (v24) publishes its GitHub Release with the gh-release block (gh_release_preflight, gh_release_publish), which this makefile does not define. Paste `luxarch --emit gh-release` directly below the image block))set -e; set -f; $(if $(filter-out default,$(origin MAKE_COMMAND)),echo "REFUSING: MAKE_COMMAND is set from outside the makefile"; exit 1; )$(if $(strip $(MAKEFILES)),echo "REFUSING: MAKEFILES is set so make read makefiles before this one that nobody committed or named: unset it"; exit 1; )$(if $(filter-out file,$(origin MAKEFILE_LIST)),echo "REFUSING: MAKEFILE_LIST is set from outside the makefile"; exit 1; )$(if $(filter-out default undefined,$(origin MAKECMDGOALS)),echo "REFUSING: MAKECMDGOALS is set from outside the makefile"; exit 1; )$(if $(filter command% environment%,$(origin SHELL) $(origin .SHELLFLAGS)),echo "REFUSING: SHELL or .SHELLFLAGS comes from the command line or the environment: the recipe would run in another shell"; exit 1; )$(if $(findstring x,$(filter-out --%,$(filter -%,$(.SHELLFLAGS)))),echo "REFUSING: .SHELLFLAGS traces the recipe (-x) and would print every value spliced into it"; exit 1; )\
	[ -z "$${BASH_ENV:-}$${ENV:-}" ] || { echo "REFUSING: BASH_ENV or ENV is set: a shell startup file ran before this recipe"; exit 1; }; case $$- in *x*) echo "REFUSING: the recipe shell traces its commands (-x) and would print every value spliced into it"; exit 1 ;; esac; \
	ib_dm=; for m in GNUmakefile makefile Makefile; do if [ -f "$$m" ]; then ib_dm=$$m; break; fi; done; \
	[ -n "$$ib_dm" ] && git ls-files --error-unmatch -- "$$ib_dm" >/dev/null 2>&1 || { \
	  echo "REFUSING: this directory's default makefile ($${ib_dm:-none}) is not tracked by git: what make reads first must be committed"; exit 1; }; \
	ib_ml='$(subst ','\'',$(MAKEFILE_LIST))'; set -- $$ib_ml; \
	[ "$$(cd "$$(dirname -- "$$1")" && pwd -P)/$$(basename -- "$$1")" = "$$(pwd -P)/$$ib_dm" ] || { \
	  echo "REFUSING: make read $$1 first and not this directory's default makefile ($$ib_dm): run make without -f"; exit 1; }; \
	ib_db=$$(env -i PATH="$$PATH" HOME="$$HOME" '$(subst ','\'',$(MAKE_COMMAND))' -pq -f "$$ib_dm" $(foreach g,$(MAKECMDGOALS),'$(subst ','\'',$(g))') 2>&1) || true; \
	printf '%s\n' "$$ib_db" | grep -q '^# Variables' && ! printf '%s\n' "$$ib_db" | grep -Eq '^([^ #][^:]*:[0-9]+|make[^:]*): [*][*][*] ' || { \
	  echo "REFUSING: the image block could not re-read this makefile in a clean environment (env -i, no command-line variables) with these goals. make said: $$(printf '%s\n' "$$ib_db" | grep -E '^([^ #][^:]*:[0-9]+|make[^:]*): [*][*][*] ' | head -n 3 | tr '\n' ' ')"; exit 1; }; \
	ib_cml=$$(printf '%s\n' "$$ib_db" | sed -n 's/^MAKEFILE_LIST :*= *//p' | head -n 1); \
	for ib_x in $$ib_ml; do case " $$ib_cml " in *" $$ib_x "*) ;; *) \
	  echo "REFUSING: make read $$ib_x and a clean evaluation of $$ib_dm does not (a second -f): run make with the default makefile only"; exit 1 ;; esac; done; \
	ib_rl=$$(printf '%s\n' "$$ib_db" | awk -v t='$(subst ','\'',$@)' 'in_t && /^#  recipe to execute \(from / { s = $$0; sub(/^#  recipe to execute \(from \047/, "", s); f = s; sub(/\047, line [0-9]+\):$$/, "", f); l = s; sub(/^.*\047, line /, "", l); sub(/\):$$/, "", l); print f "|" l; exit } /^[^#\t ][^:]*:/ { in_t = (substr($$0, 1, length(t) + 1) == t ":") }'); \
	ib_bf=$${ib_rl%|*}; ib_rn=$${ib_rl##*|}; \
	[ -n "$$ib_rl" ] && [ -f "$$ib_bf" ] || { echo "REFUSING: make's database does not say where the recipe of "'$(subst ','\'',$@)'" is, so nothing proves it is the image block's"; exit 1; }; \
	set -- $$(awk '/^# luxarch:image-block asset v[0-9]/ { m = NR; nm++ } /^# luxarch:image-block end/ { e = NR; ne++ } /^# luxarch:build-core asset v[0-9]/ { cm = NR; ncm++ } /^# luxarch:build-core end/ { ce = NR; nce++ } /^# luxarch:gh-release asset v[0-9]/ { gm = NR; ngm++ } /^# luxarch:gh-release end/ { ge = NR; nge++ } END { if (nm != 1 || ne != 1) { m = 0; e = 0 } if (ncm != 1 || nce != 1) { cm = 0; ce = 0 } if (ngm != 1 || nge != 1) { gm = 0; ge = 0 } print m + 0 " " e + 0 " " cm + 0 " " ce + 0 " " gm + 0 " " ge + 0 }' "$$ib_bf"); ib_m=$${1:-0}; ib_e=$${2:-0}; ib_cm=$${3:-0}; ib_ce=$${4:-0}; ib_gm=$${5:-0}; ib_ge=$${6:-0}; \
	ib_lo=$$ib_m; ib_hi=$$ib_e; [ '$(subst ','\'',$@)' != gh-release ] || { ib_lo=$$ib_gm; ib_hi=$$ib_ge; }; [ "$$ib_m" -gt 0 ] && [ "$$ib_e" -gt "$$ib_m" ] && [ "$$ib_rn" -gt "$$ib_lo" ] && [ "$$ib_rn" -lt "$$ib_hi" ] || { \
	  echo "REFUSING: the recipe of "'$(subst ','\'',$@)'" make runs is $$ib_bf:$$ib_rn, which is not inside the block that ships it (gh-release: the gh-release block; every other target: the image block): a redefinition of the target replaced it"; exit 1; }; \
	[ "$$ib_cm" -gt 0 ] && [ "$$ib_ce" -gt "$$ib_cm" ] && [ "$$ib_ce" -lt "$$ib_m" ] || { \
	  echo "REFUSING: $$ib_bf has no build core directly above the image block (exactly one core marker and one core end marker in the file, both before the block's): the block's quoting and image names are the core's, and its guard checks them there. Paste luxarch --emit build-core above the block"; exit 1; }; \
	[ "$$ib_gm" -gt "$$ib_e" ] && [ "$$ib_ge" -gt "$$ib_gm" ] || { \
	  echo "REFUSING: $$ib_bf has no gh-release block below the image block (exactly one gh-release marker and one gh-release end marker in the file, both after the block's end): the release publishes its GitHub Release with it, and the guard checks its lines as the block's. Paste luxarch --emit gh-release below the block"; exit 1; }; \
	ib_nm=$$(awk -v m="$$ib_m" -v e="$$ib_e" -v cm="$$ib_cm" -v ce="$$ib_ce" -v gm="$$ib_gm" -v ge="$$ib_ge" '(NR >= m && NR <= e || NR >= cm && NR <= ce || NR >= gm && NR <= ge) && /^override / { s = $$0; sub(/^override +(define +)?/, "", s); sub(/[ \t:=+!?].*/, "", s); printf " %s", s } END { print " " }' "$$ib_bf"); \
	ib_bad=$$(printf '%s\n' "$$ib_db" | awk -v F="$$ib_bf" -v m="$$ib_m" -v e="$$ib_e" -v cm="$$ib_cm" -v ce="$$ib_ce" -v gm="$$ib_gm" -v ge="$$ib_ge" -v names="$$ib_nm" -v tg='$(subst ','\'',release publish-sha release-public publish-mirror dev-deploy dev-pin gh-release $@ $(MAKECMDGOALS))' 'function bad(n, w, f, l) { if (index(names, " " n " ") && (w != "" || f != F || (l + 0 < m || l + 0 > e) && (l + 0 < cm || l + 0 > ce) && (l + 0 < gm || l + 0 > ge))) printf "%s%s at %s:%s; ", n, (w != "" ? " (" w "-specific)" : ""), f, l; else if (w != "" && index(" REGISTRY RELEASE_REGISTRY PUBLIC_REGISTRY PRIVATE_REGISTRY LUXAUDIT_IMAGE LUXAUDIT IMAGE_NAME PLATFORMS ", " " n " ") && reaches(sc)) printf "%s (%s-specific, %s) at %s:%s; ", n, w, sc, f, l } function reaches(p,   i, k, T, a, b) { k = split(tg, T, " "); i = index(p, "%"); for (a = 1; a <= k; a++) { if (i == 0 && T[a] == p) return 1; if (i > 0 && index(T[a], substr(p, 1, i - 1)) == 1 && length(T[a]) >= length(p) - 1 && substr(T[a], length(T[a]) - (length(p) - i) + 1) == substr(p, i + 1)) return 1 } return 0 } /^# Pattern-specific Variable Values/ { pat = 1 } /^# (Directories|Implicit Rules|Files)/ { pat = 0 } pat && /^[^#].* :$$/ { ph = $$0; sub(/ :$$/, "", ph) } /^# (makefile|\047override\047 directive|environment|environment under -e|command line|default|automatic)( \(from \047.*\047, line [0-9]+\))?$$/ { o = 1; f = ""; l = 0; if (match($$0, /\(from \047.*\047, line [0-9]+\)$$/)) { s = substr($$0, RSTART + 7, RLENGTH - 8); f = s; sub(/\047, line [0-9]+$$/, "", f); l = s; sub(/^.*\047, line /, "", l) } next } o && pat && /^# [A-Za-z_.][A-Za-z0-9_.]* (::?:?=|=|\+=|\?=|!=)/ { sc = ph; bad($$2, "pattern", f, l); o = 0; next } o && /^[^#\t ][^:]*: [A-Za-z_.][A-Za-z0-9_.]* (::?:?=|=|\+=|\?=|!=)/ { x = $$0; sc = x; sub(/:.*/, "", sc); sub(/^[^:]*: /, "", x); split(x, X, " "); bad(X[1], "target", f, l); o = 0; next } o && /^define [A-Za-z_]/ { bad($$2, "", f, l); o = 0; next } o && /^[A-Za-z_.][A-Za-z0-9_.]* (::?:?=|=|\+=|\?=|!=)/ { bad($$1, "", f, l); o = 0; next } { o = 0 }'); \
	[ -z "$$ib_bad" ] || { echo "REFUSING: make's own database (a clean evaluation with these goals) defines what the image block defines from outside the block: $${ib_bad%; }. The block's names are set inside it only."; exit 1; }; \
	$(require_registry); $(require_images)$(require_build_inputs)$(refuse_dirty_tree); $(require_scanner); \
	$(if $(IMAGE_LIST),$(publish_sha_images),$(publish_sha_one)); \
	echo "deploy it with:  make dev-deploy   (or: make dev-pin TAG=sha-"$(call sq,$(COMMIT))")"$(ib_unchanged)

# v17: the tag on origin is compared, peeled, with the commit tagged here. v16 checked only that origin
# HAD the tag: a local tag force-moved to HEAD and not pushed passed every check, the image was built
# from HEAD, and `gh release create --verify-tag` hung the Release off origin's tag, another commit.
# Now `git ls-remote origin refs/tags/v<VERSION>^{}` (an annotated tag's commit; a lightweight tag is
# its own) must equal `v<VERSION>^{commit}` here, which `release` has already required to be HEAD. A
# standalone `make gh-release` after HEAD moved on compares with the local tag, the released commit.

# v17: origin's `v<VERSION>`, peeled, is the commit tagged here (see the note above). gh-release
# and release-public both run it: a local tag moved onto another commit must not vouch for a
# re-pushed `:VERSION` that release-public would copy public.
override define require_origin_tag
rt=$$(git ls-remote origin $(call sq,refs/tags/v$(VERSION)) $(call sq,refs/tags/v$(VERSION)^{})) || { \
  echo "REFUSING: git ls-remote origin failed, so nothing proves v"$(call sq,$(VERSION))" is on origin at the released commit"; exit 1; }; \
o=$$(printf '%s\n' "$$rt" | awk -v r=$(call sq,refs/tags/v$(VERSION)) '$$2 == r "^{}" { p = $$1 } $$2 == r { t = $$1 } END { print (p != "" ? p : t) }'); \
[ -n "$$o" ] || { \
  echo "REFUSING: v"$(call sq,$(VERSION))" is not on origin; the GitHub Release hangs off the pushed tag:"; \
  echo "    git tag -a v"$(call sq,$(VERSION))" -m v"$(call sq,$(VERSION))" && git push origin v"$(call sq,$(VERSION)); exit 1; }; \
l=$$(git rev-parse -q --verify $(call sq,refs/tags/v$(VERSION)^{commit}) 2>/dev/null || true); \
[ -n "$$l" ] || { echo "REFUSING: v"$(call sq,$(VERSION))" is not tagged in this checkout, so nothing says which commit was released (git fetch --tags)"; exit 1; }; \
[ "$$o" = "$$l" ] || { \
  echo "REFUSING: origin's v"$(call sq,$(VERSION))" is commit $$o, but here v"$(call sq,$(VERSION))" is $$l, the commit released: the GitHub Release (and release-public's copy) would vouch for a commit that was not released. A released tag is never moved: bump VERSION and release again."; exit 1; }
endef

# Cut VERSION: the immutable release tag prod pins. Refuses when that version is ALREADY released, in
# the registry or as a git tag at another commit: a released version is never re-pushed, not even from
# its own commit (a rebuild is different bytes under a name prod already runs). Bump VERSION instead.
# v14: a release pushes `:$(VERSION)` and nothing else. v13 also re-pushed `:sha-<commit>` and the
# `:dev` alias, overwriting the sha a dev stack pins; those are publish-sha's.
# v14, PLATFORMS set: the same refusals first, then the candidate is pushed to REGISTRY, its digest
# pinned, every platform scanned by that digest, and `:$(VERSION)` created in RELEASE_REGISTRY from it.
# v16, IMAGES set: every image's `:$(VERSION)` is refused if published, then every image is built and
# scanned, and pushed only after the last scan passed (one `set -e` shell): a failing scan of any
# image pushes none, so a release is refused whole.
override define release_build
docker build --load --target $(call sq,$(call img_target,$(1))) $(call sqw,$(BUILD_ARGS)) -f $(call sq,$(call img_dockerfile,$(1))) -t $(call sq,$(call img_version,$(1))) $(call sq,$(call img_context,$(1))); \
$(call scan_candidate,$(call img_version,$(1)))$(if $(1),; rm -f "$$T")
endef

override define release_push
docker push $(call sq,$(call img_version,$(1)))
endef

override define release_multi_build
docker buildx build --platform $(call sq,$(PLATFORMS)) --push --target $(call sq,$(call img_target,$(1))) $(call sqw,$(BUILD_ARGS)) -f $(call sq,$(call img_dockerfile,$(1))) -t $(call sq,$(call img_candidate,$(1))) $(call sq,$(call img_context,$(1))); \
$(call promote_pin_scan,$(call img_candidate,$(1)),$(call img_base,$(1)),$(if $(1),h_$(1)))
endef

override define release_multi_push
$(call promote_create,$(call img_base,$(1)),$(call img_version,$(1)),$(if $(1),h_$(1)))
endef

override define release_single
$(call image_block_each,release_build,;); \
$(call image_block_each,release_push,;)
endef

override define release_multi
$(call image_block_each,release_multi_build)\
$(call image_block_each,release_multi_push,;)
endef

# v23: and, with PUBLIC_REGISTRY set, a version already public there: a new private `:$(VERSION)` would
# name other bits than the public one, and every copy is the released digest.
override define release_refuse
$(call refuse_published,$(call img_version,$(1)),Bump VERSION for a new release; deploy this commit to dev with make dev-deploy. If its GitHub Release is missing: make gh-release)$(if $(strip $(PUBLIC_REGISTRY)),; \
$(call refuse_published,$(call img_public,$(1)),A released version is immutable on the public registry too: bump VERSION.))
endef

release: $(if $(PLATFORM_LIST),buildx-setup) ## Cut VERSION: build + scan + PUSH :$(VERSION), then the GitHub Release, which `release-public` publishes instead when PUBLIC_REGISTRY is set (refuses an already-released VERSION)
	@$(ib_run_snap)$(if $(and $(value sq),$(value sqw),$(value img_dockerfile)),,$(error REFUSING: the image block (v18) builds with the build core's quoting and image helpers (sq, sqw, img_*), which this makefile does not define. Paste `luxarch --emit build-core` directly above the image block))$(if $(value gh_release_publish),,$(error REFUSING: the image block (v24) publishes its GitHub Release with the gh-release block (gh_release_preflight, gh_release_publish), which this makefile does not define. Paste `luxarch --emit gh-release` directly below the image block))set -e; set -f; $(if $(filter-out default,$(origin MAKE_COMMAND)),echo "REFUSING: MAKE_COMMAND is set from outside the makefile"; exit 1; )$(if $(strip $(MAKEFILES)),echo "REFUSING: MAKEFILES is set so make read makefiles before this one that nobody committed or named: unset it"; exit 1; )$(if $(filter-out file,$(origin MAKEFILE_LIST)),echo "REFUSING: MAKEFILE_LIST is set from outside the makefile"; exit 1; )$(if $(filter-out default undefined,$(origin MAKECMDGOALS)),echo "REFUSING: MAKECMDGOALS is set from outside the makefile"; exit 1; )$(if $(filter command% environment%,$(origin SHELL) $(origin .SHELLFLAGS)),echo "REFUSING: SHELL or .SHELLFLAGS comes from the command line or the environment: the recipe would run in another shell"; exit 1; )$(if $(findstring x,$(filter-out --%,$(filter -%,$(.SHELLFLAGS)))),echo "REFUSING: .SHELLFLAGS traces the recipe (-x) and would print every value spliced into it"; exit 1; )\
	[ -z "$${BASH_ENV:-}$${ENV:-}" ] || { echo "REFUSING: BASH_ENV or ENV is set: a shell startup file ran before this recipe"; exit 1; }; case $$- in *x*) echo "REFUSING: the recipe shell traces its commands (-x) and would print every value spliced into it"; exit 1 ;; esac; \
	ib_dm=; for m in GNUmakefile makefile Makefile; do if [ -f "$$m" ]; then ib_dm=$$m; break; fi; done; \
	[ -n "$$ib_dm" ] && git ls-files --error-unmatch -- "$$ib_dm" >/dev/null 2>&1 || { \
	  echo "REFUSING: this directory's default makefile ($${ib_dm:-none}) is not tracked by git: what make reads first must be committed"; exit 1; }; \
	ib_ml='$(subst ','\'',$(MAKEFILE_LIST))'; set -- $$ib_ml; \
	[ "$$(cd "$$(dirname -- "$$1")" && pwd -P)/$$(basename -- "$$1")" = "$$(pwd -P)/$$ib_dm" ] || { \
	  echo "REFUSING: make read $$1 first and not this directory's default makefile ($$ib_dm): run make without -f"; exit 1; }; \
	ib_db=$$(env -i PATH="$$PATH" HOME="$$HOME" '$(subst ','\'',$(MAKE_COMMAND))' -pq -f "$$ib_dm" $(foreach g,$(MAKECMDGOALS),'$(subst ','\'',$(g))') 2>&1) || true; \
	printf '%s\n' "$$ib_db" | grep -q '^# Variables' && ! printf '%s\n' "$$ib_db" | grep -Eq '^([^ #][^:]*:[0-9]+|make[^:]*): [*][*][*] ' || { \
	  echo "REFUSING: the image block could not re-read this makefile in a clean environment (env -i, no command-line variables) with these goals. make said: $$(printf '%s\n' "$$ib_db" | grep -E '^([^ #][^:]*:[0-9]+|make[^:]*): [*][*][*] ' | head -n 3 | tr '\n' ' ')"; exit 1; }; \
	ib_cml=$$(printf '%s\n' "$$ib_db" | sed -n 's/^MAKEFILE_LIST :*= *//p' | head -n 1); \
	for ib_x in $$ib_ml; do case " $$ib_cml " in *" $$ib_x "*) ;; *) \
	  echo "REFUSING: make read $$ib_x and a clean evaluation of $$ib_dm does not (a second -f): run make with the default makefile only"; exit 1 ;; esac; done; \
	ib_rl=$$(printf '%s\n' "$$ib_db" | awk -v t='$(subst ','\'',$@)' 'in_t && /^#  recipe to execute \(from / { s = $$0; sub(/^#  recipe to execute \(from \047/, "", s); f = s; sub(/\047, line [0-9]+\):$$/, "", f); l = s; sub(/^.*\047, line /, "", l); sub(/\):$$/, "", l); print f "|" l; exit } /^[^#\t ][^:]*:/ { in_t = (substr($$0, 1, length(t) + 1) == t ":") }'); \
	ib_bf=$${ib_rl%|*}; ib_rn=$${ib_rl##*|}; \
	[ -n "$$ib_rl" ] && [ -f "$$ib_bf" ] || { echo "REFUSING: make's database does not say where the recipe of "'$(subst ','\'',$@)'" is, so nothing proves it is the image block's"; exit 1; }; \
	set -- $$(awk '/^# luxarch:image-block asset v[0-9]/ { m = NR; nm++ } /^# luxarch:image-block end/ { e = NR; ne++ } /^# luxarch:build-core asset v[0-9]/ { cm = NR; ncm++ } /^# luxarch:build-core end/ { ce = NR; nce++ } /^# luxarch:gh-release asset v[0-9]/ { gm = NR; ngm++ } /^# luxarch:gh-release end/ { ge = NR; nge++ } END { if (nm != 1 || ne != 1) { m = 0; e = 0 } if (ncm != 1 || nce != 1) { cm = 0; ce = 0 } if (ngm != 1 || nge != 1) { gm = 0; ge = 0 } print m + 0 " " e + 0 " " cm + 0 " " ce + 0 " " gm + 0 " " ge + 0 }' "$$ib_bf"); ib_m=$${1:-0}; ib_e=$${2:-0}; ib_cm=$${3:-0}; ib_ce=$${4:-0}; ib_gm=$${5:-0}; ib_ge=$${6:-0}; \
	ib_lo=$$ib_m; ib_hi=$$ib_e; [ '$(subst ','\'',$@)' != gh-release ] || { ib_lo=$$ib_gm; ib_hi=$$ib_ge; }; [ "$$ib_m" -gt 0 ] && [ "$$ib_e" -gt "$$ib_m" ] && [ "$$ib_rn" -gt "$$ib_lo" ] && [ "$$ib_rn" -lt "$$ib_hi" ] || { \
	  echo "REFUSING: the recipe of "'$(subst ','\'',$@)'" make runs is $$ib_bf:$$ib_rn, which is not inside the block that ships it (gh-release: the gh-release block; every other target: the image block): a redefinition of the target replaced it"; exit 1; }; \
	[ "$$ib_cm" -gt 0 ] && [ "$$ib_ce" -gt "$$ib_cm" ] && [ "$$ib_ce" -lt "$$ib_m" ] || { \
	  echo "REFUSING: $$ib_bf has no build core directly above the image block (exactly one core marker and one core end marker in the file, both before the block's): the block's quoting and image names are the core's, and its guard checks them there. Paste luxarch --emit build-core above the block"; exit 1; }; \
	[ "$$ib_gm" -gt "$$ib_e" ] && [ "$$ib_ge" -gt "$$ib_gm" ] || { \
	  echo "REFUSING: $$ib_bf has no gh-release block below the image block (exactly one gh-release marker and one gh-release end marker in the file, both after the block's end): the release publishes its GitHub Release with it, and the guard checks its lines as the block's. Paste luxarch --emit gh-release below the block"; exit 1; }; \
	ib_nm=$$(awk -v m="$$ib_m" -v e="$$ib_e" -v cm="$$ib_cm" -v ce="$$ib_ce" -v gm="$$ib_gm" -v ge="$$ib_ge" '(NR >= m && NR <= e || NR >= cm && NR <= ce || NR >= gm && NR <= ge) && /^override / { s = $$0; sub(/^override +(define +)?/, "", s); sub(/[ \t:=+!?].*/, "", s); printf " %s", s } END { print " " }' "$$ib_bf"); \
	ib_bad=$$(printf '%s\n' "$$ib_db" | awk -v F="$$ib_bf" -v m="$$ib_m" -v e="$$ib_e" -v cm="$$ib_cm" -v ce="$$ib_ce" -v gm="$$ib_gm" -v ge="$$ib_ge" -v names="$$ib_nm" -v tg='$(subst ','\'',release publish-sha release-public publish-mirror dev-deploy dev-pin gh-release $@ $(MAKECMDGOALS))' 'function bad(n, w, f, l) { if (index(names, " " n " ") && (w != "" || f != F || (l + 0 < m || l + 0 > e) && (l + 0 < cm || l + 0 > ce) && (l + 0 < gm || l + 0 > ge))) printf "%s%s at %s:%s; ", n, (w != "" ? " (" w "-specific)" : ""), f, l; else if (w != "" && index(" REGISTRY RELEASE_REGISTRY PUBLIC_REGISTRY PRIVATE_REGISTRY LUXAUDIT_IMAGE LUXAUDIT IMAGE_NAME PLATFORMS ", " " n " ") && reaches(sc)) printf "%s (%s-specific, %s) at %s:%s; ", n, w, sc, f, l } function reaches(p,   i, k, T, a, b) { k = split(tg, T, " "); i = index(p, "%"); for (a = 1; a <= k; a++) { if (i == 0 && T[a] == p) return 1; if (i > 0 && index(T[a], substr(p, 1, i - 1)) == 1 && length(T[a]) >= length(p) - 1 && substr(T[a], length(T[a]) - (length(p) - i) + 1) == substr(p, i + 1)) return 1 } return 0 } /^# Pattern-specific Variable Values/ { pat = 1 } /^# (Directories|Implicit Rules|Files)/ { pat = 0 } pat && /^[^#].* :$$/ { ph = $$0; sub(/ :$$/, "", ph) } /^# (makefile|\047override\047 directive|environment|environment under -e|command line|default|automatic)( \(from \047.*\047, line [0-9]+\))?$$/ { o = 1; f = ""; l = 0; if (match($$0, /\(from \047.*\047, line [0-9]+\)$$/)) { s = substr($$0, RSTART + 7, RLENGTH - 8); f = s; sub(/\047, line [0-9]+$$/, "", f); l = s; sub(/^.*\047, line /, "", l) } next } o && pat && /^# [A-Za-z_.][A-Za-z0-9_.]* (::?:?=|=|\+=|\?=|!=)/ { sc = ph; bad($$2, "pattern", f, l); o = 0; next } o && /^[^#\t ][^:]*: [A-Za-z_.][A-Za-z0-9_.]* (::?:?=|=|\+=|\?=|!=)/ { x = $$0; sc = x; sub(/:.*/, "", sc); sub(/^[^:]*: /, "", x); split(x, X, " "); bad(X[1], "target", f, l); o = 0; next } o && /^define [A-Za-z_]/ { bad($$2, "", f, l); o = 0; next } o && /^[A-Za-z_.][A-Za-z0-9_.]* (::?:?=|=|\+=|\?=|!=)/ { bad($$1, "", f, l); o = 0; next } { o = 0 }'); \
	[ -z "$$ib_bad" ] || { echo "REFUSING: make's own database (a clean evaluation with these goals) defines what the image block defines from outside the block: $${ib_bad%; }. The block's names are set inside it only."; exit 1; }; \
	$(require_registry); $(require_images)$(require_build_inputs)$(refuse_dirty_tree); $(require_scanner); \
	$(call image_block_each,release_refuse,;); \
	t=$$(git rev-parse -q --verify $(call sq,refs/tags/v$(VERSION))"^{commit}" 2>/dev/null || true); \
	if [ -n "$$t" ] && [ "$$t" != "$$(git rev-parse HEAD)" ]; then \
	  echo "REFUSING: v"$(call sq,$(VERSION))" is already tagged at $$t, not HEAD: bump VERSION."; exit 1; \
	fi; \
	if [ "$$t" != "$$(git rev-parse HEAD)" ]; then \
	  echo "REFUSING: v"$(call sq,$(VERSION))" is not tagged at HEAD. Tag and push it first:"; \
	  echo "    git tag -a v"$(call sq,$(VERSION))" -m v"$(call sq,$(VERSION))" && git push origin v"$(call sq,$(VERSION)); exit 1; \
	fi; \
	$(gh_release_preflight); \
	$(export_head); \
	$(if $(PLATFORM_LIST),$(release_multi),$(release_single)); \
	$(export_leave); \
	$(if $(strip $(PUBLIC_REGISTRY)),echo "The GitHub Release for v"$(call sq,$(VERSION))" follows the public copy: make release-public copies the release to "$(call sq,$(PUBLIC_REGISTRY))" and then publishes it",$(gh_release_publish)); \
	echo "released "$(call sq,$(call image_block_each,img_version))"; pin prod to TAG="$(call sq,$(VERSION))$(ib_unchanged)

# v14: a PUBLIC copy of the release, for an image other people pull (a public collector on GHCR). Set
# `PUBLIC_REGISTRY := ghcr.io` above this block and the target exists; unset, there is none. It never
# builds: it pins the RELEASED `:$(VERSION)` by digest, rescans that digest on every platform (a CVE
# published since the release stops it) and copies it, so the public image is bit-identical to the
# one prod pins. Like `release` it refuses a version already public there, and only the registry's
# own not-found answer reads as unpublished.
# v17: it refuses a dirty tree, as `release` does. The rescan reads this checkout's `.luxaudit.toml`,
# and v16 ran it over whatever was uncommitted: an `[[ignore]]` added and never committed cleared the
# rescan, and the image went public.
PUBLIC_REGISTRY ?=
PUBLIC_LATEST ?=
override PUBLIC_IMAGE := $(PUBLIC_REGISTRY)/$(if $(IMAGE_PRIMARY),$($(IMAGE_PRIMARY)_IMAGE_NAME),$(IMAGE_NAME)):$(VERSION)
override PUBLIC_LATEST_IMAGE := $(PUBLIC_REGISTRY)/$(if $(IMAGE_PRIMARY),$($(IMAGE_PRIMARY)_IMAGE_NAME),$(IMAGE_NAME)):latest

# v16, IMAGES set: every image's checks first, every rescan next, the copies last.
# v23: `make release-public PUBLIC_RESUME=1` resumes a copy that stopped part way, image by image: an
# image whose public `:$(VERSION)` exists must hold the digest just rescanned and only its `:latest`
# moves; an image whose public `:$(VERSION)` is absent is copied whole. Without it a public
# `:$(VERSION)` refuses, as always. It is one run's choice on this make's own command line: another
# origin, a parent make (MAKELEVEL) or an exported MAKEFLAGS naming it refuses. That check
# reads make's starting environment in /proc, so a resume runs on Linux only.
override IB_PUBLIC_RESUME = $(and $(filter command line,$(origin PUBLIC_RESUME)),$(filter 1,$(PUBLIC_RESUME)))
override define public_resume_gate
$(if $(filter-out undefined,$(origin PUBLIC_RESUME)),$(if $(filter-out command line,$(origin PUBLIC_RESUME)),echo "REFUSING: PUBLIC_RESUME is set in "$(call sq,$(origin PUBLIC_RESUME))": resuming a public copy is a choice for one run on the command line (make release-public PUBLIC_RESUME=1)"; exit 1; ,$(if $(IB_PUBLIC_RESUME),,echo "REFUSING: PUBLIC_RESUME="$(call sq,$(PUBLIC_RESUME))" is not 1"; exit 1; )))$(if $(IB_PUBLIC_RESUME),[ $(call sq,$(MAKELEVEL)) = 0 ] || { \
  echo "REFUSING: PUBLIC_RESUME came from a parent make (MAKELEVEL "$(call sq,$(MAKELEVEL))"): it is one run's choice on this make's own command line"; exit 1; }; \
ib_pe=$$(tr '\0' '\n' < /proc/$$PPID/environ) || { echo "REFUSING: PUBLIC_RESUME needs make's starting environment (/proc/$$PPID/environ) to tell this command line from an exported MAKEFLAGS"; exit 1; }; \
if printf '%s\n' "$$ib_pe" | grep -Eq '^(GNU)?MAKEFLAGS=.*PUBLIC_RESUME'; then echo "REFUSING: PUBLIC_RESUME is in an exported MAKEFLAGS: it is one run's choice on this make's own command line"; exit 1; fi; )
endef

override define public_seen
$(or $(if $(1),pv_$(1)),pv)=; \
if docker manifest inspect $(call sq,$(call img_public,$(1))) >/dev/null 2>&1; then $(or $(if $(1),pv_$(1)),pv)=1; \
elif out=$$(docker manifest inspect $(call sq,$(call img_public,$(1))) 2>&1); then $(or $(if $(1),pv_$(1)),pv)=1; \
else case "$$out" in *[Nn]"o such manifest"*|*"manifest unknown"*) ;; \
  *) echo "REFUSING: cannot verify whether "$(call sq,$(call img_public,$(1)))" is published: $$out"; exit 1 ;; esac; fi
endef

override define public_refuse
$(if $(IB_PUBLIC_RESUME),$(call public_seen,$(1)),$(call refuse_published,$(call img_public,$(1)),A released version is immutable: bump VERSION. If it holds the released digest (a copy that stopped before :latest): make release-public PUBLIC_RESUME=1)); \
docker manifest inspect $(call sq,$(call img_version,$(1))) >/dev/null 2>&1 || { \
  echo "REFUSING: "$(call sq,$(call img_version,$(1)))" is not released; run make release first (publish only what you released)"; exit 1; }
endef

# v17: the copy is judged by what the released digest HOLDS, not by this checkout's settings. v16
# rescanned PLATFORMS' platforms, and `imagetools create` copies the whole index: `PLATFORMS` changed
# since the release, or empty, left platforms public that nothing rescanned. And nothing tied the
# digest to the release: a `:$(VERSION)` re-pushed after `make release` went public as it was. Now
# the platforms are read from the digest itself (each image of an index, attestations aside; a single
# image, its own), every one is rescanned, and every one must carry an
# `org.opencontainers.image.revision` label (the canonical `BUILD_COMMIT`, short or full) naming the
# commit `v$(VERSION)` is tagged at here. A digest with no label, or another commit's, refuses.
#   $(1) the released ref  $(2) its repository (no tag)  $(3) the digest variable (`h` when empty)
override define public_pin_scan
set -e; ref=$(call sq,$(or $(LUXAUDIT_IMAGE),$(LUXAUDIT))); \
if [ -z "$$ref" ]; then echo "REFUSING: set LUXAUDIT_IMAGE to the pinned luxaudit; the image must be scanned before it is promoted"; exit 2; fi; \
$(or $(3),h)=$$(docker buildx imagetools inspect $(call sq,$(1)) --format '{{.Manifest.Digest.Encoded}}'); \
case "$$$(or $(3),h)" in ''|*[!0-9a-f]*) echo "REFUSING: could not read the digest of "$(call sq,$(1))"; nothing is promoted"; exit 1 ;; esac; \
pr=$(call sq,$(2)); T=$$(mktemp); trap 'trap "" HUP INT TERM; rm -f "$$T"; [ -z "$${ctxdir:-}" ] || rm -rf "$$ctxdir"; ( trap - HUP INT TERM; exec docker image rm "$$pr@sha256:$$$(or $(3),h)" ) >/dev/null 2>&1 || true' EXIT; trap 'trap "" HUP INT TERM; exit 1' HUP INT TERM; \
rev=$$(git rev-parse -q --verify $(call sq,refs/tags/v$(VERSION)^{commit}) 2>/dev/null) || { \
  echo "REFUSING: v"$(call sq,$(VERSION))" is not tagged in this checkout, so nothing names the commit "$(call sq,$(1))" must be (git fetch --tags)"; exit 1; }; \
mt=$$(docker buildx imagetools inspect $(call sq,$(2))@sha256:$$$(or $(3),h) --format '{{.Manifest.MediaType}}') || { echo "REFUSING: could not read what "$(call sq,$(1))" holds; nothing is promoted"; exit 1; }; \
case "$$mt" in \
  *index*|*manifest.list*) \
    plats=$$(docker buildx imagetools inspect $(call sq,$(2))@sha256:$$$(or $(3),h) --format '{{range .Manifest.Manifests}}{{if index .Annotations "vnd.docker.reference.type"}}{{else if .Platform}}{{.Platform.OS}}/{{.Platform.Architecture}}{{if .Platform.Variant}}/{{.Platform.Variant}}{{end}} {{else}}none {{end}}{{end}}') && \
    revs=$$(docker buildx imagetools inspect $(call sq,$(2))@sha256:$$$(or $(3),h) --format '{{range $$p, $$i := .Image}}{{or (index $$i.Config.Labels "org.opencontainers.image.revision") "-"}} {{end}}') ;; \
  *) \
    plats=$$(docker buildx imagetools inspect $(call sq,$(2))@sha256:$$$(or $(3),h) --format '{{.Image.OS}}/{{.Image.Architecture}}{{if .Image.Variant}}/{{.Image.Variant}}{{end}}') && \
    revs=$$(docker buildx imagetools inspect $(call sq,$(2))@sha256:$$$(or $(3),h) --format '{{or (index .Image.Config.Labels "org.opencontainers.image.revision") "-"}}') ;; \
esac || { echo "REFUSING: could not read the platforms and labels "$(call sq,$(1))" holds; nothing is promoted"; exit 1; }; \
case " $$plats " in *" none "*|*" / "*|"  ") echo "REFUSING: "$(call sq,$(1))" holds an image whose platform cannot be read, so it cannot be rescanned; nothing is promoted"; exit 1 ;; esac; \
[ "$$(echo $$plats | wc -w)" -eq "$$(echo $$revs | wc -w)" ] || { echo "REFUSING: "$(call sq,$(1))" holds $$(echo $$plats | wc -w) image(s) but $$(echo $$revs | wc -w) image config(s): nothing is promoted"; exit 1; }; \
for x in $$revs; do \
  case "$$x" in -|*[!0-9a-f]*) echo "REFUSING: an image of "$(call sq,$(1))" carries no org.opencontainers.image.revision label (it reads '$$x'), so nothing proves it is v"$(call sq,$(VERSION))"'s commit $$rev; nothing is promoted. Stamp it from BUILD_COMMIT (--doc FLEET-BUILD-DEPLOY-STANDARD)."; exit 1 ;; esac; \
  case "$$rev" in "$$x"*) [ $${#x} -ge 7 ] || { echo "REFUSING: an image of "$(call sq,$(1))" names its revision as '$$x', too short to name a commit; nothing is promoted"; exit 1; } ;; \
    *) echo "REFUSING: an image of "$(call sq,$(1))" was built from commit $$x, but v"$(call sq,$(VERSION))" is tagged at $$rev: the digest at :"$(call sq,$(VERSION))" is not the release; nothing is promoted"; exit 1 ;; esac; \
done; \
for p in $$plats; do \
  docker image rm $(call sq,$(2))@sha256:$$$(or $(3),h) >/dev/null 2>&1 || true; \
  docker pull -q --platform "$$p" $(call sq,$(2))@sha256:$$$(or $(3),h); \
  docker save --platform "$$p" $(call sq,$(2))@sha256:$$$(or $(3),h) -o "$$T"; chmod 644 "$$T"; \
  docker run --rm -v $(call sq,$(CURDIR)):/repo -v luxaudit-cache:/root/.cache/trivy -v "$$T":/candidate.tar:ro "$$ref" --image-archive /candidate.tar --image-label $(call sq,$(1))" ($$p)"; \
done; \
$(if $(3),rm -f "$$T"; docker image rm $(call sq,$(2))@sha256:$$$(3) >/dev/null 2>&1 || true; )
endef

override define public_scan
$(call public_pin_scan,$(call img_version,$(1)),$(call img_release,$(1)),$(if $(1),h_$(1)))
endef

# v17: `PUBLIC_LATEST := 1` (empty, the default, is v16's behaviour) also moves the PUBLIC `:latest` to
# the digest just rescanned and copied, in the same `imagetools create`, so the alias never points at
# anything the copy did not. It is a human alias on the public registry, as `:dev` is in the private
# one: nothing of the fleet's pins it. Any other value refuses. It refuses, too, unless VERSION is
# the NEWEST release: the highest of origin's `v<digits.dots>` tags (`ls-remote --tags`), ordered as
# versions (SemVer and CalVer both order numerically, field by field), so re-publishing an older
# version cannot roll `:latest` back. That one publishes with `PUBLIC_LATEST=` on its command line.
override define public_gate
$(refuse_dirty_tree); \
$(require_origin_tag); \
case $(call sq,$(strip $(PUBLIC_LATEST))) in ''|1) ;; *) echo "REFUSING: PUBLIC_LATEST is empty or 1, not "$(call sq,$(PUBLIC_LATEST)); exit 1 ;; esac; \
if [ $(call sq,$(strip $(PUBLIC_LATEST))) = 1 ]; then \
  vt=$$(git ls-remote --tags --refs origin 'refs/tags/v*') || { echo "REFUSING: git ls-remote origin failed, so nothing proves v"$(call sq,$(VERSION))" is the newest release, and :latest is moved only to the newest"; exit 1; }; \
  top=$$(printf '%s\n' "$$vt" | sed -n 's|^[0-9a-f]*[[:space:]]*refs/tags/v\([0-9][0-9]*\(\.[0-9][0-9]*\)*\)$$|\1|p' | sort -V | tail -n 1); \
  [ "$$top" = $(call sq,$(VERSION)) ] || { \
    echo "REFUSING: PUBLIC_LATEST moves :latest only to the newest release, and origin's newest is v$${top:-<none>}, not v"$(call sq,$(VERSION))": publishing an older version must not roll :latest back. Publish it without PUBLIC_LATEST (make release-public PUBLIC_LATEST=)"; exit 1; }; \
fi
endef

override img_public_latest = $(if $(1),$(PUBLIC_REGISTRY)/$(call img_name,$(1)):latest,$(PUBLIC_LATEST_IMAGE))

override define public_match
[ -z "$$$(or $(if $(1),pv_$(1)),pv)" ] || { pd=$$(docker buildx imagetools inspect $(call sq,$(call img_public,$(1))) --format '{{.Manifest.Digest.Encoded}}') || pd=; \
case "$$pd" in ''|*[!0-9a-f]*) echo "REFUSING: could not read the digest of "$(call sq,$(call img_public,$(1)))"; nothing is promoted"; exit 1 ;; esac; \
[ "$$pd" = "$$$(or $(if $(1),h_$(1)),h)" ] || { \
  echo "REFUSING: "$(call sq,$(call img_public,$(1)))" is PUBLISHED at another digest (sha256:$$pd) than the released "$(call sq,$(call img_version,$(1)))" (sha256:$$$(or $(if $(1),h_$(1)),h)): there is no copy to resume, and it is immutable. Bump VERSION."; exit 1; }; }
endef

override define public_copy
$(if $(IB_PUBLIC_RESUME),if [ -n "$$$(or $(if $(1),pv_$(1)),pv)" ]; then $(if $(filter 1,$(strip $(PUBLIC_LATEST))),$(call promote_copy,$(call img_release,$(1)),$(call img_public_latest,$(1)),$(if $(1),h_$(1))),echo $(call sq,$(call img_public,$(1)))" already holds the released digest: nothing to copy"); else $(call promote_copy,$(call img_release,$(1)),$(call img_public,$(1)) $(if $(filter 1,$(strip $(PUBLIC_LATEST))),$(call img_public_latest,$(1))),$(if $(1),h_$(1))); fi,$(call promote_copy,$(call img_release,$(1)),$(call img_public,$(1)) $(if $(filter 1,$(strip $(PUBLIC_LATEST))),$(call img_public_latest,$(1))),$(if $(1),h_$(1))))
endef

override public_said = $(call img_version,$(1)) as $(call img_public,$(1))

ifneq ($(strip $(PUBLIC_REGISTRY)),)
release-public: ## Copy the RELEASED :$(VERSION) to $(PUBLIC_REGISTRY) by digest after rescanning it (run `make release` first)
	@$(ib_run_snap)$(if $(and $(value sq),$(value sqw),$(value img_dockerfile)),,$(error REFUSING: the image block (v18) builds with the build core's quoting and image helpers (sq, sqw, img_*), which this makefile does not define. Paste `luxarch --emit build-core` directly above the image block))$(if $(value gh_release_publish),,$(error REFUSING: the image block (v24) publishes its GitHub Release with the gh-release block (gh_release_preflight, gh_release_publish), which this makefile does not define. Paste `luxarch --emit gh-release` directly below the image block))set -e; set -f; $(if $(filter-out default,$(origin MAKE_COMMAND)),echo "REFUSING: MAKE_COMMAND is set from outside the makefile"; exit 1; )$(if $(strip $(MAKEFILES)),echo "REFUSING: MAKEFILES is set so make read makefiles before this one that nobody committed or named: unset it"; exit 1; )$(if $(filter-out file,$(origin MAKEFILE_LIST)),echo "REFUSING: MAKEFILE_LIST is set from outside the makefile"; exit 1; )$(if $(filter-out default undefined,$(origin MAKECMDGOALS)),echo "REFUSING: MAKECMDGOALS is set from outside the makefile"; exit 1; )$(if $(filter command% environment%,$(origin SHELL) $(origin .SHELLFLAGS)),echo "REFUSING: SHELL or .SHELLFLAGS comes from the command line or the environment: the recipe would run in another shell"; exit 1; )$(if $(findstring x,$(filter-out --%,$(filter -%,$(.SHELLFLAGS)))),echo "REFUSING: .SHELLFLAGS traces the recipe (-x) and would print every value spliced into it"; exit 1; )\
	[ -z "$${BASH_ENV:-}$${ENV:-}" ] || { echo "REFUSING: BASH_ENV or ENV is set: a shell startup file ran before this recipe"; exit 1; }; case $$- in *x*) echo "REFUSING: the recipe shell traces its commands (-x) and would print every value spliced into it"; exit 1 ;; esac; \
	ib_dm=; for m in GNUmakefile makefile Makefile; do if [ -f "$$m" ]; then ib_dm=$$m; break; fi; done; \
	[ -n "$$ib_dm" ] && git ls-files --error-unmatch -- "$$ib_dm" >/dev/null 2>&1 || { \
	  echo "REFUSING: this directory's default makefile ($${ib_dm:-none}) is not tracked by git: what make reads first must be committed"; exit 1; }; \
	ib_ml='$(subst ','\'',$(MAKEFILE_LIST))'; set -- $$ib_ml; \
	[ "$$(cd "$$(dirname -- "$$1")" && pwd -P)/$$(basename -- "$$1")" = "$$(pwd -P)/$$ib_dm" ] || { \
	  echo "REFUSING: make read $$1 first and not this directory's default makefile ($$ib_dm): run make without -f"; exit 1; }; \
	ib_db=$$(env -i PATH="$$PATH" HOME="$$HOME" '$(subst ','\'',$(MAKE_COMMAND))' -pq -f "$$ib_dm" $(foreach g,$(MAKECMDGOALS),'$(subst ','\'',$(g))') 2>&1) || true; \
	printf '%s\n' "$$ib_db" | grep -q '^# Variables' && ! printf '%s\n' "$$ib_db" | grep -Eq '^([^ #][^:]*:[0-9]+|make[^:]*): [*][*][*] ' || { \
	  echo "REFUSING: the image block could not re-read this makefile in a clean environment (env -i, no command-line variables) with these goals. make said: $$(printf '%s\n' "$$ib_db" | grep -E '^([^ #][^:]*:[0-9]+|make[^:]*): [*][*][*] ' | head -n 3 | tr '\n' ' ')"; exit 1; }; \
	ib_cml=$$(printf '%s\n' "$$ib_db" | sed -n 's/^MAKEFILE_LIST :*= *//p' | head -n 1); \
	for ib_x in $$ib_ml; do case " $$ib_cml " in *" $$ib_x "*) ;; *) \
	  echo "REFUSING: make read $$ib_x and a clean evaluation of $$ib_dm does not (a second -f): run make with the default makefile only"; exit 1 ;; esac; done; \
	ib_rl=$$(printf '%s\n' "$$ib_db" | awk -v t='$(subst ','\'',$@)' 'in_t && /^#  recipe to execute \(from / { s = $$0; sub(/^#  recipe to execute \(from \047/, "", s); f = s; sub(/\047, line [0-9]+\):$$/, "", f); l = s; sub(/^.*\047, line /, "", l); sub(/\):$$/, "", l); print f "|" l; exit } /^[^#\t ][^:]*:/ { in_t = (substr($$0, 1, length(t) + 1) == t ":") }'); \
	ib_bf=$${ib_rl%|*}; ib_rn=$${ib_rl##*|}; \
	[ -n "$$ib_rl" ] && [ -f "$$ib_bf" ] || { echo "REFUSING: make's database does not say where the recipe of "'$(subst ','\'',$@)'" is, so nothing proves it is the image block's"; exit 1; }; \
	set -- $$(awk '/^# luxarch:image-block asset v[0-9]/ { m = NR; nm++ } /^# luxarch:image-block end/ { e = NR; ne++ } /^# luxarch:build-core asset v[0-9]/ { cm = NR; ncm++ } /^# luxarch:build-core end/ { ce = NR; nce++ } /^# luxarch:gh-release asset v[0-9]/ { gm = NR; ngm++ } /^# luxarch:gh-release end/ { ge = NR; nge++ } END { if (nm != 1 || ne != 1) { m = 0; e = 0 } if (ncm != 1 || nce != 1) { cm = 0; ce = 0 } if (ngm != 1 || nge != 1) { gm = 0; ge = 0 } print m + 0 " " e + 0 " " cm + 0 " " ce + 0 " " gm + 0 " " ge + 0 }' "$$ib_bf"); ib_m=$${1:-0}; ib_e=$${2:-0}; ib_cm=$${3:-0}; ib_ce=$${4:-0}; ib_gm=$${5:-0}; ib_ge=$${6:-0}; \
	ib_lo=$$ib_m; ib_hi=$$ib_e; [ '$(subst ','\'',$@)' != gh-release ] || { ib_lo=$$ib_gm; ib_hi=$$ib_ge; }; [ "$$ib_m" -gt 0 ] && [ "$$ib_e" -gt "$$ib_m" ] && [ "$$ib_rn" -gt "$$ib_lo" ] && [ "$$ib_rn" -lt "$$ib_hi" ] || { \
	  echo "REFUSING: the recipe of "'$(subst ','\'',$@)'" make runs is $$ib_bf:$$ib_rn, which is not inside the block that ships it (gh-release: the gh-release block; every other target: the image block): a redefinition of the target replaced it"; exit 1; }; \
	[ "$$ib_cm" -gt 0 ] && [ "$$ib_ce" -gt "$$ib_cm" ] && [ "$$ib_ce" -lt "$$ib_m" ] || { \
	  echo "REFUSING: $$ib_bf has no build core directly above the image block (exactly one core marker and one core end marker in the file, both before the block's): the block's quoting and image names are the core's, and its guard checks them there. Paste luxarch --emit build-core above the block"; exit 1; }; \
	[ "$$ib_gm" -gt "$$ib_e" ] && [ "$$ib_ge" -gt "$$ib_gm" ] || { \
	  echo "REFUSING: $$ib_bf has no gh-release block below the image block (exactly one gh-release marker and one gh-release end marker in the file, both after the block's end): the release publishes its GitHub Release with it, and the guard checks its lines as the block's. Paste luxarch --emit gh-release below the block"; exit 1; }; \
	ib_nm=$$(awk -v m="$$ib_m" -v e="$$ib_e" -v cm="$$ib_cm" -v ce="$$ib_ce" -v gm="$$ib_gm" -v ge="$$ib_ge" '(NR >= m && NR <= e || NR >= cm && NR <= ce || NR >= gm && NR <= ge) && /^override / { s = $$0; sub(/^override +(define +)?/, "", s); sub(/[ \t:=+!?].*/, "", s); printf " %s", s } END { print " " }' "$$ib_bf"); \
	ib_bad=$$(printf '%s\n' "$$ib_db" | awk -v F="$$ib_bf" -v m="$$ib_m" -v e="$$ib_e" -v cm="$$ib_cm" -v ce="$$ib_ce" -v gm="$$ib_gm" -v ge="$$ib_ge" -v names="$$ib_nm" -v tg='$(subst ','\'',release publish-sha release-public publish-mirror dev-deploy dev-pin gh-release $@ $(MAKECMDGOALS))' 'function bad(n, w, f, l) { if (index(names, " " n " ") && (w != "" || f != F || (l + 0 < m || l + 0 > e) && (l + 0 < cm || l + 0 > ce) && (l + 0 < gm || l + 0 > ge))) printf "%s%s at %s:%s; ", n, (w != "" ? " (" w "-specific)" : ""), f, l; else if (w != "" && index(" REGISTRY RELEASE_REGISTRY PUBLIC_REGISTRY PRIVATE_REGISTRY LUXAUDIT_IMAGE LUXAUDIT IMAGE_NAME PLATFORMS ", " " n " ") && reaches(sc)) printf "%s (%s-specific, %s) at %s:%s; ", n, w, sc, f, l } function reaches(p,   i, k, T, a, b) { k = split(tg, T, " "); i = index(p, "%"); for (a = 1; a <= k; a++) { if (i == 0 && T[a] == p) return 1; if (i > 0 && index(T[a], substr(p, 1, i - 1)) == 1 && length(T[a]) >= length(p) - 1 && substr(T[a], length(T[a]) - (length(p) - i) + 1) == substr(p, i + 1)) return 1 } return 0 } /^# Pattern-specific Variable Values/ { pat = 1 } /^# (Directories|Implicit Rules|Files)/ { pat = 0 } pat && /^[^#].* :$$/ { ph = $$0; sub(/ :$$/, "", ph) } /^# (makefile|\047override\047 directive|environment|environment under -e|command line|default|automatic)( \(from \047.*\047, line [0-9]+\))?$$/ { o = 1; f = ""; l = 0; if (match($$0, /\(from \047.*\047, line [0-9]+\)$$/)) { s = substr($$0, RSTART + 7, RLENGTH - 8); f = s; sub(/\047, line [0-9]+$$/, "", f); l = s; sub(/^.*\047, line /, "", l) } next } o && pat && /^# [A-Za-z_.][A-Za-z0-9_.]* (::?:?=|=|\+=|\?=|!=)/ { sc = ph; bad($$2, "pattern", f, l); o = 0; next } o && /^[^#\t ][^:]*: [A-Za-z_.][A-Za-z0-9_.]* (::?:?=|=|\+=|\?=|!=)/ { x = $$0; sc = x; sub(/:.*/, "", sc); sub(/^[^:]*: /, "", x); split(x, X, " "); bad(X[1], "target", f, l); o = 0; next } o && /^define [A-Za-z_]/ { bad($$2, "", f, l); o = 0; next } o && /^[A-Za-z_.][A-Za-z0-9_.]* (::?:?=|=|\+=|\?=|!=)/ { bad($$1, "", f, l); o = 0; next } { o = 0 }'); \
	[ -z "$$ib_bad" ] || { echo "REFUSING: make's own database (a clean evaluation with these goals) defines what the image block defines from outside the block: $${ib_bad%; }. The block's names are set inside it only."; exit 1; }; \
	$(require_registry); $(require_images)$(require_build_inputs)$(public_gate); $(require_scanner); $(gh_release_preflight); $(public_resume_gate)\
	$(call image_block_each,public_refuse,;); \
	$(call image_block_each,public_scan)\
	$(if $(IB_PUBLIC_RESUME),$(call image_block_each,public_match,;); )\
	$(call image_block_each,public_copy,;); \
	$(gh_release_publish); \
	echo "published "$(call sq,$(call image_block_each,public_said,$(IMAGE_BLOCK_COMMA)))", the same digest"$(ib_unchanged)
endif

# ── A tool mirror: a pinned upstream tool image, tagged by the UPSTREAM version ──────────────────
# v17: a repo that runs a third-party tool image (a browser-smoke runner FROM the upstream
# playwright image, plus the package that drives it) mirrors it into REGISTRY and pins it, so nothing
# pulls upstream at run time. Its immutable tag is the tool's version, not VERSION (it is rebuilt
# when the tool is bumped, never per release) and not a commit. v16 had no route for it: `IMAGES`
# gives every image `:$(VERSION)` and `:sha-<commit>`, and a hand-written publisher is red under
# repo.image_block_wired. A DECLARED mode, set above the block:
#   MIRROR_VERSION    := 1.48.0                 one literal, digits and dots: the tag, and the one
#                                               canonical home of the tool's version
#   MIRROR_IMAGE_NAME := luxardolabs/playwright
#   MIRROR_DOCKERFILE := Dockerfile.smoke       (default <context>/Dockerfile.mirror)
#   MIRROR_BUILD_CONTEXT := .                   (default .)   MIRROR_TARGET (default production)
# `make publish-mirror` refuses everything `publish-sha` refuses (a dirty tree, a registry from the
# shell, a value that is shell syntax, BUILD_ARGS outside its allowlist, a context or Dockerfile outside
# the commit), refuses a mirror tag already published (immutable: bump MIRROR_VERSION), builds from
# the commit with `--build-arg MIRROR_VERSION=<it>` (so the Dockerfile's `ARG MIRROR_VERSION` and the
# tag are one value), scans it, and only then pushes `$(REGISTRY)/<name>:<MIRROR_VERSION>`. A stack or
# a target pins MIRROR_IMAGE. `release` and `publish-sha` never touch it. It is built
# for this host's architecture (PLATFORMS is the app's).
MIRROR_VERSION       ?=
MIRROR_IMAGE_NAME    ?=
MIRROR_BUILD_CONTEXT ?= .
MIRROR_DOCKERFILE    ?= $(MIRROR_BUILD_CONTEXT)/Dockerfile.mirror
MIRROR_TARGET        ?= production
override MIRROR_IMAGE := $(REGISTRY)/$(MIRROR_IMAGE_NAME):$(MIRROR_VERSION)

override define require_mirror
$(if $(filter-out file override,$(origin MIRROR_VERSION)),echo "REFUSING: MIRROR_VERSION comes from the shell or the command line and not a makefile: declare it above the image block as one literal (MIRROR_VERSION := 1.48.0)"; exit 1; )\
printf '%s\n' $(call sq,$(MIRROR_VERSION)) | grep -Eqx '[0-9]+(\.[0-9]+)+' || { \
  echo "REFUSING: MIRROR_VERSION is the upstream tool's version as one literal of digits and dots (MIRROR_VERSION := 1.48.0), not '"$(call sq,$(MIRROR_VERSION))"'"; exit 1; }; \
[ -n $(call sq,$(strip $(MIRROR_IMAGE_NAME))) ] || { echo "REFUSING: set MIRROR_IMAGE_NAME above the image block (luxardolabs/<tool>)"; exit 1; }; \
case $(call sq,$(MIRROR_TARGET)) in ''|*[!A-Za-z0-9_.-]*) echo "REFUSING: MIRROR_TARGET is one stage name ([A-Za-z0-9_.-])"; exit 1 ;; esac; \
$(if $(filter $(strip $(MIRROR_IMAGE_NAME)),$(IMAGE_NAME) $(foreach i,$(IMAGE_LIST),$($(i)_IMAGE_NAME))),echo "REFUSING: MIRROR_IMAGE_NAME is an app image's name: a mirror is an image of its own"; exit 1; )\
$(if $(filter MIRROR,$(IMAGE_LIST)),echo "REFUSING: IMAGES lists MIRROR: that prefix is the tool mirror's settings"; exit 1; )\
[ $(call sq,$(MIRROR_IMAGE)) = $(call sq,$(REGISTRY)/$(MIRROR_IMAGE_NAME):$(MIRROR_VERSION)) ] || { \
  echo "REFUSING: the MIRROR_* settings are set BELOW the image block (or changed after it), so the mirror ref it computed is not theirs: set them above the block"; exit 1; }
endef

publish-mirror: ## Build + scan + PUSH the pinned tool mirror :$(MIRROR_VERSION) (the MIRROR_* settings above the block)
	@$(ib_run_snap)$(if $(and $(value sq),$(value sqw),$(value img_dockerfile)),,$(error REFUSING: the image block (v18) builds with the build core's quoting and image helpers (sq, sqw, img_*), which this makefile does not define. Paste `luxarch --emit build-core` directly above the image block))$(if $(value gh_release_publish),,$(error REFUSING: the image block (v24) publishes its GitHub Release with the gh-release block (gh_release_preflight, gh_release_publish), which this makefile does not define. Paste `luxarch --emit gh-release` directly below the image block))set -e; set -f; $(if $(filter-out default,$(origin MAKE_COMMAND)),echo "REFUSING: MAKE_COMMAND is set from outside the makefile"; exit 1; )$(if $(strip $(MAKEFILES)),echo "REFUSING: MAKEFILES is set so make read makefiles before this one that nobody committed or named: unset it"; exit 1; )$(if $(filter-out file,$(origin MAKEFILE_LIST)),echo "REFUSING: MAKEFILE_LIST is set from outside the makefile"; exit 1; )$(if $(filter-out default undefined,$(origin MAKECMDGOALS)),echo "REFUSING: MAKECMDGOALS is set from outside the makefile"; exit 1; )$(if $(filter command% environment%,$(origin SHELL) $(origin .SHELLFLAGS)),echo "REFUSING: SHELL or .SHELLFLAGS comes from the command line or the environment: the recipe would run in another shell"; exit 1; )$(if $(findstring x,$(filter-out --%,$(filter -%,$(.SHELLFLAGS)))),echo "REFUSING: .SHELLFLAGS traces the recipe (-x) and would print every value spliced into it"; exit 1; )\
	[ -z "$${BASH_ENV:-}$${ENV:-}" ] || { echo "REFUSING: BASH_ENV or ENV is set: a shell startup file ran before this recipe"; exit 1; }; case $$- in *x*) echo "REFUSING: the recipe shell traces its commands (-x) and would print every value spliced into it"; exit 1 ;; esac; \
	ib_dm=; for m in GNUmakefile makefile Makefile; do if [ -f "$$m" ]; then ib_dm=$$m; break; fi; done; \
	[ -n "$$ib_dm" ] && git ls-files --error-unmatch -- "$$ib_dm" >/dev/null 2>&1 || { \
	  echo "REFUSING: this directory's default makefile ($${ib_dm:-none}) is not tracked by git: what make reads first must be committed"; exit 1; }; \
	ib_ml='$(subst ','\'',$(MAKEFILE_LIST))'; set -- $$ib_ml; \
	[ "$$(cd "$$(dirname -- "$$1")" && pwd -P)/$$(basename -- "$$1")" = "$$(pwd -P)/$$ib_dm" ] || { \
	  echo "REFUSING: make read $$1 first and not this directory's default makefile ($$ib_dm): run make without -f"; exit 1; }; \
	ib_db=$$(env -i PATH="$$PATH" HOME="$$HOME" '$(subst ','\'',$(MAKE_COMMAND))' -pq -f "$$ib_dm" $(foreach g,$(MAKECMDGOALS),'$(subst ','\'',$(g))') 2>&1) || true; \
	printf '%s\n' "$$ib_db" | grep -q '^# Variables' && ! printf '%s\n' "$$ib_db" | grep -Eq '^([^ #][^:]*:[0-9]+|make[^:]*): [*][*][*] ' || { \
	  echo "REFUSING: the image block could not re-read this makefile in a clean environment (env -i, no command-line variables) with these goals. make said: $$(printf '%s\n' "$$ib_db" | grep -E '^([^ #][^:]*:[0-9]+|make[^:]*): [*][*][*] ' | head -n 3 | tr '\n' ' ')"; exit 1; }; \
	ib_cml=$$(printf '%s\n' "$$ib_db" | sed -n 's/^MAKEFILE_LIST :*= *//p' | head -n 1); \
	for ib_x in $$ib_ml; do case " $$ib_cml " in *" $$ib_x "*) ;; *) \
	  echo "REFUSING: make read $$ib_x and a clean evaluation of $$ib_dm does not (a second -f): run make with the default makefile only"; exit 1 ;; esac; done; \
	ib_rl=$$(printf '%s\n' "$$ib_db" | awk -v t='$(subst ','\'',$@)' 'in_t && /^#  recipe to execute \(from / { s = $$0; sub(/^#  recipe to execute \(from \047/, "", s); f = s; sub(/\047, line [0-9]+\):$$/, "", f); l = s; sub(/^.*\047, line /, "", l); sub(/\):$$/, "", l); print f "|" l; exit } /^[^#\t ][^:]*:/ { in_t = (substr($$0, 1, length(t) + 1) == t ":") }'); \
	ib_bf=$${ib_rl%|*}; ib_rn=$${ib_rl##*|}; \
	[ -n "$$ib_rl" ] && [ -f "$$ib_bf" ] || { echo "REFUSING: make's database does not say where the recipe of "'$(subst ','\'',$@)'" is, so nothing proves it is the image block's"; exit 1; }; \
	set -- $$(awk '/^# luxarch:image-block asset v[0-9]/ { m = NR; nm++ } /^# luxarch:image-block end/ { e = NR; ne++ } /^# luxarch:build-core asset v[0-9]/ { cm = NR; ncm++ } /^# luxarch:build-core end/ { ce = NR; nce++ } /^# luxarch:gh-release asset v[0-9]/ { gm = NR; ngm++ } /^# luxarch:gh-release end/ { ge = NR; nge++ } END { if (nm != 1 || ne != 1) { m = 0; e = 0 } if (ncm != 1 || nce != 1) { cm = 0; ce = 0 } if (ngm != 1 || nge != 1) { gm = 0; ge = 0 } print m + 0 " " e + 0 " " cm + 0 " " ce + 0 " " gm + 0 " " ge + 0 }' "$$ib_bf"); ib_m=$${1:-0}; ib_e=$${2:-0}; ib_cm=$${3:-0}; ib_ce=$${4:-0}; ib_gm=$${5:-0}; ib_ge=$${6:-0}; \
	ib_lo=$$ib_m; ib_hi=$$ib_e; [ '$(subst ','\'',$@)' != gh-release ] || { ib_lo=$$ib_gm; ib_hi=$$ib_ge; }; [ "$$ib_m" -gt 0 ] && [ "$$ib_e" -gt "$$ib_m" ] && [ "$$ib_rn" -gt "$$ib_lo" ] && [ "$$ib_rn" -lt "$$ib_hi" ] || { \
	  echo "REFUSING: the recipe of "'$(subst ','\'',$@)'" make runs is $$ib_bf:$$ib_rn, which is not inside the block that ships it (gh-release: the gh-release block; every other target: the image block): a redefinition of the target replaced it"; exit 1; }; \
	[ "$$ib_cm" -gt 0 ] && [ "$$ib_ce" -gt "$$ib_cm" ] && [ "$$ib_ce" -lt "$$ib_m" ] || { \
	  echo "REFUSING: $$ib_bf has no build core directly above the image block (exactly one core marker and one core end marker in the file, both before the block's): the block's quoting and image names are the core's, and its guard checks them there. Paste luxarch --emit build-core above the block"; exit 1; }; \
	[ "$$ib_gm" -gt "$$ib_e" ] && [ "$$ib_ge" -gt "$$ib_gm" ] || { \
	  echo "REFUSING: $$ib_bf has no gh-release block below the image block (exactly one gh-release marker and one gh-release end marker in the file, both after the block's end): the release publishes its GitHub Release with it, and the guard checks its lines as the block's. Paste luxarch --emit gh-release below the block"; exit 1; }; \
	ib_nm=$$(awk -v m="$$ib_m" -v e="$$ib_e" -v cm="$$ib_cm" -v ce="$$ib_ce" -v gm="$$ib_gm" -v ge="$$ib_ge" '(NR >= m && NR <= e || NR >= cm && NR <= ce || NR >= gm && NR <= ge) && /^override / { s = $$0; sub(/^override +(define +)?/, "", s); sub(/[ \t:=+!?].*/, "", s); printf " %s", s } END { print " " }' "$$ib_bf"); \
	ib_bad=$$(printf '%s\n' "$$ib_db" | awk -v F="$$ib_bf" -v m="$$ib_m" -v e="$$ib_e" -v cm="$$ib_cm" -v ce="$$ib_ce" -v gm="$$ib_gm" -v ge="$$ib_ge" -v names="$$ib_nm" -v tg='$(subst ','\'',release publish-sha release-public publish-mirror dev-deploy dev-pin gh-release $@ $(MAKECMDGOALS))' 'function bad(n, w, f, l) { if (index(names, " " n " ") && (w != "" || f != F || (l + 0 < m || l + 0 > e) && (l + 0 < cm || l + 0 > ce) && (l + 0 < gm || l + 0 > ge))) printf "%s%s at %s:%s; ", n, (w != "" ? " (" w "-specific)" : ""), f, l; else if (w != "" && index(" REGISTRY RELEASE_REGISTRY PUBLIC_REGISTRY PRIVATE_REGISTRY LUXAUDIT_IMAGE LUXAUDIT IMAGE_NAME PLATFORMS ", " " n " ") && reaches(sc)) printf "%s (%s-specific, %s) at %s:%s; ", n, w, sc, f, l } function reaches(p,   i, k, T, a, b) { k = split(tg, T, " "); i = index(p, "%"); for (a = 1; a <= k; a++) { if (i == 0 && T[a] == p) return 1; if (i > 0 && index(T[a], substr(p, 1, i - 1)) == 1 && length(T[a]) >= length(p) - 1 && substr(T[a], length(T[a]) - (length(p) - i) + 1) == substr(p, i + 1)) return 1 } return 0 } /^# Pattern-specific Variable Values/ { pat = 1 } /^# (Directories|Implicit Rules|Files)/ { pat = 0 } pat && /^[^#].* :$$/ { ph = $$0; sub(/ :$$/, "", ph) } /^# (makefile|\047override\047 directive|environment|environment under -e|command line|default|automatic)( \(from \047.*\047, line [0-9]+\))?$$/ { o = 1; f = ""; l = 0; if (match($$0, /\(from \047.*\047, line [0-9]+\)$$/)) { s = substr($$0, RSTART + 7, RLENGTH - 8); f = s; sub(/\047, line [0-9]+$$/, "", f); l = s; sub(/^.*\047, line /, "", l) } next } o && pat && /^# [A-Za-z_.][A-Za-z0-9_.]* (::?:?=|=|\+=|\?=|!=)/ { sc = ph; bad($$2, "pattern", f, l); o = 0; next } o && /^[^#\t ][^:]*: [A-Za-z_.][A-Za-z0-9_.]* (::?:?=|=|\+=|\?=|!=)/ { x = $$0; sc = x; sub(/:.*/, "", sc); sub(/^[^:]*: /, "", x); split(x, X, " "); bad(X[1], "target", f, l); o = 0; next } o && /^define [A-Za-z_]/ { bad($$2, "", f, l); o = 0; next } o && /^[A-Za-z_.][A-Za-z0-9_.]* (::?:?=|=|\+=|\?=|!=)/ { bad($$1, "", f, l); o = 0; next } { o = 0 }'); \
	[ -z "$$ib_bad" ] || { echo "REFUSING: make's own database (a clean evaluation with these goals) defines what the image block defines from outside the block: $${ib_bad%; }. The block's names are set inside it only."; exit 1; }; \
	$(require_mirror); $(require_registry); $(require_images)$(require_build_inputs)$(refuse_dirty_tree); $(require_scanner); \
	$(call refuse_published,$(MIRROR_IMAGE),A mirror tag is immutable: bump MIRROR_VERSION to mirror another upstream version.); \
	$(export_tree); \
	$(call export_contained,MIRROR); \
	$(export_build_args); \
	docker build --load --target $(call sq,$(call img_target,MIRROR)) $(call sqw,$(BUILD_ARGS)) --build-arg $(call sq,MIRROR_VERSION=$(MIRROR_VERSION)) -f $(call sq,$(call img_dockerfile,MIRROR)) -t $(call sq,$(MIRROR_IMAGE)) $(call sq,$(call img_context,MIRROR)); \
	$(call scan_candidate,$(MIRROR_IMAGE)); \
	docker push $(call sq,$(MIRROR_IMAGE)); \
	$(export_leave); \
	echo "mirrored "$(call sq,$(MIRROR_IMAGE))": pin it as MIRROR_IMAGE"$(ib_unchanged)

# ── Point an environment at a build ─────────────────────────────────────────────────────────────
# Immutable tags move a burden: a NEW tag per build has to actually reach the stack. This block used
# to end by telling a human to go hand-edit a gitignored file — advice beside a working button, and
# it is how a dev node ends up still serving last week's sha while everyone believes otherwise.
#
# The tag is PERSISTED into .env.<env>, not passed in the deploying shell, because the stack has to
# come back after a reboot: compose reads `${TAG:?}`, so a tag that lived only in one shell leaves a
# plain `docker compose up` on that node unable to start the stack at all. Exactly ONE line of that
# file is rewritten in place; nothing else is read, printed or reordered, because it holds secrets.
#
# `.env.prod` takes the same call from whatever `prod-deploy` does over SSH — the pinning is shared,
# the transport is node-specific and stays in the repo.

TAG ?= sha-$(COMMIT)

# Which compose profiles the dev stack runs. v8: v7 restarted with a bare `up -d`, and in a compose.yml
# where every service carries `profiles:` (the fleet's one-file model) that selects NO service unless
# something declares the stack: compose exits 0 and `dev-deploy` reported success over a stack it never
# restarted. Declare it ONE of two ways (`repo.compose_up_selects_services` checks either):
#   - COMPOSE_PROFILES=<profiles> in .env.dev, declared in the committed .env.example (leave this empty);
#   - or set the profiles above this block: `DEV_PROFILES := dev`. A `--profile` REPLACES the
#     env file's COMPOSE_PROFILES, so list every profile the dev stack needs.
# A service with no `profiles:` starts either way.
DEV_PROFILES ?=

# v17: the env file the dev stack runs with, and the one `dev-pin` writes `TAG=` into. v16 hardcoded
# `.env.dev`, so a repo running a second dev stack (its own profile, env file and credentials) could
# not deploy or roll it back through the block. One stack needs nothing; another deploys with
#   make dev-deploy DEV_ENV_FILE=.env.dev-b DEV_PROFILES=dev-b SMOKE_CONTAINERS=<its containers>
# (`dev-deploy`'s sub-makes inherit the command line, and smoke reads the same file by default).
DEV_ENV_FILE ?= .env.dev

# v12: `dev-pin` waits for the stack: running, and healthy where a service has a healthcheck. v11 returned when the
# containers STARTED, so `smoke` hit the proxy before the app listened: every first probe was a 502, and
# the forged-Host probe "passed" because nothing answered at all. Seconds to wait before failing the deploy:
DEV_WAIT_TIMEOUT ?= 120

# v23: the compose services recreated when their bind-mounted config changed (dev_recreate below).
DEV_RECREATE ?=

# v19: where the dev stack runs. `compose` (the default) is the stack above: `dev-pin` writes `TAG=` into
# DEV_ENV_FILE and restarts compose. `kustomize` is a Kubernetes dev cluster (FLEET-BUILD-DEPLOY-STANDARD,
# "Kubernetes (kustomize)"): the dev overlay DEV_OVERLAY pins each image the block publishes as
# `newTag: __TAG__`, and `dev-pin`, after the same checks, renders it AS COMMITTED (`git archive
# HEAD`, then `kubectl kustomize`), requires every `image:` naming one of those images to be exactly
# `:__TAG__`, substitutes TAG into the rendered copy (the tracked overlay is never written, so the
# next build's tree stays clean), refuses any `__X__` placeholder still left, applies it, and waits on
# each workload it applied, in its namespace (rollout, a Job's completion, a Pod's readiness). v18 had no such lane, so a k3s-deployed repo could not adopt the
# block at all.
# v20: DEV_PRE_OVERLAYS are committed kustomizations applied, in order, before DEV_OVERLAY: what must
# exist or finish before the app rolls out (a Secret, the migration Job, cluster-scoped config). Each
# is rendered from HEAD with the same checks (an image the block publishes runs only at `:__TAG__`; no
# `__X__` placeholder left), every overlay renders and passes them before any is applied, and each is
# applied and waited on before the next: a Job that does not complete prints its logs and stops the
# deploy before the app's rollout. DEV_KUSTOMIZE renders on this machine; DEV_KUBECTL talks to the
# cluster and reads every manifest on its stdin, so it can be a kubectl on another host
# (`DEV_KUBECTL := ssh <node> kubectl`), or a local one with `--context <ctx>`.
# v21: `DEV_DEPLOY := none` declares that this makefile deploys no dev stack: it publishes a tool
# mirror only (`publish-mirror`), as a makefile for an embedded toolchain does. `dev-deploy` and
# `dev-pin` then refuse and run nothing, so there is no deploy to probe (`repo.stack_smoke_wired`) and
# no `compose up` to judge (`repo.compose_up_selects_services`).
DEV_DEPLOY ?= compose
override IB_NO_STACK := DEV_DEPLOY is none: this makefile deploys no dev stack (it publishes a tool mirror only: make publish-mirror)
DEV_OVERLAY ?= k8s/overlays/dev
DEV_PRE_OVERLAYS ?=
# v21: the overlays applied SERVER-SIDE, under DEV_FIELD_MANAGER as the owner of their fields
# (`apply --server-side --field-manager=<it> --force-conflicts`): cluster-scoped config another
# controller also writes (a k3s HelmChartConfig in kube-system, a storage operator's CRs), which the
# repo takes over and records itself as owning. Each must be one of DEV_PRE_OVERLAYS or DEV_OVERLAY;
# every other overlay is applied client-side, as before.
DEV_SERVER_SIDE ?=
DEV_FIELD_MANAGER ?=
DEV_KUSTOMIZE ?= kubectl kustomize
DEV_KUBECTL ?= kubectl

# The compose dev stack's Docker host: exactly one `DEV_HOST := <host>` line in the committed
# Makefile, an ssh alias every coding machine resolves (`DEV_HOST := devhost`), or `local`. `dev-pin`
# and `smoke` reach it as `DOCKER_HOST=ssh://<DEV_HOST>` (`private`: dev-pin's prerequisites and
# `publish-sha` stay on this machine). Before anything is written, dev-pin refuses unless its value
# is that committed line (HEAD) exactly, and the dev host reads this checkout at the same path (a
# probe file and the env file, compared by checksum over ssh). The stack publishes no host port
# (`repo.dev_host_declared`). A DEV_HOST from the shell is ignored; `local` is this shell's docker.
DEV_HOST ?=
override IB_DEV_HOST = $(if $(filter file override,$(origin DEV_HOST)),$(strip $(DEV_HOST)))
override IB_AMBIENT_DOCKER_HOST := $(DOCKER_HOST)
dev-pin smoke: private export DOCKER_HOST = $(if $(filter-out local,$(IB_DEV_HOST)),ssh://$(IB_DEV_HOST),$(IB_AMBIENT_DOCKER_HOST))

# v15: a file with more than one `TAG=` line refuses. v14 rewrote the first, and compose reads the
# LAST, so the stack stayed on the old version under a pin that reported success.
# v14: one awk pass writes the file, and the rewrite is refused unless every line but `TAG=` is
# byte-for-byte what it was. v13 appended with `printf >>` after a `cp`, so a file whose last line had
# no newline came out as `SECRET_KEY=abcTAG=sha-…`: a corrupted secret and no TAG, past a line-count
# check the extra newline satisfied. awk ends every line it prints.
# v17: the pin is judged by what COMPOSE resolves from the rewritten file, before it is written. v16
# checked only that the text `TAG=<t>` landed, and compose reads the file another way: an
# `export TAG=` line (compose ignores the `export`) was not seen, so a second `TAG=` was appended
# below it; a `TAG=` BELOW a line that builds the image from `${TAG}` (`APP_IMAGE=…:${TAG}`) leaves
# that line empty; and with no `TAG=` line the appended one lands below every use. Each reported
# success while a reboot, or a plain `docker compose up`, ran the old tag or an invalid `…:` ref (the
# deploy itself looked fine: the deploying shell had TAG exported). Now `export TAG=` and `TAG = …`
# are TAG lines, rewritten in place as `TAG=<t>`, and the rewritten copy is handed to `config
# --images` in an EMPTY environment (PATH, HOME and docker's own DOCKER_HOST / DOCKER_CONFIG /
# DOCKER_CONTEXT only), because a reboot has no shell: make exports every command-line variable, so
# `make dev-pin TAG=… REGISTRY=…` would otherwise resolve a `${REGISTRY}` the file does not hold.
# Nothing is written unless, of the images resolved, every one in a checked repository runs `:<t>`
# (a second service pinned by `${WORKER_TAG:-sha-old}` would run old bytes beside new) and at least
# one does. A checked image the stack does not run at all (a profile this stack leaves out) is fine.
# The stack is judged BY RESOLUTION: compose resolves the whole model (`config`) twice from the
# rewritten file, once in this deploy's own environment (what `up` runs now) and once as a reboot
# would (an empty environment: PATH, HOME and docker's own variables), and the two must be the SAME,
# byte for byte, but for `x-*` extension keys (at the top level, and directly under a service,
# network, volume, secret or config definition, where compose treats them as extensions; their
# anchored content shows where it is used) and a service's `build:` section (the image is built
# already, so a build argument cannot change what a reboot runs), unless that service's
# `pull_policy` is `build`: then `up` rebuilds, and its build arguments are compared too. A stated
# limit: with `pull_policy: missing` and the image absent locally while the registry is unreachable,
# `up` falls back to building, and those build arguments are not compared.
# Order counts: swapped `ports:` or reversed `command:` items differ. A difference refuses the pin,
# and the refusal prints nothing taken from the resolved model or from compose's messages (both carry
# values): only the NAMES of variables this deploy sets non-empty that the file does not, from
# `config --variables`, the file, and the pass-through `environment:` entries. A top-level secret or
# config read from the `environment:` resolves to its variable's name in the model, so compose is
# asked for those variables themselves, through a probe file holding one inert service
# (`profiles: [never]`, its own project name, so no `up` and no `--images` ever sees it): each must
# resolve non-empty after a reboot and the same as now. The verdict is the whole probe output, byte for
# byte (a PEM's later lines, a long value compose folds over several lines, all count); the variables
# are then compared one whole value at a time only to name the ones that differ. A name
# compose cannot interpolate (`MY.SECRET`, `1PW`) refuses: rename it to a plain identifier. When a resolution fails the refusal says which, and how to see why.
# prod-deploy judges only the node's own model: the node has no deploying shell.
#   $(1) the env file  $(2) the tag  $(3) the compose command, without --env-file (default
#   `docker compose`)  $(4) the image REPOSITORIES the pin checked, no tag (default: any image at `:<t>`)
#   $(5) optional: the directory standing in for the node, where the rewritten file is also written as
#   `.env`, because that is where the node holds it (a service's `env_file: .env` reads it there)
override define pin_env_tag
umask 077; f=$(call sq,$(1)); t=$(call sq,$(2)); \
[ -f "$$f" ] || { echo "$$f is missing — copy .env.example and fill it in first"; exit 1; }; \
n=$$(grep -cE '^[[:space:]]*(export[[:space:]]+)?TAG[[:space:]]*=' "$$f" || true); \
[ "$$n" -le 1 ] || { echo "refusing: $$f has more than one TAG= line ($$n; a line of a multi-line quoted value that starts with TAG= counts too), and compose reads the last: keep one (nothing written)"; exit 1; }; \
tmp=$$(mktemp); trap 'trap "" HUP INT TERM; rm -f "$$tmp" "$$tmp.err" "$$tmp.now" "$$tmp.boot" "$$tmp.a" "$$tmp.b" "$$tmp.probe.yml" "$$tmp.pb" "$$tmp.pn" "$$tmp.vb" "$$tmp.vn"; [ -z "$${pindir:-}" ] || rm -rf "$$pindir"; [ -z "$${rf:-}" ] || rm -f "$$rf"' EXIT; trap 'trap "" HUP INT TERM; exit 1' HUP INT TERM; \
awk -v t="$$t" '/^[[:space:]]*(export[[:space:]]+)?TAG[[:space:]]*=/ && !d {print "TAG=" t; d=1; next} {print} END {if (!d) print "TAG=" t}' "$$f" > "$$tmp"; \
[ -s "$$tmp" ] || { echo "refusing to write an empty $$f"; exit 1; }; \
[ "$$(grep -vE '^[[:space:]]*(export[[:space:]]+)?TAG[[:space:]]*=' "$$f")" = "$$(grep -vE '^[[:space:]]*(export[[:space:]]+)?TAG[[:space:]]*=' "$$tmp")" ] || \
  { echo "refusing: rewriting $$f would change a line other than TAG= (nothing written)"; exit 1; }; \
grep -qxF "TAG=$$t" "$$tmp" || { echo "refusing: TAG=$$t did not land on a line of its own in $$f"; exit 1; }; \
pin_resolve() { env -i PATH="$$PATH" HOME="$$HOME" $${DOCKER_HOST:+DOCKER_HOST="$$DOCKER_HOST"} $${DOCKER_CONFIG:+DOCKER_CONFIG="$$DOCKER_CONFIG"} $${DOCKER_CONTEXT:+DOCKER_CONTEXT="$$DOCKER_CONTEXT"} \
  docker compose $${nd:+-f "$$nd/compose.yml"} $(call sqw,$(3)) --env-file "$$tmp" config "$$@"; }; \
$(if $(strip $(5)),nd=$$pindir; cat "$$tmp" > "$$nd/.env",nd=); \
pin_unset_names() { sed -n -e 's/.*required variable \([A-Za-z_][A-Za-z0-9_]*\) is missing.*/\1/p' -e 's/.*The \\*"\([A-Za-z_][A-Za-z0-9_]*\)\\*" variable is not set.*/\1/p' "$$tmp.err" | sort -u; }; \
pin_unset() { \
  u=$$(pin_unset_names | tr '\n' ' '); \
  [ -z "$$u" ] || echo "Not set by $$f: $${u% }. A reboot resolves the stack from $$f alone, so a variable the Makefile exports or your shell sets is not there: define it in $$f (and a placeholder in .env.example)."; }; \
imgs=$$(pin_resolve --images 2>"$$tmp.err") || { \
  echo "refusing: $(if $(strip $(5)),the node's,the reboot's) resolution failed: compose cannot resolve the stack from $$f with TAG=$$t and nothing else (no shell variables; for prod-deploy, only what the node holds: compose.yml and this file as .env) (nothing written). Run: env -i PATH=\"\$$PATH\" HOME=\"\$$HOME\" docker compose $(if $(strip $(5)),-f compose.yml )--env-file "$$f" config, to see why (the reboot's environment; not printed here: compose's messages carry values)."; \
  pin_unset; exit 1; }; \
want=$(call sq,$(strip $(4))); \
if [ -n "$$want" ]; then \
  why=$$(printf '%s\n' "$$imgs" | awk -v repos="$$want" -v t="$$t" 'BEGIN { n = split(repos, R, " ") } { ref = $$0; dig = index(ref, "@"); if (dig) ref = substr(ref, 1, dig - 1); last = ref; sub(/.*\//, "", last); j = index(last, ":"); repo = ref; tag = ""; if (j) { tag = substr(last, j + 1); repo = substr(ref, 1, length(ref) - length(last) + j - 1) } for (k = 1; k <= n; k++) if (repo == R[k]) { seen = 1; if (dig || tag != t) { bad = bad " " $$0; if (!dig && tag == "") empty = 1 } } } END { if (!seen) { print "none"; exit 1 } if (bad != "") { print (empty ? "empty" : "other") bad; exit 1 } }') || true; \
else \
  why=; printf '%s\n' "$$imgs" | awk -v s=":$$t" 'length($$0) > length(s) && substr($$0, length($$0) - length(s) + 1) == s {f=1} END {exit !f}' || why=none; \
fi; \
if [ -n "$$why" ]; then \
  case "$$why" in \
    none) echo "refusing: with TAG=$$t in $$f, compose runs no image of $${want:-any repository} at :$$t (nothing written). It resolves:" ;; \
    *) echo "refusing: with TAG=$$t in $$f, compose would run $${why#* } (nothing written). It resolves:" ;; \
  esac; \
  printf '%s\n' "$$imgs" | sed 's/^/    /'; \
  case "$$why" in \
    empty*) echo "An image's tag is empty: a TAG= line must come before any line in $$f that uses \$${TAG}." ;; \
    other*) echo "Every service that runs a pinned image must take its tag from TAG (not a default or another variable)." ;; \
    *) echo "Name the pinned image with \$${TAG}, in compose.yml or above it in $$f, and set nothing it needs only in your shell." ;; \
  esac; pin_unset; exit 1; \
fi; \
pin_resolve > "$$tmp.boot" 2>/dev/null || { \
  echo "refusing: $(if $(strip $(5)),the node's,the reboot's) resolution failed: compose cannot resolve the stack from $$f, from the file alone (nothing written). Run: env -i PATH=\"\$$PATH\" HOME=\"\$$HOME\" docker compose $(if $(strip $(5)),-f compose.yml )--env-file "$$f" config, to see why (the reboot's environment; not printed here: compose's messages carry values)."; exit 1; }; \
need=$$(awk '/^(secrets|configs):/ { top = 1; next } /^[^ ]/ { top = 0 } top && /^    environment: / { v = substr($$0, 18); gsub(/^["\047]|["\047]$$/, "", v); print v }' "$$tmp.boot" | sort -u); \
odd=$$(printf '%s\n' "$$need" | grep -vxE '[A-Za-z_][A-Za-z0-9_]*' | grep -v '^$$' | tr '\n' ' ' || true); \
[ -z "$$odd" ] || { \
  echo "refusing: compose.yml's secrets or configs read the environment variable(s) $${odd% }, which compose cannot interpolate, so the image block cannot prove they resolve after a reboot (nothing written). Rename each to a plain identifier ([A-Za-z_][A-Za-z0-9_]*)."; exit 1; }; \
if [ -n "$$need" ]; then \
  { echo 'services:'; echo '  luxarch-pin-probe:'; echo '    image: scratch'; echo '    profiles: [never]'; echo '    environment:'; \
    i=0; for v in $$need; do printf '      PIN_%s: $${%s}\n' "$$i" "$$v"; i=$$((i + 1)); done; } > "$$tmp.probe.yml"; \
  pin_probe() { docker compose -p luxarch-pin-probe -f "$$tmp.probe.yml" --profile never --env-file "$$tmp" config; }; \
  pin_values() { awk '/^      PIN_[0-9]+:/ { k = $$1; sub(/:$$/, "", k); v = $$0; sub(/^[^:]*:[ ]?/, "", v); V[k] = v; cur = k; next } cur != "" && /^       / { V[cur] = V[cur] "\034" $$0; next } { cur = "" } END { for (k in V) print k "\t" V[k] }' "$$1" | sort; }; \
  pin_name() { i=0; for v in $$need; do [ "PIN_$$i" = "$$1" ] && printf '%s ' "$$v"; i=$$((i + 1)); done; }; \
  env -i PATH="$$PATH" HOME="$$HOME" $${DOCKER_HOST:+DOCKER_HOST="$$DOCKER_HOST"} $${DOCKER_CONFIG:+DOCKER_CONFIG="$$DOCKER_CONFIG"} $${DOCKER_CONTEXT:+DOCKER_CONTEXT="$$DOCKER_CONTEXT"} \
    docker compose -p luxarch-pin-probe -f "$$tmp.probe.yml" --profile never --env-file "$$tmp" config > "$$tmp.pb" 2>/dev/null || { \
    echo "refusing: $(if $(strip $(5)),the node's,the reboot's) resolution of the variables compose.yml's secrets and configs read failed (nothing written). Run: env -i PATH=\"\$$PATH\" HOME=\"\$$HOME\" docker compose $(if $(strip $(5)),-f compose.yml )--env-file "$$f" config, to see why (the reboot's environment; not printed here: compose's messages carry values)."; exit 1; }; \
  pin_values "$$tmp.pb" > "$$tmp.vb"; \
  empty=; for k in $$(awk -F '\t' '$$2 == "" || $$2 == "\"\"" || $$2 == "null" { print $$1 }' "$$tmp.vb"); do empty="$$empty$$(pin_name "$$k")"; done; \
  [ -z "$$empty" ] || { \
    echo "refusing: compose.yml's secrets or configs read $${empty% } from the environment, and after a reboot compose resolves them empty from $$f, so the stack cannot start (nothing written). Define them in $$f."; exit 1; }; \
  if [ -z "$$nd" ]; then \
    pin_probe > "$$tmp.pn" 2>/dev/null || { \
      echo "refusing: this deploy's resolution of the variables compose.yml's secrets and configs read failed (nothing written). Run: docker compose --env-file "$$f" config, to see why (not printed here: compose's messages carry values)."; exit 1; }; \
    pin_values "$$tmp.pn" > "$$tmp.vn"; \
    diffn=; if ! cmp -s "$$tmp.pn" "$$tmp.pb"; then \
      for k in $$(comm -3 "$$tmp.vn" "$$tmp.vb" | awk -F '\t' '{ print ($$1 == "" ? $$2 : $$1) }' | grep -E '^PIN_[0-9]+$$' | sort -u); do diffn="$$diffn$$(pin_name "$$k")"; done; \
      [ -n "$$diffn" ] || diffn="$$(echo $$need) "; \
    fi; \
    [ -z "$$diffn" ] || { \
      echo "refusing: with TAG=$$t in $$f, the secret or config variable(s) $${diffn% } resolve differently after a reboot, from $$f alone (nothing written). Set each in $$f to the value this deploy uses."; exit 1; }; \
  fi; \
fi; \
if [ -z "$$nd" ]; then \
  docker compose $(call sqw,$(3)) --env-file "$$tmp" config > "$$tmp.now" 2>/dev/null || { \
    echo "refusing: this deploy's resolution failed: compose cannot resolve the stack from $$f in this deploy's own environment (nothing written). Run: docker compose --env-file "$$f" config, to see why (not printed here: compose's messages carry values)."; exit 1; }; \
  pin_strip() { awk 'function ind(l) { return match(l, /[^ ]/) ? RSTART - 1 : length(l) } NR == FNR { i = ind($$0); if (i == 0) top = $$0; else if (i == 2) def = $$0; else if (i == 4 && top == "services:" && $$0 == "    pull_policy: build") keep[def] = 1; next } { i = ind($$0); if (skip && i > sind) next; skip = 0; if (i == 0) top = $$0; if (i == 2) def = $$0; line = substr($$0, i + 1); if ((i == 0 && line ~ /^x-/) || (i == 4 && top ~ /^(services|networks|volumes|secrets|configs):$$/ && line ~ /^x-/) || (i == 4 && top == "services:" && line ~ /^build:/ && !keep[def])) { skip = 1; sind = i; next } print }' "$$1" "$$1"; }; \
  pin_strip "$$tmp.now" > "$$tmp.a"; pin_strip "$$tmp.boot" > "$$tmp.b"; \
  if ! cmp -s "$$tmp.a" "$$tmp.b"; then \
    names=$$( { pin_resolve --variables 2>/dev/null | awk 'NR > 1 { print $$1 }'; \
      awk '/^    environment:$$/ { e = 1; next } e && /^      [A-Za-z_][A-Za-z0-9_]*:/ { k = $$1; sub(/:$$/, "", k); print k; next } { e = 0 }' "$$tmp.boot"; grep -oE '\$$\{?[A-Za-z_][A-Za-z0-9_]*' "$$tmp" | sed 's/^\$$[{]*//'; } | sort -u | \
      while read -r v; do if [ -n "$$(printenv "$$v")" ] && ! grep -qE "^[[:space:]]*(export[[:space:]]+)?$$v[[:space:]]*=" "$$tmp"; then printf '%s ' "$$v"; fi; done); \
    rm -f "$$tmp.now" "$$tmp.boot" "$$tmp.a" "$$tmp.b"; \
    echo "refusing: with TAG=$$t in $$f, the resolved stack differs after a reboot (nothing written)."; \
    if [ -n "$$names" ]; then echo "Set by this deploy and not by $$f: $${names% }."; fi; \
    echo "A variable this deploy sets (a Makefile export, your shell) that $$f does not, or sets differently, changes the stack at the next reboot: define it in $$f (and a placeholder in .env.example)."; exit 1; \
  fi; \
fi; \
rm -f "$$tmp.now" "$$tmp.boot" "$$tmp.a" "$$tmp.b" "$$tmp.probe.yml" "$$tmp.pb" "$$tmp.pn" "$$tmp.vb" "$$tmp.vn"; \
rm -f "$$tmp.err"; cat "$$tmp" > "$$f"; \
echo "$$f: TAG=$$t"
endef

# v22: `dev-deploy` and `dev-pin` run from the main checkout. compose takes a bind mount's source from
# the directory it runs in, so a stack deployed from a linked worktree (an agent's
# `<repo parent>/.worktrees/<repo>/<KEY>`) mounts that worktree's files and `dev-pin` writes `TAG=` into its copy of
# the env file; landing the worktree then removes them under the running stack. Deploy from the main
# checkout, after landing. `DEV_DEPLOY_FROM_WORKTREE=1` on the command line or in the environment
# deploys from a worktree anyway; set in a makefile, or to anything but `1`, it refuses. git is asked
# with the variables that point it at a repository (GIT_DIR, GIT_WORK_TREE, …) unset, so one set
# elsewhere cannot make a worktree read as the main checkout, and so is each superproject this
# checkout is a submodule of: a submodule checked out inside a linked worktree is in that worktree.
# A makefile is trusted code: a recipe of its own that runs
# `$(MAKE) dev-pin DEV_DEPLOY_FROM_WORKTREE=1` passes the value as a command line.
override define require_main_checkout
case $(call sq,$(origin DEV_DEPLOY_FROM_WORKTREE)) in \
  undefined) \
    ib_git() { env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES -u GIT_NAMESPACE -u GIT_CEILING_DIRECTORIES git "$$@"; }; \
    ib_wd=$(call sq,$(CURDIR)); ib_n=0; \
    while :; do \
      ib_top=$$(cd "$$ib_wd" && ib_git rev-parse --show-toplevel 2>/dev/null) && \
      ib_gd=$$(cd "$$ib_top" && ib_git rev-parse --git-dir 2>/dev/null) && ib_gc=$$(cd "$$ib_top" && ib_git rev-parse --git-common-dir 2>/dev/null) && \
      ib_gd=$$(cd "$$ib_top" && cd "$$ib_gd" && pwd -P) && ib_gc=$$(cd "$$ib_top" && cd "$$ib_gc" && pwd -P) || { \
        echo "REFUSING: git cannot say whether "$(call sq,$(CURDIR))" is the main checkout or a linked worktree, so nothing shows what the dev stack would mount"; exit 1; }; \
      [ "$$ib_gd" = "$$ib_gc" ] || { \
        echo "REFUSING: "$(call sq,$(CURDIR))" is in a linked worktree ($$ib_top, git dir $$ib_gd), not the main checkout: a stack deployed from here mounts this worktree's files, and landing it removes them under the running stack. Land, then deploy from the main checkout ($${ib_gc%/.git}). To deploy from here anyway: DEV_DEPLOY_FROM_WORKTREE=1 on the command line"; exit 1; }; \
      ib_sp=$$(cd "$$ib_top" && ib_git rev-parse --show-superproject-working-tree 2>/dev/null) || ib_sp=; \
      ib_n=$$((ib_n + 1)); [ -n "$$ib_sp" ] && [ "$$ib_n" -lt 16 ] || break; ib_wd=$$ib_sp; \
    done ;; \
  'command line'|environment) \
    [ $(call sq,$(value DEV_DEPLOY_FROM_WORKTREE)) = 1 ] || { \
      echo "REFUSING: DEV_DEPLOY_FROM_WORKTREE="$(call sq,$(value DEV_DEPLOY_FROM_WORKTREE))" is not 1, the one value that deploys from a linked worktree"; exit 1; } ;; \
  *) echo "REFUSING: DEV_DEPLOY_FROM_WORKTREE is set in a makefile ("$(call sq,$(origin DEV_DEPLOY_FROM_WORKTREE))"): deploying from a linked worktree is a choice for one run, on the command line, never a setting"; exit 1 ;; \
esac
endef

# v10: a deploy ends by probing what it deployed (`luxarch --emit smoke`, pasted below this block). A
# deploy that restarted the stack is not one that works: the suite runs in-process and cannot see the
# proxy, the server, the production image or a standalone entry point.
# Before it builds or pushes anything, dev-deploy makes dev-pin's dev-host checks in its own recipe, in a
# subshell: what they export never reaches the build, even under .ONESHELL.
dev-deploy: ## Build+push THIS commit (:sha-…, never the version), pin $(DEV_ENV_FILE) to it, restart the dev stack, smoke it
	@$(if $(filter none,$(DEV_DEPLOY)),:,$(require_main_checkout))
	@$(if $(filter compose,$(DEV_DEPLOY)),( set -e; set -f; $(if $(filter-out local,$(IB_DEV_HOST)),DOCKER_HOST=ssh://$(call sq,$(IB_DEV_HOST)); export DOCKER_HOST; )ib_dm=; for m in GNUmakefile makefile Makefile; do if [ -f "$$m" ]; then ib_dm=$$m; break; fi; done; [ -n "$$ib_dm" ] || { echo "REFUSING: this directory has no default makefile"; exit 1; }; $(require_dev_env_file); $(require_dev_host); $(dev_host_same_files) ) || exit 1,:)
	@$(if $(and $(value sq),$(value sqw),$(value img_dockerfile)),,$(error REFUSING: the image block (v18) builds with the build core's quoting and image helpers (sq, sqw, img_*), which this makefile does not define. Paste `luxarch --emit build-core` directly above the image block))$(if $(filter none,$(DEV_DEPLOY)),echo "REFUSING: "$(call sq,$(IB_NO_STACK)); exit 1,$(MAKE) --no-print-directory publish-sha)
	@$(if $(filter none,$(DEV_DEPLOY)),:,$(MAKE) --no-print-directory dev-pin TAG=sha-$(call sq,$(COMMIT)))
	@$(if $(filter none,$(DEV_DEPLOY)),:,$(MAKE) --no-print-directory smoke)

# The rollback path, and the only one that does not build: name a tag you already published.
# The registry is checked FIRST because the alternative is the outage above — a stack pinned to a
# name the registry never held, discovered at the next restart when there was nothing to re-pull.
# v16: every image is checked before the one shared `TAG=` is written, once.
override define dev_pin_check
docker manifest inspect $(call sq,$(call img_base,$(1)):$(TAG)) >/dev/null 2>&1 || \
  { echo $(call sq,$(call img_base,$(1)):$(TAG))" is not in the registry — publish it before pinning a stack to it"; exit 1; }
endef

# v17: DEV_ENV_FILE reaches the shell as one word, so it must be one plain path (a space would pin
# one file and start the stack from another, or from none).
override define require_dev_deploy
case $(call sq,$(DEV_DEPLOY)) in compose) ;; \
  kustomize) $(if $(strip $(DEV_RECREATE)),echo "REFUSING: DEV_RECREATE recreates services of the compose dev lane: under kustomize a changed config ships in the overlay it renders"; exit 1) ;; \
  none) echo "REFUSING: "$(call sq,$(IB_NO_STACK)); exit 1 ;; \
  *) echo "REFUSING: DEV_DEPLOY must be compose, kustomize or none, not "$(call sq,$(DEV_DEPLOY)); exit 1 ;; esac
endef

# v19: each image the block publishes runs, in the rendered dev overlay, as exactly
# `<registry>/<name>:__TAG__` wherever an `image:` names it: never a digest (`@sha256:…`, which the
# kubelet pulls instead of the tag), no tag (`:latest`), a suffixed tag, or another tag; and at least
# one `image:` does. Only `image:` values are read (a pin in an annotation runs nothing), and a name is
# the whole value up to its digest (`@`) and its tag (the last `:` after the last `/`; a registry's
# `:<port>` is part of the name), so another registry's `x<registry>/<name>` is not this image. The
# "at least one" holds for DEV_OVERLAY (`$$km` set); a pre-overlay may run none of them (a Secret).
override define dev_kustomize_image
kv=$$(awk -v b=$(call sq,$(call img_base,$(1))) '/^[ \t]*(- )?image:[ \t]/ { v = $$0; sub(/^[ \t]*(- )?image:[ \t]*/, "", v); sub(/[ \t]+$$/, "", v); gsub(/^["\047]|["\047]$$/, "", v); n = v; sub(/@.*/, "", n); if (match(n, /:[^\/]*$$/)) n = substr(n, 1, RSTART - 1); if (n != b) next; if (v == b ":__TAG__") ok = 1; else bad = bad " " v } END { if (bad != "") print "BAD" bad; else if (!ok) print "NONE" }' "$$kr"); \
case "$$kv" in NONE) [ -z "$$km" ] || { \
  echo "REFUSING: the rendered dev overlay $$ov runs no container at "$(call sq,$(call img_base,$(1)))":__TAG__ (pin it with images: - name: … newTag: __TAG__): the tag dev-pin pins must be the one that runs"; exit 1; } ;; \
BAD*) echo "REFUSING: the rendered dev overlay $$ov also runs "$(call sq,$(call img_base,$(1)))" as:$${kv#BAD} (only :__TAG__, exactly, is the pin: not a digest, no tag, nor another tag)"; exit 1 ;; esac
endef

# v19: what is applied is the COMMIT: the overlay is rendered from `git archive HEAD` (its bases too),
# so an edited or untracked file in the working tree never reaches the cluster. The workloads waited
# on are read from the render with their namespace: `rollout status` for a Deployment, StatefulSet or
# DaemonSet, completion for a Job, Ready for a Pod (a CronJob runs on its schedule, not at deploy).
# v20: every overlay (DEV_PRE_OVERLAYS in order, then DEV_OVERLAY) is rendered and checked before any
# is applied, so a bad app overlay never leaves a migration run against the cluster; then each is
# applied and its workloads waited on before the next is applied. A Job's template cannot change once
# the Job exists, so each Job an overlay holds is deleted just before that overlay is applied: the
# next deploy runs the migration again at its own TAG, and a retry re-runs a Job that failed. A Job
# that does not complete prints its logs. Every manifest reaches DEV_KUBECTL on its stdin
# (`apply -f -`), never as a local path. Each overlay is spelled one way (no `./`, `//` or trailing
# `/`), so no overlay is applied twice under two spellings.
override define dev_kustomize
kd=$$(mktemp -d); trap 'trap "" HUP INT TERM; rm -rf "$$kd"' EXIT; trap 'trap "" HUP INT TERM; exit 1' HUP INT TERM; \
mkdir "$$kd/src" && git archive --format=tar HEAD | tar -x -C "$$kd/src" || { echo "REFUSING: could not export HEAD to render the dev overlays from"; exit 1; }; \
kn=0; kall=; for ov in $(call sqw,$(DEV_PRE_OVERLAYS)) $(call sq,$(DEV_OVERLAY)); do \
  case "$$ov" in ''|-*|/*|*..*|*[!A-Za-z0-9._/-]*|.|./*|*/.|*/./*|*//*|*/) echo "REFUSING: DEV_OVERLAY and each of DEV_PRE_OVERLAYS must be one plain path inside the repo, spelled one way (letters, digits, . _ / -; no ./, //, /./ or trailing /), not $$ov"; exit 1 ;; esac; \
  case " $$kall " in *" $$ov "*) echo "REFUSING: $$ov is listed twice (DEV_PRE_OVERLAYS, DEV_OVERLAY): each overlay is applied once"; exit 1 ;; esac; kall="$$kall $$ov"; \
  { git cat-file -e "HEAD:$$ov/kustomization.yaml" || git cat-file -e "HEAD:$$ov/kustomization.yml"; } 2>/dev/null || { \
    echo "REFUSING: $$ov holds no committed kustomization: a dev overlay is what runs, so it must be committed"; exit 1; }; \
  kn=$$((kn + 1)); kr=$$kd/$$kn.render.yaml; ka=$$kd/$$kn.apply.yaml; km=; [ "$$ov" != $(call sq,$(DEV_OVERLAY)) ] || km=1; \
  $(call sqw,$(DEV_KUSTOMIZE)) "$$kd/src/$$ov" > "$$kr" || { echo "REFUSING: "$(call sq,$(DEV_KUSTOMIZE))" could not render $$ov (as committed)"; exit 1; }; \
  $(call image_block_each,dev_kustomize_image,;); \
  sed -e "s|__TAG__|"$(call sq,$(TAG))"|g" "$$kr" > "$$ka" || exit 1; \
  kl=$$(grep -o '__[A-Z][A-Z0-9_]*__' "$$ka" | sort -u | tr '\n' ' '); \
  [ -z "$$kl" ] || { echo "REFUSING: the rendered dev overlay $$ov still holds $$kl once TAG is substituted: the dev deploy substitutes __TAG__ only"; exit 1; }; \
  printf '%s\n' "$$ov" > "$$kd/$$kn.name"; \
done; \
ksv=$(call sq,$(strip $(DEV_SERVER_SIDE))); ksm=$(call sq,$(strip $(DEV_FIELD_MANAGER))); \
for s in $$ksv; do case " $$kall " in *" $$s "*) ;; *) \
  echo "REFUSING: DEV_SERVER_SIDE names $$s, which is not one of DEV_PRE_OVERLAYS or DEV_OVERLAY (spelled as they are)"; exit 1 ;; esac; done; \
[ -z "$$ksv" ] || printf '%s\n' "$$ksm" | grep -Eqx '[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?' || { \
  echo "REFUSING: DEV_SERVER_SIDE needs DEV_FIELD_MANAGER, the name server-side apply records as the owner of those fields (lowercase letters, digits and -, e.g. myapp-deploy)"; exit 1; }; \
ki=0; while [ "$$ki" -lt "$$kn" ]; do ki=$$((ki + 1)); ka=$$kd/$$ki.apply.yaml; ov=$$(cat "$$kd/$$ki.name"); \
  ksa=; case " $$ksv " in *" $$ov "*) ksa="--server-side --field-manager=$$ksm --force-conflicts" ;; esac; \
  kw=$$(awk 'function out() { if (k != "" && nm != "") print k "|" nm "|" ns } /^---/ { out(); k = ""; nm = ""; ns = ""; md = 0; next } /^kind:[ \t]/ { k = $$2 } /^metadata:/ { md = 1; next } /^[^ \t]/ { md = 0 } md && /^  name:[ \t]/ { nm = $$2 } md && /^  namespace:[ \t]/ { ns = $$2 } END { out() }' "$$ka" | tr -d "\"'"); \
  for w in $$kw; do case "$${w%%|*}" in Job) r=$${w#*|}; nm=$${r%%|*}; ns=$${r#*|}; set -- $${ns:+-n "$$ns"}; \
    $(call sqw,$(DEV_KUBECTL)) delete "$$@" "job/$$nm" --ignore-not-found >/dev/null || { echo "FAIL  could not delete the previous job/$$nm$${ns:+ (namespace $$ns)} before applying $$ov"; exit 1; } ;; esac; done; \
  $(call sqw,$(DEV_KUBECTL)) apply $$ksa -f - < "$$ka" >/dev/null || { echo "FAIL  kubectl apply$${ksa:+ (server-side)} of the rendered dev overlay $$ov failed"; exit 1; }; \
  for w in $$kw; do k=$${w%%|*}; r=$${w#*|}; nm=$${r%%|*}; ns=$${r#*|}; set -- $${ns:+-n "$$ns"}; \
    case "$$k" in \
      Deployment|StatefulSet|DaemonSet) $(call sqw,$(DEV_KUBECTL)) rollout status "$$@" "$$k/$$nm" --timeout=$(call sq,$(DEV_WAIT_TIMEOUT))s ;; \
      Job) $(call sqw,$(DEV_KUBECTL)) wait "$$@" --for=condition=complete "job/$$nm" --timeout=$(call sq,$(DEV_WAIT_TIMEOUT))s || { \
        echo "FAIL  job/$$nm$${ns:+ (namespace $$ns)} in $$ov did not complete; its logs:"; $(call sqw,$(DEV_KUBECTL)) logs "$$@" "job/$$nm" --tail=200 || true; false; } ;; \
      Pod) $(call sqw,$(DEV_KUBECTL)) wait "$$@" --for=condition=Ready "pod/$$nm" --timeout=$(call sq,$(DEV_WAIT_TIMEOUT))s ;; \
      *) true ;; \
    esac || { echo "FAIL  $$k/$$nm$${ns:+ (namespace $$ns)} did not become ready within "$(call sq,$(DEV_WAIT_TIMEOUT))"s"; exit 1; }; done; \
  echo "$$ov: applied at TAG="$(call sq,$(TAG)); \
done
endef

override define require_dev_env_file
case $(call sq,$(DEV_ENV_FILE)) in ''|-*|*[!A-Za-z0-9._/-]*) \
  echo "REFUSING: DEV_ENV_FILE must be one plain path (letters, digits, . _ / -), not "$(call sq,$(DEV_ENV_FILE)); exit 1 ;; esac
endef

# DEV_HOST is empty, `local`, or one ssh destination `[user@]host` of plain characters: it becomes
# `ssh://<it>`, so a space, an option or a path in it would point docker somewhere else.
override define require_dev_host
[ $(call sq,$(origin DEV_HOST)) != 'command line' ] || { echo "REFUSING: DEV_HOST is set on the command line: where the dev stack runs is the committed Makefile's DEV_HOST := line, never one run's choice"; exit 1; }; \
case $(call sq,$(IB_DEV_HOST)) in ''|local) ;; \
  -*|*@*@*|@*|*@|*[!A-Za-z0-9._@-]*) echo "REFUSING: DEV_HOST must be local or one ssh destination [user@]host (letters, digits, . _ -), not "$(call sq,$(DEV_HOST)); exit 1 ;; \
  *) [ $(call sq,$(DEV_DEPLOY)) = compose ] || { echo "REFUSING: DEV_HOST is the compose dev lane's Docker host; DEV_DEPLOY is "$(call sq,$(DEV_DEPLOY))" (kustomize reaches its cluster through DEV_KUBECTL)"; exit 1; } ;; esac
endef

# The committed-line check, then (a host) the same-checkout check: see DEV_HOST above.
override define dev_host_same_files
dh_all=$$(git show "HEAD:./$$ib_dm" 2>/dev/null | grep -E '^[[:space:]]*(export[[:space:]]+|override[[:space:]]+)*DEV_HOST[[:space:]]*(::?=|:::=|\?=|\+=|!=|=)' | grep -vxE 'DEV_HOST[[:space:]]*\?=[[:space:]]*') || dh_all=; \
dh_c=$$(printf '%s\n' "$$dh_all" | grep -E '^DEV_HOST[[:space:]]*:=') || dh_c=; \
[ "$$(printf '%s\n' "$$dh_all" | grep -c 'DEV_HOST' || true)" = "$$(printf '%s\n' "$$dh_c" | grep -c 'DEV_HOST' || true)" ] || { echo "REFUSING: the committed $$ib_dm (HEAD) sets DEV_HOST with another form than DEV_HOST := <host> at the start of a line ($$(printf '%s\n' "$$dh_all" | grep -vE '^DEV_HOST[[:space:]]*:=' | head -n 1)). Write it as exactly one line: DEV_HOST := devhost"; exit 1; }; \
[ "$$(printf '%s' "$$dh_c" | grep -c '^DEV_HOST' || true)" -le 1 ] || { echo "REFUSING: the committed $$ib_dm (HEAD) has more than one DEV_HOST := line, so where the dev stack runs depends on which one this machine evaluates. Keep one"; exit 1; }; \
dh_v=$$(printf '%s\n' "$$dh_c" | sed -n 's/^DEV_HOST[[:space:]]*:=[[:space:]]*//p' | sed 's/[[:space:]]*$$//'); \
case "$$dh_v" in *[!A-Za-z0-9._@-]*) echo "REFUSING: the committed $$ib_dm (HEAD) sets DEV_HOST to something other than a literal ($$dh_v). Write the host itself, with nothing after it: DEV_HOST := devhost"; exit 1 ;; esac; \
[ "$$dh_v" = $(call sq,$(IB_DEV_HOST)) ] || { echo "REFUSING: DEV_HOST is "$(call sq,$(IB_DEV_HOST))" in this run, but the committed $$ib_dm (HEAD) says DEV_HOST := $${dh_v:-<nothing>}. Where the dev stack runs is that committed line, exactly: a Makefile.local, a conditional or computed definition, or an uncommitted edit moved it. Remove that, or commit the change"; exit 1; }; \
if [ -n $(call sq,$(IB_DEV_HOST)) ] && [ $(call sq,$(IB_DEV_HOST)) != local ]; then \
  [ "$${DOCKER_HOST:-}" = ssh://$(call sq,$(IB_DEV_HOST)) ] || { echo "REFUSING: DEV_HOST is "$(call sq,$(IB_DEV_HOST))" but this recipe's docker is $${DOCKER_HOST:-unset, this machine}: the stack would start somewhere else"; exit 1; }; \
  cd -P . || exit 1; dh_d=$$(pwd -P); umask 077; \
  case "$$dh_d" in *[!A-Za-z0-9._/-]*) echo "REFUSING: this checkout's path $$dh_d holds a character other than letters, digits, . _ / -, so the dev host cannot be asked for the same path"; exit 1 ;; esac; \
  [ -s $(call sq,$(DEV_ENV_FILE)) ] || { echo "$$dh_d/"$(call sq,$(DEV_ENV_FILE))" is missing or empty — copy .env.example and fill it in first"; exit 1; }; \
  dh_n=$$(mktemp "$$dh_d/.luxarch-dev-host.XXXXXX") || { echo "REFUSING: could not write a probe file in $$dh_d to show the dev host reads this same directory"; exit 1; }; \
  trap 'trap "" HUP INT TERM; rm -f "$$dh_n"' EXIT; trap 'trap "" HUP INT TERM; exit 1' HUP INT TERM; \
  od -An -N16 -tx1 /dev/urandom | tr -d ' \n' > "$$dh_n"; \
  dh_want=$$(cat -- "$$dh_n" "$$dh_d/"$(call sq,$(DEV_ENV_FILE)) | cksum); \
  dh_got=$$(ssh -o BatchMode=yes -o ConnectTimeout=10 $(call sq,$(IB_DEV_HOST)) cat -- "$$dh_n" "$$dh_d/"$(call sq,$(DEV_ENV_FILE)) 2>/dev/null </dev/null | cksum); \
  rm -f "$$dh_n"; trap - EXIT; dh_ok=; [ "$$dh_got" != "$$dh_want" ] || dh_ok=1; \
  [ -n "$$dh_ok" ] || { \
    echo "REFUSING: the dev host "$(call sq,$(IB_DEV_HOST))" does not read this checkout at $$dh_d (unreachable over ssh, not mounted there at this path, or a copy rather than the same directory: a file just written here is not there, or "$(call sq,$(DEV_ENV_FILE))" differs). Its docker would start the stack with bind mounts taken from its own filesystem, and a missing one as an empty directory: mount the checkout on the dev host at this same path"; exit 1; }; \
fi
endef

# v17: `--wait` waits for the LONG-RUNNING services only, and a ONE-SHOT service is judged by exiting
# 0. v16 waited on every service, and a run-once init (it creates a bucket or seeds a schema and exits
# 0) failed `up --wait` ("container … exited (0)"): a healthy deploy failed and its smoke never ran.
# What is one-shot is read from compose's own model of this stack (`config`), never from a name: a
# service whose `restart` is `no` (or unset, compose's default) and that the stack DECLARES one-shot,
# as the target of a `depends_on: <it>: condition: service_completed_successfully` (compose itself then
# starts its dependent only after it exits 0). Every other service of the stack is waited for, by name;
# each one-shot must then be `exited 0`. A stack with no one-shot runs v16's command unchanged. A
# service that exits 0 and is NOT declared is still waited for, and fails the deploy: declare it.
override define dev_compose
docker compose --env-file $(call sq,$(DEV_ENV_FILE)) $(foreach p,$(DEV_PROFILES),--profile $(call sq,$(p)))
endef

override define dev_up
svcs=$$($(dev_compose) config --services 2>/dev/null) && model=$$($(dev_compose) config 2>/dev/null) || { \
  echo "REFUSING: compose cannot resolve the dev stack from "$(call sq,$(DEV_ENV_FILE))" to tell its one-shot services from the long-running ones (run its config to see why; not printed here: it carries values)"; exit 1; }; \
once=$$(printf '%s\n' "$$model" | awk '/^[^ ]/ { top = $$0; next } top != "services:" { next } /^  [^ ]/ { s = $$1; sub(/:$$/, "", s); S[s] = 1; dep = 0; next } /^    [^ ]/ { dep = ($$0 == "    depends_on:"); if ($$1 == "restart:") { r = $$2; gsub(/["\047]/, "", r); R[s] = r } next } dep && /^      [^ ]/ { d = $$1; sub(/:$$/, "", d); next } dep && $$0 == "        condition: service_completed_successfully" { T[d] = 1 } END { for (x in T) if ((x in S) && (!(x in R) || R[x] == "no")) print x }' | sort -u); \
long=$$(printf '%s\n' "$$svcs" | awk -v once=" $$(echo $$once) " '$$0 != "" && index(once, " " $$0 " ") == 0'); \
ib_up_why() { for s in $$1; do \
  ps=$$($(dev_compose) ps -a --format '{{.Name}} {{.State}} {{.ExitCode}} {{.Health}}' "$$s" 2>/dev/null) || ps=; \
  [ -n "$$ps" ] || { echo "FAIL  $$s: compose reports no container for it"; continue; }; \
  printf '%s\n' "$$ps" | while read -r n st ec hl; do \
    case "$$st $$hl" in "running healthy"|"running ") continue ;; esac; \
    why=$$(docker inspect -f '{{if .State.Health}}{{range .State.Health.Log}}{{.Output}}{{end}}{{end}}' "$$n" 2>/dev/null | grep -v '^[[:space:]]*$$' | tail -n 1); \
    x=; [ "$$st" != exited ] || x=" (exit code $$ec)"; \
    echo "FAIL  $$s ($$n) is $$st$${hl:+ and $$hl}$$x$${why:+; its health check last said: $$why}"; \
    [ "$$st $$ec" != "exited 0" ] || echo "      $$s exited 0. If it runs once and exits (restart: \"no\"), declare it one-shot: the service that needs it gets depends_on: <it>: condition: service_completed_successfully. dev-pin then waits only for the long-running services and judges it by exiting 0."; \
  done; done; }; \
if [ -z "$$once" ] || [ -z "$$long" ]; then \
  $(dev_compose) up -d --wait --wait-timeout $(call sq,$(DEV_WAIT_TIMEOUT)) || { ib_up_why "$$svcs"; exit 1; }; \
else \
  $(dev_compose) up -d --wait --wait-timeout $(call sq,$(DEV_WAIT_TIMEOUT)) $$long || { ib_up_why "$$long"; exit 1; }; \
  for s in $$once; do st=$$($(dev_compose) ps -a --format '{{.State}} {{.ExitCode}}' "$$s" | sort -u); \
    [ "$$st" = "exited 0" ] || { echo "FAIL: the one-shot service $$s did not exit 0 (compose reports: $${st:-no container}), so the dev stack is not up"; exit 1; }; done; \
fi$(foreach s,$(DEV_RECREATE),; $(call dev_recreate,$(s)))
endef

# v23: DEV_RECREATE names services whose bind-mounted config compose cannot see change, each with the
# paths it starts from and an optional check run first in a throwaway container:
#   DEV_RECREATE := nginx
#   nginx_RECREATE_PATHS := nginx/nginx.conf nginx/templates
#   nginx_RECREATE_CHECK := nginx -t
# After `up --wait`, a service whose paths changed after its container started is checked, then
# recreated alone. Nothing enters the compose model. A missing path, an empty path list and a service
# the stack does not run refuse. The compose lane only.
override define dev_recreate
s=$(call sq,$(1)); \
case "$$s" in ''|-*|*[!A-Za-z0-9._-]*) echo "REFUSING: DEV_RECREATE entry '$$s' is not a compose service name"; exit 1 ;; esac; \
[ -n $(call sq,$(strip $($(1)_RECREATE_PATHS))) ] || { \
  echo "REFUSING: DEV_RECREATE names $$s but "$(call sq,$(1)_RECREATE_PATHS)" is empty: name the bind-mounted config it starts from"; exit 1; }; \
for p in $(call sqw,$($(1)_RECREATE_PATHS)); do case "$$p" in -*|/*|..|../*|*/..|*/../*) \
    echo "REFUSING: "$(call sq,$(1)_RECREATE_PATHS)" names $$p: each is a path inside the repo"; exit 1 ;; esac; \
  [ -e "$$p" ] || { echo "REFUSING: "$(call sq,$(1)_RECREATE_PATHS)" names $$p, which is not in this checkout: a misspelt path would never recreate $$s"; exit 1; }; done; \
ids=$$($(dev_compose) ps -q "$$s" 2>/dev/null) || ids=; \
[ -n "$$ids" ] || { echo "REFUSING: DEV_RECREATE names $$s, but the dev stack runs no container for $$s"; exit 1; }; \
ch=; for id in $$ids; do st=$$(docker inspect -f '{{.State.StartedAt}}' "$$id" 2>/dev/null) || st=; rf=$$(mktemp); \
  touch -d "$$st" "$$rf" 2>/dev/null && [ -n "$$st" ] || { rm -f "$$rf"; \
    echo "REFUSING: could not read when $$s's container $$id started ('$$st'), so nothing says whether it runs its current config"; exit 1; }; \
  c=$$(find $(call sqw,$($(1)_RECREATE_PATHS)) -newer "$$rf" -print 2>/dev/null | head -n 1); rm -f "$$rf"; [ -z "$$c" ] || ch=$$c; done; \
if [ -n "$$ch" ]; then \
  $(if $(strip $($(1)_RECREATE_CHECK)),$(call dev_recreate_check,$(1)) || { \
    echo "FAIL  $$s's changed config fails its check ("$(call sq,$(strip $($(1)_RECREATE_CHECK)))"): $$s is not recreated and keeps running its previous one"; exit 1; }; )\
  $(dev_compose) up -d --wait --wait-timeout $(call sq,$(DEV_WAIT_TIMEOUT)) --force-recreate --no-deps "$$s" || { ib_up_why "$$s"; exit 1; }; \
  echo "$$s: recreated ($$ch changed after its container started)"; \
fi
endef

# v25: the check runs while the service's own container holds its fixed addresses. `compose run` hands
# the throwaway container the service's networks with their `ipv4_address` / `ipv6_address` /
# `mac_address`, which docker refuses ("Address already in use"), so for a service that pins one the
# check runs on compose's resolved model of the stack (`config`: the same image, mounts and
# environment), read from stdin, with only those keys of that service dropped. A service that pins
# no address runs its check as `$(dev_compose) run`.
override define dev_recreate_check
m=$$($(dev_compose) config 2>/dev/null) || { \
  echo "REFUSING: compose cannot resolve the dev stack from "$(call sq,$(DEV_ENV_FILE))" to run $$s's check (run its config to see why; not printed here: it carries values)"; exit 1; }; \
fx=$$(printf '%s\n' "$$m" | awk -v s="$$s" '/^[^ ]/ { top = $$0; in_s = 0; print; next } top == "services:" && /^  [^ ]/ { in_s = ($$1 == s ":"); print; next } in_s && /^ +(ipv4_address|ipv6_address|mac_address):/ { next } { print }'); \
if [ "$$fx" = "$$m" ]; then \
  $(dev_compose) run --rm --no-deps -T "$$s" $(call sqw,$($(1)_RECREATE_CHECK)); \
else \
  printf '%s\n' "$$fx" | $(dev_compose) -f - run --rm --no-deps -T "$$s" $(call sqw,$($(1)_RECREATE_CHECK)); \
fi
endef

# v17: `dev-pin` pins only an IMMUTABLE tag the block publishes: `sha-<commit>` (publish-sha's, the
# commit abbreviated as COMMIT is, 12 hex digits, up to the full 40) or a released version (digits and
# dots, tagged `v<version>` in this checkout). v16 checked only that the registry held the tag, so
# the tags `dev` and `latest` (moving: the stack changes at the next push) and `candidate-<commit>`
# (pushed BEFORE its scan, so possibly the very image the scan rejected) were pinned like any other.
override define require_pin_tag
t=$(call sq,$(TAG)); \
if printf '%s\n' "$$t" | grep -Eqx 'sha-[0-9a-f]{12,40}'; then :; \
elif printf '%s\n' "$$t" | grep -Eqx '[0-9]+(\.[0-9]+)+'; then \
  git rev-parse -q --verify "refs/tags/v$$t^{commit}" >/dev/null 2>&1 || { \
    echo "REFUSING: TAG=$$t is not a released version here (no tag v$$t; git fetch --tags), and dev-pin pins only an immutable, published tag"; exit 1; }; \
else \
  echo "REFUSING: TAG=$$t is not an immutable tag the image block publishes. Pin sha-<commit> (make publish-sha) or a released version; dev and latest move, and a candidate- tag is pushed before its scan."; exit 1; \
fi
endef

dev-pin: ## Point the dev stack (compose, or the kustomize dev overlay) at an ALREADY-PUBLISHED tag and restart it (rollback path)
	@$(ib_run_snap)$(if $(and $(value sq),$(value sqw),$(value img_dockerfile)),,$(error REFUSING: the image block (v18) builds with the build core's quoting and image helpers (sq, sqw, img_*), which this makefile does not define. Paste `luxarch --emit build-core` directly above the image block))$(if $(value gh_release_publish),,$(error REFUSING: the image block (v24) publishes its GitHub Release with the gh-release block (gh_release_preflight, gh_release_publish), which this makefile does not define. Paste `luxarch --emit gh-release` directly below the image block))set -e; set -f; $(if $(filter-out default,$(origin MAKE_COMMAND)),echo "REFUSING: MAKE_COMMAND is set from outside the makefile"; exit 1; )$(if $(strip $(MAKEFILES)),echo "REFUSING: MAKEFILES is set so make read makefiles before this one that nobody committed or named: unset it"; exit 1; )$(if $(filter-out file,$(origin MAKEFILE_LIST)),echo "REFUSING: MAKEFILE_LIST is set from outside the makefile"; exit 1; )$(if $(filter-out default undefined,$(origin MAKECMDGOALS)),echo "REFUSING: MAKECMDGOALS is set from outside the makefile"; exit 1; )$(if $(filter command% environment%,$(origin SHELL) $(origin .SHELLFLAGS)),echo "REFUSING: SHELL or .SHELLFLAGS comes from the command line or the environment: the recipe would run in another shell"; exit 1; )$(if $(findstring x,$(filter-out --%,$(filter -%,$(.SHELLFLAGS)))),echo "REFUSING: .SHELLFLAGS traces the recipe (-x) and would print every value spliced into it"; exit 1; )\
	[ -z "$${BASH_ENV:-}$${ENV:-}" ] || { echo "REFUSING: BASH_ENV or ENV is set: a shell startup file ran before this recipe"; exit 1; }; case $$- in *x*) echo "REFUSING: the recipe shell traces its commands (-x) and would print every value spliced into it"; exit 1 ;; esac; \
	ib_dm=; for m in GNUmakefile makefile Makefile; do if [ -f "$$m" ]; then ib_dm=$$m; break; fi; done; \
	[ -n "$$ib_dm" ] && git ls-files --error-unmatch -- "$$ib_dm" >/dev/null 2>&1 || { \
	  echo "REFUSING: this directory's default makefile ($${ib_dm:-none}) is not tracked by git: what make reads first must be committed"; exit 1; }; \
	ib_ml='$(subst ','\'',$(MAKEFILE_LIST))'; set -- $$ib_ml; \
	[ "$$(cd "$$(dirname -- "$$1")" && pwd -P)/$$(basename -- "$$1")" = "$$(pwd -P)/$$ib_dm" ] || { \
	  echo "REFUSING: make read $$1 first and not this directory's default makefile ($$ib_dm): run make without -f"; exit 1; }; \
	ib_db=$$(env -i PATH="$$PATH" HOME="$$HOME" '$(subst ','\'',$(MAKE_COMMAND))' -pq -f "$$ib_dm" $(foreach g,$(MAKECMDGOALS),'$(subst ','\'',$(g))') 2>&1) || true; \
	printf '%s\n' "$$ib_db" | grep -q '^# Variables' && ! printf '%s\n' "$$ib_db" | grep -Eq '^([^ #][^:]*:[0-9]+|make[^:]*): [*][*][*] ' || { \
	  echo "REFUSING: the image block could not re-read this makefile in a clean environment (env -i, no command-line variables) with these goals. make said: $$(printf '%s\n' "$$ib_db" | grep -E '^([^ #][^:]*:[0-9]+|make[^:]*): [*][*][*] ' | head -n 3 | tr '\n' ' ')"; exit 1; }; \
	ib_cml=$$(printf '%s\n' "$$ib_db" | sed -n 's/^MAKEFILE_LIST :*= *//p' | head -n 1); \
	for ib_x in $$ib_ml; do case " $$ib_cml " in *" $$ib_x "*) ;; *) \
	  echo "REFUSING: make read $$ib_x and a clean evaluation of $$ib_dm does not (a second -f): run make with the default makefile only"; exit 1 ;; esac; done; \
	ib_rl=$$(printf '%s\n' "$$ib_db" | awk -v t='$(subst ','\'',$@)' 'in_t && /^#  recipe to execute \(from / { s = $$0; sub(/^#  recipe to execute \(from \047/, "", s); f = s; sub(/\047, line [0-9]+\):$$/, "", f); l = s; sub(/^.*\047, line /, "", l); sub(/\):$$/, "", l); print f "|" l; exit } /^[^#\t ][^:]*:/ { in_t = (substr($$0, 1, length(t) + 1) == t ":") }'); \
	ib_bf=$${ib_rl%|*}; ib_rn=$${ib_rl##*|}; \
	[ -n "$$ib_rl" ] && [ -f "$$ib_bf" ] || { echo "REFUSING: make's database does not say where the recipe of "'$(subst ','\'',$@)'" is, so nothing proves it is the image block's"; exit 1; }; \
	set -- $$(awk '/^# luxarch:image-block asset v[0-9]/ { m = NR; nm++ } /^# luxarch:image-block end/ { e = NR; ne++ } /^# luxarch:build-core asset v[0-9]/ { cm = NR; ncm++ } /^# luxarch:build-core end/ { ce = NR; nce++ } /^# luxarch:gh-release asset v[0-9]/ { gm = NR; ngm++ } /^# luxarch:gh-release end/ { ge = NR; nge++ } END { if (nm != 1 || ne != 1) { m = 0; e = 0 } if (ncm != 1 || nce != 1) { cm = 0; ce = 0 } if (ngm != 1 || nge != 1) { gm = 0; ge = 0 } print m + 0 " " e + 0 " " cm + 0 " " ce + 0 " " gm + 0 " " ge + 0 }' "$$ib_bf"); ib_m=$${1:-0}; ib_e=$${2:-0}; ib_cm=$${3:-0}; ib_ce=$${4:-0}; ib_gm=$${5:-0}; ib_ge=$${6:-0}; \
	ib_lo=$$ib_m; ib_hi=$$ib_e; [ '$(subst ','\'',$@)' != gh-release ] || { ib_lo=$$ib_gm; ib_hi=$$ib_ge; }; [ "$$ib_m" -gt 0 ] && [ "$$ib_e" -gt "$$ib_m" ] && [ "$$ib_rn" -gt "$$ib_lo" ] && [ "$$ib_rn" -lt "$$ib_hi" ] || { \
	  echo "REFUSING: the recipe of "'$(subst ','\'',$@)'" make runs is $$ib_bf:$$ib_rn, which is not inside the block that ships it (gh-release: the gh-release block; every other target: the image block): a redefinition of the target replaced it"; exit 1; }; \
	[ "$$ib_cm" -gt 0 ] && [ "$$ib_ce" -gt "$$ib_cm" ] && [ "$$ib_ce" -lt "$$ib_m" ] || { \
	  echo "REFUSING: $$ib_bf has no build core directly above the image block (exactly one core marker and one core end marker in the file, both before the block's): the block's quoting and image names are the core's, and its guard checks them there. Paste luxarch --emit build-core above the block"; exit 1; }; \
	[ "$$ib_gm" -gt "$$ib_e" ] && [ "$$ib_ge" -gt "$$ib_gm" ] || { \
	  echo "REFUSING: $$ib_bf has no gh-release block below the image block (exactly one gh-release marker and one gh-release end marker in the file, both after the block's end): the release publishes its GitHub Release with it, and the guard checks its lines as the block's. Paste luxarch --emit gh-release below the block"; exit 1; }; \
	ib_nm=$$(awk -v m="$$ib_m" -v e="$$ib_e" -v cm="$$ib_cm" -v ce="$$ib_ce" -v gm="$$ib_gm" -v ge="$$ib_ge" '(NR >= m && NR <= e || NR >= cm && NR <= ce || NR >= gm && NR <= ge) && /^override / { s = $$0; sub(/^override +(define +)?/, "", s); sub(/[ \t:=+!?].*/, "", s); printf " %s", s } END { print " " }' "$$ib_bf"); \
	ib_bad=$$(printf '%s\n' "$$ib_db" | awk -v F="$$ib_bf" -v m="$$ib_m" -v e="$$ib_e" -v cm="$$ib_cm" -v ce="$$ib_ce" -v gm="$$ib_gm" -v ge="$$ib_ge" -v names="$$ib_nm" -v tg='$(subst ','\'',release publish-sha release-public publish-mirror dev-deploy dev-pin gh-release $@ $(MAKECMDGOALS))' 'function bad(n, w, f, l) { if (index(names, " " n " ") && (w != "" || f != F || (l + 0 < m || l + 0 > e) && (l + 0 < cm || l + 0 > ce) && (l + 0 < gm || l + 0 > ge))) printf "%s%s at %s:%s; ", n, (w != "" ? " (" w "-specific)" : ""), f, l; else if (w != "" && index(" REGISTRY RELEASE_REGISTRY PUBLIC_REGISTRY PRIVATE_REGISTRY LUXAUDIT_IMAGE LUXAUDIT IMAGE_NAME PLATFORMS ", " " n " ") && reaches(sc)) printf "%s (%s-specific, %s) at %s:%s; ", n, w, sc, f, l } function reaches(p,   i, k, T, a, b) { k = split(tg, T, " "); i = index(p, "%"); for (a = 1; a <= k; a++) { if (i == 0 && T[a] == p) return 1; if (i > 0 && index(T[a], substr(p, 1, i - 1)) == 1 && length(T[a]) >= length(p) - 1 && substr(T[a], length(T[a]) - (length(p) - i) + 1) == substr(p, i + 1)) return 1 } return 0 } /^# Pattern-specific Variable Values/ { pat = 1 } /^# (Directories|Implicit Rules|Files)/ { pat = 0 } pat && /^[^#].* :$$/ { ph = $$0; sub(/ :$$/, "", ph) } /^# (makefile|\047override\047 directive|environment|environment under -e|command line|default|automatic)( \(from \047.*\047, line [0-9]+\))?$$/ { o = 1; f = ""; l = 0; if (match($$0, /\(from \047.*\047, line [0-9]+\)$$/)) { s = substr($$0, RSTART + 7, RLENGTH - 8); f = s; sub(/\047, line [0-9]+$$/, "", f); l = s; sub(/^.*\047, line /, "", l) } next } o && pat && /^# [A-Za-z_.][A-Za-z0-9_.]* (::?:?=|=|\+=|\?=|!=)/ { sc = ph; bad($$2, "pattern", f, l); o = 0; next } o && /^[^#\t ][^:]*: [A-Za-z_.][A-Za-z0-9_.]* (::?:?=|=|\+=|\?=|!=)/ { x = $$0; sc = x; sub(/:.*/, "", sc); sub(/^[^:]*: /, "", x); split(x, X, " "); bad(X[1], "target", f, l); o = 0; next } o && /^define [A-Za-z_]/ { bad($$2, "", f, l); o = 0; next } o && /^[A-Za-z_.][A-Za-z0-9_.]* (::?:?=|=|\+=|\?=|!=)/ { bad($$1, "", f, l); o = 0; next } { o = 0 }'); \
	[ -z "$$ib_bad" ] || { echo "REFUSING: make's own database (a clean evaluation with these goals) defines what the image block defines from outside the block: $${ib_bad%; }. The block's names are set inside it only."; exit 1; }; \
	$(require_main_checkout); $(require_registry); $(require_images)$(require_dev_deploy); $(require_dev_env_file); $(require_dev_host); $(require_pin_tag); \
	$(call image_block_each,dev_pin_check,;); \
	$(if $(filter none,$(DEV_DEPLOY)),:,$(if $(filter kustomize,$(DEV_DEPLOY)),$(dev_kustomize),$(dev_host_same_files); $(call pin_env_tag,$(DEV_ENV_FILE),$(TAG),$(foreach p,$(DEV_PROFILES),--profile $(p)),$(call image_block_each,img_base,)); $(dev_up)))$(ib_unchanged)

# ── Verify: build from source, locally, every run ───────────────────────────────────────────────
# The test image must carry the SAME app layers production ships, plus the dev group. Two Dockerfile
# shapes do that, and either is canonical:
#   - `FROM production AS test`, putting back what production stripped (`python -m ensurepip`)
#     before `poetry install --with dev`;
#   - one shared `app` stage that both `test` and `production` build FROM, when production also
#     strips poetry. v3 said only "FROM production", which a production stage hardened per
#     FLEET-BUILD-DEPLOY-STANDARD (no pip/poetry in the runtime) cannot satisfy literally.
# Either way the Dockerfile needs a stage named `test`: this target builds it. v16, IMAGES set: the
# first image's, the one the suite runs in (TEST_IMAGE). v23: under `DEV_DEPLOY := none` (a tool mirror
# only) it refuses and builds nothing, as `dev-deploy` and `dev-pin` do.

test-build: ## Build the LOCAL test image from source (never pushed, never a deploy tag)
	@$(if $(and $(value sq),$(value sqw),$(value img_dockerfile)),,$(error REFUSING: the image block (v18) builds with the build core's quoting and image helpers (sq, sqw, img_*), which this makefile does not define. Paste `luxarch --emit build-core` directly above the image block))$(if $(filter none,$(DEV_DEPLOY)),echo "REFUSING: "$(call sq,$(IB_NO_STACK))"; it has no app image to build a test stage of"; exit 1,set -f; docker build --load --target test $(call sqw,$(BUILD_ARGS)) -f $(call sq,$(call img_dockerfile,$(IMAGE_PRIMARY))) -t $(call sq,$(TEST_IMAGE)) $(call sq,$(call img_context,$(IMAGE_PRIMARY))) >/dev/null)
# luxarch:image-block end - DO NOT edit this marker line: the block's runtime guard reads its range.

# luxarch:gh-release asset v3 - DO NOT edit this marker line; it is how repo.emitted_assets_current knows your copy is current. Re-emit with `luxarch --emit gh-release`.
# ── The GitHub Release: this version's notes on origin's /releases page ──────────────────────────
# Emitted by `luxarch --emit gh-release`. Paste it directly BELOW the image block (v24 or later), in the
# same makefile: the block's `release` and `release-public` run its macros, every block target refuses
# without it, and the block's inline guard checks these lines as its own. Until image block v24 these
# lines were part of the image block (v8-v23). Each `vN:` below is the image block version in which
# that line came in, and `v1:` this block's own.
# The GitHub Release: this version's user-facing notes on the repo's /releases page (--doc
# FLEET-RELEASE-PROCESS §9, `repo.github_release_wired`). v8: v1-v7 had no step for it, so an exact copy
# of this DO-NOT-EDIT block was red on that rule and the only ways to green were editing the block or a
# target outside `release` that nothing runs. `release` now runs it last, and checks everything it needs
# BEFORE the first push, against the REMOTE: `gh release create --verify-tag` needs the tag on GitHub, so
# a tag that exists only locally would let the image push and the Release fail. If the Release step
# still fails, re-run `make gh-release` alone: it is idempotent, and it needs the pushed tag, not HEAD
# (`release` refuses an already-released version, and HEAD moves on after the release commit). With
# PUBLIC_REGISTRY set, `release-public` runs it last instead, after the public copy (v23).
# RELEASE_NOTES is found, not assumed: `<app>/release_notes/$(VERSION).md` wherever the app lives, up to
# three directories down (`app/`, `src/<pkg>/`, `apps/backend/app/`). Set it above the image block only when
# more than one app ships notes.
RELEASE_NOTES ?= $(wildcard release_notes/$(VERSION).md */release_notes/$(VERSION).md */*/release_notes/$(VERSION).md */*/*/release_notes/$(VERSION).md)

# v1: the Release is created, and read back, on ORIGIN's GitHub repository, named to gh with `-R
# github.com/<owner>/<repo>` on every `gh release` call. Without it gh acts on the repository IT
# resolves (GH_REPO in the shell, `gh repo set-default`, an `upstream` remote), where another app with
# the same tag passes `--verify-tag`, and the read-back vouched for that repository. origin's URL is
# read as git expands it (`git remote get-url origin`, the URL `require_origin_tag` asked for the tag):
# https or ssh on github.com (ssh over port 443 at ssh.github.com too), or it refuses (an ssh host
# alias names no host it can check; the URL is not printed: it may carry a token). A GH_REPO
# naming another repository refuses, so a shell set up for another repo is never silently overridden.
override define gh_release_repo
ib_gho=$$(git remote get-url origin 2>/dev/null) || { echo "REFUSING: this checkout has no origin remote, so nothing names the GitHub repository the Release belongs to"; exit 1; }; \
ib_ghr=$$(printf '%s\n' "$$ib_gho" | awk 'NR == 1 { u = tolower($$0) } END { if (NR != 1) exit; if (!sub(/^(https?:\/\/([^\/@]*@)?github\.com(:443)?\/|ssh:\/\/([^\/@]*@)?(github\.com(:22)?|ssh\.github\.com(:443)?)\/|([^\/@:]*@)?github\.com:)/, "", u)) exit; sub(/\/$$/, "", u); sub(/\.git$$/, "", u); if (u ~ /^[a-z0-9_.-]+\/[a-z0-9_.-]+$$/ && u !~ /\/\.+$$/) print u }'); \
[ -n "$$ib_ghr" ] || { echo "REFUSING: origin's URL is not a github.com repository (https://github.com/<owner>/<repo>, git@github.com:<owner>/<repo>, or ssh://git@ssh.github.com:443/<owner>/<repo>), so it names no GitHub repository for the Release. An ssh host alias (git@<alias>:<owner>/<repo>) does not say which host it is: set origin to one of those forms (git remote set-url origin git@github.com:<owner>/<repo>.git)"; exit 1; }; \
[ -z "$${GH_REPO:-}" ] || [ "$$(printf '%s\n' "$$GH_REPO" | tr 'A-Z' 'a-z' | sed -e 's|^https://||' -e 's|^github\.com/||' -e 's|\.git$$||' -e 's|/$$||')" = "$$ib_ghr" ] || { \
  echo "REFUSING: GH_REPO is '$$GH_REPO', and origin is github.com/$$ib_ghr: the Release belongs to origin's repository. Unset GH_REPO"; exit 1; }
endef

override define gh_release_preflight
command -v gh >/dev/null 2>&1 || { echo "REFUSING: the GitHub CLI (gh) is not installed; the release publishes its notes with it"; exit 1; }; \
ghv=$$(gh --version 2>/dev/null | head -n 1 || true); \
printf '%s\n' "$$ghv" | grep -Eq '^gh version [0-9]+\.[0-9]+\.[0-9]+' || { \
  echo "REFUSING: $$(command -v gh) is not the GitHub CLI: its --version printed '$$ghv', not 'gh version X.Y.Z'. Reinstall gh"; exit 1; }; \
ghh=$$(gh release view --help 2>&1 || true); case "$$ghh" in *--json*) ;; *) \
  echo "REFUSING: $$ghv is too old: its gh release view takes no --json, which the release reads the Release back with. Install a gh whose 'gh release view --help' lists --json"; exit 1 ;; esac; \
$(gh_release_repo); \
gh auth status --hostname github.com >/dev/null 2>&1 || { echo "REFUSING: gh is not authenticated to github.com (gh auth login)"; exit 1; }; \
set -- $(call sqw,$(RELEASE_NOTES)); if [ $$# -ne 1 ]; then \
  echo "REFUSING: need exactly ONE release notes file for "$(call sq,$(VERSION))", found $$#: "$(call sq,$(or $(RELEASE_NOTES),none)); \
  echo "Write <app>/release_notes/"$(call sq,$(VERSION))".md (luxarch --emit release-notes-guide), or set RELEASE_NOTES above the image block."; \
  exit 1; \
fi; \
$(require_origin_tag); \
$(gh_release_notes_tagged)
endef

# v2: the notes published are the ones the tagged commit holds (`git cat-file blob v$(VERSION):<file>`,
# the path read from this directory), never the working tree's: an uncommitted edit, or one committed
# after the tag, would put text on the Release that the released commit does not carry. A tag that does
# not hold the notes file refuses, in the preflight, before anything is pushed. An absolute
# RELEASE_NOTES under this directory is read relative to it; one outside it names no file the tag holds.
override gh_release_notes_path = $(patsubst $(CURDIR)/%,%,$(strip $(RELEASE_NOTES)))
override define gh_release_notes_tagged
$(if $(filter /%,$(gh_release_notes_path)),echo "REFUSING: RELEASE_NOTES is "$(call sq,$(strip $(RELEASE_NOTES)))": outside this checkout ("$(call sq,$(CURDIR))") and so in no tagged commit. Set it to the notes file inside the repo"; exit 1; )\
git cat-file -e $(call sq,refs/tags/v$(VERSION)^{commit}:./$(gh_release_notes_path)) 2>/dev/null || { \
  echo "REFUSING: v"$(call sq,$(VERSION))" does not hold "$(call sq,$(strip $(RELEASE_NOTES)))": the GitHub Release publishes the notes the tagged commit holds. Commit the notes, then tag (a released tag is never moved: bump VERSION)"; exit 1; }
endef

# v23: a Release is reported only when gh shows it published (by its tag, and not a draft): an exit
# status is no proof, and a `gh` that is not the GitHub CLI exits 0 having published nothing.
override define gh_release_shown
ib_ght=$$(gh release view $(call sq,v$(VERSION)) -R "github.com/$${ib_ghr:?}" --json tagName,isDraft --jq '.tagName + " " + (.isDraft | tostring)' 2>/dev/null || true); [ "$$ib_ght" = $(call sq,v$(VERSION))" false" ]
endef

override define gh_release_publish
if $(gh_release_shown); then \
  echo "GitHub Release v"$(call sq,$(VERSION))" already exists on github.com/$$ib_ghr, skipped (a Release, like its tag, is immutable)"; \
elif [ "$$ib_ght" = $(call sq,v$(VERSION))" true" ]; then \
  echo "REFUSING: GitHub Release v"$(call sq,$(VERSION))" is a draft, which nobody can see: publish or delete the draft v"$(call sq,$(VERSION)); exit 1; \
else \
  ( ib_nt=$$(mktemp) || { echo "REFUSING: mktemp failed, so there is no file to hand gh the tagged notes in; nothing was published"; exit 1; }; \
    trap 'trap "" HUP INT TERM; rm -f "$$ib_nt"' EXIT; trap 'trap "" HUP INT TERM; exit 1' HUP INT TERM; \
    git cat-file blob $(call sq,refs/tags/v$(VERSION)^{commit}:./$(gh_release_notes_path)) > "$$ib_nt" || { \
      echo "REFUSING: could not read "$(call sq,$(strip $(RELEASE_NOTES)))" from v"$(call sq,$(VERSION))"; nothing was published"; exit 1; }; \
    gh release create $(call sq,v$(VERSION)) -R "github.com/$${ib_ghr:?}" --verify-tag --title $(call sq,$(VERSION)) --notes-file "$$ib_nt" || { \
      echo "REFUSING: gh release create v"$(call sq,$(VERSION))" failed; nothing was published"; exit 1; } ) || exit 1; \
  $(gh_release_shown) || { \
    echo "REFUSING: gh release create exited 0, but gh release view v"$(call sq,$(VERSION))" does not show the Release: nothing is published"; exit 1; }; \
  echo "Published GitHub Release v"$(call sq,$(VERSION))" on github.com/$$ib_ghr"; \
fi
endef

# v23: with PUBLIC_REGISTRY set, users pull from there, so the GitHub Release follows the public copy:
# `release` leaves it to `release-public`, and a standalone `gh-release` refuses until every image's
# public `:$(VERSION)` exists (any answer but the manifest refuses, an unreachable registry too).
# v2: and until the copy is the release, judged by digest as `release-public PUBLIC_RESUME=1` judges
# it: every image's public `:$(VERSION)` holds the digest of its released `:$(VERSION)` (another digest
# refuses: it is immutable, so bump VERSION), and with PUBLIC_LATEST its public `:latest` holds it too
# (a copy that stopped before `:latest` refuses and names the resume, which moves it and then publishes
# the Release). An older version, copied without moving `:latest`, runs with `PUBLIC_LATEST=` on the
# command line, as its copy did.
override define gh_release_public_check
case $(call sq,$(strip $(PUBLIC_LATEST))) in ''|1) ;; *) echo "REFUSING: PUBLIC_LATEST is empty or 1, not "$(call sq,$(PUBLIC_LATEST)); exit 1 ;; esac; \
docker manifest inspect $(call sq,$(call img_public,$(1))) >/dev/null 2>&1 || { \
  echo "REFUSING: "$(call sq,$(call img_public,$(1)))" is not published, and the GitHub Release follows the public copy (users pull from "$(call sq,$(PUBLIC_REGISTRY))"): make release-public publishes both"; exit 1; }; \
rd=$$(docker buildx imagetools inspect $(call sq,$(call img_version,$(1))) --format '{{.Manifest.Digest.Encoded}}' 2>/dev/null) || rd=; \
case "$$rd" in ''|*[!0-9a-f]*) echo "REFUSING: could not read the digest of the released "$(call sq,$(call img_version,$(1)))", so nothing proves "$(call sq,$(call img_public,$(1)))" is the release"; exit 1 ;; esac; \
pd=$$(docker buildx imagetools inspect $(call sq,$(call img_public,$(1))) --format '{{.Manifest.Digest.Encoded}}' 2>/dev/null) || pd=; \
case "$$pd" in ''|*[!0-9a-f]*) echo "REFUSING: could not read the digest of "$(call sq,$(call img_public,$(1)))", so nothing proves it is the release"; exit 1 ;; esac; \
[ "$$pd" = "$$rd" ] || { \
  echo "REFUSING: "$(call sq,$(call img_public,$(1)))" is PUBLISHED at another digest (sha256:$$pd) than the released "$(call sq,$(call img_version,$(1)))" (sha256:$$rd): the GitHub Release would name a public image that is not the release, and it is immutable. Bump VERSION."; exit 1; }$(if $(filter 1,$(strip $(PUBLIC_LATEST))),; \
ld=$$(docker buildx imagetools inspect $(call sq,$(call img_public_latest,$(1))) --format '{{.Manifest.Digest.Encoded}}' 2>/dev/null) || ld=; \
[ "$$ld" = "$$rd" ] || { \
  echo "REFUSING: "$(call sq,$(call img_public_latest,$(1)))" is not at the released digest sha256:$$rd (it reads '$${ld:-nothing}'): the public copy stopped before :latest. make release-public PUBLIC_RESUME=1 moves it and then publishes the GitHub Release. An older version that leaves :latest where it is: make gh-release PUBLIC_LATEST="; exit 1; })
endef

gh-release: ## Publish the GitHub Release for v$(VERSION) from its release notes (idempotent; `release` runs it, or `release-public` with PUBLIC_REGISTRY set)
	@$(ib_run_snap)$(if $(and $(value sq),$(value sqw),$(value img_dockerfile)),,$(error REFUSING: the image block (v18) builds with the build core's quoting and image helpers (sq, sqw, img_*), which this makefile does not define. Paste `luxarch --emit build-core` directly above the image block))$(if $(value gh_release_publish),,$(error REFUSING: the image block (v24) publishes its GitHub Release with the gh-release block (gh_release_preflight, gh_release_publish), which this makefile does not define. Paste `luxarch --emit gh-release` directly below the image block))set -e; set -f; $(if $(filter-out default,$(origin MAKE_COMMAND)),echo "REFUSING: MAKE_COMMAND is set from outside the makefile"; exit 1; )$(if $(strip $(MAKEFILES)),echo "REFUSING: MAKEFILES is set so make read makefiles before this one that nobody committed or named: unset it"; exit 1; )$(if $(filter-out file,$(origin MAKEFILE_LIST)),echo "REFUSING: MAKEFILE_LIST is set from outside the makefile"; exit 1; )$(if $(filter-out default undefined,$(origin MAKECMDGOALS)),echo "REFUSING: MAKECMDGOALS is set from outside the makefile"; exit 1; )$(if $(filter command% environment%,$(origin SHELL) $(origin .SHELLFLAGS)),echo "REFUSING: SHELL or .SHELLFLAGS comes from the command line or the environment: the recipe would run in another shell"; exit 1; )$(if $(findstring x,$(filter-out --%,$(filter -%,$(.SHELLFLAGS)))),echo "REFUSING: .SHELLFLAGS traces the recipe (-x) and would print every value spliced into it"; exit 1; )\
	[ -z "$${BASH_ENV:-}$${ENV:-}" ] || { echo "REFUSING: BASH_ENV or ENV is set: a shell startup file ran before this recipe"; exit 1; }; case $$- in *x*) echo "REFUSING: the recipe shell traces its commands (-x) and would print every value spliced into it"; exit 1 ;; esac; \
	ib_dm=; for m in GNUmakefile makefile Makefile; do if [ -f "$$m" ]; then ib_dm=$$m; break; fi; done; \
	[ -n "$$ib_dm" ] && git ls-files --error-unmatch -- "$$ib_dm" >/dev/null 2>&1 || { \
	  echo "REFUSING: this directory's default makefile ($${ib_dm:-none}) is not tracked by git: what make reads first must be committed"; exit 1; }; \
	ib_ml='$(subst ','\'',$(MAKEFILE_LIST))'; set -- $$ib_ml; \
	[ "$$(cd "$$(dirname -- "$$1")" && pwd -P)/$$(basename -- "$$1")" = "$$(pwd -P)/$$ib_dm" ] || { \
	  echo "REFUSING: make read $$1 first and not this directory's default makefile ($$ib_dm): run make without -f"; exit 1; }; \
	ib_db=$$(env -i PATH="$$PATH" HOME="$$HOME" '$(subst ','\'',$(MAKE_COMMAND))' -pq -f "$$ib_dm" $(foreach g,$(MAKECMDGOALS),'$(subst ','\'',$(g))') 2>&1) || true; \
	printf '%s\n' "$$ib_db" | grep -q '^# Variables' && ! printf '%s\n' "$$ib_db" | grep -Eq '^([^ #][^:]*:[0-9]+|make[^:]*): [*][*][*] ' || { \
	  echo "REFUSING: the image block could not re-read this makefile in a clean environment (env -i, no command-line variables) with these goals. make said: $$(printf '%s\n' "$$ib_db" | grep -E '^([^ #][^:]*:[0-9]+|make[^:]*): [*][*][*] ' | head -n 3 | tr '\n' ' ')"; exit 1; }; \
	ib_cml=$$(printf '%s\n' "$$ib_db" | sed -n 's/^MAKEFILE_LIST :*= *//p' | head -n 1); \
	for ib_x in $$ib_ml; do case " $$ib_cml " in *" $$ib_x "*) ;; *) \
	  echo "REFUSING: make read $$ib_x and a clean evaluation of $$ib_dm does not (a second -f): run make with the default makefile only"; exit 1 ;; esac; done; \
	ib_rl=$$(printf '%s\n' "$$ib_db" | awk -v t='$(subst ','\'',$@)' 'in_t && /^#  recipe to execute \(from / { s = $$0; sub(/^#  recipe to execute \(from \047/, "", s); f = s; sub(/\047, line [0-9]+\):$$/, "", f); l = s; sub(/^.*\047, line /, "", l); sub(/\):$$/, "", l); print f "|" l; exit } /^[^#\t ][^:]*:/ { in_t = (substr($$0, 1, length(t) + 1) == t ":") }'); \
	ib_bf=$${ib_rl%|*}; ib_rn=$${ib_rl##*|}; \
	[ -n "$$ib_rl" ] && [ -f "$$ib_bf" ] || { echo "REFUSING: make's database does not say where the recipe of "'$(subst ','\'',$@)'" is, so nothing proves it is the image block's"; exit 1; }; \
	set -- $$(awk '/^# luxarch:image-block asset v[0-9]/ { m = NR; nm++ } /^# luxarch:image-block end/ { e = NR; ne++ } /^# luxarch:build-core asset v[0-9]/ { cm = NR; ncm++ } /^# luxarch:build-core end/ { ce = NR; nce++ } /^# luxarch:gh-release asset v[0-9]/ { gm = NR; ngm++ } /^# luxarch:gh-release end/ { ge = NR; nge++ } END { if (nm != 1 || ne != 1) { m = 0; e = 0 } if (ncm != 1 || nce != 1) { cm = 0; ce = 0 } if (ngm != 1 || nge != 1) { gm = 0; ge = 0 } print m + 0 " " e + 0 " " cm + 0 " " ce + 0 " " gm + 0 " " ge + 0 }' "$$ib_bf"); ib_m=$${1:-0}; ib_e=$${2:-0}; ib_cm=$${3:-0}; ib_ce=$${4:-0}; ib_gm=$${5:-0}; ib_ge=$${6:-0}; \
	ib_lo=$$ib_m; ib_hi=$$ib_e; [ '$(subst ','\'',$@)' != gh-release ] || { ib_lo=$$ib_gm; ib_hi=$$ib_ge; }; [ "$$ib_m" -gt 0 ] && [ "$$ib_e" -gt "$$ib_m" ] && [ "$$ib_rn" -gt "$$ib_lo" ] && [ "$$ib_rn" -lt "$$ib_hi" ] || { \
	  echo "REFUSING: the recipe of "'$(subst ','\'',$@)'" make runs is $$ib_bf:$$ib_rn, which is not inside the block that ships it (gh-release: the gh-release block; every other target: the image block): a redefinition of the target replaced it"; exit 1; }; \
	[ "$$ib_cm" -gt 0 ] && [ "$$ib_ce" -gt "$$ib_cm" ] && [ "$$ib_ce" -lt "$$ib_m" ] || { \
	  echo "REFUSING: $$ib_bf has no build core directly above the image block (exactly one core marker and one core end marker in the file, both before the block's): the block's quoting and image names are the core's, and its guard checks them there. Paste luxarch --emit build-core above the block"; exit 1; }; \
	[ "$$ib_gm" -gt "$$ib_e" ] && [ "$$ib_ge" -gt "$$ib_gm" ] || { \
	  echo "REFUSING: $$ib_bf has no gh-release block below the image block (exactly one gh-release marker and one gh-release end marker in the file, both after the block's end): the release publishes its GitHub Release with it, and the guard checks its lines as the block's. Paste luxarch --emit gh-release below the block"; exit 1; }; \
	ib_nm=$$(awk -v m="$$ib_m" -v e="$$ib_e" -v cm="$$ib_cm" -v ce="$$ib_ce" -v gm="$$ib_gm" -v ge="$$ib_ge" '(NR >= m && NR <= e || NR >= cm && NR <= ce || NR >= gm && NR <= ge) && /^override / { s = $$0; sub(/^override +(define +)?/, "", s); sub(/[ \t:=+!?].*/, "", s); printf " %s", s } END { print " " }' "$$ib_bf"); \
	ib_bad=$$(printf '%s\n' "$$ib_db" | awk -v F="$$ib_bf" -v m="$$ib_m" -v e="$$ib_e" -v cm="$$ib_cm" -v ce="$$ib_ce" -v gm="$$ib_gm" -v ge="$$ib_ge" -v names="$$ib_nm" -v tg='$(subst ','\'',release publish-sha release-public publish-mirror dev-deploy dev-pin gh-release $@ $(MAKECMDGOALS))' 'function bad(n, w, f, l) { if (index(names, " " n " ") && (w != "" || f != F || (l + 0 < m || l + 0 > e) && (l + 0 < cm || l + 0 > ce) && (l + 0 < gm || l + 0 > ge))) printf "%s%s at %s:%s; ", n, (w != "" ? " (" w "-specific)" : ""), f, l; else if (w != "" && index(" REGISTRY RELEASE_REGISTRY PUBLIC_REGISTRY PRIVATE_REGISTRY LUXAUDIT_IMAGE LUXAUDIT IMAGE_NAME PLATFORMS ", " " n " ") && reaches(sc)) printf "%s (%s-specific, %s) at %s:%s; ", n, w, sc, f, l } function reaches(p,   i, k, T, a, b) { k = split(tg, T, " "); i = index(p, "%"); for (a = 1; a <= k; a++) { if (i == 0 && T[a] == p) return 1; if (i > 0 && index(T[a], substr(p, 1, i - 1)) == 1 && length(T[a]) >= length(p) - 1 && substr(T[a], length(T[a]) - (length(p) - i) + 1) == substr(p, i + 1)) return 1 } return 0 } /^# Pattern-specific Variable Values/ { pat = 1 } /^# (Directories|Implicit Rules|Files)/ { pat = 0 } pat && /^[^#].* :$$/ { ph = $$0; sub(/ :$$/, "", ph) } /^# (makefile|\047override\047 directive|environment|environment under -e|command line|default|automatic)( \(from \047.*\047, line [0-9]+\))?$$/ { o = 1; f = ""; l = 0; if (match($$0, /\(from \047.*\047, line [0-9]+\)$$/)) { s = substr($$0, RSTART + 7, RLENGTH - 8); f = s; sub(/\047, line [0-9]+$$/, "", f); l = s; sub(/^.*\047, line /, "", l) } next } o && pat && /^# [A-Za-z_.][A-Za-z0-9_.]* (::?:?=|=|\+=|\?=|!=)/ { sc = ph; bad($$2, "pattern", f, l); o = 0; next } o && /^[^#\t ][^:]*: [A-Za-z_.][A-Za-z0-9_.]* (::?:?=|=|\+=|\?=|!=)/ { x = $$0; sc = x; sub(/:.*/, "", sc); sub(/^[^:]*: /, "", x); split(x, X, " "); bad(X[1], "target", f, l); o = 0; next } o && /^define [A-Za-z_]/ { bad($$2, "", f, l); o = 0; next } o && /^[A-Za-z_.][A-Za-z0-9_.]* (::?:?=|=|\+=|\?=|!=)/ { bad($$1, "", f, l); o = 0; next } { o = 0 }'); \
	[ -z "$$ib_bad" ] || { echo "REFUSING: make's own database (a clean evaluation with these goals) defines what the image block defines from outside the block: $${ib_bad%; }. The block's names are set inside it only."; exit 1; }; \
	$(gh_release_preflight); \
	$(if $(strip $(PUBLIC_REGISTRY)),$(call image_block_each,gh_release_public_check,;); )$(gh_release_publish)$(ib_unchanged)
# luxarch:gh-release end - DO NOT edit this marker line: the image block's runtime guard reads its range.

# Smoke settings: this collector serves no HTTP, so the deployed stack is probed through its
# container (it must run this commit and reach healthy by its own HEALTHCHECK) and its two real
# entry points are imported in the production image. SMOKE_URL stays empty on purpose.
SMOKE_CONTAINERS := kasa-collector
SMOKE_ENTRY_MODULES := app.main app.health.check

# luxarch:smoke asset v15 - DO NOT edit this marker line; it is how repo.emitted_assets_current knows your copy is current. Re-emit with `luxarch --emit smoke`.
# ── Smoke: probe the DEPLOYED stack from outside, after every dev deploy ──────────────────────────
# Emitted by `luxarch --emit smoke`; paste below the image block. `make test` runs the app in-process
# against its test stack, so it cannot see the proxy, the server, the production image or an entry
# point other than the app's. One repo shipped four bugs under a green `make check` that only a probe
# of the deployed stack found: a rate limiter that took the host down, a proxy serving an unstyled UI,
# a standalone script that crashed on a circular import in the production image, and a Host-header
# defence no test exercised. Each probe below is aimed at one of them. `make dev-deploy` runs it
# (`repo.stack_smoke_wired`); a FAIL fails the deploy, and a probe that cannot run says NOT RUN and
# why, never a silent pass.
#
# Settings are `?=` defaults: override them above this block, committed (SMOKE_URL is the dev name).

# Setting: where the dev stack is reachable from the build host (e.g. https://dev.example.com) ---
SMOKE_URL ?=
# Setting: the deployed containers to probe on the docker host the deploy restarted. Each must run
# THIS build (its image's org.opencontainers.image.revision label names the commit) and reach
# `healthy` by its own HEALTHCHECK. For a stack that serves no HTTP (a collector, a poller) this is
# the probe, and SMOKE_URL stays empty; an HTTP stack may list its containers too (v5) ----------
SMOKE_CONTAINERS ?=
# Setting: how many seconds a container may stay `starting` before its health probe FAILs (v5) --
SMOKE_HEALTH_WAIT ?= 180
# Setting: how many seconds every container must STAY healthy, with no restart, after its first
# healthy sample; a HEALTHCHECK with a longer interval stretches it to one interval, so that check
# has run again (v6) ------------------------------------------------------------------------------
SMOKE_HEALTH_SETTLE ?= 30
# Setting: the health path; its response must name the build's commit (any field name) -------
SMOKE_HEALTH_PATH ?= /health
# Setting: a static asset the image serves (empty only if the app serves no static files) -----
SMOKE_STATIC_PATH ?= /static/css/app.css
# Setting: a path that needs authentication; the token comes from the SMOKE_AUTH_TOKEN env var -
SMOKE_AUTH_PATH ?=
# Setting: the content type the signed-in answer carries (e.g. application/json, or
# text/event-stream for a stream). Required with SMOKE_AUTH_PATH, so a proxy's or an error page's
# 200 cannot pass for a signed-in answer (v11) -------------------------------------------------
SMOKE_AUTH_TYPE ?=
# Setting: the package directory of standalone entry points, and the image's import root -------
SMOKE_SCRIPTS_DIR ?= app/scripts
SMOKE_IMPORT_ROOT ?= .
# Setting: entry-point MODULES outside that directory. The default is every `*_main` module at the
# app package's root, where the layout standard (fw.module_homes) puts a service's entry points
# (`app.portal_main`); list them yourself for any other place (v3) ---------------------------
SMOKE_ENTRY_MODULES ?= $(basename $(subst /,.,$(patsubst $(SMOKE_IMPORT_ROOT)/%,%,$(wildcard $(SMOKE_IMPORT_ROOT)/app/*_main.py))))
# Setting: the env file the dev stack runs with; each entry point is imported with it, because a
# module that builds the app's settings needs the config the deployed container has (v2). Its
# `TAG=` line names the build the deploy pinned, and that is the build every probe expects (v6).
# v9: by default the image block's DEV_ENV_FILE, the file `dev-pin` wrote, so a second dev stack
# deployed with `DEV_ENV_FILE=…` is probed against its own pin, not `.env.dev`'s -------------------
SMOKE_ENV_FILE ?= $(or $(DEV_ENV_FILE),.env.dev)
# Setting: extra `docker run` options for the entry-point imports (e.g. -e NAME=value) ----------
SMOKE_RUN_OPTS ?=
# Setting: extra curl options (e.g. --cacert <file> for a private CA) -------------------------
SMOKE_CURL_OPTS ?=

# v15: `smoke-browser` runs on THIS machine's docker, the one the shell that ran make names (the image
# block's IB_AMBIENT_DOCKER_HOST, or none), never the dev host this target's probes reach: its runner
# mounts this machine's directories (the pages, the suite, the traces), which the dev host does not
# hold, and it reaches SMOKE_URL over the network like any browser. The probes end with no `exit` when
# they pass, so under `.ONESHELL` (one shell for the whole recipe) the hand-off still runs: v14's
# `exit $$fail` ended that one shell with 0 before `smoke-browser`, and `make smoke` passed without it.
# v14: with the browser-smoke block pasted below this one (luxarch --emit browser-smoke), `make smoke`
# runs `smoke-browser` last, once every probe above has passed, so a page that breaks in a browser
# fails the deploy. Without that block (opt-in) the line does nothing.
# v11: the key reaches curl on its standard input, never its command line, where any user on the
# host could read it for as long as curl runs (a stream holds it open). The signed-in probe wants
# SMOKE_AUTH_TYPE as its media type (any case) and a whole body, or be an event stream still open
# when the probe stops reading, and a wrong key must be refused: the real key with its second-to-last
# character before any `=` padding changed (in any case), so a check of the key's shape alone, or of
# its decoded bytes, does not pass. A forged Host passes only on
# a 4xx other than a timeout (408) or a rate limit (429): a 5xx is the app failing, not refusing.
# An empty SMOKE_CONTAINERS prints NOT RUN.
# v8: a forged-Host 502 also names the SNI cause: a front proxy that sends the client's Host as its
# upstream TLS SNI meets the catch-all's ssl_reject_handshake, so even `return 400` never answers.
# v8: the static-asset probe keeps its expected content type in its own variable. v7 reused `want`,
# the build the stack should run, so every SMOKE_CONTAINERS probe after it compared the revision with
# "text/css" and FAILed a stack that was running the right build.
# v7: git's own error is shown when the commit cannot be read. v6 discarded it, so a checkout owned by
# another user (git's "dubious ownership" refusal) printed only "git rev-parse failed". Trusting the
# checkout is the operator's call, made once with git's own remedy, never bypassed here: the image
# block's dirty-tree check refuses the same checkout for the same reason.
# v6: a forged Host that is answered names the defence to install (FLEET-BUILD-DEPLOY-STANDARD "Trusted hosts"):
# v5 said the defence was off and nothing said what it is, so each repo invented its own.
# v6: one healthy sample was enough, so a container that crashed and restarted right after it PASSed.
# A container now passes only when it is still healthy SMOKE_HEALTH_SETTLE seconds later (at least
# one interval of its HEALTHCHECK) with the same start time and restart count. The build expected is the one SMOKE_ENV_FILE's `TAG=` pins: v5
# compared against HEAD only, so a `make dev-pin TAG=<release>` rollback could never be verified.
# A forged-Host 502 behind a front proxy names its likely cause; a refusal is only credited when the
# same URL answers the real Host (a stack that answers nothing does not refuse anything).
# v5: a stack with no HTTP surface has nothing for the HTTP probes to ask, and v4 refused to run at all
# without SMOKE_URL. It is probed through its containers instead (SMOKE_CONTAINERS): the build each
# runs and the verdict of its own HEALTHCHECK, beside the entry-point imports.
# v4: a 502/503/504 on the forged-Host probe is the PROXY answering for an app that did not, not a refusal.
# v3 printed "PASS  forged Host refused (502)" while the stack was still starting, beside two FAILs that
# said the same thing; the probe can only pass on an answer from the app itself.
smoke: ## Probe the deployed dev stack: build commit, static asset, forged Host refused, auth, containers healthy, standalone entry points
	@set -u; fail=0; \
	[ -n "$(strip $(SMOKE_URL)$(SMOKE_CONTAINERS))" ] || { echo "REFUSING: commit SMOKE_URL := https://<the dev stack's dev name> in the Makefile, or SMOKE_CONTAINERS := <its containers> when it serves no HTTP"; exit 2; }; \
	probe() { curl -sS --max-time 15 $(SMOKE_CURL_OPTS) -o "$$B" -w '%{http_code} %{content_type}' "$$@" 2>/dev/null || echo "000 -"; }; \
	B=$$(mktemp); trap 'trap "" HUP INT TERM; rm -f "$$B"' EXIT; trap 'trap "" HUP INT TERM; exit 1' HUP INT TERM; \
	sha=$$(git rev-parse --short=7 HEAD) || sha=; \
	pin=; if [ -n "$(SMOKE_ENV_FILE)" ] && [ -f "$(SMOKE_ENV_FILE)" ]; then pin=$$(sed -n 's/^[[:space:]]*TAG=//p' "$(SMOKE_ENV_FILE)" | tail -n 1 | tr -d "\"' \r"); fi; \
	want=$$sha; what="this commit"; img="$(SHA_IMAGE)"; \
	if [ -n "$$pin" ] && { [ -z "$$sha" ] || case "$$pin" in sha-"$$sha"*) false;; *) true;; esac; }; then \
	  img="$(IMAGE):$$pin"; what="the pinned TAG=$$pin"; want=; \
	  if ! docker image inspect "$$img" >/dev/null 2>&1 && ! docker pull -q "$$img" >/dev/null 2>&1; then echo "FAIL  $(SMOKE_ENV_FILE) pins TAG=$$pin, and $$img is neither here nor pullable, so the build the stack should run cannot be named"; fail=1; \
	  else want=$$(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$$img" 2>/dev/null | cut -c1-7); \
	    if [ -z "$$want" ]; then echo "FAIL  $$img carries no org.opencontainers.image.revision label, so the build the stack should run cannot be named"; fail=1; \
	    else echo "NOTE  $(SMOKE_ENV_FILE) pins TAG=$$pin (revision $$want), not this checkout ($${sha:-unknown}): probing the pinned build"; fi; fi; \
	elif [ -z "$$sha" ]; then echo "FAIL  cannot read this checkout's commit (git's error is above; a checkout owned by another user needs git config --global --add safe.directory $(CURDIR)), so the deployed build cannot be checked"; fail=1; fi; \
	if [ -z "$(SMOKE_URL)" ]; then echo "NOT RUN  HTTP probes (health, static asset, forged Host, auth): SMOKE_URL is empty, so the stack is probed only through SMOKE_CONTAINERS (right only for a stack that serves no HTTP)"; \
	else \
	r=$$(probe "$(SMOKE_URL)$(SMOKE_HEALTH_PATH)"); hcode=$${r%% *}; \
	if [ -z "$$want" ]; then :; \
	elif [ "$$hcode" = 200 ] && grep -q "$$want" "$$B"; then echo "PASS  health names $$what ($$want)"; \
	else echo "FAIL  $(SMOKE_HEALTH_PATH): $$r, and the response does not name $$want: the stack is not running $$what"; fail=1; fi; \
	if [ -n "$(SMOKE_STATIC_PATH)" ]; then \
	  r=$$(probe "$(SMOKE_URL)$(SMOKE_STATIC_PATH)"); ctype=$${r#* }; \
	  case "$(SMOKE_STATIC_PATH)" in *.css) mime=text/css;; *.js|*.mjs) mime=javascript;; *) mime=;; esac; \
	  if [ "$${r%% *}" = 200 ] && [ -s "$$B" ] && ! grep -qi '<html' "$$B" && { [ -z "$$mime" ] || case "$$ctype" in *"$$mime"*) true;; *) false;; esac; }; then echo "PASS  static asset served ($(SMOKE_STATIC_PATH), $$ctype)"; \
	  else echo "FAIL  $(SMOKE_STATIC_PATH): $$r: the proxy or image does not serve the built asset as $${mime:-a file} (a browser refuses a stylesheet or script with the wrong type)"; fail=1; fi; \
	else echo "NOT RUN  static asset: SMOKE_STATIC_PATH is empty (only right for an app that serves no static files)"; fi; \
	r=$$(probe -H "Host: smoke-forged.invalid" "$(SMOKE_URL)$(SMOKE_HEALTH_PATH)"); \
	case "$${r%% *}" in 2??|3??) echo "FAIL  a forged Host header was answered ($$r): the trusted-host defence is not on in the real stack. The app must refuse it: luxarch --doc FLEET-BUILD-DEPLOY-STANDARD, \"Trusted hosts\" (luxarch --emit trusted-host)"; fail=1;; \
	  000) if [ "$$hcode" = 000 ]; then echo "FAIL  the forged-Host probe got no answer, and neither did $(SMOKE_HEALTH_PATH) with the real Host: nothing is answering at $(SMOKE_URL), so whether it refuses a forged Host is unknown"; fail=1; \
	    else echo "PASS  forged Host refused (connection rejected)"; fi;; \
	  502|503|504) if [ "$$hcode" = 200 ]; then echo "FAIL  the forged-Host probe got $${r%% *} while $(SMOKE_HEALTH_PATH) answers 200 through the same URL: a proxy in front of the stack reported a refusal it could not pass on (a closed connection: nginx's 444) as $${r%% *}, or the stack failed this request. Either way no refusal was seen. Behind another proxy, refuse with an answer: the app's trusted-host check answers 400 through any proxy, so let the forged Host reach it, or have the catch-all server return 400, not 444. If it already returns 400, the front proxy likely sends the client's Host as its upstream TLS SNI and the catch-all's ssl_reject_handshake drops the handshake: pin the proxy's upstream SNI to the real name, or drop ssl_reject_handshake behind a front proxy. Keep SMOKE_URL on the public address: FLEET-BUILD-DEPLOY-STANDARD, \"Trusted hosts\""; \
	    else echo "FAIL  the forged-Host probe got $${r%% *} from the proxy: the app did not answer, so whether it refuses a forged Host is unknown"; fi; fail=1;; \
	  408|429) echo "FAIL  the forged-Host probe got $${r%% *} ($$r): a timeout or a rate limit answered, not a check of the Host, so whether it is refused is unknown"; fail=1;; \
	  4??) echo "PASS  forged Host refused ($${r%% *})";; \
	  *) echo "FAIL  the forged-Host probe got $${r%% *} ($$r): a refusal is a 4xx, and an app that fails on a forged Host does not refuse it. The app must refuse it: luxarch --doc FLEET-BUILD-DEPLOY-STANDARD, \"Trusted hosts\""; fail=1;; esac; \
	if [ -n "$(SMOKE_AUTH_PATH)" ]; then \
	  r=$$(probe "$(SMOKE_URL)$(SMOKE_AUTH_PATH)"); \
	  case "$${r%% *}" in 401|403) echo "PASS  $(SMOKE_AUTH_PATH) refuses a request with no credentials ($${r%% *})";; \
	    *) echo "FAIL  $(SMOKE_AUTH_PATH) answered a request with NO credentials ($$r): it is not protected"; fail=1;; esac; \
	  aprobe() { w=$$(curl -sS --max-time 15 $(SMOKE_CURL_OPTS) -o "$$B" -w '%{http_code} %{content_type}' -H @- "$(SMOKE_URL)$(SMOKE_AUTH_PATH)" 2>/dev/null); echo "$$? $${w:-000 -}"; }; \
	  k=$${SMOKE_AUTH_TOKEN:-smoke-wrong-key-$$$$}; pad=; while case "$$k" in *=) true;; *) false;; esac; do pad="$$pad="; k=$${k%=}; done; \
	  h=$${k%??}; t=$${k#"$$h"}; c=$${t%?}; case "$$c" in [Aa]) c=B;; *) c=A;; esac; \
	  if [ $${#k} -lt 2 ]; then k="$${k}x$$pad"; else k="$$h$$c$${t#?}$$pad"; fi; h=; t=; \
	  r=$$(printf 'Authorization: Bearer %s\n' "$$k" | aprobe); k=; r=$${r#* }; \
	  case "$${r%% *}" in 401|403) echo "PASS  $(SMOKE_AUTH_PATH) refuses a wrong key ($${r%% *})";; \
	    *) echo "FAIL  $(SMOKE_AUTH_PATH) answered a WRONG key ($$r): it does not check the key it is given"; fail=1;; esac; \
	  if [ -z "$${SMOKE_AUTH_TOKEN:-}" ]; then echo "FAIL  SMOKE_AUTH_PATH is set but SMOKE_AUTH_TOKEN is not in the environment"; fail=1; \
	  elif [ -z "$(strip $(SMOKE_AUTH_TYPE))" ]; then echo "FAIL  SMOKE_AUTH_PATH is set but SMOKE_AUTH_TYPE is empty: set it to the content type the signed-in answer carries (application/json, text/event-stream, text/html), so a proxy's or an error page's 200 cannot pass"; fail=1; \
	  else r=$$(printf 'Authorization: Bearer %s\n' "$$SMOKE_AUTH_TOKEN" | aprobe); arc=$${r%% *}; r=$${r#* }; code=$${r%% *}; ctype=$$(printf '%s' "$${r#* }" | tr A-Z a-z); \
	    atype=$$(printf '%s' "$(strip $(SMOKE_AUTH_TYPE))" | tr A-Z a-z); \
	    base=$${ctype%%;*}; base=$${base%% *}; if [ "$$base" = "$$atype" ]; then typed=1; else typed=; fi; \
	    case "$$arc $$base" in "0 "*) [ -s "$$B" ] || typed=;; "28 text/event-stream") ;; *) typed=;; esac; \
	    if [ "$$code" = 200 ] && [ -n "$$typed" ]; then echo "PASS  authenticated request ($(SMOKE_AUTH_PATH), $$ctype)"; \
	    else echo "FAIL  authenticated $(SMOKE_AUTH_PATH): $$r (curl exit $$arc): a signed-in answer is a whole 200 of $(SMOKE_AUTH_TYPE) with a body, or an event stream still open when the probe stops reading"; fail=1; fi; fi; \
	else echo "NOT RUN  authenticated request: SMOKE_AUTH_PATH is empty"; fi; \
	fi; \
	settle=$(SMOKE_HEALTH_SETTLE); healthy=; \
	[ -n "$(strip $(SMOKE_CONTAINERS))" ] || echo "NOT RUN  containers (build and health): SMOKE_CONTAINERS is empty"; \
	for c in $(SMOKE_CONTAINERS); do \
	  if ! rev=$$(docker inspect -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$$c" 2>/dev/null); then echo "FAIL  container $$c is not on this docker host: the deploy did not bring it up"; fail=1; continue; fi; \
	  if [ -n "$$want" ]; then case "$$rev" in *"$$want"*) echo "PASS  $$c runs $$what ($$want)";; \
	    *) echo "FAIL  $$c runs revision '$$rev', not $$want: the stack is not running $$what (an image with no org.opencontainers.image.revision label cannot say which build it is)"; fail=1;; esac; fi; \
	  life=$$(docker inspect -f '{{.RestartCount}} {{.State.StartedAt}}' "$$c" 2>/dev/null || echo gone); \
	  t=0; while :; do \
	    st=$$(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$$c" 2>/dev/null || echo "gone -"); \
	    case "$$st" in "running starting"|restarting*) [ "$$t" -lt $(SMOKE_HEALTH_WAIT) ] || break; sleep 5; t=$$((t + 5));; *) break;; esac; \
	  done; \
	  case "$$st" in "running healthy") \
	    iv=$$(docker inspect -f '{{if .Config.Healthcheck}}{{json .Config.Healthcheck.Interval}}{{end}}' "$$c" 2>/dev/null); \
	    case "$$iv" in ""|*[!0-9]*) iv=0;; esac; iv=$$((iv / 1000000000)); [ "$$iv" -gt 0 ] || iv=30; \
	    [ "$$iv" -le "$$settle" ] || settle=$$iv; healthy="$$healthy $$c=$$(printf '%s' "$$life" | tr ' ' '@')";; \
	    "running none") echo "FAIL  $$c declares no HEALTHCHECK, so nothing shows its process works: declare one in its Dockerfile or compose service"; fail=1;; \
	    "running starting") echo "FAIL  $$c is still starting after $(SMOKE_HEALTH_WAIT)s: its HEALTHCHECK never passed"; fail=1;; \
	    "running unhealthy") why=$$(docker inspect -f '{{range .State.Health.Log}}{{.Output}}{{end}}' "$$c" 2>/dev/null | grep -v '^[[:space:]]*$$' | tail -n 1); echo "FAIL  $$c is unhealthy by its own HEALTHCHECK: $$why"; fail=1;; \
	    *) echo "FAIL  $$c is not running ($$st): the deployed process stopped or is crash-looping"; fail=1;; esac; \
	done; \
	if [ -n "$$healthy" ]; then sleep "$$settle"; for e in $$healthy; do \
	  c=$${e%%=*}; life=$$(printf '%s' "$${e#*=}" | tr '@' ' '); \
	  st=$$(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$$c" 2>/dev/null || echo "gone -"); \
	  now=$$(docker inspect -f '{{.RestartCount}} {{.State.StartedAt}}' "$$c" 2>/dev/null || echo gone); \
	  if [ "$$now" != "$$life" ]; then echo "FAIL  $$c restarted during the probe (restart count and start time '$$life', then '$$now'): it crashed after its HEALTHCHECK passed"; fail=1; \
	  else case "$$st" in "running healthy") echo "PASS  $$c is healthy by its own HEALTHCHECK, and still is $${settle}s later with no restart";; \
	    "running unhealthy") why=$$(docker inspect -f '{{range .State.Health.Log}}{{.Output}}{{end}}' "$$c" 2>/dev/null | grep -v '^[[:space:]]*$$' | tail -n 1); echo "FAIL  $$c is unhealthy by its own HEALTHCHECK $${settle}s after it first passed: $$why"; fail=1;; \
	    *) echo "FAIL  $$c is not running ($$st) $${settle}s after its HEALTHCHECK passed: the deployed process stopped"; fail=1;; esac; fi; \
	done; fi; \
	n=0; mods=; \
	if [ -d "$(SMOKE_SCRIPTS_DIR)" ]; then root=$$(CDPATH= cd -P -- "$(SMOKE_IMPORT_ROOT)" && pwd -P) || exit 1; \
	  for f in $$(find "$(SMOKE_SCRIPTS_DIR)" -name '*.py' ! -name '__init__.py' | sort); do \
	  d=$$(CDPATH= cd -P -- "$$(dirname -- "$$f")" && pwd -P) || exit 1; \
	  case "$$d/" in "$${root%/}/"*) rel="$${d#"$${root%/}"}/$$(basename "$$f")"; rel=$${rel#/} ;; \
	    *) echo "REFUSING: $$f is not under SMOKE_IMPORT_ROOT ($(SMOKE_IMPORT_ROOT)), so it has no module name to import"; exit 1 ;; esac; \
	  mods="$$mods $$(printf '%s' "$${rel%.py}" | tr / .)"; done; fi; \
	mods=$$(printf '%s\n' $$mods $(SMOKE_ENTRY_MODULES) | sort -u); \
	if [ -n "$$mods" ]; then \
	  envf=; [ -n "$(SMOKE_ENV_FILE)" ] && [ -f "$(SMOKE_ENV_FILE)" ] && envf="--env-file=$(SMOKE_ENV_FILE)"; \
	  if ! docker image inspect "$$img" >/dev/null 2>&1 && ! docker pull -q "$$img" >/dev/null 2>&1; then \
	    echo "FAIL  entry points: $$img is neither built here nor pullable, so no module could be imported (deploy this commit first)"; fail=1; n=-1; \
	  else for mod in $$mods; do \
	    n=$$((n + 1)); \
	    if err=$$(docker run --rm $$envf $(SMOKE_RUN_OPTS) --entrypoint python "$$img" -c "import $$mod" 2>&1 >/dev/null); then echo "PASS  $$mod imports on its own in the production image"; \
	    else fail=1; why=$$(printf '%s\n' "$$err" | grep -E '^[A-Za-z_][A-Za-z0-9_.]*(Error|Exception|Exit)\b' | tail -n 1); why=$${why:-$$(printf '%s\n' "$$err" | grep -v '^[[:space:]]*$$' | tail -n 1)}; \
	      case "$$err" in *ImportError*|*ModuleNotFoundError*|*"circular import"*) echo "FAIL  $$mod does not import on its own in $$img (a circular or missing import the app's own import order hides): $$why";; \
	        *) echo "FAIL  $$mod raised at import in $$img: $$why"; [ -n "$$envf" ] || echo "      no env file was passed ($(SMOKE_ENV_FILE) not found): set SMOKE_ENV_FILE to the file the stack runs with";; esac; fi; \
	  done; fi; \
	fi; \
	[ "$$n" -ne 0 ] || echo "NOT RUN  entry points: no module under $(SMOKE_SCRIPTS_DIR) and no SMOKE_ENTRY_MODULES"; \
	[ "$$fail" = 0 ] || exit "$$fail"
	@$(if $(value smoke_browser_block),$(if $(filter undefined,$(origin IB_AMBIENT_DOCKER_HOST)),,$(if $(IB_AMBIENT_DOCKER_HOST),DOCKER_HOST=$(call sq,$(IB_AMBIENT_DOCKER_HOST)),env -u DOCKER_HOST) )$(MAKE) --no-print-directory smoke-browser,:)

# The emulator is a TEST FIXTURE, never a released artifact: built locally under a BARE name and
# never pushed, so the demo and e2e stacks resolve it from the local store with no registry.
harness-build: ## Build the fake-device emulator image (compose never builds — it runs a tag)
	docker build --load -t $(FAKE_IMAGE) ./harness
	@echo "built $(FAKE_IMAGE)"

docker-inspect: ## Inspect release image metadata
	@docker inspect $(VERSION_IMAGE) --format='Version: {{index .Config.Labels "org.opencontainers.image.version"}}' 2>/dev/null || echo "Image not built"
	@docker inspect $(VERSION_IMAGE) --format='Built:   {{index .Config.Labels "org.opencontainers.image.created"}}' 2>/dev/null || true
	@docker inspect $(VERSION_IMAGE) --format='Commit:  {{index .Config.Labels "org.opencontainers.image.revision"}}' 2>/dev/null || true

docker-clean: ## Remove local image tags (this commit's :sha, :$(VERSION), the :dev alias, the bare test images)
	docker rmi $(SHA_IMAGE) $(VERSION_IMAGE) $(DEV_ALIAS) $(TEST_IMAGE) $(E2E_IMAGE) $(FAKE_IMAGE) 2>/dev/null || true

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

##@ Dev — the full stack on the dev host (DEV_HOST: your real devices + bundled InfluxDB + Grafana)

# Runs whatever .env.dev pins, on the dev host. To run new code: commit, then `make dev-deploy`
# (build + push :sha-<commit>, pin, restart). `make dev-pin TAG=…` rolls back to a published tag.
dev-up: ## Start the full dev stack on the dev host at the TAG pinned in .env.dev
	$(DEV_DC) up -d
	@echo "kasa-collector [dev] on $(DEV_HOST) — Grafana by its dev name through the dev host's edge (no host port)"

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

##@ Local — your real devices + bundled InfluxDB + Grafana on THIS machine (.env.local)

local-up: ## Start the collector + a bundled InfluxDB and Grafana here, at the TAG pinned in .env.local
	$(LOCAL_DC) up -d
	@echo "kasa-collector [local] — Grafana on the port set by GRAFANA_PORT in .env.local (default 3000)"

local-down: ## Stop the local stack (keep data volumes)
	$(LOCAL_DC) down

local-clean: ## Stop the local stack AND delete its data volumes
	$(LOCAL_DC) down -v

local-logs: ## Follow local stack logs
	$(LOCAL_DC) logs -f

local-ps: ## Local stack status
	$(LOCAL_DC) ps

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
	$(PROD_SSH) '$(PROD_REMOTE_DC) pull && $(PROD_REMOTE_DC) up -d'
	@printf "✓ deployed to $(PROD_NODE)\n"

prod-status: check-prod-node ## Container status on the node
	$(PROD_SSH) '$(PROD_REMOTE_DC) ps'

prod-logs-remote: check-prod-node ## Follow collector logs on the node
	$(PROD_SSH) '$(PROD_REMOTE_DC) logs --tail=100 -f'

prod-health: check-prod-node ## Run the in-container health check on the node
	$(PROD_SSH) '$(PROD_REMOTE_DC) exec -T kasa-collector python3 -m app.health.check'

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

# luxarch:guard-upgrade asset v7 - DO NOT edit this marker line; it is how repo.emitted_assets_current knows your copy is current. Re-emit with `luxarch --emit guard-upgrade`.
# Bumps each guard pin to its latest release and prints the rules the new luxarch adds (`--new-rules`).
# The preview mounts `$(CURDIR)`, this makefile's directory, whatever directory `make -C` ran from.
# Latest is the registry's `:latest`, or with REGISTRY empty (guards loaded from the release tarball)
# the highest released `<guard>:X.Y.Z` on this machine, never `:local`. The pin is rewritten with `sed`
# into a temporary file beside the Makefile (its mode copied first), renamed over it (`mv`, one atomic
# step: a failed write leaves the Makefile as it was), then read back: the same on macOS and Linux.
# A guard whose latest cannot be read, or whose `:latest` could not be pulled (a copy cached here may
# be behind), is named and fails the run: "all pins already at latest" is printed only when every
# guard was read. A guard's own repo builds that guard from its source and holds no pin for it:
# where a VERSION file sits beside a pyproject.toml whose [project] name is a guard's and that
# guard has no pin, it is skipped with one line saying so; a pin it does hold is bumped as anywhere.
# Anywhere else a missing pin fails the run.
guard-upgrade:  ## Bump every guard pin to the published latest (prints what newly bites)
	@unread=; checked=; bumped=; self=; \
	if [ -f VERSION ] && [ -f pyproject.toml ]; then self=$$(sed -n -E '/^\[project\][[:space:]]*$$/,/^\[/s/^name[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/p' pyproject.toml); fi; \
	for g in luxarch luxlint luxaudit; do \
	  var=$$(echo $$g | tr a-z A-Z)_VERSION; \
	  old=$$(sed -n -E "s/^$$var[[:space:]]*:=[[:space:]]*//p" Makefile); \
	  if [ -z "$$old" ] && [ -n "$$self" ] && [ "$$g" = "$$self" ]; then echo "$$g: this repo builds $$g from its own source (VERSION, pyproject.toml [project] name), so it holds no pin for it — skipped"; continue; fi; \
	  if [ -n "$(REGISTRY)" ]; then \
	    img=$(REGISTRY)/luxardolabs/$$g; src="$$img:latest"; \
	    if docker pull -q $$img:latest >/dev/null 2>&1; then latest=$$(docker run --rm $$img:latest --version 2>/dev/null | awk '{print $$2}'); \
	    else latest=; src="$$img:latest (the pull failed, and a copy cached here may be behind)"; fi; \
	  else \
	    img=$$g; src="a released $$g:X.Y.Z image on this machine (REGISTRY is empty)"; \
	    latest=$$(docker images --format '{{.Tag}}' $$g 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$$' | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1); \
	  fi; \
	  if [ -z "$$old" ]; then echo "!! no $$var pin found in Makefile — NOT bumped"; unread="$$unread $$g"; continue; fi; \
	  if [ -z "$$latest" ]; then echo "!! could not read $$src — $$var left at $$old"; unread="$$unread $$g"; continue; fi; \
	  checked=1; \
	  tmp=$$(mktemp ./.guard-upgrade.XXXXXX) && cp -p Makefile "$$tmp" && sed -E "s|^($$var[[:space:]]*:=[[:space:]]*).*|\\1$$latest|" Makefile > "$$tmp" && mv -f "$$tmp" Makefile; rc=$$?; \
	  if [ "$$rc" != 0 ]; then rm -f "$$tmp"; echo "!! could not rewrite Makefile (it is unchanged) — $$var NOT bumped"; exit 1; fi; \
	  new=$$(sed -n -E "s/^$$var[[:space:]]*:=[[:space:]]*//p" Makefile); \
	  if [ "$$new" != "$$latest" ]; then echo "!! $$var did NOT change (still $$new)"; exit 1; fi; \
	  if [ "$$old" != "$$latest" ]; then echo "$$var $$old -> $$latest"; bumped=1; fi; \
	  [ "$$g" = luxarch ] && [ "$$old" != "$$latest" ] && docker run --rm -v '$(subst ','\'',$(CURDIR))':/repo $$img:$$latest --new-rules --since $$old || true; \
	done; \
	if [ -n "$$bumped" ]; then echo "pins bumped — re-run make check"; fi; \
	if [ -z "$$checked" ]; then echo "!! could not read any guard's latest (the registry, or with REGISTRY empty this machine's released images) — NO pin was checked; currency NOT established"; exit 1; fi; \
	if [ -n "$$unread" ]; then echo "!! NOT checked:$$unread (no pin, or its latest could not be read) — currency NOT established"; exit 1; fi; \
	if [ -z "$$bumped" ]; then echo "all pins already at latest"; fi

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

# Test-block settings: the suite writes to a REAL InfluxDB (compose profile `test`), the one
# backing service the deployed stack runs (repo.test_stack_parity). conftest.py only fills
# Config defaults, so these reach the code under test.
TEST_SERVICES := kasa_test_influxdb
TEST_ENV := -e KASA_COLLECTOR_INFLUXDB_URL=http://kasa_test_influxdb:8086 \
            -e KASA_COLLECTOR_INFLUXDB_TOKEN=kasa-test-token \
            -e KASA_COLLECTOR_INFLUXDB_ORG=kasa -e KASA_COLLECTOR_INFLUXDB_BUCKET=kasa

# luxarch:test-block asset v16 - DO NOT edit this marker line; it is how repo.emitted_assets_current knows your copy is current. Re-emit with `luxarch --emit test-block`.
# ── Test: THE suite, in the test image, against an isolated stack of real services ───────────────
# Emitted by `luxarch --emit test-block`; paste below the build core (`luxarch --emit build-core`, v4:
# it builds with the core's `img_*` helpers and TEST_IMAGE, and the repo's BUILD_ARGS, and quotes every
# value it splices with the core's `sq` / `sqw`), and below the image block when the repo has one. v3
# needed the whole image block, so a repo whose images are built elsewhere had to carry a deploy lane
# that could not run there. Enforced by `repo.test_block_wired`.
# Settings are `?=` defaults: set them above this block. What the suite can see, and what only
# `make smoke` sees: --doc FLEET-MAKEFILE-STANDARD §1.
#
# Before this block every repo wrote its own `make test`: four repos, four ways (a lint image with
# the source mounted, the dev image with pytest pip-installed at run time, a repo script, a test
# image), each with its own readiness loop and coverage wiring, and a coverage pipe under make's
# /bin/sh that hid pytest's failure. This is the documented practice of the tools instead:
#   - ISOLATED STACK (Docker Compose): the backing services run in a compose project of their own,
#     one per run (`-p`), so parallel runs never collide, the suite cannot reach the dev database or
#     cache at all (it is on another network), and teardown (`down --volumes --remove-orphans`)
#     removes exactly this run's containers and data, pass or fail, never the dev stack.
#   - NO INTERNET (v16): the suite runs on a network of the run's own, `<project>-suite`, created
#     `--internal`: it has no route out of the docker host (the host's own listeners on that
#     network's bridge address stay reachable). Each container of the run's compose project joins it
#     under its service name, so the suite reaches its services: a test that loads a page cannot call
#     a real third-party API, and its result never depends on one. v15 ran the suite on the compose
#     project's network, which had egress, and a suite with no services on docker's default bridge,
#     which had it too. There is no egress opt-in yet: a suite that needs the internet fails, and
#     its FAIL says so. TEST_ENV is the suite's environment and nothing else: `-e NAME=value`,
#     `--env NAME=value` and `--env-file <file>` (or their `=` forms); any other word is refused,
#     since a docker option could join another network or reach the host. A bare `-e NAME` (which
#     copies NAME from the caller's environment) is refused, and so is an `--env-file` holding a
#     `$`, or outside the checkout: the suite gets only values this repository holds.
#   - READINESS from each service's own compose healthcheck (`up --wait`), not a sleep or a loop:
#     the service declares when it is ready. For Postgres, probe over TCP with the real role
#     (`pg_isready -h 127.0.0.1 -U <user> -d <db>`); over the socket it answers while initdb's
#     temporary server is still up. `repo.test_stack_parity` checks these are the services prod runs.
#   - THE TEST SERVER IS MARKED (v10). Once its services are healthy, the run creates the role
#     `luxarch_test_server_<run token>` (NOLOGIN) on each of TEST_SERVICES running a Postgres server
#     (a container with no shell is skipped), from inside that server's own container (`compose
#     exec`, psql over the server's own socket as $POSTGRES_USER, with $POSTGRES_PASSWORD, the
#     container's PG* client settings dropped; only where the server's postmaster.pid names a
#     postgres process of that container, and refused unless the server psql reaches holds that
#     same postmaster.pid), and hands the token to the suite as LUXARCH_TEST_RUN. It refuses, and
#     fails the run, to mark a server whose data or socket directory (as written, and as the
#     container resolves it) is a mount that is not the run's own (a bind mount; a volume with
#     another driver, or driver options such as a bind `device`; a volume that is neither this
#     compose project's nor an anonymous one no other container uses), or whose pid namespace is
#     shared: that server's data outlives
#     the run, or is another server's. The test-db-bound block asks every Postgres connection for
#     that role before it lets anything through: TEST_DATABASE_URL's text does not say where the
#     driver lands (a query `host`, a `hostaddr`, PGHOSTADDR or a service file send it elsewhere),
#     production never has the role, and another run's server, or a marker left on storage that
#     outlived its run, has another name. A service running Postgres that cannot be marked fails
#     the run.
#   - THE TEST-DB-BOUND PLUGIN runs in every process of the run. When TEST_WORKDIR holds the package
#     `luxarch_test_db/` (the test-db-bound block's, `luxarch --emit test-db-bound --update
#     conftest.py`), the suite's run loads it with `-p luxarch_test_db.identity -p
#     luxarch_test_db.bound` (LUXARCH_TEST_DB_SCOPE=suite), and the migration tests' run with `-p
#     luxarch_test_db.identity` (LUXARCH_TEST_DB_SCOPE=server: any database, on a server this run
#     marked). Both put `luxarch_test_db/children` first on PYTHONPATH, before the image's own
#     value: its `sitecustomize` installs the identity check in every Python process the run starts
#     (a spawn or forkserver child, an alembic subprocess, an xdist worker), and no bytecode is read
#     from the checkout (PYTHONPYCACHEPREFIX): a committed `.pyc` would stand in for its source. PYTEST_ARGS holding
#     `--noconftest`, `--confcutdir`, a `@file` of arguments, or a `luxarch_test_db` plugin name is
#     refused: each would run the suite without the block's conftest or its plugin.
#   - Ctrl-C (or a SIGTERM) stops the suite, in any step (v3). `--init`'s tini forwards a signal to
#     its own child only, which is the `sh` running pytest, so v2's Ctrl-C let a 60-second suite run
#     to its end (measured: 58s). `TINI_KILL_PROCESS_GROUP=1` makes tini signal the whole group. Each
#     docker step runs in the background while the shell waits on it, so the trap runs at once: it
#     records the signal, sends SIGTERM to the step's whole process tree, and the run exits 130
#     (INT) or 143 (TERM) with no later suite started; a SIGTERM sent to make alone reaches the suite
#     the same way. A suite that exits 128+ by itself is a failed suite, not a stopped run. A shell
#     started with SIGINT ignored (`make test &` from a script, `nohup`) cannot see a Ctrl-C at all:
#     stop such a run with SIGTERM.
#   - LEFTOVERS: every image and container a run makes is labelled `luxarch.test-block=1` with its
#     run token, its shell's PID and PID namespace, this host's machine id and boot id, and this
#     checkout's path. `make test` first runs `make test-reap`, which removes only what proves it is
#     this checkout's, on this host, from this PID namespace, and from a run whose shell is gone;
#     anything else is listed and left alone (`make test-reap FORCE=1` also removes this checkout's
#     leftovers that cannot be proved dead, never a run proved alive). Teardown is retried until no network or volume of the run's project
#     remains, the image goes only then, and a stack that will not come down fails the suite.
#   - THE TEST IMAGE built from this source, the image's `test` stage (its `--with dev` stage), once
#     PER RUN under a tag of the run's own (v3): `<TEST_IMAGE>-<run token>`, removed when the run
#     ends. v2 ran the shared `<repo>:test`, so another checkout of the same repo building it between
#     this run's build and its `docker run` ran this suite in THAT tree's image (measured). The fleet's
#     pytest config (`luxlint --emit-config pytest`: -ra, strict markers and config, warnings are
#     errors). The source is mounted read-only and pytest writes no cache into it.
#   - THE RUN'S FILES stay private (v2): the run's directory keeps mktemp's 700, so no other local
#     user can reach the config pytest loads (a config can load plugins, in a container holding the
#     repo and the suite's credentials). Inside it, `cfg/` is 711 and each suite's `out-<suite>/` is
#     733: the image's non-root user, whatever its uid, can open the config by name and write its
#     coverage data, and nothing more. Measured: the container reaches a bind mount without the host
#     path above it, and a narrower out dir (711, 730, 755) fails coverage's write.
#   - COVERAGE with coverage.py itself, not pytest-cov: `coverage run --branch` under the sysmon
#     core (fast branch coverage on Python 3.14), then `coverage report --precision=2` and
#     `coverage json` judged by `luxlint --coverage-ratchet` against the floor, `[test].coverage_min`
#     (it only ratchets up). v3 reports two decimals and feeds the json's exact totals: at coverage's
#     default of none, a true 89.5-89.99% printed as `90%` and passed a floor of 90, and any printed
#     figure can round up onto it. A listed suite's floor file must set `coverage_min` (a ratchet
#     that runs OFF fails that suite). `coverage` belongs in the dev dependency group.
#   - TEST_ENV is words, each passed to docker as it is (v3, quoted with `sqw`): a word that holds a
#     quote, a `$`, a backslash or a backtick no longer means what v2's shell made of it (`-e X="quoted"` now sets X to
#     `"quoted"` with the quotes, `-e H=$$HOME` sets H to `$HOME`, not the host's home, and
#     `-e 'J={"a": 1}'` does not parse). `repo.test_block_wired` reds such a word: put that variable
#     in an `--env-file` that git tracks (`TEST_ENV := --env-file test-suite.env`: the fleet's
#     `.env.*` ignore patterns would keep `.env.test-suite` out of every clone).
#   - BOTH EXIT CODES reach make: pytest's and the ratchet's. No pipe carries either. The ratchet
#     reads coverage's own report file, never the suite's output (a printed `TOTAL … 100%` or
#     pytest's `[100%]` would otherwise pass for a measurement), and a report that measured nothing
#     fails.
#   - SEVERAL SUITES (v3), for a monorepo whose apps cannot share one pytest run (each its own
#     package root, dependency lock and image): `TEST_SUITES := backend agent` runs each in turn, in
#     its own image, stack and coverage floor, and `make test` fails when any one fails (all of them
#     run, so you see every failure). Empty, the default, is the one suite, exactly as before.
#   - THE ENV FILE compose interpolates with is one every checkout has (v4): TEST_ENV_FILE defaults to
#     `test-suite.env`, then `.env.example`, both committed. v3 took the first of `.env.test`,
#     `.env.dev` and `.env.example`, and the first two are ignored by the fleet's `.env.*` pattern:
#     the main checkout used its own `.env.test` while an issue worktree or a fresh clone fell back to
#     `.env.example`, silently, and its suite died on compose interpolation. A TEST_ENV_FILE that does
#     not exist refuses, naming it; `repo.test_block_wired` reds one git does not track.
#     Empty (neither file exists), compose gets `--env-file /dev/null`: its implicit `.env` is a
#     file one checkout has and another does not.
#   - MIGRATION TESTS run as a second pytest run of the same suite, in the same container, image,
#     stack and coverage (v5). A migration test builds a database of its own at an older revision
#     (`CREATE DATABASE` through the server's maintenance database, `alembic upgrade <parent>`, seed,
#     upgrade) and runs what a migration really runs, `CREATE INDEX CONCURRENTLY` among it: the
#     test-db-bound block refuses both, by design, so these tests cannot run under it. TEST_MIGRATIONS
#     names their directory (`tests/migrations`, its last part `migrations`): the main run ignores it
#     (`--ignore`), and it runs alone with `--confcutdir` set to it, so no conftest above it, the
#     block's included, is loaded; its own conftest.py builds and drops its databases. The
#     test-db-bound plugin's identity check still runs there (above). A one-off
#     PYTEST_ARGS narrows the main run only: a path in it would otherwise run outside the block. Coverage
#     appends both runs, and `make test` fails when either fails. Layout: `luxarch --playbook
#     test-isolation`, "Migration tests".
#   - A NARROWED RUN, `make test-fast PYTEST_ARGS='tests/test_orders.py -k refund'` (v6), is `make test`
#     with the same isolation (its own image tag, compose project, labels and reaping, so concurrent
#     checkouts and agents never share a stack or an image) and no coverage verdict: the ratchet
#     judges the whole floor, so a narrowed run would always fail it, and the migration tests' own
#     run is skipped. Only `make test` judges the floor; the check gate runs it. The recipe reads
#     the goals make sets from its own command line (MAKECMDGOALS at origin `default`), inline, with
#     no variable of its own: a makefile, environment, target- or pattern-specific value, or a
#     MAKEOVERRIDES word handed to a sub-make keeps the ratchet on, and `make test test-fast` runs it.
#   - A HEAVY-JOB SLOT (v12): `make test` holds one of the machine's HEAVY_SLOTS (the guard-run
#     block's `guard_slot`, v4) for the whole run, and waits, saying so, while they are all taken. A
#     narrowed `make test-fast PYTEST_ARGS=<…>` takes none; inside `make check`, which holds one, the
#     suite runs in the gate's slot. Any PYTEST_ARGS that is not blank counts as
#     narrowing (`PYTEST_ARGS=tests/` too); a blank one takes a slot.
#   - THE [shared] OVERLAY (v7). A repo declaring `[shared]` keeps 0-byte placeholders in each app
#     that the real shared code is mounted over; the suite runs from the read-only `/repo` mount, so
#     it imports the placeholders unless the overlay is mounted there too. TEST_MOUNTS
#     (`<suite>_TEST_MOUNTS`) is that overlay: `-v <host path>:<path under /repo/<workdir>>[:ro]`
#     pairs, which luxlint emits as `$(call shared_overlay,/repo/<workdir>/app)` (`luxlint
#     --emit-shared-overlay`). The overlaid code is another package's, so it counts in ONE ratchet:
#     every suite leaves its overlay out of its coverage (`coverage run --omit`), except the suite
#     holding the shared tests, which sets `<suite>_TEST_OVERLAY_COV := 1` and measures it. Its
#     mounts land under a package its TEST_COV names (a directory under the workdir, or a package
#     name such as `mypkg` in a src layout). Coverage walks a package only through directories
#     holding an `__init__.py`, so every directory from that package down to the mount, and every
#     directory of the host path that holds code, holds one, and the host path exists. A mount
#     replaces a PLACEHOLDER only: a 0-byte file, or a package holding an empty `__init__.py` and
#     no other .py or .pyw, never a symlink. A mount over code with content would hide that code
#     from the suite's coverage. The run refuses an overlay no suite measures, and one two suites measure
#     (host paths compared as the files they are). It also refuses a pair outside that shape, a
#     path holding anything but letters, digits and `._/@+-` or a `..` part (make resolves
#     `link/..` after the symlink, docker as text), and a placeholder this checkout lacks (docker
#     cannot make a mount point inside the read-only mount). Both paths are read as docker reads
#     them: repeated slashes, `.` parts and a trailing slash dropped (luxlint's map writes
#     `$(SHARED_HOST)/.` when the whole shared directory is the overlay). Make compares the host paths on this machine, so
#     a DOCKER_HOST on another machine is outside what the run can check.
#   - Each run's project is named from its own `mktemp -d` token, and refuses to run without one (a
#     PID repeats across containers and CI runners), and everything mounts the makefile's directory
#     ($(CURDIR)), so `make -C` runs the right suite.

# Setting: the compose command, and the profile holding the test services --------------------
TEST_COMPOSE ?= docker compose
TEST_PROFILE ?= test
# Setting: the env file compose interpolates the file with (it reads EVERY service, so an app
# service's `${TAG:?}` needs a value even when only the test services start). A committed file: put
# the test run's values in `test-suite.env` (no `.env.*` ignore pattern matches it) ---------------
TEST_ENV_FILE ?= $(firstword $(wildcard test-suite.env .env.example))
# Setting: the backing services the suite needs (each with a healthcheck); empty: none -----------
TEST_SERVICES ?= db-test
# Setting: the suite's environment: the test services' URLs, by service name on the test network -
TEST_ENV ?= -e TEST_DATABASE_URL=postgresql+asyncpg://postgres:postgres@db-test:5432/postgres
# Setting: where the suite runs from (a monorepo's apps/backend), and every package coverage
# measures, comma-separated (`app,collector`): it replaces any [tool.coverage.run] source ---------
TEST_WORKDIR ?= .
TEST_COV ?= app
# Setting: the luxlint key whose `[test].coverage_min` is the suite's floor, from this directory -
TEST_FLOOR ?= .luxlint.toml
# Setting: the suites, for a monorepo whose apps each have their own package root (v3). Empty: ONE
# suite, set by the TEST_* settings above. Each name is an image's settings name, as in the image
# block's IMAGES: its test image is the `test` stage of `<name>_DOCKERFILE` in `<name>_BUILD_CONTEXT`,
# tagged from `<name>_IMAGE_NAME`. A suite's own settings are `<name>_TEST_SERVICES`, `_TEST_ENV`,
# `_TEST_WORKDIR`, `_TEST_COV`, `_TEST_FLOOR`, `_TEST_MIGRATIONS`, `_TEST_MOUNTS`,
# `_TEST_OVERLAY_COV`; one it leaves unset is the TEST_* value. Every
# suite has a floor of its own: the run refuses two that name the same file. For example
#   TEST_SUITES          := backend agent
#   backend_TEST_WORKDIR := apps/backend
#   agent_TEST_WORKDIR   := apps/agent
#   agent_TEST_SERVICES  :=
#   agent_TEST_ENV       :=
#   agent_TEST_FLOOR     := apps/agent/.luxlint.toml
TEST_SUITES ?=
# Setting: the migration tests' directory, from TEST_WORKDIR (`tests/migrations`), run on their own
# outside the test-db-bound block (v5); empty: none. A listed suite's is `<suite>_TEST_MIGRATIONS` ---
TEST_MIGRATIONS ?=
# Setting: the [shared] overlay mounted over the suite's placeholders, `-v <host>:<container>[:ro]`
# pairs inside /repo/<workdir> (`$(call shared_overlay,/repo/apps/backend/app)`); empty: none -----
TEST_MOUNTS ?=
# Setting: 1 on the ONE suite whose ratchet measures the overlay (it holds the shared tests); every
# other suite leaves its overlay out of its coverage --------------------------------------------
TEST_OVERLAY_COV ?=
# Setting: NONE. For a one-off run only, on the command line: `make test-fast PYTEST_ARGS='-k orders'`.
# A committed value narrows THE suite for everyone (`repo.test_block_wired` reds one). The ratchet
# judges the whole floor, so a narrowed `make test` measures only what it touched and fails it:
# `make test-fast` runs the narrowed suite the same isolated way, without the ratchet ------------
PYTEST_ARGS ?=

# One-off pytest arguments reach the container through the environment, never spliced into a quoted
# command line (`-k 'a or b'` would otherwise split it).
export PYTEST_ARGS

# The suites the run walks: `-` is the one suite of TEST_SUITES empty. `$(call test_suite_var,<suite>,<X>)`
# names the variable a suite's setting comes from: `-`'s is TEST_<X> itself, a listed suite's is
# `<suite>_TEST_<X>` when it is set (even to nothing), else TEST_<X>; `test_suite` is its value.
# `$(call test_suite_image,<suite>)` names its image's settings for the image block's `img_*` helpers
# (`-`: the first image, or the one image). Every value the recipe splices goes through the image
# block's `sq`/`sqw` (v17), so a value is one shell word and never runs as a command. A floor is
# compared as the file it is (`realpath`), so two names of one file are one floor.
test_suites = $(or $(strip $(TEST_SUITES)),-)
test_suite_var = $(if $(filter -,$(1)),TEST_$(2),$(if $(filter undefined,$(origin $(1)_TEST_$(2))),TEST_$(2),$(1)_TEST_$(2)))
test_suite = $($(call test_suite_var,$(1),$(2)))
test_suite_image = $(if $(filter -,$(1)),$(IMAGE_PRIMARY),$(1))
test_suite_floors = $(foreach s,$(test_suites),$(or $(realpath $(call test_suite,$(s),FLOOR)),$(abspath $(call test_suite,$(s),FLOOR))))
# The overlay's host paths a suite mounts (v7), and over every suite those measured (OVERLAY_COV 1)
# and those left out: each left out must be measured, and by one suite. A NARROWED run (`test-fast`,
# or TEST_SUITES given on the command line or in the environment) may leave out the suite that
# measures it, so it is not asked whether the overlay is measured; two suites measuring one overlay
# is wrong on any run.
test_suite_mount_srcs = $(sort $(foreach w,$(filter-out -v,$(call test_suite,$(1),MOUNTS)),$(foreach h,$(firstword $(subst :, ,$(w))),$(or $(realpath $(h)),$(abspath $(h))))))
test_overlay_measured = $(foreach s,$(test_suites),$(if $(filter 1,$(call test_suite,$(s),OVERLAY_COV)),$(call test_suite_mount_srcs,$(s))))
test_overlay_unmeasured = $(filter-out $(test_overlay_measured),$(foreach s,$(test_suites),$(if $(filter 1,$(call test_suite,$(s),OVERLAY_COV)),,$(call test_suite_mount_srcs,$(s)))))
test_suites_narrowed = $(or $(filter test-fast,$(MAKECMDGOALS)),$(filter command line environment override,$(origin TEST_SUITES)))

# LEFTOVERS. Every image and container a run makes is labelled `luxarch.test-block=1`, with its run
# token, its shell's PID and PID namespace, this host's machine id (/etc/machine-id; IOPlatformUUID
# on macOS; the hostname only when neither exists) and boot id, its hostname, and this checkout's
# path; its run directory holds the same in an `owner` file. `make test` first runs `test-reap`,
# which removes only what PROVES it is this checkout's on this host (the machine id: one path can be
# two hosts' checkouts on a shared filesystem, and two hosts can share a docker daemon) and dead:
# from an earlier boot of this host (a reboot, a crash mid-run), or from this PID namespace with a
# shell `kill -0` reports gone ("No such process"). It removes its containers and image (tagged or
# not), its compose project's containers, networks and volumes (a project only when its name is
# `t…-test-<that object's own run token>[-<suite>]`), and its run directory. Anything else labelled
# `luxarch.test-block=1` is listed and left alone. `make test-reap FORCE=1` also removes this
# checkout's leftovers on this host that cannot be proved dead (another PID namespace), but never a
# run `kill -0` proves alive in this one.
test-reap: ## Remove what a dead `make test` of THIS checkout on this host left (FORCE=1: also what cannot be proved dead, never a live run)
	@$(if $(and $(value sq),$(value sqw),$(value img_test)),,$(error REFUSING: the test block builds with the build core's image helpers and quotes every value it splices with its sq and sqw, which this makefile does not define. Paste the build core above it: luxarch --emit build-core))set -u; set -f; \
	co=$(call sq,$(CURDIR)); ns=$$(readlink /proc/self/ns/pid 2>/dev/null || echo none); host=$$(hostname); \
	machine=$$(cat /etc/machine-id 2>/dev/null); [ -n "$$machine" ] || machine=$$(ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null | sed -n 's/.*"IOPlatformUUID" = "\([^"]*\)".*/\1/p'); [ -n "$$machine" ] || machine=$$host; \
	boot=$$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || sysctl -n kern.bootsessionuuid 2>/dev/null || echo "$$machine"); \
	force=$(call sq,$(if $(filter test-reap,$(MAKECMDGOALS)),$(FORCE))); [ "$$force" = 1 ] || force=; \
	dead() { case "$$1" in ''|*[!0-9]*) return 1;; esac; case "$$(LC_ALL=C kill -0 "$$1" 2>&1)" in *[Nn]o\ such\ process*) return 0;; esac; return 1; }; \
	alive() { case "$$1" in ''|*[!0-9]*) return 1;; esac; ! dead "$$1"; }; \
	may() { [ "$$4" = "$$co" ] && [ "$$6" = "$$machine" ] || return 1; [ "$$5" = "$$boot" ] || return 0; \
	  if [ "$$2" = "$$ns" ]; then dead "$$1" && return 0; [ -n "$$force" ] && ! alive "$$1"; else [ -n "$$force" ]; fi; }; \
	lab() { docker inspect -f "{{index .Config.Labels \"luxarch.test-block.$$1\"}}" "$$2" 2>/dev/null; }; \
	gone=; kept=; \
	for x in $$(docker ps -aq --filter label=luxarch.test-block=1 | sed 's/^/c:/'; docker images -a -q --filter label=luxarch.test-block=1 | sed 's/^/i:/'); do \
	  k=$${x%%:*}; id=$${x#*:}; \
	  if may "$$(lab pid "$$id")" "$$(lab pidns "$$id")" - "$$(lab checkout "$$id")" "$$(lab boot "$$id")" "$$(lab machine "$$id")"; then \
	    run=$$(lab run "$$id"); proj=$$(lab project "$$id"); \
	    case "$$run" in ''|*[!a-z0-9]*) run=; proj=;; esac; \
	    case "$$proj" in t*-test-"$$run"|t*-test-"$$run"-*) ;; *) proj=;; esac; \
	    if [ -n "$$proj" ]; then \
	      for c in $$(docker ps -aq --filter "label=com.docker.compose.project=$$proj"); do docker rm -fv "$$c" >/dev/null 2>&1; done; \
	      for n in $$(docker network ls -q --filter "label=com.docker.compose.project=$$proj"); do docker network rm "$$n" >/dev/null 2>&1; done; \
	      for v in $$(docker volume ls -q --filter "label=com.docker.compose.project=$$proj"); do docker volume rm "$$v" >/dev/null 2>&1; done; fi; \
	    if [ "$$k" = c ]; then docker rm -fv "$$id" >/dev/null 2>&1; else \
	      [ -z "$$run" ] || for c in $$(docker ps -aq --filter "label=luxarch.test-block.run=$$run" --filter "label=luxarch.test-block.checkout=$$co"); do docker rm -fv "$$c" >/dev/null 2>&1; done; \
	      docker rmi -f "$$id" >/dev/null 2>&1; fi; gone="$$gone $$id"; \
	  else kept="$$kept $$id"; fi; done; \
	set +f; for d in "$${TMPDIR:-/tmp}"/luxarch-test.*; do \
	  [ -d "$$d" ] && [ -O "$$d" ] && [ -f "$$d/owner" ] || continue; \
	  opid=; ons=; oco=; oboot=; omachine=; { read -r opid; read -r ons; read -r oco; read -r oboot; read -r omachine; } < "$$d/owner"; \
	  if may "$$opid" "$$ons" - "$$oco" "$$oboot" "$$omachine"; then rm -rf "$$d"; gone="$$gone $${d##*/}"; fi; done; set -f; \
	[ -z "$$gone" ] || printf 'test-reap: removed what a dead run of this checkout left%s:%s\n' "$${force:+ (FORCE)}" "$$gone"; \
	[ -z "$$kept" ] || printf 'test-reap: leftovers from other runs, left alone:%s (their own checkout'"'"'s make test-reap removes a dead run'"'"'s; FORCE=1 there also what cannot be proved dead)\n' "$$kept"

# How the run stops (v3). Every docker step runs in the background and the shell WAITS for it, so a
# signal runs the trap at once, whatever the step does with its own copy; the trap records it in a
# sticky file and sends SIGTERM to the step's whole process tree (`docker compose` runs its plugin as
# a child, which the CLI does not pass a SIGTERM to), and nothing starts after it: the run exits 130
# (INT) or 143 (TERM) and no later suite begins. A SIGTERM sent to make alone reaches the suite the
# same way. Only that stop file says the run was stopped: a suite that exits 128+ by itself is a
# failed suite, and the next suite still runs.
test: test-reap ## THE suite (each of TEST_SUITES in turn): its own test image, an isolated stack of real services, coverage ratchet
	@$(if $(and $(value sq),$(value sqw),$(value img_test)),,$(error REFUSING: the test block builds with the build core's image helpers and quotes every value it splices with its sq and sqw, which this makefile does not define. Paste the build core above it: luxarch --emit build-core))set -u; set -f; \
	co=$(call sq,$(CURDIR)); ns=$$(readlink /proc/self/ns/pid 2>/dev/null || echo none); host=$$(hostname); \
	machine=$$(cat /etc/machine-id 2>/dev/null); [ -n "$$machine" ] || machine=$$(ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null | sed -n 's/.*"IOPlatformUUID" = "\([^"]*\)".*/\1/p'); [ -n "$$machine" ] || machine=$$host; \
	boot=$$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || sysctl -n kern.bootsessionuuid 2>/dev/null || echo "$$machine"); \
	$(if $(value guard_slot),,$(error REFUSING: the suite holds a heavy-job slot from the guard-run block (v4), which this makefile does not define: paste luxarch --emit guard-run above it))$(if $(value guard_caps),,$(error REFUSING: the suite runs under the guard-run block's memory and CPU caps (v6), which this makefile does not define: re-emit luxarch --emit guard-run above it))if [ -n $(call sq,$(if $(filter default,$(origin MAKECMDGOALS)),$(if $(filter test,$(MAKECMDGOALS)),,$(if $(filter test-fast,$(MAKECMDGOALS)),1)))) ] && case "$${PYTEST_ARGS:-}" in (*[![:space:]]*) true;; (*) false;; esac; then :; else $(guard_slot); fi; \
	D=$$(mktemp -d "$${TMPDIR:-/tmp}/luxarch-test.XXXXXXXXXXXX") || { echo "REFUSING: could not make this run's directory"; exit 2; }; \
	tok=$$(basename "$$D" | sed 's/^luxarch-test\.//' | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9'); \
	[ $${#tok} -ge 8 ] || { echo "REFUSING: could not make a unique name for this run"; rm -rf "$$D"; exit 2; }; \
	printf '%s\n%s\n%s\n%s\n%s\n' "$$$$" "$$ns" "$$co" "$$boot" "$$machine" > "$$D/owner" || { rm -rf "$$D"; exit 2; }; \
	[ -z $(call sq,$(TEST_ENV_FILE)) ] || [ -f $(call sq,$(TEST_ENV_FILE)) ] || { printf 'REFUSING: TEST_ENV_FILE is %s, which this checkout does not have: compose would fail on interpolation. Commit it (test-suite.env), or set TEST_ENV_FILE to a committed file\n' $(call sq,$(TEST_ENV_FILE)); rm -rf "$$D"; exit 2; }; \
	[ $(words $(test_suite_floors)) = $(words $(sort $(test_suite_floors))) ] || { printf 'REFUSING: two suites would share one coverage floor (%s): give each its own <suite>_TEST_FLOOR\n' $(call sq,$(foreach s,$(test_suites),$(s)=$(call test_suite,$(s),FLOOR))); rm -rf "$$D"; exit 2; }; \
	[ -z $(call sq,$(findstring %,$(foreach s,$(test_suites),$(call test_suite,$(s),MOUNTS)))) ] || { echo 'REFUSING: a TEST_MOUNTS path holds %, which make reads as a pattern: each path is letters, digits and ._/@+-'; rm -rf "$$D"; exit 2; }; \
	[ -n $(call sq,$(strip $(test_suites_narrowed))) ] || [ -z $(call sq,$(strip $(test_overlay_unmeasured))) ] || { printf 'REFUSING: no suite measures the overlay %s, and every suite mounting it leaves it out of its coverage: set <suite>_TEST_OVERLAY_COV := 1 on the suite holding its tests\n' $(call sq,$(strip $(test_overlay_unmeasured))); rm -rf "$$D"; exit 2; }; \
	[ $(words $(test_overlay_measured)) = $(words $(sort $(test_overlay_measured))) ] || { printf 'REFUSING: two suites measure one overlay (%s): it counts in one ratchet, so set <suite>_TEST_OVERLAY_COV := 1 on one suite only\n' $(call sq,$(strip $(test_overlay_measured))); rm -rf "$$D"; exit 2; }; \
	case "$${PYTEST_ARGS:-}" in (*noconftest*|*confcutdir*|*luxarch_test_db*|@*|*[[:space:]=]@*) printf 'REFUSING: PYTEST_ARGS is %s: --noconftest, --confcutdir, a @file of arguments or a luxarch_test_db plugin name runs the suite without the test-db-bound block'"'"'s conftest or plugin, which judge where it connects\n' "$$PYTEST_ARGS"; rm -rf "$$D"; exit 2;; esac; \
	stop="$$D/stop"; kid=; insuite=; fast=$(if $(filter default,$(origin MAKECMDGOALS)),$(if $(filter test,$(MAKECMDGOALS)),,$(if $(filter test-fast,$(MAKECMDGOALS)),1))); \
	kids() { p=$$1; if command -v pgrep >/dev/null 2>&1; then pgrep -P "$$p"; else set +f; for f in /proc/[0-9]*/stat; do read -r l < "$$f" 2>/dev/null || continue; set -- $${l##*)}; [ "$${2:-}" = "$$p" ] && { c=$${f#/proc/}; echo "$${c%/stat}"; }; done; set -f; fi; }; \
	tree() { for c in $$(kids "$$1"); do tree "$$c"; done; kill -TERM "$$1" 2>/dev/null; }; \
	trap 'trap "" HUP INT TERM; rm -rf "$$D"' EXIT; \
	trap 'echo 130 > "$$stop"; [ -z "$$kid" ] || { [ -n "$$insuite" ] && kill -TERM "$$kid" 2>/dev/null || tree "$$kid"; }' INT; \
	trap 'echo 143 > "$$stop"; [ -z "$$kid" ] || { [ -n "$$insuite" ] && kill -TERM "$$kid" 2>/dev/null || tree "$$kid"; }' TERM; \
	halt() { [ ! -s "$$stop" ] || exit "$$(cat "$$stop")"; }; \
	bg() { "$$@" & kid=$$!; while wait "$$kid"; r=$$?; kill -0 "$$kid" 2>/dev/null; do :; done; kid=; halt; return "$$r"; }; \
	bgin() { f=$$1; shift; "$$@" < "$$f" & kid=$$!; while wait "$$kid"; r=$$?; kill -0 "$$kid" 2>/dev/null; do :; done; kid=; halt; return "$$r"; }; \
	lab="--label luxarch.test-block=1 --label luxarch.test-block.run=$$tok --label luxarch.test-block.pid=$$$$ --label luxarch.test-block.pidns=$$ns --label luxarch.test-block.boot=$$boot --label luxarch.test-block.machine=$$machine --label luxarch.test-block.host=$$host"; \
	run=t$$(printf '%s' $(call sq,$(notdir $(CURDIR))) | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '-')-test-$$tok; \
	mkdir "$$D/cfg" && chmod 711 "$$D/cfg" || exit 2; \
	bg docker run --rm --init $$lab --label "luxarch.test-block.checkout=$$co" -v $(call sq,$(CURDIR)):/repo $(call sq,$(LUXLINT)) --emit-config pytest > "$$D/cfg/pytest.ini" || exit 2; \
	chmod 644 "$$D/cfg/pytest.ini"; failed=; \
	$(foreach s,$(test_suites),insuite=1; ( \
	  p="$$run"$(if $(filter -,$(s)),,-$$(printf '%s' $(call sq,$(s)) | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '-')); out="$$D/$$p"; \
	  img=$(call sq,$(call img_test,$(call test_suite_image,$(s))))-"$$tok"; \
	  dc() { $(call sqw,$(TEST_COMPOSE)) -p "$$p" --env-file $(call sq,$(or $(TEST_ENV_FILE),/dev/null)) --profile $(call sq,$(TEST_PROFILE)) "$$@"; }; \
	  trap 'trap "" HUP INT TERM; ok=; for t in 1 2 3; do ( trap - HUP INT TERM; dc down --volumes --remove-orphans ) >/dev/null 2>&1; ( trap - HUP INT TERM; exec docker network rm "$$p-suite" ) >/dev/null 2>&1; [ -z "$$(trap - HUP INT TERM; docker network ls -q --filter "label=com.docker.compose.project=$$p"; docker volume ls -q --filter "label=com.docker.compose.project=$$p")" ] && { ok=1; break; }; done; if [ -n "$$ok" ]; then ( trap - HUP INT TERM; exec docker rmi -f "$$img" ) >/dev/null 2>&1; else printf "FAIL  the test stack %s did not come down (its networks or volumes remain): make test-reap removes it once they are free\n" "$$p"; exit 1; fi' EXIT; \
	  trap '[ -z "$$kid" ] || tree "$$kid"' TERM; \
	  mkdir "$$out" && chmod 733 "$$out" || exit 2; \
	  mig=$(call sq,$(call test_suite,$(s),MIGRATIONS)); mig=$${mig%/}; \
	  if [ -n "$$mig" ]; then case "/$$mig/" in (//*|*/../*|*/./*) mig=;; esac; case "$$mig" in (migrations|*/migrations) ;; (*) mig=;; esac; \
	    [ -n "$$mig" ] && [ -d $(call sq,$(CURDIR)/$(call test_suite,$(s),WORKDIR))/"$$mig" ] \
	      || { printf 'REFUSING: %s is %s: name the directory of the migration tests under %s, its last part migrations (tests/migrations)\n' $(call sq,$(call test_suite_var,$(s),MIGRATIONS)) $(call sq,$(call test_suite,$(s),MIGRATIONS)) $(call sq,$(call test_suite,$(s),WORKDIR)); exit 2; }; fi; \
	  wd=$$(printf '%s\n' /repo/$(call sq,$(call test_suite,$(s),WORKDIR)) | sed -e 's#//*#/#g' -e ':a' -e 's#/\./#/#' -e 'ta' -e 's#/\.$$##' -e 's#/$$##'); own=$(call sq,$(filter 1,$(call test_suite,$(s),OVERLAY_COV))); mnt=; omit=; set -- $(call sqw,$(call test_suite,$(s),MOUNTS)); \
	  while [ $$# -gt 0 ]; do \
	    m=$${2:-}; src=$${m%%:*}; dst=$${m#*:}; opt=$${dst#*:}; [ "$$opt" != "$$dst" ] || opt=; dst=$${dst%%:*}; \
	    src=$$(printf '%s\n' "$$src" | sed -e 's#//*#/#g' -e ':a' -e 's#/\./#/#' -e 'ta' -e 's#/\.$$##' -e 's#\(.\)/$$#\1#'); \
	    dst=$$(printf '%s\n' "$$dst" | sed -e 's#//*#/#g' -e ':b' -e 's#/\./#/#' -e 'tb' -e 's#/\.$$##' -e 's#\(.\)/$$#\1#'); bad=; \
	    [ "$$1" = -v ] || bad=1; case "$$opt" in (''|ro) ;; (*) bad=1;; esac; case "$$src$$dst" in (*[!A-Za-z0-9._/@+-]*) bad=1;; esac; \
	    case "$$src" in (/*) ;; (*) bad=1;; esac; case "$$dst/" in ("$$wd"/?*/) ;; (*) bad=1;; esac; case "/$$src/ /$$dst/" in (*/../*) bad=1;; esac; \
	    [ -z "$$bad" ] || { printf 'REFUSING: %s takes -v <host path>:<path under %s>[:ro] pairs, each path of letters, digits and ._/@+- (the [shared] overlay: $$(call shared_overlay,%s/app)); %s %s is not one\n' $(call sq,$(call test_suite_var,$(s),MOUNTS)) "$$wd" "$$wd" "$$1" "$$m"; exit 2; }; \
	    ph=$(call sq,$(CURDIR))/"$${dst#/repo/}"; \
	    [ -e "$$ph" ] || [ -L "$$ph" ] || { printf 'REFUSING: %s mounts over %s, which this checkout does not have: docker cannot make a mount point inside the read-only /repo. Commit the placeholder (a directory: an empty __init__.py in it, as git keeps no empty directory)\n' $(call sq,$(call test_suite_var,$(s),MOUNTS)) "$${dst#/repo/}"; exit 2; }; \
	    if [ ! -L "$$ph" ] && { { [ -f "$$ph" ] && [ ! -s "$$ph" ]; } || { [ -d "$$ph" ] && [ -f "$$ph/__init__.py" ] && [ -z "$$(find "$$ph" \( -name '*.py' -o -name '*.pyw' \) ! \( -name __init__.py -size 0 \) | head -n 1)" ]; }; }; then :; else \
	      printf 'REFUSING: %s mounts over %s, which is not a placeholder: the overlay replaces a 0-byte file, or a package holding an empty __init__.py and no other .py or .pyw, never code of the suite'"'"'s own\n' $(call sq,$(call test_suite_var,$(s),MOUNTS)) "$${dst#/repo/}"; exit 2; fi; \
	    if [ -n "$$own" ]; then root=; for c in $$(printf '%s' $(call sq,$(call test_suite,$(s),COV)) | tr ',' ' '); do c=$${c#./}; c=$${c%/}; [ "$$c" != . ] || c=; \
	      if [ -z "$$c" ] || [ -d $(call sq,$(CURDIR))$${wd#/repo}/"$$c" ]; then case "$$dst/" in ("$$wd$${c:+/$$c}"/*) root=$$wd$${c:+/$$c};; esac; \
	      else cp=$$(printf '%s' "$$c" | tr . /); case "$$dst/" in (*/"$$cp"/*) d2=$$dst/; root=$${d2%%/"$$cp"/*}/$$cp;; esac; fi; done; \
	    [ -n "$$root" ] || { printf 'REFUSING: %s measures its overlay, so each mount lands under a package it measures (%s); %s does not\n' $(call sq,$(call test_suite_var,$(s),OVERLAY_COV)) $(call sq,$(call test_suite,$(s),COV)) "$$dst"; exit 2; }; \
	    [ -e "$$src" ] || { printf 'REFUSING: %s measures the overlay %s, which does not exist\n' $(call sq,$(call test_suite_var,$(s),OVERLAY_COV)) "$$src"; exit 2; }; \
	    rel=$${dst#"$$root"/}; q=$$root; last=; nopkg=; for x in $$(printf '%s' "$$rel" | tr '/' ' '); do [ -z "$$last" ] || { q=$$q/$$last; [ -f $(call sq,$(CURDIR))/"$${q#/repo/}"/__init__.py ] || nopkg="$$nopkg $${q#/repo/}"; }; last=$$x; done; \
	    [ ! -d "$$src" ] || nopkg="$$nopkg$$(find "$$src" -type d ! -name __pycache__ | while read -r d; do [ -f "$$d/__init__.py" ] || [ -z "$$(find "$$d" \( -name '*.py' -o -name '*.pyw' \) | head -n 1)" ] || printf ' %s' "$$d"; done)"; \
	    [ -z "$$nopkg" ] || { printf 'REFUSING: %s measures its overlay, and coverage walks a package only through directories holding an __init__.py, so it would never report the code under%s: give each one an __init__.py\n' $(call sq,$(call test_suite_var,$(s),OVERLAY_COV)) "$$nopkg"; exit 2; }; fi; \
	    mnt="$$mnt -v $$src:$$dst$${opt:+:$$opt}"; [ -n "$$own" ] || omit="$$omit,$$dst,$$dst/*"; shift 2; done; omit=$${omit#,}; \
	  $(if $(filter -,$(s)),,printf '── suite %s (%s)\n' $(call sq,$(s)) $(call sq,$(call test_suite,$(s),WORKDIR));) \
	  bg docker build --load --target test $$lab --label "luxarch.test-block.checkout=$$co" --label "luxarch.test-block.project=$$p" $(call sqw,$(BUILD_ARGS)) -f $(call sq,$(call img_dockerfile,$(call test_suite_image,$(s)))) -t "$$img" $(call sq,$(call img_context,$(call test_suite_image,$(s)))) >/dev/null \
	    || { printf 'FAIL  the test image did not build: the test stage of %s\n' $(call sq,$(call img_dockerfile,$(call test_suite_image,$(s)))); exit 1; }; \
	  nx=; for w in $(call sqw,$(call test_suite,$(s),ENV)); do v=; if [ -n "$$nx" ]; then v=$$w; else case "$$w" in (-e|--env|--env-file) nx=$$w; continue;; (--env-file=*) nx=--env-file; v=$${w#*=};; (--env=*) nx=--env; v=$${w#*=};; (-e?*) nx=-e; v=$${w#-e};; \
	    (*) printf 'REFUSING: %s holds %s: TEST_ENV is the suite'"'"'s environment and nothing else: -e NAME=value and --env-file <file> (or their = forms). Any other docker option could join another network or reach the host and undo the suite'"'"'s isolation\n' $(call sq,$(call test_suite_var,$(s),ENV)) "$$w"; exit 2;; esac; fi; \
	    if [ "$$nx" = --env-file ]; then case "$$v" in (/*|..|../*|*/..|*/../*|*'$$'*) bad=1;; (*) bad=; d=$$(CDPATH= cd -P -- "$$(dirname -- "$$v")" 2>/dev/null && pwd -P) || d=; case "$$d/" in ("$$(pwd -P)"/*) ;; (*) bad=1;; esac; [ ! -L "$$v" ] || bad=1;; esac; \
	      [ -z "$$bad" ] || { printf 'REFUSING: %s hands the suite --env-file %s: the file must be in this checkout, named without a $$: the suite gets only values this repository holds\n' $(call sq,$(call test_suite_var,$(s),ENV)) "$$v"; exit 2; }; \
	    else case "$$v" in (*=*) ;; (*) printf 'REFUSING: %s holds %s %s with no =: a bare name copies that variable from the caller'"'"'s environment into the suite; write -e NAME=value\n' $(call sq,$(call test_suite_var,$(s),ENV)) "$$nx" "$$v"; exit 2;; esac; fi; nx=; done; \
	  [ -z "$$nx" ] || { printf 'REFUSING: %s ends with an option and no value\n' $(call sq,$(call test_suite_var,$(s),ENV)); exit 2; }; \
	  bg docker network create --internal $$lab --label "luxarch.test-block.checkout=$$co" --label "com.docker.compose.project=$$p" "$$p-suite" >/dev/null \
	    || { printf 'FAIL  could not create the suite network %s\n' "$$p-suite"; exit 1; }; \
	  if [ -n $(call sq,$(strip $(call test_suite,$(s),SERVICES))) ]; then \
	    bg dc up -d --wait --wait-timeout 120 $(call sqw,$(call test_suite,$(s),SERVICES)) \
	      || { printf 'FAIL  the test services did not become healthy: %s\n' $(call sq,$(call test_suite,$(s),SERVICES)); exit 1; }; \
	    printf '%s\n' 'SELECT 1 / (CASE WHEN pg_catalog.inet_server_addr() IS NULL AND pg_catalog.rtrim(pg_catalog.pg_read_file('"'"'postmaster.pid'"'"'), E'"'"'\n'"'"') = :'"'"'pm'"'"' THEN 1 ELSE 0 END) AS its_own_server;' "CREATE ROLE luxarch_test_server_$$tok NOLOGIN;" > "$$D/mark.sql" || exit 2; \
	    for sv in $(call sqw,$(call test_suite,$(s),SERVICES)); do \
	      sid=$$(dc ps -q "$$sv" | head -n 1); full=$$(docker inspect -f '{{.Id}}' "$$sid" 2>/dev/null); why=; pmode=$$(docker inspect -f '{{.HostConfig.PidMode}}' "$$sid" 2>/dev/null); case "$$pmode" in (''|private) ;; (*) why="its pid namespace is shared ($$pmode)";; esac; pgd=$$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$$sid" 2>/dev/null | sed -n 's/^PGDATA=//p' | head -n 1); pgd=$${pgd:-/var/lib/postgresql/data}; res=$$(dc exec -T "$$sv" sh -c 'for d in "$${PGDATA:-/var/lib/postgresql/data}" /var/run/postgresql; do (cd "$$d" 2>/dev/null && pwd -P); done' 2>/dev/null </dev/null); [ -n "$$why" ] || why=$$(docker inspect -f '{{range .Mounts}}{{.Type}}|{{.Name}}|{{.Destination}}{{println}}{{end}}' "$$sid" 2>/dev/null | while IFS='|' read -r mt mn md; do [ -n "$$md" ] || continue; hit=; for dd in "$$pgd" /var/run/postgresql $$res; do case "$$dd/" in ("$$md"/*) hit=1;; esac; case "$$md/" in ("$$dd"/*) hit=1;; esac; done; [ -n "$$hit" ] || continue; case "$$mt" in (tmpfs) ;; (volume) vd=$$(docker volume inspect -f '{{.Driver}}|{{json .Options}}' "$$mn" 2>/dev/null); case "$$vd" in ('local|null'|'local|{}') ;; (*) echo "$$md is the volume $$mn, whose driver or options put its data elsewhere ($$vd)"; break;; esac; [ "$$(docker volume inspect -f '{{index .Labels "com.docker.compose.project"}}' "$$mn" 2>/dev/null)" = "$$p" ] && continue; others=$$(docker ps -aq --no-trunc --filter "volume=$$mn" | grep -v -x "$$full"); if printf '%s\n' "$$mn" | grep -qx '[0-9a-f]\{64\}' && [ -z "$$others" ]; then continue; fi; echo "$$md is the volume $$mn, which is not this run's own (it outlives the run, or another container uses it)"; break;; (*) echo "$$md is a $$mt mount, not this run's own"; break;; esac; done | head -n 1); \
	      bgin "$$D/mark.sql" dc exec -T -e LUXARCH_MARK_REFUSE="$$why" "$$sv" sh -c 'sock=; for f in /var/run/postgresql/.s.PGSQL.*; do case "$$f" in (*.lock) ;; (*) [ -S "$$f" ] && sock=$$f;; esac; done; pid=$${PGDATA:-/var/lib/postgresql/data}/postmaster.pid; pm=$$(cat "$$pid" 2>/dev/null); [ -n "$$sock" ] && [ -n "$$pm" ] && [ "$$(cat /proc/$$(head -n 1 "$$pid")/comm 2>/dev/null)" = postgres ] && command -v psql >/dev/null 2>&1 || exit 0; [ -z "$${LUXARCH_MARK_REFUSE:-}" ] || { printf "REFUSING to mark this Postgres server: %s\n" "$$LUXARCH_MARK_REFUSE" >&2; exit 3; }; unset PGHOST PGHOSTADDR PGPORT PGSERVICE PGSERVICEFILE PGDATABASE PGUSER PGOPTIONS PGSYSCONFDIR PGPASSFILE; [ -z "$${POSTGRES_PASSWORD_FILE:-}" ] || POSTGRES_PASSWORD=$$(cat "$$POSTGRES_PASSWORD_FILE"); PGPASSWORD=$${POSTGRES_PASSWORD:-} exec psql -h /var/run/postgresql -p "$${sock##*.}" -v pm="$$pm" -v ON_ERROR_STOP=1 -X -q -U "$${POSTGRES_USER:-postgres}" -d postgres' >/dev/null \
	        || { r=$$?; [ "$$r" = 126 ] || [ "$$r" = 127 ] || { printf 'FAIL  could not mark %s as this run'"'"'s test server: the role luxarch_test_server_<run token>, created over the server'"'"'s own socket as $$POSTGRES_USER, which the test-db-bound block asks every Postgres connection for\n' "$$sv"; exit 1; }; }; done; \
	    for cid in $$(dc ps -q); do sv=$$(docker inspect -f '{{index .Config.Labels "com.docker.compose.service"}}' "$$cid" 2>/dev/null); \
	      [ -n "$$sv" ] && docker network connect --alias "$$sv" "$$p-suite" "$$cid" >/dev/null \
	        || { printf 'FAIL  %s (%s) could not join the suite network %s, so the suite cannot reach it\n' "$${sv:-a container}" "$$cid" "$$p-suite"; exit 1; }; done; fi; \
	  bg docker run --rm --init $(guard_caps) $$lab --label "luxarch.test-block.checkout=$$co" -e TINI_KILL_PROCESS_GROUP=1 --network "$$p-suite" $(call sqw,$(call test_suite,$(s),ENV)) -e PYTEST_ADDOPTS="$${PYTEST_ARGS:-}" -e LUXARCH_TEST_RUN="$$tok" -e LUXARCH_TEST_MIGRATIONS="$$mig" -e LUXARCH_TEST_FAST="$$fast" \
	    -e LUXARCH_TEST_COV=$(call sq,$(call test_suite,$(s),COV)) -e LUXARCH_TEST_OMIT="$$omit" -e COVERAGE_CORE=sysmon -e COVERAGE_FILE=/out/.coverage -e PYTHONDONTWRITEBYTECODE=1 \
	    -v $(call sq,$(CURDIR)):/repo:ro $$mnt -v "$$D/cfg":/cfg:ro -v "$$out":/out -w /repo/$(call sq,$(call test_suite,$(s),WORKDIR)) "$$img" \
	    sh -c 'm=$${LUXARCH_TEST_MIGRATIONS:-}; o=$${LUXARCH_TEST_OMIT:-}; unset LUXARCH_TEST_DB_REFUSALS LUXARCH_TEST_DB_TARGET; p=; if [ -e luxarch_test_db ]; then PYTHONPATH="$$PWD/luxarch_test_db/children$${PYTHONPATH:+:$$PYTHONPATH}"; PYTHONPYCACHEPREFIX=/tmp/luxarch-pycache; export PYTHONPATH PYTHONPYCACHEPREFIX; p=1; fi; LUXARCH_TEST_DB_SCOPE=suite python -m coverage run --branch --source="$$LUXARCH_TEST_COV" $${o:+"--omit=$$o"} -m pytest -c /cfg/pytest.ini --rootdir=. -p no:cacheprovider $${p:+-p luxarch_test_db.identity -p luxarch_test_db.bound} $${m:+"--ignore=$$m"}; s=$$?; if [ -n "$$m" ] && [ -z "$${LUXARCH_TEST_FAST:-}" ]; then PYTEST_ADDOPTS= LUXARCH_TEST_DB_SCOPE=server python -m coverage run --append --branch --source="$$LUXARCH_TEST_COV" $${o:+"--omit=$$o"} -m pytest -c /cfg/pytest.ini --rootdir=. -p no:cacheprovider $${p:+-p luxarch_test_db.identity} --confcutdir="$$m" "$$m"; ms=$$?; [ "$$ms" = 0 ] || echo "FAIL  the migration tests in $$m failed (exit $$ms)"; [ "$$s" != 0 ] || s=$$ms; fi; python -m coverage report --show-missing --precision=2 > /out/coverage.txt; echo $$? > /out/coverage.rc; python -m coverage json -q -o - > /out/coverage.json; cat /out/coverage.txt; exit $$s'; \
	  rc=$$?; \
	  [ "$$rc" = 0 ] || { echo "FAIL  the suite failed (exit $$rc). It runs with no internet: egress is not supported yet, so a test that calls a real outside host fails"; exit 1; }; \
	  [ -z "$$fast" ] || { echo "test-fast: passed, with no coverage verdict and no migration tests (make test runs both)"; exit 0; }; \
	  [ "$$(cat "$$out/coverage.rc" 2>/dev/null)" = 0 ] || { printf 'FAIL  coverage measured nothing (coverage report: %s): check %s names the package the suite imports\n' "$$(tail -n 1 "$$out/coverage.txt" 2>/dev/null)" $(call sq,$(call test_suite_var,$(s),COV)); exit 1; }; \
	  [ -f $(call sq,$(abspath $(call test_suite,$(s),FLOOR))) ] || { printf 'FAIL  the coverage floor %s (%s) does not exist: put [test].coverage_min there\n' $(call sq,$(call test_suite,$(s),FLOOR)) $(call sq,$(call test_suite_var,$(s),FLOOR)); exit 1; }; \
	  cat "$$out/coverage.txt" "$$out/coverage.json" > "$$out/ratchet.in" 2>/dev/null; \
	  bgin "$$out/ratchet.in" docker run --rm -i --init $$lab --label "luxarch.test-block.checkout=$$co" -v $(call sq,$(CURDIR)):/repo $(call sq,$(LUXLINT)) --coverage-ratchet --config /repo/$(call sq,$(call test_suite,$(s),FLOOR)) > "$$out/ratchet.txt"; crc=$$?; \
	  sed -n '/coverage ratchet/,$$p' "$$out/ratchet.txt"; \
	  $(if $(filter -,$(s)),,! grep -q 'coverage ratchet OFF' "$$out/ratchet.txt" || { printf 'FAIL  suite %s has no floor: %s (%s) sets no [test].coverage_min\n' $(call sq,$(s)) $(call sq,$(call test_suite,$(s),FLOOR)) $(call sq,$(call test_suite_var,$(s),FLOOR)); exit 1; };) \
	  [ "$$crc" = 0 ] || { echo "FAIL  the coverage ratchet failed (its verdict is above): add tests, never lower the floor"; exit 1; } \
	) & kid=$$!; while wait "$$kid"; r=$$?; kill -0 "$$kid" 2>/dev/null; do :; done; kid=; insuite=; halt; [ "$$r" = 0 ] || failed="$$failed "$(call sq,$(s)); ) \
	[ -z "$$failed" ] || { $(if $(strip $(TEST_SUITES)),echo "FAIL  suites that failed:$$failed";) exit 1; }

# THE NARROWED RUN (v6): `make test` with the same isolation and no coverage verdict. The recipe is
# `test`'s own: it reads this goal from make's command line.
test-fast: test ## One-off narrowed run, isolated like `make test`, no coverage verdict: make test-fast PYTEST_ARGS='tests/test_x.py -k y'

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
# luxarch:guard-run asset v12 - DO NOT edit this marker line; it is how repo.emitted_assets_current knows your copy is current. Re-emit with `luxarch --emit guard-run`.
# ── GUARD_RUN: how every guard sees this checkout ───────────────────────────────────────────────────
# Emitted by `luxarch --emit guard-run`; paste it above the targets that run the guards (`status:`, and
# `arch:` / `lint:` / `audit:` where they run a guard image).
#
# Agents work in linked worktrees (`<repo parent>/.worktrees/<repo>/<ISSUE-KEY>`). A worktree's `.git` is a file
# pointing into the MAIN checkout's `.git`, and the hooks keep their session state (the heartbeat) in
# the main checkout's `.claude/`. A guard that mounts only the worktree at /repo can read neither:
# every rule that reads git or the heartbeat goes INERT there, and `make status` run in a worktree
# commits those INERT verdicts as the repo's record. So GUARD_RUN also mounts the main checkout,
# read-only, at its own path, where the worktree's `.git` file points. In the main checkout itself
# there is nothing more to mount. Not covered: a worktree whose `.git` names its gitdir by a RELATIVE
# path (`worktree.useRelativePaths`), which resolves from /repo to somewhere else; its git-reading
# rules stay INERT. The worktree hook makes worktrees with `git worktree add`, which writes absolute
# pointers unless that setting is on. A worktree beside the repository gets the same two mounts.
# The main checkout is mounted only from a linked worktree: git's own directory differs from the
# common one. A plain subdirectory of a checkout is not a worktree and gets no second mount. A
# worktree of a submodule or of a bare repository has a common directory not named `.git`: that
# directory itself is mounted. A git hook's GIT_DIR is not this checkout's, so it is ignored here.
override GUARD_MAIN := $(if $(filter command,$(origin GUARD_MAIN)),$(GUARD_MAIN),$(shell unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR; cd -P -- '$(subst ','\'',$(CURDIR))' 2>/dev/null && g=$$(git rev-parse --path-format=absolute --git-dir 2>/dev/null) && d=$$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) && [ "$$g" != "$$d" ] && if [ "$$(basename "$$d")" = .git ]; then dirname "$$d"; else printf '%s\n' "$$d"; fi))
#
# Every emitted block mounts `$(CURDIR)` as this checkout, and a relative `-include Makefile.local`
# is read from it. Under `make -f <path>` started in another directory, `$(CURDIR)` is that other
# directory: the guards would judge the wrong tree, and Makefile.local would not be read. So a run
# whose first makefile is not in the directory make runs in is refused; `make -C <dir>` is the way to
# run it from elsewhere. The makefile is found by joining MAKEFILE_LIST's words until they name a
# file (a path may hold spaces), and its directory is compared, as a whole string, with the shell's
# real one and with CURDIR; the longest joining that names a file wins, so a stray file named like
# the path's first word does not. MAKEFILES (makefiles read first) is refused. A CURDIR given on the
# top make's command line names the tree deliberately and is honoured; a sub-make, which inherits
# it, is judged like any run, except under `make -n`, which runs no guard. v3: the dry runs luxarch and
# luxlint read a makefile with (`make -n`, in a copy of the tree, CURDIR naming the real one, each
# sub-make at its own MAKELEVEL) were refused at the first sub-make, so a correctly wired repo read
# red. The block's own variables are set with `override` and never
# exported, so neither `make -e` nor a parent's bare `export` can hand a sub-make other values.
# Refused rather than misread: a `-f` path holding two spaces in a row or a tab
# (MAKEFILE_LIST collapses them: run `make -C`), and a checkout path holding `:` (docker reads it
# as a mount option). Not refused: under `make -n`, a guard line that make runs anyway (a `+` line,
# or one naming `$(MAKE)`) in a sub-make that inherited a command-line CURDIR.
override guard_same = $(and $(findstring |$(1)|,|$(2)|),$(findstring |$(2)|,|$(1)|))
override guard_dry := $(findstring n,$(filter-out -% %=%,$(firstword $(MAKEFLAGS))))
$(if $(strip $(MAKEFILES)),$(error REFUSING: MAKEFILES ($(MAKEFILES)) reads other makefiles first, so the guards' tree is not this makefile's: unset it))
unexport CURDIR GUARD_MAIN GUARD_HERE GUARD_PWD GUARD_RUN guard_same guard_dry
override GUARD_HERE := $(shell set -- $(foreach w,$(MAKEFILE_LIST),'$(subst ','\'',$(w))'); p=; for w do p="$${p:+$$p }$$w"; if [ -f "$$p" ]; then h=$$(cd -P -- "$$(dirname -- "$$p")" && pwd -P); fi; done; printf '%s\n' "$$h")
override GUARD_PWD := $(shell pwd -P)
$(if $(and $(filter command,$(origin CURDIR)),$(or $(filter 0,$(MAKELEVEL)),$(guard_dry))),,$(if $(and $(GUARD_HERE),$(call guard_same,$(GUARD_HERE),$(GUARD_PWD)),$(call guard_same,$(GUARD_HERE),$(CURDIR))),,$(if $(filter environment%,$(origin GUARD_MAIN)),$(error REFUSING: GUARD_MAIN comes from the environment, so the caller chose a tree to mount: unset it))$(error REFUSING: make runs in $(GUARD_PWD) (CURDIR $(CURDIR)), not in this makefile's directory $(or $(GUARD_HERE),(not found)), so every guard would read the wrong tree: run make -C <the makefile's directory>)))
override GUARD_RUN = guard_slot_run() ( $(guard_slot_body) $(guard_capped) ); guard_slot_run $(guard_slot_vals) docker run --rm $(guard_caps) -v '$(subst ','\'',$(CURDIR))':/repo $(if $(GUARD_MAIN),$(if $(call guard_same,$(CURDIR),$(GUARD_MAIN)),,-v '$(subst ','\'',$(GUARD_MAIN))':'$(subst ','\'',$(GUARD_MAIN))':ro))
#
# ── Heavy-job slots (v5): at most HEAVY_SLOTS heavy jobs run on this machine at once ─────────────────
# A full guard scan, the full gate (`make check`) and the full test suite each hold one slot for as long
# as they run, counted across every checkout, session and user on the machine; the next one waits. Ten
# parallel full scans once held 40 GiB on one host, and its timing tests failed at load 60. A slot is a
# flock(2) lock on `<HEAVY_SLOT_DIR>/slot.<n>`, held on file descriptor 9 by the job's own processes:
# GUARD_RUN runs the guard's `docker run` through a shell function (`guard_slot_run`, a subshell that
# takes the slot and execs the client with it open), and the gate's and the suite's recipe shell
# opens it, so every command they start inherits it. The kernel releases it when the last of them
# exits, on a normal exit, Ctrl-C or kill -9 alike: there is no cleanup step and nothing goes stale.
# A guard's container runs under the docker daemon, not under the client that started it, so a kill
# -9 of the client frees the lock while the capped container runs on. So GUARD_RUN labels the
# container `fleet.heavy-slot=<slot file>`, and a slot whose lock is free while a running container
# carries its label (`docker ps -q --filter label=...` lists one) counts as held: the slot stays
# taken until that container ends (v9). Where docker cannot be asked, only the lock counts.
# It is taken with flock(1), or where there is none (macOS) with python3's fcntl.flock on the same
# descriptor; with neither, the job is refused, naming both.
# The slot code runs in the recipe's own shell and holds under `set -e` there, as the fleet's
# recipes run: a held slot, a slot file another job made first or an ancestor that exits mid-walk
# moves the job on, never ends it.
#   - WAITING polls each second and, once it has waited a second, prints one line on stderr naming
#     the jobs that hold the slots (each holder writes `slot.<n>.who` as it takes one, a job nested
#     through an ancestor as its own lock is granted). A job never fails for want of a slot, and
#     never runs without one.
#   - TARGETED runs take none: a GUARD_RUN naming `--rule <id>` (a value holding more than blanks
#     and commas, which luxarch drops, so `--rule ' '` runs every rule), or a flag that scans nothing
#     (`--emit*`, `--doc`, `--docs`, `--playbook`, `--version`, `--list-rules`, `--changelog`,
#     `--new-rules`, `--coverage-ratchet`, `--help`), a luxarch run with `--path <file>` (a value
#     holding more than blanks), which from luxarch 0.373.0 runs only the per-file rules on the named
#     files, and `make test-fast PYTEST_ARGS=<…>`. The image is read as docker reads it: the first
#     word after `docker run` that is no option and no option's value (`-v <mount>`, `--name <x>`,
#     `-e <K=V>`). It is `luxarch:<version>` at 0.373.0 or later, or a checkout's own
#     `luxarch:local-<hash>`. Only the words after it are the guard's, so `--path` and the modes that
#     read the whole repo (`--plan`, `--sweep`, `--ratchet`, `--json`) are read there, and an
#     `--entrypoint` anywhere makes it a full scan. Every other guard run is a full scan and takes
#     one: `--path` on an older image, under another tag, or on another guard, too.
#   - NESTED heavy jobs take no second slot: a job whose descriptor 9 is open on one of slots
#     1..HEAVY_SLOTS and holds its lock runs inside the job that took it (`check` running `test`
#     running a scan), so it starts at once, at HEAVY_SLOTS=1 too. So does a job one of whose
#     ancestor processes has descriptor 9 open on such a slot while it is locked (read from /proc),
#     which finds the holder through a process that closed the descriptors it inherited (Python's
#     subprocess does by default). That job opens the slot on
#     descriptor 9 itself and waits in the background to take the lock, so it keeps the slot
#     after its ancestor exits, for as long as it runs. No variable can claim either: the descriptor and the lock are the
#     proof.
#   - HEAVY_SLOTS and HEAVY_SLOT_DIR are machine settings: set them in Makefile.local (`HEAVY_SLOTS :=
#     2`, a whole number from 1 to 9999). From the environment, the command line or `--eval` they
#     are refused, as check refuses CHECK_LEGS: a value set in passing would let one caller choose
#     how many heavy jobs the whole machine runs. So is `-I <dir>` (outside `make -n`), from which
#     make reads a Makefile.local this checkout lacks.
#   - THE DIRECTORY is `/var/tmp/fleet-heavy-slots`, not under TMPDIR: TMPDIR is per user on macOS and
#     per session in some agent harnesses, which would give each its own slots. `/var/tmp` exists,
#     sticky and writable by every user, on Linux and macOS, and it is not where per-run scratch
#     goes (`repo.makefile_no_fixed_tmp` reds a fixed `/tmp` path: the slots are shared on purpose).
#     The directory is made 1777 (sticky and world-writable, as /tmp is) so every user can add a slot
#     file, and each slot file 644 so every user can open it read-only, which is all a lock needs: two
#     users on one machine share one cap. A slot directory or file that is a symlink, not a plain
#     file, or unreadable is refused, naming it.
# The cap counts slots 1..HEAVY_SLOTS of each caller, so a caller with a larger setting
# (or a second makefile given with `-f` that sets one) uses more slots than one with a smaller; a
# process a job starts that outlives it (a backgrounded daemon) keeps the descriptor, and so the slot,
# until it exits; where there is no /proc (macOS) a job started through a process that closed its
# descriptors is not seen as nested and waits for a slot of its own; and an ancestor shell that opens
# a held slot file on descriptor 9 by hand makes its children read as nested in that slot.
# Also as built: a `--rule` substring that matches many rules (`--rule .`) is taken as
# targeted; a job nested through an ancestor runs unlocked from the moment it finds the ancestor's
# lock until its own background request reaches the kernel, so an ancestor that exits in that window
# (milliseconds; not hit unloaded in 50 tries) lets a new job share its slot; a slot file removed
# while held (`rm`; systemd-tmpfiles skips locked files) is made anew, and its next holder runs beside
# the old one; the ancestor walk cannot read another user's /proc entries, so a job started as
# another user through a process that closed its descriptors waits for a slot of its own (at
# HEAVY_SLOTS=1, on its own ancestor); a user who creates a slot file others cannot read makes their
# jobs refuse; a `slot.<n>.who` left by another user cannot be replaced, so waiters may name an
# earlier job; and a command that unlocks its inherited descriptor 9 (`flock -u 9`) frees its job's
# slot.
HEAVY_SLOTS ?= 3
HEAVY_SLOT_DIR ?= /var/tmp/fleet-heavy-slots
# ── Heavy-job caps: how much of the machine one guard or test container may take ────────────────────
# Every guard run (and the test block's suite) runs with `--memory=HEAVY_MEMORY` (swap included, so it
# cannot spill). Without it one run that grows (a full scan of a large repo reached 5-7 GB) shares the
# Docker VM's memory with the app and its database, and when the VM runs out the kernel's OOM killer
# picks whichever it likes: on one Mac it took the app and Postgres. Capped, a run that hits its own
# limit is the one killed, exit 137, and it says so. Machine configuration, like HEAVY_SLOTS, set in
# Makefile.local; unset, it is two thirds of the Docker VM's memory shared among HEAVY_SLOTS (`docker
# info`; 6 GiB on a 27 GiB Docker Desktop VM), or 6g where docker cannot say. HEAVY_CPUS, when set,
# adds `--cpus`; unset there is no CPU cap (a suite that sizes its workers from the host's cores, as
# pytest-xdist's `-n auto` does, would run them all inside the quota).
# Each also runs at `--oom-score-adj=500`, so when the VM runs out anyway the kernel kills a guard
# or test container before the app and its database, which compose ranks at -500
# (`repo.compose_oom_ranked`).
# (recursive, so `docker info` runs only when a capped run expands it, never on every parse)
HEAVY_MEMORY ?= $(or $(shell docker info --format '{{.MemTotal}}' 2>/dev/null | awk -v n='$(HEAVY_SLOTS)' '$$1 ~ /^[0-9]+$$/ { n += 0; if (n < 1) n = 3; m = int($$1 * 2 / 3 / n / 1048576); if (m < 1024) m = 1024; print m "m"; exit }'),6g)
HEAVY_CPUS ?=
unexport HEAVY_SLOTS HEAVY_SLOT_DIR HEAVY_MEMORY HEAVY_CPUS guard_slot guard_slot_vals guard_slot_body guard_caps guard_capped
override guard_caps = $(foreach v,HEAVY_MEMORY HEAVY_CPUS,$(if $(filter environment% command,$(origin $(v))),$(error REFUSING: $(v) comes from the $(origin $(v)), so the caller chose how much of this machine one heavy job may take: set it in Makefile.local)))--oom-score-adj=500 --memory='$(subst ','\'',$(HEAVY_MEMORY))' --memory-swap='$(subst ','\'',$(HEAVY_MEMORY))'$(if $(HEAVY_CPUS), --cpus='$(subst ','\'',$(HEAVY_CPUS))')
# the run, then its exit: 137 is a SIGKILL, which for a capped container is almost always its own limit
override guard_capped = if [ -z "$$gs_x" ] && [ "$${1:-}" = docker ] && [ "$${2:-}" = run ]; then shift 2; set -- docker run --label "fleet.heavy-slot=$$gs_f" "$$@"; fi; gs_rc=0; "$$@" || gs_rc=$$?; [ "$$gs_rc" != 137 ] || echo "$$gs_job: the container was killed (exit 137), most likely at its memory cap (HEAVY_MEMORY $(HEAVY_MEMORY)): raise HEAVY_MEMORY in Makefile.local, or lower HEAVY_SLOTS so the machine has room" >&2; exit "$$gs_rc"
# make's own flags are what MAKEFLAGS holds before ` -- `: a variable's value after it can read like a flag.
override guard_space := $(subst x,,x x)
override guard_flags = $(subst :SP:, ,$(firstword $(subst :CUT:, ,$(subst $(guard_space),:SP:,$(subst $(guard_space)--$(guard_space),:CUT:,x $(MAKEFLAGS))))))
override guard_slot_vals = $(foreach v,HEAVY_SLOTS HEAVY_SLOT_DIR,$(if $(filter environment% command,$(origin $(v))),$(error REFUSING: $(v) comes from the $(origin $(v)), so the caller chose how many heavy jobs this machine runs at once: set it in Makefile.local)))$(if $(filter --eval=%,$(MAKEFLAGS)),$(error REFUSING: --eval adds makefile text from the command line, which could choose the heavy-job slots: put it in Makefile.local))$(if $(guard_dry),,$(if $(filter -I% --include-dir%,$(guard_flags)),$(error REFUSING: -I lets make read a Makefile.local from another directory, which could choose the heavy-job slots: run without it)))'$(subst ','\'',$(HEAVY_SLOT_DIR))' '$(subst ','\'',$(HEAVY_SLOTS))' '$(subst ','\'',make $@ in $(CURDIR))'
override guard_slot = $(if $(guard_dry),:,set -- $(guard_slot_vals); $(guard_slot_body) :)
override guard_slot_body = gs_d=$$1 gs_n=$$2 gs_job=$$3; shift 3; \
  case "$$gs_n" in (""|0*|*[!0-9]*|?????*) echo "REFUSING: HEAVY_SLOTS is \"$$gs_n\", not a whole number from 1 to 9999: set it in Makefile.local" >&2; exit 2;; esac; \
  gs_x=; gs_p=; gs_pa=; gs_nw=; gs_la=; gs_im=; gs_rn=; gs_sk=; for gs_a in "$$@"; do case "$$gs_p" in (--rule) case "$$gs_a" in (*[![:space:],]*) gs_x=1;; esac;; (--path) [ -z "$$gs_im" ] || case "$$gs_a" in (*[![:space:]]*) gs_pa=1;; (*) gs_nw=1;; esac;; esac; \
    case "$$gs_a" in (--rule=*[![:space:],]*|--emit|--emit=?*|--emit-*|--doc|--doc=?*|--docs|--playbook|--playbook=?*|--version|--list-rules|--changelog|--new-rules|--coverage-ratchet|--help) gs_x=1;; (--entrypoint|--entrypoint=*) gs_nw=1;; esac; \
    if [ -n "$$gs_im" ]; then case "$$gs_a" in (--path=*[![:space:]]*) gs_pa=1;; (--path=*|--pl*|--sw*|--ra*|--js*) gs_nw=1;; esac; \
    elif [ -z "$$gs_rn" ]; then [ "$$gs_a" != run ] || gs_rn=1; \
    elif [ -n "$$gs_sk" ]; then gs_sk=; \
    else case "$$gs_a" in (-v|--volume|-e|--env|--env-file|--name|-h|--hostname|-w|--workdir|--network|--net|--network-alias|-u|--user|-l|--label|--label-file|--mount|--platform|-m|--memory|--memory-swap|--memory-reservation|-c|--cpu-shares|--cpus|--cpuset-cpus|--oom-score-adj|--add-host|--cap-add|--cap-drop|--device|--dns|--group-add|--ipc|--pid|--uts|--userns|--cgroupns|--security-opt|--tmpfs|--ulimit|--shm-size|--log-driver|--log-opt|-p|--publish|--expose|--runtime|--gpus|--restart|--stop-signal|--stop-timeout|--cidfile|--pull|--volumes-from|--link|--ip|--ip6|--mac-address|--health-cmd|--health-interval|--health-retries|--health-timeout|--isolation|--attach|-a) gs_sk=1;; (-*) ;; \
      (*) gs_im=1; case "$$gs_a" in (luxarch:local-?*|*/luxarch:local-?*) gs_la=1;; (luxarch:[0-9]*|*/luxarch:[0-9]*) \
      gs_mj=$$(expr "x$$gs_a" : '.*luxarch:\([0-9][0-9]*\)\.' || :); gs_mn=$$(expr "x$$gs_a" : '.*luxarch:[0-9][0-9]*\.\([0-9][0-9]*\)' || :); \
      if [ -n "$$gs_mj" ] && [ -n "$$gs_mn" ] && { [ "$$gs_mj" -gt 0 ] || [ "$$gs_mn" -ge 373 ]; }; then gs_la=1; fi;; esac;; esac; fi; gs_p=$$gs_a; done; \
  [ -z "$$gs_pa" ] || [ -n "$$gs_nw" ] || [ -z "$$gs_la" ] || gs_x=1; \
  gs_who() { gs_t=$$(mktemp "$$gs_d/.who.XXXXXX") && { printf "%s\n" "$$gs_job (shell pid $$$$, user $$(id -un 2>/dev/null))" > "$$gs_t"; chmod 644 "$$gs_t"; mv -f "$$gs_t" "$$gs_f.who" 2>/dev/null || rm -f "$$gs_t"; }; }; \
  gs_busy() { command -v docker >/dev/null 2>&1 && docker ps -q --filter "label=fleet.heavy-slot=$$1" 2>/dev/null | grep -qE '^[0-9a-f]{12,64}$$'; }; \
  gs_lock() { if command -v flock >/dev/null 2>&1; then flock -n -E 75 9; else python3 -I -c "import fcntl,os,sys; sys.excepthook=lambda t,v,b: os._exit(75 if t is BlockingIOError else 2); fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)"; fi; }; \
  gs_have=; if [ -z "$$gs_x" ]; then gs_i=1; while [ "$$gs_i" -le "$$gs_n" ]; do gs_f=$$gs_d/slot.$$gs_i; \
      if [ /dev/fd/9 -ef "$$gs_f" ] && gs_lock; then gs_have=1; break; fi; gs_i=$$((gs_i + 1)); done; \
    gs_a=$$PPID; while [ -z "$$gs_have" ] && [ "$$gs_a" -gt 1 ] 2>/dev/null && [ -d "/proc/$$gs_a/fd" ]; do gs_i=1; \
      while [ "$$gs_i" -le "$$gs_n" ]; do gs_f=$$gs_d/slot.$$gs_i; \
        if [ "/proc/$$gs_a/fd/9" -ef "$$gs_f" ] && { ( exec 9<"$$gs_f"; gs_lock ); [ $$? = 75 ]; }; then gs_have=1; gs_anc=1; break; fi; gs_i=$$((gs_i + 1)); done; \
      gs_a=$$(sed -e "s/.*) . //" -e "s/ .*//" "/proc/$$gs_a/stat" 2>/dev/null) || gs_a=; done; \
    if [ -n "$${gs_anc:-}" ]; then exec 9<"$$gs_f"; ( if command -v flock >/dev/null 2>&1; then flock 9; else python3 -I -c "import fcntl; fcntl.flock(9, fcntl.LOCK_EX)"; fi && gs_who ) >/dev/null 2>&1 & fi; fi; \
  if [ -z "$$gs_x$$gs_have" ]; then \
    if [ -L "$$gs_d" ] || { [ ! -d "$$gs_d" ] && ! mkdir -m 1777 "$$gs_d" 2>/dev/null && [ ! -d "$$gs_d" ]; }; then \
      echo "REFUSING: the heavy-job slot directory $$gs_d (HEAVY_SLOT_DIR) is not a directory this job can use" >&2; exit 2; fi; \
    gs_w=; gs_r=75; while :; do gs_i=1; \
      while [ "$$gs_i" -le "$$gs_n" ]; do gs_f=$$gs_d/slot.$$gs_i; \
        if [ ! -e "$$gs_f" ] && [ ! -L "$$gs_f" ]; then gs_t=$$(mktemp "$$gs_d/.slot.XXXXXX") && { chmod 644 "$$gs_t"; ln "$$gs_t" "$$gs_f" 2>/dev/null || :; rm -f "$$gs_t"; }; fi; \
        if [ -L "$$gs_f" ] || [ ! -f "$$gs_f" ] || [ ! -r "$$gs_f" ]; then \
          echo "REFUSING: $$gs_f is not a plain file this job can read, so the heavy-job slots cannot be counted: remove it" >&2; exit 2; fi; \
        exec 9<"$$gs_f"; gs_r=0; gs_lock || gs_r=$$?; [ "$$gs_r" != 0 ] || ! gs_busy "$$gs_f" || gs_r=75; [ "$$gs_r" = 75 ] || break 2; gs_i=$$((gs_i + 1)); done; \
      if [ -z "$$gs_w" ]; then gs_w=0; elif [ "$$gs_w" = 0 ]; then gs_w=1; gs_h=; gs_i=1; while [ "$$gs_i" -le "$$gs_n" ]; do gs_o=; gs_f=$$gs_d/slot.$$gs_i.who; \
          if [ -f "$$gs_f" ] && [ ! -L "$$gs_f" ]; then read -r gs_o < "$$gs_f" || :; fi; gs_h="$$gs_h$${gs_h:+; }$${gs_o:-slot $$gs_i: holder unknown}"; gs_i=$$((gs_i + 1)); done; \
        echo "$$gs_job: waiting for a heavy-job slot ($$gs_n in use in $$gs_d, held by: $$gs_h)" >&2; fi; \
      sleep 1; done; \
    [ "$$gs_r" = 0 ] || { echo "REFUSING: could not lock the heavy-job slot $$gs_f with flock(1) or python3 (exit $$gs_r)" >&2; exit 2; }; \
    gs_who; fi;
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
	docker build --load --target production -f Dockerfile $(BUILD_ARGS) -t $(E2E_IMAGE) .
	./scripts/e2e-test.sh

# THE fleet gate — byte-identical composition across every app repo. Five different `check`
# targets is five different answers to "is this repo green," and the drift hides holes: a gate
# that quietly drops mypy, or arch, or the secret scan reads exactly as green as one that runs
# them. Order: pin drift -> ruff -> types -> tests -> architecture -> dependency CVEs -> secrets.
# `check` is a GATE, not a report: Make stops at the FIRST failing step. For the full red board
# (every red at once, phase-ordered + file-clustered) run `make plan`.
# See luxarch --doc FLEET-MAKEFILE-STANDARD.
# luxarch:check-gate asset v6 - DO NOT edit this marker line; it is how repo.emitted_assets_current knows your copy is current. Re-emit with `luxarch --emit check-gate`.
# ── The fleet gate: every leg runs, then the gate fails naming each red leg ───────────────────────
# Emitted by `luxarch --emit check-gate`; it replaces a hand-written `check:` line. A gate written as a
# prerequisite list (`check: … lint mypy test arch …`) stops at the FIRST failing leg: one ruff finding
# hid a 4,700-test suite, every hidden red cost one more fix-and-rerun cycle, and agents reached for
# `make -k`, which keeps going but also throws away the fatal steps' fatality.
#
# `guard-version-check` and `honest` are fatal and run first, as sub-makes on their own recipe lines: a
# stale guard or a rule family that scanned nothing makes every later verdict meaningless, and `make -o`
# can skip a prerequisite, which the recipe could never see. Each ends `|| exit 2`, so it stays fatal
# under `.ONESHELL`. Every other leg then runs in order. A leg that fails is recorded, never skipped, and the gate exits non-zero naming
# each one. `repo.makefile_canonical` credits CHECK_LEGS only when this recipe is the asset's own, so
# a hand-written loop that drops an exit code earns nothing.
#
# The recipe refuses, as make expands it, every way found for a caller to end the gate in a pass over
# a red leg. An expansion `$(error)` stops make even under `make -i` (which throws away every exit
# status, the gate's own included), and it is reached wherever `check` runs in this make, as a goal or
# as a prerequisite. A parent recipe that runs `$(MAKE) check` under its own `-i` still discards it.
#   - make's flags `-i` (errors ignored), `-t` (legs touched, not run) and `-e` (the environment
#     overrides the makefile's tool settings), in any spelling: MAKEFLAGS, GNUMAKEFLAGS, `+=`;
#   - `--eval`, `-I` (it can supply an included file such as Makefile.local) and MAKEFILES: each adds
#     makefile text from outside to this make and every leg, so the caller would choose what the
#     legs run, or which legs count;
#   - CHECK_LEGS, MAKE, MAKE_COMMAND, SHELL or .SHELLFLAGS from the environment or the command line,
#     and an empty CHECK_LEGS.
# A variable given on the command line never reaches a leg: `check` empties MAKEOVERRIDES for its
# sub-makes and unsets each such variable in the shell that starts them (make exports it there
# too; never PATH or a name the shell owns, like PPID or OPTIND), so each leg runs with the makefile's
# settings and `make release ALLOW_RETAG=1` still runs
# the gate. MAKEFLAGS or
# GNUMAKEFLAGS given as a command-line variable is refused, and MAKE and SHELL are checked as the
# recipe runs: make's own MAKE, and a POSIX shell.
# Under `make -n` the legs dry-run (each sub-make prints its commands) and the gate exits 1 with no
# verdict: nothing ran, so nothing passed. A second makefile given with `-f` is part
# of the makefile as far as make can tell, and a variable a leg runs that the makefile sets with `?=`
# or never sets (an image, a tool, its arguments) takes a value from the environment; the gate can
# tell neither from your own. `make -o check`, or `-o` in MAKEFLAGS in the environment, marks `check`
# itself as made, so nothing here runs, and an untracked Makefile.local can say `.IGNORE`: neither
# reaches a recipe. The emitted git hooks clear make's flags before they run it.
# v3: the gate holds one of the machine's heavy-job slots (the guard-run block's `guard_slot`, v4) while
# its legs run, so a full gate counts once against HEAVY_SLOTS and every scan and suite it starts runs
# inside that slot instead of waiting for a second one. Its two fatal steps run before it takes the
# slot, so each of their full scans takes a slot of its own for as long as it runs.
# Each leg ends with a `── make <leg>: <N>s` line, its wall time, so a slow gate says which leg holds
# the time.

# Setting: the legs, in order, set in the makefile. An app repo's are exactly these; a repo with more
# legs (a guard's own parity suite) appends them. Removing one reds repo.makefile_canonical ----------
CHECK_LEGS ?= lint mypy test arch audit gitleaks
unexport CHECK_LEGS

check: override MAKEOVERRIDES :=
.PHONY: check
check: ## THE fleet gate: runs every leg, then fails naming each red one
	@$(MAKE) --no-print-directory guard-version-check || exit 2
	@$(MAKE) --no-print-directory honest || exit 2
	@$(foreach v,MAKEFLAGS GNUMAKEFLAGS,$(if $(filter command,$(origin $(v))),$(error REFUSING: $(v) is given as a command-line variable, so every leg would inherit flags this gate never saw: pass make's flags as flags)))$(if $(filter-out default,$(origin MAKE_COMMAND)),$(error REFUSING: MAKE_COMMAND is set by the $(origin MAKE_COMMAND), so a leg would not be make))$(if $(filter-out override,$(origin MAKEOVERRIDES)),$(error REFUSING: check's own `override MAKEOVERRIDES :=` is missing or changed, so a command-line variable would reach the legs: re-emit the gate))$(if $(subst $$(MAKE_COMMAND),,$(value MAKE)),$(error REFUSING: MAKE is $(value MAKE), not make's own $$(MAKE_COMMAND), so a leg would not be make))$(if $(and $(filter 1,$(words $(SHELL))),$(filter /bin/sh /usr/bin/sh /bin/bash /usr/bin/bash /bin/dash /usr/bin/dash /bin/zsh /usr/bin/zsh,$(SHELL))),,$(error REFUSING: SHELL is $(SHELL), not a POSIX shell that returns each leg's status))$(if $(or $(findstring i,$(filter-out -%,$(firstword $(MAKEFLAGS)))),$(findstring t,$(filter-out -%,$(firstword $(MAKEFLAGS)))),$(findstring e,$(filter-out -%,$(firstword $(MAKEFLAGS))))),$(error REFUSING: make -i ignores every failure, -t touches the legs instead of running them, and -e lets the environment override the makefile's tools (flags: $(filter-out -%,$(firstword $(MAKEFLAGS)))), so a red leg could pass: run make check without them))$(if $(findstring n,$(filter-out -%,$(firstword $(MAKEFLAGS)))),,$(if $(filter -I% --include-dir%,$(MAKEFLAGS)),$(error REFUSING: -I lets an included file (Makefile.local) come from another directory, into every leg: run make check without it))$(if $(filter --eval=%,$(MAKEFLAGS)),$(error REFUSING: --eval adds makefile text from the command line to every leg: put it in the makefile))$(if $(strip $(MAKEFILES)),$(error REFUSING: MAKEFILES ($(MAKEFILES)) reads other makefiles into every leg: unset it))$(foreach v,CHECK_LEGS MAKE MAKE_COMMAND SHELL .SHELLFLAGS,$(if $(filter environment% command,$(origin $(v))),$(error REFUSING: $(v) comes from the $(origin $(v)), so the caller chose how the legs run: set it in the makefile))))$(if $(strip $(CHECK_LEGS)),,$(error REFUSING: CHECK_LEGS is empty, so no leg would run))$(foreach v,$(filter-out PATH PPID SHELLOPTS BASHOPTS OPTIND UID EUID BASH_VERSINFO,$(.VARIABLES)),$(if $(filter command,$(origin $(v))),case '$(subst ','\'',$(v))' in ([0-9]*|*[!A-Za-z0-9_]*) ;; (*) unset '$(subst ','\'',$(v))';; esac; )) \
	$(if $(value guard_slot),,$(error REFUSING: the gate holds a heavy-job slot from the guard-run block (v4), which this makefile does not define: paste luxarch --emit guard-run above it))$(guard_slot); \
	failed=; for leg in $(CHECK_LEGS); do \
	  printf '\n── make %s\n' "$$leg"; \
	  started=$$(date +%s); \
	  $(MAKE) --no-print-directory "$$leg" || failed="$$failed $$leg"; \
	  printf '── make %s: %ss\n' "$$leg" "$$(($$(date +%s) - started))"; \
	done; \
	if [ -n "$$failed" ]; then printf '\n✗ make check FAILED:%s (every leg ran; each one is above)\n' "$$failed"; exit 1; fi; \
	case '$(filter-out -%,$(firstword $(MAKEFLAGS)))' in *n*) printf '\nmake -n: the legs above were printed, not run, so make check gives no verdict\n'; exit 1;; esac; \
	printf '\n✓ make check: every leg passed (%s)\n' '$(CHECK_LEGS)'

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

# luxarch:gitleaks asset v27 - DO NOT edit this marker line; it is how repo.emitted_assets_current knows your copy is current. Re-emit with `luxarch --emit gitleaks`.
# ── The privacy gate: EVERY surface a commit publishes ──────────────────────────────────────────
# Emitted by `luxarch --emit gitleaks`. Drop in verbatim.
#
# `gitleaks` scans DIFF CONTENT. A commit's author/committer address lives in the commit object
# HEADER and never appears in a patch, so no content rule can ever match it — it is a surface the
# scanner does not read. A repo reported `no leaks found` over 963 commits while 29 of them carried a
# personal address in both the author and committer fields, and it would have reported exactly the
# same thing after the scrub: identical output, opposite truth. Measured across the fleet, EIGHT
# repos carry a personal address in history and two of them are PUBLIC.
#
# v13: the commit MESSAGE is a third surface, and through v12 nothing read it. It is neither a patch
# nor the header, so a message naming an org-denylisted host passed the staged scan, the full-history
# scan and the push hook: seven commits in one public repo, found only when a file repeated the name.
# Every commit and annotated-tag message in history is now scanned with the same config as file
# content, and `gitleaks-commit-msg` scans the message being written (run by hooks/commit-msg).

# The fleet's makefiles need GNU make 4 or later. macOS ships GNU make 3.81, which cannot read this
# block (nor some others) and would stop every target with a parse error. make reads lines in order,
# so this refusal comes first and says what to do: `brew install make`, then run `gmake` (or put
# "$(brew --prefix)/opt/make/libexec/gnubin" first on PATH, so `make` is GNU make 4).
$(if $(filter 3.%,$(MAKE_VERSION)),$(error REFUSING: GNU make $(MAKE_VERSION) is too old for this Makefile; it needs GNU make 4 or later. On macOS: brew install make; then run gmake))

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
# The allowance is read from the makefile only: set it there, above this block, to add an identity.
# The identity pass refuses one from the environment or the command line, where a value left in
# the shell (`GIT_IDENTITY_OK=.`) would match every author and pass any identity. It is never
# exported, so a bare `export` in the makefile does not hand it to a sub-make as such a value.
# v27: an allowance other than this default is honoured only while every makefile make reads is a
# file this repository commits, unchanged from HEAD (its content compared): an untracked, edited,
# other-repository or space-named makefile refuses it, whatever that makefile holds.
GIT_IDENTITY_OK ?= <214140984\+luxardolabs@users\.noreply\.github\.com>$$|<noreply@github\.com>$$
unexport GIT_IDENTITY_OK

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
override GITLEAKS_IMAGE = $(if $(findstring /,$(LUXLINT)),$(dir $(LUXLINT)),zricethezav/)gitleaks:v8.30.1@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f

# v13: `/repo` is `$(CURDIR)`, this makefile's directory. v1-v12 mounted `$(PWD)`, the CALLER's shell
# directory, so `make -C <repo> gitleaks` run from another repo scanned THAT repo's history with THAT
# repo's config while the identity pass read this one: two repos' answers, reported as this one's.
# v15: a WORKTREE's `.git` is a file naming `<main>/.git/worktrees/<name>`, outside the `/repo` mount, so
# git failed in the container and gitleaks logged "not a git repository", scanned 0 commits and passed:
# from every agent worktree, the history scan before a push read nothing. git's common directory is now
# mounted at its own absolute path, where that pointer leads, and a scan that reports no commit scanned
# while the repo has commits is refused, whatever the cause.
# v16: every `tr` that reads history bytes runs under `LC_ALL=C`, as the `awk` beside it does. BSD/macOS
# `tr` checks its input against the locale and aborts ("Illegal byte sequence") on a non-UTF-8 byte, so
# on a Mac the commit-message pass died before gitleaks ran, and a credential in a commit message was
# never reported.
# v17: the same for every `sed`, `sort` and `grep` that reads history bytes. BSD `grep` erroring on a
# non-UTF-8 author name inside `|| true` left the identity pass empty, so it PASSED having read nothing.
# Every pass reads this checkout's repository, never one a caller's GIT_DIR (or a git hook's) names:
# the variables that point git elsewhere or change what it reads are unset for each pass.
# Every pass reads the commits a push publishes, never a local `git replace` that shows git another
# commit (another identity, message, path or content) in their place.
# The repository's own config cannot change what a pass reads either: each pass, the history scan's
# container included, runs git with these settings as command-line config, which outranks every config
# file. `core.useReplaceRefs=false`: git 2.39 (the git macOS ships) lets a repository's `true` turn
# replace refs back on over GIT_NO_REPLACE_OBJECTS. `i18n.logOutputEncoding=UTF-8`: a repository set to
# UTF-16 or UTF-32 output re-encodes every record git prints, the passes' header lines included, and
# the message and identity passes then read nothing. `core.bigFileThreshold=512m` (git's default): a
# lower one makes git treat every file as binary and print no patch. `diff.relative=false`: a relative
# diff drops every path outside the directory git runs in. `log.follow=false`: the binary pass reads
# one path per `git log`, which `log.follow` turns into following a rename to another file.
override GITLEAKS_GIT_CONFIG := GIT_CONFIG_COUNT=5 GIT_CONFIG_KEY_0=core.useReplaceRefs GIT_CONFIG_VALUE_0=false GIT_CONFIG_KEY_1=i18n.logOutputEncoding GIT_CONFIG_VALUE_1=UTF-8 GIT_CONFIG_KEY_2=core.bigFileThreshold GIT_CONFIG_VALUE_2=512m GIT_CONFIG_KEY_3=diff.relative GIT_CONFIG_VALUE_3=false GIT_CONFIG_KEY_4=log.follow GIT_CONFIG_VALUE_4=false
override GITLEAKS_HISTORY_ENV := unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_GRAFT_FILE GIT_NAMESPACE GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT GIT_CEILING_DIRECTORIES GIT_DISCOVERY_ACROSS_FILESYSTEM; export $(GITLEAKS_GIT_CONFIG);
.PHONY: gitleaks gitleaks-staged gitleaks-commit-msg
# make's own flags are what MAKEFLAGS holds before ` -- `: a variable's value after it can read like a flag.
override gitleaks_space := $(subst x,,x x)
override gitleaks_flags = $(subst :SP:, ,$(firstword $(subst :CUT:, ,$(subst $(gitleaks_space),:SP:,$(subst $(gitleaks_space)--$(gitleaks_space),:CUT:,x $(MAKEFLAGS))))))
override gitleaks_refusals = $(foreach v,MAKEFLAGS GNUMAKEFLAGS,$(if $(filter command,$(origin $(v))),$(error REFUSING: $(v) is given as a command-line variable, so the scan would run under flags it never saw: pass make's flags as flags)))$(if $(or $(findstring i,$(filter-out -%,$(firstword $(MAKEFLAGS)))),$(findstring t,$(filter-out -%,$(firstword $(MAKEFLAGS))))),$(error REFUSING: make -i or -t would let a finding pass: run the scan without it))$(if $(filter --eval=% -I% --include-dir%,$(gitleaks_flags)),$(error REFUSING: --eval or -I adds makefile text from outside, which could set the identity allowance: run the scan without it))$(if $(strip $(MAKEFILES)),$(error REFUSING: MAKEFILES ($(MAKEFILES)) reads other makefiles before this one: unset it))$(foreach v,SHELL .SHELLFLAGS,$(if $(filter environment% command,$(origin $(v))),$(error REFUSING: $(v) comes from the $(origin $(v)), so the scan would run in another shell)))$(if $(filter environment% command,$(origin MAKEFILE_LIST)),$(error REFUSING: MAKEFILE_LIST comes from the $(origin MAKEFILE_LIST), so the identity pass would read other makefiles: unset it))$(if $(findstring n,$(filter-out -% %=%,$(firstword $(MAKEFLAGS)))),,$(if $(filter command,$(origin CURDIR)),$(error REFUSING: CURDIR is on the command line, so the scan would read another repository's history and report it as this one's: use make -C <dir>)))$(if $(filter 0,$(MAKELEVEL)),$(foreach v,LUXLINT LUXLINT_IMAGE,$(if $(filter environment% command,$(origin $(v))),$(error REFUSING: $(v) comes from the $(origin $(v)), so the caller chose the image that decides this scan: set it in the makefile or Makefile.local))))
override gitleaks_no_waiver = if [ -e "$$D/t/.gitleaksignore" ]; then mv "$$D/t/.gitleaksignore" "$$(mktemp -d "$$D/t/gitleaksignore.XXXXXXXX")/"; fi;
unexport gitleaks_refusals gitleaks_no_waiver gitleaks_flags gitleaks_space
# The builds this makefile's image block declares, one `<context><TAB><Dockerfile>` line each, for
# the working-tree pass: each image of IMAGES (or the one image) by the build core's `img_context` and
# `img_dockerfile`, the mirror when MIRROR_VERSION is set, and each `--build-context <name>=<dir>` in
# BUILD_ARGS (a named context reads its own `.dockerignore`, so its Dockerfile field is empty).
override gitleaks_q = '$(subst ','\'',$(1))'
override gitleaks_pair = printf '%s\t%s\n' $(call gitleaks_q,$(call img_context,$(1))) $(call gitleaks_q,$(call img_dockerfile,$(1)));
override gitleaks_named = $(patsubst --build-context=%,%,$(filter --build-context=%,$(BUILD_ARGS))) $(patsubst --build-context:NEXT:%,%,$(filter --build-context:NEXT:%,$(join $(BUILD_ARGS),$(addprefix :NEXT:,$(wordlist 2,$(words $(BUILD_ARGS)),$(BUILD_ARGS))))))
override gitleaks_declared = $(if $(value img_context),$(if $(IMAGE_LIST),$(foreach n,$(IMAGE_LIST),$(call gitleaks_pair,$(n))),$(call gitleaks_pair,))$(if $(strip $(MIRROR_VERSION)),$(call gitleaks_pair,MIRROR)))$(foreach x,$(strip $(gitleaks_named)),printf '%s\t\n' $(call gitleaks_q,$(patsubst $(firstword $(subst =, ,$(x)))=%,%,$(x)));)
unexport gitleaks_q gitleaks_pair gitleaks_named gitleaks_declared
# The working-tree pass's file work, in one process (python3 in the luxlint image, no network): `farm`
# lays out a link for each path in `cand` (a `dir/` entry: every file under it) for BuildKit to judge,
# and `copy` copies each path in `sent` out of the checkout, a link as a link and a file with its NUL
# bytes stripped. Paths are bytes end to end. `builds` asks make which `docker build` / `buildx build`
# each target of each makefile git lists runs, and prints `B <context> <Dockerfile>` for each (`N <dir>
# <Dockerfile>` for a named `--build-context`), repo-relative, and `U <Dockerfile>` for one whose
# context it cannot read (an empty Dockerfile when that cannot be read either). make never sees the
# repo's makefiles: it reads a mirror in which each is a rewritten copy (the MAKE variable renamed, `+`
# prefixes dropped, so no recipe line runs under `-n`; every file make's MAKEFILE_LIST names, whatever
# its name, and none it reads from outside the mirror) and every other entry links to the checkout,
# with CURDIR pinned to the real directory, as luxarch's own makefile rules read one. It runs as
# `nobody` (where the container lets it drop root), with the checkout read-only and no network. What
# runs is the makefiles' `$(shell ...)`, the same text `make gitleaks` itself has just evaluated. Each
# printed command is split as the shell splits it (`cd <dir>` followed, shell keywords and wrappers such
# as `timeout 900` read past, a command substitution one unreadable word, a docker build it still cannot
# read an unreadable build), and a build's context is its one positional word, each valued flag's value skipped.
override define gitleaks_stage_py
import os, sys
mode, w, d = sys.argv[1], os.fsencode(sys.argv[2]), os.fsencode(sys.argv[3])
def names(f):
    with open(os.path.join(d, f), "rb") as h:
        return [n for n in h.read().split(b"\n") if n]
def entry(p):
    return os.path.islink(p) or os.path.isfile(p)
if mode == "farm":
    for p in names(b"cand"):
        src, got = os.path.join(w, p.rstrip(b"/")), []
        if p.endswith(b"/"):
            for here, dirs, files in os.walk(src):
                got += [os.path.relpath(os.path.join(here, n), w) for n in files + dirs if entry(os.path.join(here, n))]
        elif entry(src):
            got.append(p)
        for q in got:
            dst = os.path.join(d, b"s", q)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            if not os.path.lexists(dst):
                os.symlink(b"-", dst)
elif mode == "copy":
    for p in names(b"sent"):
        src, dst = os.path.join(w, p), os.path.join(d, b"t", p)
        if not entry(src):
            continue
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        if os.path.islink(src):
            os.symlink(os.readlink(src), dst)
            continue
        with open(src, "rb") as i, open(dst, "wb") as o:
            for chunk in iter(lambda: i.read(1 << 20), b""):
                o.write(chunk.replace(b"\0", b""))
elif mode == "builds":
    import posixpath, re, shlex, subprocess, tempfile, time
    from concurrent.futures import ThreadPoolExecutor
    wr = os.fsdecode(w)
    base = tempfile.mkdtemp()
    os.chmod(base, 0o755)
    top = os.path.join(base, "r")
    ents = ("GNUmakefile", "makefile", "Makefile")
    def mkfile(n):
        return n in ents or n.startswith("Makefile") or n.endswith(".mk")
    mks, need = set(), {wr}
    for here, dirs, files in os.walk(wr):
        dirs[:] = [x for x in dirs if x not in (".git", "node_modules", ".venv", "venv", "__pycache__")]
        for f in files:
            if mkfile(f):
                mks.add(os.path.join(here, f))
                p = here
                while p not in need:
                    need.add(p)
                    p = os.path.dirname(p)
    sub = re.compile(r"\$([({])MAKE([)}])")
    plus = re.compile(r"(?m)^(\t[@\- ]*)\+")
    for real in sorted(need, key=len):
        dst = top + real[len(wr):]
        os.makedirs(dst, exist_ok=True)
        os.chmod(dst, 0o755)
        for e in os.scandir(real):
            out = os.path.join(dst, e.name)
            if e.path in need and e.is_dir(follow_symlinks=False):
                continue
            if e.path in mks and e.is_file(follow_symlinks=False):
                with open(e.path, encoding="utf-8", errors="surrogateescape") as h:
                    t = h.read()
                with open(out, "w", encoding="utf-8", errors="surrogateescape") as h:
                    h.write(plus.sub(r"\1", sub.sub(r"$\1GITLEAKS_SUBMAKE\2", t)))
                os.chmod(out, 0o644)
            else:
                os.symlink(e.path, out)
    def own_copy(q):
        # the mirror path `q` becomes a rewritten copy of the file it stands for, each directory on the
        # way a real mirror directory; False when it is not under the mirror or names no file
        q = os.path.normpath(q)
        if q != top and not q.startswith(top + "/"):
            return False
        at = top
        for part in q[len(top) + 1:].split("/")[:-1]:
            at = os.path.join(at, part)
            if os.path.islink(at):
                real = os.readlink(at)
                if not os.path.isdir(real):
                    return False
                os.unlink(at)
                os.mkdir(at, 0o755)
                for e in os.scandir(real):
                    os.symlink(e.path, os.path.join(at, e.name))
            elif not os.path.isdir(at):
                return False
        if not os.path.islink(q):
            return os.path.isfile(q)
        real = os.readlink(q)
        if not os.path.isfile(real):
            return False
        with open(real, encoding="utf-8", errors="surrogateescape") as h:
            t = h.read()
        os.unlink(q)
        with open(q, "w", encoding="utf-8", errors="surrogateescape") as h:
            h.write(plus.sub(r"\1", sub.sub(r"$\1GITLEAKS_SUBMAKE\2", t)))
        os.chmod(q, 0o644)
        return True
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": "/nonexistent", "LANG": "C.UTF-8",
           "GIT_DIR": os.path.join(wr, ".git"), "GIT_WORK_TREE": wr, "GIT_CONFIG_COUNT": "1",
           "GIT_CONFIG_KEY_0": "safe.directory", "GIT_CONFIG_VALUE_0": "*"}
    drop = [os.geteuid() == 0]
    end = time.monotonic() + 240
    def run(args, cwd, rel):
        t = max(1, min(60, end - time.monotonic()))
        a = ["make", *args, "GITLEAKS_SUBMAKE=make", "CURDIR=" + posixpath.join(wr, rel).rstrip("/")]
        kw = dict(cwd=cwd, env=env, capture_output=True, text=True, errors="surrogateescape", timeout=t, check=False)
        if drop[0]:
            try:
                return subprocess.run(a, user=65534, group=65534, extra_groups=[], **kw)
            except PermissionError:
                drop[0] = False
        return subprocess.run(a, **kw)
    vf = set("-t --tag --target -f --file --platform --build-arg --output -o --label --cache-from --cache-to --secret --ssh --progress --builder --iidfile --metadata-file --network --build-context --shm-size --add-host --allow --annotation --attest --sbom --provenance --call --cgroup-parent --ulimit --memory -m --memory-swap --cpu-shares -c --cpu-period --cpu-quota --cpuset-cpus --cpuset-mems --isolation --security-opt --label-file --policy".split())
    gv = set("-H --host --context -c --config -l --log-level --tlscacert --tlscert --tlskey".split())
    found = set()
    def rel_of(p, cwd):
        if p.startswith("/"):
            for pre in (wr, top):
                if p == pre or p.startswith(pre.rstrip("/") + "/"):
                    return posixpath.normpath(p[len(pre):].lstrip("/") or ".")
            return posixpath.normpath(p)
        return posixpath.normpath(posixpath.join(cwd, p))
    def bad(x):
        return any(c in x for c in "$`*?[") or x == ""
    def build(words, cwd):
        i = 1
        while i < len(words) and words[i].startswith("-"):
            i += 2 if words[i] in gv else 1
        rest = words[i:]
        if rest[:1] == ["build"]:
            rest = rest[1:]
        elif len(rest) > 1 and rest[0] in ("buildx", "image", "builder") and rest[1] == "build":
            rest = rest[2:]
        else:
            return False
        pos, df, named, j = [], None, [], 0
        while j < len(rest):
            a = rest[j]
            if a in ("-f", "--file") and j + 1 < len(rest):
                df, j = rest[j + 1], j + 2
                continue
            if a.startswith("--file="):
                df = a[7:]
            elif a.startswith("-f") and not a.startswith("--") and len(a) > 2:
                df = a[2:].lstrip("=")
            elif a == "--build-context" and j + 1 < len(rest):
                named.append(rest[j + 1])
                j += 2
                continue
            elif a.startswith("--build-context="):
                named.append(a[16:])
            elif a in vf:
                j += 2
                continue
            elif a == "-" or not a.startswith("-"):
                pos.append(a)
            j += 1
        if df == "-" or (len(pos) == 1 and ("://" in pos[0] or pos[0].startswith("git@"))):
            return True
        spelled = df if df is not None else posixpath.join(pos[0], "Dockerfile") if len(pos) == 1 else ""
        if bad(spelled):
            key = ""
        elif cwd is None:
            key = posixpath.normpath(spelled)
        else:
            key = rel_of(spelled, cwd)
        if cwd is None or len(pos) != 1 or pos[0] == "-" or bad(pos[0]):
            found.add(("U", key))
            return True
        ctx, dfr = rel_of(pos[0], cwd), key
        found.add(("B", ctx, dfr))
        for n in named:
            v = n.split("=", 1)[1] if "=" in n else ""
            if v and "://" not in v and not v.startswith("docker-image:") and not v.startswith("oci-layout:"):
                found.add(("N", "U" if bad(v) else rel_of(v, cwd), dfr))
        return True
    keywords = {"then", "else", "elif", "do", "if", "while", "until", "{", "!"}
    wrappers = {"env": {"-u", "-C", "-S"}, "exec": {"-a"}, "command": set(), "nohup": set(), "time": set(),
                "sudo": {"-u", "-g", "-C", "-D", "-h", "-p", "-U"}, "nice": {"-n"},
                "xargs": {"-I", "-n", "-P", "-L", "-d", "-E", "-s", "-a"}, "timeout": {"-s", "-k"}}
    def redir(t):
        return bool(t) and set(t) <= set("<>&|") and ("<" in t or ">" in t)
    def flat(s):
        out, i, q = [], 0, ""
        while i < len(s):
            c = s[i]
            if q == "'":
                q = "" if c == "'" else q
                out.append(c)
                i += 1
            elif c == "\\" and i + 1 < len(s):
                out.append(s[i:i + 2])
                i += 2
            elif s.startswith("$(", i) or c == "`":
                j, depth = i + 1, 1
                if c == "`":
                    while j < len(s) and s[j] != "`":
                        j += 1
                else:
                    j += 1
                    while j < len(s) and depth:
                        depth += {"(": 1, ")": -1}.get(s[j], 0)
                        j += 1
                    j -= 1
                out.append("$S")
                i = j + 1
            else:
                if c in "'\"":
                    q = "" if q == c else (q or c)
                out.append(c)
                i += 1
        return "".join(out)
    def line(text, cwd):
        try:
            lx = shlex.shlex(flat(text), posix=True, punctuation_chars=";&|()<>")
            lx.whitespace_split = True
            lx.commenters = ""
            toks = list(lx)
        except ValueError:
            if "build" in text:
                found.add(("U", ""))
            return
        stack, seg, cur = [], [], cwd
        def seg_done(seg, cur):
            k, out = 0, []
            while k < len(seg):
                t = seg[k]
                if redir(t):
                    k += 2
                elif t.isdigit() and k + 1 < len(seg) and redir(seg[k + 1]):
                    k += 3
                else:
                    out.append(t)
                    k += 1
            words = list(out)
            while out:
                if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", out[0]) or out[0] in keywords:
                    out.pop(0)
                elif out[0] in wrappers:
                    wrap = out.pop(0)
                    while out and out[0].startswith("-"):
                        flag = out.pop(0)
                        if flag in wrappers[wrap] and out:
                            out.pop(0)
                    if wrap == "timeout" and out:
                        out.pop(0)
                else:
                    break
            if not out:
                return cur
            if out[0] == "cd":
                if len(out) == 2 and not bad(out[1]) and cur is not None:
                    return rel_of(out[1], cur)
                return None
            # a command handed to a wrapper this does not know (a shell function: `bg docker build …`)
            # is read from its docker word on
            at = next((i for i, x in enumerate(out) if posixpath.basename(x) in ("docker", "podman")), None)
            read = at is not None and build(out[at:], cur)
            if not read and "build" in words and any(posixpath.basename(x) in ("docker", "podman") for x in words):
                found.add(("U", ""))
            return cur
        split = []
        for t in toks:
            if set(t) <= set(";&|()") and t:
                split += re.findall(r"&&|\|\||\|&|;;|[;&|()]", t)
            else:
                split.append(t)
        for t in split + [";"]:
            if t in ("&&", "||", ";", "|", "&", "|&", ";;"):
                cur = seg_done(seg, cur)
                seg = []
            elif t == "(":
                cur = seg_done(seg, cur)
                seg = []
                stack.append(cur)
            elif t == ")":
                seg_done(seg, cur)
                seg = []
                cur = stack.pop() if stack else cur
            else:
                seg.append(t)
    def commands(out, cwd):
        buf = ""
        for raw in out.splitlines():
            if raw.endswith("\\"):
                buf += raw[:-1] + " "
                continue
            line(buf + raw, cwd)
            buf = ""
        if buf:
            line(buf, cwd)
    mine = ("gitleaks", "gitleaks-staged", "gitleaks-commit-msg")
    rule = re.compile(r"^([^\s#=:][^#=]*?):{1,2}(?!=)")
    with open(os.path.join(d, b"names"), "rb") as h:
        listed = {os.fsdecode(n) for n in h.read().split(b"\0") if n}
    for dd in sorted(need, key=len):
        r0 = dd[len(wr):].lstrip("/")
        names = set(os.listdir(top + dd[len(wr):]))
        ent = next((n for n in ents if n in names), None)
        if ent is None or posixpath.join(r0, ent) not in listed:
            continue
        cwd = top + dd[len(wr):]
        rel = dd[len(wr):].lstrip("/") or "."
        hold = [y for m in sorted(mks) if not os.path.relpath(m, dd).startswith("..") for y in ("-o", os.path.relpath(m, dd))]
        hold += [y for g in mine for y in ("-o", g)]
        try:
            db = run(["-qpR", "-f", ent, "__gitleaks_no_such_target__"], cwd, rel).stdout
            listed_mk = re.search(r"(?m)^MAKEFILE_LIST :?= ?(.*)$", db)
            mklist = shlex.split(listed_mk.group(1)) if listed_mk else []
            if not listed_mk or not all(own_copy(os.path.join(cwd, m)) for m in mklist):
                found.add(("U", ""))
                continue
            db = run(["-qpR", "-f", ent, "__gitleaks_no_such_target__"], cwd, rel).stdout
            hold += [y for m in mklist for y in ("-o", m)]
        except (OSError, subprocess.TimeoutExpired, ValueError):
            found.add(("U", ""))
            continue
        if "\n# Files\n" not in db:
            found.add(("U", ""))
            continue
        files = db.split("\n# Files\n", 1)[1]
        files = re.split(r"\n# (?:files hash-table stats|VPATH Search Paths)", files)[0]
        goals, prev = [], ""
        for ln in files.splitlines():
            m = rule.match(ln)
            if m and prev != "# Not a target:":
                g = m.group(1).strip()
                if not g.startswith(".") and "%" not in g and g not in mine and g not in goals:
                    goals.append(g)
            prev = ln
        if not goals:
            continue
        try:
            p = run(["-n", "-k", "-B", "--no-print-directory", *hold, "-f", ent, *goals], cwd, rel)
            ok = p.returncode == 0
        except (OSError, subprocess.TimeoutExpired):
            p, ok = None, False
        if ok:
            commands(p.stdout, rel)
            continue
        def one(g, cwd=cwd, rel=rel, ent=ent, hold=hold):
            try:
                return run(["-n", "-B", "--no-print-directory", *hold, "-f", ent, g], cwd, rel)
            except (OSError, subprocess.TimeoutExpired):
                return None
        with ThreadPoolExecutor(max_workers=8) as pool:
            for g, q in zip(goals, pool.map(one, goals)):
                if q is None:
                    found.add(("U", ""))
                    continue
                commands(q.stdout, rel)
    for f in sorted(found):
        sys.stdout.write("\t".join(f) + "\n")
endef
unexport gitleaks_stage_py
# Every object a push publishes, read raw: each commit on a branch, a tag or HEAD, and every annotated
# tag object, the tags a tag points at included (a tag of a tag shows `for-each-ref` only its outer
# tagger and message). The identity and message passes both read this list. `$$X` names the list file
# and `$$N` the run's nonce; each git call writes a file, so a failing one stops the pass (`set -e`).
override gitleaks_objects = git rev-list --branches --tags --glob='refs/notes/*' HEAD > "$$X"; \
  git for-each-ref refs/heads refs/tags refs/notes --format='%(objecttype) %(objectname)' > "$$X.r"; \
  LC_ALL=C sed -n 's/^tag //p' "$$X.r" > "$$X.n"; LC_ALL=C sort -u "$$X.n" > "$$X.t"; \
  while [ -s "$$X.t" ]; do cat "$$X.t" >> "$$X"; \
    git cat-file --batch="$$N %(objectname) %(objecttype)" < "$$X.t" > "$$X.r"; LC_ALL=C tr -d '\000' < "$$X.r" > "$$X.c"; \
    LC_ALL=C awk -v n="$$N" -v mode=nested "$$GITLEAKS_OBJECTS_AWK" "$$X.c" > "$$X.n"; LC_ALL=C sort -u "$$X.n" > "$$X.t"; \
  done; \
  git cat-file --batch="$$N %(objectname) %(objecttype)" < "$$X" > "$$X.r"; LC_ALL=C tr -d '\000' < "$$X.r" > "$$X.c";

# Reads the raw objects `git cat-file --batch` prints, each after a `<nonce> <sha> <type>` line, and
# reads every header line a commit or tag carries, continuation lines included:
#   mode=id      prints `<identity><TAB><where>` for each author, committer and tagger line (the date
#                cut off), each address an unknown header holds, and each address a signature carries.
#   mode=msg     prints each tag message, a `mergetag` header's embedded tag included, as
#                `<nonce> tag-message/<sha>` (or `mergetag-message/<commit>-<n>`) and its lines.
#   mode=nested  prints the object each tag of a tag points at.
# A signature is a `gpgsig` / `gpgsig-sha256` header, or a signature block at the end of a tag message.
# An address in one is published with the object: gpg writes the signing user ID (subpacket 28) when
# the key is named by address, an X.509 signature carries the signer's certificate (gitsign's names
# the signer's address), and an armor header can say anything. OpenPGP packets are parsed: the
# signer's user ID, a User ID packet, a human-readable notation, an embedded signature and an
# embedded key block (subpacket 38, `gpg --include-key-block`: the signer's key with every user ID)
# are read;
# an issuer key ID or fingerprint names a key, not an address, and is not an identity. An SSHSIG is
# parsed and each printable string it holds is read; a certificate key and an X.509 signature are read
# for every address-shaped printable run. A signature in a form this cannot parse is refused as
# unreadable, never passed. awk has no bitwise operators, so bits are read with division, and powers of two come from a table
# (busybox awk can be built without `^`).
override define gitleaks_objects_awk
function b64init(   s, i) {
  s = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  for (i = 1; i <= 64; i++) B64[substr(s, i, 1)] = i - 1
  P2[0] = 1
  for (i = 1; i <= 8; i++) P2[i] = P2[i - 1] * 2
}
function decode(text,   L, nl, k, i, c, acc, bits, cnt) {
  cnt = 0; acc = 0; bits = 0; nl = split(text, L, "\n")
  for (k = 1; k <= nl; k++) {
    if (L[k] ~ /^=/) break
    for (i = 1; i <= length(L[k]); i++) {
      c = substr(L[k], i, 1)
      if (c == "=") break
      if (!(c in B64)) return -1
      acc = acc * 64 + B64[c]; bits += 6
      if (bits >= 8) { bits -= 8; BY[++cnt] = int(acc / P2[bits]); acc = acc % P2[bits] }
    }
  }
  return cnt
}
function str(p, e,   s, i) {
  s = ""
  for (i = p; i <= e; i++) s = s sprintf("%c", BY[i])
  return s
}
function num(p, w,   v, k) {
  v = 0
  for (k = 0; k < w; k++) v = v * 256 + BY[p + k]
  return v
}
# v27: a header git writes is skipped only when its value has the shape git writes there (an object
# id, a type word, an encoding name, a tag name with no `@`); any other header is judged, its name
# and value together, so `encoding <an address>` and a header named by an address are identities.
function shaped(hn, hv) {
  if (hn == "tree" || hn == "parent" || hn == "object") return hv ~ /^[0-9a-f]+$/ && (length(hv) == 40 || length(hv) == 64)
  if (hn == "type") return hv ~ /^(commit|tree|blob|tag)$/
  if (hn == "encoding") return hv ~ /^[A-Za-z0-9._:+-]+$/
  if (hn == "tag") return hv !~ /@/
  return 0
}
function out(s, where) {
  if (QUIET) return
  gsub(/[\t\n\r]/, " ", s)
  print s "\t" where
}
function emit(s, where) {
  if (s ~ /[<>]/) out(s, where)
  else if (s ~ /@/) out("signer <" s ">", where)
}
function unreadable(where) {
  out("a signature this pass cannot read <?>", where)
}
# v27: an X.509 signature (CMS) is read as DER, by tag and length (indefinite lengths too): every
# IA5, UTF8, Printable, Teletex, Visible and BMP string, and every email and URI name, holding an `@`
# is an identity; an OCTET STRING that is itself DER is read too. DER it cannot read is unreadable.
# Read as printable runs, the length byte before an emailAddress joined the address.
function bmp(p, e,   s, i) {
  if ((e - p + 1) % 2) return "?"
  s = ""
  for (i = p; i < e; i += 2) s = s ((BY[i] == 0 && BY[i + 1] >= 32 && BY[i + 1] <= 126) ? sprintf("%c", BY[i + 1]) : "?")
  return s
}
function der(p, e, where, indef,   t, l1, n, len, k, s, q) {
  while (p <= e) {
    if (indef && p + 1 <= e && BY[p] == 0 && BY[p + 1] == 0) return p + 2
    t = BY[p++]
    if (t % 32 == 31 || p > e) return -1
    l1 = BY[p++]
    if (l1 < 128) len = l1
    else if (l1 == 128) len = -1
    else { n = l1 - 128; if (n > 4 || p + n - 1 > e) return -1; len = 0; for (k = 0; k < n; k++) len = len * 256 + BY[p + k]; p += n }
    if (len < 0) {
      if (int(t / 32) % 2 == 0) return -1
      p = der(p, e, where, 1)
      if (p < 0) return -1
      continue
    }
    if (p + len - 1 > e) return -1
    if (int(t / 32) % 2 == 1) { if (len > 0 && der(p, p + len - 1, where, 0) < 0) return -1 }
    else if (t == 30) { s = bmp(p, p + len - 1); if (s ~ /@/) emit(s, where) }
    else if (t == 12 || t == 19 || t == 20 || t == 22 || t == 26 || t == 129 || t == 134) { s = str(p, p + len - 1); if (s ~ /@/) emit(s, where) }
    else if (t == 4 && len > 1 && BY[p] == 48) {
      q = QUIET; QUIET = 1; k = der(p, p + len - 1, where, 0); QUIET = q
      if (k == p + len) der(p, p + len - 1, where, 0)
    }
    p += len
  }
  return indef ? -1 : p
}
function subs(p, e, where,   l1, len, t, nl, vl) {
  while (p <= e) {
    l1 = BY[p++]
    if (l1 < 192) len = l1
    else if (l1 < 255) { if (p > e) return 0; len = (l1 - 192) * 256 + BY[p++] + 192 }
    else { if (p + 3 > e) return 0; len = num(p, 4); p += 4 }
    if (len < 1 || p + len - 1 > e) return 0
    t = BY[p] % 128
    if (t == 28) emit(str(p + 1, p + len - 1), where)
    else if (t == 32) { if (!sig(p + 1, p + len - 1, where)) return 0 }
    else if (t == 38) { if (len < 3 || !pgp(p + 2, p + len - 1, where)) return 0 }
    else if (t == 20) {
      if (len < 9) return 0
      nl = num(p + 5, 2); vl = num(p + 7, 2)
      if (9 + nl + vl != len) return 0
      if (BY[p + 1] >= 128) emit(str(p + 9 + nl, p + 8 + nl + vl), where)
    }
    p += len
  }
  return p == e + 1
}
function sig(p, e, where,   v, w, cnt) {
  if (p > e) return 0
  v = BY[p]
  if (v == 3) return 1
  if (v != 4 && v != 5 && v != 6) return 0
  w = (v == 6) ? 4 : 2
  p += 4
  if (p + w - 1 > e) return 0
  cnt = num(p, w); p += w
  if (p + cnt - 1 > e || !subs(p, p + cnt - 1, where)) return 0
  p += cnt
  if (p + w - 1 > e) return 0
  cnt = num(p, w); p += w
  if (p + cnt - 1 > e || !subs(p, p + cnt - 1, where)) return 0
  return 1
}
function pgp(p, e, where,   h, tag, len, l1, lt, w) {
  while (p <= e) {
    h = BY[p++]
    if (h < 128) return 0
    if (int(h / 64) % 2) {
      tag = h % 64
      if (p > e) return 0
      l1 = BY[p++]
      if (l1 < 192) len = l1
      else if (l1 < 224) { if (p > e) return 0; len = (l1 - 192) * 256 + BY[p++] + 192 }
      else if (l1 == 255) { if (p + 3 > e) return 0; len = num(p, 4); p += 4 }
      else return 0
    } else {
      tag = int(h / 4) % 16; lt = h % 4
      if (lt == 3) len = e - p + 1
      else { w = (lt == 0) ? 1 : (lt == 1) ? 2 : 4; if (p + w - 1 > e) return 0; len = num(p, w); p += w }
    }
    if (p + len - 1 > e) return 0
    if (tag == 2) { if (!sig(p, p + len - 1, where)) return 0 }
    else if (tag == 13) emit(str(p, p + len - 1), where)
    else if (tag != 4 && tag != 6 && tag != 12 && tag != 14 && tag != 17) return 0
    p += len
  }
  return 1
}
function sshstrings(p, e, where,   len, s) {
  while (p <= e) {
    if (p + 3 > e) return 0
    len = num(p, 4); p += 4
    if (p + len - 1 > e) return 0
    s = str(p, p + len - 1)
    if (s ~ /^[ -~]*$/ && s ~ /@/ && s !~ /^[a-z0-9.-]+@openssh[.]com$/) emit(s, where)
    p += len
  }
  return 1
}
# v27: an SSH certificate (PROTOCOL.certkeys), field by field: its key id and principals are judged as
# identities, and its key type and extension names (`…@openssh.com`) are not. Read as printable runs,
# the key type `ssh-ed25519-cert-v01@openssh.com` was an address, so every certificate was refused.
function sshfield(p, e,   len) {
  if (p + 3 > e) return -1
  len = num(p, 4)
  return (p + 3 + len > e) ? -1 : p + 4 + len
}
function sshprincipals(p, e, where,   len, s) {
  while (p <= e) {
    if (p + 3 > e) return 0
    len = num(p, 4); p += 4
    if (p + len - 1 > e) return 0
    s = str(p, p + len - 1)
    if (s ~ /@/) emit(s, where)
    p += len
  }
  return 1
}
# (name, data) pairs; data is empty or a string holding the value. A name is a name, never an
# identity (GitHub's SSH CA names an extension `login@github.com`); a value holding an `@` is judged.
function sshopts(p, e, where,   len, s) {
  while (p <= e) {
    if (p + 3 > e) return 0
    len = num(p, 4); p += 4; if (p + len - 1 > e) return 0
    p += len
    if (p + 3 > e) return 0
    len = num(p, 4); p += 4; if (p + len - 1 > e) return 0
    if (len >= 4 && num(p, 4) == len - 4) s = str(p + 4, p + len - 1)
    else s = str(p, p + len - 1)
    if (s ~ /@/) emit(s, where)
    p += len
  }
  return 1
}
function sshkey(p, e, where,   len, t, q0, q1, s) {
  if (!sshstrings(p, e, where)) return 0
  len = num(p, 4); t = str(p + 4, p + 3 + len)
  if (t !~ /^sk-/) return 1
  while (p <= e) { len = num(p, 4); q0 = p + 4; q1 = p + 3 + len; p = q1 + 1 }
  s = str(q0, q1); if (s ~ /@/) emit(s, where)
  return 1
}
function sshcert(p, e, where,   len, t, n, k, q, q0) {
  if (p + 3 > e) return 0
  len = num(p, 4); if (p + 3 + len > e) return 0
  t = str(p + 4, p + 3 + len); p += 4 + len
  if (t ~ /^ssh-ed25519-cert/) n = 2
  else if (t ~ /^sk-ssh-ed25519-cert/) n = 3
  else if (t ~ /^ecdsa-sha2-[a-z0-9]+-cert/ || t ~ /^ssh-rsa-cert/) n = 3
  else if (t ~ /^sk-ecdsa-sha2-[a-z0-9]+-cert/) n = 4
  else if (t ~ /^ssh-dss-cert/) n = 5
  else return 0
  for (k = 1; k <= n; k++) {
    q0 = p; p = sshfield(p, e); if (p < 0) return 0
    if (k == n && t ~ /^sk-/) { q = str(q0 + 4, p - 1); if (q ~ /@/) emit(q, where) }
  }
  p += 12
  if (p + 3 > e) return 0
  len = num(p, 4); p += 4; if (p + len - 1 > e) return 0
  if (len > 0) { q = str(p, p + len - 1); if (q ~ /@/) emit(q, where) }
  p += len
  if (p + 3 > e) return 0
  len = num(p, 4); p += 4; if (p + len - 1 > e || !sshprincipals(p, p + len - 1, where)) return 0
  p += len + 16
  for (k = 1; k <= 2; k++) {
    if (p + 3 > e) return 0
    len = num(p, 4); p += 4; if (p + len - 1 > e || !sshopts(p, p + len - 1, where)) return 0
    p += len
  }
  for (k = 1; k <= 3; k++) { p = sshfield(p, e); if (p < 0) return 0 }
  return p == e + 1
}
function ssh(e, where,   p, i, len) {
  if (e < 10 || str(1, 6) != "SSHSIG") return 0
  p = 11
  for (i = 1; i <= 5; i++) {
    if (p + 3 > e) return 0
    len = num(p, 4); p += 4
    if (p + len - 1 > e) return 0
    if (i == 1) {
      if (len >= 4 && num(p, 4) <= len - 4 && str(p + 4, p + 3 + num(p, 4)) ~ /-cert-/) { if (!sshcert(p, p + len - 1, where)) return 0 }
      else if (!sshkey(p, p + len - 1, where)) return 0
    } else if (i < 5 && str(p, p + len - 1) ~ /@/) emit(str(p, p + len - 1), where)
    p += len
  }
  return p == e + 1
}
# v27: each line is read as git reads it, a trailing `\r` and spaces dropped and a BEGIN line matched by
# its prefix; a line after the checksum (`=…`) or after base64 padding makes it unreadable; in a `gpgsig` value (`required`) a line outside an armor block is judged too, and one
# with no `@` makes the signature unreadable: the value is armor blocks and nothing else. Before a
# tag's signature is its message, which the message pass reads.
function armor(text, where, required,   L, nl, i, k, ty, body, found, ok, nb, hv, tail, bad) {
  nl = split(text, L, "\n"); found = 0
  for (k = 1; k <= nl; k++) sub(/[ \t\r]+$/, "", L[k])
  for (i = 1; i <= nl; i++) {
    if (!match(L[i], /^-----BEGIN (PGP SIGNATURE|PGP MESSAGE|SSH SIGNATURE|SIGNED MESSAGE)-----/)) {
      if (required && L[i] ~ /@/) emit(L[i], where)
      else if (required && L[i] != "") unreadable(where)
      continue
    }
    ty = substr(L[i], 12, RLENGTH - 16); body = ""; ok = 0; found++; tail = 0; bad = 0
    for (i++; i <= nl; i++) {
      if (index(L[i], "-----END " ty "-----") == 1) { ok = 1; break }
      if (L[i] ~ /^=/) { if (tail == 2) bad = 1; tail = 2 }
      else if (tail && L[i] != "") bad = 1
      else if (L[i] ~ "^[A-Za-z0-9+/=]+$") { body = body L[i] "\n"; if (L[i] ~ /=/) tail = 1 }
      else if (L[i] ~ /@/) { hv = L[i]; sub(/^[^:]*:[ ]*/, "", hv); emit(hv, where) }
    }
    nb = (ok && !bad) ? decode(body) : -1
    if (nb <= 0) { unreadable(where); continue }
    if (ty ~ /^PGP/) ok = pgp(1, nb, where)
    else if (ty == "SSH SIGNATURE") ok = ssh(nb, where)
    else ok = (der(1, nb, where, 0) == nb + 1)
    if (!ok) unreadable(where)
  }
  if (required && !found) unreadable(where)
}
function object(text, otyp, osha, where, name, top,   L, nl, i, hn, hv, sp, body, j, target) {
  nl = split(text, L, "\n"); i = 1
  while (i <= nl && L[i] != "") {
    hn = L[i]; sp = index(hn, " "); hv = (sp && sp < length(hn)) ? substr(hn, sp + 1) : ""; hn = (sp > 1) ? substr(hn, 1, sp - 1) : (sp ? "" : hn)
    for (i++; i <= nl && L[i] ~ /^ /; i++) hv = hv "\n" (length(L[i]) > 1 ? substr(L[i], 2) : "")
    if (mode == "nested") {
      if (hn == "object") target = hv
      else if (hn == "type" && hv == "tag" && top) print target
    } else if (hn == "mergetag") {
      object(hv, "tag", osha, "the mergetag in commit " osha, "mergetag-message/" osha "-" (++MT), 0)
    } else if (mode != "id") {
      continue
    } else if (hn == "author" || hn == "committer" || hn == "tagger") {
      sub(/ [0-9]+ [-+][0-9][0-9][0-9][0-9]$/, "", hv); out(hv, where)
    } else if (hn == "gpgsig" || hn == "gpgsig-sha256") {
      armor(hv, "the signature of " where, 1)
    } else if ((hn " " hv) ~ /@/ && !shaped(hn, hv)) {
      out(hn " <" hv ">", where)
    }
  }
  if (otyp != "tag") return
  body = ""
  for (j = i + 1; j <= nl; j++) body = body L[j] "\n"
  if (mode == "msg") printf "%s %s\n%s", n, name, body
  else if (mode == "id") armor(body, "the signature of " where, 0)
}
function flush() {
  if (typ == "commit") object(buf, typ, sha, "commit " sha, "", 1)
  else if (typ == "tag") object(buf, typ, sha, "tag " sha, "tag-message/" sha, 1)
  buf = ""; typ = ""
}
BEGIN { b64init(); buf = ""; typ = ""; sha = ""; MT = 0 }
NF == 3 && $1 == n { flush(); sha = $2; typ = $3; next }
{ buf = buf $0 "\n" }
END { flush() }
endef
unexport gitleaks_objects gitleaks_objects_awk
gitleaks: override export GITLEAKS_OBJECTS_AWK = $(value gitleaks_objects_awk)
gitleaks: override export GIT_NO_REPLACE_OBJECTS := 1
gitleaks: override export GITLEAKS_STAGE_PY = $(value gitleaks_stage_py)
gitleaks: ## secret scan over FULL HISTORY, what an image build sends, + the commit-identity pass (the hooks cover commit/push)
	+@$(gitleaks_refusals)true
	@# A caller cannot change what this scan reads or how its failures count: make's -i and -t, in any
	@# spelling, makefile text from --eval, -I or MAKEFILES (each could set the identity allowance), a
	@# SHELL or .SHELLFLAGS from outside, a CURDIR on the command line, and at the top level a LUXLINT or
	@# LUXLINT_IMAGE from outside (`GITLEAKS_IMAGE` cannot be set at all) are refused before any pass runs,
	@# on the first line, a `+` line: make runs it under -t too, and under .ONESHELL the first line's
	@# prefix is the recipe's. Under `make check`, a variable that reached the environment of a leg
	@# is not told apart from the makefile's own, since a bare `export` in it looks the same, and a
	@# MAKELEVEL from outside looks like a leg. `-o` and `-n` from outside never reach a recipe (the
	@# emitted git hooks clear make's flags), and an untracked Makefile.local can say `.IGNORE`.
	@# A shallow clone and a graft file each make git (and so every pass) read part of the history,
	@# and the scanned-nothing check below agrees with them: both are refused before any pass. A
	@# merge commit's own changes are read against its first parent (`--diff-merges=first-parent`), in
	@# this scan and the binary and path passes: git shows a merge no diff by default, so a secret
	@# only a merge added passed every pass. A partial clone (blobs fetched on demand, which the scan
	@# container cannot do) is refused like a shallow one, and so is a scan whose git log failed partway
	@# (gitleaks reports `ERR` and still exits 0). Every log reads the root commit (`--root`), without
	@# the repository's textconv drivers or display settings, which could hide a file or the output.
	@# The scan reads the repository's git directory, never the checkout: gitleaks runs in an empty
	@# directory with `GIT_DIR` naming that git directory and that empty directory as the work tree, so
	@# no `core.worktree` the repository sets (a submodule's points outside the mounts) and no
	@# `.gitattributes` in the checkout applies. gitleaks reads a `.gitleaksignore` from the
	@# directory it scans and from its ignore path, and both are that empty directory, so no file in the
	@# checkout (tracked, untracked or excluded) waives a finding. A leak that reached history is
	@# removed from it, never waived.
	@set -e; $(GITLEAKS_HISTORY_ENV) C=$$(mktemp); O=$$(mktemp); E=$$(mktemp -d); trap 'trap "" HUP INT TERM; rm -rf "$$C" "$$O" "$$E"' EXIT; trap 'trap "" HUP INT TERM; exit 1' HUP INT TERM; \
	[ "$$(git rev-parse --is-shallow-repository)" = false ] || { echo "REFUSING: this clone is shallow, so the scan would read only part of the published history: run git fetch --unshallow first."; exit 1; }; \
	if [ -n "$$(git config --get extensions.partialClone)" ] || git config --type=bool --get-regexp '^remote\..*\.promisor$$' | grep -q ' true$$'; then \
	  echo "REFUSING: this is a partial clone, so the scan cannot read the blobs it lacks: clone the repository in full first."; exit 1; fi; \
	gf=$$(git rev-parse --path-format=absolute --git-path info/grafts); [ ! -e "$$gf" ] || { echo "REFUSING: $$gf rewrites history's parents, so the scan would skip the commits it hides: remove it (git replace --convert-graft-file) first."; exit 1; }; \
	G=$$(git -C '$(subst ','\'',$(CURDIR))' rev-parse --path-format=absolute --git-common-dir); \
	A=$$(git -C '$(subst ','\'',$(CURDIR))' rev-parse --absolute-git-dir); \
	n=$$(git -C '$(subst ','\'',$(CURDIR))' rev-list --count --all); \
	docker run --rm -v '$(subst ','\'',$(CURDIR))':/repo $(LUXLINT) --emit-config gitleaks > "$$C"; \
	rc=0; docker run --rm -e GIT_NO_REPLACE_OBJECTS=1 $(foreach kv,$(GITLEAKS_GIT_CONFIG),-e $(kv)) -e GIT_DIR="$$A" -e GIT_WORK_TREE=/scan -v "$$G":"$$G":ro -v "$$C":/gl.toml:ro -v "$$E":/scan:ro -w /scan \
	  $(GITLEAKS_IMAGE) git /scan -c /gl.toml --redact -v --ignore-gitleaks-allow --gitleaks-ignore-path /scan \
	  --log-opts='--all --full-history --root --diff-merges=first-parent --no-textconv --no-ext-diff --no-color --pretty=medium --date=default --no-abbrev-commit' > "$$O" 2>&1 || rc=$$?; \
	cat "$$O"; [ "$$rc" -eq 0 ] || exit "$$rc"; \
	if LC_ALL=C grep -Eq 'stderr is not empty|ERR[^A-Za-z]*\[git\]' "$$O"; then \
	  echo "REFUSING: git failed partway through the history scan (ERR above), so what it had not read yet was never scanned."; exit 1; \
	fi; \
	if [ "$$n" -gt 0 ] && ! grep -Eq '(^|[^0-9])[1-9][0-9]* commits scanned' "$$O"; then \
	  echo "REFUSING: gitleaks scanned no commit of a history holding $$n: the history scan read nothing (above)."; exit 1; \
	fi
	@# v12: what `gitleaks git` never reads. It scans git's PATCHES, and git prints no patch for a file it
	@# treats as binary: a NUL byte, UTF-16 (a `Localizable.strings`), or a `binary` / `-diff` attribute.
	@# A token in any of them reached the remote with "no leaks found". So every path git ever showed as
	@# binary is re-read as text, NULs stripped, and scanned by path (the config's path allowlists hold).
	@# Which paths are binary is read from an empty work tree, run there, as the history scan reads
	@# them, so a `.gitattributes` in the checkout (committed or not) calls no file text here that the
	@# scan saw no patch for.
	@set -e; $(GITLEAKS_HISTORY_ENV) C=$$(mktemp); D=$$(mktemp -d); trap 'trap "" HUP INT TERM; rm -rf "$$C" "$$D"' EXIT; trap 'trap "" HUP INT TERM; exit 1' HUP INT TERM; \
	docker run --rm -v '$(subst ','\'',$(CURDIR))':/repo $(LUXLINT) --emit-config gitleaks > "$$C"; \
	mkdir "$$D/t" "$$D/none"; \
	git log --branches --tags HEAD --format= --name-only -z --root --diff-merges=first-parent > "$$D/names"; \
	nl=$$(LC_ALL=C tr -cd '\n' < "$$D/names" | wc -c); \
	[ "$$nl" -eq 0 ] || { echo "REFUSING: a path in history holds a newline, which this scan cannot name: rename it."; exit 1; }; \
	A=$$(git -C '$(subst ','\'',$(CURDIR))' rev-parse --absolute-git-dir); \
	git -C "$$D/none" --git-dir="$$A" --work-tree="$$D/none" -c color.ui=never log --branches --tags HEAD --format= --numstat -z --no-renames --root \
	  --diff-merges=first-parent --no-ext-diff --no-textconv > "$$D/numstat"; \
	T=$$(printf '\t'); LC_ALL=C tr '\000' '\n' < "$$D/numstat" | LC_ALL=C sed -n "s/^-$$T-$$T//p" \
	  | LC_ALL=C sort -u > "$$D/binary"; \
	if [ -s "$$D/binary" ]; then \
	  while IFS= read -r f; do \
	    mkdir -p "$$D/t/$$(dirname "$$f")"; \
	    git -c color.ui=never -c diff.noprefix=false --literal-pathspecs log --branches --tags HEAD \
	      --format= -p --text --no-color --src-prefix=a/ --dst-prefix=b/ --root --diff-merges=first-parent \
	      --no-ext-diff --no-textconv -- "$$f" > "$$D/p"; \
	    LC_ALL=C grep -a '^+' "$$D/p" | LC_ALL=C tr -d '\000' > "$$D/t/$$f"; \
	  done < "$$D/binary"; \
	  $(gitleaks_no_waiver) \
	  docker run --rm -v "$$D/t":/scan:ro -w /scan -v "$$D/none":/none:ro -v "$$C":/gl.toml:ro \
	    $(GITLEAKS_IMAGE) dir . -c /gl.toml --redact -v --ignore-gitleaks-allow \
	    --gitleaks-ignore-path /none; \
	fi
	@# v13: every commit and annotated-tag MESSAGE, scanned as a file with the same config (credential
	@# rules and the denylist). One `git log` and one `for-each-ref`, split on a header line carrying a
	@# per-run nonce, so a message cannot forge a header and steer its own lines out of the scan.
	@set -e; $(GITLEAKS_HISTORY_ENV) C=$$(mktemp); D=$$(mktemp -d); trap 'trap "" HUP INT TERM; rm -rf "$$C" "$$D"' EXIT; trap 'trap "" HUP INT TERM; exit 1' HUP INT TERM; \
	docker run --rm -v '$(subst ','\'',$(CURDIR))':/repo $(LUXLINT) --emit-config gitleaks > "$$C"; \
	N=$$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n'); [ $${#N} -eq 32 ]; \
	mkdir -p "$$D/t/commit-message" "$$D/t/tag-message" "$$D/t/mergetag-message" "$$D/none"; \
	git log --branches --tags HEAD --format="$$N commit-message/%H%n%B" > "$$D/raw"; \
	X="$$D/objs"; $(gitleaks_objects) LC_ALL=C awk -v n="$$N" -v mode=msg "$$GITLEAKS_OBJECTS_AWK" "$$X.c" >> "$$D/raw"; \
	LC_ALL=C tr -d '\000' < "$$D/raw" > "$$D/msgs"; \
	LC_ALL=C awk -v n="$$N" -v d="$$D/t" \
	  '$$1 == n && NF == 2 { if (f != "") close(f); f = d "/" $$2; printf "" > f; next } \
	   f != "" { print > f }' "$$D/msgs"; \
	docker run --rm -v "$$D/t":/scan:ro -w /scan -v "$$D/none":/none:ro -v "$$C":/gl.toml:ro \
	  $(GITLEAKS_IMAGE) dir . -c /gl.toml --redact -v --ignore-gitleaks-allow \
	  --gitleaks-ignore-path /none || { \
	  echo "REFUSING: a commit or tag MESSAGE carries a finding (the File above names it:"; \
	  echo "  commit-message/<sha>, tag-message/<object> or mergetag-message/<commit>-<n>). A message is"; \
	  echo "  published with its commit"; \
	  echo "  forever. Reword it (git rebase -i, or git filter-repo --message-callback for older"; \
	  echo "  history), re-run, and ask the OWNER to approve the force-push. Never force-push unapproved."; \
	  exit 1; }
	@# v14: what a push publishes besides content and messages: every file PATH in history and every
	@# branch and tag NAME. A path is not a patch line, so `gitleaks git` never read one, and a file or
	@# a branch named for an internal host passed every gate into a public remote.
	@set -e; $(GITLEAKS_HISTORY_ENV) C=$$(mktemp); D=$$(mktemp -d); trap 'trap "" HUP INT TERM; rm -rf "$$C" "$$D"' EXIT; trap 'trap "" HUP INT TERM; exit 1' HUP INT TERM; \
	docker run --rm -v '$(subst ','\'',$(CURDIR))':/repo $(LUXLINT) --emit-config gitleaks > "$$C"; \
	mkdir -p "$$D/t" "$$D/none"; \
	git -c core.quotePath=false -c color.ui=never log --branches --tags HEAD --format= --name-only \
	  --root --diff-merges=first-parent > "$$D/names"; LC_ALL=C sort -u < "$$D/names" > "$$D/t/paths"; \
	git for-each-ref --format='%(refname:short)' refs/heads refs/tags > "$$D/t/ref-names"; \
	docker run --rm -v "$$D/t":/scan:ro -w /scan -v "$$D/none":/none:ro -v "$$C":/gl.toml:ro \
	  $(GITLEAKS_IMAGE) dir . -c /gl.toml --redact -v --ignore-gitleaks-allow \
	  --gitleaks-ignore-path /none || { \
	  echo "REFUSING: a file PATH or a branch/tag NAME carries a finding (File: paths or ref-names above)."; \
	  echo "  A name is published with the history it is in. Rename it (git mv; git branch -m; for older"; \
	  echo "  history git filter-repo --path-rename), re-run, and ask the OWNER to approve the force-push."; \
	  exit 1; }
	@# v23: what an image build SENDS. The passes above read history, and a file git does not hold (one
	@# that is untracked, or gitignored and not dockerignored) still reaches the builder, where `COPY . .`
	@# puts it in the image. History holds every tracked file as HEAD has it, so what is left to read is
	@# each file git lists as untracked (gitignored included), changed against HEAD, marked
	@# assume-unchanged or skip-worktree, under a clean/smudge `filter` attribute (git-crypt, LFS: HEAD
	@# holds the cleaned bytes, the build sends the checkout's), or inside a submodule or a nested
	@# repository. BuildKit decides
	@# which of those each build sends, by its own ignore matcher: the paths are laid out as links and
	@# built as the context (`FROM scratch`, `COPY . /`, exported with `--output type=local`) under the
	@# ignore file BuildKit reads for that build, `<Dockerfile>.dockerignore` beside its Dockerfile, else
	@# the context's `.dockerignore`. The builds are the ones the image block declares
	@# (`gitleaks_declared` above), and each other Dockerfile git holds or would add (`Dockerfile`,
	@# `Dockerfile.*`, `*.Dockerfile`, `*.dockerfile`, `Containerfile`, `*.Containerfile`; tracked, or
	@# untracked and not gitignored) at each context a makefile recipe builds it from, as make prints
	@# the recipe (`gitleaks_stage_py`'s `builds`): a recipe building `-f apps/b/Dockerfile.lint` from `.`
	@# has it read at the root, under the root's ignore file. Every recipe that builds it is read, so several
	@# contexts are each judged. One no recipe builds is read at its own directory, the context a build
	@# of that directory gives it. One a recipe builds from a context it cannot read (a shell variable,
	@# a `cd` to one, stdin), or a build command it cannot read at all, is read at its own directory and
	@# at the checkout root, beside the contexts it can. A context outside the checkout is
	@# refused. With no Dockerfile and no declared build, the untracked files git would add and the
	@# files changed against HEAD (staged included) are read instead: one commit puts them in history.
	@# What is sent is copied out and scanned by path, NULs stripped as the binary pass does. git reads
	@# this checkout as the work tree, whatever `core.worktree` the repository sets. A
	@# build no makefile recipe runs (a compose `build.context: .` for a nested Dockerfile, a script a
	@# recipe calls, a sub-make's own arguments) is judged at its Dockerfile's directory, a gitignored
	@# Dockerfile is not found, a `$(LUXLINT)` image with no make reads every undeclared
	@# Dockerfile at its own directory (a note says so), and the pass needs `docker buildx`
	@# wherever there is a Dockerfile. The host tools it runs (`cut`, `sort -u`, `dirname --`, `find
	@# -print0`, `tr`, `sed`) are POSIX (`-print0` since POSIX.1-2024), and macOS ships each of them.
	@set -e; $(GITLEAKS_HISTORY_ENV) unset GIT_INDEX_FILE; C=$$(mktemp); D=$$(mktemp -d); trap 'trap "" HUP INT TERM; rm -rf "$$C" "$$D"' EXIT; trap 'trap "" HUP INT TERM; exit 1' HUP INT TERM; \
	docker run --rm -v '$(subst ','\'',$(CURDIR))':/repo $(LUXLINT) --emit-config gitleaks > "$$C"; \
	mkdir "$$D/t" "$$D/s" "$$D/none" "$$D/df"; : > "$$D/seen"; : > "$$D/sent"; T=$$(printf '\t'); \
	W='$(subst ','\'',$(CURDIR))'; A=$$(git -C "$$W" rev-parse --absolute-git-dir); \
	g() { git -C "$$W" --git-dir="$$A" --work-tree="$$W" -c core.quotePath=false "$$@"; }; \
	g ls-files -co --exclude-standard -z > "$$D/names"; \
	g ls-files -o -z > "$$D/c0"; \
	if git --git-dir="$$A" rev-parse -q --verify 'HEAD^{tree}' > /dev/null; then g diff --name-only --no-renames --no-ext-diff -z HEAD >> "$$D/c0"; else g ls-files -c -z >> "$$D/c0"; fi; \
	g ls-files -v -z >> "$$D/c1"; g ls-files -s -z >> "$$D/c2"; g ls-files -z | g check-attr -z --stdin filter > "$$D/c3"; \
	nl=$$(cat "$$D/names" "$$D/c0" "$$D/c1" "$$D/c2" "$$D/c3" | LC_ALL=C tr -cd '\n' | wc -c); \
	[ "$$nl" -eq 0 ] || { echo "REFUSING: a path in the working tree holds a newline, which this scan cannot name: rename it."; exit 1; }; \
	{ LC_ALL=C tr '\000' '\n' < "$$D/c0"; \
	  LC_ALL=C tr '\000' '\n' < "$$D/c1" | { LC_ALL=C grep -E '^([a-z]|S) ' || true; } | LC_ALL=C cut -c 3-; \
	  LC_ALL=C tr '\000' '\n' < "$$D/c2" | LC_ALL=C sed -n "s|^160000 [0-9a-f]* [0-9]*$$T\(.*\)|\1/|p"; \
	  LC_ALL=C tr '\000' '\n' < "$$D/c3" | paste - - - | LC_ALL=C sed -n -e "/$${T}filter$${T}unspecified$$/d" -e "/$${T}filter$${T}unset$$/d" -e "s/$${T}filter$${T}[^$$T]*$$//p"; } | LC_ALL=C sort -u > "$$D/cand"; \
	LC_ALL=C tr '\000' '\n' < "$$D/names" \
	  | { LC_ALL=C grep -E '(^|/)(Dockerfile([._-][^/]+)?|dockerfile|[^/]+[._-][Dd]ockerfile|Containerfile([._-][^/]+)?|[^/]+[.]Containerfile)$$' || true; } \
	  | { LC_ALL=C grep -v '[.]dockerignore$$' || true; } > "$$D/dockerfiles"; \
	stage() { docker run --rm --network none -u "$$(id -u):$$(id -g)" -v "$$W":/w:ro -v "$$D":/d --entrypoint python3 $(LUXLINT) -c "$$GITLEAKS_STAGE_PY" "$$1" /w /d; }; \
	{ $(gitleaks_declared) :; } > "$$D/builds"; \
	if [ -s "$$D/dockerfiles" ] || [ -s "$$D/builds" ]; then \
	  docker buildx version > /dev/null 2>&1 || { echo "REFUSING: this repository has a Dockerfile or declares a build, and docker buildx is not installed, so what an image build sends cannot be staged for the scan: install it."; exit 1; }; \
	  stage farm; printf 'FROM scratch\nCOPY . /\n' > "$$D/df/Dockerfile"; \
	  LC_ALL=C cut -f 2 "$$D/builds" | LC_ALL=C sed 's|^\(\./\)*||' > "$$D/used"; \
	  docker run --rm --network none -v "$$W":/w:ro -v "$$D":/d:ro --entrypoint python3 $(LUXLINT) -c "$$GITLEAKS_STAGE_PY" builds /w /d > "$$D/made" \
	    || { echo "note: make could not be asked which builds the makefiles run, so each Dockerfile the image block does not declare is read at its own directory."; : > "$$D/made"; }; \
	  while IFS= read -r f; do \
	    ! LC_ALL=C grep -qxF -- "$$f" "$$D/used" || continue; \
	    F="$$f" LC_ALL=C awk -F "$$T" '$$3 == ENVIRON["F"] && $$1 == "B" { print $$2 FS $$3 } $$3 == ENVIRON["F"] && $$1 == "N" && $$2 != "U" { print $$2 FS }' "$$D/made" > "$$D/mine"; \
	    cat "$$D/mine" >> "$$D/builds"; \
	    LC_ALL=C grep -q . "$$D/mine" || printf '%s\t%s\n' "$$(dirname -- "$$f")" "$$f" >> "$$D/builds"; \
	    if F="$$f" LC_ALL=C awk -F "$$T" '$$1 == "U" && ($$2 == "" || $$2 == ENVIRON["F"] || substr(ENVIRON["F"], length(ENVIRON["F"]) - length($$2)) == "/" $$2) { u = 1 } $$1 == "N" && $$2 == "U" && $$3 == ENVIRON["F"] { u = 1 } END { exit !u }' "$$D/made"; then \
	      printf '%s\t%s\n' "$$(dirname -- "$$f")" "$$f" . "$$f" >> "$$D/builds"; \
	    fi; \
	  done < "$$D/dockerfiles"; \
	  while IFS="$$T" read -r c f; do \
	    case "$$c" in -|*://*|git@*) continue ;; esac; \
	    c=$$(printf '%s\n' "$$c" | LC_ALL=C sed 's|^\(\./\)*||; s|/*$$||'); \
	    case "$$c" in "$$W") c=. ;; "$$W"/*) c=$${c#"$$W"/} ;; "") c=. ;; esac; \
	    case "$$c" in /*|..|../*|*/../*|*/..) echo "REFUSING: the build context $$c is outside this checkout, so this scan cannot read what it sends: build from inside the repository."; exit 1 ;; esac; \
	    if [ -n "$$f" ] && [ -f "$$f.dockerignore" ]; then i="$$f.dockerignore"; elif [ -f "./$$c/.dockerignore" ]; then i="./$$c/.dockerignore"; else i=; fi; \
	    ! LC_ALL=C grep -qxF -- "$$c$$T$$i" "$$D/seen" || continue; printf '%s\t%s\n' "$$c" "$$i" >> "$$D/seen"; \
	    if [ -n "$$i" ]; then cp -- "$$i" "$$D/df/Dockerfile.dockerignore"; else : > "$$D/df/Dockerfile.dockerignore"; fi; \
	    rm -rf "$$D/x"; mkdir -p "$$D/x" "$$D/s/$$c"; \
	    docker buildx build -q --provenance=false --sbom=false --output "type=local,dest=$$D/x" -f "$$D/df/Dockerfile" "$$D/s/$$c" > /dev/null \
	      || { echo "REFUSING: BuildKit could not judge the context $$c (ignore file: $${i:-none}), so what it sends cannot be scanned: see its error above."; exit 1; }; \
	    (cd "$$D/x" && find . \( -type l -o -type f \) -print0) | LC_ALL=C tr '\000' '\n' \
	      | if [ "$$c" = . ]; then LC_ALL=C sed 's|^[.]/||'; else LC_ALL=C sed "s|^[.]/|$$(printf '%s' "$$c" | LC_ALL=C sed 's/[|&\\]/\\&/g')/|"; fi >> "$$D/sent"; \
	  done < "$$D/builds"; \
	  what="a file an image build would send"; fix="remove it from the working tree, or exclude it in the ignore file that build reads (.dockerignore, or <Dockerfile>.dockerignore beside the Dockerfile)"; \
	else \
	  { g ls-files -o --exclude-standard -z; \
	    if git --git-dir="$$A" rev-parse -q --verify 'HEAD^{tree}' > /dev/null; then g diff --name-only --no-renames --no-ext-diff -z HEAD; else g ls-files -c -z; fi; } \
	    | LC_ALL=C tr '\000' '\n' > "$$D/sent"; \
	  what="an untracked file git would add"; fix="remove it from the working tree, or gitignore it"; \
	fi; \
	LC_ALL=C sort -u "$$D/sent" > "$$D/n"; mv -f "$$D/n" "$$D/sent"; \
	[ ! -s "$$D/sent" ] || stage copy; \
	$(gitleaks_no_waiver) \
	docker run --rm -v "$$D/t":/scan:ro -w /scan -v "$$D/none":/none:ro -v "$$C":/gl.toml:ro \
	  $(GITLEAKS_IMAGE) dir . -c /gl.toml --redact -v --ignore-gitleaks-allow \
	  --gitleaks-ignore-path /none || { \
	  echo "REFUSING: $$what carries a finding (the File above is its path in the repository)."; \
	  echo "  History does not hold it, so the passes above never read it. To fix: $$fix."; \
	  exit 1; }
	@# The identity pass — the half gitleaks structurally cannot do. It reads every author, committer
	@# and tagger, from git's formats and from the raw objects (nested tags and `mergetag` headers
	@# included), and every address a header or a signature carries. An address in a name field, and an
	@# identity line holding more than one `<` or `>`, is refused whatever the allowance says: the
	@# allowance is anchored on the line's end, and git's formats read only the first `<...>`.
	@# v27: one name holding an address passes, a name that is exactly its own address (`a@corp <a@corp>`,
	@# byte for byte), and only when the allowance accepts that address: the shape a hosting platform's
	@# commit tool writes, which discloses nothing the address does not. Any other address in a name
	@# stays refused, including another allowed address, or the line's own in another case or with
	@# anything around it.
	@# v27: a branch, tag or notes NAME holding an `@` is an identity line too (`a ref named <refs/…>`),
	@# and notes commits (`refs/notes/*`, which a push carries when the remote is set to) are read like
	@# branches. Remote-tracking refs stay unread, as above.
	@# v27: every control byte in an identity (a NUL in a decoded signer UID, a CR in a raw header) is
	@# written as `?` before anything compares the list, and grep reads it as text (`-a`): one NUL made
	@# GNU grep call the whole list a binary file, print only that, and find no identity at all.
	@# Walks what THIS repo publishes (branches, tags, HEAD), NOT `--all`: a remote-tracking ref caches the
	@# remote's state, which during a scrub is by definition the un-rewritten history you are about to
	@# force-push over — `--all` refused the verified fix, and any `git fetch` re-armed it.
	@$(if $(filter environment% command,$(origin GIT_IDENTITY_OK)),$(error REFUSING: GIT_IDENTITY_OK comes from the $(origin GIT_IDENTITY_OK), so the caller chose which authors pass the identity pass: set it in the makefile))set -e; $(GITLEAKS_HISTORY_ENV) unset GIT_INDEX_FILE; I="$$(mktemp)"; Y="$$(mktemp -d)"; trap 'trap "" HUP INT TERM; rm -rf "$$I" "$$Y"' EXIT; trap 'trap "" HUP INT TERM; exit 1' HUP INT TERM; \
	if [ '$(subst ','\'',$(value GIT_IDENTITY_OK))' != '<214140984\+luxardolabs@users\.noreply\.github\.com>$$$$|<noreply@github\.com>$$$$' ]; then \
	  top=$$(git rev-parse --show-toplevel) && top=$$(CDPATH= cd -P -- "$$top" && pwd -P) || exit 1; \
	  rp() { readlink -f -- "$$1" 2>/dev/null || { [ ! -L "$$1" ] && d=$$(CDPATH= cd -P -- "$$(dirname -- "$$1")" 2>/dev/null && pwd -P) && printf '%s/%s\n' "$$d" "$$(basename -- "$$1")"; }; }; \
	  for f in $(foreach f,$(MAKEFILE_LIST),'$(subst ','\'',$(f))'); do \
	    r=; [ -f "$$f" ] && r=$$(rp "$$f") || r=; rel=$${r#"$$top"/}; \
	    if [ -z "$$r" ] || [ "$$rel" = "$$r" ] || ! git -C "$$top" ls-files --error-unmatch -- "$$rel" >/dev/null 2>&1 \
	      || [ "$$(git -C "$$top" hash-object -- "$$rel" 2>/dev/null)" != "$$(git -C "$$top" rev-parse -q --verify "HEAD:$$rel" 2>/dev/null)" ]; then \
	      echo "REFUSING: GIT_IDENTITY_OK is not the block's own allowance, and make reads $$f, which is not a file this repository commits, unchanged from HEAD (untracked, edited, in another repository, or named with a space): the allowance is honoured only when every makefile make reads is committed here."; exit 1; \
	    fi; \
	  done; \
	fi; \
	git log --branches --tags --glob='refs/notes/*' HEAD --pretty='%an <%ae>%n%cn <%ce>' > "$$I"; \
	git for-each-ref refs/tags --format='%(taggername) %(taggeremail)' | LC_ALL=C sed '/^ *$$/d' >> "$$I"; \
	git for-each-ref refs/heads refs/tags refs/notes --format='%(refname)' > "$$Y/refs"; LC_ALL=C sed -n 's/^\(.*@.*\)$$/a ref named <\1>/p' "$$Y/refs" >> "$$I"; \
	N=$$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n'); [ $${#N} -eq 32 ]; X="$$Y/objs"; $(gitleaks_objects) \
	LC_ALL=C awk -v n="$$N" -v mode=id "$$GITLEAKS_OBJECTS_AWK" "$$X.c" > "$$Y/w0"; LC_ALL=C tr '\000-\010\013-\037\177' '?' < "$$Y/w0" > "$$Y/where"; LC_ALL=C cut -f1 "$$Y/where" >> "$$I"; \
	LC_ALL=C tr '\000-\011\013-\037\177' '?' < "$$I" > "$$Y/ids"; cat "$$Y/ids" > "$$I"; \
	bad=$$({ LC_ALL=C grep -avE '$(GIT_IDENTITY_OK)' "$$I" || true; LC_ALL=C awk '/^[^<]*@[^<]*</ { i = index($$0, " <"); if (i > 1 && substr($$0, length($$0)) == ">" && substr($$0, 1, i - 1) == substr($$0, i + 2, length($$0) - i - 2)) next; print }' "$$I" || true; LC_ALL=C grep -avE '^[^<>]* <[^<>]*>$$' "$$I" || true; } | LC_ALL=C sort -u); \
	if [ -n "$$bad" ]; then \
	  echo "REFUSING: a non-fleet identity appears in commit or tag METADATA (author/committer/tagger/signer):"; \
	  echo "$$bad" | LC_ALL=C sed 's/^/    /'; \
	  echo "$$bad" > "$$Y/bad"; w=$$(LC_ALL=C awk -F '\t' 'NR == FNR { b[$$0]; next } ($$1 in b) { print "    " $$2 ": " $$1 }' "$$Y/bad" "$$Y/where" | LC_ALL=C sort -u); \
	  if [ -n "$$w" ]; then echo "  read from the raw objects:"; echo "$$w"; \
	    echo "  A signature carries its signer's user ID when the key is named by address: name it by"; \
	    echo "  fingerprint (git config user.signingKey <fingerprint>) or sign as the fleet identity, then rewrite."; fi; \
	  echo "gitleaks cannot see this — it scans diffs, not commit headers, so it reported no leaks."; \
	  echo "An address here is attached to every affected commit forever, not to one line of one file."; \
	  echo "Scrub per FLEET-ONBOARDING-STANDARD §2: mirror backup -> git filter-repo -> re-verify with"; \
	  echo "  git log --branches --tags --glob='refs/notes/*' HEAD --pretty='%an <%ae>%n%cn <%ce>' | sort -u"; \
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
# leak. No pass reads a `.gitleaksignore`: neither new content nor history gets a waiver. A repo file
# with that name, copied to the scan root, is renamed there before the scan and scanned like any file.
gitleaks-staged: ## secret scan of the STAGED changes (run by hooks/pre-commit)
	+@$(gitleaks_refusals)true
	@set -e; C=$$(mktemp); D=$$(mktemp -d); trap 'trap "" HUP INT TERM; rm -rf "$$C" "$$D"' EXIT; trap 'trap "" HUP INT TERM; exit 1' HUP INT TERM; \
	docker run --rm -v '$(subst ','\'',$(CURDIR))':/repo $(LUXLINT) --emit-config gitleaks > "$$C"; \
	mkdir "$$D/t" "$$D/none"; \
	git -c core.quotePath=false diff --cached --name-only --diff-filter=ACMRT -z > "$$D/names"; \
	nl=$$(LC_ALL=C tr -cd '\n' < "$$D/names" | wc -c); \
	[ "$$nl" -eq 0 ] || { echo "REFUSING: a staged path holds a newline, which this scan cannot name: rename it."; exit 1; }; \
	LC_ALL=C tr '\000' '\n' < "$$D/names" | while IFS= read -r f; do \
	  [ -n "$$f" ] || continue; \
	  mkdir -p "$$D/t/$$(dirname "$$f")"; \
	  git -c core.quotePath=false -c color.ui=never --literal-pathspecs diff --cached --text --no-color --no-ext-diff --no-textconv -U0 -- "$$f" \
	    > "$$D/p"; \
	  LC_ALL=C grep -a '^+' "$$D/p" | LC_ALL=C tr -d '\000' > "$$D/t/$$f"; \
	done; \
	$(gitleaks_no_waiver) \
	docker run --rm -v "$$D/t":/scan:ro -w /scan -v "$$D/none":/none:ro -v "$$C":/gl.toml:ro \
	  $(GITLEAKS_IMAGE) dir . -c /gl.toml --redact -v --ignore-gitleaks-allow \
	  --gitleaks-ignore-path /none

# v13: the message being WRITTEN, run by hooks/commit-msg (pre-commit cannot see it: git writes the
# message after that hook runs). The hook passes the file in `GITLEAKS_COMMIT_MSG`. The WHOLE file is
# scanned, comment lines included: `--cleanup=verbatim` publishes them, and a cut at the scissors line
# would let a verbatim message hide everything below one. No file to read is a refusal, never a pass.
gitleaks-commit-msg: ## secret + denylist scan of the commit MESSAGE being written (run by hooks/commit-msg)
	+@$(gitleaks_refusals)true
	@set -e; M="$${GITLEAKS_COMMIT_MSG:-}"; \
	if [ -z "$$M" ] || [ ! -f "$$M" ] || [ ! -r "$$M" ]; then \
	  echo "REFUSING: no commit message to scan (GITLEAKS_COMMIT_MSG='$$M'). hooks/commit-msg" >&2; \
	  echo "  passes the file git hands it; re-emit the hooks with luxlint --emit-hooks." >&2; \
	  exit 1; \
	fi; \
	C=$$(mktemp); D=$$(mktemp -d); trap 'trap "" HUP INT TERM; rm -rf "$$C" "$$D"' EXIT; trap 'trap "" HUP INT TERM; exit 1' HUP INT TERM; \
	docker run --rm -v '$(subst ','\'',$(CURDIR))':/repo $(LUXLINT) --emit-config gitleaks > "$$C"; \
	mkdir -p "$$D/t/commit-message" "$$D/none"; \
	LC_ALL=C tr -d '\000' < "$$M" > "$$D/t/commit-message/COMMIT_EDITMSG"; \
	docker run --rm -v "$$D/t":/scan:ro -w /scan -v "$$D/none":/none:ro -v "$$C":/gl.toml:ro \
	  $(GITLEAKS_IMAGE) dir . -c /gl.toml --redact -v --ignore-gitleaks-allow \
	  --gitleaks-ignore-path /none || { \
	  echo "REFUSING: this commit's MESSAGE carries a finding. A message is published with the" >&2; \
	  echo "  commit forever: reword it and commit again. Never --no-verify." >&2; \
	  exit 1; }

##@ Utilities

clean: ## Clean python/test caches
	find . -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
	find . -type f -name "*.pyc" -delete 2>/dev/null || true
	rm -rf .pytest_cache/ .mypy_cache/ .ruff_cache/ .coverage htmlcov/

clean-all: clean docker-clean ## Clean caches + local docker image tags
