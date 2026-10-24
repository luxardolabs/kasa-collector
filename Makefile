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
# LOCAL verification images for the hardware-free stacks — BARE on purpose, so they cannot be
# pushed by accident or mistaken for a deployable, and a clean clone needs no registry. The
# e2e image shares the image block's TEST_IMAGE name (`<repo>:test`, the only bare app name
# repo.compose_conventions accepts): `make test` builds the `test` stage there and `make test-e2e`
# the `production` stage, each from source immediately before it runs, so neither reads the other's.
E2E_IMAGE  := kasa-collector:test
FAKE_IMAGE := kasa-collector-fake:test

# Architecture guard (luxarch) — pinned; pulled via LUXARCH_REGISTRY (Makefile.local).
# Bump LUXARCH_VERSION when adopting new rules. Unset host → `make arch` skips gracefully.
LUXARCH_REGISTRY ?=
LUXARCH_VERSION  := 0.321.1
LUXARCH_IMAGE    ?= $(LUXARCH_REGISTRY)/luxardolabs/luxarch:$(LUXARCH_VERSION)

# Code-style + type guard (luxlint) — pinned; pulled via LUXLINT_REGISTRY (Makefile.local),
# same out-of-tree pattern as luxarch. Unset host → make lint/format skip gracefully.
LUXLINT_REGISTRY ?=
LUXLINT_VERSION  := 0.70.0
LUXLINT_IMAGE    ?= $(LUXLINT_REGISTRY)/luxardolabs/luxlint:$(LUXLINT_VERSION)
# The luxlint ref the emitted gitleaks and test blocks read. Without the fleet registry it is the
# same pinned version from the local image store, never an unversioned build.
LUXLINT = $(if $(LUXLINT_REGISTRY),$(LUXLINT_IMAGE),luxlint:$(LUXLINT_VERSION))

# Dependency-vulnerability guard (luxaudit) — pinned; pulled via LUXAUDIT_REGISTRY (Makefile.local).
# Scans poetry.lock against the live OSV+PyPA feed. Unset host → `make audit` skips gracefully.
LUXAUDIT_REGISTRY ?=
LUXAUDIT_VERSION  := 0.14.0
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

# luxarch:image-block asset v20 - DO NOT edit this marker line; it is how repo.emitted_assets_current knows your copy is current. Re-emit with `luxarch --emit image-block`.
# ── Images: ONE naming scheme, and the NAME declares what the image IS ──────────────────────────
# Emitted by `luxarch --emit image-block`. Two axes, both readable from the name alone:
#
#   Registry-qualified  ->  DEPLOY artifact  ->  built AND PUSHED
#   Bare (no registry)  ->  LOCAL artifact   ->  built from source every run, NEVER pushed
#
#   Immutable tag (:$(VERSION), :sha-…)  ->  a stack MAY pin it
#   Moving tag (:dev, :latest)           ->  a human alias; NOTHING pins it, NOTHING builds FROM it
#
# **Immutable tags are the point.** "A deployable never rolls" is why `:latest` is banned as a
# deploy tag — and `:dev` rolls identically. Every `docker push` of `:dev` silently changes what
# every stack pinned to it will run on next restart, so a moving tag cannot be a deployment record:
# you cannot say which bits are in dev, and you cannot roll back to them. One build -> one permanent
# identifier -> environments reference THAT. The sha costs nothing: this repo already computes it
# for BUILD_COMMIT.
#
# **A local-only image must not wear a registry name.** One repo's compose pulled
# `$(REGISTRY)/luxardolabs/<app>:dev` with no `build:` fallback, its Makefile never pushed it,
# the registry held ZERO tags, and a routine `docker image prune` took the service down with
# nothing to re-pull. The name promised a registry artifact; only a local one existed.
#
# Enforced by `repo.image_name_declares_provenance`.

# v18: the image names (IMAGE_NAME, IMAGES and the `img_*` helpers), where each is built from
# (BUILD_CONTEXT, DOCKERFILE), TEST_IMAGE and the quoting (`sq`, `sqw`) moved to the build core
# (`luxarch --emit build-core`), which the test block builds with too: a repo that builds and publishes
# elsewhere pastes the core and the test block, never this block. Paste the core directly ABOVE this
# block, in the same makefile: every target here refuses without it, and the inline publish guard
# below checks the core's lines as the block's own (a name either one sets is defined inside one of
# the two ranges, nowhere else).
# v14: the registry HOST is never written here. v1-v13 defaulted REGISTRY to the fleet's private host
# in this do-not-edit text, so a PUBLIC repo could not commit the block at all: its own gitleaks
# disclosure tier refuses that host in a committed file. Define it ABOVE the block: a private repo in
# its Makefile (`REGISTRY := <host>:<port>`), a public one in its gitignored `Makefile.local`
# (`-include Makefile.local` above the block). Left empty, every target that pushes or pins refuses.
REGISTRY      ?=
# v17, RECOMMENDED and optional: the registry this repo declares PRIVATE, as a literal beside REGISTRY
# (`PRIVATE_REGISTRY := <host>:<port>`). Nothing in the block can tell a private host from a public
# one, so the declaration is the fact: set, REGISTRY (every candidate before its scan, every sha-
# build) must be it, compared by host as for PUBLIC_REGISTRY, and so must RELEASE_REGISTRY when it is
# REGISTRY. Unset, nothing is checked against it.
PRIVATE_REGISTRY ?=
# v13: the registry the RELEASE goes to, the one prod pulls from. The fleet has more than one: dev
# stacks pull from the local registry above, prod at a remote host pulls from a registry it can reach
# (a public app: GHCR). v1-v12 pushed `:$(VERSION)` to REGISTRY, so a repo whose prod cannot reach it
# had to override REGISTRY on the command line for every release, and a release cut without the
# override landed where prod could not pull it. Set it above the block when prod pulls elsewhere,
# e.g. `RELEASE_REGISTRY := registry.example.com`; one registry for both needs nothing.
RELEASE_REGISTRY ?= $(REGISTRY)
# One image's tags, `$(call img_<x>,<name>)`, beside the build core's `img_*` settings helpers.
# With an EMPTY name each is the single-image VARIABLE itself, not a recomputation of it, so the ref
# checked is the ref pushed (an adversarial pass: v16 checked `$(SHA_IMAGE)` but pushed a recomputed
# ref, and re-pushed a published `:sha`). v17: none of these refs may be set from outside the
# makefile (require_registry refuses one from the command line or an `-e` environment): every pushed
# ref is derived from the makefile's own registry and name.
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

# BASE — no tag; every tag composes from it. The comment sits ABOVE the value, never after it:
# GNU make keeps the whitespace between a value and an inline `#`, so `IMAGE := …/repo   # note`
# defines IMAGE *with trailing spaces*, and every tag built from it — `…/repo   :0.1.0` — is an
# invalid docker reference. This block shipped that way from 0.197.0 and `make release` could not
# run at all; no repo had executed it, so three green rules stood over a recipe that was broken on
# its first line. Locked by test_emitted_makefiles_have_no_inline_comment_on_an_assignment.
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

# v14: the architectures a release builds. EMPTY, the default, builds the host's one architecture with
# `docker build --load`, as v13 did: everything the fleet runs itself is x86 (amd64). Set it
# only when this repo publishes an image someone ELSE runs on another architecture, as buildx's comma
# list, above this block (it picks the recipe when make reads it): `PLATFORMS := linux/amd64,linux/arm64`.
# Set, `release` and `publish-sha` build every platform once with `docker buildx build --push` on the
# shared builder (`buildx-setup`, `luxarch --emit buildx-setup`, in the same Makefile) under a
# `candidate-<commit>` tag nothing pins, scan EACH platform's image, and only then point the immutable
# tag at that candidate with `imagetools create`. The immutable tag is never built directly.
# --doc FLEET-BUILD-DEPLOY-STANDARD, "Architectures".
PLATFORMS ?=
override IMAGE_BLOCK_COMMA := ,
override PLATFORM_LIST := $(subst $(IMAGE_BLOCK_COMMA), ,$(strip $(PLATFORMS)))
# v14: where a multi-arch build pushes its candidate: REGISTRY, the private one, ALWAYS. A candidate
# exists to be scanned, and a rejected one must never be public: a release whose prod pulls from a
# public registry (RELEASE_REGISTRY := ghcr.io) would otherwise publish unscanned bits under a tag
# anyone can pull. `imagetools create` copies the scanned digest into RELEASE_REGISTRY afterwards.
override CANDIDATE     := $(IMAGE):candidate-$(COMMIT)

# ── Deploy: build AND push, always together ─────────────────────────────────────────────────────
# Never split them. A `docker build` of a registry-qualified tag with no matching push is what
# leaves a deployable name pointing at nothing.
#
# v14: every target that pushes or pins is ONE `set -e` shell: its refusals, its build, its scan and
# its push are a single recipe line. v13 put each refusal and the scan on a line of its own, and make
# carries on past a failing line under `make -i`, a `-i` in MAKEFLAGS or a `.IGNORE:`: an existing
# `:$(VERSION)` was overwritten and a failing scan still pushed. The pieces below are shell text,
# joined into that one line by each target; never give one of them a recipe line of its own.

# Named `release`, not `publish`. An earlier cut of this block called it `publish` while
# `--emit release-skill` step 11, `--doc FLEET-RELEASE-PROCESS` §8 and `repo.github_release_wired`
# all said `release` — so a repo that correctly adopted THIS asset ended up with no `release` target
# and the rule stopped looking. Adopting the newer asset was what made the older rule go quiet.
# One name, and `release` is the one the skill, the standard, the rule and every
# fleet Makefile already use.

# v17: the registries are the makefile's, never the shell's or the command line's. v16 took REGISTRY
# from wherever make found it, and the block's own `REGISTRY ?=` yields to the environment: a shell
# that had sourced an env file holding `REGISTRY=<public host>` pushed the UNSCANNED multi-arch
# candidate, and `release` the version, to the public registry. Each of REGISTRY, RELEASE_REGISTRY and
# PUBLIC_REGISTRY must come from a makefile (`$(origin)` `file`, or an `override` there), so set it
# with `:=` (which an exported shell value cannot replace) in the Makefile or Makefile.local; and
# REGISTRY, where every candidate and every `:sha` goes, is never the public registry. Hosts are
# compared lowercased, without the default port :443, with 127.x.x.x, 0.0.0.0 and [::1] as localhost
# and docker hub's index / registry-1 names as docker.io. A stated limit: the short and numeric
# spellings of a loopback address (127.1, 2130706433, 0x7f.1) are not folded.
# v17: and every ref the block pushes is DERIVED: IMAGE, CANDIDATE, SHA_IMAGE, VERSION_IMAGE and the
# rest are `:=` in the block, so the environment cannot change them, but the command line (or `make
# -e`) can, and `make publish-sha IMAGE=<public host>/…` pushed `:sha` and `:dev` there past every
# registry check, a CANDIDATE override left an unscanned candidate public, and `make release
# VERSION_IMAGE=<public>…` skipped release-public's checks. One from outside the makefile refuses.
# v17: the make INVOCATION is part of what is judged. Every variable and macro the block sets is
# `override`, so a command line (`make publish-sha require_registry=true IMAGE=…`), `make -e` or a
# MAKEFILES file cannot replace it, and `--eval=override …` is read before the block and replaced by
# it. A command-line value of one of them would be silently ignored, so it refuses instead, and so do
# `make -e` (the environment overriding the makefile), `--eval` and MAKEFILE_LIST from outside. The
# makefile make read FIRST must be this directory's default one (GNUmakefile, makefile, Makefile):
# `make -f <wrapper>` puts the wrapper's settings ahead of everything, and the clean evaluation below
# reads the default makefile, never the one `-f` named. A stated limit: a makefile that reads a file
# through HOME or PATH (`-include $(HOME)/…`) reads it in the clean evaluation too.
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
ib_host() { printf '%s\n' "$$1" | sed -e 's|/.*||' | tr 'A-Z' 'a-z' | sed -e 's/:443$$//' -e 's/^127\.[0-9]*\.[0-9]*\.[0-9]*\(:\|$$\)/localhost\1/' -e 's/^0\.0\.0\.0\(:\|$$\)/localhost\1/' -e 's/^\[::1\]\(:\|$$\)/localhost\1/' -e 's/^\(index\|registry-1\)\.docker\.io$$/docker.io/'; }; \
rh=$$(ib_host $(call sq,$(strip $(REGISTRY)))); ph=$$(ib_host $(call sq,$(strip $(PUBLIC_REGISTRY)))); \
[ -z "$$ph" ] || [ "$$rh" != "$$ph" ] || { \
  echo "REFUSING: REGISTRY is PUBLIC_REGISTRY (one host: compared lowercased, without the default port :443, localhost and 127.0.0.1 alike). REGISTRY holds every candidate before its scan and every sha- build; the public registry gets only a released, rescanned version (make release-public)"; exit 1; }; \
$(if $(filter-out file override,$(origin PRIVATE_REGISTRY)),echo "REFUSING: PRIVATE_REGISTRY comes from the shell or the command line and not a makefile: declare it above the image block as a literal"; exit 1; )\
pv=$$(ib_host $(call sq,$(strip $(PRIVATE_REGISTRY)))); lh=$$(ib_host $(call sq,$(strip $(RELEASE_REGISTRY)))); \
[ -z "$$pv" ] || [ "$$rh" = "$$pv" ] || { \
  echo "REFUSING: REGISTRY is host $$rh, not PRIVATE_REGISTRY's $$pv, the registry this repo declares private: every candidate and every sha- build goes to REGISTRY"; exit 1; }; \
[ -z "$$pv" ] || [ "$$lh" != "$$rh" ] || [ "$$lh" = "$$pv" ] || { \
  echo "REFUSING: RELEASE_REGISTRY is REGISTRY (host $$lh) but not PRIVATE_REGISTRY's $$pv"; exit 1; }; \
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
override IB_EVAL_VARS = REGISTRY RELEASE_REGISTRY PUBLIC_REGISTRY PRIVATE_REGISTRY IMAGE_NAME IMAGES PLATFORMS COMMIT VERSION \
  MIRROR_VERSION MIRROR_IMAGE_NAME $(foreach i,$(IMAGE_LIST),$(i)_IMAGE_NAME) $(IB_DERIVED_REFS)
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
override define export_head
for v in $$(env | sed -n -e 's/^\(GIT_CONFIG_KEY_[0-9][0-9]*\)=.*/\1/p' -e 's/^\(GIT_CONFIG_VALUE_[0-9][0-9]*\)=.*/\1/p'); do unset "$$v"; done; \
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE \
  GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT GIT_TEMPLATE_DIR GIT_ATTR_SOURCE; \
top=$$(git -C $(call sq,$(CURDIR)) rev-parse --show-toplevel) && pre=$$(git -C $(call sq,$(CURDIR)) rev-parse --show-prefix) && \
head=$$(git -C $(call sq,$(CURDIR)) rev-parse --verify HEAD) && short=$$(git -C $(call sq,$(CURDIR)) rev-parse --short=12 HEAD) || { \
  echo "REFUSING: git cannot name this checkout's commit, so there is nothing to build from"; exit 1; }; \
[ "$$short" = $(call sq,$(COMMIT)) ] || { \
  echo "REFUSING: this checkout is at $$short, but the image would be tagged sha-"$(call sq,$(COMMIT))": $(if $(filter command line environment%,$(origin COMMIT)),COMMIT="$(call sq,$(COMMIT))" was set $(if $(findstring command,$(origin COMMIT)),on the command line,in the environment); do not set it,a GIT_DIR / GIT_WORK_TREE (or another GIT_*) variable pointed make at another repository; unset it). sha-<commit> names the commit it is built from."; exit 1; }; \
ctxdir=$$(mktemp -d); trap '[ -z "$$ctxdir" ] || rm -rf "$$ctxdir"' EXIT; trap 'exit 1' HUP INT TERM; \
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
root=$$(cd "$$ctxdir/src" && pwd -P); cd "$$ctxdir/src/$$pre"; \
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
T=$$(mktemp); trap 'rm -f "$$T"; [ -z "$${ctxdir:-}" ] || rm -rf "$$ctxdir"' EXIT; trap 'exit 1' HUP INT TERM; \
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
pr=$(call sq,$(2)); T=$$(mktemp); trap 'rm -f "$$T"; [ -z "$${ctxdir:-}" ] || rm -rf "$$ctxdir"; docker image rm "$$pr@sha256:$$$(or $(3),h)" >/dev/null 2>&1 || true' EXIT; trap 'exit 1' HUP INT TERM; \
$(foreach p,$(or $(PLATFORM_LIST),host),docker image rm $(call sq,$(2))@sha256:$$$(or $(3),h) >/dev/null 2>&1 || true; docker pull -q $(if $(filter-out host,$(p)),--platform $(call sq,$(p)) )$(call sq,$(2))@sha256:$$$(or $(3),h); docker save $(if $(filter-out host,$(p)),--platform $(call sq,$(p)) )$(call sq,$(2))@sha256:$$$(or $(3),h) -o "$$T"; chmod 644 "$$T"; docker run --rm -v $(call sq,$(CURDIR)):/repo -v luxaudit-cache:/root/.cache/trivy -v "$$T":/candidate.tar:ro "$$ref" --image-archive /candidate.tar --image-label $(call sq,$(1) ($(p))); )$(if $(3),rm -f "$$T"; docker image rm $(call sq,$(2))@sha256:$$$(3) >/dev/null 2>&1 || true; )
endef

override define promote_create
docker buildx imagetools create $(foreach t,$(2),-t $(call sq,$(t))) $(call sq,$(1))@sha256:$$$(or $(3),h)
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
	@$(if $(and $(value sq),$(value sqw),$(value img_dockerfile)),,$(error REFUSING: the image block (v18) builds with the build core's quoting and image helpers (sq, sqw, img_*), which this makefile does not define. Paste `luxarch --emit build-core` directly above the image block))set -e; set -f; $(if $(filter-out default,$(origin MAKE_COMMAND)),echo "REFUSING: MAKE_COMMAND is set from outside the makefile"; exit 1; )$(if $(strip $(MAKEFILES)),echo "REFUSING: MAKEFILES is set so make read makefiles before this one that nobody committed or named: unset it"; exit 1; )$(if $(filter-out file,$(origin MAKEFILE_LIST)),echo "REFUSING: MAKEFILE_LIST is set from outside the makefile"; exit 1; )$(if $(filter-out default undefined,$(origin MAKECMDGOALS)),echo "REFUSING: MAKECMDGOALS is set from outside the makefile"; exit 1; )$(if $(filter command% environment%,$(origin SHELL) $(origin .SHELLFLAGS)),echo "REFUSING: SHELL or .SHELLFLAGS comes from the command line or the environment: the recipe would run in another shell"; exit 1; )$(if $(findstring x,$(filter-out --%,$(filter -%,$(.SHELLFLAGS)))),echo "REFUSING: .SHELLFLAGS traces the recipe (-x) and would print every value spliced into it"; exit 1; )\
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
	set -- $$(awk '/^# luxarch:image-block asset v[0-9]/ { m = NR; nm++ } /^# luxarch:image-block end/ { e = NR; ne++ } /^# luxarch:build-core asset v[0-9]/ { cm = NR; ncm++ } /^# luxarch:build-core end/ { ce = NR; nce++ } END { if (nm != 1 || ne != 1) { m = 0; e = 0 } if (ncm != 1 || nce != 1) { cm = 0; ce = 0 } print m + 0 " " e + 0 " " cm + 0 " " ce + 0 }' "$$ib_bf"); ib_m=$${1:-0}; ib_e=$${2:-0}; ib_cm=$${3:-0}; ib_ce=$${4:-0}; \
	[ "$$ib_m" -gt 0 ] && [ "$$ib_e" -gt "$$ib_m" ] && [ "$$ib_rn" -gt "$$ib_m" ] && [ "$$ib_rn" -lt "$$ib_e" ] || { \
	  echo "REFUSING: the recipe of "'$(subst ','\'',$@)'" make runs is $$ib_bf:$$ib_rn, which is not inside the image block: a redefinition of the target replaced it"; exit 1; }; \
	[ "$$ib_cm" -gt 0 ] && [ "$$ib_ce" -gt "$$ib_cm" ] && [ "$$ib_ce" -lt "$$ib_m" ] || { \
	  echo "REFUSING: $$ib_bf has no build core directly above the image block (exactly one core marker and one core end marker in the file, both before the block's): the block's quoting and image names are the core's, and its guard checks them there. Paste luxarch --emit build-core above the block"; exit 1; }; \
	ib_nm=$$(awk -v m="$$ib_m" -v e="$$ib_e" -v cm="$$ib_cm" -v ce="$$ib_ce" '(NR >= m && NR <= e || NR >= cm && NR <= ce) && /^override / { s = $$0; sub(/^override +(define +)?/, "", s); sub(/[ \t:=+!?].*/, "", s); printf " %s", s } END { print " " }' "$$ib_bf"); \
	ib_bad=$$(printf '%s\n' "$$ib_db" | awk -v F="$$ib_bf" -v m="$$ib_m" -v e="$$ib_e" -v cm="$$ib_cm" -v ce="$$ib_ce" -v names="$$ib_nm" -v tg='$(subst ','\'',release publish-sha release-public publish-mirror dev-deploy dev-pin gh-release $@ $(MAKECMDGOALS))' 'function bad(n, w, f, l) { if (index(names, " " n " ") && (w != "" || f != F || (l + 0 < m || l + 0 > e) && (l + 0 < cm || l + 0 > ce))) printf "%s%s at %s:%s; ", n, (w != "" ? " (" w "-specific)" : ""), f, l; else if (w != "" && index(" REGISTRY RELEASE_REGISTRY PUBLIC_REGISTRY PRIVATE_REGISTRY ", " " n " ") && reaches(sc)) printf "%s (%s-specific, %s) at %s:%s; ", n, w, sc, f, l } function reaches(p,   i, k, T, a, b) { k = split(tg, T, " "); i = index(p, "%"); for (a = 1; a <= k; a++) { if (i == 0 && T[a] == p) return 1; if (i > 0 && index(T[a], substr(p, 1, i - 1)) == 1 && length(T[a]) >= length(p) - 1 && substr(T[a], length(T[a]) - (length(p) - i) + 1) == substr(p, i + 1)) return 1 } return 0 } /^# Pattern-specific Variable Values/ { pat = 1 } /^# (Directories|Implicit Rules|Files)/ { pat = 0 } pat && /^[^#].* :$$/ { ph = $$0; sub(/ :$$/, "", ph) } /^# (makefile|\047override\047 directive|environment|environment under -e|command line|default|automatic)( \(from \047.*\047, line [0-9]+\))?$$/ { o = 1; f = ""; l = 0; if (match($$0, /\(from \047.*\047, line [0-9]+\)$$/)) { s = substr($$0, RSTART + 7, RLENGTH - 8); f = s; sub(/\047, line [0-9]+$$/, "", f); l = s; sub(/^.*\047, line /, "", l) } next } o && pat && /^# [A-Za-z_.][A-Za-z0-9_.]* (::?:?=|=|\+=|\?=|!=)/ { sc = ph; bad($$2, "pattern", f, l); o = 0; next } o && /^[^#\t ][^:]*: [A-Za-z_.][A-Za-z0-9_.]* (::?:?=|=|\+=|\?=|!=)/ { x = $$0; sc = x; sub(/:.*/, "", sc); sub(/^[^:]*: /, "", x); split(x, X, " "); bad(X[1], "target", f, l); o = 0; next } o && /^define [A-Za-z_]/ { bad($$2, "", f, l); o = 0; next } o && /^[A-Za-z_.][A-Za-z0-9_.]* (::?:?=|=|\+=|\?=|!=)/ { bad($$1, "", f, l); o = 0; next } { o = 0 }'); \
	[ -z "$$ib_bad" ] || { echo "REFUSING: make's own database (a clean evaluation with these goals) defines what the image block defines from outside the block: $${ib_bad%; }. The block's names are set inside it only."; exit 1; }; \
	$(require_registry); $(require_images)$(require_build_inputs)$(refuse_dirty_tree); $(require_scanner); \
	$(if $(IMAGE_LIST),$(publish_sha_images),$(publish_sha_one)); \
	echo "deploy it with:  make dev-deploy   (or: make dev-pin TAG=sha-"$(call sq,$(COMMIT))")"

# The GitHub Release: this version's user-facing notes on the repo's /releases page (--doc
# FLEET-RELEASE-PROCESS §9, `repo.github_release_wired`). v8: v1-v7 had no step for it, so an exact copy
# of this DO-NOT-EDIT block was red on that rule and the only ways to green were editing the block or a
# target outside `release` that nothing runs. `release` now runs it last, and checks everything it needs
# BEFORE the first push, against the REMOTE: `gh release create --verify-tag` needs the tag on GitHub, so
# a tag that exists only locally would let the image push and the Release fail. If the Release step
# still fails, re-run `make gh-release` alone: it is idempotent, and it needs the pushed tag, not HEAD
# (`release` refuses an already-released version, and HEAD moves on after the release commit).
# RELEASE_NOTES is found, not assumed: `<app>/release_notes/$(VERSION).md` wherever the app lives, up to
# three directories down (`app/`, `src/<pkg>/`, `apps/backend/app/`). Set it above this block only when
# more than one app ships notes.
# v17: the tag on origin is compared, peeled, with the commit tagged here. v16 checked only that origin
# HAD the tag: a local tag force-moved to HEAD and not pushed passed every check, the image was built
# from HEAD, and `gh release create --verify-tag` hung the Release off origin's tag, another commit.
# Now `git ls-remote origin refs/tags/v<VERSION>^{}` (an annotated tag's commit; a lightweight tag is
# its own) must equal `v<VERSION>^{commit}` here, which `release` has already required to be HEAD. A
# standalone `make gh-release` after HEAD moved on compares with the local tag, the released commit.
RELEASE_NOTES ?= $(wildcard release_notes/$(VERSION).md */release_notes/$(VERSION).md */*/release_notes/$(VERSION).md */*/*/release_notes/$(VERSION).md)

# v17: origin's `v<VERSION>`, peeled, is the commit tagged here (see RELEASE_NOTES above). gh-release
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

override define gh_release_preflight
command -v gh >/dev/null 2>&1 || { echo "REFUSING: the GitHub CLI (gh) is not installed; the release publishes its notes with it"; exit 1; }; \
gh auth status >/dev/null 2>&1 || { echo "REFUSING: gh is not authenticated (gh auth login)"; exit 1; }; \
set -- $(call sqw,$(RELEASE_NOTES)); if [ $$# -ne 1 ]; then \
  echo "REFUSING: need exactly ONE release notes file for "$(call sq,$(VERSION))", found $$#: "$(call sq,$(or $(RELEASE_NOTES),none)); \
  echo "Write <app>/release_notes/"$(call sq,$(VERSION))".md (luxarch --emit release-notes-guide), or set RELEASE_NOTES above this block."; \
  exit 1; \
fi; \
$(require_origin_tag)
endef

override define gh_release_publish
if gh release view $(call sq,v$(VERSION)) >/dev/null 2>&1; then \
  echo "GitHub Release v"$(call sq,$(VERSION))" already exists, skipped (a Release, like its tag, is immutable)"; \
else \
  gh release create $(call sq,v$(VERSION)) --verify-tag --title $(call sq,$(VERSION)) --notes-file $(call sqw,$(RELEASE_NOTES)); \
fi
endef

gh-release: ## Publish the GitHub Release for v$(VERSION) from its release notes (idempotent; `release` runs it)
	@$(if $(and $(value sq),$(value sqw),$(value img_dockerfile)),,$(error REFUSING: the image block (v18) builds with the build core's quoting and image helpers (sq, sqw, img_*), which this makefile does not define. Paste `luxarch --emit build-core` directly above the image block))set -e; set -f; $(if $(filter-out default,$(origin MAKE_COMMAND)),echo "REFUSING: MAKE_COMMAND is set from outside the makefile"; exit 1; )$(if $(strip $(MAKEFILES)),echo "REFUSING: MAKEFILES is set so make read makefiles before this one that nobody committed or named: unset it"; exit 1; )$(if $(filter-out file,$(origin MAKEFILE_LIST)),echo "REFUSING: MAKEFILE_LIST is set from outside the makefile"; exit 1; )$(if $(filter-out default undefined,$(origin MAKECMDGOALS)),echo "REFUSING: MAKECMDGOALS is set from outside the makefile"; exit 1; )$(if $(filter command% environment%,$(origin SHELL) $(origin .SHELLFLAGS)),echo "REFUSING: SHELL or .SHELLFLAGS comes from the command line or the environment: the recipe would run in another shell"; exit 1; )$(if $(findstring x,$(filter-out --%,$(filter -%,$(.SHELLFLAGS)))),echo "REFUSING: .SHELLFLAGS traces the recipe (-x) and would print every value spliced into it"; exit 1; )\
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
	set -- $$(awk '/^# luxarch:image-block asset v[0-9]/ { m = NR; nm++ } /^# luxarch:image-block end/ { e = NR; ne++ } /^# luxarch:build-core asset v[0-9]/ { cm = NR; ncm++ } /^# luxarch:build-core end/ { ce = NR; nce++ } END { if (nm != 1 || ne != 1) { m = 0; e = 0 } if (ncm != 1 || nce != 1) { cm = 0; ce = 0 } print m + 0 " " e + 0 " " cm + 0 " " ce + 0 }' "$$ib_bf"); ib_m=$${1:-0}; ib_e=$${2:-0}; ib_cm=$${3:-0}; ib_ce=$${4:-0}; \
	[ "$$ib_m" -gt 0 ] && [ "$$ib_e" -gt "$$ib_m" ] && [ "$$ib_rn" -gt "$$ib_m" ] && [ "$$ib_rn" -lt "$$ib_e" ] || { \
	  echo "REFUSING: the recipe of "'$(subst ','\'',$@)'" make runs is $$ib_bf:$$ib_rn, which is not inside the image block: a redefinition of the target replaced it"; exit 1; }; \
	[ "$$ib_cm" -gt 0 ] && [ "$$ib_ce" -gt "$$ib_cm" ] && [ "$$ib_ce" -lt "$$ib_m" ] || { \
	  echo "REFUSING: $$ib_bf has no build core directly above the image block (exactly one core marker and one core end marker in the file, both before the block's): the block's quoting and image names are the core's, and its guard checks them there. Paste luxarch --emit build-core above the block"; exit 1; }; \
	ib_nm=$$(awk -v m="$$ib_m" -v e="$$ib_e" -v cm="$$ib_cm" -v ce="$$ib_ce" '(NR >= m && NR <= e || NR >= cm && NR <= ce) && /^override / { s = $$0; sub(/^override +(define +)?/, "", s); sub(/[ \t:=+!?].*/, "", s); printf " %s", s } END { print " " }' "$$ib_bf"); \
	ib_bad=$$(printf '%s\n' "$$ib_db" | awk -v F="$$ib_bf" -v m="$$ib_m" -v e="$$ib_e" -v cm="$$ib_cm" -v ce="$$ib_ce" -v names="$$ib_nm" -v tg='$(subst ','\'',release publish-sha release-public publish-mirror dev-deploy dev-pin gh-release $@ $(MAKECMDGOALS))' 'function bad(n, w, f, l) { if (index(names, " " n " ") && (w != "" || f != F || (l + 0 < m || l + 0 > e) && (l + 0 < cm || l + 0 > ce))) printf "%s%s at %s:%s; ", n, (w != "" ? " (" w "-specific)" : ""), f, l; else if (w != "" && index(" REGISTRY RELEASE_REGISTRY PUBLIC_REGISTRY PRIVATE_REGISTRY ", " " n " ") && reaches(sc)) printf "%s (%s-specific, %s) at %s:%s; ", n, w, sc, f, l } function reaches(p,   i, k, T, a, b) { k = split(tg, T, " "); i = index(p, "%"); for (a = 1; a <= k; a++) { if (i == 0 && T[a] == p) return 1; if (i > 0 && index(T[a], substr(p, 1, i - 1)) == 1 && length(T[a]) >= length(p) - 1 && substr(T[a], length(T[a]) - (length(p) - i) + 1) == substr(p, i + 1)) return 1 } return 0 } /^# Pattern-specific Variable Values/ { pat = 1 } /^# (Directories|Implicit Rules|Files)/ { pat = 0 } pat && /^[^#].* :$$/ { ph = $$0; sub(/ :$$/, "", ph) } /^# (makefile|\047override\047 directive|environment|environment under -e|command line|default|automatic)( \(from \047.*\047, line [0-9]+\))?$$/ { o = 1; f = ""; l = 0; if (match($$0, /\(from \047.*\047, line [0-9]+\)$$/)) { s = substr($$0, RSTART + 7, RLENGTH - 8); f = s; sub(/\047, line [0-9]+$$/, "", f); l = s; sub(/^.*\047, line /, "", l) } next } o && pat && /^# [A-Za-z_.][A-Za-z0-9_.]* (::?:?=|=|\+=|\?=|!=)/ { sc = ph; bad($$2, "pattern", f, l); o = 0; next } o && /^[^#\t ][^:]*: [A-Za-z_.][A-Za-z0-9_.]* (::?:?=|=|\+=|\?=|!=)/ { x = $$0; sc = x; sub(/:.*/, "", sc); sub(/^[^:]*: /, "", x); split(x, X, " "); bad(X[1], "target", f, l); o = 0; next } o && /^define [A-Za-z_]/ { bad($$2, "", f, l); o = 0; next } o && /^[A-Za-z_.][A-Za-z0-9_.]* (::?:?=|=|\+=|\?=|!=)/ { bad($$1, "", f, l); o = 0; next } { o = 0 }'); \
	[ -z "$$ib_bad" ] || { echo "REFUSING: make's own database (a clean evaluation with these goals) defines what the image block defines from outside the block: $${ib_bad%; }. The block's names are set inside it only."; exit 1; }; \
	$(gh_release_preflight); \
	$(gh_release_publish)

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

override define release_refuse
$(call refuse_published,$(call img_version,$(1)),Bump VERSION for a new release; deploy this commit to dev with make dev-deploy. If its GitHub Release is missing: make gh-release)
endef

release: $(if $(PLATFORM_LIST),buildx-setup) ## Cut VERSION: build + scan + PUSH :$(VERSION), then the GitHub Release (refuses an already-released VERSION)
	@$(if $(and $(value sq),$(value sqw),$(value img_dockerfile)),,$(error REFUSING: the image block (v18) builds with the build core's quoting and image helpers (sq, sqw, img_*), which this makefile does not define. Paste `luxarch --emit build-core` directly above the image block))set -e; set -f; $(if $(filter-out default,$(origin MAKE_COMMAND)),echo "REFUSING: MAKE_COMMAND is set from outside the makefile"; exit 1; )$(if $(strip $(MAKEFILES)),echo "REFUSING: MAKEFILES is set so make read makefiles before this one that nobody committed or named: unset it"; exit 1; )$(if $(filter-out file,$(origin MAKEFILE_LIST)),echo "REFUSING: MAKEFILE_LIST is set from outside the makefile"; exit 1; )$(if $(filter-out default undefined,$(origin MAKECMDGOALS)),echo "REFUSING: MAKECMDGOALS is set from outside the makefile"; exit 1; )$(if $(filter command% environment%,$(origin SHELL) $(origin .SHELLFLAGS)),echo "REFUSING: SHELL or .SHELLFLAGS comes from the command line or the environment: the recipe would run in another shell"; exit 1; )$(if $(findstring x,$(filter-out --%,$(filter -%,$(.SHELLFLAGS)))),echo "REFUSING: .SHELLFLAGS traces the recipe (-x) and would print every value spliced into it"; exit 1; )\
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
	set -- $$(awk '/^# luxarch:image-block asset v[0-9]/ { m = NR; nm++ } /^# luxarch:image-block end/ { e = NR; ne++ } /^# luxarch:build-core asset v[0-9]/ { cm = NR; ncm++ } /^# luxarch:build-core end/ { ce = NR; nce++ } END { if (nm != 1 || ne != 1) { m = 0; e = 0 } if (ncm != 1 || nce != 1) { cm = 0; ce = 0 } print m + 0 " " e + 0 " " cm + 0 " " ce + 0 }' "$$ib_bf"); ib_m=$${1:-0}; ib_e=$${2:-0}; ib_cm=$${3:-0}; ib_ce=$${4:-0}; \
	[ "$$ib_m" -gt 0 ] && [ "$$ib_e" -gt "$$ib_m" ] && [ "$$ib_rn" -gt "$$ib_m" ] && [ "$$ib_rn" -lt "$$ib_e" ] || { \
	  echo "REFUSING: the recipe of "'$(subst ','\'',$@)'" make runs is $$ib_bf:$$ib_rn, which is not inside the image block: a redefinition of the target replaced it"; exit 1; }; \
	[ "$$ib_cm" -gt 0 ] && [ "$$ib_ce" -gt "$$ib_cm" ] && [ "$$ib_ce" -lt "$$ib_m" ] || { \
	  echo "REFUSING: $$ib_bf has no build core directly above the image block (exactly one core marker and one core end marker in the file, both before the block's): the block's quoting and image names are the core's, and its guard checks them there. Paste luxarch --emit build-core above the block"; exit 1; }; \
	ib_nm=$$(awk -v m="$$ib_m" -v e="$$ib_e" -v cm="$$ib_cm" -v ce="$$ib_ce" '(NR >= m && NR <= e || NR >= cm && NR <= ce) && /^override / { s = $$0; sub(/^override +(define +)?/, "", s); sub(/[ \t:=+!?].*/, "", s); printf " %s", s } END { print " " }' "$$ib_bf"); \
	ib_bad=$$(printf '%s\n' "$$ib_db" | awk -v F="$$ib_bf" -v m="$$ib_m" -v e="$$ib_e" -v cm="$$ib_cm" -v ce="$$ib_ce" -v names="$$ib_nm" -v tg='$(subst ','\'',release publish-sha release-public publish-mirror dev-deploy dev-pin gh-release $@ $(MAKECMDGOALS))' 'function bad(n, w, f, l) { if (index(names, " " n " ") && (w != "" || f != F || (l + 0 < m || l + 0 > e) && (l + 0 < cm || l + 0 > ce))) printf "%s%s at %s:%s; ", n, (w != "" ? " (" w "-specific)" : ""), f, l; else if (w != "" && index(" REGISTRY RELEASE_REGISTRY PUBLIC_REGISTRY PRIVATE_REGISTRY ", " " n " ") && reaches(sc)) printf "%s (%s-specific, %s) at %s:%s; ", n, w, sc, f, l } function reaches(p,   i, k, T, a, b) { k = split(tg, T, " "); i = index(p, "%"); for (a = 1; a <= k; a++) { if (i == 0 && T[a] == p) return 1; if (i > 0 && index(T[a], substr(p, 1, i - 1)) == 1 && length(T[a]) >= length(p) - 1 && substr(T[a], length(T[a]) - (length(p) - i) + 1) == substr(p, i + 1)) return 1 } return 0 } /^# Pattern-specific Variable Values/ { pat = 1 } /^# (Directories|Implicit Rules|Files)/ { pat = 0 } pat && /^[^#].* :$$/ { ph = $$0; sub(/ :$$/, "", ph) } /^# (makefile|\047override\047 directive|environment|environment under -e|command line|default|automatic)( \(from \047.*\047, line [0-9]+\))?$$/ { o = 1; f = ""; l = 0; if (match($$0, /\(from \047.*\047, line [0-9]+\)$$/)) { s = substr($$0, RSTART + 7, RLENGTH - 8); f = s; sub(/\047, line [0-9]+$$/, "", f); l = s; sub(/^.*\047, line /, "", l) } next } o && pat && /^# [A-Za-z_.][A-Za-z0-9_.]* (::?:?=|=|\+=|\?=|!=)/ { sc = ph; bad($$2, "pattern", f, l); o = 0; next } o && /^[^#\t ][^:]*: [A-Za-z_.][A-Za-z0-9_.]* (::?:?=|=|\+=|\?=|!=)/ { x = $$0; sc = x; sub(/:.*/, "", sc); sub(/^[^:]*: /, "", x); split(x, X, " "); bad(X[1], "target", f, l); o = 0; next } o && /^define [A-Za-z_]/ { bad($$2, "", f, l); o = 0; next } o && /^[A-Za-z_.][A-Za-z0-9_.]* (::?:?=|=|\+=|\?=|!=)/ { bad($$1, "", f, l); o = 0; next } { o = 0 }'); \
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
	$(gh_release_publish); \
	echo "released "$(call sq,$(call image_block_each,img_version))"; pin prod to TAG="$(call sq,$(VERSION))

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
override define public_refuse
$(call refuse_published,$(call img_public,$(1)),A released version is immutable: bump VERSION.); \
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
pr=$(call sq,$(2)); T=$$(mktemp); trap 'rm -f "$$T"; [ -z "$${ctxdir:-}" ] || rm -rf "$$ctxdir"; docker image rm "$$pr@sha256:$$$(or $(3),h)" >/dev/null 2>&1 || true' EXIT; trap 'exit 1' HUP INT TERM; \
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

override define public_copy
$(call promote_create,$(call img_release,$(1)),$(call img_public,$(1)) $(if $(filter 1,$(strip $(PUBLIC_LATEST))),$(call img_public_latest,$(1))),$(if $(1),h_$(1)))
endef

override public_said = $(call img_version,$(1)) as $(call img_public,$(1))

ifneq ($(strip $(PUBLIC_REGISTRY)),)
release-public: ## Copy the RELEASED :$(VERSION) to $(PUBLIC_REGISTRY) by digest after rescanning it (run `make release` first)
	@$(if $(and $(value sq),$(value sqw),$(value img_dockerfile)),,$(error REFUSING: the image block (v18) builds with the build core's quoting and image helpers (sq, sqw, img_*), which this makefile does not define. Paste `luxarch --emit build-core` directly above the image block))set -e; set -f; $(if $(filter-out default,$(origin MAKE_COMMAND)),echo "REFUSING: MAKE_COMMAND is set from outside the makefile"; exit 1; )$(if $(strip $(MAKEFILES)),echo "REFUSING: MAKEFILES is set so make read makefiles before this one that nobody committed or named: unset it"; exit 1; )$(if $(filter-out file,$(origin MAKEFILE_LIST)),echo "REFUSING: MAKEFILE_LIST is set from outside the makefile"; exit 1; )$(if $(filter-out default undefined,$(origin MAKECMDGOALS)),echo "REFUSING: MAKECMDGOALS is set from outside the makefile"; exit 1; )$(if $(filter command% environment%,$(origin SHELL) $(origin .SHELLFLAGS)),echo "REFUSING: SHELL or .SHELLFLAGS comes from the command line or the environment: the recipe would run in another shell"; exit 1; )$(if $(findstring x,$(filter-out --%,$(filter -%,$(.SHELLFLAGS)))),echo "REFUSING: .SHELLFLAGS traces the recipe (-x) and would print every value spliced into it"; exit 1; )\
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
	set -- $$(awk '/^# luxarch:image-block asset v[0-9]/ { m = NR; nm++ } /^# luxarch:image-block end/ { e = NR; ne++ } /^# luxarch:build-core asset v[0-9]/ { cm = NR; ncm++ } /^# luxarch:build-core end/ { ce = NR; nce++ } END { if (nm != 1 || ne != 1) { m = 0; e = 0 } if (ncm != 1 || nce != 1) { cm = 0; ce = 0 } print m + 0 " " e + 0 " " cm + 0 " " ce + 0 }' "$$ib_bf"); ib_m=$${1:-0}; ib_e=$${2:-0}; ib_cm=$${3:-0}; ib_ce=$${4:-0}; \
	[ "$$ib_m" -gt 0 ] && [ "$$ib_e" -gt "$$ib_m" ] && [ "$$ib_rn" -gt "$$ib_m" ] && [ "$$ib_rn" -lt "$$ib_e" ] || { \
	  echo "REFUSING: the recipe of "'$(subst ','\'',$@)'" make runs is $$ib_bf:$$ib_rn, which is not inside the image block: a redefinition of the target replaced it"; exit 1; }; \
	[ "$$ib_cm" -gt 0 ] && [ "$$ib_ce" -gt "$$ib_cm" ] && [ "$$ib_ce" -lt "$$ib_m" ] || { \
	  echo "REFUSING: $$ib_bf has no build core directly above the image block (exactly one core marker and one core end marker in the file, both before the block's): the block's quoting and image names are the core's, and its guard checks them there. Paste luxarch --emit build-core above the block"; exit 1; }; \
	ib_nm=$$(awk -v m="$$ib_m" -v e="$$ib_e" -v cm="$$ib_cm" -v ce="$$ib_ce" '(NR >= m && NR <= e || NR >= cm && NR <= ce) && /^override / { s = $$0; sub(/^override +(define +)?/, "", s); sub(/[ \t:=+!?].*/, "", s); printf " %s", s } END { print " " }' "$$ib_bf"); \
	ib_bad=$$(printf '%s\n' "$$ib_db" | awk -v F="$$ib_bf" -v m="$$ib_m" -v e="$$ib_e" -v cm="$$ib_cm" -v ce="$$ib_ce" -v names="$$ib_nm" -v tg='$(subst ','\'',release publish-sha release-public publish-mirror dev-deploy dev-pin gh-release $@ $(MAKECMDGOALS))' 'function bad(n, w, f, l) { if (index(names, " " n " ") && (w != "" || f != F || (l + 0 < m || l + 0 > e) && (l + 0 < cm || l + 0 > ce))) printf "%s%s at %s:%s; ", n, (w != "" ? " (" w "-specific)" : ""), f, l; else if (w != "" && index(" REGISTRY RELEASE_REGISTRY PUBLIC_REGISTRY PRIVATE_REGISTRY ", " " n " ") && reaches(sc)) printf "%s (%s-specific, %s) at %s:%s; ", n, w, sc, f, l } function reaches(p,   i, k, T, a, b) { k = split(tg, T, " "); i = index(p, "%"); for (a = 1; a <= k; a++) { if (i == 0 && T[a] == p) return 1; if (i > 0 && index(T[a], substr(p, 1, i - 1)) == 1 && length(T[a]) >= length(p) - 1 && substr(T[a], length(T[a]) - (length(p) - i) + 1) == substr(p, i + 1)) return 1 } return 0 } /^# Pattern-specific Variable Values/ { pat = 1 } /^# (Directories|Implicit Rules|Files)/ { pat = 0 } pat && /^[^#].* :$$/ { ph = $$0; sub(/ :$$/, "", ph) } /^# (makefile|\047override\047 directive|environment|environment under -e|command line|default|automatic)( \(from \047.*\047, line [0-9]+\))?$$/ { o = 1; f = ""; l = 0; if (match($$0, /\(from \047.*\047, line [0-9]+\)$$/)) { s = substr($$0, RSTART + 7, RLENGTH - 8); f = s; sub(/\047, line [0-9]+$$/, "", f); l = s; sub(/^.*\047, line /, "", l) } next } o && pat && /^# [A-Za-z_.][A-Za-z0-9_.]* (::?:?=|=|\+=|\?=|!=)/ { sc = ph; bad($$2, "pattern", f, l); o = 0; next } o && /^[^#\t ][^:]*: [A-Za-z_.][A-Za-z0-9_.]* (::?:?=|=|\+=|\?=|!=)/ { x = $$0; sc = x; sub(/:.*/, "", sc); sub(/^[^:]*: /, "", x); split(x, X, " "); bad(X[1], "target", f, l); o = 0; next } o && /^define [A-Za-z_]/ { bad($$2, "", f, l); o = 0; next } o && /^[A-Za-z_.][A-Za-z0-9_.]* (::?:?=|=|\+=|\?=|!=)/ { bad($$1, "", f, l); o = 0; next } { o = 0 }'); \
	[ -z "$$ib_bad" ] || { echo "REFUSING: make's own database (a clean evaluation with these goals) defines what the image block defines from outside the block: $${ib_bad%; }. The block's names are set inside it only."; exit 1; }; \
	$(require_registry); $(require_images)$(require_build_inputs)$(public_gate); $(require_scanner); \
	$(call image_block_each,public_refuse,;); \
	$(call image_block_each,public_scan)\
	$(call image_block_each,public_copy,;); \
	echo "published "$(call sq,$(call image_block_each,public_said,$(IMAGE_BLOCK_COMMA)))", the same digest"
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
# a target pins MIRROR_IMAGE. `release` and `publish-sha` never touch it. A stated limit: it is built
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
	@$(if $(and $(value sq),$(value sqw),$(value img_dockerfile)),,$(error REFUSING: the image block (v18) builds with the build core's quoting and image helpers (sq, sqw, img_*), which this makefile does not define. Paste `luxarch --emit build-core` directly above the image block))set -e; set -f; $(if $(filter-out default,$(origin MAKE_COMMAND)),echo "REFUSING: MAKE_COMMAND is set from outside the makefile"; exit 1; )$(if $(strip $(MAKEFILES)),echo "REFUSING: MAKEFILES is set so make read makefiles before this one that nobody committed or named: unset it"; exit 1; )$(if $(filter-out file,$(origin MAKEFILE_LIST)),echo "REFUSING: MAKEFILE_LIST is set from outside the makefile"; exit 1; )$(if $(filter-out default undefined,$(origin MAKECMDGOALS)),echo "REFUSING: MAKECMDGOALS is set from outside the makefile"; exit 1; )$(if $(filter command% environment%,$(origin SHELL) $(origin .SHELLFLAGS)),echo "REFUSING: SHELL or .SHELLFLAGS comes from the command line or the environment: the recipe would run in another shell"; exit 1; )$(if $(findstring x,$(filter-out --%,$(filter -%,$(.SHELLFLAGS)))),echo "REFUSING: .SHELLFLAGS traces the recipe (-x) and would print every value spliced into it"; exit 1; )\
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
	set -- $$(awk '/^# luxarch:image-block asset v[0-9]/ { m = NR; nm++ } /^# luxarch:image-block end/ { e = NR; ne++ } /^# luxarch:build-core asset v[0-9]/ { cm = NR; ncm++ } /^# luxarch:build-core end/ { ce = NR; nce++ } END { if (nm != 1 || ne != 1) { m = 0; e = 0 } if (ncm != 1 || nce != 1) { cm = 0; ce = 0 } print m + 0 " " e + 0 " " cm + 0 " " ce + 0 }' "$$ib_bf"); ib_m=$${1:-0}; ib_e=$${2:-0}; ib_cm=$${3:-0}; ib_ce=$${4:-0}; \
	[ "$$ib_m" -gt 0 ] && [ "$$ib_e" -gt "$$ib_m" ] && [ "$$ib_rn" -gt "$$ib_m" ] && [ "$$ib_rn" -lt "$$ib_e" ] || { \
	  echo "REFUSING: the recipe of "'$(subst ','\'',$@)'" make runs is $$ib_bf:$$ib_rn, which is not inside the image block: a redefinition of the target replaced it"; exit 1; }; \
	[ "$$ib_cm" -gt 0 ] && [ "$$ib_ce" -gt "$$ib_cm" ] && [ "$$ib_ce" -lt "$$ib_m" ] || { \
	  echo "REFUSING: $$ib_bf has no build core directly above the image block (exactly one core marker and one core end marker in the file, both before the block's): the block's quoting and image names are the core's, and its guard checks them there. Paste luxarch --emit build-core above the block"; exit 1; }; \
	ib_nm=$$(awk -v m="$$ib_m" -v e="$$ib_e" -v cm="$$ib_cm" -v ce="$$ib_ce" '(NR >= m && NR <= e || NR >= cm && NR <= ce) && /^override / { s = $$0; sub(/^override +(define +)?/, "", s); sub(/[ \t:=+!?].*/, "", s); printf " %s", s } END { print " " }' "$$ib_bf"); \
	ib_bad=$$(printf '%s\n' "$$ib_db" | awk -v F="$$ib_bf" -v m="$$ib_m" -v e="$$ib_e" -v cm="$$ib_cm" -v ce="$$ib_ce" -v names="$$ib_nm" -v tg='$(subst ','\'',release publish-sha release-public publish-mirror dev-deploy dev-pin gh-release $@ $(MAKECMDGOALS))' 'function bad(n, w, f, l) { if (index(names, " " n " ") && (w != "" || f != F || (l + 0 < m || l + 0 > e) && (l + 0 < cm || l + 0 > ce))) printf "%s%s at %s:%s; ", n, (w != "" ? " (" w "-specific)" : ""), f, l; else if (w != "" && index(" REGISTRY RELEASE_REGISTRY PUBLIC_REGISTRY PRIVATE_REGISTRY ", " " n " ") && reaches(sc)) printf "%s (%s-specific, %s) at %s:%s; ", n, w, sc, f, l } function reaches(p,   i, k, T, a, b) { k = split(tg, T, " "); i = index(p, "%"); for (a = 1; a <= k; a++) { if (i == 0 && T[a] == p) return 1; if (i > 0 && index(T[a], substr(p, 1, i - 1)) == 1 && length(T[a]) >= length(p) - 1 && substr(T[a], length(T[a]) - (length(p) - i) + 1) == substr(p, i + 1)) return 1 } return 0 } /^# Pattern-specific Variable Values/ { pat = 1 } /^# (Directories|Implicit Rules|Files)/ { pat = 0 } pat && /^[^#].* :$$/ { ph = $$0; sub(/ :$$/, "", ph) } /^# (makefile|\047override\047 directive|environment|environment under -e|command line|default|automatic)( \(from \047.*\047, line [0-9]+\))?$$/ { o = 1; f = ""; l = 0; if (match($$0, /\(from \047.*\047, line [0-9]+\)$$/)) { s = substr($$0, RSTART + 7, RLENGTH - 8); f = s; sub(/\047, line [0-9]+$$/, "", f); l = s; sub(/^.*\047, line /, "", l) } next } o && pat && /^# [A-Za-z_.][A-Za-z0-9_.]* (::?:?=|=|\+=|\?=|!=)/ { sc = ph; bad($$2, "pattern", f, l); o = 0; next } o && /^[^#\t ][^:]*: [A-Za-z_.][A-Za-z0-9_.]* (::?:?=|=|\+=|\?=|!=)/ { x = $$0; sc = x; sub(/:.*/, "", sc); sub(/^[^:]*: /, "", x); split(x, X, " "); bad(X[1], "target", f, l); o = 0; next } o && /^define [A-Za-z_]/ { bad($$2, "", f, l); o = 0; next } o && /^[A-Za-z_.][A-Za-z0-9_.]* (::?:?=|=|\+=|\?=|!=)/ { bad($$1, "", f, l); o = 0; next } { o = 0 }'); \
	[ -z "$$ib_bad" ] || { echo "REFUSING: make's own database (a clean evaluation with these goals) defines what the image block defines from outside the block: $${ib_bad%; }. The block's names are set inside it only."; exit 1; }; \
	$(require_mirror); $(require_registry); $(require_images)$(require_build_inputs)$(refuse_dirty_tree); $(require_scanner); \
	$(call refuse_published,$(MIRROR_IMAGE),A mirror tag is immutable: bump MIRROR_VERSION to mirror another upstream version.); \
	$(export_head); \
	$(call export_contained,MIRROR); \
	docker build --load --target $(call sq,$(call img_target,MIRROR)) $(call sqw,$(BUILD_ARGS)) --build-arg $(call sq,MIRROR_VERSION=$(MIRROR_VERSION)) -f $(call sq,$(call img_dockerfile,MIRROR)) -t $(call sq,$(MIRROR_IMAGE)) $(call sq,$(call img_context,MIRROR)); \
	$(call scan_candidate,$(MIRROR_IMAGE)); \
	docker push $(call sq,$(MIRROR_IMAGE)); \
	$(export_leave); \
	echo "mirrored "$(call sq,$(MIRROR_IMAGE))": pin it as MIRROR_IMAGE"

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
DEV_DEPLOY ?= compose
DEV_OVERLAY ?= k8s/overlays/dev
DEV_PRE_OVERLAYS ?=
DEV_KUSTOMIZE ?= kubectl kustomize
DEV_KUBECTL ?= kubectl

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
tmp=$$(mktemp); trap 'rm -f "$$tmp" "$$tmp.err" "$$tmp.now" "$$tmp.boot" "$$tmp.a" "$$tmp.b" "$$tmp.probe.yml" "$$tmp.pb" "$$tmp.pn" "$$tmp.vb" "$$tmp.vn"; [ -z "$${pindir:-}" ] || rm -rf "$$pindir"' EXIT; trap 'exit 1' HUP INT TERM; \
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

# v10: a deploy ends by probing what it deployed (`luxarch --emit smoke`, pasted below this block). A
# deploy that restarted the stack is not one that works: the suite runs in-process and cannot see the
# proxy, the server, the production image or a standalone entry point.
dev-deploy: ## Build+push THIS commit (:sha-…, never the version), pin $(DEV_ENV_FILE) to it, restart the dev stack, smoke it
	@$(if $(and $(value sq),$(value sqw),$(value img_dockerfile)),,$(error REFUSING: the image block (v18) builds with the build core's quoting and image helpers (sq, sqw, img_*), which this makefile does not define. Paste `luxarch --emit build-core` directly above the image block))$(MAKE) --no-print-directory publish-sha
	@$(MAKE) --no-print-directory dev-pin TAG=sha-$(call sq,$(COMMIT))
	@$(MAKE) --no-print-directory smoke

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
case $(call sq,$(DEV_DEPLOY)) in compose|kustomize) ;; *) \
  echo "REFUSING: DEV_DEPLOY must be compose or kustomize, not "$(call sq,$(DEV_DEPLOY)); exit 1 ;; esac
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
kd=$$(mktemp -d); trap 'rm -rf "$$kd"' EXIT; \
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
ki=0; while [ "$$ki" -lt "$$kn" ]; do ki=$$((ki + 1)); ka=$$kd/$$ki.apply.yaml; ov=$$(cat "$$kd/$$ki.name"); \
  kw=$$(awk 'function out() { if (k != "" && nm != "") print k "|" nm "|" ns } /^---/ { out(); k = ""; nm = ""; ns = ""; md = 0; next } /^kind:[ \t]/ { k = $$2 } /^metadata:/ { md = 1; next } /^[^ \t]/ { md = 0 } md && /^  name:[ \t]/ { nm = $$2 } md && /^  namespace:[ \t]/ { ns = $$2 } END { out() }' "$$ka" | tr -d "\"'"); \
  for w in $$kw; do case "$${w%%|*}" in Job) r=$${w#*|}; nm=$${r%%|*}; ns=$${r#*|}; set -- $${ns:+-n "$$ns"}; \
    $(call sqw,$(DEV_KUBECTL)) delete "$$@" "job/$$nm" --ignore-not-found >/dev/null || { echo "FAIL  could not delete the previous job/$$nm$${ns:+ (namespace $$ns)} before applying $$ov"; exit 1; } ;; esac; done; \
  $(call sqw,$(DEV_KUBECTL)) apply -f - < "$$ka" >/dev/null || { echo "FAIL  kubectl apply of the rendered dev overlay $$ov failed"; exit 1; }; \
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
ib_up_hint() { echo "If a service runs once and exits (restart: \"no\"), declare it one-shot: the service that needs it gets depends_on: <it>: condition: service_completed_successfully. dev-pin then waits only for the long-running services and judges it by exiting 0."; }; \
if [ -z "$$once" ] || [ -z "$$long" ]; then \
  $(dev_compose) up -d --wait --wait-timeout $(call sq,$(DEV_WAIT_TIMEOUT)) || { ib_up_hint; exit 1; }; \
else \
  $(dev_compose) up -d --wait --wait-timeout $(call sq,$(DEV_WAIT_TIMEOUT)) $$long || { ib_up_hint; exit 1; }; \
  for s in $$once; do st=$$($(dev_compose) ps -a --format '{{.State}} {{.ExitCode}}' "$$s" | sort -u); \
    [ "$$st" = "exited 0" ] || { echo "FAIL: the one-shot service $$s did not exit 0 (compose reports: $${st:-no container}), so the dev stack is not up"; exit 1; }; done; \
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
	@$(if $(and $(value sq),$(value sqw),$(value img_dockerfile)),,$(error REFUSING: the image block (v18) builds with the build core's quoting and image helpers (sq, sqw, img_*), which this makefile does not define. Paste `luxarch --emit build-core` directly above the image block))set -e; set -f; $(if $(filter-out default,$(origin MAKE_COMMAND)),echo "REFUSING: MAKE_COMMAND is set from outside the makefile"; exit 1; )$(if $(strip $(MAKEFILES)),echo "REFUSING: MAKEFILES is set so make read makefiles before this one that nobody committed or named: unset it"; exit 1; )$(if $(filter-out file,$(origin MAKEFILE_LIST)),echo "REFUSING: MAKEFILE_LIST is set from outside the makefile"; exit 1; )$(if $(filter-out default undefined,$(origin MAKECMDGOALS)),echo "REFUSING: MAKECMDGOALS is set from outside the makefile"; exit 1; )$(if $(filter command% environment%,$(origin SHELL) $(origin .SHELLFLAGS)),echo "REFUSING: SHELL or .SHELLFLAGS comes from the command line or the environment: the recipe would run in another shell"; exit 1; )$(if $(findstring x,$(filter-out --%,$(filter -%,$(.SHELLFLAGS)))),echo "REFUSING: .SHELLFLAGS traces the recipe (-x) and would print every value spliced into it"; exit 1; )\
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
	set -- $$(awk '/^# luxarch:image-block asset v[0-9]/ { m = NR; nm++ } /^# luxarch:image-block end/ { e = NR; ne++ } /^# luxarch:build-core asset v[0-9]/ { cm = NR; ncm++ } /^# luxarch:build-core end/ { ce = NR; nce++ } END { if (nm != 1 || ne != 1) { m = 0; e = 0 } if (ncm != 1 || nce != 1) { cm = 0; ce = 0 } print m + 0 " " e + 0 " " cm + 0 " " ce + 0 }' "$$ib_bf"); ib_m=$${1:-0}; ib_e=$${2:-0}; ib_cm=$${3:-0}; ib_ce=$${4:-0}; \
	[ "$$ib_m" -gt 0 ] && [ "$$ib_e" -gt "$$ib_m" ] && [ "$$ib_rn" -gt "$$ib_m" ] && [ "$$ib_rn" -lt "$$ib_e" ] || { \
	  echo "REFUSING: the recipe of "'$(subst ','\'',$@)'" make runs is $$ib_bf:$$ib_rn, which is not inside the image block: a redefinition of the target replaced it"; exit 1; }; \
	[ "$$ib_cm" -gt 0 ] && [ "$$ib_ce" -gt "$$ib_cm" ] && [ "$$ib_ce" -lt "$$ib_m" ] || { \
	  echo "REFUSING: $$ib_bf has no build core directly above the image block (exactly one core marker and one core end marker in the file, both before the block's): the block's quoting and image names are the core's, and its guard checks them there. Paste luxarch --emit build-core above the block"; exit 1; }; \
	ib_nm=$$(awk -v m="$$ib_m" -v e="$$ib_e" -v cm="$$ib_cm" -v ce="$$ib_ce" '(NR >= m && NR <= e || NR >= cm && NR <= ce) && /^override / { s = $$0; sub(/^override +(define +)?/, "", s); sub(/[ \t:=+!?].*/, "", s); printf " %s", s } END { print " " }' "$$ib_bf"); \
	ib_bad=$$(printf '%s\n' "$$ib_db" | awk -v F="$$ib_bf" -v m="$$ib_m" -v e="$$ib_e" -v cm="$$ib_cm" -v ce="$$ib_ce" -v names="$$ib_nm" -v tg='$(subst ','\'',release publish-sha release-public publish-mirror dev-deploy dev-pin gh-release $@ $(MAKECMDGOALS))' 'function bad(n, w, f, l) { if (index(names, " " n " ") && (w != "" || f != F || (l + 0 < m || l + 0 > e) && (l + 0 < cm || l + 0 > ce))) printf "%s%s at %s:%s; ", n, (w != "" ? " (" w "-specific)" : ""), f, l; else if (w != "" && index(" REGISTRY RELEASE_REGISTRY PUBLIC_REGISTRY PRIVATE_REGISTRY ", " " n " ") && reaches(sc)) printf "%s (%s-specific, %s) at %s:%s; ", n, w, sc, f, l } function reaches(p,   i, k, T, a, b) { k = split(tg, T, " "); i = index(p, "%"); for (a = 1; a <= k; a++) { if (i == 0 && T[a] == p) return 1; if (i > 0 && index(T[a], substr(p, 1, i - 1)) == 1 && length(T[a]) >= length(p) - 1 && substr(T[a], length(T[a]) - (length(p) - i) + 1) == substr(p, i + 1)) return 1 } return 0 } /^# Pattern-specific Variable Values/ { pat = 1 } /^# (Directories|Implicit Rules|Files)/ { pat = 0 } pat && /^[^#].* :$$/ { ph = $$0; sub(/ :$$/, "", ph) } /^# (makefile|\047override\047 directive|environment|environment under -e|command line|default|automatic)( \(from \047.*\047, line [0-9]+\))?$$/ { o = 1; f = ""; l = 0; if (match($$0, /\(from \047.*\047, line [0-9]+\)$$/)) { s = substr($$0, RSTART + 7, RLENGTH - 8); f = s; sub(/\047, line [0-9]+$$/, "", f); l = s; sub(/^.*\047, line /, "", l) } next } o && pat && /^# [A-Za-z_.][A-Za-z0-9_.]* (::?:?=|=|\+=|\?=|!=)/ { sc = ph; bad($$2, "pattern", f, l); o = 0; next } o && /^[^#\t ][^:]*: [A-Za-z_.][A-Za-z0-9_.]* (::?:?=|=|\+=|\?=|!=)/ { x = $$0; sc = x; sub(/:.*/, "", sc); sub(/^[^:]*: /, "", x); split(x, X, " "); bad(X[1], "target", f, l); o = 0; next } o && /^define [A-Za-z_]/ { bad($$2, "", f, l); o = 0; next } o && /^[A-Za-z_.][A-Za-z0-9_.]* (::?:?=|=|\+=|\?=|!=)/ { bad($$1, "", f, l); o = 0; next } { o = 0 }'); \
	[ -z "$$ib_bad" ] || { echo "REFUSING: make's own database (a clean evaluation with these goals) defines what the image block defines from outside the block: $${ib_bad%; }. The block's names are set inside it only."; exit 1; }; \
	$(require_registry); $(require_images)$(require_dev_deploy); $(require_dev_env_file); $(require_pin_tag); \
	$(call image_block_each,dev_pin_check,;); \
	$(if $(filter kustomize,$(DEV_DEPLOY)),$(dev_kustomize),$(call pin_env_tag,$(DEV_ENV_FILE),$(TAG),$(foreach p,$(DEV_PROFILES),--profile $(p)),$(call image_block_each,img_base,)); $(dev_up))

# ── Verify: build from source, locally, every run ───────────────────────────────────────────────
# The test image must carry the SAME app layers production ships, plus the dev group. Two Dockerfile
# shapes do that, and either is canonical:
#   - `FROM production AS test`, putting back what production stripped (`python -m ensurepip`)
#     before `poetry install --with dev`;
#   - one shared `app` stage that both `test` and `production` build FROM, when production also
#     strips poetry. v3 said only "FROM production", which a production stage hardened per
#     FLEET-BUILD-DEPLOY-STANDARD (no pip/poetry in the runtime) cannot satisfy literally.
# Either way the Dockerfile needs a stage named `test`: this target builds it. v16, IMAGES set: the
# first image's, the one the suite runs in (TEST_IMAGE).

test-build: ## Build the LOCAL test image from source (never pushed, never a deploy tag)
	@$(if $(and $(value sq),$(value sqw),$(value img_dockerfile)),,$(error REFUSING: the image block (v18) builds with the build core's quoting and image helpers (sq, sqw, img_*), which this makefile does not define. Paste `luxarch --emit build-core` directly above the image block))set -f; docker build --load --target test $(call sqw,$(BUILD_ARGS)) -f $(call sq,$(call img_dockerfile,$(IMAGE_PRIMARY))) -t $(call sq,$(TEST_IMAGE)) $(call sq,$(call img_context,$(IMAGE_PRIMARY))) >/dev/null
# luxarch:image-block end - DO NOT edit this marker line: the block's runtime guard reads its range.

# Smoke settings: this collector serves no HTTP, so the deployed stack is probed through its
# container (it must run this commit and reach healthy by its own HEALTHCHECK) and its two real
# entry points are imported in the production image. SMOKE_URL stays empty on purpose.
SMOKE_CONTAINERS := kasa-collector
SMOKE_ENTRY_MODULES := app.main app.health.check

# luxarch:smoke asset v9 - DO NOT edit this marker line; it is how repo.emitted_assets_current knows your copy is current. Re-emit with `luxarch --emit smoke`.
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
# Settings are `?=` defaults: override them above this block (or in Makefile.local for a host name).

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
	[ -n "$(strip $(SMOKE_URL)$(SMOKE_CONTAINERS))" ] || { echo "REFUSING: set SMOKE_URL to the dev stack's address (Makefile.local), or SMOKE_CONTAINERS to its containers when it serves no HTTP"; exit 2; }; \
	probe() { curl -sS --max-time 15 $(SMOKE_CURL_OPTS) -o "$$B" -w '%{http_code} %{content_type}' "$$@" 2>/dev/null || echo "000 -"; }; \
	B=$$(mktemp); trap 'rm -f "$$B"' EXIT INT TERM; \
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
	  *) echo "PASS  forged Host refused ($${r%% *})";; esac; \
	if [ -n "$(SMOKE_AUTH_PATH)" ]; then \
	  r=$$(probe "$(SMOKE_URL)$(SMOKE_AUTH_PATH)"); \
	  case "$${r%% *}" in 401|403) echo "PASS  $(SMOKE_AUTH_PATH) refuses a request with no credentials ($${r%% *})";; \
	    *) echo "FAIL  $(SMOKE_AUTH_PATH) answered a request with NO credentials ($$r): it is not protected"; fail=1;; esac; \
	  if [ -z "$${SMOKE_AUTH_TOKEN:-}" ]; then echo "FAIL  SMOKE_AUTH_PATH is set but SMOKE_AUTH_TOKEN is not in the environment"; fail=1; \
	  else r=$$(probe -H "Authorization: Bearer $${SMOKE_AUTH_TOKEN}" "$(SMOKE_URL)$(SMOKE_AUTH_PATH)"); \
	    if [ "$${r%% *}" = 200 ]; then echo "PASS  authenticated request ($(SMOKE_AUTH_PATH))"; \
	    else echo "FAIL  authenticated $(SMOKE_AUTH_PATH): $$r"; fail=1; fi; fi; \
	else echo "NOT RUN  authenticated request: SMOKE_AUTH_PATH is empty"; fi; \
	fi; \
	settle=$(SMOKE_HEALTH_SETTLE); healthy=; \
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
	if [ -d "$(SMOKE_SCRIPTS_DIR)" ]; then for f in $$(find "$(SMOKE_SCRIPTS_DIR)" -name '*.py' ! -name '__init__.py' | sort); do \
	  rel=$$(realpath --relative-to="$(SMOKE_IMPORT_ROOT)" "$$f"); mods="$$mods $$(printf '%s' "$${rel%.py}" | tr / .)"; done; fi; \
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
	exit $$fail

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

# luxarch:guard-upgrade asset v4 - DO NOT edit this marker line; it is how repo.emitted_assets_current knows your copy is current. Re-emit with `luxarch --emit guard-upgrade`.
# Bumps each guard pin to its latest release and prints the rules the new luxarch adds (`--new-rules`).
# The preview mounts `$(CURDIR)`, this makefile's directory, whatever directory `make -C` ran from.
# Latest is the registry's `:latest`, or with REGISTRY empty (guards loaded from the release tarball)
# the highest released `<guard>:X.Y.Z` on this machine, never `:local`. The pin is rewritten with `sed`
# into a temporary file beside the Makefile (its mode copied first), renamed over it (`mv`, one atomic
# step: a failed write leaves the Makefile as it was), then read back: the same on macOS and Linux.
# A guard whose latest cannot be read is named and fails the run: "all pins already at latest" is
# printed only when every guard was read.
guard-upgrade:  ## Bump every guard pin to the published latest (prints what newly bites)
	@unread=; checked=; bumped=; for g in luxarch luxlint luxaudit; do \
	  if [ -n "$(REGISTRY)" ]; then \
	    img=$(REGISTRY)/luxardolabs/$$g; src="$$img:latest"; \
	    docker pull -q $$img:latest >/dev/null 2>&1 || true; \
	    latest=$$(docker run --rm $$img:latest --version 2>/dev/null | awk '{print $$2}'); \
	  else \
	    img=$$g; src="a released $$g:X.Y.Z image on this machine (REGISTRY is empty)"; \
	    latest=$$(docker images --format '{{.Tag}}' $$g 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$$' | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1); \
	  fi; \
	  var=$$(echo $$g | tr a-z A-Z)_VERSION; \
	  old=$$(sed -n -E "s/^$$var[[:space:]]*:=[[:space:]]*//p" Makefile); \
	  if [ -z "$$old" ]; then echo "!! no $$var pin found in Makefile — NOT bumped"; unread="$$unread $$g"; continue; fi; \
	  if [ -z "$$latest" ]; then echo "!! could not read $$src — $$var left at $$old"; unread="$$unread $$g"; continue; fi; \
	  checked=1; \
	  tmp=$$(mktemp ./.guard-upgrade.XXXXXX) && cp -p Makefile "$$tmp" && sed -E "s|^($$var[[:space:]]*:=[[:space:]]*).*|\\1$$latest|" Makefile > "$$tmp" && mv -f "$$tmp" Makefile; rc=$$?; \
	  if [ "$$rc" != 0 ]; then rm -f "$$tmp"; echo "!! could not rewrite Makefile (it is unchanged) — $$var NOT bumped"; exit 1; fi; \
	  new=$$(sed -n -E "s/^$$var[[:space:]]*:=[[:space:]]*//p" Makefile); \
	  if [ "$$new" != "$$latest" ]; then echo "!! $$var did NOT change (still $$new)"; exit 1; fi; \
	  if [ "$$old" != "$$latest" ]; then echo "$$var $$old -> $$latest"; bumped=1; fi; \
	  [ "$$g" = luxarch ] && [ "$$old" != "$$latest" ] && docker run --rm -v "$(CURDIR)":/repo $$img:$$latest --new-rules --since $$old || true; \
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

# luxarch:test-block asset v8 - DO NOT edit this marker line; it is how repo.emitted_assets_current knows your copy is current. Re-emit with `luxarch --emit test-block`.
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
#   - READINESS from each service's own compose healthcheck (`up --wait`), not a sleep or a loop:
#     the service declares when it is ready. For Postgres, probe over TCP with the real role
#     (`pg_isready -h 127.0.0.1 -U <user> -d <db>`); over the socket it answers while initdb's
#     temporary server is still up. `repo.test_stack_parity` checks these are the services prod runs.
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
#     block's included, is loaded; its own conftest.py builds and drops its databases. A one-off
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
# `_TEST_WORKDIR`, `_TEST_COV`, `_TEST_FLOOR`, `_TEST_MIGRATIONS`, `_TEST_MOUNTS` and
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
# and those left out: each left out must be measured, and by one suite.
test_suite_mount_srcs = $(sort $(foreach w,$(filter-out -v,$(call test_suite,$(1),MOUNTS)),$(foreach h,$(firstword $(subst :, ,$(w))),$(or $(realpath $(h)),$(abspath $(h))))))
test_overlay_measured = $(foreach s,$(test_suites),$(if $(filter 1,$(call test_suite,$(s),OVERLAY_COV)),$(call test_suite_mount_srcs,$(s))))
test_overlay_unmeasured = $(filter-out $(test_overlay_measured),$(foreach s,$(test_suites),$(if $(filter 1,$(call test_suite,$(s),OVERLAY_COV)),,$(call test_suite_mount_srcs,$(s)))))

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
	D=$$(mktemp -d "$${TMPDIR:-/tmp}/luxarch-test.XXXXXXXXXXXX") || { echo "REFUSING: could not make this run's directory"; exit 2; }; \
	tok=$$(basename "$$D" | sed 's/^luxarch-test\.//' | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9'); \
	[ $${#tok} -ge 8 ] || { echo "REFUSING: could not make a unique name for this run"; rm -rf "$$D"; exit 2; }; \
	printf '%s\n%s\n%s\n%s\n%s\n' "$$$$" "$$ns" "$$co" "$$boot" "$$machine" > "$$D/owner" || { rm -rf "$$D"; exit 2; }; \
	[ -z $(call sq,$(TEST_ENV_FILE)) ] || [ -f $(call sq,$(TEST_ENV_FILE)) ] || { printf 'REFUSING: TEST_ENV_FILE is %s, which this checkout does not have: compose would fail on interpolation. Commit it (test-suite.env), or set TEST_ENV_FILE to a committed file\n' $(call sq,$(TEST_ENV_FILE)); rm -rf "$$D"; exit 2; }; \
	[ $(words $(test_suite_floors)) = $(words $(sort $(test_suite_floors))) ] || { printf 'REFUSING: two suites would share one coverage floor (%s): give each its own <suite>_TEST_FLOOR\n' $(call sq,$(foreach s,$(test_suites),$(s)=$(call test_suite,$(s),FLOOR))); rm -rf "$$D"; exit 2; }; \
	[ -z $(call sq,$(findstring %,$(foreach s,$(test_suites),$(call test_suite,$(s),MOUNTS)))) ] || { echo 'REFUSING: a TEST_MOUNTS path holds %, which make reads as a pattern: each path is letters, digits and ._/@+-'; rm -rf "$$D"; exit 2; }; \
	[ -z $(call sq,$(strip $(test_overlay_unmeasured))) ] || { printf 'REFUSING: no suite measures the overlay %s, and every suite mounting it leaves it out of its coverage: set <suite>_TEST_OVERLAY_COV := 1 on the suite holding its tests\n' $(call sq,$(strip $(test_overlay_unmeasured))); rm -rf "$$D"; exit 2; }; \
	[ $(words $(test_overlay_measured)) = $(words $(sort $(test_overlay_measured))) ] || { printf 'REFUSING: two suites measure one overlay (%s): it counts in one ratchet, so set <suite>_TEST_OVERLAY_COV := 1 on one suite only\n' $(call sq,$(strip $(test_overlay_measured))); rm -rf "$$D"; exit 2; }; \
	stop="$$D/stop"; kid=; insuite=; fast=$(if $(filter default,$(origin MAKECMDGOALS)),$(if $(filter test,$(MAKECMDGOALS)),,$(if $(filter test-fast,$(MAKECMDGOALS)),1))); \
	kids() { p=$$1; if command -v pgrep >/dev/null 2>&1; then pgrep -P "$$p"; else set +f; for f in /proc/[0-9]*/stat; do read -r l < "$$f" 2>/dev/null || continue; set -- $${l##*)}; [ "$${2:-}" = "$$p" ] && { c=$${f#/proc/}; echo "$${c%/stat}"; }; done; set -f; fi; }; \
	tree() { for c in $$(kids "$$1"); do tree "$$c"; done; kill -TERM "$$1" 2>/dev/null; }; \
	trap 'rm -rf "$$D"' EXIT; \
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
	  trap 'ok=; for t in 1 2 3; do dc down --volumes --remove-orphans >/dev/null 2>&1; [ -z "$$(docker network ls -q --filter "label=com.docker.compose.project=$$p"; docker volume ls -q --filter "label=com.docker.compose.project=$$p")" ] && { ok=1; break; }; done; if [ -n "$$ok" ]; then docker rmi -f "$$img" >/dev/null 2>&1; else printf "FAIL  the test stack %s did not come down (its networks or volumes remain): make test-reap removes it once they are free\n" "$$p"; exit 1; fi' EXIT; \
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
	  net=; if [ -n $(call sq,$(strip $(call test_suite,$(s),SERVICES))) ]; then \
	    bg dc up -d --wait --wait-timeout 120 $(call sqw,$(call test_suite,$(s),SERVICES)) \
	      || { printf 'FAIL  the test services did not become healthy: %s\n' $(call sq,$(call test_suite,$(s),SERVICES)); exit 1; }; \
	    cid=$$(dc ps -q $(call sq,$(firstword $(call test_suite,$(s),SERVICES)))); net=; \
	    for n in $$(docker inspect -f '{{range $$k, $$v := .NetworkSettings.Networks}}{{$$k}} {{end}}' $$cid); do \
	      [ "$$(docker network inspect -f '{{index .Labels "com.docker.compose.project"}}' $$n)" = "$$p" ] && { net=$$n; break; }; done; \
	    [ -n "$$net" ] || { printf 'FAIL  %s joined no network of this run'"'"'s own project (%s)\n' $(call sq,$(firstword $(call test_suite,$(s),SERVICES))) "$$p"; exit 1; }; \
	    net="--network $$net"; fi; \
	  bg docker run --rm --init $$lab --label "luxarch.test-block.checkout=$$co" -e TINI_KILL_PROCESS_GROUP=1 $$net $(call sqw,$(call test_suite,$(s),ENV)) -e PYTEST_ADDOPTS="$${PYTEST_ARGS:-}" -e LUXARCH_TEST_MIGRATIONS="$$mig" -e LUXARCH_TEST_FAST="$$fast" \
	    -e LUXARCH_TEST_COV=$(call sq,$(call test_suite,$(s),COV)) -e LUXARCH_TEST_OMIT="$$omit" -e COVERAGE_CORE=sysmon -e COVERAGE_FILE=/out/.coverage -e PYTHONDONTWRITEBYTECODE=1 \
	    -v $(call sq,$(CURDIR)):/repo:ro $$mnt -v "$$D/cfg":/cfg:ro -v "$$out":/out -w /repo/$(call sq,$(call test_suite,$(s),WORKDIR)) "$$img" \
	    sh -c 'm=$${LUXARCH_TEST_MIGRATIONS:-}; o=$${LUXARCH_TEST_OMIT:-}; python -m coverage run --branch --source="$$LUXARCH_TEST_COV" $${o:+"--omit=$$o"} -m pytest -c /cfg/pytest.ini --rootdir=. -p no:cacheprovider $${m:+"--ignore=$$m"}; s=$$?; if [ -n "$$m" ] && [ -z "$${LUXARCH_TEST_FAST:-}" ]; then PYTEST_ADDOPTS= python -m coverage run --append --branch --source="$$LUXARCH_TEST_COV" $${o:+"--omit=$$o"} -m pytest -c /cfg/pytest.ini --rootdir=. -p no:cacheprovider --confcutdir="$$m" "$$m"; ms=$$?; [ "$$ms" = 0 ] || echo "FAIL  the migration tests in $$m failed (exit $$ms)"; [ "$$s" != 0 ] || s=$$ms; fi; python -m coverage report --show-missing --precision=2 > /out/coverage.txt; echo $$? > /out/coverage.rc; python -m coverage json -q -o - > /out/coverage.json; cat /out/coverage.txt; exit $$s'; \
	  rc=$$?; \
	  [ "$$rc" = 0 ] || { echo "FAIL  the suite failed (exit $$rc)"; exit 1; }; \
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
	docker build --load --target production -f Dockerfile $(BUILD_ARGS) -t $(E2E_IMAGE) .
	./scripts/e2e-test.sh

# THE fleet gate — byte-identical composition across every app repo. Five different `check`
# targets is five different answers to "is this repo green," and the drift hides holes: a gate
# that quietly drops mypy, or arch, or the secret scan reads exactly as green as one that runs
# them. Order: pin drift -> ruff -> types -> tests -> architecture -> dependency CVEs -> secrets.
# `check` is a GATE, not a report: Make stops at the FIRST failing step. For the full red board
# (every red at once, phase-ordered + file-clustered) run `make plan`.
# See luxarch --doc FLEET-MAKEFILE-STANDARD.
# luxarch:check-gate asset v1 - DO NOT edit this marker line; it is how repo.emitted_assets_current knows your copy is current. Re-emit with `luxarch --emit check-gate`.
# ── The fleet gate: every leg runs, then the gate fails naming each red leg ───────────────────────
# Emitted by `luxarch --emit check-gate`; it replaces a hand-written `check:` line. A gate written as a
# prerequisite list (`check: … lint mypy test arch …`) stops at the FIRST failing leg: one ruff finding
# hid a 4,700-test suite, every hidden red cost one more fix-and-rerun cycle, and agents reached for
# `make -k`, which keeps going but also throws away the fatal steps' fatality.
#
# `guard-version-check` and `honest` stay PREREQUISITES and stay fatal: they run first, and a stale
# guard or a rule family that scanned nothing makes every later verdict meaningless. Every other leg
# then runs in order. A leg that fails is recorded, never skipped, and the gate exits non-zero naming
# each one. `repo.makefile_canonical` credits CHECK_LEGS only when this recipe is the asset's own, so
# a hand-written loop that drops an exit code earns nothing.
#
# Under `make -i` nothing can fail, the gate's own exit included (make ignores it), so the recipe runs
# no leg and says why, rather than print a ✓ over legs whose failures were thrown away.

# Setting: the legs, in order. An app repo's are exactly these; a repo with more legs (a guard's own
# parity suite) appends them. Removing one reds repo.makefile_canonical --------------------------------
CHECK_LEGS ?= lint mypy test arch audit gitleaks

check: guard-version-check honest ## THE fleet gate: runs every leg, then fails naming each red one
	@case '$(filter-out -%,$(firstword $(MAKEFLAGS)))' in *i*) echo "REFUSING: make -i ignores every failure, so this gate cannot fail: run make check without -i"; exit 2;; esac; \
	failed=; for leg in $(CHECK_LEGS); do \
	  printf '\n── make %s\n' "$$leg"; \
	  $(MAKE) --no-print-directory "$$leg" || failed="$$failed $$leg"; \
	done; \
	if [ -n "$$failed" ]; then printf '\n✗ make check FAILED:%s (every leg ran; each one is above)\n' "$$failed"; exit 1; fi; \
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

# luxarch:gitleaks asset v17 - DO NOT edit this marker line; it is how repo.emitted_assets_current knows your copy is current. Re-emit with `luxarch --emit gitleaks`.
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
gitleaks: ## secret scan over FULL HISTORY + the commit-identity pass (the hooks cover commit/push)
	@set -e; C=$$(mktemp); O=$$(mktemp); trap 'rm -f "$$C" "$$O"' EXIT INT TERM; \
	G=$$(git -C "$(CURDIR)" rev-parse --path-format=absolute --git-common-dir); \
	n=$$(git -C "$(CURDIR)" rev-list --count --all); \
	docker run --rm -v "$(CURDIR)":/repo $(LUXLINT) --emit-config gitleaks > "$$C"; \
	rc=0; docker run --rm -v "$(CURDIR)":/repo -v "$$G":"$$G":ro -v "$$C":/gl.toml:ro -w /repo \
	  $(GITLEAKS_IMAGE) git /repo -c /gl.toml --redact -v --ignore-gitleaks-allow > "$$O" 2>&1 || rc=$$?; \
	cat "$$O"; [ "$$rc" -eq 0 ] || exit "$$rc"; \
	if [ "$$n" -gt 0 ] && ! grep -Eq '(^|[^0-9])[1-9][0-9]* commits scanned' "$$O"; then \
	  echo "REFUSING: gitleaks scanned no commit of a history holding $$n: the history scan read nothing (above)."; exit 1; \
	fi
	@# v12: what `gitleaks git` never reads. It scans git's PATCHES, and git prints no patch for a file it
	@# treats as binary: a NUL byte, UTF-16 (a `Localizable.strings`), or a `binary` / `-diff` attribute.
	@# A token in any of them reached the remote with "no leaks found". So every path git ever showed as
	@# binary is re-read as text, NULs stripped, and scanned by path (the config's path allowlists hold).
	@set -e; C=$$(mktemp); D=$$(mktemp -d); trap 'rm -rf "$$C" "$$D"' EXIT INT TERM; \
	docker run --rm -v "$(CURDIR)":/repo $(LUXLINT) --emit-config gitleaks > "$$C"; \
	git -c core.quotePath=false log --branches --tags HEAD --format= -p --no-ext-diff --no-textconv \
	  > "$$D/patches"; \
	LC_ALL=C sed -n 's|^Binary files .* and b/\(.*\) differ$$|\1|p' "$$D/patches" | LC_ALL=C sort -u > "$$D/binary"; \
	if [ -s "$$D/binary" ]; then \
	  mkdir "$$D/t" "$$D/none"; \
	  while IFS= read -r f; do \
	    mkdir -p "$$D/t/$$(dirname "$$f")"; \
	    git -c core.quotePath=false log --branches --tags HEAD --format= -p --text --no-ext-diff \
	      --no-textconv -- "$$f" > "$$D/p"; \
	    LC_ALL=C grep -a '^+' "$$D/p" | LC_ALL=C tr -d '\000' > "$$D/t/$$f"; \
	  done < "$$D/binary"; \
	  docker run --rm -v "$$D/t":/scan:ro -w /scan -v "$$D/none":/none:ro -v "$$C":/gl.toml:ro \
	    $(GITLEAKS_IMAGE) dir . -c /gl.toml --redact -v --ignore-gitleaks-allow \
	    --gitleaks-ignore-path /none; \
	fi
	@# v13: every commit and annotated-tag MESSAGE, scanned as a file with the same config (credential
	@# rules and the denylist). One `git log` and one `for-each-ref`, split on a header line carrying a
	@# per-run nonce, so a message cannot forge a header and steer its own lines out of the scan.
	@set -e; C=$$(mktemp); D=$$(mktemp -d); trap 'rm -rf "$$C" "$$D"' EXIT INT TERM; \
	docker run --rm -v "$(CURDIR)":/repo $(LUXLINT) --emit-config gitleaks > "$$C"; \
	N=$$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n'); [ $${#N} -eq 32 ]; \
	mkdir -p "$$D/t/commit-message" "$$D/t/tag-message" "$$D/none"; \
	git log --branches --tags HEAD --format="$$N commit-message/%H%n%B" > "$$D/raw"; \
	git for-each-ref refs/tags --format="$$N tag-message/%(objectname)%0a%(contents)" >> "$$D/raw"; \
	LC_ALL=C tr -d '\000' < "$$D/raw" > "$$D/msgs"; \
	LC_ALL=C awk -v n="$$N" -v d="$$D/t" \
	  '$$1 == n && NF == 2 { if (f != "") close(f); f = d "/" $$2; printf "" > f; next } \
	   f != "" { print > f }' "$$D/msgs"; \
	docker run --rm -v "$$D/t":/scan:ro -w /scan -v "$$D/none":/none:ro -v "$$C":/gl.toml:ro \
	  $(GITLEAKS_IMAGE) dir . -c /gl.toml --redact -v --ignore-gitleaks-allow \
	  --gitleaks-ignore-path /none || { \
	  echo "REFUSING: a commit or tag MESSAGE carries a finding (the File above names it:"; \
	  echo "  commit-message/<sha> or tag-message/<object>). A message is published with its commit"; \
	  echo "  forever. Reword it (git rebase -i, or git filter-repo --message-callback for older"; \
	  echo "  history), re-run, and ask the OWNER to approve the force-push. Never force-push unapproved."; \
	  exit 1; }
	@# v14: what a push publishes besides content and messages: every file PATH in history and every
	@# branch and tag NAME. A path is not a patch line, so `gitleaks git` never read one, and a file or
	@# a branch named for an internal host passed every gate into a public remote.
	@set -e; C=$$(mktemp); D=$$(mktemp -d); trap 'rm -rf "$$C" "$$D"' EXIT INT TERM; \
	docker run --rm -v "$(CURDIR)":/repo $(LUXLINT) --emit-config gitleaks > "$$C"; \
	mkdir -p "$$D/t" "$$D/none"; \
	git -c core.quotePath=false log --branches --tags HEAD --format= --name-only | LC_ALL=C sort -u > "$$D/t/paths"; \
	git for-each-ref --format='%(refname:short)' refs/heads refs/tags > "$$D/t/ref-names"; \
	docker run --rm -v "$$D/t":/scan:ro -w /scan -v "$$D/none":/none:ro -v "$$C":/gl.toml:ro \
	  $(GITLEAKS_IMAGE) dir . -c /gl.toml --redact -v --ignore-gitleaks-allow \
	  --gitleaks-ignore-path /none || { \
	  echo "REFUSING: a file PATH or a branch/tag NAME carries a finding (File: paths or ref-names above)."; \
	  echo "  A name is published with the history it is in. Rename it (git mv; git branch -m; for older"; \
	  echo "  history git filter-repo --path-rename), re-run, and ask the OWNER to approve the force-push."; \
	  exit 1; }
	@# The identity pass — the half gitleaks structurally cannot do. Cheap: one `git log`.
	@# Walks what THIS repo publishes (branches, tags, HEAD), NOT `--all`: a remote-tracking ref caches the
	@# remote's state, which during a scrub is by definition the un-rewritten history you are about to
	@# force-push over — `--all` refused the verified fix, and any `git fetch` re-armed it.
	@bad=$$(git log --branches --tags HEAD --pretty='%an <%ae>%n%cn <%ce>' 2>/dev/null | LC_ALL=C sort -u \
	  | LC_ALL=C grep -vE '$(GIT_IDENTITY_OK)' || true); \
	if [ -n "$$bad" ]; then \
	  echo "REFUSING: a non-fleet identity appears in commit METADATA (author/committer):"; \
	  echo "$$bad" | LC_ALL=C sed 's/^/    /'; \
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
	docker run --rm -v "$(CURDIR)":/repo $(LUXLINT) --emit-config gitleaks > "$$C"; \
	mkdir "$$D/t" "$$D/none"; \
	git -c core.quotePath=false diff --cached --name-only --diff-filter=ACMR -z > "$$D/names"; \
	LC_ALL=C tr '\000' '\n' < "$$D/names" | while IFS= read -r f; do \
	  [ -n "$$f" ] || continue; \
	  mkdir -p "$$D/t/$$(dirname "$$f")"; \
	  git -c core.quotePath=false diff --cached --text --no-ext-diff --no-textconv -U0 -- "$$f" \
	    > "$$D/p"; \
	  LC_ALL=C grep -a '^+' "$$D/p" | LC_ALL=C tr -d '\000' > "$$D/t/$$f"; \
	done; \
	docker run --rm -v "$$D/t":/scan:ro -w /scan -v "$$D/none":/none:ro -v "$$C":/gl.toml:ro \
	  $(GITLEAKS_IMAGE) dir . -c /gl.toml --redact -v --ignore-gitleaks-allow \
	  --gitleaks-ignore-path /none

# v13: the message being WRITTEN, run by hooks/commit-msg (pre-commit cannot see it: git writes the
# message after that hook runs). The hook passes the file in `GITLEAKS_COMMIT_MSG`. The WHOLE file is
# scanned, comment lines included: `--cleanup=verbatim` publishes them, and a cut at the scissors line
# would let a verbatim message hide everything below one. No file to read is a refusal, never a pass.
gitleaks-commit-msg: ## secret + denylist scan of the commit MESSAGE being written (run by hooks/commit-msg)
	@set -e; M="$${GITLEAKS_COMMIT_MSG:-}"; \
	if [ -z "$$M" ] || [ ! -f "$$M" ] || [ ! -r "$$M" ]; then \
	  echo "REFUSING: no commit message to scan (GITLEAKS_COMMIT_MSG='$$M'). hooks/commit-msg" >&2; \
	  echo "  passes the file git hands it; re-emit the hooks with luxlint --emit-hooks." >&2; \
	  exit 1; \
	fi; \
	C=$$(mktemp); D=$$(mktemp -d); trap 'rm -rf "$$C" "$$D"' EXIT INT TERM; \
	docker run --rm -v "$(CURDIR)":/repo $(LUXLINT) --emit-config gitleaks > "$$C"; \
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
