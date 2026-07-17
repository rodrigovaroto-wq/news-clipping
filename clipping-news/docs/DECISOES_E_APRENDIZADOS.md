# Decisões e Aprendizados — Oria Clipping

## Arquitetura
- Migração completa Google Sheets -> Supabase/Postgres + pgvector 0.8.2.
- Dedup HÍBRIDO por desenho:
  - intra-lote (mesmo run) -> cosseno em JS no CODE_PREP;
  - vs-publicado -> função SQL find_duplicate_v2 (HNSW + pg_trgm + zona cinzenta/LLM).
  Motivo: find_duplicate_v2 só enxerga o que já está publicado; itens do mesmo
  run ainda não estão no banco.
- Camada 1 de dedup (URL/news_id exato) garantida por constraints unique no banco.

## Pegadinhas de n8n (2.27.4)
- Postgres Execute Query: a ordem $1..$N só é garantida passando os valores como
  UM array ordenado único, não como itens separados.
- HTTP Request v4.4 substitui o item pela resposta -> exige Merge (Combine by
  Position) para rejuntar campos (usado após EMBENDDING).
- Ao converter GS->Postgres, manter o NOME dos nodes (Code nodes chamam por nome).

## Pegadinhas de Supabase/pgvector
- CREATE CAST custom falha (erro 42501, ownership). Solução: cast inline $N::vector.
- Conexão n8n: Session Pooler (IPv4-proxied), SSL com "Ignore SSL Issues".
- User do pooler precisa do sufixo .projectref (postgres.<ref>).
- RLS ligado + sem policy = trancado para chaves públicas; n8n (conexão direta) ignora.

## Seleção Top-3 do dia (curadoria)
- A triagem virou binária + SCORE. O verificador (GPT-API_VERIFICA) devolve score_core e
  score_materialidade (0-100); o CODE_RESOLVE compõe relevance_score =
  0.5*core + 0.3*materialidade + 0.2*100*tier_da_fonte.
- Tier de fonte (autoridade): Valor/Brazil Journal/NeoFeed=1.0; Exame/Capital Aberto=0.7;
  Money Times/desconhecida=0.4.
- PUBLISH deixou de ser de hora em hora e passou a rodar 1x/dia às 07:00 BRT (cron 0 0 7 * * 1-5;
  workflow com timezone=America/Sao_Paulo). Lê TODAS as aprovadas por score desc, deduplica o lote,
  CODE_TOP3 ranqueia e corta em 3, e GS_CLOSE_UNSELECTED marca o resto como rejected_nao_top3
  (evita acúmulo/stale competindo no dia seguinte).
- CODE_OGIMAGE agora recupera do CODE_TOP3 (não do CODE_PREP): o ranking/slice reordena e reduz
  o lote, então a recuperação por índice precisa ancorar no nó imediatamente antes do fetch.

## Curadoria rígida (gate de score 80) — 2ª iteração pós-teste
- Objetivo: publicar SÓ o indiscutível (evento corporativo real com o qual o cliente da Oria se identifica).
- LLMs endurecidos: triagem e verifica ganharam o TESTE DO CLIENTE ORIA e rejeitam explicitamente
  prévia/resultado trimestral (mesmo com moldura de reestruturação), entrevista/retrospectiva de
  estratégia e intenção ("quer/planeja/busca/estuda") sem transação nova. Motivo: no teste real,
  "Natura (prévia de resultado)" e "Serasa (entrevista de M&A)" venceram o Top-3 indevidamente.
- Score virou de CONTEÚDO: relevance_score = 0.6·core + 0.4·materialidade (0-100), SEM a fonte.
  A fonte saiu do score (não deve bloquear um evento ótimo de fonte menor) e virou só desempate no CODE_TOP3.
- Verifica recalibrado: barra de 80; maioria dos relevantes fica 40-70; 80+ só para fato
  inequívoco/material; teto rígido de 40 em core para prévia/entrevista/intenção/contexto.
- CODE_TOP3 aplica gate MIN_SCORE=80 antes de cortar em 3 → pode publicar <3 (ou 0) num dia fraco.
- Fallback de score (LLM omisso) baixado para 50 neutro: nunca clareia o gate — só o LLM habilita publicação.

## Recall gap dos compilados — rede de segurança REVISAR
- Problema: a triagem barra compilados ("Agenda de empresas") inteiros e perde eventos core
  escondidos neles (ex.: RJ da Oi, recuperação extrajudicial da Unimed).
- Solução (Opção A, simples e sem migração): no CODE_VALIDA_SCHEMA, quando a triagem rejeita
  um item cujo texto tem sinal FORTE de distress (recuperação judicial/extrajudicial, falência,
  liquidação, default, intervenção), o qa_flags recebe o selo `rejected_triagem_REVISAR:`.
  O item continua não-publicado, mas o operador o encontra com a query de recall gap
  (sql/09_diagnostics.sql) e puxa a matéria individual à mão.
- Também funciona como rede dupla: pega qualquer distress que a triagem tenha rejeitado por engano.
- Alternativa não adotada (Opção B): splitter por LLM que quebra o compilado em eventos e
  re-tria cada um — recall máximo, mas mais complexo de manter.

## Dedup híbrido v2 (embedding + lexical + LLM)
- 3 camadas: exato (unique) | intra-lote (CODE_PREP: cosseno OU trigrama de título) |
  vs-publicado (find_duplicate_v2 + zona cinzenta adjudicada por LLM).
- pg_trgm dá a camada lexical (título quase idêntico que o embedding sozinho deixa passar).
- find_duplicate_v2 classifica zona: high (auto-dup), gray (LLM decide "mesmo_evento"), none (único).
- GPT-API_DEDUP roda para todos os itens do lote diário (custo trivial no volume diário) e
  a rejunta é por posição (MERGE_DEDUP2, combineByPosition), padrão já usado no workflow.

## Ajustes pós-teste real (backlog de ~1000 raw_news)
- KEYWORD_PENEIRA rejeitava 52% do pool. Auditoria achou 2 falsos-negativos por
  ambiguidade de palavra: 'estreia' (filme x "estreia na bolsa/no crédito") matou o M&A
  "QI Tech compra Autobanking e estreia no crédito automotivo"; 'exposicao' (arte x
  "exposição a dívida/câmbio/crédito") matou "Fundos de crédito com exposição acima de 50%
  têm resgates de R$ 50 bi". Ambas REMOVIDAS da peneira — os casos de entretenimento/arte
  que elas pegavam são barrados depois pelo LLM (filme/cinema/hollywood/museu + triagem).
- CODE_RESOLVE ganhou fallback de score: se o verificador confirma relevância mas omite
  score_core/score_materialidade, aplica baseline por categoria (insolvencia 90 ... liquidez 55)
  e materialidade neutra 50. Motivo: no teste, um aprovado com score 0 foi publicado por
  desempate de data, arbitrariamente, sobre 27 outros com score 0. Nunca deixar aprovado com score 0.

## Threshold de embedding
- É ESPECÍFICO da dimensão. 0.82 foi calibrado em 256 dims e NÃO transfere para 1536.
- Defaults conservadores atuais (1536): sim_high=0.80, sim_low=0.62, trgm_high=0.55, janela 5 dias.
- Recalibrar medindo pares reais (sql/09_diagnostics.sql) e atualizar em DOIS lugares:
  default de find_duplicate_v2 (sql/03) e SIM_COS/SIM_TRG do CODE_PREP.
- Embedding: input ampliado (headline + summary[:700], normalizado) para capturar melhor o evento.

## Estado dos campos de triagem (raw_news)
- status: pending -> triagem_llm -> approved/rejected -> published
- qa_flags: motivo + justificativa ('rejected_triagem: ...', 'rejected_keyword', etc.)
- _segue (bool): true=passou triagem, false=barrada triagem, null=barrada keyword

## Sitemap/indexação (camada nova, desacoplada)
- Objetivo: manter `public/news-sitemap.xml`/`public/robots.txt` do repo do SITE (não deste repo
  de workflow) sempre sincronizados com o que está publicado, sem tocar PUBLISH/EXPIRE.
- Tabela `sitemap_urls` SEM foreign key para `published_news` — mesma convenção das outras 4
  tabelas do projeto (raw_news/published_news/expired_news/source_registry também não têm FK
  entre si). Falhas na camada de sitemap nunca devem bloquear a curadoria.
- `sitemap_log` é tabela SEPARADA de `sitemap_urls`: a primeira é série temporal de execuções
  (observabilidade), a segunda é estado atual (1 linha por notícia) — misturar as duas quebraria
  as duas semânticas.
- Hash de mudança calculado com **FNV-1a implementado em JS puro**, não `require('crypto')`:
  o Code node do n8n roda em sandbox e módulos built-in do Node podem não estar liberados
  (depende de `NODE_FUNCTION_ALLOW_BUILTIN` da instância). FNV-1a não precisa ser criptográfico,
  só determinístico para detectar "mudou ou não".
- Geração do XML em Code node JS, não em função SQL: evita escaping manual de XML em SQL E evita
  reintroduzir o bug de `$1`/`$2` em comentário dentro de bloco `$$...$$` (já corrigido uma vez
  neste projeto, ver find_duplicate_v2). Nenhuma função `$$...$$` nova foi criada em sql/10.
- Padrão de commit no GitHub: tenta `edit` com `continueOnFail`; se falhar (1ª execução, arquivo
  não existe), cai para `create`. Evita depender do formato exato de resposta de um `get` prévio.
  **Não validado contra n8n real** — se a detecção de erro (`!!$json.error`) não bater com o
  formato desta versão, ajustar (ver docs/FLUXO_COMPLETO.md, seção riscos).
- `robots.txt` é overwrite idempotente (conteúdo 100% gerado pelo pipeline, comparado por hash) —
  se o repo do site algum dia tiver um `robots.txt` customizado à mão, trocar para estratégia de
  patch (ler o arquivo antes de escrever, preservar regras extras).
- Anexação segura: `GS_APPEND_PUBLISHED` (fim do PUBLISH) e `GS_UPDATE_PUBLISHED` (fim do EXPIRE)
  eram nós terminais (sem saída) — a camada nova só anexa ali, nunca modifica a lógica existente.
- Search Console: scaffold completo mas com dupla trava `disabled:true` (trigger + node HTTP),
  sem credencial anexada — o usuário ainda não tem OAuth2 configurado. Sitemap já funciona sozinho
  via `robots.txt` sem essa submissão automática.
- **Bug real corrigido em teste**: `SITEMAP_READ_LASTHASH1/2` (`select ... from sitemap_log ...`)
  e `SITEMAP_READ_INDEXABLE1/2` retornam 0 linhas quando as tabelas ainda estão vazias (1ª execução,
  ou `sitemap_urls` zerada). Por padrão o n8n **para de executar o ramo do workflow** quando um nó
  Postgres devolve zero itens — mesmo o Code node seguinte (`SITEMAP_BUILD_XML1/2`) já tratando isso
  com segurança (`try/catch` no `.first()`, `|| ''` no hash). O JS nunca chegava a rodar. Corrigido
  ativando `alwaysOutputData: true` nos 4 nós de leitura — o n8n passa a emitir 1 item vazio (`{}`)
  em vez de interromper, e o código já tratava esse caso corretamente. Achado testando com
  `workflows/clipping.test.json` (cópia com nós GitHub desativados para teste sem side-effects).

## Pendências
- Calibrar thresholds 1536 com pares reais (sql/09_diagnostics.sql) — refina precisão do dedup.
- PUBLISH fixado em 07:00 BRT (workflow timezone=America/Sao_Paulo). Se a instância n8n
  estiver em UTC, o timezone do workflow prevalece; conferir na primeira execução.
- Após criar relevance_score no banco, refrescar a lista de colunas do node GS_UPDATE-raw_news
  no n8n se o auto-map não reconhecer (a coluna já está no schema do JSON).
- LIMPEZA_EMB provavelmente obsoleta com pgvector (find_duplicate_v2 já filtra janela).
- Virar repo GitHub de teste -> produção. Backups no PikaPods.
- Configurar `SITE_BASE_URL` nas variáveis do n8n antes de rodar o PUBLISH pela primeira vez
  após esta entrega (senão cai no fallback `https://oriapartners.com` embutido nos nós).
- Verificar comportamento real de `edit`/`continueOnFail` do node GitHub nesta versão do n8n na
  primeira execução do sitemap (ver riscos documentados em FLUXO_COMPLETO.md).
- Ativar a submissão ao Search Console quando houver credencial OAuth2 (ver sticky note no canvas).
- Reimportar `clipping.json` no n8n para pegar o fix de `alwaysOutputData` nos 4 nós de leitura do
  sitemap (senão a 1ª execução real trava do mesmo jeito que travou no `clipping.test.json`).
