-- Feeds RSS (config; nao se regenera sozinho)
insert into source_registry (source_name, rss_url, rss_active) values
  ('Brazil Journal', 'https://braziljournal.com/feed/', true),
  ('Exame', 'https://exame.com/feed/', true),
  ('NeoFeed', 'https://neofeed.com.br/feed/', true),
  ('Money Times', 'https://www.moneytimes.com.br/feed/', true),
  ('Valor', 'https://www.valor.com.br/rss', true),
  ('Capital Aberto', 'https://capitalaberto.com.br/feed/', true)
on conflict (source_name) do update
  set rss_url = excluded.rss_url, rss_active = excluded.rss_active;
