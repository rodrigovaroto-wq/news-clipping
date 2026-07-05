# Embedding (dedup semântico)

- **Node n8n:** `EMBENDDING` (HTTP → OpenAI /v1/embeddings)
- **Modelo:** text-embedding-3-small
- **Dimensões:** 1536  (era 256; recalibrar threshold ao mudar)
- **Entra:** `headline_original + summary_original[:300]`
- **Sai:** vetor de 1536 floats

## Body
```json
{
  "model": "text-embedding-3-small",
  "input": {{ JSON.stringify(($json.headline_original || '') + ' ' + ($json.summary_original || '').slice(0, 300)) }},
  "dimensions": 1536
}
```
