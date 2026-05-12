SHELL := /bin/bash
.DEFAULT_GOAL := help

APP_NAME       := dapr-docker-csharp
IMAGE_NAME     := queue-processor
IMAGE_TAG      := $(shell git describe --tags --always --dirty 2>/dev/null || echo "dev")
CURRENTTAG     := $(shell git describe --tags --abbrev=0 2>/dev/null || echo "dev")

# === Tool versions (managed by mise — see .mise.toml) ===
# renovate: datasource=docker depName=minlag/mermaid-cli
MERMAID_CLI_VERSION := 11.14.0


# === Project Paths ===
SOLUTION             := dapr-docker-csharp.slnx
PROJECT              := src/queue-processor/queue-processor.csproj
TEST_PROJECT         := tests/queue-processor.tests/queue-processor.tests.csproj
INTEGRATION_TEST_PROJECT := tests/queue-processor.integration.tests/queue-processor.integration.tests.csproj

# === Docker Compose ===
DOCKER_COMPOSE := docker compose --file docker-compose.yaml --file compose/dapr-docker-compose.yaml

# === Env-driven defaults (mirror .env.example; `?=` lets env override) ===
HOST_PORT          ?= 5000
APP_INTERNAL_PORT  ?= 5000
DAPR_HTTP_PORT     ?= 3500
PUBSUB_NAME        ?= pubsub
TOPIC_NAME         ?= counter
APP_HOST           ?= localhost
DAPR_HOST          ?= localhost
HEALTHCHECK_HOST   ?= localhost
ACT_PORT_MIN       ?= 40000
ACT_PORT_MAX       ?= 59999

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
	@command -v mise   >/dev/null 2>&1 || { echo "Installing mise..."; curl -fsSL https://mise.run | sh; }
	@mise install --yes

#deps-act: @ Install act for local CI runs (via mise)
deps-act: deps
	@mise install --yes aqua:nektos/act

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

#vulncheck: @ Check for vulnerable NuGet packages
vulncheck: deps
	@set -o pipefail; dotnet list package --vulnerable --include-transitive 2>&1 | tee /dev/stderr | grep -q 'has the following vulnerable packages' && exit 1 || true

#trivy-fs: @ Trivy filesystem scan (HIGH+CRITICAL vulnerabilities + misconfigs)
trivy-fs: deps
	@mise install --yes aqua:aquasecurity/trivy >/dev/null
	@trivy fs --quiet --severity HIGH,CRITICAL --exit-code 1 \
		--skip-dirs bin --skip-dirs obj --skip-dirs node_modules \
		--scanners vuln,misconfig .

#secrets: @ Scan working tree + git history for committed secrets (gitleaks)
secrets: deps
	@mise install --yes aqua:gitleaks/gitleaks >/dev/null
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

#static-check: @ Composite quality gate (lint + vulncheck + trivy-fs + secrets + mermaid-lint)
static-check: lint vulncheck trivy-fs secrets mermaid-lint

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
	@ACT_PORT=$$(shuf -i $(ACT_PORT_MIN)-$(ACT_PORT_MAX) -n 1); \
	ARTIFACT_PATH=$$(mktemp -d); \
	for j in static-check build test integration-test ci-pass; do \
		echo "==> act job: $$j"; \
		act push --job "$$j" --container-architecture linux/amd64 --pull=false \
			--artifact-server-port "$$ACT_PORT" \
			--artifact-server-path "$$ARTIFACT_PATH" || exit $$?; \
	done

#renovate-bootstrap: @ Install Node + pnpm for Renovate (via mise)
renovate-bootstrap: deps
	@mise install --yes node pnpm

#renovate-validate: @ Validate Renovate configuration
renovate-validate: renovate-bootstrap
	@if [ -n "$$GH_ACCESS_TOKEN" ]; then \
		GITHUB_COM_TOKEN=$$GH_ACCESS_TOKEN npx --yes renovate --platform=local; \
	else \
		echo "Warning: GH_ACCESS_TOKEN not set, some dependency lookups may fail"; \
		npx --yes renovate --platform=local; \
	fi

#start: @ Start Docker Compose services
start: deps
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
		echo -n "Create and push $$newtag? [y/N] " && read ans && [ "$${ans:-N}" = y ] && \
		echo $$newtag > ./version.txt && \
		git add version.txt && \
		git commit -a -s -m "Cut $$newtag release" && \
		git tag $$newtag && \
		git push origin $$newtag && \
		git push && \
		echo "Done."'

.PHONY: help deps deps-act clean build image-build test integration-test e2e \
	lint vulncheck trivy-fs secrets mermaid-lint static-check format run ci ci-run \
	renovate-bootstrap renovate-validate \
	start stop restart pull \
	dapr-logs dapr-pub dapr-counter dapr-get \
	redis-pending redis-clear redis-monitor \
	release
