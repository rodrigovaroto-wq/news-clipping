-- Oria Clipping — Schema Postgres (Supabase) + RLS + triggers
create extension if not exists vector;

-- raw_news
create table if not exists raw_news (
  news_id             text primary key,
  status              text not null default 'pending'
                        check (status in ('pending','triagem_llm','rejected','approved','published')),
  qa_flags            text default '',
  "_segue"            boolean,
  source_name         text,
  source_url          text unique,
  image_url           text,
  headline_original   text,
  summary_original    text,
  raw_content         text,
  primary_tag         text,
  published_source_at timestamptz,
  collected_at        timestamptz,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

-- published_news
create table if not exists published_news (
  news_id             text primary key,
  headline_oria       text not null,
  summary_oria        text,
  summary_full        text,
  slug                text unique,
  file_path           text,
  source_url          text unique,
  image_url           text,
  source_name         text,
  category            text,
  publication_status  text not null default 'published'
                        check (publication_status in ('published','expired')),
  published_at        timestamptz not null,
  expired_at          timestamptz,
  embedding           vector(1536),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
create index if not exists idx_pub_published_at on published_news (published_at);

-- expired_news
create table if not exists expired_news (
  news_id       text primary key,
  headline_oria text not null,
  summary_oria  text,
  slug          text,
  file_path     text,
  source_url    text,
  source_name   text,
  category      text,
  published_at  timestamptz,
  expired_at    timestamptz
);

-- source_registry
create table if not exists source_registry (
  source_name text primary key,
  rss_url     text not null,
  rss_active  boolean not null default true
);

-- updated_at automatico (auditoria)
create or replace function set_updated_at() returns trigger as $$
begin new.updated_at = now(); return new; end;
$$ language plpgsql;

drop trigger if exists trg_raw_updated on raw_news;
create trigger trg_raw_updated before update on raw_news
  for each row execute function set_updated_at();
drop trigger if exists trg_pub_updated on published_news;
create trigger trg_pub_updated before update on published_news
  for each row execute function set_updated_at();

-- RLS (trava chaves publicas; n8n via conexao direta ignora)
alter table raw_news        enable row level security;
alter table published_news  enable row level security;
alter table expired_news    enable row level security;
alter table source_registry enable row level security;
