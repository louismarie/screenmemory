"""
Convert an open sentence-embedding model to a CoreML .mlpackage targeting the ANE.

Model: sentence-transformers/all-MiniLM-L6-v2 (~22M params, 384-dim embeddings).
The exported graph includes mean-pooling + L2 normalization, so the CoreML model
outputs ready-to-use embeddings directly (no post-processing needed at query time).

Output: MiniLM.mlpackage  (fp16, fixed sequence length for ANE-friendliness).
"""
import numpy as np
import torch
import torch.nn as nn
import coremltools as ct
from transformers import AutoModel, AutoTokenizer

MODEL_ID = "sentence-transformers/all-MiniLM-L6-v2"
SEQ_LEN = 128          # fixed length -> ANE prefers static shapes
OUT = "MiniLM.mlpackage"


class Embedder(nn.Module):
    """BERT encoder + masked mean pooling + L2 normalize -> sentence embedding."""

    def __init__(self, model_id):
        super().__init__()
        self.bert = AutoModel.from_pretrained(model_id)

    def forward(self, input_ids, attention_mask):
        out = self.bert(input_ids=input_ids, attention_mask=attention_mask)
        tokens = out.last_hidden_state                       # (B, S, H)
        mask = attention_mask.unsqueeze(-1).to(tokens.dtype)  # (B, S, 1)
        summed = (tokens * mask).sum(dim=1)                   # (B, H)
        counts = mask.sum(dim=1).clamp(min=1e-9)              # (B, 1)
        mean = summed / counts
        return nn.functional.normalize(mean, p=2, dim=1)      # (B, H)


def main():
    print(f"Loading {MODEL_ID} ...")
    tok = AutoTokenizer.from_pretrained(MODEL_ID)
    model = Embedder(MODEL_ID).eval()

    ex = tok(["benchmark sentence for tracing"],
             padding="max_length", truncation=True,
             max_length=SEQ_LEN, return_tensors="pt")
    input_ids = ex["input_ids"].to(torch.long)        # embedding lookup wants long
    attn = ex["attention_mask"].to(torch.long)

    print("Exporting (torch.export) ...")
    with torch.no_grad():
        exported = torch.export.export(model, (input_ids, attn))
        exported = exported.run_decompositions({})   # TRAINING -> ATEN dialect

    print("Converting to CoreML (fp16) ...")
    mlmodel = ct.convert(
        exported,
        inputs=[
            ct.TensorType(name="input_ids", shape=(1, SEQ_LEN), dtype=np.int32),
            ct.TensorType(name="attention_mask", shape=(1, SEQ_LEN), dtype=np.int32),
        ],
        outputs=[ct.TensorType(name="embedding")],
        compute_precision=ct.precision.FLOAT16,
        compute_units=ct.ComputeUnit.ALL,
        minimum_deployment_target=ct.target.macOS13,
    )
    mlmodel.short_description = "all-MiniLM-L6-v2 sentence embedder (mean-pooled, L2-normed)"
    mlmodel.save(OUT)
    print(f"Saved -> {OUT}")


if __name__ == "__main__":
    main()
