-- Queries usadas dentro do PUBLISH (nodes Execute Query)

-- [GS_READ_APPROVED] consolidação DIÁRIA: lê TODAS as aprovadas pendentes,
-- ordenadas por score (melhor primeiro). O Top-3 é aplicado depois do dedup,
-- no node LIMIT_BATCH (maxItems=3). Sem teto SQL — quem não entrar no Top-3
-- é encerrado no fim do run por GS_CLOSE_UNSELECTED.
select * from raw_news
where status = 'approved'
order by relevance_score desc, created_at;

-- [DEDUP_CHECK] dedup vs-publicado HÍBRIDO com zona cinzenta.
-- $1 = embedding (string ::vector) | $2 = headline (trigrama).
-- Retorna a zona e o texto do candidato (p/ o LLM adjudicar a zona cinzenta).
-- Se não houver linha, o item é único.
select
  coalesce((select zone from find_duplicate_v2($1::vector, $2) limit 1), 'none') as zone,
  (select dup_news_id   from find_duplicate_v2($1::vector, $2) limit 1)           as dup_news_id,
  (select similaridade  from find_duplicate_v2($1::vector, $2) limit 1)           as similaridade,
  (select cand_headline from find_duplicate_v2($1::vector, $2) limit 1)           as cand_headline,
  (select cand_summary  from find_duplicate_v2($1::vector, $2) limit 1)           as cand_summary;

-- [GS_CLOSE_UNSELECTED] fecha as aprovadas que NÃO entraram no Top-3 do dia,
-- para não competirem (stale) no dia seguinte. Roda no fim do PUBLISH, depois
-- que as publicadas já viraram status='published'.
update raw_news
set status = 'rejected', qa_flags = 'rejected_nao_top3'
where status = 'approved';

-- [GS_APPEND_PUBLISHED] insert com cast, parametros como ARRAY ordenado unico:
-- {{ [news_id, headline_oria, summary_oria, summary_full, slug, file_path,
--     source_url, image_url, source_name, category, publication_status,
--     published_at, embedding] }}
insert into published_news (
  news_id, headline_oria, summary_oria, summary_full, slug, file_path,
  source_url, image_url, source_name, category, publication_status,
  published_at, embedding
) values ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12::timestamptz,$13::vector)
on conflict (news_id) do update set
  headline_oria=excluded.headline_oria, summary_oria=excluded.summary_oria,
  summary_full=excluded.summary_full, slug=excluded.slug, file_path=excluded.file_path,
  source_url=excluded.source_url, image_url=excluded.image_url,
  source_name=excluded.source_name, category=excluded.category,
  publication_status=excluded.publication_status, published_at=excluded.published_at,
  embedding=excluded.embedding;
