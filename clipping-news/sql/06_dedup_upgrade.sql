-- Oria Clipping — Upgrade do dedup + coluna de score de triagem
-- Rodar UMA vez no Supabase, ANTES da nova sql/03_find_duplicate.sql.
-- Idempotente (if not exists / add column if not exists).

-- 1) Score de relevância Oria (usado no ranking Top-3 do PUBLISH)
--    Composto em CODE_RESOLVE: 0.5*score_core + 0.3*score_materialidade + 0.2*100*source_tier
alter table raw_news
  add column if not exists relevance_score numeric not null default 0;

-- índice para o order by relevance_score desc do GS_READ_APPROVED
create index if not exists idx_raw_relevance_score
  on raw_news (relevance_score desc);

-- 2) Camada lexical do dedup (trigrama de título)
--    Captura duplicatas de título quase idêntico que o embedding sozinho deixa passar.
create extension if not exists pg_trgm;

-- índice GIN de trigrama no título editorial das publicadas (acelera similarity())
create index if not exists idx_pub_headline_trgm
  on published_news using gin (headline_oria gin_trgm_ops);
