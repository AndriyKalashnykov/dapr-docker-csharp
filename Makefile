.DEFAULT_GOAL := help

APP_NAME       := dapr-docker-csharp
CURRENTTAG     := $(shell git describe --tags --abbrev=0 2>/dev/null || echo "dev")

# === Tool Versions (pinned) ===
ACT_VERSION    := 0.2.87
NVM_VERSION    := 0.40.4
NODE_VERSION   := 22

# === Project Paths ===
SOLUTION       := dapr-docker-csharp.slnx
PROJECT        := src/queue-processor/queue-processor.csproj

# === Docker Compose ===
DOCKER_COMPOSE := docker compose --file docker-compose.yaml --file compose/dapr-docker-compose.yaml

# === Dapr ===
PUBSUB_NAME    := pubsub
TOPIC_NAME     := counter

#help: @ List available tasks
help:
	@echo "Usage: make COMMAND"
	@echo "Commands :"
	@grep -E '[a-zA-Z\.\-]+:.*?@ .*$$' $(MAKEFILE_LIST)| tr -d '#' | awk 'BEGIN {FS = ":.*?@ "}; {printf "\033[32m%-20s\033[0m - %s\n", $$1, $$2}'

#deps: @ Install required tools (idempotent)
deps:
	@command -v dotnet >/dev/null 2>&1 || { echo "Error: .NET SDK required. See https://dotnet.microsoft.com/download"; exit 1; }
	@command -v docker >/dev/null 2>&1 || { echo "Error: Docker required. See https://docs.docker.com/get-docker/"; exit 1; }

#deps-act: @ Install act for local CI runs
deps-act: deps
	@command -v act >/dev/null 2>&1 || { echo "Installing act $(ACT_VERSION)..."; \
		curl -sSfL https://raw.githubusercontent.com/nektos/act/master/install.sh | sudo bash -s -- -b /usr/local/bin v$(ACT_VERSION); \
	}

#clean: @ Remove build artifacts
clean:
	@dotnet clean "$(SOLUTION)" -c Release --nologo -v q
	@find . -type d \( -name bin -o -name obj \) -exec rm -rf {} + 2>/dev/null || true

#build: @ Build the solution
build: deps
	@dotnet restore "$(SOLUTION)"
	@dotnet build "$(SOLUTION)" -c Release --no-restore

# === Test Projects ===
TEST_PROJECT   := tests/queue-processor.tests/queue-processor.tests.csproj

#test: @ Run tests
test: deps
	@dotnet run --project "$(TEST_PROJECT)" -c Release

#lint: @ Check formatting and build warnings
lint: deps
	@dotnet format "$(SOLUTION)" --verify-no-changes
	@dotnet build "$(SOLUTION)" -c Release -warnaserror --nologo -v q

#vulncheck: @ Check for vulnerable NuGet packages
vulncheck: deps
	@dotnet list package --vulnerable --include-transitive 2>&1 | tee /dev/stderr | grep -q 'has the following vulnerable packages' && exit 1 || true

#format: @ Auto-fix code formatting
format: deps
	@dotnet format "$(SOLUTION)"

#update: @ Update NuGet packages to latest versions
update: deps
	@cd "src/queue-processor" && dotnet list package --outdated | grep -o '> \S*' | grep '[^> ]*' -o | xargs --no-run-if-empty -L 1 dotnet add package

#run: @ Run the application locally
run: deps
	@dotnet run --project "$(PROJECT)"

#ci: @ Run full local CI pipeline
ci: deps format lint vulncheck test build
	@echo "Local CI pipeline passed."

#ci-run: @ Run GitHub Actions workflow locally using act
ci-run: deps-act
	@act push --container-architecture linux/amd64 \
		--artifact-server-path /tmp/act-artifacts

#renovate-bootstrap: @ Install nvm and npm for Renovate
renovate-bootstrap:
	@command -v node >/dev/null 2>&1 || { \
		echo "Installing nvm $(NVM_VERSION)..."; \
		curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v$(NVM_VERSION)/install.sh | bash; \
		export NVM_DIR="$$HOME/.nvm"; \
		[ -s "$$NVM_DIR/nvm.sh" ] && . "$$NVM_DIR/nvm.sh"; \
		nvm install $(NODE_VERSION); \
	}
	@command -v pnpm >/dev/null 2>&1 || { echo "Installing pnpm via corepack..."; corepack enable pnpm; }

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
		curl "http://localhost:3500/v1.0/publish/$(PUBSUB_NAME)/$(TOPIC_NAME)?metadata.rawPayload=false" \
		--header "Content-Type: application/json" \
		--data 3

#dapr-counter: @ Increment counter via API
dapr-counter:
	@curl -s -X POST http://localhost:5000/counter -H "Content-Type: application/json" -d '2' | jq .

#dapr-get: @ Get current state via API
dapr-get:
	@curl -s -X GET http://localhost:5000/ -H "Content-Type: application/json" | jq .

#redis-pending: @ Show pending Redis stream messages
redis-pending:
	@redis-cli XRANGE $(TOPIC_NAME) - +

#redis-clear: @ Clear Redis stream messages
redis-clear:
	@redis-cli XTRIM $(TOPIC_NAME) MAXLEN = 0

#redis-monitor: @ Monitor Redis commands
redis-monitor:
	@redis-cli MONITOR

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

.PHONY: help deps deps-act clean build test lint vulncheck format update run ci ci-run \
	renovate-bootstrap renovate-validate \
	start stop restart pull \
	dapr-logs dapr-pub dapr-counter dapr-get \
	redis-pending redis-clear redis-monitor \
	release
