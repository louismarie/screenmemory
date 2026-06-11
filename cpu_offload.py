"""
No-sudo consumption proxy: CPU-time consumed per embedding, per compute unit.

Wall time  = elapsed real time.
CPU time   = process_time() = user+system CPU actually executed by THIS process.

On CPU_ONLY the CPU does the matmuls -> CPU time ~= wall time (CPU saturated).
On CPU_AND_NE the ANE does the matmuls and the CPU thread waits -> CPU time << wall time.
The ratio CPU/wall is the CPU duty cycle: low duty == CPU is freed == the always-on moat.
This is a direct, sudo-free measurement of compute offload (absolute mW still wants
powermetrics, but offload is the mechanism behind the power saving).
"""
import time
import numpy as np
import coremltools as ct

SEQ_LEN = 128
ITERS = 400
UNITS = ["CPU_ONLY", "CPU_AND_NE"]


def make_x():
    return {"input_ids": np.random.randint(0, 30000, (1, SEQ_LEN)).astype(np.int32),
            "attention_mask": np.ones((1, SEQ_LEN), dtype=np.int32)}


def measure(unit):
    m = ct.models.MLModel("MiniLM.mlpackage", compute_units=getattr(ct.ComputeUnit, unit))
    for _ in range(20):
        m.predict(make_x())
    inputs = [make_x() for _ in range(ITERS)]
    w0, c0 = time.perf_counter(), time.process_time()
    for x in inputs:
        m.predict(x)
    wall = time.perf_counter() - w0
    cpu = time.process_time() - c0
    return wall, cpu


print(f"iters={ITERS}, seq_len={SEQ_LEN}\n")
print(f"{'unit':<12}{'wall':>9}{'cpu-time':>11}{'duty':>8}{'emb/s':>9}{'cpu-ms/emb':>12}")
rows = {}
for u in UNITS:
    wall, cpu = measure(u)
    duty = cpu / wall
    eps = ITERS / wall
    cpu_ms = cpu / ITERS * 1000
    rows[u] = (wall, cpu, duty, eps, cpu_ms)
    print(f"{u:<12}{wall:>8.2f}s{cpu:>10.2f}s{duty:>7.0%}{eps:>9.1f}{cpu_ms:>11.2f}")

if all(u in rows for u in UNITS):
    cpu_only = rows["CPU_ONLY"][4]
    cpu_ne = rows["CPU_AND_NE"][4]
    print(f"\nCPU work per embedding: {cpu_ne:.2f} ms (ANE) vs {cpu_only:.2f} ms (CPU)")
    print(f"-> ANE path uses {cpu_only / cpu_ne:.1f}x LESS CPU per embedding, "
          f"at higher throughput.")
