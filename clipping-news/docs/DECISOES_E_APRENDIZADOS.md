# Decisões e Aprendizados — Oria Clipping

## Arquitetura
- Migração completa Google Sheets -> Supabase/Postgres + pgvector 0.8.2.
- Dedup HÍBRIDO por desenho:
  - intra-lote (mesmo run) -> cosseno em JS no CODE_PREP;
  - vs-publicado -> função SQL find_duplicate (índice HNSW).
  Motivo: find_duplicate só enxerga o que já está publicado; itens do mesmo
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

## Threshold de embedding
- É ESPECÍFICO da dimensão. 0.82 foi calibrado em 256 dims e NÃO transfere para 1536.
- Recalibrar medindo pares reais (1 - (a<=>b)) e atualizar em DOIS lugares:
  SIM_THRESHOLD (CODE_PREP) e default de find_duplicate.

## Estado dos campos de triagem (raw_news)
- status: pending -> triagem_llm -> approved/rejected -> published
- qa_flags: motivo + justificativa ('rejected_triagem: ...', 'rejected_keyword', etc.)
- _segue (bool): true=passou triagem, false=barrada triagem, null=barrada keyword

## Pendências
- Calibrar threshold 1536 (única pendência que barra o dedup intra-lote).
- LIMPEZA_EMB provavelmente obsoleta com pgvector (find_duplicate já filtra janela).
- Virar repo GitHub de teste -> produção. Backups no PikaPods.
