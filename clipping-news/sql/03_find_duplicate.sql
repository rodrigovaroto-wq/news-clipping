-- Dedup vs-publicado HÍBRIDO (embedding + lexical) com ZONA CINZENTA.
-- Retorna o melhor candidato publicado dentro da janela e classifica a "zona":
--   zone='high'  -> duplicata automática (cosseno alto OU trigrama de título alto)
--   zone='gray'  -> ambíguo, vai para adjudicação por LLM (node GPT-API_DEDUP)
--   (sem linha)  -> único, segue publicação
--
-- Chamada no node DEDUP_CHECK: find_duplicate_v2(embedding::vector, headline)
--   parametro 1 = embedding | parametro 2 = headline (para o trigrama)
--
-- ATENÇÃO: defaults conservadores para 1536 dims. RECALIBRAR com sql/09_diagnostics.sql
-- (medir cosseno/trgm de pares duplicados reais vs pares distintos) e ajustar aqui
-- E no SIM_THRESHOLD do CODE_PREP (intra-lote).

-- mantemos o nome antigo removido para evitar chamada obsoleta
drop function if exists find_duplicate(vector, float, int);

create or replace function find_duplicate_v2(
  q_embedding  vector(1536),
  q_headline   text  default '',
  sim_high     float default 0.80,   -- cosseno >= -> duplicata automática
  sim_low      float default 0.62,   -- cosseno >= (e < high) -> zona cinzenta (LLM)
  trgm_high    float default 0.55,   -- similaridade de título >= -> duplicata automática
  janela_dias  int   default 5       -- eventos costumam ser re-reportados em poucos dias
)
returns table (
  dup_news_id  text,
  similaridade float,
  trgm         float,
  zone         text,
  cand_headline text,
  cand_summary  text
)
language sql stable as $$
  with scored as (
    select
      p.news_id,
      1 - (p.embedding <=> q_embedding)                                as sim,
      case when coalesce(q_headline,'') = '' then 0
           else similarity(p.headline_oria, q_headline) end            as trg,
      p.headline_oria,
      p.summary_oria
    from published_news p
    where p.publication_status = 'published'
      and p.embedding is not null
      and p.published_at >= now() - (janela_dias || ' days')::interval
  ),
  ranked as (
    select *,
      case
        when sim >= sim_high or trg >= trgm_high then 'high'
        when sim >= sim_low                       then 'gray'
        else 'none'
      end as zone
    from scored
    where sim >= sim_low or trg >= trgm_high   -- descarta claramente distintos
  )
  select news_id, sim, trg, zone, headline_oria, summary_oria
  from ranked
  order by greatest(sim, trg) desc          -- melhor candidato primeiro
  limit 1;
$$;
