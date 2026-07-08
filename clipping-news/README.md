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
2. TRIAGE — dupla passada LLM (triagem + verificação) -> approved/rejected **+ `relevance_score` (core Oria + materialidade + autoridade da fonte)**
3. PUBLISH — **consolidação diária**: embedding 1536 -> dedup híbrido (embedding + trigrama + LLM na zona cinzenta) -> **ranqueia por score e publica só as 3 melhores do dia** -> captura página -> resumo -> GitHub -> published_news; encerra as demais aprovadas
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
sql/06_dedup_upgrade.sql      # relevance_score + pg_trgm + índices (rodar ANTES do 03)
sql/03_find_duplicate.sql     # find_duplicate_v2 (híbrido + zona cinzenta)
sql/04_source_registry_seed.sql
```
Depois: importar workflows/clipping.json no n8n e apontar a credencial Postgres.

## Seleção Top-3 do dia
A triagem agora atribui `relevance_score` (0.5·core Oria + 0.3·materialidade + 0.2·autoridade
da fonte). O PUBLISH roda **1x/dia** (cron `0 0 20 * * 1-5` — confira o timezone do n8n),
deduplica o lote inteiro e publica apenas as **3 de maior score**; as demais aprovadas são
encerradas (`rejected_nao_top3`).

## Dedup (3 camadas)
1. **Exato** — `source_url`/`news_id` unique.
2. **Intra-lote** — cosseno + trigrama de título no `CODE_PREP` (mantém a de maior score).
3. **Vs-publicado** — `find_duplicate_v2` (embedding + `pg_trgm`) com **zona cinzenta**: pares
   ambíguos vão ao `GPT-API_DEDUP` (LLM decide "mesmo evento?").

## Pendência atual
Calibrar os thresholds do dedup para 1536 dims com pares reais (ver
docs/DECISOES_E_APRENDIZADOS.md e sql/09_diagnostics.sql). Os defaults
(`sim_high=0.80`, `sim_low=0.62`, `trgm_high=0.55`) são conservadores; afine em **dois lugares**:
default da `find_duplicate_v2` (sql/03) e `SIM_COS`/`SIM_TRG` do `CODE_PREP`.
