"""
Hammer the embedder continuously on a chosen compute unit, for a fixed duration.
Used under powermetrics to measure perf/watt. Prints achieved throughput.

Usage: embed_loop.py <CPU_ONLY|CPU_AND_GPU|CPU_AND_NE|ALL> <seconds>
"""
import sys, time
import numpy as np
import coremltools as ct

UNIT = sys.argv[1] if len(sys.argv) > 1 else "CPU_AND_NE"
SECS = float(sys.argv[2]) if len(sys.argv) > 2 else 15.0
SEQ_LEN = 128

m = ct.models.MLModel("MiniLM.mlpackage", compute_units=getattr(ct.ComputeUnit, UNIT))
x = {"input_ids": np.random.randint(0, 30000, (1, SEQ_LEN)).astype(np.int32),
     "attention_mask": np.ones((1, SEQ_LEN), dtype=np.int32)}
for _ in range(20):
    m.predict(x)

n = 0
t0 = time.perf_counter()
while time.perf_counter() - t0 < SECS:
    m.predict(x)
    n += 1
dt = time.perf_counter() - t0
print(f"{UNIT}: {n} embeddings in {dt:.1f}s = {n/dt:.1f} emb/s", flush=True)
