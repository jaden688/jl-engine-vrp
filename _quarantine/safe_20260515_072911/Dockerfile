# ── JL_Engine-SB.Omni — Full Engine Image ─────────────────────────────────────
# Registry: jaden688/jl-engine
# Multi-stage build with optimized layer caching.
#
# Build:
#   docker build -t jaden688/jl-engine:latest .
#   docker build -t jaden688/jl-engine:latest --target runtime .
#
# Run:
#   docker run --rm -p 8081:8081 --env-file .env jaden688/jl-engine:latest

ARG JULIA_VERSION=1.12.1
ARG PYTHON_VERSION=3.12

# ── Base: Julia + system deps ──────────────────────────────────────────────────
FROM julia:${JULIA_VERSION} AS base

LABEL org.opencontainers.image.title="JL_Engine-SB.Omni" \
      org.opencontainers.image.description="Julia-native agentic AI engine — SparkByte + JLEngine" \
      org.opencontainers.image.source="https://github.com/jaden688/JL_Engine-SB.Omni" \
      org.opencontainers.image.version="0.1.0" \
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

# Install system dependencies once, in a single layer for better caching
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

# Create Python virtual environment
RUN python -m venv /opt/venv

# ── Python dependencies layer (cached if requirements.docker.txt unchanged) ────
FROM base AS python-deps

COPY requirements.docker.txt ./
RUN pip install --no-cache-dir -r requirements.docker.txt && \
    python -m playwright install --with-deps chromium

# ── Julia dependencies layer (instantiate without precompile for now) ────────
FROM python-deps AS julia-build

# Copy Julia manifests first (changes less frequently than source code)
COPY Project.toml Manifest.toml ./

# Instantiate Julia packages (precompilation happens at runtime)
RUN julia --project=. -e 'using Pkg; Pkg.instantiate()'

# ── Source code & runtime layer ───────────────────────────────────────────────
FROM julia-build AS runtime

# Copy everything else (source, configs, assets, etc.)
COPY . .

# Ensure runtime directories exist and have correct permissions
RUN mkdir -p /app/runtime /app/logs /app/data && \
    chmod -R 755 /app/runtime /app/logs /app/data && \
    # Precompile Julia project at build time if possible (errors are non-fatal)
    julia --project=. -e 'using Pkg; try Pkg.precompile() catch e println(e) end' || true

# Health check endpoint (HTTP GET to internal health endpoint)
HEALTHCHECK --interval=30s --timeout=8s --start-period=40s --retries=5 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8081/health', timeout=7).read()" || exit 1

EXPOSE 8081 8082

# Start the SparkByte application
CMD ["julia", "--project=.", "sparkbyte.jl"]
