"""Validate a multilingual embedding model on French retrieval before wiring it into Swift."""
import numpy as np
from sentence_transformers import SentenceTransformer

m = SentenceTransformer("distiluse-base-multilingual-cased-v2")

docs = [
    "Réunion budget Q3 : valider l'enveloppe marketing de 45000 euros avec Sophie avant vendredi.",
    "Bug ticket ENG-2231 : le panier se vide quand l'utilisateur change de devise EUR vers USD.",
    "Recette tarte aux pommes : 6 pommes, 200g de farine, 100g de beurre, cuisson 35 min à 180°C.",
]
queries = [
    "combien je peux dépenser en publicité ce trimestre ?",
    "quel est le problème signalé sur le paiement ?",
    "comment faire un dessert aux fruits ?",
]
D = m.encode(docs, normalize_embeddings=True)
Q = m.encode(queries, normalize_embeddings=True)
labels = ["BUDGET", "BUG", "RECETTE"]
print(f"dim = {D.shape[1]}\n")
for qi, q in enumerate(queries):
    sims = D @ Q[qi]
    order = np.argsort(-sims)
    print(f"Q: {q}")
    for r in order:
        print(f"   {sims[r]:+.3f}  {labels[r]}")
    print(f"   -> top: {labels[order[0]]}\n")
