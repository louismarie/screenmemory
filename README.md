# ScreenMemory 🧠

**Always-on semantic screen memory for Apple Silicon — 100% local, offline, free.**

ScreenMemory continuously captures your screen, OCRs it, embeds the text **on the Apple Neural Engine**, stores it in an encrypted local database, and lets you ask questions about anything you've seen — answered by Apple's on-device foundation model. Nothing ever leaves your machine.

```
ScreenCaptureKit ─→ Vision OCR ─→ embeddings on the ANE ─→ encrypted SQLite ─→ on-device RAG
   (1 fps, dedup)    (local)      (CoreML fp16, 512-d)      (AES-GCM at rest)   (FoundationModels)
```

## Why the Neural Engine matters

Existing screen-memory tools (Rewind, screenpipe) run their indexing on CPU/GPU — fans, battery drain, a busy machine. ScreenMemory pushes the embedding workload to the ANE, which is otherwise idle. Measured on an M1 Max ([full benchmark](RESULTS.md)):

| | CPU only | **ANE (`CPU_AND_NE`)** |
|---|---|---|
| CPU duty cycle while indexing | 97% (saturated) | **19% (free)** |
| CPU time per embedding | 3.70 ms | **0.51 ms — 7.2× less** |
| Throughput | 261 emb/s | **367 emb/s** |
| Embedding fidelity vs PyTorch | — | cosine 0.99998 (lossless) |

⚠️ Benchmark gotcha: CoreML's default `ComputeUnit.ALL` schedules this model on the **GPU and is slower than CPU**. You must force `CPU_AND_NE` explicitly.

*(Benchmark ran on `all-MiniLM-L6-v2`; the app ships the larger multilingual `distiluse` — absolute numbers differ, the CPU-offload mechanism is the same.)*

## Features

- **Always-on capture** at 1 fps with perceptual dedup + throttling — only screens that change get indexed.
- **Multilingual semantic search** (`distiluse-base-multilingual-cased-v2`, WordPiece tokenizer reimplemented in Swift — no Python at runtime).
- **On-device RAG**: questions answered by Apple FoundationModels, in the language of the question.
- **Privacy by construction**: AES-GCM encryption at rest, secret redaction before indexing, app exclusions, one-click pause, zero network.
- **Menubar app** (counter, start/stop, pause) + **native dashboard window** backed by a local loopback server on port 8790. Every generated answer is shown next to the raw OCR sources and scores that produced it.

## Requirements

- Apple Silicon Mac, macOS 26+ (Tahoe), **Apple Intelligence enabled** (for RAG generation; search works without it)
- Xcode command-line tools (Swift 6)
- Python 3.11+ (one-time, to convert the embedding model)

## Quickstart

```bash
# 1. Convert the embedding model to CoreML (one-time, ~260 MB, not shipped in the repo)
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
python convert_ml.py        # -> ScreenMemory/Sources/ScreenMemory/Resources/Embed.mlpackage

# 2. Build & package the menubar app
cd ScreenMemory
./package.sh                # -> ~/Applications/ScreenMemory.app (ad-hoc signed)
open ~/Applications/ScreenMemory.app

# 3. Menu 🧠 -> "Start capture" -> grant Screen Recording when prompted

# 4. Ask questions
.build/release/ScreenMemory query "what was that error I saw this morning?"

# Or the standalone dashboard server:
.build/release/ScreenMemory serve 8790
```

> **Ad-hoc signing caveat**: macOS ties the Screen Recording grant to the binary's code hash. Rebuilding the app invalidates the grant. Re-grant after each rebuild, or sign with a real Developer ID certificate to make it stable. Details in [ScreenMemory/README.md](ScreenMemory/README.md).

## Repo layout

- `ScreenMemory/` — the Swift app (capture, OCR, tokenizer, ANE embedder, encrypted store, RAG, menubar, web UI)
- `convert_ml.py`, `requirements.txt` — embedding model → CoreML conversion
- `bench.py`, `cpu_offload.py`, `embed_loop.py`, `power_loop.sh`, `verify.py`, `val_multilingual.py` — the ANE benchmark suite
- `RESULTS.md` — benchmark results

## License

[AGPL-3.0](LICENSE). You can use, modify and self-host ScreenMemory freely; if you distribute it or offer it as a service, your modifications must be released under the same license. For a commercial license without copyleft obligations, contact the author.

The embedding model (`distiluse-base-multilingual-cased-v2`) is Apache 2.0 from [sentence-transformers](https://www.sbert.net/).
