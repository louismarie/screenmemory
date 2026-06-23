"""Validate multilingual embedding retrieval with fixtures stored in the i18n catalog."""
import json
from pathlib import Path

import numpy as np
from sentence_transformers import SentenceTransformer


CATALOG = Path(__file__).parent / "ScreenMemory" / "Sources" / "ScreenMemory" / "Resources" / "i18n" / "fr.json"


def load_fixture(key):
    with CATALOG.open(encoding="utf-8") as handle:
        data = json.load(handle)
    values = data.get(key, [])
    if not isinstance(values, list) or not all(isinstance(item, str) for item in values):
        raise ValueError(f"missing string-array fixture: {key}")
    return values


model = SentenceTransformer("distiluse-base-multilingual-cased-v2")

docs = load_fixture("embeddingValidation.docs")
queries = load_fixture("embeddingValidation.queries")
labels = load_fixture("embeddingValidation.labels")

D = model.encode(docs, normalize_embeddings=True)
Q = model.encode(queries, normalize_embeddings=True)

print(f"dim = {D.shape[1]}\n")
for qi, q in enumerate(queries):
    sims = D @ Q[qi]
    order = np.argsort(-sims)
    print(f"Q: {q}")
    for r in order:
        print(f"   {sims[r]:+.3f}  {labels[r]}")
    print(f"   -> top: {labels[order[0]]}\n")
