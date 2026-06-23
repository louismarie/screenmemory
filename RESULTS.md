# ANE Embedding Benchmark Results

Machine: Mac Studio M1 Max, macOS 26.5
Model: `all-MiniLM-L6-v2` (~22M parameters, 384-dimensional embeddings), CoreML fp16,
sequence length 128

Goal: validate that the Apple Neural Engine can carry a continuous screen-memory embedding
pipeline at useful throughput and low CPU cost.

## Conversion

- Path: `torch.export` + `run_decompositions({})` -> CoreML mlprogram fp16, 43 MB.
- `torch.jit.trace` failed on `aten::Int` inside `bert/embeddings`; `torch.export` fixed it.
- Working stack: torch 2.7.0, transformers 4.49.0, coremltools 9.0.

## Numerical Fidelity

| Phrase | cos(PyTorch, CoreML fp16) |
| --- | --- |
| "The Apple Neural Engine accelerates..." | 0.99998 |
| "A cat sleeps on the warm windowsill..." | 0.99998 |

The ANE fp16 model is interchangeable with the PyTorch reference for this use case.

## Throughput Per Compute Unit

300 iterations, batch size 1.

| compute_units | latency | throughput |
| --- | --- | --- |
| CPU_ONLY | 3.49 ms | 286.8 emb/s |
| CPU_AND_GPU | 4.16 ms | 240.4 emb/s |
| CPU_AND_NE | 1.99 ms | 502.5 emb/s |
| ALL | 4.19 ms | 238.4 emb/s |

Findings:

- `CPU_AND_NE` is 1.8x faster than CPU-only.
- `ALL` does not pick the ANE here; CoreML schedules GPU and is slower.
- GPU overhead dominates on this small model.

At roughly 500 embeddings/s, the pipeline has ample headroom for deduped screen capture.

## CPU Offload

Measured without sudo by comparing CPU process time against wall-clock time.

| compute_units | CPU duty cycle | CPU/embedding | throughput |
| --- | --- | --- | --- |
| CPU_ONLY | 97% | 3.70 ms | 261 emb/s |
| CPU_AND_NE | 19% | 0.51 ms | 367 emb/s |

The ANE path uses 7.2x less CPU per embedding while keeping throughput higher. CPU is idle
around 81% of the time, leaving CPU and GPU capacity available for the rest of the machine.

## Optional Power Confirmation

Exact ANE, CPU, and GPU milliwatt numbers can be gathered with `powermetrics`, which requires
sudo:

```bash
cd ane-rag-bench
sudo ./power_loop.sh
```

This is useful for a pitch or whitepaper, but it does not change the offload conclusion above.

## Verdict

- Feasible: reliable conversion with a 43 MB model.
- Faithful: cosine 0.99998 against reference outputs.
- Fast: ANE is 1.8x faster than CPU-only throughput when explicitly selected.
- Efficient: ANE uses 7.2x less CPU per embedding, with 19% CPU duty cycle versus 97%.

ScreenMemory's core technical risk is validated: an always-on semantic screen-memory pipeline
can embed a continuous screen stream on the ANE while leaving CPU and GPU mostly free.
