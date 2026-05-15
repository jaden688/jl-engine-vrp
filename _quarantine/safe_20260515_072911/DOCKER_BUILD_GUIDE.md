# Docker Build & Deployment Guide

## Overview
JL_Engine-SB.Omni is a containerized Julia + Python hybrid application with Docker Compose orchestration for multi-service deployment.

## Files Generated

### 1. **Dockerfile** (Main Engine)
Multi-stage build optimized for layer caching and minimal image size.

**Stages:**
- `base`: Julia + system dependencies + Python venv
- `python-deps`: Python requirements (cached layer)
- `julia-build`: Julia project instantiation
- `runtime`: Final application image

**Key optimizations:**
- System dependencies in single `apt-get` layer
- Python packages cached separately from Julia deps
- Playwright browser installation with system deps
- Non-root user recommended for security

**Build:**
```bash
docker build -t jaden688/jl-engine:latest .
docker build -t jaden688/jl-engine:latest --target runtime .
```

**Run:**
```bash
docker run --rm -p 8081:8081 --env-file .env jaden688/jl-engine:latest
```

---

### 2. **mcp_server/Dockerfile** (MCP Protocol Bridge)
Lightweight Python-only container for Claude/LLM integration.

**Key features:**
- Slim Python 3.12 base image
- Virtual environment for clean dependency isolation
- Non-root user (`mcp:1001`)
- Health check for both stdio and SSE modes
- Supports environment variable overrides at runtime

**Build:**
```bash
docker build -t jaden688/sparkbyte-mcp:latest -f mcp_server/Dockerfile .
```

**Run (stdio mode):**
```bash
docker run --rm -i jaden688/sparkbyte-mcp:latest
```

**Run (SSE HTTP mode):**
```bash
docker run --rm -p 8083:8083 \
  -e MCP_TRANSPORT=sse \
  -e SPARKBYTE_WS=ws://host.docker.internal:8081 \
  jaden688/sparkbyte-mcp:latest
```

---

### 3. **compose.yaml** (Service Orchestration)
Complete multi-service stack with health checks, networking, and volumes.

**Services:**
- **sparkbyte**: Main Julia + Python engine
- **mcp**: MCP protocol server for Claude integration

**Features:**
- Dedicated bridge network (`sparkbyte-net`)
- Health checks for both services
- Service dependency (`mcp` waits for `sparkbyte` healthy)
- Environment variable substitution from `.env`
- Persistent volumes for state, logs, data
- `extra_hosts` for local service access (e.g., Ollama)

**Common commands:**
```bash
# Start all services
docker compose up -d

# View logs
docker compose logs -f

# Stop services
docker compose down

# Rebuild images
docker compose build --no-cache

# Pull always and restart
docker compose up --pull always --force-recreate
```

---

### 4. **.dockerignore** (Build Context Optimization)
Excludes unnecessary files from build context to reduce transfer size and improve cache efficiency.

**Excluded categories:**
- Version control (`.git`, `.github/`)
- IDE files (`.vscode/`, `.idea/`)
- Development/temporary files (logs, cache, `.env`)
- Large media (images, videos)
- Non-essential directories (`legacy/`, `test/`)

---

## Best Practices Applied

### Layer Caching Strategy
1. **Base layer**: System dependencies (rarely changes)
2. **Dependencies layer**: Python requirements (changes when requirements.docker.txt updates)
3. **Source layer**: Application code (changes frequently)

Result: Rebuilds only rebuild necessary layers.

### Image Size Optimization
- Multi-stage builds (only final `runtime` stage included)
- Minimal base images (Julia + Python slim)
- Dependency caching
- `.dockerignore` to exclude build artifacts

### Security
- Non-root user in MCP container
- Health checks to detect failed services
- Environment variable isolation
- Read-only volume options available (if needed)

### Networking
- Dedicated bridge network for service-to-service communication
- Service names resolve via DNS (`sparkbyte:8081` from MCP)
- Host bridge for local services (`host.docker.internal`)

### Health Checks
- Main engine: HTTP GET `/health` endpoint (30s interval)
- MCP server: HTTP GET `/health` endpoint (20s interval)
- Automatic container restart on unhealthy status
- Service dependencies enforce ordering

---

## Environment Configuration

Copy `.env.example` to `.env` and customize:

```bash
cp .env.example .env
```

**Key variables:**
- `SPARKBYTE_PUBLIC_PORT`: Main engine HTTP port (default: 8081)
- `A2A_PUBLIC_PORT`: Agent-to-agent bridge port (default: 8082)
- `MCP_PUBLIC_PORT`: MCP server port (default: 8083)
- `OLLAMA_BASE_URL`: Local LLM endpoint (default: `http://host.docker.internal:11434`)
- `JULIAN_AUTONOMOUS_SECONDS`: Autonomous agent timeout (default: 3600)

---

## Deployment

### Local Development
```bash
docker compose up --pull always
```

### Production
```bash
# Build with specific version tags
docker build -t registry.example.com/jl-engine:v0.1.0 .
docker build -t registry.example.com/sparkbyte-mcp:v0.1.0 -f mcp_server/Dockerfile .

# Push to registry
docker push registry.example.com/jl-engine:v0.1.0
docker push registry.example.com/sparkbyte-mcp:v0.1.0

# Deploy
docker compose -f compose.yaml up -d
```

### Kubernetes
Generate manifests from compose:
```bash
kompose convert -f compose.yaml -o k8s/
kubectl apply -f k8s/
```

---

## Troubleshooting

### Build Fails with "Missing source file"
Julia precompilation requires the project to be installed first. The Dockerfile handles this with non-fatal error handling.

**Solution:** Precompilation happens at first runtime. Subsequent runs use cached compilation.

### MCP Container Won't Connect to Engine
Check network connectivity:
```bash
docker compose exec mcp ping sparkbyte
docker compose logs mcp
```

### High Memory Usage
Julia can consume 2-4GB during compilation. Allocate sufficient Docker memory:
```bash
# macOS/Windows Docker Desktop
# Preferences → Resources → Memory: 8GB+
```

### Volumes Not Persisting
Verify volume mount points:
```bash
docker volume ls
docker volume inspect sparkbyte-state
```

---

## Image Inspection

View image details:
```bash
docker image inspect jaden688/jl-engine:latest
docker image history jaden688/jl-engine:latest
```

Estimate layer sizes:
```bash
docker build --progress=plain -t test . 2>&1 | grep "DONE"
```

---

## Next Steps

1. **Push images**: Tag and push to Docker Hub or private registry
2. **Add CI/CD**: GitHub Actions to auto-build on commits
3. **Monitor**: Implement health checks and logging aggregation
4. **Security scanning**: Use Docker Scout or Trivy for vulnerability scanning
5. **Performance tuning**: Profile and optimize Julia startup time

---

## References

- [Docker Compose Documentation](https://docs.docker.com/compose/)
- [Dockerfile Best Practices](https://docs.docker.com/develop/develop-images/dockerfile_best-practices/)
- [Julia in Docker](https://github.com/JuliaLang/julia/blob/master/contrib/dockerfiles/Dockerfile)
