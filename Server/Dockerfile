# FlightBag data server. One image serves both roles:
#   - `serve` (default CMD): Vapor API + artifact hosting
#   - `ingest-all` (compose `ingest` service): per-cycle chart production
#
# Build from the REPO ROOT so the ../Packages/FlightBagCore path dependency
# resolves:  docker build -f Server/Dockerfile .
# (docker-compose.yml sets this context for you.)

# ================================ Build stage ================================
FROM swift:6.1-noble AS build

# GRDB links the system SQLite on Linux.
RUN export DEBIAN_FRONTEND=noninteractive \
 && apt-get -q update \
 && apt-get -q install -y libsqlite3-dev \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Manifests first, so dependency resolution caches across source edits.
COPY Server/Package.swift Server/Package.resolved ./Server/
COPY Packages ./Packages
WORKDIR /build/Server
RUN swift package resolve

# Tests must be present for SPM to accept the manifest's testTarget.
COPY Server/Sources ./Sources
COPY Server/Tests ./Tests
RUN swift build -c release --product App --static-swift-stdlib

# Stage the runtime payload.
WORKDIR /staging
RUN cp "$(swift build -c release --show-bin-path --package-path /build/Server)/App" ./ \
 && if [ -f /usr/libexec/swift/linux/swift-backtrace-static ]; then \
      cp /usr/libexec/swift/linux/swift-backtrace-static ./; \
    fi

# =============================== Runtime stage ===============================
FROM ubuntu:24.04

# gdal-bin: gdal_translate / gdalwarp / gdaladdo for the tile pipeline.
# unzip/zip: chart/NASR extraction and plate bundling (hardcoded /usr/bin paths).
RUN export DEBIAN_FRONTEND=noninteractive \
 && apt-get -q update \
 && apt-get -q install -y --no-install-recommends \
      gdal-bin unzip zip libsqlite3-0 ca-certificates tzdata curl \
 && rm -rf /var/lib/apt/lists/*

RUN useradd --user-group --create-home --system --skel /dev/null --home-dir /app vapor

WORKDIR /app
COPY --from=build --chown=vapor:vapor /staging /app
# Mount points: artifacts (served by FileMiddleware) and the ingest workdir.
RUN mkdir -p /app/Public/artifacts /work && chown -R vapor:vapor /app/Public /work

ENV SWIFT_BACKTRACE=enable=yes,sanitize=yes,threads=all,images=all,interactive=no,swift-backtrace=./swift-backtrace-static

USER vapor:vapor
EXPOSE 8080
ENTRYPOINT ["./App"]
CMD ["serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "8080"]
