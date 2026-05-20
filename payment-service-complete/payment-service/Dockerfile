# ── Stage 1: builder ──────────────────────────────────────────────────────────
# Use a full Python image to install dependencies
FROM python:3.11-slim AS builder

WORKDIR /build

# Copy and install dependencies into a separate directory
# so we only copy what's needed into the final image
COPY app/requirements.txt .
RUN pip install --upgrade pip \
 && pip install --no-cache-dir --prefix=/install -r requirements.txt


# ── Stage 2: runtime ──────────────────────────────────────────────────────────
# Use distroless-style slim image — smaller attack surface, no shell
FROM python:3.11-slim AS runtime

# Security: run as non-root user
RUN groupadd --gid 1001 appgroup \
 && useradd  --uid 1001 --gid appgroup --no-create-home appuser

WORKDIR /app

# Copy only installed packages from builder stage
COPY --from=builder /install /usr/local

# Copy application code
COPY app/main.py .

# Drop all Linux capabilities — principle of least privilege
# (set in Kubernetes securityContext too, but good defence-in-depth)
USER appuser

# Expose the application port
EXPOSE 8000

# Health check so Docker itself knows the container is healthy
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/healthz')"

# Run with uvicorn — 2 workers, production settings
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", \
     "--workers", "2", "--access-log", "--log-level", "info"]
