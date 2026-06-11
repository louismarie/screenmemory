"""
Benchmark the CoreML embedder across compute units.

Reports latency + throughput for CPU_ONLY / CPU_AND_GPU / CPU_AND_NE / ALL.
A large speedup on CPU_AND_NE vs CPU_ONLY is the first signal the ANE is engaged;
powermetrics (see power_loop.sh) gives the definitive ANE-residency proof.
"""
import time
import numpy as np
import coremltools as ct

MODEL = "MiniLM.mlpackage"
SEQ_LEN = 128
WARMUP = 20
ITERS = 300

UNITS = {
    "CPU_ONLY": ct.ComputeUnit.CPU_ONLY,
    "CPU_AND_GPU": ct.ComputeUnit.CPU_AND_GPU,
    "CPU_AND_NE": ct.ComputeUnit.CPU_AND_NE,
    "ALL": ct.ComputeUnit.ALL,
}


def make_input():
    ids = np.random.randint(0, 30000, size=(1, SEQ_LEN)).astype(np.int32)
    mask = np.ones((1, SEQ_LEN), dtype=np.int32)
    return {"input_ids": ids, "attention_mask": mask}


def bench(name, unit):
    m = ct.models.MLModel(MODEL, compute_units=unit)
    x = make_input()
    for _ in range(WARMUP):
        m.predict(x)
    t0 = time.perf_counter()
    for _ in range(ITERS):
        m.predict(make_input())
    dt = time.perf_counter() - t0
    lat = dt / ITERS * 1000
    eps = ITERS / dt
    print(f"  {name:<13} {lat:7.2f} ms/emb   {eps:8.1f} emb/s")
    return eps


def main():
    print(f"Model: {MODEL}  seq_len={SEQ_LEN}  iters={ITERS}\n")
    results = {}
    for name, unit in UNITS.items():
        try:
            results[name] = bench(name, unit)
        except Exception as e:
            print(f"  {name:<13} ERROR: {e}")
    if "CPU_ONLY" in results and "CPU_AND_NE" in results:
        sp = results["CPU_AND_NE"] / results["CPU_ONLY"]
        print(f"\n  ANE speedup vs CPU: {sp:.1f}x")


if __name__ == "__main__":
    main()
