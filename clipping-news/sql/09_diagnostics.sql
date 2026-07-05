-- Diagnostico e calibracao

-- saude do pipeline
select status, count(*) from raw_news group by status order by count(*) desc;

-- coerencia _segue x status
select status, "_segue", count(*) from raw_news group by status, "_segue" order by status;

-- publicadas com embedding preenchido
select count(*) total, count(*) filter (where embedding is not null) com_emb
from published_news;

-- CALIBRACAO: similaridade de um par DUPLICADO real (ajuste os news_id)
select 1 - (a.embedding <=> b.embedding) as sim_duplicata
from published_news a, published_news b
where a.news_id = 'NEWS_8999_s_54' and b.news_id = 'NEWS_8999_s_56';

-- CALIBRACAO: similaridade de pares DISTINTOS (piso de ruido)
select 1 - (a.embedding <=> b.embedding) as sim_distintas
from published_news a, published_news b
where a.news_id = 'NEWS_8999_s_54' and b.news_id = 'NEWS_8999_s_1';
