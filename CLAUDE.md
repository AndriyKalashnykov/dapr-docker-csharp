# CLAUDE.md

## Project Overview

Dapr .NET demo application -- a queue processor using Dapr pub/sub with Redis, running via Docker Compose.

- **Language**: C# / .NET 10.0 (`global.json` pins SDK `10.0.201`)
- **Framework**: ASP.NET Core with Dapr.AspNetCore
- **Infrastructure**: Docker Compose (multi-file), Dapr sidecar, Redis, Jaeger (OTel tracing)
- **Solution**: `dapr-docker-csharp.slnx` (.NET 10 XML format)
- **App project**: `src/queue-processor/`
- **Test projects**:
  - `tests/queue-processor.tests/` — unit (TUnit + FakeItEasy + WebApplicationFactory)
  - `tests/queue-processor.integration.tests/` — integration (TUnit + Testcontainers Redis + daprd, real `DaprClient`)
- **E2E**: `e2e/e2e-test.sh` — Docker Compose + curl + Dapr publish API
- **Version manager**: mise (`.mise.toml` pins Node, pnpm, act, trivy, gitleaks)

## Build & Dev Commands

| Command | Purpose |
|---------|---------|
| `make help` | List all available targets |
| `make build` | Restore + build in Release mode |
| `make image-build` | Build the production Docker image (multi-stage, non-root, HEALTHCHECK) |
| `make test` | Run unit tests (TUnit, mocked `DaprClient`) |
| `make integration-test` | Run integration tests (Testcontainers Redis + daprd, real `DaprClient`) |
| `make e2e` | End-to-end tests via Docker Compose (full stack incl. pub/sub roundtrip) |
| `make lint` | Check formatting and build warnings (`dotnet format` + `dotnet build -warnaserror`) |
| `make vulncheck` | Check for vulnerable NuGet packages (direct + transitive) |
| `make trivy-fs` | Trivy filesystem scan (vulns + misconfigs) |
| `make secrets` | Scan tree + git history for committed secrets (gitleaks) |
| `make mermaid-lint` | Validate Mermaid diagrams in Markdown |
| `make static-check` | Composite quality gate (lint + vulncheck + trivy-fs + secrets + mermaid-lint) |
| `make format` | Auto-fix code formatting |
| `make clean` | Remove build artifacts (bin/obj) |
| `make run` | Run application locally |
| `make ci` | Full local CI pipeline (static-check + test + integration-test + build) |
| `make ci-run` | Run GitHub Actions locally via act |
| `make release` | Create and push a new tag |

## Docker Compose Commands

| Command | Purpose |
|---------|---------|
| `make start` | Start all services (app + Dapr + Redis + Jaeger) |
| `make stop` | Stop and remove containers |
| `make restart` | Stop then start |
| `make pull` | Pull latest Docker images |

`HOST_PORT` env var overrides the host port for the app (default 5000). E2E picks a free port via `scripts/pick-port.sh` and applies `e2e/docker-compose.e2e.override.yaml` to drop internal-service host bindings (Redis, Jaeger) so parallel runs don't collide.

## Environment configuration

`.env.example` (committed) is the source of truth for every operator-tunable. Copy to `.env` (gitignored) for local overrides. `docker compose` auto-loads `.env`; the Makefile uses `?=` defaults; `e2e/e2e-test.sh` sources both files; the integration test fixture reads `DAPR_HTTP_PORT` / `DAPR_GRPC_PORT` with the same defaults via `Environment.GetEnvironmentVariable`. Adding a new tunable: declare in `.env.example`, then `${VAR:-default}` (compose / shell) or `?=` (Make) or `Environment.GetEnvironmentVariable("VAR") ?? "default"` (.NET) at the use site. See `rules/common/configuration.md` for the portfolio rule.

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
| `make deps` | Install required tools (idempotent; bootstraps mise + `.mise.toml` tools) |
| `make deps-act` | Install act for local CI runs (via mise) |
| `make renovate-bootstrap` | Install Node + pnpm via mise for Renovate |
| `make renovate-validate` | Validate Renovate configuration |

## Tool Versions

Pinned in `.mise.toml` and Renovate-tracked:

- **Node**: 22 (used by Renovate validation)
- **pnpm**: 11.1.1
- **jq**: 1.8.1 (`aqua:jqlang/jq`)
- **act**: 0.2.88 (`aqua:nektos/act`)
- **trivy**: 0.70.0 (`aqua:aquasecurity/trivy`)
- **gitleaks**: 8.30.1 (`aqua:gitleaks/gitleaks`)
- **mermaid-cli**: 11.14.0 (Docker image `minlag/mermaid-cli`, version constant in Makefile with `# renovate:` annotation)
- **.NET SDK**: 10.0.201 (from `global.json`)

## Testing

Three-layer pyramid — each layer covers a distinct surface and runs as its own CI job:

| Layer | Location | Dependencies | Command | CI job |
|-------|----------|--------------|---------|--------|
| Unit | `tests/queue-processor.tests/` | in-process; FakeItEasy-mocked `DaprClient` | `make test` | `test` |
| Integration | `tests/queue-processor.integration.tests/` | Testcontainers Redis + daprd; real `DaprClient` over HTTP/gRPC | `make integration-test` | `integration-test` |
| E2E | `e2e/e2e-test.sh` | Full Docker Compose stack: app + daprd + Redis + Jaeger | `make e2e` | `e2e` |

- **Framework**: [TUnit](https://github.com/thomhurst/TUnit) 1.28.0 with Microsoft Testing Platform
- **Mocking**: FakeItEasy 9.0.1 (per portfolio testing rule)
- **Integration containers**: `Testcontainers` + `Testcontainers.Redis` 4.11
- **Run discipline**: `dotnet run --project ...` (required for TUnit on .NET 10 SDK; MTP entry point)

## CI

GitHub Actions workflow (`.github/workflows/ci.yml`) runs on push to main, tags `v*`, PRs, `workflow_call`, and `workflow_dispatch`:

| Job | Depends on | Step |
|-----|-----------|------|
| **changes** | — | `dorny/paths-filter` short-circuits doc-only changes |
| **static-check** | changes (code) | `make static-check` (lint + vulncheck + trivy-fs + secrets + mermaid-lint) |
| **build** | static-check | `make build` |
| **test** | static-check | `make test` (unit) |
| **integration-test** | static-check | `make integration-test` (Testcontainers) |
| **e2e** | build | `make e2e` (Docker Compose full-stack) |
| **ci-pass** | all of the above (always) | Aggregator status check (target for branch protection / Rulesets) |

Permissions: workflow-level `contents: read` + `pull-requests: read` (for `paths-filter`). SDK version from `global.json`. NuGet caching via `packages.lock.json`. mise-action installs `.mise.toml`-pinned tools for the static-check job.

A separate cleanup workflow (`.github/workflows/cleanup-runs.yml`) prunes old workflow runs (`cleanup-runs`) and stale branch caches (`cleanup-caches`) weekly.

## Observability

The app uses `OpenTelemetry.Extensions.Hosting` (1.15.x) with ASP.NET Core + HttpClient instrumentation and an OTLP gRPC exporter. The exporter endpoint is read from `OTEL_EXPORTER_OTLP_ENDPOINT` (set to `http://jaeger:4317` in `docker-compose.yaml`). Service name is `queueprocessor` (overridable via `OTEL_SERVICE_NAME`). Spans appear at the Jaeger UI (`http://localhost:16686`) once traffic flows.

The Dapr `Configuration` CR (`compose/configuration/configuration.yaml`) wires daprd's own traces to the same OTLP collector, so end-to-end traces span both the app and the sidecar.

## Health checks

- `/healthz` endpoint registered via `AddHealthChecks()` / `MapHealthChecks("/healthz")` — returns `200 Healthy` once the app process is ready.
- Production `src/queue-processor/Dockerfile` carries a `HEALTHCHECK` directive that polls `http://localhost:5000/healthz` with `curl`.
- Dev `docker-compose.yaml` declares an equivalent `healthcheck:` block on the `queueprocessor` service so `compose up --wait` blocks correctly during e2e.

## Image build

| Command | Purpose |
|---------|---------|
| `make image-build` | Build the production image (`queue-processor:<git-describe>` + `:latest`) via multi-stage Dockerfile with non-root `app:app` user and HEALTHCHECK |

## Skills

Use the following skills when working on related files:

| File(s) | Skill |
|---------|-------|
| `Makefile` | `/makefile` |
| `renovate.json` | `/renovate` |
| `README.md` | `/readme` |
| `.github/workflows/*.{yml,yaml}` | `/ci-workflow` |
| Mermaid blocks in `*.md` | `/architecture-diagrams` |
| `tests/**/*.cs`, `e2e/**` | `/test-coverage-analysis`; TUnit + FakeItEasy per `~/.claude/rules/dotnet/testing.md` |

When spawning subagents, always pass conventions from the respective skill into the agent's prompt.
