
# -------------------------------------------------
#  In-memory bench buffer (no I/O on request path)
# -------------------------------------------------
import os, time, threading, atexit, json
from collections import deque

BENCH = os.getenv("BENCH", "0") == "1"
BENCH_MAX = int(os.getenv("BENCH_MAX", "200000"))  # up to 200k samples in RAM
BENCH_OUT = os.getenv("BENCH_OUT", "/tmp/admission_bench.jsonl")

_bench_lock = threading.Lock()
_bench_buf = deque(maxlen=BENCH_MAX)

def _ns(): return time.perf_counter_ns()
def _ms(dt_ns): return dt_ns / 1e6

def _bench_add(sample: dict) -> None:
    # O(1), no syscalls
    if not BENCH:
        return
    with _bench_lock:
        _bench_buf.append(sample)
        

def _bench_reset() -> int:
    if not BENCH:
        return 0
    with _bench_lock:
        n = len(_bench_buf)
        _bench_buf.clear()
    return n


def _bench_flush(path: str = BENCH_OUT) -> int:
    if not BENCH:
        return 0
    with _bench_lock:
        items = list(_bench_buf)
        _bench_buf.clear()
    if not items:
        return 0
    # single write pass; still not on hot path
    with open(path, "a", encoding="utf-8") as f:
        for it in items:
            f.write(json.dumps(it, separators=(",", ":")) + "\n")
    return len(items)

atexit.register(_bench_flush)
