-- Queries usadas dentro do PUBLISH (nodes Execute Query)

-- [GS_READ_APPROVED] leitura dos aprovados com teto diario de 25 (cruza runs)
select * from raw_news
where status = 'approved'
order by created_at
limit greatest(0, 25 - (
  select count(*) from published_news
  where (published_at at time zone 'America/Sao_Paulo')::date
      = (now() at time zone 'America/Sao_Paulo')::date
));

-- [DEDUP_CHECK] dedup vs-publicado (parametro = embedding string do CODE_PREP)
select exists (select 1 from find_duplicate($1::vector)) as is_dup;

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
