# Oria Clipping — Fluxo Completo (node por node)

> Estado descrito: arquitetura vigente (Supabase/Postgres + pgvector, com o dedup híbrido do Passo D).
> O JSON em disco é anterior às mudanças de canvas; esta descrição reflete o desenho atual construído.
> Para auditoria exata, reexporte o workflow do n8n.

O sistema são **5 pipelines independentes**, cada um com seu próprio gatilho (schedule):
INGEST, TRIAGE, PUBLISH, EXPIRE e LIMPEZA_EMB. Todos leem/escrevem nas 4 tabelas do Supabase.

Convenção abaixo: **Recebe** = o que chega no input do node; **Envia** = o que sai para o próximo.

---

## Camada de dados (Supabase)

- **raw_news** — pool bruto. Colunas-chave: `news_id` (PK), `status` (pending→triagem_llm→approved/rejected→published), `qa_flags` (motivo+justificativa), `_segue` (bool: true=passou triagem, false=barrada triagem, null=barrada keyword), `source_url` (unique), textos originais, datas.
- **published_news** — publicadas. `news_id` (PK), textos editoriais da Oria, `slug`, `file_path`, `publication_status` (published/expired), `published_at` (timestamptz), `embedding` (**vector(1536)**), `source_url` (unique). Índice **HNSW** cosseno em `embedding`.
- **expired_news** — arquivo das que saíram do site.
- **source_registry** — feeds RSS (`source_name`, `rss_url`, `rss_active`).
- **Função `find_duplicate(embedding, sim_threshold=0.82, janela_dias=3)`** — retorna a publicada mais similar dentro da janela, se acima do limiar. É o dedup vs-publicado.

---

## PIPELINE 1 — INGEST (coleta e peneira keyword)

Coleta os RSS, normaliza, remove o que já existe, grava no pool bruto e aplica a peneira de palavras-chave.

| Node | Tipo | Função | Recebe | Envia |
|------|------|--------|--------|-------|
| **TRIGGER_INGEST** | Schedule | Dispara a coleta periodicamente | — | aciona GS_READ_SOURCES e GS_READ_RECENT |
| **GS_READ_SOURCES** | Postgres Select | Lê todos os feeds da `source_registry` | trigger | lista de fontes → CODE_BUILD_FEEDS |
| **GS_READ_RECENT** | Postgres Select | Lê `raw_news` existente (referência p/ dedup de entrada). Ramo paralelo, consultado por nome | trigger | (referência via `$('GS_READ_RECENT')`) |
| **CODE_BUILD_FEEDS** | Code | Filtra `rss_active=true` e monta a lista de URLs de feed | fontes | feeds ativos → LOOP_FEEDS |
| **LOOP_FEEDS** | Split in Batches | Itera feed a feed | feeds | um feed por vez → RSS_READ |
| **RSS_READ** | RSS Read | Baixa os itens do feed RSS | 1 feed | notícias cruas → CODE_NORMALIZE |
| **CODE_NORMALIZE** | Code | Padroniza cada item ao schema `raw_news`: gera `news_id`, `status='pending'`, `qa_flags=''`, normaliza datas, extrai link/imagem | itens crus | itens normalizados → CODE_FILTER_EXISTING |
| **CODE_FILTER_EXISTING** | Code | Descarta o que já existe, comparando contra `$('GS_READ_RECENT')` (por `news_id`/URL) — dedup camada 1 (exato) | normalizados | apenas os novos → GS_APPEND_RAW |
| **GS_APPEND_RAW** | Postgres Upsert | Insere os novos em `raw_news` (conflito em `news_id` = idempotente) | novos | itens gravados → KEYWORD_PENEIRA |
| **KEYWORD_PENEIRA** | Code | Peneira por palavras-chave: aprova→`status='triagem_llm'`; reprova→`status='rejected'`, `qa_flags='rejected_keyword'` | gravados | decisão por item → GS_UPDATE_RAW1 |
| **GS_UPDATE_RAW1** | Postgres Update | Persiste `status`/`qa_flags` da peneira (match `news_id`) | decisões | — (fim do INGEST) |

Resultado: `raw_news` populado; itens promissores ficam `triagem_llm`, o resto `rejected` (keyword).

---

## PIPELINE 2 — TRIAGE (dupla triagem LLM)

Pega os `triagem_llm`, faz triagem + verificação por LLM e decide aprovado/rejeitado.

| Node | Tipo | Função | Recebe | Envia |
|------|------|--------|--------|-------|
| **TRIGGER_TRIAGE** | Schedule | Dispara a triagem | — | GS_READ-raw_news |
| **GS_READ-raw_news** | Postgres Select | Lê `raw_news` onde `status='triagem_llm'` | trigger | candidatos → LOOP |
| **LOOP** | Split in Batches | Processa item a item (e recebe o retorno do update para continuar) | candidatos / GS_UPDATE-raw_news | 1 item → GPT-API_TRIAGEM |
| **GPT-API_TRIAGEM** | HTTP (OpenAI) | 1ª passada: classifica relevância/categoria (prompt v6, corta compilados) | 1 item | resposta LLM → CODE_VALIDA_SCHEMA |
| **CODE_VALIDA_SCHEMA** | Code | Valida o JSON da LLM; define `_cat_triagem`, `_just_triagem`, `_segue`, `status`, `qa_flags` | resposta | item avaliado → If |
| **If** | If | Roteia: `_segue=true` → verificação; `false` → grava rejeição direto | avaliado | true→GPT-API_VERIFICA / false→GS_UPDATE-raw_news |
| **GPT-API_VERIFICA** | HTTP (OpenAI) | 2ª passada: confirma relevância e categoria (reduz falso-positivo) | itens `_segue=true` | verificação → CODE_RESOLVE |
| **CODE_RESOLVE** | Code | Decisão final determinística: `approved` ou `rejected` (verifica), fixa `_segue=true`, categoria final, `qa_flags` | verificação | decisão → GS_UPDATE-raw_news |
| **GS_UPDATE-raw_news** | Postgres Update | Persiste a decisão da triagem (match `news_id`) e devolve o controle ao LOOP | decisões | → LOOP (próximo item) |

Resultado: candidatos viram `approved` (prontos p/ publicar) ou `rejected` (triagem/verifica).

---

## PIPELINE 3 — PUBLISH (dedup + captura + resumo + publicação)

O coração. Pega os `approved`, gera embedding, **deduplica (híbrido)**, captura a página, resume, publica no GitHub e grava em `published_news`.

### Parte A — seleção e dedup

| Node | Tipo | Função | Recebe | Envia |
|------|------|--------|--------|-------|
| **TRIGGER_PUBLISH** | Schedule | Cron `0 30 5-23 * * 1-5` (de hora em hora, 5h30–23h30, seg–sex) | — | GS_READ_APPROVED |
| **GS_READ_APPROVED** | Postgres Execute Query | Lê `status='approved'` **com teto diário de 25** aplicado no SQL (`limit 25 - publicadas_hoje`) | trigger | aprovados (dentro da cota) → EMBENDDING e Merge |
| **EMBENDDING** | HTTP (OpenAI) | Gera embedding **1536 dims** de `headline_original + summary_original[:300]` | aprovados | vetores → Merge |
| **Merge** | Merge (Combine by Position) | Rejunta cada item com seu embedding (o HTTP substitui o item, por isso o merge) | aprovados + vetores | item+embedding → CODE_PREP |
| **CODE_PREP** | Code | **Dedup intra-lote** (cosseno em JS entre itens do mesmo run — pega duplicatas da mesma rodada) + moldagem do item (`headline`, `summary`, `srcurl`, `embedding` como string, etc.) | item+embedding | itens únicos-no-lote → DEDUP_CHECK e MERGE_DEDUP |
| **DEDUP_CHECK** | Postgres Execute Query | **Dedup vs-publicado**: `find_duplicate($1::vector)` → `is_dup` (true se já existe similar publicado na janela) | itens | `is_dup` → MERGE_DEDUP |
| **MERGE_DEDUP** | Merge (Combine by Position) | Rejunta `is_dup` ao item completo | itens + is_dup | item+is_dup → IF |
| **IF** | If | `is_dup=false` → segue (único); `true` → descarta (duplicata de algo já publicado) | item+is_dup | true→HTTP_FETCH_PAGE / false→✕ |

> **Por que dedup em dois lugares:** `find_duplicate` só compara contra o que já está publicado. Duas notícias do mesmo evento no **mesmo run** ainda não estão no banco — quem as pega é o dedup intra-lote em JS do CODE_PREP.

### Parte B — captura, resumo e publicação

| Node | Tipo | Função | Recebe | Envia |
|------|------|--------|--------|-------|
| **HTTP_FETCH_PAGE** | HTTP | Baixa o HTML da página original da notícia | itens únicos | HTML → CODE_OGIMAGE |
| **CODE_OGIMAGE** | Code | Extrai a imagem OG (og:image) da página | HTML | item+imagem → LIMIT_BATCH |
| **LIMIT_BATCH** | Limit | Teto por execução: **15 itens** | itens | até 15 → GPT-API_RESUMO |
| **GPT-API_RESUMO** | HTTP (OpenAI) | Gera o resumo editorial (curto + longo) no tom Oria | até 15 | resposta LLM → CODE_PARSE_RESUMO |
| **CODE_PARSE_RESUMO** | Code | Faz parse do JSON do resumo (headline, summary curto/longo, categoria) | resposta | campos estruturados → CODE_BUILD_MD |
| **CODE_BUILD_MD** | Code | Monta o arquivo markdown (frontmatter + corpo) e o `slug`/`file_path` | campos | conteúdo .md → GITHUB_CREATE_FILE |
| **GITHUB_CREATE_FILE** | GitHub | Faz commit do `.md` no repositório (alimenta o site) | .md | confirmação → CODE_RAWSTATE e CODE_BUILD_PUBROW |
| **CODE_RAWSTATE** | Code | Marca a origem: `raw_news.status='published'` | confirmação | update → GS_UPDATE_RAW |
| **GS_UPDATE_RAW** | Postgres Update | Persiste `status='published'` no `raw_news` (match `news_id`) | update | — |
| **CODE_BUILD_PUBROW** | Code | Monta a linha da `published_news`; **recupera o embedding** do `$('CODE_PREP')` por `news_id` | confirmação | linha completa → GS_APPEND_PUBLISHED |
| **GS_APPEND_PUBLISHED** | Postgres Execute Query | INSERT em `published_news` com `$12::timestamptz` e `$13::vector`, `ON CONFLICT (news_id) DO UPDATE`. Parâmetros como **array ordenado único** | linha | — (fim do PUBLISH) |

Resultado: notícia única publicada no GitHub e registrada em `published_news` com embedding 1536.

---

## PIPELINE 4 — EXPIRE (expiração de conteúdo antigo)

Remove do site as publicadas antigas e as arquiva.

| Node | Tipo | Função | Recebe | Envia |
|------|------|--------|--------|-------|
| **TRIGGER_EXPIRE** | Schedule | Dispara a expiração | — | GS_READ_PUBLISHED1 |
| **GS_READ_PUBLISHED1** | Postgres Select | Lê `published_news` | trigger | publicadas → CODE_FIND_EXPIRED |
| **CODE_FIND_EXPIRED** | Code | Identifica as que passaram da validade (por `published_at`) | publicadas | expiradas → GITHUB_DELETE_FILE |
| **GITHUB_DELETE_FILE** | GitHub | Remove o `.md` do repositório | expiradas | confirmação → CODE_BUILD_EXPIREDROW e CODE_MARK_EXPIRED |
| **CODE_BUILD_EXPIREDROW** | Code | Monta a linha de arquivo | confirmação | linha → GS_APPEND_EXPIRED |
| **GS_APPEND_EXPIRED** | Postgres Upsert | Arquiva em `expired_news` | linha | — |
| **CODE_MARK_EXPIRED** | Code | Marca `publication_status='expired'` | confirmação | update → GS_UPDATE_PUBLISHED |
| **GS_UPDATE_PUBLISHED** | Postgres Update | Persiste o status expirado em `published_news` | update | — |

---

## PIPELINE 5 — LIMPEZA_EMB (limpeza de embeddings antigos)

| Node | Tipo | Função | Recebe | Envia |
|------|------|--------|--------|-------|
| **TRIGGER_EXPIRE_EMB** | Schedule | Dispara a limpeza | — | GS_READ_PUBLISHED2 |
| **GS_READ_PUBLISHED2** | Postgres Select | Lê `published_news` | trigger | publicadas → CODE_LIMPA_EMB |
| **CODE_LIMPA_EMB** | Code | Zera o `embedding` das publicadas fora da janela de dedup | publicadas | updates → GS_UPDATE_PUBLISHED1 |
| **GS_UPDATE_PUBLISHED1** | Postgres Update | Persiste os embeddings limpos | updates | — |

> **Nota:** com pgvector, este pipeline provavelmente ficou **obsoleto** — o `find_duplicate` já filtra por janela de 3 dias, então embeddings antigos não atrapalham o dedup, e storage de vetor no Postgres é barato. Candidato a desativar após estabilizar.

---

## Nós removidos / alterados na migração

- **GS_READ_PUBLISHED** (antigo read do dedup quebrado): **removido** — o dedup vs-publicado agora é o `find_duplicate`.
- **Todos os 15 nós Google Sheets** → convertidos para Postgres (Select / Upsert / Update / Execute Query).
- **CODE_PREP**: perdeu o dedup vs-publicado (foi p/ SQL) e o teto diário (foi p/ o read); manteve o dedup intra-lote.
- **EMBENDDING**: 256 → 1536 dims.
- **CODE_RESOLVE**: passou a fixar `_segue=true` (coerência de auditoria).

---

## Pendência aberta (Passo D — calibração)

O `SIM_THRESHOLD=0.82` foi calibrado em 256 dims e **não transfere** para 1536. Precisa ser
recalibrado com pares reais (medindo `1 - (a.embedding <=> b.embedding)` na `published_news`)
e atualizado em **dois lugares**: `SIM_THRESHOLD` do CODE_PREP e o default da `find_duplicate`.
