# syntax=docker/dockerfile:1.25@sha256:0adf442eae370b6087e08edc7c50b552d80ddf261576f4ebd6421006b2461f12

# ----- Build stage -----
FROM mcr.microsoft.com/dotnet/sdk:10.0@sha256:ed034a8bf0b24ded0cbbac07e17825d8e9ebfe21e308191d0f7421eaf5ad4664 AS build
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
FROM mcr.microsoft.com/dotnet/aspnet:10.0@sha256:1fa23fc4872d95fd71c2833ebe65d7e84a43b2d51a31d119516852f13d9505a7 AS runtime

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
ENV APP_INTERNAL_PORT=${APP_INTERNAL_PORT} \
    HEALTHCHECK_HOST=${HEALTHCHECK_HOST} \
    ASPNETCORE_URLS=http://*:${APP_INTERNAL_PORT} \
    DOTNET_RUNNING_IN_CONTAINER=true \
    DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=true

EXPOSE ${APP_INTERNAL_PORT}

# Liveness probe: the /healthz endpoint registered by AddHealthChecks in Program.cs.
# HEALTHCHECK flag timings MUST be literal durations — they are parsed at
# Dockerfile-parse time and are NOT ARG/ENV-expanded (`--interval=${VAR}` fails
# the build with `invalid duration`). The CMD body, by contrast, runs under
# /bin/sh at container start and DOES honor ${ENV}, so the probe host/port stay
# runtime-tunable via `docker run -e HEALTHCHECK_HOST=… -e APP_INTERNAL_PORT=…`.
HEALTHCHECK --interval=30s --timeout=3s --start-period=20s --retries=3 \
    CMD curl -sf "http://${HEALTHCHECK_HOST}:${APP_INTERNAL_PORT}/healthz" || exit 1

ENTRYPOINT ["dotnet", "queue-processor.dll"]
