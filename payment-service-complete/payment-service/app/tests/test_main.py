"""
Integration tests for the Payment Status Microservice.
Run with: pytest app/tests/ -v
These run inside the Jenkins pipeline at the test stage.
"""

import pytest
from fastapi.testclient import TestClient
from main import app

client = TestClient(app)


# ── Health probe tests ────────────────────────────────────────────────────────

def test_liveness_probe():
    """Kubernetes liveness probe must return 200 and status=ok."""
    r = client.get("/healthz")
    assert r.status_code == 200
    body = r.json()
    assert body["status"] == "ok"
    assert "timestamp" in body

def test_readiness_probe():
    """Kubernetes readiness probe must return 200 and status=ready."""
    r = client.get("/readyz")
    assert r.status_code == 200
    assert r.json()["status"] == "ready"

def test_metrics_endpoint():
    """Prometheus /metrics endpoint must return 200 with text/plain content."""
    r = client.get("/metrics")
    assert r.status_code == 200
    assert "text/plain" in r.headers["content-type"]
    assert "payment_requests_total" in r.text


# ── Payment API tests ─────────────────────────────────────────────────────────

def test_get_completed_payment():
    """TXN-001 should return COMPLETED status."""
    r = client.get("/api/v1/payments/TXN-001")
    assert r.status_code == 200
    body = r.json()
    assert body["transaction_id"] == "TXN-001"
    assert body["status"] == "COMPLETED"
    assert body["currency"] == "NGN"
    assert body["amount"] == 50000.00

def test_get_pending_payment():
    r = client.get("/api/v1/payments/TXN-002")
    assert r.status_code == 200
    assert r.json()["status"] == "PENDING"

def test_get_failed_payment():
    r = client.get("/api/v1/payments/TXN-003")
    assert r.status_code == 200
    assert r.json()["status"] == "FAILED"

def test_transaction_id_case_insensitive():
    """Transaction IDs should be case-insensitive."""
    r = client.get("/api/v1/payments/txn-001")
    assert r.status_code == 200
    assert r.json()["transaction_id"] == "TXN-001"

def test_not_found_returns_404():
    """Unknown transaction IDs must return 404."""
    r = client.get("/api/v1/payments/TXN-UNKNOWN")
    assert r.status_code == 404
    assert "not found" in r.json()["detail"].lower()

def test_list_payments():
    """List endpoint returns all transaction IDs."""
    r = client.get("/api/v1/payments")
    assert r.status_code == 200
    body = r.json()
    assert "transaction_ids" in body
    assert body["count"] == 5
    assert "TXN-001" in body["transaction_ids"]
