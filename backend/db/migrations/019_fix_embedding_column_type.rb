# frozen_string_literal: true

# The embeddings table was created with `embedding text` but pgvector's
# similarity operators (<#>, <=>, <->) require the native vector type.
# Inserts were casting to ::vector on the way in, but PostgreSQL silently
# converted back to text for storage, making all similarity queries fail.
#
# This migration converts the column to vector(1024) and adds an HNSW
# index for fast inner-product similarity search.

Sequel.migration do
  up do
    run 'ALTER TABLE embeddings ALTER COLUMN embedding TYPE vector(1024) USING embedding::vector(1024)'
    run 'CREATE INDEX IF NOT EXISTS embeddings_embedding_hnsw_idx ON embeddings USING hnsw (embedding vector_ip_ops)'
  end

  down do
    run 'DROP INDEX IF EXISTS embeddings_embedding_hnsw_idx'
    run 'ALTER TABLE embeddings ALTER COLUMN embedding TYPE text USING embedding::text'
  end
end
