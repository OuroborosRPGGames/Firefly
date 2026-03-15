# frozen_string_literal: true

require_relative 'base_adapter'

module LLM
  module Adapters
    # VoyageAdapter handles API requests to Voyage AI for embeddings.
    #
    # Voyage AI specializes in high-quality embeddings for semantic search,
    # RAG applications, and similarity matching.
    #
    # Supported models:
    #   - voyage-3-large: Best quality, 1024 dimensions (default)
    #   - voyage-3.5: Best balance of quality/cost, 1024 dimensions
    #   - voyage-3.5-lite: Fastest and cheapest, 512 dimensions
    #   - voyage-code-3: Optimized for code, 1024 dimensions
    #   - voyage-law-2: Legal domain, 1024 dimensions
    #   - voyage-finance-2: Finance domain, 1024 dimensions
    #
    # Usage:
    #   result = VoyageAdapter.generate_embedding(
    #     input: "Search query here",
    #     api_key: "pa-...",
    #     model: "voyage-3-large",
    #     input_type: "query"
    #   )
    #
    class VoyageAdapter < BaseAdapter
      BASE_URL = 'https://api.voyageai.com/v1'
      DEFAULT_MODEL = 'voyage-3-large'
      DEFAULT_TIMEOUT = GameConfig::LLM::TIMEOUTS[:voyage_embedding]

      # Model dimension mapping
      MODEL_DIMENSIONS = {
        'voyage-3-large' => 1024,
        'voyage-3.5' => 1024,
        'voyage-3.5-lite' => 512,
        'voyage-code-3' => 1024,
        'voyage-law-2' => 1024,
        'voyage-finance-2' => 1024
      }.freeze

      # Valid input types for retrieval optimization
      INPUT_TYPES = %w[document query].freeze

      class << self
        # Generate embeddings for text(s)
        #
        # @param input [String, Array<String>] text(s) to embed
        # @param api_key [String] Voyage API key
        # @param model [String] embedding model
        # @param input_type [String, nil] 'document' or 'query' (affects optimization)
        #   - query: Adds "Represent the query for retrieving supporting documents: " prefix
        #   - document: Adds "Represent the document for retrieval: " prefix
        # @param truncation [Boolean] whether to truncate long inputs
        # @return [Hash] { success: Boolean, embedding: Array, embeddings: Array, data: Hash }
        def generate_embedding(input:, api_key:, model: DEFAULT_MODEL, input_type: nil, truncation: true)
          conn = build_connection(BASE_URL, api_key, timeout: DEFAULT_TIMEOUT) do |c|
            c.headers['Authorization'] = "Bearer #{api_key}"
            c.headers['Content-Type'] = 'application/json'
          end

          body = {
            model: model,
            input: input,
            truncation: truncation
          }

          # input_type helps Voyage optimize for search queries vs documents
          # This is critical for retrieval quality
          if input_type && INPUT_TYPES.include?(input_type)
            body[:input_type] = input_type
          end

          response = conn.post('embeddings', body)

          if response.success?
            parse_embedding_response(response.body, model)
          else
            error_msg = extract_error_message(response)
            embedding_error_response(error_msg)
          end
        rescue Faraday::TimeoutError
          embedding_error_response('Request timed out')
        rescue Faraday::ConnectionFailed => e
          embedding_error_response("Connection failed: #{e.message}")
        rescue Faraday::Error => e
          embedding_error_response("HTTP error: #{e.message}")
        rescue JSON::ParserError => e
          embedding_error_response("JSON parse error: #{e.message}")
        end

        # Text generation - not supported by Voyage
        def generate(messages:, model:, api_key:, options: {}, json_mode: false, tools: nil, response_schema: nil)
          error_response('Voyage AI does not support text generation, only embeddings')
        end

        # Image generation - not supported by Voyage
        def generate_image(prompt:, api_key:, options: {})
          error_response('Voyage AI does not support image generation, only embeddings')
        end

        # Get expected dimensions for a model
        # @param model [String] model name
        # @return [Integer] embedding dimensions
        def dimensions_for(model)
          MODEL_DIMENSIONS[model] || 1024
        end

        # Check if a model is valid
        # @param model [String] model name
        # @return [Boolean]
        def valid_model?(model)
          MODEL_DIMENSIONS.key?(model)
        end

        private

        def parse_embedding_response(body, model)
          data = body.is_a?(Hash) ? body : JSON.parse(body)
          embeddings = data['data'].map { |d| d['embedding'] }

          {
            success: true,
            embedding: embeddings.first,      # Single embedding for convenience
            embeddings: embeddings,            # All embeddings if batch
            dimensions: embeddings.first&.length || dimensions_for(model),
            model: model,
            usage: data['usage'],
            data: data,
            error: nil
          }
        end

        def extract_error_message(response)
          body = response.body
          return "HTTP #{response.status}" unless body.is_a?(Hash)

          body.dig('detail') ||
            body.dig('error', 'message') ||
            body.dig('message') ||
            "HTTP #{response.status}"
        end

        def embedding_error_response(message)
          {
            success: false,
            embedding: nil,
            embeddings: [],
            dimensions: nil,
            model: nil,
            usage: nil,
            data: {},
            error: message
          }
        end
      end
    end
  end
end
