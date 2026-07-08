# Oria Clipping — Fluxo Completo (node por node)

> Estado descrito: arquitetura vigente (Supabase/Postgres + pgvector, com o dedup híbrido do Passo D).
> O JSON em disco é anterior às mudanças de canvas; esta descrição reflete o desenho atual construído.
> Para auditoria exata, reexporte o workflow do n8n.

O sistema são **5 pipelines independentes**, cada um com seu próprio gatilho (schedule):
INGEST, TRIAGE, PUBLISH, EXPIRE e LIMPEZA_EMB. Todos leem/escrevem nas 4 tabelas do Supabase.

Convenção abaixo: **Recebe** = o que chega no input do node; **Envia** = o que sai para o próximo.

---

## Camada de dados (Supabase)

- **raw_news** — pool bruto. Colunas-chave: `news_id` (PK), `status` (pending→triagem_llm→approved/rejected→published), `qa_flags` (motivo+justificativa; inclui `rejected_nao_top3` para aprovadas que não entraram no Top-3 do dia), `_segue` (bool: true=passou triagem, false=barrada triagem, null=barrada keyword), `relevance_score` (numeric: score Oria para o ranking Top-3), `source_url` (unique), textos originais, datas.
- **published_news** — publicadas. `news_id` (PK), textos editoriais da Oria, `slug`, `file_path`, `publication_status` (published/expired), `published_at` (timestamptz), `embedding` (**vector(1536)**), `source_url` (unique). Índice **HNSW** cosseno em `embedding`.
- **expired_news** — arquivo das que saíram do site.
- **source_registry** — feeds RSS (`source_name`, `rss_url`, `rss_active`).
- **Função `find_duplicate_v2(embedding, headline, sim_high=0.80, sim_low=0.62, trgm_high=0.55, janela_dias=5)`** — dedup vs-publicado HÍBRIDO. Retorna o melhor candidato dentro da janela e classifica a **zona**: `high` (cosseno ou trigrama de título alto → duplicata automática), `gray` (cosseno intermediário → adjudicação por LLM), ou nenhuma linha (único). Requer `pg_trgm`.

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
| **GPT-API_VERIFICA** | HTTP (OpenAI) | 2ª passada: confirma relevância/categoria **e dá `score_core` + `score_materialidade` (0-100)** | itens `_segue=true` | verificação → CODE_RESOLVE |
| **CODE_RESOLVE** | Code | Decisão final determinística: `approved`/`rejected`, categoria final, `qa_flags`, **e calcula `relevance_score` = 0.5·core + 0.3·materialidade + 0.2·autoridade da fonte** | verificação | decisão → GS_UPDATE-raw_news |
| **GS_UPDATE-raw_news** | Postgres Update | Persiste a decisão da triagem (match `news_id`) e devolve o controle ao LOOP | decisões | → LOOP (próximo item) |

Resultado: candidatos viram `approved` (prontos p/ publicar) ou `rejected` (triagem/verifica).

---

## PIPELINE 3 — PUBLISH (consolidação diária: dedup + Top-3 + captura + resumo + publicação)

O coração. Roda **1x/dia**: lê todas as `approved` acumuladas, gera embedding, **deduplica (híbrido + LLM)**, **ranqueia por `relevance_score` e publica só as 3 melhores**, captura a página, resume, publica no GitHub, grava em `published_news` e encerra as aprovadas não selecionadas.

### Parte A — seleção, dedup e Top-3

| Node | Tipo | Função | Recebe | Envia |
|------|------|--------|--------|-------|
| **TRIGGER_PUBLISH** | Schedule | Cron `0 0 20 * * 1-5` (**1x/dia**, 20:00 seg–sex; confira o TZ do n8n) | — | GS_READ_APPROVED |
| **GS_READ_APPROVED** | Postgres Execute Query | Lê **todas** as `status='approved'` `order by relevance_score desc` (sem teto SQL; o Top-3 é aplicado depois do dedup) | trigger | aprovados → EMBENDDING e Merge |
| **EMBENDDING** | HTTP (OpenAI) | Gera embedding **1536 dims** de `headline_original + summary_original[:700]` (normalizado) | aprovados | vetores → Merge |
| **Merge** | Merge (Combine by Position) | Rejunta cada item com seu embedding | aprovados + vetores | item+embedding → CODE_PREP |
| **CODE_PREP** | Code | **Dedup intra-lote híbrido** (cosseno **ou** trigrama de título entre itens do run; mantém a de maior score) + moldagem (`headline`, `summary`, `srcurl`, `embedding`, `relevance_score`) | item+embedding | itens únicos-no-lote → DEDUP_CHECK e MERGE_DEDUP |
| **DEDUP_CHECK** | Postgres Execute Query | **Dedup vs-publicado**: `find_duplicate_v2($1::vector, $2)` → `zone` + candidato (`cand_headline`/`cand_summary`) | itens | zona+candidato → MERGE_DEDUP |
| **MERGE_DEDUP** | Merge (Combine by Position) | Rejunta zona/candidato ao item completo | itens + zona | item+zona → GPT-API_DEDUP e MERGE_DEDUP2 |
| **GPT-API_DEDUP** | HTTP (OpenAI) | Adjudica a **zona cinzenta**: "A e B são o mesmo evento?" (só o veredito de `gray` é usado) | item+zona | `{mesmo_evento}` → MERGE_DEDUP2 |
| **MERGE_DEDUP2** | Merge (Combine by Position) | Rejunta o veredito do LLM ao item completo | item + veredito | mesclado → CODE_DEDUP_RESOLVE |
| **CODE_DEDUP_RESOLVE** | Code | Define `is_dup` final: `high`→dup, `gray`→veredito do LLM, `none`→único | mesclado | item+is_dup → IF |
| **IF** | If | `is_dup=false` → segue; `true` → descarta | item+is_dup | true→CODE_TOP3 / false→✕ |
| **CODE_TOP3** | Code | **Ranqueia os únicos por `relevance_score` e corta nos 3 melhores** (âncora de recuperação por índice do CODE_OGIMAGE) | únicos | top-3 → HTTP_FETCH_PAGE |

> **Por que dedup em vários lugares:** `find_duplicate_v2` só compara contra o publicado. Duplicatas do mesmo evento no **mesmo lote diário** ainda não estão no banco — quem as pega é o dedup intra-lote do CODE_PREP. A zona cinzenta (LLM) cobre os pares que o threshold sozinho não resolve.

### Parte B — captura, resumo, publicação e encerramento

| Node | Tipo | Função | Recebe | Envia |
|------|------|--------|--------|-------|
| **HTTP_FETCH_PAGE** | HTTP | Baixa o HTML da página original da notícia | top-3 | HTML → CODE_OGIMAGE |
| **CODE_OGIMAGE** | Code | Extrai og:image + corpo do texto; **recupera o item do `$('CODE_TOP3')` por índice** | HTML | item+imagem → GPT-API_RESUMO |
| **GPT-API_RESUMO** | HTTP (OpenAI) | Gera o resumo editorial (curto + longo) no tom Oria | até 3 | resposta LLM → CODE_PARSE_RESUMO |
| **CODE_PARSE_RESUMO** | Code | Faz parse do JSON do resumo (headline, summary curto/longo, categoria) | resposta | campos estruturados → CODE_BUILD_MD |
| **CODE_BUILD_MD** | Code | Monta o arquivo markdown (frontmatter + corpo) e o `slug`/`file_path` | campos | conteúdo .md → GITHUB_CREATE_FILE |
| **GITHUB_CREATE_FILE** | GitHub | Faz commit do `.md` no repositório (alimenta o site) | .md | confirmação → CODE_RAWSTATE e CODE_BUILD_PUBROW |
| **CODE_RAWSTATE** | Code | Marca a origem: `raw_news.status='published'` | confirmação | update → GS_UPDATE_RAW |
| **GS_UPDATE_RAW** | Postgres Update | Persiste `status='published'` no `raw_news` (match `news_id`) | update | → GS_CLOSE_UNSELECTED |
| **GS_CLOSE_UNSELECTED** | Postgres Execute Query | Encerra as aprovadas fora do Top-3: `status='rejected', qa_flags='rejected_nao_top3'` (evita acúmulo/stale) | — | — |
| **CODE_BUILD_PUBROW** | Code | Monta a linha da `published_news`; **recupera o embedding** do `$('CODE_PREP')` por `news_id` | confirmação | linha completa → GS_APPEND_PUBLISHED |
| **GS_APPEND_PUBLISHED** | Postgres Execute Query | INSERT em `published_news` com `$12::timestamptz` e `$13::vector`, `ON CONFLICT (news_id) DO UPDATE`. Parâmetros como **array ordenado único** | linha | — (fim do PUBLISH) |

Resultado: **as 3 melhores do dia** publicadas no GitHub e registradas em `published_news` com embedding 1536; as demais aprovadas encerradas.

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

> **Nota:** com pgvector, este pipeline provavelmente ficou **obsoleto** — o `find_duplicate_v2` já filtra por janela (5 dias), então embeddings antigos não atrapalham o dedup, e storage de vetor no Postgres é barato. Candidato a desativar após estabilizar.

---

## Nós removidos / alterados

- **LIMIT_BATCH** (teto de 15/execução): **removido** — substituído pelo **CODE_TOP3** (ranqueia por score e corta em 3).
- **Novos nós**: `GPT-API_DEDUP` (adjudicador de zona cinzenta), `MERGE_DEDUP2`, `CODE_DEDUP_RESOLVE`, `CODE_TOP3`, `GS_CLOSE_UNSELECTED`.
- **TRIGGER_PUBLISH**: de hora em hora → **1x/dia** (`0 0 20 * * 1-5`).
- **GS_READ_APPROVED**: perdeu o teto diário de 25; passou a `order by relevance_score desc`.
- **CODE_PREP**: dedup intra-lote virou **híbrido** (cosseno **ou** trigrama de título) e passou a carregar `relevance_score`.
- **DEDUP_CHECK**: `find_duplicate` → **`find_duplicate_v2`** (zona + candidato; 2 parâmetros).
- **GPT-API_VERIFICA / CODE_RESOLVE**: passaram a produzir/compor o `relevance_score`.
- **CODE_OGIMAGE**: recuperação por índice reancorada em `$('CODE_TOP3')` (antes `$('CODE_PREP')`).
- **EMBENDDING**: input `[:300]` → `[:700]` normalizado.
- **GS_READ_PUBLISHED** (antigo, migração): removido; **15 nós Google Sheets** → Postgres.

---

## Pendência aberta (calibração)

Os thresholds do dedup (`sim_high=0.80`, `sim_low=0.62`, `trgm_high=0.55`) são defaults
conservadores para 1536 dims. Recalibrar com pares reais (ver `sql/09_diagnostics.sql`) e
atualizar em **dois lugares**: `SIM_COS`/`SIM_TRG` do CODE_PREP e o default da `find_duplicate_v2`.
A zona cinzenta (LLM) reduz a sensibilidade ao valor exato do threshold, mas a calibração
ainda melhora precisão e custo.
