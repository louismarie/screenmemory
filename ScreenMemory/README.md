# ScreenMemory

Mémoire d'écran sémantique **always-on** sur Apple Silicon : capture l'écran en continu,
en extrait le texte, l'embedde **sur le Neural Engine**, et le rend requêtable en langage
naturel (RAG) — le tout **on-device, privé, gratuit**.

Le pari (validé dans `../RESULTS.md`) : faire les embeddings sur l'ANE coûte **7,2× moins
de CPU** par embedding qu'en CPU pur → un pipeline d'indexation continu qui laisse la machine
libre, là où Rewind/screenpipe tapent dans le CPU/GPU et la batterie.

## Pipeline (les 4 étapes)

```
ScreenCaptureKit ─► dédup (average-hash 8x8) ─► Vision OCR ─► Embedder (CoreML/ANE)
                                                                      │
                                              SQLite (vecteurs)  ◄────┘
                                                     │
   requête ─► Embedder (ANE) ─► cosine top-k ─► FoundationModels (réponse on-device)
```

| Étape | Fichier | Statut |
|---|---|---|
| 1. Capture + dédup | `Capture.swift` (ScreenCaptureKit) | ✅ testé sur écran réel (5194 chars OCR'd, dédup OK) |
| 2. OCR | `OCR.swift` (Vision) | ✅ testé sur image + écran |
| 3. Vector store | `Store.swift` (SQLite + cosine) | ✅ retrieval français correct |
| 4. RAG | `RAG.swift` (FoundationModels) | ✅ câblé ; génération = voir prérequis |
| Embedder ANE | `Embedder.swift` + `Tokenizer.swift` | ✅ distiluse multilingue, scores == référence Python |
| **Confidentialité** | `Privacy.swift` | ✅ exclusion d'apps + rédaction secrets + pause (testés) |
| **Chiffrement at-rest** | `Crypto.swift` (AES-GCM + Keychain) | ✅ base = ciphertext, round-trip OK |
| **Langue de réponse** | `RAG.swift` (NaturalLanguage) | ✅ FR→FR, EN→EN (détection + directive explicite) |
| **Always-on** | `Agent.swift` (launchd) | ✅ daemon vérifié (capture en arrière-plan) |
| **Interface** | `MenuBar.swift` (AppKit) | ✅ menubar lance sans crash (compteur/pause/on-off/log) |
| **Concurrence** | `Store.swift` (WAL) | ✅ daemon écrit pendant que query lit, sans deadlock |

### Confidentialité (le bloquant qui a coulé Recall) — implémenté

- **Pause** : `screenmemory pause` / `resume` (drop d'un flag) → la capture n'indexe plus rien. Testé : 0 souvenir en pause, reprise OK.
- **Exclusion d'apps** : gestionnaires de mots de passe + banque jamais capturés (`SCContentFilter`). Extensible via `~/.screenmemory.exclude` (un bundle id par ligne).
- **Rédaction de secrets** *avant* embed+stockage : mots de passe, cartes, IBAN, emails, clés API/JWT → `[REDACTED:LABEL]`. Le secret n'entre ni dans le vecteur ni dans la base.
- **Chiffrement at-rest** : texte chiffré AES-GCM 256 bits, clé en Keychain (repli fichier 0600). Vérifié : le secret en clair est absent du fichier `.db`.

## Modèle

`distiluse-base-multilingual-cased-v2` → CoreML fp16, exécuté en `.cpuAndNeuralEngine`.
Choisi **multilingue** après qu'`all-MiniLM-L6-v2` (anglais) ait mal classé le contenu FR.
Tokenizer WordPiece *cased* réimplémenté en Swift (self-contained, `vocab.txt`).

## Build & usage

```bash
swift build
BIN=.build/debug/ScreenMemory

$BIN capture 1                 # capture continue à 1 fps (dédup + throttle -> indexe les écrans qui changent)
$BIN index photo.png           # OCR + embed + store d'une image
$BIN add "texte libre"         # embed + store direct (secrets rédigés)
$BIN query "ma question ?"     # retrieval + réponse FoundationModels (dans la langue de la question)
$BIN pause / resume            # stoppe / reprend l'indexation en capture
$BIN stats                     # nb de souvenirs + état pause
$BIN ready                     # état du modèle on-device (READY / en téléchargement)

# Always-on (daemon launchd) :
$BIN agent-install 1           # installe + lance la capture en service (relancé au login/crash)
$BIN agent-status              # l'agent tourne-t-il ?
$BIN agent-uninstall           # stoppe + retire le service

# Interface :
$BIN menubar                   # app barre de menus (compteur, pause, on/off always-on, log)

# Sorties JSON (consommées par l'UI web) :
$BIN list 50 0                 # souvenirs déchiffrés, du plus récent au plus ancien (limit, offset)
$BIN search "requête" 8        # top-k brut avec scores cosinus, sans génération
$BIN ask "question ?" 4        # réponse RAG + les sources exactes utilisées
```

## UI web locale (requête + anti-hallucination)

```bash
python3 ui/server.py           # -> http://127.0.0.1:7790
```

Dashboard local (aucune donnée ne sort de la machine) : question RAG avec réponse et
**sources OCR brutes côte à côte** (scores cosinus, citations `[n]` cliquables), bannière
« pertinence faible » quand aucune source ne dépasse 0,25, mode recherche pure (instantané),
et registre paginé des souvenirs déchiffrés. Le serveur shell-out vers le **binaire de dev**
(`.build/release/`) — jamais vers l'app figée de `~/Applications` (son grant TCC dépend du cdhash).

## Prérequis runtime (toggles, pas du code)

- **Génération RAG** : nécessite **Apple Intelligence activé** (Réglages → Apple Intelligence).
  Sinon `query` renvoie le top-k brut (fallback) au lieu d'une réponse rédigée.
- **Capture** : nécessite la permission **Enregistrement de l'écran** pour le terminal
  (déjà accordée ici — la capture a tourné).

## Pistes suivantes (restantes)

- **Index ANN** (sqlite-vec / HNSW) — seulement quand le volume dépasse la recherche brute-force
  (à ~10k+ souvenirs ; en dessous, le cosine linéaire est instantané, donc non prioritaire).
- **Dédup perceptuelle pHash** (DCT) si l'average-hash laisse passer trop de quasi-doublons en usage réel.
- **UI menubar** (pause/stats/recherche) au lieu du CLN.
- Activer **Apple Intelligence** pour la génération RAG complète (toggle Réglages, hors code).
