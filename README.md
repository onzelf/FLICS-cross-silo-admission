

# 🔐 FLICS-cross-silo-admission
## PoC — Reference prototype on session-scoped admission control for cross-silo federated learning (FL).  

[![Docker](https://img.shields.io/badge/Docker-Required-2496ED?logo=docker&logoColor=white)](https://www.docker.com/)
[![OpenTofu](https://img.shields.io/badge/OpenTofu-Compatible-844FBA?logo=terraform&logoColor=white)](https://opentofu.org/)
[![Python](https://img.shields.io/badge/Python-3.x-3776AB?logo=python&logoColor=white)](https://www.python.org/)

---
## 📋 Overview
The prototype implements an **admission gateway** at the **session interface boundary** using (i) **signed session capability tokens**, (ii) **request-bound proof-of-possession (PoP)**, and (iii) **structured decision evidence** (ALLOW/DENY + reason) emitted per request.

> Provenance: the implementation is extracted from a broader federated-computing testbed. this README presents an FL-native view and provides a terminology mapping.

---

## What this PoC demonstrates

**Problem:** In cross-silo FL, deployments often fail on a practical gap: *portable, auditable authorization for session-scoped operations across organizational boundaries*.

**Demonstration:** A session admission layer that:
- treats the FL **session interface** as an enforcement boundary (canonical caller: **coordinator**),
- checks each operation request via **stateless verification** (token validity + PoP binding + capability match),
- emits **structured evidence** for both allowed and denied requests,
- persists run artifacts and optionally model checkpoints in an artifact store, accessible only under appropriate session capabilities.

---

## Session interface and operations

This prototype models a session interface with **session-scoped operations** (examples):
- `start_session` / `join_session` / `end_session` (administrator-controlled)
- `submit_update` (client update submission)
- `evaluate`
- `fetch_model` (gated access to model artifacts)

In the code and tests, each HTTP/RPC endpoint is mapped to an abstract **operation** that is matched against the session capability token.

## Repository layout (high level)

- `vfp-governance/`
  - `verifier/` — admission verification, decision records, evidence plumbing
  - `issuer-*` — per-org token issuance + per-org member registries
  - `signer/` — holder-side signing service (PoC) for DPoP generation
- `vfp-core/`
  - `frontend/` — lightweight UI for mint + predict + negative tests
  - `hub/` — FL workflow façade (predict path), calls admission + routes to model artifacts
- `src/tests/` — end-to-end scripts (mint + predict + denial cases), evidence outputs

## Architecture summary

This PoC uses **two organizations** (HospitalA, HospitalB) to model a cross-silo setting:

- Each organization has its own **Issuer**:
  - authoritative for the organization’s **member registry** (public keys) and **SCT issuance**.
- A shared **Admission Gateway** verifies SCT + DPoP at runtime and emits decision evidence.
- A shared **Hub** exposes a session-interface endpoint (`/predict`) and routes through admission.
- A shared **Artifact/Evidence store** contains:
  - issuance artifacts (as produced during setup), and
  - admission decision records for both ALLOW and DENY outcomes.


## 🚀 Getting Started

### Prerequisites

Before you begin, ensure you have:

- ✅ **Docker Engine** installed
- ✅ **OpenTofu** (or Terraform) installed
- ✅ **Python 3** (for helper scripts used by Test #2)
- ✅ Your **local machine** shall resolve `verifier.local` in `/etc/hosts`	

### Generating cerificates

```bash
cd tests
./make_certs.sh
```
The following pairs will be generated:  
```
vfp-governance/verifier/certs/<name>.crt
vfp-governance/verifier/certs/<name>.key
<name> = [ca, HospitalA, HospitalB, hub, issuer-proxy, verifier]
```

### Build + Provision

From repo root:

```bash
cd infra/tofu
tofu init
tofu apply -auto-approve
```

This starts the docker network and containers (nginx proxy, verifier-app, redis, hub, flower components).

## Out-of-the-box issuance + admission

This PoC follows the principle that *the principal is cryptographic*: the admission gateway authorizes requests based on signed artifacts and registered holder keys, not on UI usernames.

### Session binding + capability model

- **Session binding:** each Session Capability Token (SCT) is minted for a specific `session_id` and is only valid for requests targeting that session.
- **Operation capability set:** each SCT carries an explicit set of allowed session-interface operations (e.g., `fetch_model`, `submit_update`, `evaluate`, lifecycle ops). Requests are admitted only if the requested operation is included and constraints are satisfied.

### Proof-of-possession (PoP) verification uses the registered holder key

At admission time, PoP verification is performed against the **registered public key** of the token subject:

1. The admission gateway parses the SCT subject (`sub`).
2. The gateway looks up `sub` in the member registry and retrieves `pub_b64`.
3. The gateway reconstructs the verification key (e.g., `VerifyKey(pub_raw)`).
4. The gateway verifies the PoP signature over the request binding.
5. Capability matching is evaluated only after PoP verification succeeds.

This keeps the principal purely cryptographic: authorization is derived from signed artifacts and registered keys, not from UI-provided usernames.

---

## Reviewer quickstart  

### 1) Generate member keys
```bash
cd tools
python gen_member_keys.py --org org://HospitalA --who Audrey
python gen_member_keys.py --org org://HospitalB --who Bob
```
## 🧪 Test #1 — Envelope creation (KYO) + operational trigger (Flower training)

### Step 1: Start verification session (KYO)

Admins initiate `/verify-start` and receives a 6-digit code using the command

``` bash
cd tools
./simulatePhone.sh
```

### Step 2: Claim session (Hub)
```bash
cd tests
./Test1A_createEnvelope.sh
```
### Step 3: Run the post-envelope script
```
./Test1B_postEnvelope.sh <envelope_id>
<envelope_id> is the ACTIVE envelope
```
## 🧪 Test #2 — Trust chain admission: ECT + DPoP (/admission/check) 
### Run the trust chain script
```bash
./Test2A_run_probe_eddsa_nginx.sh
```
## 🧪  Test #3 — Surrogation of MNIST  for “clinical imaging” prediction with Session admission

 Test #3 extends the PoC from “admission only” (Test #2) to **admission + guarded inference**. MNIST digits are treated as a stand-in for **clinical imaging resources (PET-CT)**, and cohorts (`EVEN_ONLY`, `ODD_ONLY`, `ODD_PLUS`) act like regulated “patient groups / study strata” to demonstrate scope enforcement.

### Test3A — Admission probes 
Goal: validate that **capability minting + `/admission/check`** behaves correctly for prediction requests,
```bash
python ./Test3A_run_probe_mnist.sh
```
### Test3B — Prediction via Hub with ECT/DPoP 
```bash
python ./Test3B_run_predict_via_hub.sh
```
### Test3C — Admission control smoke test
```bash
python ./Test3C_admission_pop,sh
```



Goal: validate that prediction requests traverse the intended boundary:
---

## Threat model

Bearer tokens are vulnerable to replay if stolen. This PoC makes token theft insufficient by requiring each request to include a **PoP signature** over a canonical representation of the request (including operation + session identifier + freshness). The admission gateway rejects requests when:
- the capability token does not permit the requested operation (capability mismatch),
- the PoP does not validate or is bound to a different key (possession mismatch),
- the session identifier does not match (session mismatch),
- the request is stale or replayed (optional nonce / bounded replay cache).

---

## Evidence and artifacts

Two evidence streams are produced:

1. **Issuance evidence** (setup/issuance): approvals, mint events, session constraints  
2. **Decision evidence** (runtime admission): per-request ALLOW/DENY, reason codes, hashes, session/run metadata

Artifacts typically include:
- `run.json` / metrics
- optional model checkpoints
- evidence logs (issuance + decisions)

--- 
## Performance sanity check (microbench)

1. **ALLOW** (valid token + valid PoP + permitted operation)  
2. **DENY: capability mismatch** (operation not in capability set)  
3. **DENY: PoP mismatch** (signature/key mismatch or stale proof)  
4. **DENY: session mismatch** (token session ≠ request session)

### Conference paper's Table II generation
the three columns in  Table II described in Section VI for  the paper "Auditable Session Adnission for Cross-Silo Federated Learning" can be generated as follows:
```bash
cd tests/microbench
./Bench_admission.sh 
COHORT_REQ="ODD_PLUS"   ./Bench_admission.sh 
DPOP_FAIL=true          ./Bench_admission.sh 
```




---

## Terminology mapping (origin → FL-facing)

| Origin term (code paths) | FL-facing term (paper/README) |
|---|---|
| `envelope_id` | `session_id` |
| `issuer` | org token issuer / authorization service |
| `ECT` | session capability token |
| `DPoP` | request-bound proof-of-possession (PoP) |
| `verifier` | admission gateway / verifier |
| `hub` | coordinator boundary (canonical caller) |

---

## Repository layout (high-level)

- `.../flower_server`, `.../flower_client`: FL backend and clients (workflow)
- `.../verifier`: admission gateway (`POST /admission/check`)
- `.../issuers`: org-managed token issuance (`POST /mint/token`)
- `.../vault` or `.../artifact_store`: run artifacts + evidence logs

---

## License and disclaimer
**Apache 2.0**

> This is a research prototype provided for reproducibility of the associated FLICS submission. It is not a production security product.

