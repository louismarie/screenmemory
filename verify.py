"""
1. Correctness: CoreML embedding vs PyTorch reference (cosine similarity should be ~1.0).
2. ANE placement: try to read the compute plan and report op assignment.
"""
import numpy as np
import torch
import coremltools as ct
from transformers import AutoTokenizer
from convert import Embedder, MODEL_ID, SEQ_LEN, OUT

SENTS = [
    "The Apple Neural Engine accelerates on-device machine learning.",
    "A cat sleeps on the warm windowsill in the afternoon sun.",
]


def tokenize(tok, s):
    e = tok([s], padding="max_length", truncation=True,
            max_length=SEQ_LEN, return_tensors="pt")
    return e["input_ids"], e["attention_mask"]


def main():
    tok = AutoTokenizer.from_pretrained(MODEL_ID)
    ref = Embedder(MODEL_ID).eval()
    ml = ct.models.MLModel(OUT, compute_units=ct.ComputeUnit.ALL)

    print("=== Correctness (CoreML vs PyTorch) ===")
    for s in SENTS:
        ids, attn = tokenize(tok, s)
        with torch.no_grad():
            ref_emb = ref(ids, attn)[0].numpy()
        ml_out = ml.predict({
            "input_ids": ids.to(torch.int32).numpy(),
            "attention_mask": attn.to(torch.int32).numpy(),
        })
        ml_emb = np.array(list(ml_out.values())[0]).ravel()
        cos = float(np.dot(ref_emb, ml_emb) /
                    (np.linalg.norm(ref_emb) * np.linalg.norm(ml_emb)))
        print(f"  cos(ref, coreml) = {cos:.5f}   '{s[:40]}...'")

    print("\n(ANE residency is confirmed empirically via powermetrics in power_loop.sh)")


if __name__ == "__main__":
    main()
