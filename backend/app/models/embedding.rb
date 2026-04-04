# frozen_string_literal: true

require 'digest'

# Skip loading if table doesn't exist (pgvector not installed)
return unless DB.table_exists?(:embeddings)

# Embedding stores vector embeddings for semantic search and similarity.
#
# Supports multiple content types (NPC memory, room descriptions, items, etc.)
# and provides methods for similarity search using pgvector.
#
# Usage:
#   # Store an embedding (generates embedding automatically)
#   Embedding.store(
#     content_type: 'npc_memory',
#     content_id: memory.id,
#     text: 'The player helped me find my lost cat',
#     character_id: npc.character_id
#   )
#
#   # Search by text query
#   results = Embedding.search('helping someone', content_type: 'npc_memory')
#   results.each { |r| puts "#{r[:similarity]}: #{r[:embedding].source_text}" }
#
#   # Find similar content by vector
#   results = Embedding.similar_to(query_embedding, limit: 5)
#
class Embedding < Sequel::Model
  plugin :timestamps, update_on_create: true
  plugin :validation_helpers

  many_to_one :character
  many_to_one :room
  many_to_one :item, class: 'Item', key: :item_id

  CONTENT_TYPES = %w[
    npc_memory
    room_description
    item_description
    character_bio
    conversation
    quest_log
    world_lore
    world_memory
    helpfile
    narrative_entity
  ].freeze

  INPUT_TYPES = %w[document query].freeze

  def validate
    super
    validates_presence [:content_type, :content_id, :embedding]
    validates_includes CONTENT_TYPES, :content_type if content_type
    validates_includes INPUT_TYPES, :input_type if input_type
  end

  class << self
    # Store or update an embedding for content
    #
    # Automatically generates the embedding if not provided.
    # Uses content hashing to skip re-embedding unchanged content.
    #
    # @param content_type [String] type of content (see CONTENT_TYPES)
    # @param content_id [Integer] ID of the content record
    # @param text [String] text to embed
    # @param vector [Array<Float>, nil] pre-computed embedding vector (optional)
    # @param model [String] embedding model used
    # @param input_type [String] 'document' or 'query'
    # @param character_id [Integer, nil] associated character
    # @param room_id [Integer, nil] associated room
    # @param item_id [Integer, nil] associated item
    # @return [Embedding, nil] the embedding record, or nil if generation failed
    def store(content_type:, content_id:, text: nil, vector: nil, model: nil,
              input_type: 'document', character_id: nil, room_id: nil, item_id: nil)
      model ||= LLM::EmbeddingService.default_model
      content_hash = text ? Digest::SHA256.hexdigest(text) : nil

      # Check if embedding exists and content hasn't changed
      existing = first(content_type: content_type, content_id: content_id)
      if existing && existing.content_hash == content_hash && content_hash
        return existing
      end

      # Generate embedding if not provided
      unless vector
        return nil unless text

        result = LLM::EmbeddingService.generate(text: text, model: model, input_type: input_type)
        return nil unless result[:success]

        vector = result[:embedding]
      end

      # Format vector for pgvector
      vector_string = format_vector(vector)

      if existing
        DB.run(<<-SQL)
          UPDATE embeddings SET
            embedding = '#{vector_string}',
            source_text = #{DB.literal(text)},
            content_hash = #{DB.literal(content_hash)},
            model = #{DB.literal(model)},
            input_type = #{DB.literal(input_type)},
            dimensions = #{vector.length},
            character_id = #{character_id.nil? ? 'NULL' : character_id},
            room_id = #{room_id.nil? ? 'NULL' : room_id},
            item_id = #{item_id.nil? ? 'NULL' : item_id},
            updated_at = NOW()
          WHERE id = #{existing.id}
        SQL
        first(id: existing.id)
      else
        result = DB.run(<<-SQL)
          INSERT INTO embeddings (
            content_type, content_id, embedding, source_text, content_hash,
            model, input_type, dimensions, character_id, room_id, item_id,
            created_at, updated_at
          ) VALUES (
            #{DB.literal(content_type)},
            #{content_id},
            '#{vector_string}',
            #{DB.literal(text)},
            #{DB.literal(content_hash)},
            #{DB.literal(model)},
            #{DB.literal(input_type)},
            #{vector.length},
            #{character_id.nil? ? 'NULL' : character_id},
            #{room_id.nil? ? 'NULL' : room_id},
            #{item_id.nil? ? 'NULL' : item_id},
            NOW(),
            NOW()
          )
          RETURNING id
        SQL
        first(content_type: content_type, content_id: content_id)
      end
    end

    # Find similar embeddings using inner product (dot-product)
    #
    # Since Voyage embeddings are normalized to length 1, inner product
    # is equivalent to cosine similarity but faster to compute.
    #
    # @param query_vector [Array<Float>] query embedding
    # @param limit [Integer] max results
    # @param content_type [String, nil] filter by content type
    # @param threshold [Float, nil] min similarity (0 to 1, higher = more similar)
    # @return [Array<Hash>] embeddings with similarity scores
    def similar_to(query_vector, limit: 10, content_type: nil, threshold: nil)
      vector_string = format_vector(query_vector)

      # Use inner product operator <#> for normalized vectors
      # Note: <#> returns negative inner product, so we negate for similarity
      ds = dataset
        .select_append(Sequel.lit("-(embedding <#> ?::vector) AS similarity", vector_string))
        .order(Sequel.lit("embedding <#> ?::vector", vector_string))
        .limit(limit)

      ds = ds.where(content_type: content_type) if content_type
      ds = ds.where(Sequel.lit("-(embedding <#> ?::vector) >= ?", vector_string, threshold)) if threshold

      ds.all.map do |emb|
        {
          embedding: emb,
          similarity: emb[:similarity]
        }
      end
    end

    # Search by text query (generates embedding then searches)
    #
    # @param query [String] search text
    # @param limit [Integer] max results
    # @param content_type [String, nil] filter by content type
    # @param threshold [Float, nil] min similarity
    # @return [Array<Hash>] embeddings with similarity scores
    def search(query, limit: 10, content_type: nil, threshold: nil)
      # Use 'query' input_type for better search results
      result = LLM::EmbeddingService.generate(text: query, input_type: 'query')
      return [] unless result[:success]

      similar_to(result[:embedding], limit: limit, content_type: content_type, threshold: threshold)
    end

    # Delete embeddings for content
    #
    # @param content_type [String]
    # @param content_id [Integer]
    # @return [Integer] number of rows deleted
    def remove(content_type:, content_id:)
      where(content_type: content_type, content_id: content_id).delete
    end

    # Delete all embeddings for a specific character
    #
    # @param character_id [Integer]
    # @return [Integer] number of rows deleted
    def remove_for_character(character_id)
      where(character_id: character_id).delete
    end

    # Delete all embeddings for a specific room
    #
    # @param room_id [Integer]
    # @return [Integer] number of rows deleted
    def remove_for_room(room_id)
      where(room_id: room_id).delete
    end

    # Check if content has an embedding
    #
    # @param content_type [String]
    # @param content_id [Integer]
    # @return [Boolean]
    def exists_for?(content_type:, content_id:)
      where(content_type: content_type, content_id: content_id).any?
    end

    # Get embedding for specific content
    #
    # @param content_type [String]
    # @param content_id [Integer]
    # @return [Embedding, nil]
    def find_for(content_type:, content_id:)
      first(content_type: content_type, content_id: content_id)
    end

    private

    # Format vector array as pgvector string
    # Validates all values are numeric to prevent SQL injection
    def format_vector(vector)
      validated = vector.map do |v|
        Float(v)
      rescue ArgumentError, TypeError
        raise ArgumentError, "Vector contains non-numeric value: #{v.inspect}"
      end
      "[#{validated.join(',')}]"
    end
  end

  # Check if this embedding needs to be regenerated
  #
  # @param new_text [String] the current text
  # @return [Boolean]
  def stale?(new_text)
    new_hash = Digest::SHA256.hexdigest(new_text)
    content_hash != new_hash
  end
end
