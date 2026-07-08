-- Diagnostico e CALIBRACAO (1536 dims + dedup híbrido)

-- ============ SAÚDE DO PIPELINE ============
select status, count(*) from raw_news group by status order by count(*) desc;

-- coerencia _segue x status
select status, "_segue", count(*) from raw_news group by status, "_segue" order by status;

-- distribuição do score de triagem (sanidade do ranking Top-3)
select
  count(*) filter (where status='approved')                       as aprovadas,
  round(avg(relevance_score) filter (where status='approved'),1)  as score_medio,
  max(relevance_score) filter (where status='approved')           as score_max,
  min(relevance_score) filter (where status='approved')           as score_min
from raw_news;

-- publicadas com embedding preenchido
select count(*) total, count(*) filter (where embedding is not null) com_emb
from published_news;

-- ============ CALIBRAÇÃO DO THRESHOLD (1536) ============
-- Objetivo: achar sim_high / sim_low / trgm_high que separem DUPLICATA de DISTINTO.
-- Rodar sobre publicadas reais e olhar onde as distribuições se separam.

-- 1) Distribuição de cosseno entre TODOS os pares recentes (piso de ruído + cauda alta).
--    A cauda alta (p95/p99) indica onde moram as duplicatas; a mediana, o ruído.
with pares as (
  select 1 - (a.embedding <=> b.embedding) as sim
  from published_news a
  join published_news b
    on a.news_id < b.news_id
   and b.published_at >= now() - interval '7 days'
  where a.embedding is not null and b.embedding is not null
    and a.published_at >= now() - interval '7 days'
)
select
  round(avg(sim)::numeric,3)                                        as media,
  round((percentile_cont(0.50) within group (order by sim))::numeric,3) as p50,
  round((percentile_cont(0.90) within group (order by sim))::numeric,3) as p90,
  round((percentile_cont(0.95) within group (order by sim))::numeric,3) as p95,
  round((percentile_cont(0.99) within group (order by sim))::numeric,3) as p99,
  round(max(sim)::numeric,3)                                        as maximo
from pares;

-- 2) Pareamento de título (trigrama) — mesma ideia para a camada lexical.
with pares as (
  select similarity(a.headline_oria, b.headline_oria) as trg
  from published_news a
  join published_news b
    on a.news_id < b.news_id
   and b.published_at >= now() - interval '7 days'
  where a.published_at >= now() - interval '7 days'
)
select
  round((percentile_cont(0.90) within group (order by trg))::numeric,3) as p90,
  round((percentile_cont(0.99) within group (order by trg))::numeric,3) as p99,
  round(max(trg)::numeric,3)                                            as maximo
from pares;

-- 3) Par DUPLICADO conhecido (ajuste os news_id): esperado cosseno alto + trgm alto.
select
  1 - (a.embedding <=> b.embedding)             as sim_duplicata,
  similarity(a.headline_oria, b.headline_oria)  as trgm_duplicata
from published_news a, published_news b
where a.news_id = 'NEWS_8999_s_54' and b.news_id = 'NEWS_8999_s_56';

-- 4) Par DISTINTO conhecido (piso de ruído): esperado cosseno/trgm baixos.
select
  1 - (a.embedding <=> b.embedding)             as sim_distintas,
  similarity(a.headline_oria, b.headline_oria)  as trgm_distintas
from published_news a, published_news b
where a.news_id = 'NEWS_8999_s_54' and b.news_id = 'NEWS_8999_s_1';

-- REGRA PRÁTICA: sim_high ~ entre p99-dos-pares e o cosseno_duplicata;
--                sim_low  ~ acima do p90-dos-pares (ruído), abaixo do cosseno_duplicata;
--                trgm_high ~ acima do p99-de-título. Atualizar em DOIS lugares:
--                default de find_duplicate_v2 (sql/03) e SIM_THRESHOLD do CODE_PREP.
