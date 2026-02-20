#!/usr/bin/env bash
set -euo pipefail

# -------- Config --------
PORT=${PORT:-8443}
ISSUER="https://verifier.local:8443"

CAC="../vfp-governance/verifier/certs/ca.crt"
CRT="../vfp-governance/verifier/certs/hub.crt"
KEY="../vfp-governance/verifier/certs/hub.key"

# Org-admin mTLS material for /mint_ect (Test#2)
MINT_CRT="${MINT_CRT:-../vfp-governance/verifier/certs/HospitalA-admin.crt}"
MINT_KEY="${MINT_KEY:-../vfp-governance/verifier/certs/HospitalA-admin.key}"

# Cap profiles to mint (must exist in policy.cap_profiles)
CAP_PROFILES='["capset:trainer_A","capset:data_scientist"]'

NBF="$(date -u -Iseconds -d '-60 seconds' | sed 's/+00:00/Z/')"
EXP="$(date -u -Iseconds -d '+1 hour'     | sed 's/+00:00/Z/')"
CURL_MTLS=( -s --cacert "$CAC" --cert "$CRT" --key "$KEY" )
CURL_MTLS_MINT=( -s --cacert "$CAC" --cert "$MINT_CRT" --key "$MINT_KEY" )

# -------- Generate holder keys --------
echo "== 1) Generate holder keys =="
python3 ../tools/gen_member_keys.py --org org://HospitalA   --who Martinez | sed 's/^/[keys] /' || true
PUB_B64=$(cat holder_keys/Martinez.pubb64)
PRIV_HEX=$(cat holder_keys/Martinez.privhex)


echo "== 2)  Wait for /health =="
for i in {1..30}; do
  sleep 0.3
  echo -n "."
  if curl "${CURL_MTLS[@]}" "${ISSUER}/health" >/dev/null; then break; fi
done
echo "[issuer $i] $(curl "${CURL_MTLS[@]}" ${ISSUER}/health)"

# -------- Mint ECT --------
echo "== 3) Mint ECT =="
ECT_RESP=$(curl "${CURL_MTLS_MINT[@]}" -X POST "${ISSUER}/mint_ect" \
  -H 'content-type: application/json' \
  -d "$(jq -n --arg pub "$PUB_B64" --argjson profiles "${CAP_PROFILES}" --arg nbf "$NBF" --arg exp "$EXP" \
        '{holder_pub_b64:$pub, cap_profiles:$profiles, nbf:$nbf, exp:$exp}')")

echo "${ECT_RESP}" | jq .
ECT=$(echo "${ECT_RESP}" | jq -r .ect_jws)
echo "[ect]" "${ECT}"

# -------- Make DPoP (custom, from make_dpop.py) --------
echo "== 4) Make DPoP =="
NONCE="test-nonce-$(date +%s)"
echo "[nonce]" "${NONCE}"

JTI="jti-$(date +%s)"
#HTU="${ISSUER}/admission/check"
HTU="https://verifier.local/admission/check"
DPoP=$(python3 ../tools/make_dpop_jwt_eddsa.py "${PRIV_HEX}" "${PUB_B64}" "${NONCE}" "${JTI}" "POST" "${HTU}")
echo "[dpop]" "${DPoP}"

# -------- Probe: allow (tumor measurements aggregated, no PII/contact) --------
echo "== 5) Probe ALLOW =="
ALLOW_REQ='{"resource":"TUMOR_MEASUREMENTS","action":"read","agg":"aggregated","pii":false,"contact":false,"jti":"'"${JTI}"'"}'
echo $ALLOW_REQ
curl "${CURL_MTLS[@]}" -X POST "${ISSUER}/admission/check" \
  -H "Authorization: ECT ${ECT}" \
  -H "DPoP: ${DPoP}" \
  -H "X-DPoP-Nonce: ${NONCE}" \
  -H 'content-type: application/json' \
  -d "${ALLOW_REQ}" | jq .

# -------- Probe: deny (wrong purpose) --------
echo "== 6) Probe DENY (wrong purpose) =="
DENY_REQ='{"resource":"PET-CT","action":"train","purpose":"model_prediction","cohort":"A","jti":"'"${JTI}"'"}'
echo $DENY_REQ
curl "${CURL_MTLS[@]}" -X POST "${ISSUER}/admission/check" \
  -H "Authorization: ECT ${ECT}" \
  -H "DPoP: ${DPoP}" \
  -H "X-DPoP-Nonce: ${NONCE}" \
  -H 'content-type: application/json' \
  -d "${DENY_REQ}" | jq .


# -------- Probe: deny (wrong cohort) --------
echo "== 7) Probe DENY (wrong cohort B) =="
DENY_REQ_COHORT='{"resource":"PET-CT","action":"train","purpose":"model_training","cohort":"B","jti":"'"${JTI}"'"}'
echo $DENY_REQ_COHORT
curl "${CURL_MTLS[@]}" -X POST "${ISSUER}/admission/check" \
  -H "Authorization: ECT ${ECT}" \
  -H "DPoP: ${DPoP}" \
  -H "X-DPoP-Nonce: ${NONCE}" \
  -H 'content-type: application/json' \
  -d "${DENY_REQ_COHORT}" | jq .


# -------- Probe: deny (binding mismatch) --------
echo "== 8) Probe DENY (binding mismatch with different key) =="
# Generate a second keypair for another member
python3 ../tools/gen_member_keys.py --org org://HospitalA   --who "intruder" | sed 's/^/[keys-intruder] /' || true
PUB_B64_INTRUDER=$(cat holder_keys/intruder.pubb64)
PRIV_HEX_INTRUDER=$(cat holder_keys/intruder.privhex)

# Make a DPoP with the intruder's key instead of the bound one
NONCE_INTRUDER="nonce-intruder-$(date +%s)"
JTI_INTRUDER="jti-intruder-$(date +%s)"
DPoP_INTRUDER=$(python3 ../tools/make_dpop_jwt_eddsa.py "${PRIV_HEX_INTRUDER}" "${PUB_B64_INTRUDER}" "${NONCE_INTRUDER}" "${JTI_INTRUDER}" "POST" "${HTU}")
ALLOW_REQ_INTRUDER=$(echo "${ALLOW_REQ}" | jq -c --arg jti "${JTI_INTRUDER}" '.jti=$jti')


curl "${CURL_MTLS[@]}" -X POST "${ISSUER}/admission/check" \
  -H "Authorization: ECT ${ECT}" \
  -H "DPoP: ${DPoP_INTRUDER}" \
  -H "X-DPoP-Nonce: ${NONCE_INTRUDER}" \
  -H 'content-type: application/json' \
  -d "${ALLOW_REQ_INTRUDER}" | jq .

 
echo "Done."

