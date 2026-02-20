# hub/hub.py - Hub as coordination orchestrator
from fastapi import FastAPI, Request, HTTPException, Header
import redis.asyncio as redis
import asyncio
import json
import os
import requests
import uvicorn
import time
from pydantic import BaseModel, Field
from typing import Optional
 

app = FastAPI()

REDIS_URL = os.environ.get("REDIS_URL", "redis://redis:6379")

# Registry of available backends
BACKEND_REGISTRY = {}  # backend_type -> {"url": str, "registered_at": int}
 

redis_client = None

async def get_redis():
    global redis_client
    if redis_client is None:
        redis_client = await redis.from_url(REDIS_URL, decode_responses=True)
        await redis_client.ping()
    return redis_client

@app.on_event("startup")
async def startup():
    """Start listening to envelope  creation events"""
    asyncio.create_task(subscribe_to_envelope_events())

@app.get("/status")
async def status():
    """Hub health check"""
    r = await get_redis()
    ping = await r.ping()
    return {
        "hub": "ok",
        "redis": ping,
        "registered_backends": list(BACKEND_REGISTRY.keys())
    }

@app.post("/backend/register")
async def register_backend(req: Request):
    """Backends register themselves with the Hub"""
    d = await req.json()
    backend_type = d.get("type")
    backend_url = d.get("url")
    
    if not backend_type or not backend_url:
        raise HTTPException(400, "missing type or url")
    
    BACKEND_REGISTRY[backend_type] = {
        "url": backend_url,
        "registered_at": int(time.time())
    }
    
    print(f"[hub] Registered backend: {backend_type} at {backend_url}", flush=True)
    
    return {"registered": True, "backend_type": backend_type}

@app.get("/backend/list")
async def list_backends():
    """List all registered backends"""
    return {"backends": BACKEND_REGISTRY}

async def subscribe_to_envelope_events():
    """Subscribe to envelope creation events from verifier"""
    r = await get_redis()
    pubsub = r.pubsub()
    await pubsub.subscribe("fcac:envelopes:created")
    print(f"[hub] Subscribed to envelope creation events", flush=True)
    
    '''
    async for message in pubsub.listen():
        if message["type"] == "message":
            envelope = json.loads(message["data"])
            await handle_envelope_created(envelope)
    '''
    try:
        while True:
            msg = await pubsub.get_message(ignore_subscribe_messages=True, timeout=1.0)
            if msg is None:
                await asyncio.sleep(0.05)
                continue

            # With decode_responses=True, msg["data"] is str.
            envelope = json.loads(msg["data"])
            await handle_envelope_created(envelope)
    finally:
        try:
            await pubsub.unsubscribe("fcac:envelopes:created")
            await pubsub.close()
        except Exception:
            pass


class PredictReq(BaseModel):
    envelope_id: str
    cohort: str
    digit: int = Field(ge=0, le=9)
    topk: Optional[int] = 3
    jti: str

@app.post("/predict")
def predict(
    req: PredictReq,
    authorization: str = Header(..., alias="Authorization"),
    dpop: str = Header(..., alias="DPoP"),
    dpop_nonce: str = Header(..., alias="X-DPoP-Nonce"),
):
    # 1) constitutional tuple for admission (policy match)
    manifest = {
        "resource": "PET-CT",
        "action": "read",
        "purpose": "model_prediction",
        "cohort": req.cohort,
        "jti": req.jti,
    }

    verifier_base = os.getenv("VERIFIER_URL", "https://verifier.local:8443").rstrip("/")
    verifier_check = verifier_base + "/admission/check"

    ca_crt  = os.getenv("FCAC_CA_CRT",  "/run/certs/ca.crt")
    hub_crt = os.getenv("FCAC_HUB_CRT", "/run/certs/hub.crt")
    hub_key = os.getenv("FCAC_HUB_KEY", "/run/certs/hub.key")

    try:
        vr = requests.post(
            verifier_check,
            headers={
                "Authorization": authorization,  # "ECT <jws>"
                "DPoP": dpop,
                "X-DPoP-Nonce": dpop_nonce,
                "Content-Type": "application/json",
            },
            json=manifest,
            timeout=15,
            verify=ca_crt,
            cert=(hub_crt, hub_key),
        )
        probe = vr.json()
    except Exception as e:
        raise HTTPException(502, f"verifier_error:{e}")

    if not probe.get("allow", False):
        return {"admission": probe, "executed": False}

    # 2) forward to federated service (internal-only)
    flower_base = os.getenv("FLOWER_URL", "http://flower-server:8081").rstrip("/")
    pr = requests.post(
        flower_base + "/predict_image",
        json={
            "envelope_id": req.envelope_id,
            "cohort": req.cohort,
            "digit": req.digit,
            "topk": req.topk,
        },
        timeout=30,
    )
    return {"admission": probe, "executed": True, "prediction": pr.json()}



async def handle_envelope_created(envelope: dict):
    """
    Hub receives envelope creation event and coordinates backend assignment.
    This is where user intent (backend type) is read and acted upon.
    """
    envelope_id = envelope["envelope_id"]
    scope = envelope.get("scope", {})
    
    # User's declared intent: which backend should serve this envelope
    backend_type = scope.get("backend", "flower_server")
    
    print(f"[hub] Envelope {envelope_id} created, needs backend: {backend_type}", flush=True)
    
    # Check if this backend type is registered
    if backend_type not in BACKEND_REGISTRY:
        print(f"[hub] ERROR: Backend {backend_type} not registered", flush=True)
        # Log failure event
        return
    
    # Coordinate with the registered backend
    backend_info = BACKEND_REGISTRY[backend_type]
    backend_url = backend_info["url"]
    
    try:
        # Hub directly instructs backend to bind to this envelope
        resp = requests.post(
            f"{backend_url}/bind_envelope",
            json={
                "envelope_id": envelope_id,
                "allowed_ops": envelope["allowed_ops"],
                "policy_hash": envelope["policy_hash"],
                "valid_until": envelope["valid_until"],
                "scope": scope
            },
            timeout=10
        )
        resp.raise_for_status()
        
        print(f"[hub] Successfully bound {backend_type} to envelope {envelope_id}", flush=True)
        
    except Exception as ex:
        print(f"[hub] ERROR: Failed to bind backend {backend_type}: {ex}", flush=True)

if __name__ == "__main__":
    uvicorn.run("hub:app", host="0.0.0.0", port=8080)