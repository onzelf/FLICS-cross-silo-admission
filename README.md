# FLICS-cross-silo-admission

Reference prototype for the FLICS submission on **session-scoped admission control** for **cross-silo federated learning (FL)**.  
The prototype implements an **admission gateway** at the **session interface boundary** using (i) **signed session capability tokens**, (ii) **request-bound proof-of-possession (PoP)**, and (iii) **structured decision evidence** (ALLOW/DENY + reason) emitted per request.

> Provenance: the implementation is extracted from a broader federated-computing testbed. Some internal folder names may still reflect that origin; this README presents an FL-native view and provides a terminology mapping.

---

## What this PoC demonstrates

**Problem:** In cross-silo FL, deployments often fail on a practical gap: *portable, auditable authorization for session-scoped operations across organizational boundaries*.

**Demonstration:** A session admission layer that:
- treats the FL **session interface** as an enforcement boundary (canonical caller: **coordinator**),
- checks each operation request via **stateless verification** (token validity + PoP binding + capability match),
- emits **structured evidence** for both allowed and denied requests,
- persists run artifacts and optionally model checkpoints in an artifact store, accessible only under appropriate session capabilities.

---

## Architecture

- **Figure 1 (end-to-end):** session admission layer in front of the FL workflow  
- **Figure 2 (zoom):** setup/issuance (stateful) vs runtime admission (stateless per request)

Place figures in `docs/figures/` (or link them here once committed).

---

## Session interface and operations

This prototype models a session interface with **session-scoped operations** (examples):
- `start_session` / `join_session` / `end_session` (administrator-controlled)
- `submit_update` (client update submission)
- `evaluate`
- `fetch_model` (gated access to model artifacts)

In the code and tests, each HTTP/RPC endpoint is mapped to an abstract **operation** that is matched against the session capability token.

---

## Threat model (in one paragraph)

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

## Quickstart (reproducible E2E tests)

This PoC is intended to be runnable end-to-end with scripted tests that exercise:

1. **ALLOW** (valid token + valid PoP + permitted operation)  
2. **DENY: capability mismatch** (operation not in capability set)  
3. **DENY: PoP mismatch** (signature/key mismatch or stale proof)  
4. **DENY: session mismatch** (token session ≠ request session)

The tests print the decision and point to the emitted evidence record.

> Add the exact commands once the refactor is finalized (scripts typically live in `tests/` or `flics/scripts/`).

---

## Performance sanity check (microbench)

FLICS reviewers commonly ask for overhead. The prototype includes a microbench that measures:
- token signature verification latency
- PoP verification latency
- capability match latency
- full admission check latency (token + PoP + match)

Include system configuration in the report (CPU, RAM, OS, Docker).

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

This is a research prototype provided for reproducibility of the associated FLICS submission. It is not a production security product.
``
::contentReference[oaicite:0]{index=0}

