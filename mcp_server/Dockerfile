# ── SparkByte MCP Server — Standalone Container ──────────────────────────────
# Registry: jaden688/sparkbyte-mcp
# Standalone MCP protocol server bridging Claude/LLMs to SparkByte engine.
#
# Build:
#   docker build -t jaden688/sparkbyte-mcp:latest -f mcp_server/Dockerfile .
#
# Run (stdio mode):
#   docker run --rm -i jaden688/sparkbyte-mcp:latest
#
# Run (SSE mode over HTTP):
#   docker run --rm -p 8083:8083 \
#     -e MCP_TRANSPORT=sse \
#     -e SPARKBYTE_WS=ws://host.docker.internal:8081 \
#     jaden688/sparkbyte-mcp:latest

ARG PYTHON_VERSION=3.12
FROM python:${PYTHON_VERSION}-slim

LABEL org.opencontainers.image.title="SparkByte MCP Server" \
      org.opencontainers.image.description="Standalone MCP protocol bridge for JL_Engine-SB.Omni" \
      org.opencontainers.image.source="https://github.com/jaden688/JL_Engine-SB.Omni" \
      org.opencontainers.image.version="0.1.0" \
      org.opencontainers.image.authors="jaden688"

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    VIRTUAL_ENV=/opt/venv \
    PATH=/opt/venv/bin:$PATH \
    # MCP server defaults (override at runtime)
    MCP_TRANSPORT=stdio \
    MCP_PORT=8083 \
    MCP_BIND=0.0.0.0 \
    SPARKBYTE_WS=ws://host.docker.internal:8081 \
    MCP_ALLOW_REMOTE_WS=1 \
    MCP_WS_CONCURRENCY=4 \
    MCP_MAX_RESPONSE_BYTES=60000

WORKDIR /app

# Create virtual environment for layered caching
RUN python -m venv /opt/venv

# Install Python dependencies (cached layer)
COPY mcp_server/requirements.txt ./mcp_server/
RUN pip install --no-cache-dir -r mcp_server/requirements.txt

# Copy only necessary runtime files (excludes tests, docs, etc. via .dockerignore)
COPY mcp_server/ ./mcp_server/
COPY sparkbyte_memory.db* ./
COPY dynamic_tools_registry.json* ./
COPY JulianMetaMorph/ ./JulianMetaMorph/

# Create non-root user for security
RUN useradd -m -u 1001 mcp && chown -R mcp:mcp /app
USER mcp

EXPOSE 8083

# Health check (works in both stdio and SSE modes)
HEALTHCHECK --interval=20s --timeout=5s --start-period=10s --retries=3 \
    CMD python -c "\
import urllib.request, os; \
port = os.environ.get('MCP_PORT', '8083'); \
try: \
  urllib.request.urlopen(f'http://127.0.0.1:{port}/health', timeout=4).read(); \
  exit(0); \
except: \
  exit(1)" || exit 1

# Default command: MCP server in stdio mode
# Override with -e MCP_TRANSPORT=sse for HTTP mode
CMD ["python", "-m", "mcp_server.server"]
