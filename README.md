[![CI](https://github.com/AndriyKalashnykov/dapr-docker-csharp/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/AndriyKalashnykov/dapr-docker-csharp/actions/workflows/ci.yml)
[![Hits](https://hits.sh/github.com/AndriyKalashnykov/dapr-docker-csharp.svg?view=today-total&style=plastic)](https://hits.sh/github.com/AndriyKalashnykov/dapr-docker-csharp/)
[![License: MIT](https://img.shields.io/badge/License-MIT-brightgreen.svg)](https://opensource.org/licenses/MIT)
[![Renovate enabled](https://img.shields.io/badge/renovate-enabled-brightgreen.svg)](https://app.renovatebot.com/dashboard#github/AndriyKalashnykov/dapr-docker-csharp)

# dapr-docker-csharp

Dapr .NET demo -- a queue processor using Dapr pub/sub with Redis, running via Docker Compose. Built with C# / .NET 10.0 and ASP.NET Core with Dapr.AspNetCore. Uses `.slnx` solution format and TUnit for testing.

## Quick Start

```bash
make deps       # verify .NET SDK and Docker are installed
make build      # build the solution
make start      # start all services (app + Dapr sidecar + Redis)
make dapr-logs  # follow queue processor logs
make dapr-pub   # publish a test message
```

## Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| [GNU Make](https://www.gnu.org/software/make/) | 3.81+ | Build orchestration |
| [Git](https://git-scm.com/) | 2.0+ | Version control |
| [.NET SDK](https://dotnet.microsoft.com/download) | 10.0 | C# runtime and compiler (pinned in `global.json`) |
| [Docker](https://www.docker.com/) | latest | Container runtime with Compose v2 |
| [jq](https://jqlang.github.io/jq/) | latest | API response formatting |
| [redis-cli](https://redis.io/docs/getting-started/) | latest | Redis debugging (optional) |
| [act](https://github.com/nektos/act) | 0.2.87 | Run GitHub Actions locally (optional, installed by `make deps-act`) |

Install all required dependencies:

```bash
make deps
```

## Available Make Targets

Run `make help` to see all targets.

### Build & Run

| Target | Description |
|--------|-------------|
| `make build` | Build the solution |
| `make test` | Run TUnit tests |
| `make lint` | Check code formatting |
| `make format` | Auto-fix code formatting |
| `make clean` | Remove build artifacts |
| `make run` | Run the application locally |
| `make update` | Update NuGet packages to latest versions |

### Docker Compose

| Target | Description |
|--------|-------------|
| `make start` | Start Docker Compose services |
| `make stop` | Stop Docker Compose services |
| `make restart` | Restart Docker Compose services |
| `make pull` | Pull latest Docker images |

### Dapr

| Target | Description |
|--------|-------------|
| `make dapr-logs` | Follow queue processor logs |
| `make dapr-pub` | Publish a message via Dapr pub/sub |
| `make dapr-counter` | Increment counter via API |
| `make dapr-get` | Get current state via API |

### Redis

| Target | Description |
|--------|-------------|
| `make redis-pending` | Show pending Redis stream messages |
| `make redis-clear` | Clear Redis stream messages |
| `make redis-monitor` | Monitor Redis commands |

### CI & Utilities

| Target | Description |
|--------|-------------|
| `make help` | List available tasks |
| `make ci` | Run full local CI pipeline |
| `make ci-run` | Run GitHub Actions workflow locally using [act](https://github.com/nektos/act) |
| `make deps` | Install required tools (idempotent) |
| `make deps-act` | Install act for local CI runs |
| `make renovate-bootstrap` | Install nvm and npm for Renovate |
| `make renovate-validate` | Validate Renovate configuration |
| `make release` | Create and push a new tag |

## Architecture

- **QueueProcessor** -- ASP.NET Core app subscribing to Dapr pub/sub topics via Redis Streams
- **Dapr Sidecar** -- handles pub/sub, state management, and service invocation
- **Redis** -- message broker and state store
- **Jaeger** -- distributed tracing via OpenTelemetry (UI at `http://localhost:16686`)

Docker Compose files:
- `docker-compose.yaml` -- app service, Redis
- `compose/dapr-docker-compose.yaml` -- Dapr sidecar, Jaeger tracing

## CI/CD

GitHub Actions runs on every push to `main`, tags `v*`, and pull requests.

| Job | Triggers | Steps |
|-----|----------|-------|
| **lint** | push, PR, tags | Lint (format check) |
| **build** | after lint passes | Build |
| **test** | after lint passes | Test |

A separate cleanup workflow (`.github/workflows/cleanup-runs.yml`) removes old workflow runs weekly (retains 7 days / minimum 5 runs).

[Renovate](https://docs.renovatebot.com/) keeps dependencies up to date with branch automerge (squash strategy) enabled.
