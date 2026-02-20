#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Test #3A — MNIST (as clinical imaging) admission probes
#
# Post-Test#4 update:
#   - ECT minting is performed by issuer containers (org-admin credentials)
#   - This script keeps probing /admission/check directly (mTLS hub cert)
#
# Cohort→Issuer mapping (PoC convention):
#   - EVEN_ONLY, ODD_PLUS  -> issuer-hospitala
#   - ODD_ONLY             -> issuer-hospitalb
# ============================================================

# -------- Config --------
PORT=${PORT:-8443}
VERIFIER_BASE="https://verifier.local:${PORT}"

CAC="../vfp-governance/verifier/certs/ca.crt"
CRT="../vfp-governance/verifier/certs/hub.crt"
KEY="../vfp-governance/verifier/certs/hub.key"

CURL_MTLS=( -sS --cacert "$CAC" --cert "$CRT" --key "$KEY" )

ISSUER_A_CONTAINER=${ISSUER_A_CONTAINER:-issuer-hospitala}
ISSUER_B_CONTAINER=${ISSUER_B_CONTAINER:-issuer-hospitalb}

# HTU must match verifier expectation (same as Test#2)
HTU="https://verifier.local/admission/check"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 1; }; }
need jq
need python3
need docker

mint_ect_via_issuer() {
  local issuer_container="$1"
  local sub="$2"
  local cohort="$3"

  # Call issuer HTTP endpoint from inside the issuer container (no host port needed).
  docker exec -i "${issuer_container}" python3 - <<PY
import json, sys
import requests
payload = {"sub": "${sub}", "cohort": "${cohort}"}
r = requests.post("http://127.0.0.1:8080/mint", json=payload, timeout=20)
print(json.dumps({"status": r.status_code, "body": r.json() if r.headers.get('content-type','').startswith('application/json') else r.text}))
PY
}

extract_ect() {
  # Accept either {ect:..} (normalized) or {ect_jws:..} (verifier legacy)
  jq -r '.body.ect // .body.ect_jws // empty'
}

# -------- Enroll members holder keys --------
echo "== 1) Register holder keys =="
python3 ../tools/gen_member_keys.py --org org://HospitalA --who Audrey | sed 's/^/[keys] /' || true
PUB_B64_A=$(cat holder_keys/Audrey.pubb64)
PRIV_HEX_A=$(cat holder_keys/Audrey.privhex)
DATA_A=$(jq 'del(.created_at)' holder_keys/Audrey.register.json)
echo $DATA_A

curl -vk \
  --resolve issuer-hospitala.local:9443:192.168.1.25 \
  --cacert ../vfp-governance/verifier/certs/ca.crt \
  --cert  ../vfp-governance/verifier/certs/HospitalA-admin.crt \
  --key   ../vfp-governance/verifier/certs/HospitalA-admin.key \
  -H "Content-Type: application/json" \
  --data "$DATA_A" https://issuer-hospitala.local:9443/members/register

cp -v holder_keys/Audrey.privhex ../vfp-governance/verifier/vault/holder_keys/  

# -------- Wait for /health --------
echo "== 2) Wait for /health =="
for i in {1..30}; do
  sleep 0.3
  echo -n "."

  echo "${CURL_MTLS[@]} --- ${VERIFIER_BASE}/health"
  if curl "${CURL_MTLS[@]}" "${VERIFIER_BASE}/health" ; then break; fi
done
echo

make_dpop() {
  local nonce="$1"
  local jti="$2"
  local pubb64="$3"
  local privhex="$4"
  python3 ../tools/make_dpop_jwt_eddsa.py "${privhex}" "${pubb64}" "${nonce}" "${jti}" "POST" "${HTU}"
}

probe() {
  local ect="$1"
  local dpop="$2"
  local nonce="$3"
  local req_json="$4"

  echo "${req_json}"
  curl "${CURL_MTLS[@]}" -X POST "${VERIFIER_BASE}/admission/check" \
    -H "Authorization: ECT ${ect}" \
    -H "DPoP: ${dpop}" \
    -H "X-DPoP-Nonce: ${nonce}" \
    -H 'content-type: application/json' \
    -d "${req_json}" | jq .
}

# ============================================================
# Scenario S1 — predictor_even (EVEN_ONLY)
# ============================================================
echo
echo "=========================================="
echo "Scenario S1: predictor_even (EVEN_ONLY)"
echo "========================================="

echo "== 3) Mint ECT via issuer-hospitala =="
MINT_RAW=$(mint_ect_via_issuer "${ISSUER_A_CONTAINER}" "Audrey" "EVEN_ONLY")
echo "${MINT_RAW}" | jq .
ECT=$(echo "${MINT_RAW}" | extract_ect)
[[ -n "${ECT}" ]] || { echo "ERROR: mint returned no ect"; exit 1; }

NONCE="test-nonce-$(date +%s)"
JTI="jti-even-$(date +%s)"
DPoP=$(make_dpop "${NONCE}" "${JTI}" "${PUB_B64_A}" "${PRIV_HEX_A}")

echo "== 4) Probe ALLOW (EVEN_ONLY) =="
probe "${ECT}" "${DPoP}" "${NONCE}" '{"resource":"PET-CT","action":"read","purpose":"model_prediction","cohort":"EVEN_ONLY","jti":"'"${JTI}"'"}'

echo
echo "== 5) Probe DENY (ODD_ONLY) =="
probe "${ECT}" "${DPoP}" "${NONCE}" '{"resource":"PET-CT","action":"read","purpose":"model_prediction","cohort":"ODD_ONLY","jti":"'"${JTI}"'"}'

echo
echo "== 6) Probe DENY (ODD_PLUS) =="
probe "${ECT}" "${DPoP}" "${NONCE}" '{"resource":"PET-CT","action":"read","purpose":"model_prediction","cohort":"ODD_PLUS","jti":"'"${JTI}"'"}'

echo
echo "== 7) Probe DENY (wrong purpose=model_training) =="
probe "${ECT}" "${DPoP}" "${NONCE}" '{"resource":"PET-CT","action":"read","purpose":"model_training","cohort":"EVEN_ONLY","jti":"'"${JTI}"'"}'

# ============================================================
# Scenario S2 — predictor_odd (ODD_ONLY)
# ============================================================
echo
echo "====================================="
echo "Scenario S2: predictor_odd (ODD_ONLY)"
echo "====================================="

python3 ../tools/gen_member_keys.py --org org://HospitalB --who Bob | sed 's/^/[keys] /' || true
PUB_B64_B=$(cat holder_keys/Bob.pubb64)
PRIV_HEX_B=$(cat holder_keys/Bob.privhex)
DATA_B=$(jq 'del(.created_at)' holder_keys/Bob.register.json)

curl -vk \
  --resolve issuer-hospitalb.local:9443:192.168.1.25 \
  --cacert ../vfp-governance/verifier/certs/ca.crt \
  --cert  ../vfp-governance/verifier/certs/HospitalA-admin.crt \
  --key   ../vfp-governance/verifier/certs/HospitalA-admin.key \
  -H "Content-Type: application/json" \
  --data "$DATA_B"  \
  https://issuer-hospitalb.local:9443/members/register

# synch with member(s) privhex keys on Signer
cp -v holder_keys/Bob.privhex ../vfp-governance/verifier/vault/holder_keys/

echo "== 8) Mint ECT via issuer-hospitalb =="
MINT_RAW=$(mint_ect_via_issuer "${ISSUER_B_CONTAINER}" "Bob" "ODD_ONLY")
echo "${MINT_RAW}" | jq .
ECT=$(echo "${MINT_RAW}" | extract_ect)
[[ -n "${ECT}" ]] || { echo "ERROR: mint returned no ect"; exit 1; }

NONCE="test-nonce-$(date +%s)"
JTI="jti-odd-$(date +%s)"
DPoP=$(make_dpop "${NONCE}" "${JTI}" "${PUB_B64_B}" "${PRIV_HEX_B}")

echo "== 9) Probe ALLOW (ODD_ONLY) =="
probe "${ECT}" "${DPoP}" "${NONCE}" '{"resource":"PET-CT","action":"read","purpose":"model_prediction","cohort":"ODD_ONLY","jti":"'"${JTI}"'"}'

echo
echo "== 10) Probe DENY (EVEN_ONLY) =="
probe "${ECT}" "${DPoP}" "${NONCE}" '{"resource":"PET-CT","action":"read","purpose":"model_prediction","cohort":"EVEN_ONLY","jti":"'"${JTI}"'"}'

# ============================================================
# Scenario S3 — predictor_odd_plus (ODD_PLUS)
# ============================================================
echo
echo "============================================="
echo "Scenario S3: predictor_odd_plus (ODD_PLUS)"
echo "============================================="

echo "== 11) Mint ECT via issuer-hospitala =="
MINT_RAW=$(mint_ect_via_issuer "${ISSUER_A_CONTAINER}" "Audrey" "ODD_PLUS")
echo "${MINT_RAW}" | jq .
ECT=$(echo "${MINT_RAW}" | extract_ect)
[[ -n "${ECT}" ]] || { echo "ERROR: mint returned no ect"; exit 1; }

NONCE="test-nonce-$(date +%s)"
JTI="jti-oddplus-$(date +%s)"
DPoP=$(make_dpop "${NONCE}" "${JTI}" "${PUB_B64_A}" "${PRIV_HEX_A}")

echo "== 12) Probe ALLOW (ODD_PLUS) =="
probe "${ECT}" "${DPoP}" "${NONCE}" '{"resource":"PET-CT","action":"read","purpose":"model_prediction","cohort":"ODD_PLUS","jti":"'"${JTI}"'"}'

echo
echo "== 13) Probe DENY (tampered ECT) =="
# tamper signature segment while keeping 3 segments
IFS='.' read -r h p s <<<"${ECT}"
INVALID_ECT="${h}.${p}.${s%?}ELF"
echo ${INVALID_ECT}
probe "${INVALID_ECT}" "${DPoP}" "${NONCE}" '{"resource":"PET-CT","action":"read","purpose":"model_prediction","cohort":"ODD_PLUS","jti":"'"${JTI}"'"}'

echo "Done."
