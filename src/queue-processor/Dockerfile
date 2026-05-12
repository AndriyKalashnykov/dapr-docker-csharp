# syntax=docker/dockerfile:1.7

# ----- Build stage -----
FROM mcr.microsoft.com/dotnet/sdk:10.0@sha256:f061e5a7532b36fa1d1b684857fe1f504ba92115b9934f154643266613c44c62 AS build
WORKDIR /src

# Copy csproj + lockfile first for cache-friendly restore.
COPY src/queue-processor/queue-processor.csproj src/queue-processor/
COPY src/queue-processor/packages.lock.json src/queue-processor/
RUN dotnet restore src/queue-processor/queue-processor.csproj --locked-mode

COPY src/queue-processor/ src/queue-processor/
RUN dotnet publish src/queue-processor/queue-processor.csproj \
    -c Release \
    --no-restore \
    -o /app/publish

# ----- Runtime stage -----
FROM mcr.microsoft.com/dotnet/aspnet:10.0@sha256:55e37c7795bfaf6b9cc5d77c155811d9569f529d86e20647704bc1d7dd9741d4 AS runtime

# curl is required by Docker HEALTHCHECK. Install + clean apt lists in one layer.
# Microsoft's aspnet:10.0 image already ships a non-root `app` user (UID 1654);
# we reuse it rather than creating a duplicate.
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=build --chown=app:app /app/publish ./

USER app:app

# Container-internal port + healthcheck host — kept in sync with `.env.example`.
# Override at build time with `--build-arg KEY=value` (see Makefile image-build).
ARG APP_INTERNAL_PORT=5000
ARG HEALTHCHECK_HOST=localhost
ARG HEALTHCHECK_INTERVAL=30s
ARG HEALTHCHECK_TIMEOUT=3s
ARG HEALTHCHECK_START_PERIOD=20s
ARG HEALTHCHECK_RETRIES=3
ENV APP_INTERNAL_PORT=${APP_INTERNAL_PORT} \
    HEALTHCHECK_HOST=${HEALTHCHECK_HOST} \
    ASPNETCORE_URLS=http://*:${APP_INTERNAL_PORT} \
    DOTNET_RUNNING_IN_CONTAINER=true \
    DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=true

EXPOSE ${APP_INTERNAL_PORT}

# Liveness probe: the /healthz endpoint registered by AddHealthChecks in Program.cs.
# HEALTHCHECK flags use build-time ARG substitution (BuildKit). The CMD args
# use `${ENV}` runtime expansion so `docker run -e …` overrides reach the probe.
HEALTHCHECK --interval=${HEALTHCHECK_INTERVAL} --timeout=${HEALTHCHECK_TIMEOUT} \
    --start-period=${HEALTHCHECK_START_PERIOD} --retries=${HEALTHCHECK_RETRIES} \
    CMD curl -sf "http://${HEALTHCHECK_HOST}:${APP_INTERNAL_PORT}/healthz" || exit 1

ENTRYPOINT ["dotnet", "queue-processor.dll"]
