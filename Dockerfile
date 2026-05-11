# ── JL_Engine-SB.Omni — Full Engine Image ─────────────────────────────────────
# Registry: jaden688/jl-engine
#
# Build:
#   docker build -t jaden688/jl-engine:latest .
#
# Run:
#   docker run --rm -p 8081:8081 --env-file .env jaden688/jl-engine:latest

ARG JULIA_VERSION=1.12.1
FROM julia:${JULIA_VERSION} AS base

LABEL org.opencontainers.image.title="JL_Engine-SB.Omni" \
      org.opencontainers.image.description="Julia-native agentic AI engine — SparkByte + JLEngine" \
      org.opencontainers.image.source="https://github.com/jaden688/JL_Engine-SB.Omni" \
      org.opencontainers.image.authors="jaden688"

ENV DEBIAN_FRONTEND=noninteractive \
    JULIA_CONDAPKG_BACKEND=Null \
    JULIA_PYTHONCALL_EXE=/opt/venv/bin/python \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    SPARKBYTE_HOST=0.0.0.0 \
    SPARKBYTE_PORT=8081 \
    SPARKBYTE_LAUNCH_BROWSER=0 \
    SPARKBYTE_SKIP_PKG_INSTANTIATE=1 \
    SPARKBYTE_STATE_DIR=/app/runtime \
    VIRTUAL_ENV=/opt/venv \
    PATH=/opt/venv/bin:$PATH

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    git \
    python3 \
    python3-pip \
    python3-venv \
    python3-dev \
    libpython3-dev \
    python-is-python3 \
    && rm -rf /var/lib/apt/lists/*

RUN python -m venv /opt/venv

# Python deps layer — cached unless requirements change
COPY requirements.docker.txt ./requirements.docker.txt
RUN pip install --no-cache-dir -r requirements.docker.txt && \
    python -m playwright install --with-deps chromium

# ── Julia precompile stage ─────────────────────────────────────────────────────
FROM base AS build

ARG CACHE_BUST=1

# Copy manifests first for better layer caching
COPY Project.toml Manifest.toml ./
RUN julia --project=. -e 'using Pkg; Pkg.instantiate()'

COPY . .
RUN julia --project=. -e 'using Pkg; Pkg.precompile()'

# ── Runtime stage ──────────────────────────────────────────────────────────────
FROM base AS runtime

COPY --chown=root:root . .
COPY --from=build /root/.julia /root/.julia

RUN mkdir -p /app/runtime

EXPOSE 8081
EXPOSE 8082

HEALTHCHECK --interval=30s --timeout=8s --start-period=40s --retries=5 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8081/health', timeout=7).read()"

CMD ["julia", "--project=.", "sparkbyte.jl"]
