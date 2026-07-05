# Oria Clipping — Inteligência de Notícias Institucional

Pipeline n8n + Supabase (Postgres + pgvector) que coleta notícias financeiras (PT-BR),
tria por LLM, deduplica por embedding e publica no site institucional da Oria Partners
(reestruturação, M&A, special situations) via markdown no GitHub.

## Estrutura
```
clipping-news/
├── workflows/clipping.json   # workflow n8n (cole o seu export aqui)
├── prompts/                  # prompts LLM (triagem, verifica, resumo) + embedding
├── sql/                      # schema, índice HNSW, find_duplicate, seeds, queries, diagnóstico
├── docs/                     # fluxo completo, decisões/aprendizados, contexto p/ Claude Code
└── README.md
```

## Os 5 pipelines
1. INGEST — RSS -> normaliza -> filtra existentes -> raw_news -> peneira keyword
2. TRIAGE — dupla passada LLM (triagem + verificação) -> approved/rejected
3. PUBLISH — embedding 1536 -> dedup híbrido -> captura página -> resumo -> GitHub -> published_news
4. EXPIRE — remove antigas do site -> expired_news
5. LIMPEZA_EMB — limpa embeddings antigos (provavelmente obsoleto com pgvector)

## Stack
- n8n 2.27.4 (PikaPods)
- Supabase: Postgres + pgvector 0.8.2 (índice HNSW cosseno)
- OpenAI: gpt-4o-mini (triagem/verifica/resumo) + text-embedding-3-small (1536 dims)
- GitHub (markdown) -> Lovable/Netlify (site)

## Setup do banco (ordem)
```
sql/01_schema.sql
sql/02_index_hnsw.sql
sql/03_find_duplicate.sql
sql/04_source_registry_seed.sql
```
Depois: importar workflows/clipping.json no n8n e apontar a credencial Postgres.

## Pendência atual
Calibrar o threshold de similaridade para 1536 dims (ver docs/DECISOES_E_APRENDIZADOS.md
e sql/09_diagnostics.sql). É o que falta para o dedup intra-lote barrar duplicatas
como o par s_54/s_56 (mesmo leilão, fontes diferentes).
