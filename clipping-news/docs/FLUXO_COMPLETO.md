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
| **CODE_RESOLVE** | Code | Decisão final determinística: `approved`/`rejected`, categoria final, `qa_flags`, **e calcula `relevance_score` de conteúdo = 0.6·core + 0.4·materialidade** (0–100, sem a fonte) | verificação | decisão → GS_UPDATE-raw_news |
| **GS_UPDATE-raw_news** | Postgres Update | Persiste a decisão da triagem (match `news_id`) e devolve o controle ao LOOP | decisões | → LOOP (próximo item) |

Resultado: candidatos viram `approved` (prontos p/ publicar) ou `rejected` (triagem/verifica).

---

## PIPELINE 3 — PUBLISH (consolidação diária: dedup + Top-3 + captura + resumo + publicação)

O coração. Roda **1x/dia**: lê todas as `approved` acumuladas, gera embedding, **deduplica (híbrido + LLM)**, **ranqueia por `relevance_score` e publica só as 3 melhores**, captura a página, resume, publica no GitHub, grava em `published_news` e encerra as aprovadas não selecionadas.

### Parte A — seleção, dedup e Top-3

| Node | Tipo | Função | Recebe | Envia |
|------|------|--------|--------|-------|
| **TRIGGER_PUBLISH** | Schedule | Cron `0 0 7 * * 1-5` (**1x/dia**, 07:00 BRT seg–sex; workflow `timezone=America/Sao_Paulo`) | — | GS_READ_APPROVED |
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
| **CODE_TOP3** | Code | **Gate rígido `relevance_score >= 80`** + corta nos 3 melhores (empate por autoridade da fonte). Publica <3 (ou 0) em dia fraco. Âncora de recuperação por índice do CODE_OGIMAGE | únicos | top-3 (≥80) → HTTP_FETCH_PAGE |

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

## PIPELINE 6 — SITEMAP/INDEXAÇÃO (camada desacoplada, pós-publicação)

Objetivo: garantir que toda notícia publicada apareça automaticamente num `news-sitemap.xml`
válido, que notícias expiradas saiam dele automaticamente, e preparar a resubmissão em lote ao
Google Search Console. **Não altera** a lógica de PUBLISH/EXPIRE — só se anexa aos nós terminais
`GS_APPEND_PUBLISHED` e `GS_UPDATE_PUBLISHED` (ambos sem saída antes desta entrega).

Fonte de verdade própria: tabela `sitemap_urls` (sem foreign key para `published_news`, mesma
convenção de desacoplamento das outras tabelas do projeto) e `sitemap_log` (observabilidade,
série temporal de execuções — ver `sql/10_sitemap.sql`).

### Parte A — `sync_on_publish` (anexado ao fim do PUBLISH)

| Node | Tipo | Função | Recebe | Envia |
|------|------|--------|--------|-------|
| **CODE_BUILD_SITEMAP_ROW** | Code | Monta a URL pública (`SITE_BASE_URL/noticias/{categoria}/{slug}`); recupera dados do `CODE_BUILD_PUBROW` por índice | saída de `GS_APPEND_PUBLISHED` | linha → GS_UPSERT_SITEMAP_URL |
| **GS_UPSERT_SITEMAP_URL** | Postgres Execute Query | Upsert em `sitemap_urls`; `expires_at = published_at + 30 dias` calculado em SQL | linha | — → CODE_COLLAPSE_TO_ONE1 |
| **CODE_COLLAPSE_TO_ONE1** | Code | Reduz até 3 itens/dia a **1 só disparo** de regeneração do sitemap | N itens | 1 item → SITEMAP_READ_LASTHASH1 |
| **SITEMAP_READ_LASTHASH1 / SITEMAP_READ_INDEXABLE1** | Postgres Select | Último hash commitado + todas as URLs indexáveis atuais | 1 item | → SITEMAP_BUILD_XML1 |
| **SITEMAP_BUILD_XML1** | Code | Monta XML (com escaping) + `robots.txt`; hash **FNV-1a puro-JS** (sem `require('crypto')`); compara com o último hash | leituras | `changed`/`robotsChanged` → IF_SITEMAP_CHANGED1 |
| **IF_SITEMAP_CHANGED1** | If | Só segue para commit se o XML mudou | — | true→GITHUB_EDIT_SITEMAP1 / false→IF_ROBOTS_CHANGED1 |
| **GITHUB_EDIT_SITEMAP1** (`continueOnFail`) → **IF_SITEMAP_EDIT_FAILED1** → **GITHUB_CREATE_SITEMAP1** | GitHub | Tenta editar `public/news-sitemap.xml`; se falhar (1ª execução, arquivo não existe), cria | XML | commit → GS_MARK_INCLUDED1 |
| **GS_MARK_INCLUDED1** | Postgres Execute Query | `sitemap_included_at = now()` nas URLs indexáveis | commit | → IF_ROBOTS_CHANGED1 |
| **IF_ROBOTS_CHANGED1** → **GITHUB_EDIT_ROBOTS1**/**GITHUB_CREATE_ROBOTS1** | If + GitHub | Mesmo padrão edit-com-fallback-create para `public/robots.txt` (overwrite idempotente, conteúdo 100% gerado pelo pipeline) | — | → GS_LOG_SITEMAP1 |
| **GS_LOG_SITEMAP1** | Postgres Execute Query | Insere em `sitemap_log` (inclusive quando não houve commit, para observabilidade) | — | — (fim) |

### Parte B — `reconcile_expired_news` (trigger próprio + gancho no EXPIRE)

| Node | Tipo | Função | Recebe | Envia |
|------|------|--------|--------|-------|
| **TRIGGER_RECONCILE_SITEMAP** | Schedule | Cron `0 */12 * * * *` (a cada 12min) | — | GS_READ_TO_EXPIRE |
| **GS_READ_TO_EXPIRE** | Postgres Execute Query | 1 SELECT cobrindo os 2 motivos de saída: `expires_at<=now()` OU `published_news.publication_status='expired'` | trigger | candidatos → CODE_COUNT_CHECK |
| **CODE_COUNT_CHECK** | Code | Corta o fluxo (retorna `[]`) se não há nada a reconciliar — evita ruído a cada 12min | candidatos | ids → GS_MARK_SITEMAP_EXPIRED |
| **GS_MARK_SITEMAP_EXPIRED** | Postgres Execute Query | `is_indexable=false, status='expired'` em lote | ids | → SITEMAP_READ_LASTHASH2 |
| *(mesma cadeia da Parte A, sufixo 2)* | | Regenera o sitemap só se algo mudou de fato | | → GS_LOG_SITEMAP2 |

**Gancho leve no EXPIRE existente** (não altera a lógica dele, só anexa em `GS_UPDATE_PUBLISHED`,
antes sem saída): `GS_UPDATE_PUBLISHED` → **CODE_MARK_SITEMAP_ROW_EXPIRED** (recupera `news_id` de
`$('CODE_MARK_EXPIRED')` por índice) → **GS_MARK_SITEMAP_EXPIRED_IMMEDIATE** (`is_indexable=false`
na hora). Isso derruba a janela de staleness de até 12min para ~0 — mas **não commita no GitHub**;
o commit real fica para o próximo tick do `TRIGGER_RECONCILE_SITEMAP`, evitando commits repetidos
quando o EXPIRE processa vários itens no mesmo run.

### Parte C — Search Console (scaffold desativado)

`TRIGGER_GSC_SUBMIT` (`disabled: true`) → `GS_READ_GSC_STATE` → `CODE_CHECK_NEEDS_SUBMIT` (curto-
circuita se o hash commitado já foi submetido) → `HTTP_GSC_SUBMIT` (`PUT .../sitemaps/{feedpath}`,
**sem credencial anexada, `disabled: true`** — dupla trava) → `GS_LOG_GSC_SUBMIT` +
`GS_MARK_SITEMAP_URLS_SUBMITTED`. Sticky note no canvas do n8n explica os 4 passos para ativar
(criar OAuth2 no Google Cloud, credencial no n8n, anexar ao node, remover os `disabled:true`). Sem
isso, o sitemap já funciona sozinho — o Google descobre via `robots.txt`.

### Riscos documentados

- **Semântica exata de `continueOnFail`/`get` do node GitHub** não foi validada contra uma instância
  real de n8n nesta versão — se `IF_SITEMAP_EDIT_FAILED{1,2}`/`IF_ROBOTS_EDIT_FAILED{1,2}` não
  detectarem o erro corretamente na 1ª execução (arquivo ainda não existe), ajustar a expressão
  `!!$json.error` conforme o formato real de erro desta versão do n8n.
- Corrida entre `sync_on_publish` e `reconcile_expired_news`: mitigada por cadência (colisão rara)
  e por tudo ser idempotente (hash divergente se autocorrige no próximo tick).
- `MAX_DAYS=30` duplicado (hardcoded em `CODE_FIND_EXPIRED` e replicado como `interval '30 days'`
  no upsert) — atualizar os dois juntos se a política de TTL mudar.
- `category`/`slug` são um snapshot congelado no momento da publicação; não há hoje pipeline que
  edite `published_news` pós-publicação, então o risco de URL dessincronizada é dormente.

---

## Nós removidos / alterados

- **LIMIT_BATCH** (teto de 15/execução): **removido** — substituído pelo **CODE_TOP3** (ranqueia por score e corta em 3).
- **Novos nós**: `GPT-API_DEDUP` (adjudicador de zona cinzenta), `MERGE_DEDUP2`, `CODE_DEDUP_RESOLVE`, `CODE_TOP3`, `GS_CLOSE_UNSELECTED`.
- **TRIGGER_PUBLISH**: de hora em hora → **1x/dia** às 07:00 BRT (`0 0 7 * * 1-5`; workflow `timezone=America/Sao_Paulo`).
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
