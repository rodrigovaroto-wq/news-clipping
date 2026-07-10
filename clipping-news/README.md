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

## Seleção Top-3 do dia (curadoria rígida)
A triagem atribui `relevance_score` de **conteúdo** (`0.6·core Oria + 0.4·materialidade`, 0–100),
independente da fonte. O PUBLISH roda **1x/dia** às **07:00 BRT** (cron `0 0 7 * * 1-5`; workflow com
`timezone=America/Sao_Paulo`), deduplica o lote e publica **no máximo 3**, aplicando um
**gate rígido: só publica com `relevance_score >= 80`** (evento corporativo indiscutível com o qual
o cliente da Oria se identifica). Empate desfeito por autoridade da fonte. Dias fracos publicam
menos de 3 (ou 0) — é o custo da curadoria. As demais aprovadas são encerradas (`rejected_nao_top3`).

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
