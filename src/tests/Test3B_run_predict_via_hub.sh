#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Test #3B — Prediction via Hub /predict (ECT+DPoP)
#
# Post-Test#4 update:
#   - ECT minting is performed by issuer containers (org-admin credentials)
#   - Hub performs /admission/check (mTLS) then forwards internally to flower-server
#
# Usage:
#   ./Test3B_run_predict_via_hub.sh <envelope_id>
# ============================================================

ENVELOPE_ID="${1:-}"
if [[ -z "$ENVELOPE_ID" ]]; then
  echo "Usage: $0 <envelope_id>" >&2
  exit 1
fi

# -------- Config --------
HUB_URL="${HUB_URL:-http://127.0.0.1:8080}"
FLOWER_URL="${FLOWER_URL:-http://flower-server:8081}"   # internal from hub

ISSUER_A_CONTAINER=${ISSUER_A_CONTAINER:-issuer-hospitala}
ISSUER_B_CONTAINER=${ISSUER_B_CONTAINER:-issuer-hospitalb}

# DPoP HTU must match verifier expectation 
HTU="${HTU:-https://verifier.local/admission/check}"

HOLDER="${HOLDER:-Audrey}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 1; }; }
need jq
need python3
need curl
need docker

mint_ect_via_issuer() {
  local issuer_container="$1"
  local sub="$2"
  local cohort="$3"

docker exec -i "${issuer_container}" python3 - <<PY
import json
import requests
payload = {"sub": "${sub}", "cohort": "${cohort}"}
r = requests.post("http://127.0.0.1:8080/mint", json=payload, timeout=20)
print(json.dumps({"status": r.status_code, "body": r.json() if r.headers.get('content-type','').startswith('application/json') else r.text}))
PY
}

extract_ect() {
  jq -r '.body.ect // .body.ect_jws // empty'
}

make_dpop() {
  local priv_hex="$1"
  local pub_b64="$2"
  local nonce="$3"
  local jti="$4"
  python3 ../tools/make_dpop_jwt_eddsa.py "${priv_hex}" "${pub_b64}" "${nonce}" "${jti}" "POST" "${HTU}"
}

call_hub_predict() {
  local cohort="$1"
  local digit="$2"
  local jti="$3"
  local topk="$4"
  local ect="$5"
  local dpop="$6"
  local nonce="$7"

  echo "== HUB /predict (cohort=${cohort} digit=${digit}) =="
  curl -sS "${HUB_URL}/predict" \
    -H "Content-Type: application/json" \
    -H "Authorization: ECT ${ect}" \
    -H "DPoP: ${dpop}" \
    -H "X-DPoP-Nonce: ${nonce}" \
    -d '{
      "envelope_id": "'"${ENVELOPE_ID}"'",
      "cohort": "'"${cohort}"'",
      "digit": '"${digit}"',
      "jti": "'"${jti}"'",
      "topk": '"${topk}"'
    }' | jq .
  echo
}

echo "== 0) (Optional) register flower backend in Hub =="
curl -sS -X POST "http://127.0.0.1:8080/backend/register" \
  -H "Content-Type: application/json" \
  -d '{"type":"flower","url":"http://flower-server:8081"}' | jq .


echo ""
echo "EVEN_ONLY:= [0,2,4,6,8]"
echo "ODD_ONLY:=  [1,3,5,7,9]"
echo "ODD_PLUS:=  [1,5,7,0,2]"

echo "== 1) Enrol holder keys =="
python3 ../tools/gen_member_keys.py --org org://HospitalA --who Audrey | sed 's/^/[keys] /' || true
PUB_B64_A=$(cat holder_keys/Audrey.pubb64)
PRIV_HEX_A=$(cat holder_keys/Audrey.privhex)
JKT_A=$(cat holder_keys/Audrey.jkt)

curl -vk \
  --resolve issuer-hospitala.local:9443:192.168.1.25 \
  --cacert ../vfp-governance/verifier/certs/ca.crt \
  --cert  ../vfp-governance/verifier/certs/HospitalA-admin.crt \
  --key   ../vfp-governance/verifier/certs/HospitalA-admin.key \
  -H "Content-Type: application/json" \
  --data "{\"org_id\":\"org://HospitalA\",\"member_id\":\"Audrey\",\"sub\":\"Audrey\",\"pub_b64\":\"$PUB_B64_A\",  \"jkt\":\"$JKT_A\"}" \
  https://issuer-hospitala.local:9443/members/register

cp -v holder_keys/Audrey.privhex ../vfp-governance/verifier/vault/holder_keys/ 

# ============================================================
# Scenario A: EVEN_ONLY (issuer-hospitala)
# ============================================================

echo "== 2) Mint ECT (Audrey, EVEN_ONLY) via issuer-hospitala =="
MINT_RAW=$(mint_ect_via_issuer "${ISSUER_A_CONTAINER}" "Audrey" "EVEN_ONLY")
echo "${MINT_RAW}" | jq .
ECT=$(echo "${MINT_RAW}" | extract_ect)
[[ -n "${ECT}" ]] || { echo "ERROR: mint returned no ect"; exit 1; }

NONCE="nonce-a-$(date +%s)"
JTI="jti-a-$(date +%s)"
DPOP="$(make_dpop "${PRIV_HEX_A}" "${PUB_B64_A}" "${NONCE}" "${JTI}")"

call_hub_predict "EVEN_ONLY" 2 "${JTI}" 3 "${ECT}" "${DPOP}" "${NONCE}"     # allow
call_hub_predict "EVEN_ONLY" 3 "${JTI}" 3 "${ECT}" "${DPOP}" "${NONCE}"     # procedural reject
call_hub_predict "ODD_ONLY"  3 "${JTI}" 3 "${ECT}" "${DPOP}" "${NONCE}"     # admission deny

# ============================================================
# Scenario B: ODD_ONLY (issuer-hospitalb)
# ============================================================
python3 ../tools/gen_member_keys.py --org org://HospitalB --who Bob | sed 's/^/[keys] /' || true
PUB_B64_B=$(cat holder_keys/Bob.pubb64)
PRIV_HEX_B=$(cat holder_keys/Bob.privhex)
JKT_B=$(cat holder_keys/Audrey.jkt)

curl -vk \
  --resolve issuer-hospitalb.local:9443:192.168.1.25 \
  --cacert ../vfp-governance/verifier/certs/ca.crt \
  --cert  ../vfp-governance/verifier/certs/HospitalA-admin.crt \
  --key   ../vfp-governance/verifier/certs/HospitalA-admin.key \
  -H "Content-Type: application/json" \
  --data "{\"org_id\":\"org://HospitalB\",\"member_id\":\"Bob\",\"sub\":\"Bob\",\"pub_b64\":\"$PUB_B64_B\", \"jkt\":\"$JKT_B\"}" \
  https://issuer-hospitalb.local:9443/members/register

cp -v holder_keys/Bob.privhex ../vfp-governance/verifier/vault/holder_keys/ 

echo "== 3) Mint ECT (Bob, ODD_ONLY) via issuer-hospitalb =="
MINT_RAW=$(mint_ect_via_issuer "${ISSUER_B_CONTAINER}" "Bob" "ODD_ONLY")
echo "${MINT_RAW}" | jq .
ECT=$(echo "${MINT_RAW}" | extract_ect)
[[ -n "${ECT}" ]] || { echo "ERROR: mint returned no ect"; exit 1; }

NONCE="nonce-b-$(date +%s)"
JTI="jti-b-$(date +%s)"
DPOP="$(make_dpop "${PRIV_HEX_B}" "${PUB_B64_B}" "${NONCE}" "${JTI}")"

call_hub_predict "ODD_ONLY"  3 "${JTI}" 3 "${ECT}" "${DPOP}" "${NONCE}"     # allow
call_hub_predict "EVEN_ONLY" 2 "${JTI}" 3 "${ECT}" "${DPOP}" "${NONCE}"     # admission deny

# ============================================================
# Scenario C: ODD_PLUS (issuer-hospitala)
# ============================================================

echo "== 4) Mint ECT (Audrey, ODD_PLUS) via issuer-hospitala =="
MINT_RAW=$(mint_ect_via_issuer "${ISSUER_A_CONTAINER}" "Audrey" "ODD_PLUS")
echo "${MINT_RAW}" | jq .
ECT=$(echo "${MINT_RAW}" | extract_ect)
[[ -n "${ECT}" ]] || { echo "ERROR: mint returned no ect"; exit 1; }

NONCE="nonce-c-$(date +%s)"
JTI="jti-c-$(date +%s)"
DPOP="$(make_dpop "${PRIV_HEX_A}" "${PUB_B64_A}" "${NONCE}" "${JTI}")"

call_hub_predict "ODD_PLUS"  7 "${JTI}" 3 "${ECT}" "${DPOP}" "${NONCE}"     # allow
call_hub_predict "ODD_PLUS"  4 "${JTI}" 3 "${ECT}" "${DPOP}" "${NONCE}"     # procedural reject

# ============================================================
# Scenario D: cryptographic negative control (tampered ECT)
# ============================================================

echo "== 5) Tamper ECT (signature segment) =="
IFS='.' read -r h p s <<<"${ECT}"
INVALID_ECT="${h}.${p}.${s%?}ELF"

NONCE="nonce-d-$(date +%s)"
JTI="jti-d-$(date +%s)"
DPOP="$(make_dpop "${PRIV_HEX_A}" "${PUB_B64_A}" "${NONCE}" "${JTI}")"
call_hub_predict "ODD_PLUS"  6 "${JTI}" 3 "${INVALID_ECT}" "${DPOP}" "${NONCE}"  # admission deny (sig fail)

echo "Done."
