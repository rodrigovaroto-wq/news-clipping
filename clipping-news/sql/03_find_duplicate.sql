-- Dedup vs-publicado. Retorna a publicada mais similar dentro da janela,
-- se >= threshold. Chamada no node DEDUP_CHECK: find_duplicate($1::vector)
-- ATENCAO: sim_threshold calibrado para 256 dims. RECALIBRAR para 1536.
create or replace function find_duplicate(
  q_embedding vector(1536),
  sim_threshold float default 0.82,   -- <<< recalibrar para 1536
  janela_dias int default 3
)
returns table (dup_news_id text, similaridade float)
language sql stable as $$
  select news_id, 1 - (embedding <=> q_embedding) as similaridade
  from published_news
  where publication_status = 'published'
    and embedding is not null
    and published_at >= now() - (janela_dias || ' days')::interval
    and 1 - (embedding <=> q_embedding) >= sim_threshold
  order by embedding <=> q_embedding
  limit 1;
$$;
