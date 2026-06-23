# ScreenMemory

Always-on semantic screen memory for Apple Silicon: ScreenMemory captures changing screens,
extracts text, embeds it on the Neural Engine, and makes it searchable with local RAG.
The default path is on-device, private, and free.

The bet, validated in `../RESULTS.md`: ANE embeddings use 7.2x less CPU per embedding than
CPU-only execution, so continuous indexing can run while leaving the machine responsive.

## Pipeline

```text
ScreenCaptureKit -> average-hash dedup -> Vision OCR -> CoreML/ANE embedder
                                                        |
                                             SQLite vector store
                                                        |
query -> CoreML/ANE embedder -> cosine top-k -> FoundationModels local answer
```

| Step | File | Status |
| --- | --- | --- |
| Capture + dedup | `Capture.swift` | Tested on a real screen |
| OCR | `OCR.swift` | Tested on images and screen captures |
| Vector store | `Store.swift` | SQLite storage with cosine retrieval |
| RAG | `RAG.swift` | Grounded constrained generation |
| ANE embedder | `Embedder.swift`, `Tokenizer.swift` | Multilingual distiluse model, Python parity |
| Privacy | `Privacy.swift` | App exclusions, secret redaction, pause |
| Encryption at rest | `Crypto.swift` | AES-GCM text storage with Keychain key |
| Localization | `Resources/i18n/*.json` | English and French catalogs |
| Always-on app | `MenuBar.swift` | Menubar host, dashboard window, login item |

## Privacy

- Pause: `screenmemory pause` / `resume` toggles a flag that stops capture indexing.
- App exclusions: password managers and banking apps are filtered through ScreenCaptureKit.
- Secret redaction runs before embedding and storage for passwords, cards, IBANs, emails,
  API keys, and JWTs.
- Text is encrypted at rest with AES-GCM 256-bit keys stored in Keychain, with a locked-down
  file fallback.

## Model

`distiluse-base-multilingual-cased-v2` is converted to CoreML fp16 and run with
`.cpuAndNeuralEngine`. The WordPiece tokenizer is implemented in Swift and ships with
`vocab.txt`.

## Build And Usage

```bash
swift build
BIN=.build/debug/ScreenMemory

$BIN capture 1                 # continuous capture at 1 fps
$BIN index photo.png           # OCR, embed, and store an image
$BIN add "free text"           # embed and store raw text
$BIN query "my question?"      # retrieve and answer with FoundationModels
$BIN pause / resume            # stop or resume capture indexing
$BIN stats                     # stored memory count and pause state
$BIN ready                     # local model availability

$BIN login on                  # register the packaged app as a login item
$BIN menubar                   # run the menubar app and dashboard host

$BIN list 50 0                 # JSON memories, newest first
$BIN search "query" 8          # hybrid top-k retrieval, no generation
$BIN ask "question?" 6         # grounded RAG answer with cited sources
$BIN recap [today|yesterday|YYYY-MM-DD] [--json]
$BIN analytics [days]

$BIN focus [days] [--json]
$BIN coach [today|yesterday|YYYY-MM-DD] [--json]
$BIN weekly [YYYY-MM-DD end] [--json]
$BIN digest [yesterday|YYYY-MM-DD]
$BIN tick [--force] [--silent]

$BIN reindex
$BIN prune 90 --apply
$BIN eval make 30 && $BIN eval
$BIN bakeoff
```

## Retrieval

Screens are split into spatial blocks before embedding, so large OCR dumps are not truncated
as one whole-screen vector. Chunks carry app and window title metadata. Search combines BM25,
cosine similarity, Reciprocal Rank Fusion, recency, time filters parsed from the question,
and near-duplicate collapse. Generation is constrained with `@Generable`: the model can only
cite supplied excerpts and returns `notFound` instead of inventing.

Time-filter phrases and stopwords for supported languages live in `Resources/i18n/*.json`.
The Swift search code is English; language-specific data stays in catalogs.

## Daily Recap

`recap` groups a day into sessions by app, window, and idle gaps, summarizes each session with
the on-device model, and reduces them into a work journal: summary, highlights, and threads to
resume. Markdown is cached in `~/.screenmemory.recaps/`, while raw rows can be pruned later.

## Proactive Layer

The menubar scheduler produces:

- focus analytics computed deterministically in Swift;
- coaching suggestions grounded on metrics;
- weekly synthesis from daily recaps;
- morning digest, evening recap, and Monday synthesis notifications.

Artifacts are written under `~/.screenmemory.{coach,weekly,digests}/`.

## Dashboard

The dashboard is served by the app itself through a loopback-only `Network.framework` server
on `127.0.0.1:8790`. The menubar opens it in a native macOS `WKWebView` window, not in a
browser.

```bash
ScreenMemory serve [port]      # standalone dashboard host
python3 ui/server.py           # legacy development server
```

The modern dashboard has tabs for Resume, Ask, Journal, Coach, Week, Focus, Trends, and Memory.
It uses file-based i18n catalogs from `Resources/i18n/en.json` and `Resources/i18n/fr.json`.

## Runtime Requirements

- RAG generation requires Apple Intelligence to be enabled. Without it, the CLI falls back to
  raw top-k matches.
- Capture requires macOS Screen Recording permission for the packaged app.

## Next Work

- ANN index only after data volume justifies it.
- DCT pHash if average-hash lets too many near-duplicates through.
- Additional signed distribution options for stable TCC behavior across upgrades.
