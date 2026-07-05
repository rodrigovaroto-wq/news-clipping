-- Indice vetorial HNSW (cosseno) para o dedup semantico
create index if not exists idx_pub_embedding_hnsw
  on published_news using hnsw (embedding vector_cosine_ops);
