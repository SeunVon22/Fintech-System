"""
Payment Status Microservice
A production-realistic FastAPI service for checking payment transaction status.
Designed to run on AKS — includes health probes, structured logging, and Prometheus metrics.
"""

import time
import uuid
import logging
from datetime import datetime, timezone
from enum import Enum
from typing import Optional

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST
from starlette.responses import Response

# ── Structured logging ────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format='{"time": "%(asctime)s", "level": "%(levelname)s", "message": "%(message)s"}'
)
logger = logging.getLogger(__name__)

# ── Prometheus metrics ─────────────────────────────────────────────────────────
REQUEST_COUNT = Counter(
    "payment_requests_total",
    "Total number of payment API requests",
    ["method", "endpoint", "status_code"]
)
REQUEST_LATENCY = Histogram(
    "payment_request_duration_seconds",
    "Payment API request latency in seconds",
    ["endpoint"]
)
PAYMENT_STATUS_COUNTER = Counter(
    "payment_status_lookups_total",
    "Total payment status lookups by result",
    ["status"]
)

# ── App setup ─────────────────────────────────────────────────────────────────
app = FastAPI(
    title="Payment Status Service",
    description="Microservice for querying payment transaction status",
    version="1.0.0",
)

# ── Enums & Models ────────────────────────────────────────────────────────────
class PaymentStatus(str, Enum):
    PENDING    = "PENDING"
    PROCESSING = "PROCESSING"
    COMPLETED  = "COMPLETED"
    FAILED     = "FAILED"
    REVERSED   = "REVERSED"

class PaymentResponse(BaseModel):
    transaction_id: str
    status: PaymentStatus
    amount: float
    currency: str = "NGN"
    created_at: str
    updated_at: str
    message: str

class HealthResponse(BaseModel):
    status: str
    version: str = "1.0.0"
    timestamp: str

# ── Mock data store (replace with real DB in production) ──────────────────────
MOCK_PAYMENTS = {
    "TXN-001": {"status": PaymentStatus.COMPLETED,  "amount": 50000.00},
    "TXN-002": {"status": PaymentStatus.PENDING,    "amount": 12500.00},
    "TXN-003": {"status": PaymentStatus.FAILED,     "amount": 8750.00},
    "TXN-004": {"status": PaymentStatus.PROCESSING, "amount": 200000.00},
    "TXN-005": {"status": PaymentStatus.REVERSED,   "amount": 35000.00},
}

# ── Middleware: request timing ─────────────────────────────────────────────────
@app.middleware("http")
async def metrics_middleware(request: Request, call_next):
    start = time.time()
    response = await call_next(request)
    duration = time.time() - start

    REQUEST_COUNT.labels(
        method=request.method,
        endpoint=request.url.path,
        status_code=response.status_code
    ).inc()
    REQUEST_LATENCY.labels(endpoint=request.url.path).observe(duration)

    logger.info(f"method={request.method} path={request.url.path} "
                f"status={response.status_code} duration={duration:.3f}s")
    return response

# ── Routes ────────────────────────────────────────────────────────────────────

@app.get("/healthz", response_model=HealthResponse, tags=["ops"])
async def liveness():
    """Kubernetes liveness probe — returns 200 if the process is alive."""
    return HealthResponse(
        status="ok",
        timestamp=datetime.now(timezone.utc).isoformat()
    )

@app.get("/readyz", response_model=HealthResponse, tags=["ops"])
async def readiness():
    """
    Kubernetes readiness probe — returns 200 only when the service
    is ready to accept traffic (e.g. DB connections established).
    """
    # In production: check DB pool, cache connection, downstream deps
    return HealthResponse(
        status="ready",
        timestamp=datetime.now(timezone.utc).isoformat()
    )

@app.get("/metrics", tags=["ops"])
async def metrics():
    """Prometheus scrape endpoint."""
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)

@app.get("/api/v1/payments/{transaction_id}", response_model=PaymentResponse, tags=["payments"])
async def get_payment_status(transaction_id: str):
    """
    Retrieve the status of a payment transaction by ID.
    Returns full transaction details including status, amount, and timestamps.
    """
    payment = MOCK_PAYMENTS.get(transaction_id.upper())

    if not payment:
        PAYMENT_STATUS_COUNTER.labels(status="not_found").inc()
        logger.warning(f"transaction_id={transaction_id} result=not_found")
        raise HTTPException(
            status_code=404,
            detail=f"Transaction {transaction_id} not found"
        )

    PAYMENT_STATUS_COUNTER.labels(status=payment["status"].value).inc()
    logger.info(f"transaction_id={transaction_id} status={payment['status'].value}")

    now = datetime.now(timezone.utc).isoformat()
    return PaymentResponse(
        transaction_id=transaction_id.upper(),
        status=payment["status"],
        amount=payment["amount"],
        currency="NGN",
        created_at=now,
        updated_at=now,
        message=f"Payment is {payment['status'].value.lower()}"
    )

@app.get("/api/v1/payments", tags=["payments"])
async def list_payments():
    """List all available transaction IDs (demo endpoint)."""
    return {"transaction_ids": list(MOCK_PAYMENTS.keys()), "count": len(MOCK_PAYMENTS)}
