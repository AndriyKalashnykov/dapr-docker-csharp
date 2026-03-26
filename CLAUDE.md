# CLAUDE.md

## Project Overview

Dapr .NET demo application — a queue processor using Dapr pub/sub with Redis, running via Docker Compose.

- **Language**: C# / .NET 10.0 (`global.json` pins SDK `10.0.201`)
- **Framework**: ASP.NET Core with Dapr.AspNetCore
- **Infrastructure**: Docker Compose (multi-file), Dapr sidecar, Redis
- **Solution**: `dapr-docker-csharp.sln` with single project `src/Dapr.Demo.QueueProcessor/`

## Build & Dev Commands

| Command | Purpose |
|---------|---------|
| `make help` | List all available targets |
| `make build` | Restore + build in Release mode |
| `make test` | Run tests |
| `make lint` | Check code formatting (`dotnet format --verify-no-changes`) |
| `make format` | Auto-fix code formatting |
| `make clean` | Remove build artifacts (bin/obj) |
| `make update` | Update NuGet packages to latest |
| `make run` | Run application locally |
| `make ci` | Full local CI pipeline (build + lint + test) |
| `make ci-run` | Run GitHub Actions locally via act |

## Docker Compose Commands

| Command | Purpose |
|---------|---------|
| `make start` | Start all services (app + Dapr + Redis) |
| `make stop` | Stop and remove containers |
| `make restart` | Stop then start |
| `make pull` | Pull latest Docker images |

## Dapr Commands

| Command | Purpose |
|---------|---------|
| `make dapr-logs` | Follow queue processor logs |
| `make dapr-pub` | Publish message via Dapr pub/sub |
| `make dapr-counter` | POST to counter endpoint |
| `make dapr-get` | GET current state |

## Redis Commands

| Command | Purpose |
|---------|---------|
| `make redis-pending` | Show pending Redis stream messages |
| `make redis-clear` | Clear Redis stream |
| `make redis-monitor` | Monitor Redis commands |

## Tool Versions

- **act**: 0.2.86 (installed by `make deps-act` / `make ci-run`)
- **.NET SDK**: 10.0.201 (from `global.json`)

## CI

GitHub Actions workflow (`.github/workflows/ci.yml`) runs on push to main and PRs:
1. Build (`make build`)
2. Lint (`make lint` — `dotnet format --verify-no-changes`)
3. Test (`make test`)

Permissions: `contents: read` (minimal).
