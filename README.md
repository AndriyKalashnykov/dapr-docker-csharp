[![CI](https://github.com/AndriyKalashnykov/dapr-docker-csharp/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/AndriyKalashnykov/dapr-docker-csharp/actions/workflows/ci.yml)
[![Hits](https://hits.sh/github.com/AndriyKalashnykov/dapr-docker-csharp.svg?view=today-total&style=plastic)](https://hits.sh/github.com/AndriyKalashnykov/dapr-docker-csharp/)
[![License: MIT](https://img.shields.io/badge/License-MIT-brightgreen.svg)](https://opensource.org/licenses/MIT)
[![Renovate enabled](https://img.shields.io/badge/renovate-enabled-brightgreen.svg)](https://app.renovatebot.com/dashboard#github/AndriyKalashnykov/dapr-docker-csharp)

# Dapr on Docker Compose — C# Queue Processor

**Runtime surface:** ASP.NET Core minimal-API subscriber wired to a Dapr sidecar (`Dapr.AspNetCore`) for pub/sub on Redis Streams via `MapSubscribeHandler` + CloudEvents and Dapr state on Redis, with `OpenTelemetry.Extensions.Hosting` exporting OTLP traces to Jaeger and an `AddHealthChecks()`-backed `/healthz` endpoint probed by both the Dockerfile HEALTHCHECK and a compose-level healthcheck. **Delivery surface:** three-layer test pyramid (TUnit + FakeItEasy unit · TUnit + Testcontainers Redis+daprd integration · bash/curl e2e through Docker Compose covering pub/sub roundtrip and Jaeger trace ingestion), composite `make static-check` (`dotnet format --verify-no-changes` · `-warnaserror` · NuGet `--vulnerable` audit · Trivy filesystem scan · gitleaks · `minlag/mermaid-cli` C4 diagram lint), multi-stage production Dockerfile (non-root `app:app`, BuildKit-ARG-tunable HEALTHCHECK), GitHub Actions CI with `dorny/paths-filter` changes detector + `ci-pass` aggregator + `jdx/mise-action` toolchain bootstrap, `.env.example`-driven parameter externalization, mise-pinned auxiliary toolchain (Node, pnpm, act, trivy, gitleaks), and Renovate-managed deps with `automergeType: pr` covering NuGet + Dockerfile + docker-compose + GitHub Actions + mise + custom-regex (Makefile + C# annotations).

## Tech Stack

| Component | Technology |
|-----------|------------|
| Language | C# / .NET 10.0 (SDK 10.0.201 via `global.json`) |
| Framework | ASP.NET Core (`Microsoft.NET.Sdk.Web`), `Dapr.AspNetCore` |
| Messaging | Dapr pub/sub on Redis Streams |
| State store | Dapr state on Redis |
| Tracing | OpenTelemetry → Jaeger (compose-declared) |
| Unit / integration testing | TUnit 1.28.0 + `WebApplicationFactory` + Testcontainers 4.11 |
| Mocking | FakeItEasy 9.0.1 |
| E2E testing | Docker Compose + bash curl harness |
| Container runtime | Docker Compose v2 |
| Static analysis | `dotnet format`, `dotnet build -warnaserror`, `dotnet list package --vulnerable`, Trivy filesystem scan, gitleaks, mermaid-cli |
| CI | GitHub Actions (changes → static-check → build/test/integration-test → e2e → ci-pass) |
| Dependency mgmt | Renovate (PR automerge, squash) |
| Version manager | mise (`.mise.toml` pins Node, pnpm, act, trivy, gitleaks) |

## Quick Start

```bash
make deps       # verify .NET SDK + Docker, bootstrap mise
make build      # build the solution
make start      # start all services (app + Dapr sidecar + Redis + Jaeger)
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
| [mise](https://mise.jdx.dev/) | latest | Polyglot version manager (Node, pnpm, act per `.mise.toml`) |
| [jq](https://jqlang.github.io/jq/) | latest | API response formatting |
| [redis-cli](https://redis.io/docs/getting-started/) | latest | Redis debugging (optional) |

Install required tools (idempotent — verifies .NET / Docker, bootstraps mise, installs `.mise.toml` tools):

```bash
make deps
```

## Architecture

```mermaid
C4Context
    title System Context — Dapr on Docker Compose
    Person(operator, "Operator", "curl / Make targets")
    System(qp, "QueueProcessor", "ASP.NET Core minimal API + Dapr sidecar; squares input and persists to state store")
    System_Ext(jaeger, "Jaeger", "OTel trace collector + UI")
    Rel(operator, qp, "HTTP", "GET / · POST /counter · publish via Dapr API")
    Rel(qp, jaeger, "OTLP gRPC :4317", "exports traces via OpenTelemetry.Exporter.OpenTelemetryProtocol")
```

```mermaid
C4Container
    title Container Diagram — QueueProcessor on Docker Compose
    Person(operator, "Operator")
    System_Boundary(compose, "docker compose") {
        Container(app, "QueueProcessor", "C# / .NET 10, ASP.NET Core, Dapr.AspNetCore", "GET / state · POST /counter (squares input) · pub/sub subscriber on topic counter")
        Container(daprd, "Dapr Sidecar", "daprd 1.17", "Pub/sub + state-store proxy; HTTP :3500, gRPC :50001")
        ContainerDb(redis, "Redis", "redis:8", "State store · pub/sub broker (Redis Streams)")
        Container(jaeger, "Jaeger", "jaegertracing/jaeger:2", "Trace collector + UI on :16686")
    }
    Rel(operator, app, "HTTP", "port 5000 (or HOST_PORT override)")
    Rel(app, daprd, "HTTP / gRPC", "in-pod localhost")
    Rel(daprd, redis, "RESP", "state SaveState/GetState · pubsub publish/subscribe")
    Rel(daprd, jaeger, "OTLP gRPC :4317", "trace export")
```

Component highlights:

- **QueueProcessor** — ASP.NET Core minimal API subscribing to the `counter` Dapr pub/sub topic via Redis Streams. Squares incoming integers and persists to the state store. Exposes `/healthz` (used by both Dockerfile HEALTHCHECK and the compose-level healthcheck). Emits OTLP traces via `OpenTelemetry.Extensions.Hosting`.
- **Dapr Sidecar** — `daprio/daprd` configured with `pubsub` (Redis Streams) and `statestore` (Redis) components; trace export wired through the Dapr `Configuration` CR.
- **Redis** — single broker handling both pub/sub backbone and state-store backing.
- **Jaeger** — OTLP trace collector reachable on the `dapr-demo-network`. Both the .NET app and the Dapr sidecar export to `jaeger:4317`. UI at `http://localhost:16686`.

Docker Compose files:

- `docker-compose.yaml` — app service (dev SDK image + `dotnet watch`), Redis, compose-level `healthcheck:` against `/healthz` (host port via `HOST_PORT`, defaults to 5000)
- `compose/dapr-docker-compose.yaml` — Dapr sidecar, Jaeger (on `dapr-demo-network` so `jaeger:4317` resolves from both app and sidecar)
- `e2e/docker-compose.e2e.override.yaml` — strips internal-only host port bindings for parallel-safe e2e

Production deployments build the image from `src/queue-processor/Dockerfile` (multi-stage; runtime image is `mcr.microsoft.com/dotnet/aspnet:10.0` with a non-root `app:app` user and a `HEALTHCHECK` directive against `/healthz`). Build with `make image-build`.

## Environment Configuration

`.env.example` (committed) declares every operator-tunable with a default — host port, app internal port, OTel exporter endpoint, Dapr publish port, pub/sub names, Jaeger query host:port, healthcheck cadence (image-level + compose-level), e2e timeouts and poll intervals, act ephemeral port range. Copy to `.env` (gitignored) for local overrides. `docker compose` auto-loads `.env`; the Makefile uses `?=` defaults; `e2e/e2e-test.sh` sources both files; integration tests read sidecar ports (`DAPR_HTTP_PORT`, `DAPR_GRPC_PORT`) via `Environment.GetEnvironmentVariable` with matching defaults.

## Testing

Three-layer pyramid:

| Layer | Where | Real dependencies | Command |
|-------|-------|-------------------|---------|
| Unit | `tests/queue-processor.tests/EndpointTests.cs` (TUnit + `WebApplicationFactory` + FakeItEasy-mocked `DaprClient`) | none — in-process | `make test` |
| Integration | `tests/queue-processor.integration.tests/StateStoreIntegrationTests.cs` (TUnit + Testcontainers Redis + daprd container, real `DaprClient` over HTTP/gRPC) | Redis + daprd via Testcontainers | `make integration-test` |
| E2E | `e2e/e2e-test.sh` (curl + Dapr publish API against the full Docker Compose stack) | Full compose stack: app + daprd + Redis + Jaeger | `make e2e` |

## Available Make Targets

Run `make help` to see all targets.

### Build & Run

| Target | Description |
|--------|-------------|
| `make build` | Build the solution |
| `make image-build` | Build the production Docker image (multi-stage, non-root, HEALTHCHECK) |
| `make test` | Run unit tests (TUnit, mocked DaprClient) |
| `make integration-test` | Run integration tests against real Dapr + Redis (Testcontainers) |
| `make e2e` | Run end-to-end tests via Docker Compose (full stack incl. pub/sub roundtrip) |
| `make lint` | Check code formatting + warnaserror build |
| `make vulncheck` | Check for vulnerable NuGet packages |
| `make trivy-fs` | Trivy filesystem scan (vulns + misconfigs, HIGH/CRITICAL) |
| `make secrets` | Scan working tree + git history for committed secrets (gitleaks) |
| `make mermaid-lint` | Validate Mermaid diagrams in Markdown files |
| `make static-check` | Composite quality gate (lint + vulncheck + trivy-fs + secrets + mermaid-lint) |
| `make format` | Auto-fix code formatting |
| `make clean` | Remove build artifacts |
| `make run` | Run the application locally |

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
| `make ci` | Run full local CI pipeline (static-check + test + build) |
| `make ci-run` | Run GitHub Actions workflow locally using [act](https://github.com/nektos/act) |
| `make deps` | Install required tools (idempotent) |
| `make deps-act` | Install act for local CI runs |
| `make renovate-bootstrap` | Install Node + pnpm via mise |
| `make renovate-validate` | Validate Renovate configuration |
| `make release` | Create and push a new tag |

## CI/CD

GitHub Actions runs on every push to `main`, tags `v*`, pull requests, `workflow_call`, and `workflow_dispatch`.

| Job | Triggers | Steps |
|-----|----------|-------|
| **changes** | every run | `dorny/paths-filter` short-circuits doc-only changes |
| **static-check** | code change or tag push | `make static-check` (lint + vulncheck + trivy-fs + secrets + mermaid-lint) |
| **build** | after static-check | `make build` |
| **test** | after static-check | `make test` (unit) |
| **integration-test** | after static-check | `make integration-test` (Testcontainers Redis + daprd) |
| **e2e** | after build | `make e2e` (Docker Compose full-stack roundtrip) |
| **ci-pass** | always | Aggregator status check for branch protection / Rulesets |

### Required Secrets and Variables

Only the auto-provided `GITHUB_TOKEN` is used. No additional secrets are required.

A separate cleanup workflow (`.github/workflows/cleanup-runs.yml`) prunes old workflow runs (retains 7 days / minimum 5) and stale branch caches weekly.

[Renovate](https://docs.renovatebot.com/) keeps dependencies up to date with PR automerge (squash strategy) enabled.
