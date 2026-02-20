

FILE_JSONL="${1:-}"
if [[ -z "${FILE_JSONL}" ]]; then
  echo "Usage: $0  admission_bench_<tag>.jsonl" >&2
  exit 1
fi

echo "Compute median (p50) for $FILE_JSONL"

jq -s '
def p50(x): (x|sort)[((length-1)*0.5|floor)];
{
 n: length,
 token_p50: p50(map(.token_verify_ms)),
 pop_p50:   p50(map(.pop_verify_ms)),
 cap_p50:   (map(.cap_match_ms) | map(select(.!=null)) | (if length>0 then p50(.) else null end)),
 full_p50:  p50(map(.full_check_ms))
}' $FILE_JSONL