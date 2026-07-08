# Embedding (dedup semântico)

- **Node n8n:** `EMBENDDING` (HTTP → OpenAI /v1/embeddings)
- **Modelo:** text-embedding-3-small
- **Dimensões:** 1536  (era 256; recalibrar threshold ao mudar)
- **Entra:** `headline_original + summary_original[:700]`, espaços normalizados
- **Sai:** vetor de 1536 floats

> O input mais longo e normalizado dá ao embedding mais contexto do EVENTO (empresas,
> valores, ato), melhorando a captura de duplicatas de fontes diferentes.

## Body
```json
{
  "model": "text-embedding-3-small",
  "input": {{ JSON.stringify((($json.headline_original || '') + ' ' + ($json.summary_original || '').slice(0, 700)).replace(/\s+/g, ' ').trim()) }},
  "dimensions": 1536
}
```
