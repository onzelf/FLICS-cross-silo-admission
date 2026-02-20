 # backends/flower_server/server.py
# FastAPI (control plane) + Flower server (data plane)
#
# Test #3 scope:
# - Hub binds envelope -> training starts
# - Persist artifact to VAULT_ROOT/<envelope_id>/run.json
# - No authorization or admission logic in this service

from __future__ import annotations

import json, random
import numpy as np
import os, time, requests, io, base64
import threading
from pathlib import Path
from typing import Any, Dict, Optional, Tuple, List
from uuid import UUID

import flwr as fl
from fastapi import FastAPI, HTTPException, Request
import uvicorn
from flwr.server.strategy import FedAvg
from flwr.common import parameters_to_ndarrays

from pydantic import BaseModel
from torchvision.datasets import MNIST
import torch
import torch.nn as nn
from PIL import Image
import torchvision.transforms as T
 
# ----------------------------
# Configuration
# ----------------------------

NUM_ROUNDS = int(os.environ.get("NUM_ROUNDS", "3"))
MIN_AVAILABLE_CLIENTS = int(os.environ.get("MIN_AVAILABLE_CLIENTS", "2"))
FRACTION_FIT = float(os.environ.get("FRACTION_FIT", "1.0"))
FRACTION_EVALUATE = float(os.environ.get("FRACTION_EVALUATE", "1.0"))

# Simulated enclave boundary (mounted by OpenTofu)
VAULT_ROOT = Path(os.environ.get("VAULT_ROOT", "/vault"))

# Kept for compatibility (not used in Test #3)
VERIFIER_URL = os.environ.get("VERIFIER_URL", "https://verifier-proxy:8443")
VERIFY_TLS = os.environ.get("VERIFY_TLS", "0") == "1"
HUB_CERT: Tuple[str, str] = (
    os.environ.get("HUB_CERT_CRT", "/run/certs/hub.crt"),
    os.environ.get("HUB_CERT_KEY", "/run/certs/hub.key"),
)

HUB_URL = os.environ.get("HUB_URL", "http://fc-hub:8080")

_MNIST = None

def sample_mnist_pil(d: int) -> Image.Image:
    global _MNIST
    if _MNIST is None:
        _MNIST = MNIST("/tmp/mnist", train=False, download=True)
    idx = [i for i, t in enumerate(_MNIST.targets) if int(t) == d]
    if not idx:
        raise HTTPException(500, f"mnist_no_samples_for_digit:{d}")
    img, _ = _MNIST[random.choice(idx)]   # PIL image 28x28
    return img.convert("L")


def register_with_hub():
    payload = {"type": "flower_server", "url": "http://flower-server:8081"}
    for i in range(60):
        try:
            r = requests.post(f"{HUB_URL}/backend/register", json=payload, timeout=5)
            if r.status_code == 200:
                print("[flower-server] registered with hub", flush=True)
                return
            print(f"[flower-server] register HTTP {r.status_code}: {r.text[:200]}", flush=True)
        except Exception as e:
            print(f"[flower-server] hub not ready ({i+1}/60): {e}", flush=True)
        time.sleep(1)
    raise RuntimeError("could not register with hub")

# ----------------------------
# State (workflow)
# ----------------------------

app = FastAPI()

envelope_config: Optional[Dict[str, Any]] = None
envelope_bound = threading.Event()  # set when Hub binds the envelope

training_metrics: Dict[str, Any] = {
    "rounds": 0,
    "loss": None,
    "accuracy": None,
    "started_at": None,
    "ended_at": None,
    "status": "idle",  # idle | bound | training | done | failed
    "error": None,
}


def now() -> str:
    return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime())


def persist_run_artifact(envelope_id: str, payload: Dict[str, Any]) -> Path:
    outdir = VAULT_ROOT / envelope_id
    outdir.mkdir(parents=True, exist_ok=True)
    path = outdir / "run.json"
    path.write_text(json.dumps(payload, indent=2, sort_keys=True))
    print(f"[flower_server:{now()}] persisted artifact: {path}", flush=True)
    return path


COHORT_TO_DIGITS = {
    "EVEN_ONLY": [0,2,4,6,8],
    "ODD_ONLY":  [1,3,5,7,9],
    "ODD_PLUS":  [1,5,7,0,2],
}

#
# Prediction support
class PredictReq(BaseModel):
    envelope_id: UUID
    cohort: str
    digit: Optional[int] = None
    image_b64: Optional[str] = None
    topk: Optional[int] = 3

_transform = T.Compose([
    T.Grayscale(num_output_channels=1),
    T.Resize((28, 28)),
    T.ToTensor(),
    # MNIST normalization if your training used it:
    #T.Normalize((0.1307,), (0.3081,))
])


def persist_model_state(envelope_id: str, ndarrays: List[np.ndarray]) -> str:
    outdir = VAULT_ROOT / envelope_id
    outdir.mkdir(parents=True, exist_ok=True)
    path = outdir / "model.pth"

    model = Net()
    with torch.no_grad():
        for p, arr in zip(model.parameters(), ndarrays):
            p.copy_(torch.tensor(arr).reshape_as(p))

    torch.save(model.state_dict(), path)
    print(f"[flower_server:{now()}] persisted model: {path}", flush=True)
    return str(path)


def load_model(envelope_id: str):
    model_path = f"/vault/{envelope_id}/model.pth"
    print(f"[load_model] envelope_id={envelope_id!r} path={model_path}")

    if not os.path.exists(model_path):
        raise HTTPException(409, "model_not_ready")

    model = Net()
    state = torch.load(model_path, map_location="cpu")
    model.load_state_dict(state, strict=True)
    model.eval()
    return model



def mask_logits(logits: torch.Tensor, allowed: List[int]) -> torch.Tensor:
    # logits: [1,10]
    mask = torch.full_like(logits, float("-inf"))
    for d in allowed:
        if 0 <= d <= 9:
            mask[0, d] = 0.0
    return logits + mask



#
#-- Net definition
class Net(nn.Module):
    def __init__(self):
        super().__init__()
        self.seq = nn.Sequential(
            nn.Conv2d(1, 32, 3, 1), nn.ReLU(), nn.MaxPool2d(2),
            nn.Conv2d(32, 64, 3, 1), nn.ReLU(), nn.MaxPool2d(2),
            nn.Flatten(), nn.Linear(1600, 128), nn.ReLU(),
            nn.Linear(128, 10)
        )
    def forward(self, x):
        return self.seq(x)


# ----------------------------
# Flower strategy (captures metrics)
# ----------------------------

class MetricsFedAvg(FedAvg):
    def aggregate_fit(self, server_round, results, failures):
        agg_params, agg_metrics = super().aggregate_fit(server_round, results, failures)

        # Persist final model at the end of training
        try:
            if agg_params is not None and envelope_config is not None:
                if int(server_round) == int(NUM_ROUNDS):
                    nds = parameters_to_ndarrays(agg_params)
                    persist_model_state(envelope_config["envelope_id"], nds)
        except Exception as e:
            print(f"[flower_server:{now()}] WARN: model persist failed: {e}", flush=True)

        return agg_params, agg_metrics 
    
    def aggregate_evaluate(self, server_round, results, failures):
        # This hook runs after evaluation aggregation each round (if clients evaluate).
        # We record whatever we can as "run evidence" for Test #3.
        try:
            # flwr returns list of (client_proxy, EvaluateRes)
            if results:
                losses = [float(res.loss) for _, res in results if res and res.loss is not None]
                accs = []
                for _, res in results:
                    if res and res.metrics and "accuracy" in res.metrics:
                        try:
                            accs.append(float(res.metrics["accuracy"]))
                        except Exception:
                            pass

                avg_loss = sum(losses) / max(1, len(losses)) if losses else None
                avg_acc = sum(accs) / max(1, len(accs)) if accs else None

                training_metrics["rounds"] = int(server_round)
                if avg_loss is not None:
                    training_metrics["loss"] = float(avg_loss)
                if avg_acc is not None:
                    training_metrics["accuracy"] = float(avg_acc)

                if avg_loss is not None and avg_acc is not None:
                    print(
                        f"[flower_server] Round {server_round}: loss={avg_loss:.4f}, accuracy={avg_acc:.4f}",
                        flush=True,
                    )
                elif avg_loss is not None:
                    print(
                        f"[flower_server] Round {server_round}: loss={avg_loss:.4f}",
                        flush=True,
                    )

        except Exception as e:
            print(f"[flower_server:{now()}] WARN: metrics aggregation failed: {e}", flush=True)

        return super().aggregate_evaluate(server_round, results, failures)


# ----------------------------
# FastAPI endpoints (control plane)
# ----------------------------

@app.get("/status")
async def status():
    if envelope_config is None:
        return {
            "status": "waiting_for_binding",
            "envelope_id": None,
            "training": training_metrics,
        }

    return {
        "status": envelope_config.get("status", "bound"),
        "envelope_id": envelope_config.get("envelope_id"),
        "bound": envelope_bound.is_set(),
        "training": training_metrics,
    }


@app.post("/bind_envelope")
async def bind_envelope(req: Request):
    """
    Workflow hook called by Hub once the envelope is ACTIVE (quorum complete).
    this is the only trigger condition: bind => start training.
    """
    global envelope_config

    data = await req.json()
    envelope_id = data.get("envelope_id")
    if not envelope_id:
        raise HTTPException(400, "missing envelope_id")

    if envelope_config is not None:
        raise HTTPException(409, f"already bound to {envelope_config.get('envelope_id')}")

    envelope_config = {
        "envelope_id": envelope_id,
        "policy_hash": data.get("policy_hash"),
        "scope": data.get("scope", {}),
        "status": "bound",
        "bound_at": int(time.time()),
    }

    training_metrics["status"] = "bound"
    training_metrics["error"] = None

    envelope_bound.set()

    print(f"[flower_server:{now()}] Envelope bound: {envelope_id}. Training will start.", flush=True)
    return {"bound": True, "envelope_id": envelope_id, "status": "bound"}


@app.post("/predict_image")
async def predict_image(req: PredictReq):

    print(f"[predict_image] envelope_id={req.envelope_id!r} cohort={req.cohort!r} digit={req.digit!r}")

    # ---- cohort → allowed digits (procedural constraint) ----
    allowed = COHORT_TO_DIGITS.get(req.cohort)
    if not allowed:
        raise HTTPException(400, f"unknown_cohort:{req.cohort}")

    # ---- choose image source: digit (preferred) OR image_b64 (fallback) ----
    img: Image.Image

    if req.digit is not None:
        d = int(req.digit)
        if d < 0 or d > 9:
            raise HTTPException(400, f"bad_digit:{d}")

        # "Fail immediately" if digit is not allowed for the cohort
        if d not in allowed:
            raise HTTPException(403, "digit_not_allowed_by_cohort")

        # Sample a random MNIST image for that digit (backend-controlled)
        img = sample_mnist_pil(d)  # returns PIL.Image in "L"

    elif req.image_b64:
        raw = base64.b64decode(req.image_b64)
        img = Image.open(io.BytesIO(raw)).convert("L")

    else:
        raise HTTPException(400, "need_digit_or_image_b64")

    # ---- load model (persisted under /vault/<envelope_id>/...) ----
    model = load_model(req.envelope_id)

    # ---- preprocess and infer ----
    x = _transform(img).unsqueeze(0)  # [1,1,28,28]

    with torch.no_grad():
        logits = model(x)
        logits = mask_logits(logits, allowed)          # enforce cohort on outputs
        probs = torch.softmax(logits, dim=-1)[0]       # [10]

    topk = max(1, min(int(req.topk or 3), 10))
    vals, idxs = torch.topk(probs, k=topk)

    buf = io.BytesIO()
    img.save(buf, format="PNG")
    image_png_b64 = base64.b64encode(buf.getvalue()).decode("ascii")

    return {
        "prediction": int(idxs[0].item()),
        "topk": [{"digit": int(i.item()), "prob": float(v.item())} for v, i in zip(vals, idxs)],
        "allowed_digits": allowed,
        "image_png_b64": image_png_b64,
        "requested_digit": int(req.digit) if req.digit is not None else None,
    }



def start_fastapi():
    uvicorn.run(app, host="0.0.0.0", port=8081, log_level="info")


# ----------------------------
# Main (data plane)
# ----------------------------

if __name__ == "__main__":
    print(f"[flower_server:{now()}] Starting up...", flush=True)

    # Start control-plane API
    fastapi_thread = threading.Thread(target=start_fastapi, daemon=True)
    fastapi_thread.start()

    # Register backend with Hub 
    register_with_hub()

    print("[flower_server] Waiting for Hub binding...", flush=True)
    envelope_bound.wait()

    assert envelope_config is not None
    envelope_id = envelope_config["envelope_id"]

    # Start Flower training
    try:
        training_metrics["started_at"] = time.time()
        training_metrics["status"] = "training"

        strategy = MetricsFedAvg(
            fraction_fit=FRACTION_FIT,
            fraction_evaluate=FRACTION_EVALUATE,
            min_available_clients=MIN_AVAILABLE_CLIENTS,
        )

        print(
            f"[flower_server:{now()}] Starting Flower gRPC server on 0.0.0.0:8080 "
            f"(rounds={NUM_ROUNDS}, min_clients={MIN_AVAILABLE_CLIENTS})",
            flush=True,
        )

        fl.server.start_server(
            server_address="0.0.0.0:8080",
            config=fl.server.ServerConfig(num_rounds=NUM_ROUNDS),
            strategy=strategy,
        )

        training_metrics["ended_at"] = time.time()
        training_metrics["status"] = "done"

        print(f"[flower_server:{now()}] Training completed", flush=True)

        # Persist run evidence to vault/<envelope_id>/run.json
        persist_run_artifact(envelope_id, {
            "envelope_id": envelope_id,
            "policy_hash": envelope_config.get("policy_hash"),
            "scope": envelope_config.get("scope", {}),
            "num_rounds": NUM_ROUNDS,
            "min_available_clients": MIN_AVAILABLE_CLIENTS,
            "fraction_fit": FRACTION_FIT,
            "fraction_evaluate": FRACTION_EVALUATE,
            "training": training_metrics,
        })

    except Exception as ex:
        training_metrics["ended_at"] = time.time()
        training_metrics["status"] = "failed"
        training_metrics["error"] = str(ex)

        print(f"[flower_server:{now()}] FATAL ERROR in Flower: {ex}", flush=True)

        # Persist failure evidence too (useful in PoC)
        try:
            persist_run_artifact(envelope_id, {
                "envelope_id": envelope_id,
                "status": "failed",
                "error": str(ex),
                "training": training_metrics,
            })
        except Exception as persist_ex:
            print(f"[flower_server:{now()}] WARN: could not persist failure artifact: {persist_ex}", flush=True)

        raise

    # Keep process alive after training for observability (status endpoint)
    threading.Event().wait()
