# Contexto para Claude Code

Ver README.md e docs/FLUXO_COMPLETO.md para a arquitetura.

Regras de trabalho:
- NÃO recriar do zero. Corrigir cirurgicamente, preservar nomes de nodes e conexões.
- Trabalhar decisão-por-decisão, uma alteração por vez, com confirmação.
- Ser honesto sobre limites: Claude Code edita arquivos locais (workflow JSON, SQL,
  prompts) mas NÃO executa o workflow no n8n nem roda queries no Supabase — os testes
  de execução são feitos pelo operador. Não afirmar ter "testado internamente" o que
  depende de n8n/Supabase rodando.

Camadas 1 (INGEST) e 2 (TRIAGE): OTIMIZADAS, não mexer.
Camada 3 parte 2 (fetch->resumo->publish): correta, não mexer.
FOCO: camada 3 parte 1 (dedup) — calibrar threshold 1536 e validar find_duplicate.
