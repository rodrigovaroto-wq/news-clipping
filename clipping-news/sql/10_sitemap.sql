-- Oria Clipping — Camada de Sitemap/Indexacao (desacoplada do pipeline de curadoria)
-- Fonte de verdade PROPRIA do sitemap. SEM foreign key para published_news, por desenho:
-- mesma convencao das outras tabelas do projeto (raw_news/published_news/expired_news/
-- source_registry nao tem FK entre si). Falhas aqui nunca devem bloquear PUBLISH/EXPIRE.
-- Idempotente (create table if not exists / add column if not exists).
-- Sem funcoes com bloco $$...$$ novas: evita reintroduzir o bug de comentario com
-- parametro posicional (parametro 1, parametro 2) sendo confundido com delimitador de
-- bloco pelo SQL Editor do Supabase (ja corrigido uma vez neste projeto, ver sql/03).

create table if not exists sitemap_urls (
  news_id                      text primary key,
  url                          text not null unique,
  slug                         text not null,
  category                     text not null,
  status                       text not null default 'published'
                                 check (status in ('published','expired','deleted')),
  is_indexable                 boolean not null default true,
  published_at                 timestamptz not null,
  expires_at                   timestamptz not null,
  lastmod                      timestamptz not null,
  sitemap_included_at          timestamptz,
  search_console_submitted_at  timestamptz,
  created_at                   timestamptz not null default now(),
  updated_at                   timestamptz not null default now()
);

-- consulta quente do gerador de XML: quem esta indexavel e ainda dentro da validade
create index if not exists idx_sitemap_indexable
  on sitemap_urls (is_indexable, expires_at);
create index if not exists idx_sitemap_status
  on sitemap_urls (status);

-- updated_at automatico: reaproveita a MESMA funcao ja criada em 01_schema.sql
drop trigger if exists trg_sitemap_updated on sitemap_urls;
create trigger trg_sitemap_updated before update on sitemap_urls
  for each row execute function set_updated_at();

alter table sitemap_urls enable row level security;

-- ================= observabilidade (serie temporal de execucoes) =================
-- Nao misturar com sitemap_urls (que e ESTADO ATUAL, 1 linha por noticia).
create table if not exists sitemap_log (
  id                bigint generated always as identity primary key,
  run_type          text not null
                      check (run_type in ('sync_on_publish','reconcile_expired','gsc_submit')),
  ran_at            timestamptz not null default now(),
  url_count         integer,
  xml_hash          text,
  robots_hash       text,
  committed         boolean not null default false,
  gsc_submitted_at  timestamptz,
  divergence_count  integer,
  error_message     text
);
create index if not exists idx_sitemap_log_ran_at on sitemap_log (ran_at desc);
alter table sitemap_log enable row level security;

-- dashboard de 1 linha
create or replace view sitemap_status as
select
  (select max(ran_at) from sitemap_log
    where run_type in ('sync_on_publish','reconcile_expired'))                       as ultima_geracao_at,
  (select url_count from sitemap_log
    where committed = true order by ran_at desc limit 1)                             as ultimo_commit_url_count,
  (select xml_hash from sitemap_log
    where committed = true order by ran_at desc limit 1)                             as ultimo_commit_hash,
  (select max(gsc_submitted_at) from sitemap_log)                                     as ultima_submissao_gsc_at,
  (select count(*) from sitemap_urls
    where status = 'published' and is_indexable and expires_at > now())              as urls_indexaveis_agora,
  (select count(*) from published_news
    where publication_status = 'published')                                          as publicadas_vivas_agora,
  (select count(*) from published_news where publication_status = 'published') -
  (select count(*) from sitemap_urls
    where status = 'published' and is_indexable and expires_at > now())              as divergencia_agora;
