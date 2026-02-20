#!/usr/bin/env bash
set -euo pipefail

# ======= CONFIG (adjust paths to match your repo) =======
VERIFIER_HOST="${VERIFIER_HOST:-verifier.local}"
VERIFIER_PORT="${VERIFIER_PORT:-8443}"
ADMISSION_URL="https://${VERIFIER_HOST}:${VERIFIER_PORT}/admission/check"

# mTLS material used by the caller (hub/coordinator identity)
CACERT="${CACERT:-../../vfp-governance/verifier/certs/ca.crt}"
CLIENT_CRT="${CLIENT_CRT:-../../vfp-governance/verifier/certs/hub.crt}"
CLIENT_KEY="${CLIENT_KEY:-../../vfp-governance/verifier/certs/hub.key}"

# DPoP HTU must match what admission expects
DPoP_HTU="${DPoP_HTU:-https://verifier.local/admission/check}"

# issuer container (mint SCT/ECT)
ISSUER_CONTAINER="${ISSUER_CONTAINER:-issuer-hospitala}"

# holder identity + local demo custody keys (used to sign DPoP)
SUB="${SUB:-Audrey}"
COHORT="${COHORT:-EVEN_ONLY}"
COHORT_REQ="${COHORT_REQ:-EVEN_ONLY}"

ORG_BAD="${ORG_BAD:-org://HospitalB}"
HOLDER_BAD="${HOLDER_BAD:-Bob}"
DPOP_FAIL="${DPOP_FAIL:-False}"


# admission request content
RESOURCE="${RESOURCE:-PET-CT}"
ACTION="${ACTION:-read}"
PURPOSE="${PURPOSE:-model_prediction}"

# GOOD holder key files (demo custody)
HOLDER_DIR="${HOLDER_DIR:-../holder_keys}"
PRIVHEX_FILE="${PRIVHEX_FILE:-${HOLDER_DIR}/${SUB}.privhex}"
PUBB64_FILE="${PUBB64_FILE:-${HOLDER_DIR}/${SUB}.pubb64}"

# BAD holder key files (demo custody)
PRIVHEX_FILE_BAD="${PRIVHEX_FILE_BAD:-${HOLDER_DIR}/${HOLDER_BAD}.privhex}"
PUBB64_FILE_BAD="${PUBB64_FILE_BAD:-${HOLDER_DIR}/${HOLDER_BAD}.pubb64}"

# tool that builds the DPoP JWT
MAKE_DPOP="${MAKE_DPOP:-../../tools/make_dpop_jwt_eddsa.py}"


RESET_JSON="$(
  curl -sk -X POST "https://${VERIFIER_HOST}:${VERIFIER_PORT}/bench/reset" \
    --cacert "$CACERT" --cert "$CLIENT_CRT" --key "$CLIENT_KEY"
)"
echo "$RESET_JSON" | jq .


# iterations
NITER="${NITER:-1000}"
SLEEP_MS="${SLEEP_MS:-0}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1" >&2; exit 1; }; }
need docker
need python3
need jq
need curl

[[ -f "$PRIVHEX_FILE" ]] || { echo "Missing $PRIVHEX_FILE"; exit 1; }
[[ -f "$PUBB64_FILE" ]]  || { echo "Missing $PUBB64_FILE"; exit 1; }
[[ -f "$MAKE_DPOP" ]]    || { echo "Missing $MAKE_DPOP"; exit 1; }

PUB_B64="$(cat "$PUBB64_FILE")"
PRIV_HEX="$(cat "$PRIVHEX_FILE")"

PUB_B64_BAD="$(cat "$PUBB64_FILE_BAD")"
PRIV_HEX_BAD="$(cat "$PRIVHEX_FILE_BAD")"

ms_sleep() {
  local ms="$1"
  [[ "$ms" -le 0 ]] && return 0
  python3 - <<PY
import time
time.sleep(${ms}/1000.0)
PY
}

mint_ect() {
  local sub="$1"
  local cohort="$2"
  docker exec -i "$ISSUER_CONTAINER" python3 - <<PY
import json, requests
payload = {"sub": "${sub}", "cohort": "${cohort}"}
r = requests.post("http://127.0.0.1:8080/mint", json=payload, timeout=20)
out = r.json() if r.headers.get("content-type","").startswith("application/json") else r.text
print(json.dumps({"status": r.status_code, "body": out}))
PY
}

make_dpop() {
  local priv_hex="$1"
  local pub_b64="$2"
  local nonce="$3"
  local jti="$4"
  # make_dpop_jwt_eddsa.py arguments must match your tool.
  # This matches your Test3B pattern: privhex pubb64 nonce jti method htu
  python3 "$MAKE_DPOP" "$priv_hex" "$pub_b64" "$nonce" "$jti" "POST" "$DPoP_HTU"
}

echo "== Mint ECT (sub=$SUB cohort=$COHORT) =="
MINT_JSON="$(mint_ect "$SUB" "$COHORT")"
echo "$MINT_JSON" | jq .
ECT="$(echo "$MINT_JSON" | jq -r '.body.ect // .body.ect_jws // empty')"
[[ -n "$ECT" ]] || { echo "Mint failed: no ect in response"; exit 1; }


if [ "${DPOP_FAIL,,}" = "false" ]; then
    PRIV_HEX__="$PRIV_HEX"
    PUB_B64__="$PUB_B64"
    if [ "$COHORT_REQ" = "$COHORT" ]; then
        TAG="_allow"
     else
        TAG="_deny_cap"   
    fi    
elif [ "${DPOP_FAIL,,}" = "true" ]; then
    PRIV_HEX__="$PRIV_HEX_BAD"
    PUB_B64__="$PUB_B64_BAD"
    TAG="_deny_pop"
fi
echo "TAG=$TAG"

echo "== Run N=$NITER admission checks =="
for i in $(seq 1 "$NITER"); do
  NONCE="bench-nonce-$(date +%s)-$i"
  JTI="bench-jti-$(date +%s)-$i"

  DPOP="$(make_dpop "$PRIV_HEX__"  "$PUB_B64__"  "$NONCE" "$JTI")"

  BODY="$(jq -cn \
    --arg r "$RESOURCE" --arg a "$ACTION" --arg p "$PURPOSE" --arg c "$COHORT_REQ" --arg j "$JTI" \
    '{resource:$r, action:$a, purpose:$p, cohort:$c, jti:$j}')"

  curl -sk "$ADMISSION_URL" \
    --cacert "$CACERT" --cert "$CLIENT_CRT" --key "$CLIENT_KEY" \
    -H "Content-Type: application/json" \
    -H "Authorization: ECT $ECT" \
    -H "DPoP: $DPOP" \
    -H "X-DPoP-Nonce: $NONCE" \
    -d "$BODY"  >/dev/null   #| jq -c '{allow:.allow, reason:(.reason//"" )}'


    PCT=$((i * 100 / NITER))
    FILLED=$((PCT / 2))
    BAR=$(printf '%0.s#' $(seq 1 $FILLED))
    printf "\r[%-50s] %d%%" "$BAR" "$PCT"

  ms_sleep "$SLEEP_MS"
done


docker exec -it verifier-app sh -lc 'rm -f /tmp/admission_bench.jsonl'

echo "== Flush server bench buffer =="
FLUSH_JSON="$(
  curl -sk -X POST "https://${VERIFIER_HOST}:${VERIFIER_PORT}/bench/flush" \
    --cacert "$CACERT" --cert "$CLIENT_CRT" --key "$CLIENT_KEY"
)"
echo "$FLUSH_JSON" | jq .

BENCH_PATH="$(echo "$FLUSH_JSON" | jq -r '.path')"
echo "BENCH_PATH=$BENCH_PATH"

echo "== Copy bench file from verifier-app:${BENCH_PATH} =="
docker cp "verifier-app:${BENCH_PATH}" ./admission_bench$TAG.jsonl
echo "Saved ./admission_bench$TAG.jsonl (lines: $(wc -l < ./admission_bench$TAG.jsonl))"


echo "Done."
