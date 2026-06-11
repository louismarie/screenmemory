"""
Convert the multilingual sentence embedder to CoreML (ANE), replicating the full
SentenceTransformer forward (transformer + pooling + dense + L2 normalize) so the
CoreML model outputs ready-to-use 512-d embeddings.

Model: distiluse-base-multilingual-cased-v2  (WordPiece *cased* tokenizer -> works
with our self-contained Swift tokenizer; multilingual incl. French).
"""
import numpy as np
import torch
import torch.nn as nn
import coremltools as ct
from sentence_transformers import SentenceTransformer

MODEL_ID = "distiluse-base-multilingual-cased-v2"
SEQ_LEN = 128
OUT = "ScreenMemory/Sources/ScreenMemory/Resources/Embed.mlpackage"
VOCAB_DIR = "ScreenMemory/Sources/ScreenMemory/Resources"


class STWrapper(nn.Module):
    """Pure-tensor replica of distiluse: DistilBERT -> mean pool -> Dense(768->512)+Tanh -> L2.
    Avoids SentenceTransformer's dict-based forward, which torch.export can't trace."""
    def __init__(self, st):
        super().__init__()
        self.bert = st[0].auto_model      # DistilBertModel
        self.linear = st[2].linear        # Linear(768, 512)
        self.act = st[2].activation_function  # Tanh

    def forward(self, input_ids, attention_mask):
        tokens = self.bert(input_ids=input_ids, attention_mask=attention_mask).last_hidden_state
        mask = attention_mask.unsqueeze(-1).to(tokens.dtype)
        mean = (tokens * mask).sum(1) / mask.sum(1).clamp(min=1e-9)
        dense = self.act(self.linear(mean))
        return nn.functional.normalize(dense, p=2, dim=1)


def main():
    print(f"Loading {MODEL_ID} ...")
    st = SentenceTransformer(MODEL_ID, device="cpu").eval()
    st.tokenizer.save_vocabulary(VOCAB_DIR)        # mBERT cased vocab.txt
    model = STWrapper(st).eval()

    ids = torch.randint(0, 1000, (1, SEQ_LEN), dtype=torch.long)
    mask = torch.ones((1, SEQ_LEN), dtype=torch.long)

    print("Exporting (torch.export) ...")
    with torch.no_grad():
        ep = torch.export.export(model, (ids, mask))
        ep = ep.run_decompositions({})

    print("Converting to CoreML (fp16) ...")
    ml = ct.convert(
        ep,
        inputs=[
            ct.TensorType(name="input_ids", shape=(1, SEQ_LEN), dtype=np.int32),
            ct.TensorType(name="attention_mask", shape=(1, SEQ_LEN), dtype=np.int32),
        ],
        outputs=[ct.TensorType(name="embedding")],
        compute_precision=ct.precision.FLOAT16,
        compute_units=ct.ComputeUnit.ALL,
        minimum_deployment_target=ct.target.macOS13,
    )
    ml.short_description = "distiluse-base-multilingual-cased-v2 sentence embedder (512-d, L2-normed)"
    ml.save(OUT)
    print(f"Saved -> {OUT}")


if __name__ == "__main__":
    main()
