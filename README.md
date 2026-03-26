# dapr-docker-csharp

Dapr .NET demo — a queue processor using Dapr pub/sub with Redis, running via Docker Compose.

## Prerequisites

- [.NET SDK 10.0](https://dotnet.microsoft.com/download) (pinned in `global.json`)
- [Docker](https://docs.docker.com/get-docker/) with Compose v2
- [jq](https://jqlang.github.io/jq/) (for API response formatting)
- [redis-cli](https://redis.io/docs/getting-started/) (optional, for Redis debugging)

## Quick Start

```bash
make start      # Start all services (app + Dapr sidecar + Redis)
make dapr-logs  # Follow queue processor logs
make dapr-pub   # Publish a test message
make stop       # Tear down
```

## Available Make Targets

Run `make help` to see all targets:

| Target | Description |
|--------|-------------|
| `help` | List available tasks |
| `deps` | Install required tools (idempotent) |
| `clean` | Remove build artifacts |
| `build` | Build the solution |
| `test` | Run tests |
| `lint` | Check code formatting |
| `format` | Auto-fix code formatting |
| `update` | Update NuGet packages to latest versions |
| `run` | Run the application locally |
| `ci` | Run full local CI pipeline |
| `ci-run` | Run GitHub Actions workflow locally using act |
| `start` | Start Docker Compose services |
| `stop` | Stop Docker Compose services |
| `restart` | Restart Docker Compose services |
| `pull` | Pull latest Docker images |
| `dapr-logs` | Follow queue processor logs |
| `dapr-pub` | Publish a message via Dapr pub/sub |
| `dapr-counter` | Increment counter via API |
| `dapr-get` | Get current state via API |
| `redis-pending` | Show pending Redis stream messages |
| `redis-clear` | Clear Redis stream messages |
| `redis-monitor` | Monitor Redis commands |
| `release` | Create and push a new tag |

## Architecture

- **QueueProcessor** — ASP.NET Core app subscribing to Dapr pub/sub topics via Redis Streams
- **Dapr Sidecar** — handles pub/sub, state management, and service invocation
- **Redis** — message broker and state store

Docker Compose files:
- `docker-compose.yaml` — app service, Redis
- `compose/dapr-docker-compose.yaml` — Dapr sidecar configuration
