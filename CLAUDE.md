# CLAUDE.md

## Project Overview

Dapr .NET demo application -- a queue processor using Dapr pub/sub with Redis, running via Docker Compose.

- **Language**: C# / .NET 10.0 (`global.json` pins SDK `10.0.201`)
- **Framework**: ASP.NET Core with Dapr.AspNetCore
- **Infrastructure**: Docker Compose (multi-file), Dapr sidecar, Redis
- **Solution**: `dapr-docker-csharp.slnx` (.NET 10 XML format)
- **App project**: `src/queue-processor/`
- **Test project**: `tests/queue-processor.tests/` (TUnit + NSubstitute + WebApplicationFactory)

## Build & Dev Commands

| Command | Purpose |
|---------|---------|
| `make help` | List all available targets |
| `make build` | Restore + build in Release mode |
| `make test` | Run TUnit tests via `dotnet run` |
| `make lint` | Check code formatting (`dotnet format --verify-no-changes`) |
| `make format` | Auto-fix code formatting |
| `make clean` | Remove build artifacts (bin/obj) |
| `make update` | Update NuGet packages to latest |
| `make run` | Run application locally |
| `make ci` | Full local CI pipeline (format + lint + test + build) |
| `make ci-run` | Run GitHub Actions locally via act |
| `make release` | Create and push a new tag |

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

## Utility Commands

| Command | Purpose |
|---------|---------|
| `make deps` | Install required tools (idempotent) |
| `make deps-act` | Install act for local CI runs |
| `make renovate-bootstrap` | Install nvm and npm for Renovate |
| `make renovate-validate` | Validate Renovate configuration |

## Tool Versions

- **act**: 0.2.87 (installed by `make deps-act` / `make ci-run`)
- **.NET SDK**: 10.0.201 (from `global.json`)

## Testing

- **Framework**: [TUnit](https://github.com/thomhurst/TUnit) 1.28.0 with Microsoft Testing Platform
- **Mocking**: NSubstitute 5.3.0
- **Integration**: `WebApplicationFactory<Program>` from `Microsoft.AspNetCore.Mvc.Testing`
- **Run**: `make test` (uses `dotnet run` — required for TUnit on .NET 10 SDK)

## CI

GitHub Actions workflow (`.github/workflows/ci.yml`) runs on push to main, tags `v*`, PRs, and `workflow_call`:

| Job | Depends on | Step |
|-----|-----------|------|
| **lint** | — | `make lint` (`dotnet format --verify-no-changes`) |
| **build** | lint | `make build` |
| **test** | lint | `make test` |

Permissions: `contents: read` (minimal). SDK version from `global.json`. NuGet caching via `packages.lock.json`.

A separate cleanup workflow (`.github/workflows/cleanup-runs.yml`) removes old runs weekly.

## Backlog

- [ ] Add health check endpoint and Docker HEALTHCHECK instruction

## Skills

Use the following skills when working on related files:

| File(s) | Skill |
|---------|-------|
| `Makefile` | `/makefile` |
| `renovate.json` | `/renovate` |
| `README.md` | `/readme` |
| `.github/workflows/*.yml` | `/ci-workflow` |

When spawning subagents, always pass conventions from the respective skill into the agent's prompt.
