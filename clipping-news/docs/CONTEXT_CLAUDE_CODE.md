# Contexto para Claude Code

Ver README.md e docs/FLUXO_COMPLETO.md para a arquitetura.

Regras de trabalho:
- NÃO recriar do zero. Corrigir cirurgicamente, preservar nomes de nodes e conexões.
- Trabalhar decisão-por-decisão, uma alteração por vez, com confirmação.
- Ser honesto sobre limites: Claude Code edita arquivos locais (workflow JSON, SQL,
  prompts) mas NÃO executa o workflow no n8n nem roda queries no Supabase — os testes
  de execução são feitos pelo operador. Não afirmar ter "testado internamente" o que
  depende de n8n/Supabase rodando.

Estado atual (após a otimização Top-3 + dedup híbrido):
- INGEST: inalterado.
- TRIAGE: agora, além de approved/rejected, o verificador dá `score_core` e `score_materialidade`
  e o CODE_RESOLVE grava `relevance_score` composto (core + materialidade + autoridade da fonte).
- PUBLISH: consolidação DIÁRIA. Lê todas as aprovadas por score desc, deduplica (híbrido +
  LLM na zona cinzenta), ranqueia e publica só as 3 melhores (CODE_TOP3); encerra as demais
  (GS_CLOSE_UNSELECTED -> rejected_nao_top3). Parte 2 (fetch->resumo->publish) intacta, exceto
  o CODE_OGIMAGE que passou a recuperar do CODE_TOP3 (âncora estável após ranking/slice).
- Dedup: 3 camadas — exato (unique), intra-lote (cosseno+trigrama no CODE_PREP) e vs-publicado
  (find_duplicate_v2 híbrido + zona cinzenta adjudicada por GPT-API_DEDUP).

PENDÊNCIA: calibrar os thresholds de 1536 com pares reais (sql/09_diagnostics.sql) e ajustar
em dois lugares (default de find_duplicate_v2 e SIM_COS/SIM_TRG do CODE_PREP).
