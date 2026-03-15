# frozen_string_literal: true

require_relative '../concerns/time_format_concern'

module Commands
  module Staff
    class SearchMemory < Commands::Base::Command
      include Commands::Staff::Concerns::TimeFormatConcern
      command_name 'searchmemory'
      aliases 'memsearch', 'searchmem'
      category :staff
      help_text 'Search world memories using semantic similarity'
      usage 'searchmemory <query>'
      examples 'searchmemory bandits attacking', 'memsearch guild meeting'

      DEFAULT_LIMIT = 10

      def perform_command(parsed_input)
        error = require_staff
        return error if error

        args = parsed_input[:text] || ''
        query = args.strip
        return error_result('Usage: searchmemory <query>') if query.empty?

        results = search_memories(query, DEFAULT_LIMIT)
        lines = build_output(query, results)

        success_result(lines.join("\n"), type: :status, data: {
                         action: 'searchmemory',
                         query: query,
                         count: results.length
                       })
      end

      private

      def search_memories(query, limit)
        return [] unless defined?(LLM::Client) && defined?(Embedding) && defined?(WorldMemory)

        # Embed query with input_type: 'query' for asymmetric retrieval
        result = LLM::Client.embed(text: query, input_type: 'query')
        return [] unless result[:success]

        # Find similar embeddings
        similar = Embedding.similar_to(
          result[:embedding],
          limit: limit,
          content_type: 'world_memory',
          threshold: 0.3 # Lower threshold for broader results
        )

        return [] if similar.empty?

        # Load full memory records
        memory_ids = similar.map { |s| s[:embedding].content_id }
        memories = WorldMemory.where(id: memory_ids).all
        memories_by_id = memories.each_with_object({}) { |m, h| h[m.id] = m }

        # Return with similarity scores preserved
        similar.filter_map do |s|
          memory = memories_by_id[s[:embedding].content_id]
          next unless memory

          { memory: memory, similarity: s[:similarity] }
        end
      end

      def build_output(query, results)
        lines = ['<h3>World Memory Search</h3>']
        lines << "Query: \"#{query}\""
        lines << ''

        if results.empty?
          lines << 'No matching memories found.'
          lines << ''
          lines << '(Note: Embeddings must be generated for world memories to be searchable)'
        else
          results.each do |r|
            m = r[:memory]
            sim = (r[:similarity] * 100).round(0)
            age = format_age(m.memory_at)
            lines << "[##{m.id}] (Similarity: #{sim}%, Importance: #{m.importance || 5}, #{age})"
            lines << m.summary.to_s.strip
            lines << ''
          end
          lines << "Use 'viewmemory <id>' to see full log."
        end

        lines
      end

    end
  end
end

Commands::Base::Registry.register(Commands::Staff::SearchMemory)
