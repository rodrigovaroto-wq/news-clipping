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

## Os 6 pipelines
1. INGEST — RSS -> normaliza -> filtra existentes -> raw_news -> peneira keyword
2. TRIAGE — dupla passada LLM (triagem + verificação) -> approved/rejected **+ `relevance_score` (core Oria + materialidade + autoridade da fonte)**
3. PUBLISH — **consolidação diária**: embedding 1536 -> dedup híbrido (embedding + trigrama + LLM na zona cinzenta) -> **ranqueia por score e publica só as 3 melhores do dia** -> captura página -> resumo -> GitHub -> published_news; encerra as demais aprovadas -> **sync_on_publish** registra a URL no sitemap
4. EXPIRE — remove antigas do site -> expired_news -> gancho imediato zera a URL do sitemap
5. LIMPEZA_EMB — limpa embeddings antigos (provavelmente obsoleto com pgvector)
6. SITEMAP/INDEXAÇÃO — `reconcile_expired_news` (a cada 12min) mantém `news-sitemap.xml`/`robots.txt` sincronizados no repo do site; submissão ao Search Console pronta mas desativada (ver docs/FLUXO_COMPLETO.md)

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
sql/10_sitemap.sql            # sitemap_urls + sitemap_log + view sitemap_status
```
Depois: importar workflows/clipping.json no n8n, apontar a credencial Postgres e configurar a
variável de ambiente n8n `SITE_BASE_URL` (ex.: `https://oriapartners.com`; fallback embutido nos
nós caso não seja definida).

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

## Sitemap/indexação (camada desacoplada, pós-publicação)
Tabela própria `sitemap_urls` (sem FK para `published_news`) registra a URL pública de cada
notícia (`https://{SITE_BASE_URL}/noticias/{categoria}/{slug}`). Dois workflows mantêm o
`public/news-sitemap.xml`/`public/robots.txt` do repo do site sempre em dia:
- **sync_on_publish** — anexado ao fim do PUBLISH: grava a URL nova e regenera o sitemap.
- **reconcile_expired_news** — cron a cada 12min: remove URLs vencidas (30 dias) ou já expiradas
  no EXPIRE, e regenera o sitemap. Um gancho leve no EXPIRE já zera a indexação quase na hora.

Só commita no GitHub quando o conteúdo realmente muda (hash comparado em `sitemap_log`).
Submissão automática ao Google Search Console já está construída mas **desativada** (falta
credencial OAuth2) — ver sticky note no workflow e `docs/FLUXO_COMPLETO.md`.

## Pendência atual
Calibrar os thresholds do dedup para 1536 dims com pares reais (ver
docs/DECISOES_E_APRENDIZADOS.md e sql/09_diagnostics.sql). Os defaults
(`sim_high=0.80`, `sim_low=0.62`, `trgm_high=0.55`) são conservadores; afine em **dois lugares**:
default da `find_duplicate_v2` (sql/03) e `SIM_COS`/`SIM_TRG` do `CODE_PREP`.
