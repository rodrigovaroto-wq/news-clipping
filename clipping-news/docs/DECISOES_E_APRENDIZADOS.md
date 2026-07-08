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

## Dedup híbrido v2 (embedding + lexical + LLM)
- 3 camadas: exato (unique) | intra-lote (CODE_PREP: cosseno OU trigrama de título) |
  vs-publicado (find_duplicate_v2 + zona cinzenta adjudicada por LLM).
- pg_trgm dá a camada lexical (título quase idêntico que o embedding sozinho deixa passar).
- find_duplicate_v2 classifica zona: high (auto-dup), gray (LLM decide "mesmo_evento"), none (único).
- GPT-API_DEDUP roda para todos os itens do lote diário (custo trivial no volume diário) e
  a rejunta é por posição (MERGE_DEDUP2, combineByPosition), padrão já usado no workflow.

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

## Pendências
- Calibrar thresholds 1536 com pares reais (sql/09_diagnostics.sql) — refina precisão do dedup.
- PUBLISH fixado em 07:00 BRT (workflow timezone=America/Sao_Paulo). Se a instância n8n
  estiver em UTC, o timezone do workflow prevalece; conferir na primeira execução.
- Após criar relevance_score no banco, refrescar a lista de colunas do node GS_UPDATE-raw_news
  no n8n se o auto-map não reconhecer (a coluna já está no schema do JSON).
- LIMPEZA_EMB provavelmente obsoleta com pgvector (find_duplicate_v2 já filtra janela).
- Virar repo GitHub de teste -> produção. Backups no PikaPods.
