SHELL := /bin/bash
.DEFAULT_GOAL := help

APP_NAME       := dapr-docker-csharp
IMAGE_NAME     := queue-processor
IMAGE_TAG      := $(shell git describe --tags --always --dirty 2>/dev/null || echo "dev")
CURRENTTAG     := $(shell git describe --tags --abbrev=0 2>/dev/null || echo "dev")

# === Tool versions (managed by mise — see .mise.toml) ===
# renovate: datasource=docker depName=minlag/mermaid-cli
MERMAID_CLI_VERSION := 11.16.0

# PlantUML renderer for the C4 architecture diagrams (docs/diagrams/*.puml).
# The bump PR drives a committed-PNG regen (`make diagrams`) the hosted Renovate
# app cannot run, so renovate.json disables automerge for this dep (a human runs
# `make diagrams` + commits the PNGs on its bump PR). See /architecture-diagrams.
# renovate: datasource=docker depName=plantuml/plantuml
PLANTUML_VERSION := 1.2026.6

# act runner image. CI uses GitHub-hosted `ubuntu-latest`; act needs an
# equivalent locally. Pin the DATED catthehacker tag (immutable, content-
# addressable) — NOT the floating `act-latest` tag, which would let
# `docker pull` swap the image out from under us between runs and break
# reproducibility. The dated tag mirrors the workflow's `runs-on:
# ubuntu-latest` substrate at the moment of this commit; Renovate bumps
# the date roughly weekly via the docker datasource (catthehacker publishes
# `act-latest-YYYYMMDD` snapshots alongside the floating tag).
# `versioning=loose` because the suffix isn't semver — Renovate compares
# tags lexicographically and a later date sorts higher.
# renovate: datasource=docker depName=catthehacker/ubuntu versioning=regex:^act-latest-(?<major>\d{4})(?<minor>\d{2})(?<patch>\d{2})$
ACT_UBUNTU_VERSION := act-latest-20260629


# === Project Paths ===
SOLUTION             := dapr-docker-csharp.slnx
PROJECT              := src/queue-processor/queue-processor.csproj
TEST_PROJECT         := tests/queue-processor.tests/queue-processor.tests.csproj
INTEGRATION_TEST_PROJECT := tests/queue-processor.integration.tests/queue-processor.integration.tests.csproj

# === Docker Compose ===
DOCKER_COMPOSE := docker compose --file docker-compose.yaml --file compose/dapr-docker-compose.yaml

# Load operator overrides from .env (gitignored) BEFORE the `?=` defaults, so
# `.env` is authoritative for `make` too — not just for `docker compose` (which
# auto-loads it). `-include` (leading `-`) silently skips a missing .env, in
# which case the `?=` defaults apply; a value present in .env sets the var first,
# so the later `?=` is a no-op. Keep .env shell-clean `KEY=value` (escape `$` as `$$`).
-include .env

# === Env-driven defaults (mirror .env.example; `?=` lets env override) ===
HOST_PORT                   ?= 5000
APP_INTERNAL_PORT           ?= 5000
REDIS_HOST_PORT             ?= 6379
JAEGER_QUERY_HOST_PORT      ?= 16686
JAEGER_OTLP_GRPC_HOST_PORT  ?= 4317
JAEGER_OTLP_HTTP_HOST_PORT  ?= 4318
DAPR_HTTP_PORT              ?= 3500
PUBSUB_NAME                 ?= pubsub
TOPIC_NAME                  ?= counter
APP_HOST                    ?= localhost
DAPR_HOST                   ?= localhost
HEALTHCHECK_HOST            ?= localhost
ACT_PORT_MIN                ?= 40000
ACT_PORT_MAX                ?= 59999

# Ensure mise-managed shims are on PATH for tools installed via .mise.toml
export PATH := $(HOME)/.local/share/mise/shims:$(HOME)/.local/bin:$(PATH)

#help: @ List available tasks
help:
	@echo "Usage: make COMMAND"
	@echo "Commands :"
	@grep -E '[a-zA-Z\.\-]+:.*?@ .*$$' $(MAKEFILE_LIST)| tr -d '#' | awk 'BEGIN {FS = ":.*?@ "}; {printf "\033[32m%-20s\033[0m - %s\n", $$1, $$2}'

#deps: @ Install required tools (idempotent)
deps:
	@command -v dotnet >/dev/null 2>&1 || { echo "Error: .NET SDK required. See https://dotnet.microsoft.com/download"; exit 1; }
	@command -v docker >/dev/null 2>&1 || { echo "Error: Docker required. See https://docs.docker.com/get-docker/"; exit 1; }
	@# CI installs mise via jdx/mise-action; only bootstrap the binary locally.
	@if [ -z "$$CI" ]; then command -v mise >/dev/null 2>&1 || { echo "Installing mise..."; curl -fsSL https://mise.run | sh; }; fi
	@mise install --yes

#deps-act: @ Install act for local CI runs (via mise)
deps-act: deps
	@# act is pinned in .mise.toml and installed by `deps`; nothing extra needed.

#clean: @ Remove build artifacts
clean:
	@dotnet clean "$(SOLUTION)" -c Release --nologo -v q
	@find . -type d \( -name bin -o -name obj \) -exec rm -rf {} + 2>/dev/null || true

#build: @ Build the solution
build: deps
	@dotnet restore "$(SOLUTION)"
	@dotnet build "$(SOLUTION)" -c Release --no-restore

#image-build: @ Build the production Docker image (multi-stage, non-root, with HEALTHCHECK)
image-build: deps
	@docker build -f src/queue-processor/Dockerfile -t $(IMAGE_NAME):$(IMAGE_TAG) -t $(IMAGE_NAME):latest .

#test: @ Run unit tests
test: deps
	@# TUnit on .NET 10 SDK requires `dotnet run` (MTP entry point), not `dotnet test`.
	@# See https://github.com/thomhurst/TUnit. Unit and Integration tests live in
	@# separate projects, so layer selection is via project path, not a filter.
	@dotnet run --project "$(TEST_PROJECT)" -c Release

#integration-test: @ Run integration tests (Testcontainers Redis + daprd)
integration-test: deps
	@dotnet run --project "$(INTEGRATION_TEST_PROJECT)" -c Release

#e2e: @ Run end-to-end tests via Docker Compose (full stack)
e2e: deps
	@./e2e/e2e-test.sh

#lint: @ Check formatting and build warnings
lint: deps
	@dotnet format "$(SOLUTION)" --verify-no-changes
	@dotnet build "$(SOLUTION)" -c Release -warnaserror --nologo -v q
	@# Guard against shell scripts losing +x mode (e.g., a subagent Write that
	@# defaults to 0644, or a careless `chmod -x`). Without +x, CI invokes the
	@# script as ./path/to/file.sh and exits 126 "Permission denied" — the kind
	@# of regression that ci-run wouldn't catch if the e2e job is skipped.
	@NONEXEC=$$(find scripts e2e -name '*.sh' -not -executable -print 2>/dev/null); \
	if [ -n "$$NONEXEC" ]; then \
		echo "Error: shell scripts missing +x mode:"; \
		echo "$$NONEXEC" | sed 's/^/  /'; \
		echo "Fix: chmod +x <file>; git add <file>"; \
		exit 1; \
	fi

#vulncheck: @ Check for vulnerable NuGet packages
vulncheck: deps
	@set -o pipefail; dotnet list package --vulnerable --include-transitive 2>&1 | tee /dev/stderr | grep -q 'has the following vulnerable packages' && exit 1 || true

#trivy-fs: @ Trivy filesystem scan (HIGH+CRITICAL vulnerabilities + misconfigs)
trivy-fs: deps
	@trivy fs --quiet --severity HIGH,CRITICAL --exit-code 1 \
		--skip-dirs bin --skip-dirs obj --skip-dirs node_modules \
		--scanners vuln,misconfig .

#secrets: @ Scan working tree + git history for committed secrets (gitleaks)
secrets: deps
	@gitleaks detect --no-banner --redact --exit-code 1

#mermaid-lint: @ Lint Mermaid diagrams embedded in Markdown files
mermaid-lint: deps
	@docker image inspect minlag/mermaid-cli:$(MERMAID_CLI_VERSION) >/dev/null 2>&1 \
		|| docker pull -q minlag/mermaid-cli:$(MERMAID_CLI_VERSION) >/dev/null
	@files=$$(grep -rlE '^[[:space:]]*```mermaid' --include='*.md' . 2>/dev/null \
		| grep -v -E '/(bin|obj|node_modules|\.git)/' || true); \
	if [ -z "$$files" ]; then \
		echo "No Markdown files with Mermaid blocks found — nothing to lint."; \
		exit 0; \
	fi; \
	out=$$(mktemp -d); \
	for f in $$files; do \
		echo "==> mermaid-lint: $$f"; \
		docker run --rm --user $$(id -u):$$(id -g) \
			-v "$$(pwd):/data:ro" -v "$$out:/out" -w /data \
			minlag/mermaid-cli:$(MERMAID_CLI_VERSION) \
			--quiet -i "$$f" -o "/out/$$(basename $$f).svg" \
			|| { rm -rf "$$out"; exit 1; }; \
	done; \
	rm -rf "$$out"

# === C4 architecture diagrams (PlantUML) ===
DIAGRAM_DIR   := docs/diagrams
DIAGRAM_SRC   := $(wildcard $(DIAGRAM_DIR)/*.puml)
DIAGRAM_OUT   := $(patsubst $(DIAGRAM_DIR)/%.puml,$(DIAGRAM_DIR)/out/%.png,$(DIAGRAM_SRC))
# Version-stamped sentinel: a PLANTUML_VERSION bump changes the stamp NAME, so the
# old stamp no longer satisfies the prereq and every PNG re-renders — closes the
# "renderer bumped but PNG not regenerated" blind spot of a bare source-only gate.
DIAGRAM_STAMP := $(DIAGRAM_DIR)/out/.plantuml-$(PLANTUML_VERSION).stamp

#diagrams: @ Render C4 PlantUML architecture diagrams to PNG
diagrams: $(DIAGRAM_OUT)

$(DIAGRAM_DIR)/out/%.png: $(DIAGRAM_DIR)/%.puml $(DIAGRAM_STAMP)
	@docker image inspect plantuml/plantuml:$(PLANTUML_VERSION) >/dev/null 2>&1 \
		|| docker pull -q plantuml/plantuml:$(PLANTUML_VERSION) >/dev/null
	@docker run --rm -v "$(CURDIR)/$(DIAGRAM_DIR):/work" -w /work \
		--user $$(id -u):$$(id -g) \
		-e JAVA_TOOL_OPTIONS=-Duser.home=/tmp \
		plantuml/plantuml:$(PLANTUML_VERSION) \
		-tpng -o out $(notdir $<)

$(DIAGRAM_STAMP):
	@mkdir -p $(DIAGRAM_DIR)/out
	@rm -f $(DIAGRAM_DIR)/out/.plantuml-*.stamp
	@touch $@

#diagrams-clean: @ Remove rendered diagram artefacts
diagrams-clean:
	@rm -rf $(DIAGRAM_DIR)/out

#diagrams-check: @ Verify committed diagram PNGs match current .puml source (CI drift gate)
diagrams-check: diagrams
	@# Two-part predicate (NOT bare `git diff`): `git diff` catches an EDITED source
	@# whose tracked PNG changed; `ls-files --others` catches a NEW source whose
	@# freshly-rendered PNG is still untracked (git diff is blind to untracked files).
	@# A staged render that matches fresh output is invisible to both -> GREEN
	@# pre-commit (this gate runs inside static-check, which `make ci` runs before commit).
	@git diff --exit-code -- $(DIAGRAM_DIR)/out >/dev/null 2>&1 \
		|| { echo "ERROR: committed diagram PNG is stale — run 'make diagrams' and commit."; \
		     git --no-pager diff --stat -- $(DIAGRAM_DIR)/out; exit 1; }
	@U=$$(git ls-files --others --exclude-standard -- $(DIAGRAM_DIR)/out); \
	[ -z "$$U" ] || { echo "ERROR: rendered diagram output not committed/staged:"; \
		echo "$$U"; exit 1; }
	@echo "diagrams-check: rendered output matches committed source."

#check-env: @ STOPPER gate — fail if the committed .env.example source-of-truth is missing
check-env:
	@test -f .env.example || { \
		echo "ERROR: .env.example is missing (BLOCKING per rules/common/configuration.md)."; \
		echo "       It is the committed source of truth for every operator-tunable value."; \
		exit 1; }

#check-ports: @ Fail early if a fixed host port bound by `make start` is already in use
check-ports:
	@for pair in "HOST_PORT $(HOST_PORT)" "REDIS_HOST_PORT $(REDIS_HOST_PORT)" \
			"JAEGER_QUERY_HOST_PORT $(JAEGER_QUERY_HOST_PORT)" \
			"JAEGER_OTLP_GRPC_HOST_PORT $(JAEGER_OTLP_GRPC_HOST_PORT)" \
			"JAEGER_OTLP_HTTP_HOST_PORT $(JAEGER_OTLP_HTTP_HOST_PORT)"; do \
		name=$${pair%% *}; port=$${pair##* }; \
		if (exec 3<>/dev/tcp/127.0.0.1/$$port) 2>/dev/null; then \
			exec 3>&- 3<&- 2>/dev/null || true; \
			holder=$$(docker ps --format '{{.Names}} ({{.Ports}})' 2>/dev/null | grep ":$$port->" || echo "an unknown process"); \
			echo "ERROR: port $$port ($$name) is already in use by: $$holder"; \
			echo "       Free it, or override $$name (e.g. 'make start $$name=<free-port>' or set it in .env)."; \
			exit 1; \
		fi; \
	done
	@echo "check-ports: all fixed host ports free."

#static-check: @ Composite quality gate (lint + vulncheck + trivy-fs + secrets + mermaid-lint + diagrams-check)
static-check: check-env lint vulncheck trivy-fs secrets mermaid-lint diagrams-check

#format: @ Auto-fix code formatting
format: deps
	@dotnet format "$(SOLUTION)"

#run: @ Run the application locally
run: deps
	@dotnet run --project "$(PROJECT)"

#ci: @ Run full local CI pipeline
ci: deps static-check test integration-test build
	@echo "Local CI pipeline passed."

#ci-run: @ Run GitHub Actions workflow locally using act
ci-run: deps-act
	@docker container prune -f >/dev/null 2>&1 || true
	@# Forward GITHUB_TOKEN env-only (per security rule: never put secret VALUES on argv).
	@# act --secret KEY reads VALUE from inherited env. Auto-derive from gh CLI when unset.
	@if [ -z "$$GITHUB_TOKEN" ] && command -v gh >/dev/null 2>&1; then \
		export GITHUB_TOKEN="$$(gh auth token 2>/dev/null)"; \
	fi; \
	ACT_PORT=$$(shuf -i $(ACT_PORT_MIN)-$(ACT_PORT_MAX) -n 1); \
	ARTIFACT_PATH=$$(mktemp -d); \
	trap 'rm -rf "$$ARTIFACT_PATH"' EXIT INT TERM; \
	for j in static-check build image-build test integration-test e2e ci-pass; do \
		echo "==> act job: $$j"; \
		act push --job "$$j" --container-architecture linux/amd64 --pull=false \
			-P ubuntu-latest=catthehacker/ubuntu:$(ACT_UBUNTU_VERSION) \
			--secret GITHUB_TOKEN \
			--artifact-server-port "$$ACT_PORT" \
			--artifact-server-path "$$ARTIFACT_PATH" || exit $$?; \
	done
	@# Note on the loop list: `ci-pass` is the workflow's aggregator (needs:
	@# all of the above). When act runs `--job ci-pass`, it resolves the
	@# `needs:` DAG and re-executes every upstream job transitively before
	@# evaluating the aggregator step. This is intentional duplication —
	@# kept for portfolio-wide uniformity across all dapr-* / spring-* repos
	@# where every workflow job is explicit in the ci-run loop, and so a
	@# future top-level job that ci-pass doesn't `needs:` cannot be silently
	@# omitted. The cost is one extra full pass at the end of ci-run.

#renovate-bootstrap: @ Install Node + pnpm for Renovate (via mise)
renovate-bootstrap: deps
	@# Node + pnpm are pinned in .mise.toml and installed by `deps`.

#renovate-validate: @ Validate Renovate configuration
renovate-validate: renovate-bootstrap
	@if [ -n "$$GH_ACCESS_TOKEN" ]; then \
		GITHUB_COM_TOKEN=$$GH_ACCESS_TOKEN npx --yes renovate --platform=local; \
	else \
		echo "Warning: GH_ACCESS_TOKEN not set, some dependency lookups may fail"; \
		npx --yes renovate --platform=local; \
	fi

#start: @ Start Docker Compose services
start: deps check-ports
	@$(DOCKER_COMPOSE) up -d

#stop: @ Stop Docker Compose services
stop: deps
	@$(DOCKER_COMPOSE) rm --stop --force

#restart: @ Restart Docker Compose services
restart: stop start

#pull: @ Pull latest Docker images
pull: deps
	@$(DOCKER_COMPOSE) pull

#dapr-logs: @ Follow queue processor logs
dapr-logs:
	@$(DOCKER_COMPOSE) logs -f queueprocessor

#dapr-pub: @ Publish a message via Dapr pub/sub
dapr-pub:
	@$(DOCKER_COMPOSE) exec queueprocessor \
		curl "http://$(DAPR_HOST):$(DAPR_HTTP_PORT)/v1.0/publish/$(PUBSUB_NAME)/$(TOPIC_NAME)?metadata.rawPayload=false" \
		--header "Content-Type: application/json" \
		--data 3

#dapr-counter: @ Increment counter via API
dapr-counter:
	@curl -s -X POST "http://$(APP_HOST):$(HOST_PORT)/counter" -H "Content-Type: application/json" -d '2' | jq .

#dapr-get: @ Get current state via API
dapr-get:
	@curl -s -X GET "http://$(APP_HOST):$(HOST_PORT)/" -H "Content-Type: application/json" | jq .

#redis-pending: @ Show pending Redis stream messages (via compose-running container)
redis-pending:
	@$(DOCKER_COMPOSE) exec -T redis redis-cli XRANGE $(TOPIC_NAME) - +

#redis-clear: @ Clear Redis stream messages (via compose-running container)
redis-clear:
	@$(DOCKER_COMPOSE) exec -T redis redis-cli XTRIM $(TOPIC_NAME) MAXLEN = 0

#redis-monitor: @ Monitor Redis commands (via compose-running container)
redis-monitor:
	@$(DOCKER_COMPOSE) exec redis redis-cli MONITOR

#release: @ Create and push a new tag
release:
	@bash -c 'read -p "New tag (current: $(CURRENTTAG)): " newtag && \
		echo "$$newtag" | grep -qE "^v[0-9]+\.[0-9]+\.[0-9]+$$" || { echo "Error: Tag must match vN.N.N"; exit 1; } && \
		if git rev-parse -q --verify "refs/tags/$$newtag" >/dev/null 2>&1; then echo "ERROR: tag $$newtag already exists locally. Pick a new version or delete it: git tag -d $$newtag"; exit 1; fi && \
		if git ls-remote --exit-code --tags origin "refs/tags/$$newtag" >/dev/null 2>&1; then echo "ERROR: tag $$newtag already exists on origin. Pick a new version."; exit 1; fi && \
		echo -n "Create and push $$newtag? [y/N] " && read ans && [ "$${ans:-N}" = y ] && \
		echo $$newtag > ./version.txt && \
		git add version.txt && \
		git commit -a -s -m "Cut $$newtag release" && \
		git tag $$newtag && \
		git push origin $$newtag && \
		git push && \
		echo "Done."'

.PHONY: help deps deps-act clean build image-build test integration-test e2e \
	lint vulncheck trivy-fs secrets mermaid-lint diagrams diagrams-clean diagrams-check \
	check-env check-ports static-check format run ci ci-run \
	renovate-bootstrap renovate-validate \
	start stop restart pull \
	dapr-logs dapr-pub dapr-counter dapr-get \
	redis-pending redis-clear redis-monitor \
	release
