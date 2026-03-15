# frozen_string_literal: true

module LLM
  # EmbeddingService handles embedding generation via Voyage AI.
  #
  # Provides a high-level interface for generating embeddings, with
  # configuration pulled from GameSetting.
  #
  # Usage:
  #   # Generate single embedding
  #   result = LLM::EmbeddingService.generate(text: 'Hello world')
  #   result[:embedding]  # => [0.123, -0.456, ...]
  #
  #   # Batch embedding
  #   result = LLM::EmbeddingService.generate_batch(texts: ['Hello', 'World'])
  #   result[:embeddings]  # => [[...], [...]]
  #
  #   # Query embedding (optimized for search)
  #   result = LLM::EmbeddingService.generate(text: 'search query', input_type: 'query')
  #
  class EmbeddingService
    DEFAULT_MODEL = 'voyage-3-large'

    class << self
      # Generate embedding for a single text
      #
      # @param text [String] text to embed
      # @param model [String, nil] embedding model (defaults to game setting)
      # @param input_type [String] 'document' or 'query'
      #   - Use 'document' when embedding content for storage
      #   - Use 'query' when embedding a search query
      # @return [Hash] { success: Boolean, embedding: Array, dimensions: Integer, error: String }
      def generate(text:, model: nil, input_type: 'document')
        return error_response('Text is required') if text.nil? || text.empty?

        model ||= default_model
        api_key = voyage_api_key
        return error_response('Voyage API key not configured') unless api_key && !api_key.empty?

        Adapters::VoyageAdapter.generate_embedding(
          input: text,
          api_key: api_key,
          model: model,
          input_type: input_type
        )
      end

      # Generate embeddings for multiple texts in one API call
      #
      # More efficient than multiple single calls for batch operations.
      #
      # @param texts [Array<String>] texts to embed
      # @param model [String, nil] embedding model
      # @param input_type [String] 'document' or 'query'
      # @return [Hash] { success: Boolean, embeddings: Array<Array>, dimensions: Integer }
      def generate_batch(texts:, model: nil, input_type: 'document')
        return error_response('Texts array is required') if texts.nil? || texts.empty?
        return error_response('Texts must be an array') unless texts.is_a?(Array)

        model ||= default_model
        api_key = voyage_api_key
        return error_response('Voyage API key not configured') unless api_key && !api_key.empty?

        Adapters::VoyageAdapter.generate_embedding(
          input: texts,
          api_key: api_key,
          model: model,
          input_type: input_type
        )
      end

      # Check if embedding service is available
      # @return [Boolean]
      def available?
        key = voyage_api_key
        !key.nil? && !key.empty?
      end

      # Get default model from settings
      # @return [String]
      def default_model
        GameSetting.get('default_embedding_model') || DEFAULT_MODEL
      end

      # Get dimensions for the default model
      # @return [Integer]
      def default_dimensions
        Adapters::VoyageAdapter.dimensions_for(default_model)
      end

      # Get dimensions for a specific model
      # @param model [String]
      # @return [Integer]
      def dimensions_for(model)
        Adapters::VoyageAdapter.dimensions_for(model)
      end

      private

      def voyage_api_key
        GameSetting.get('voyage_api_key')
      end

      def error_response(message)
        {
          success: false,
          embedding: nil,
          embeddings: [],
          dimensions: nil,
          error: message
        }
      end
    end
  end
end
