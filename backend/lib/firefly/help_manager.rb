# frozen_string_literal: true

module Firefly
  # Central help system manager
  #
  # Provides a unified API for accessing help content from database,
  # with caching for performance and methods for searching/suggesting.
  #
  module HelpManager
    CACHE_TTL = 300 # 5 minutes
    CACHE_PREFIX = 'help:'

    class << self
      # Get help for a topic
      # @param topic [String] command name, topic, or synonym
      # @param character_instance [CharacterInstance, nil] for permission checks
      # @return [Hash, nil] formatted help content
      def get_help(topic, character_instance = nil)
        return nil if topic.nil? || topic.strip.empty?

        normalized = topic.downcase.strip

        # Try cache first
        cached = cached_fetch(normalized)
        return cached if cached

        # Look up in database
        helpfile = Helpfile.find_by_topic(normalized)
        return nil unless helpfile

        # Check permissions
        if helpfile.admin_only
          return nil unless character_instance&.character&.user&.admin?
        end

        return nil if helpfile.hidden

        result = helpfile.to_agent_format
        set_cached(normalized, result)
        result
      end

      # Search for help topics
      # @param query [String] search query
      # @param options [Hash] search options
      # @return [Array<Hash>] matching topics
      def search(query, options = {})
        return [] if query.nil? || query.strip.empty?

        Helpfile.search(query, options).map do |helpfile|
          {
            command: helpfile.command_name,
            topic: helpfile.topic,
            summary: helpfile.summary,
            category: helpfile.category
          }
        end
      end

      # Get autocomplete suggestions
      # @param partial [String] partial input
      # @param limit [Integer] max suggestions
      # @return [Array<String>] suggested topics
      def suggest_topics(partial, limit = 10)
        return [] if partial.nil? || partial.strip.empty?

        normalized = partial.downcase.strip
        suggestions = []

        # Command names starting with partial
        suggestions += Helpfile
                       .where(Sequel.ilike(:command_name, "#{normalized}%"))
                       .where(hidden: false)
                       .limit(limit)
                       .select_map(:command_name)

        # Synonyms starting with partial
        suggestions += HelpfileSynonym
                       .where(Sequel.ilike(:synonym, "#{normalized}%"))
                       .limit(limit)
                       .select_map(:synonym)

        suggestions.uniq.first(limit)
      end

      # Get table of contents (organized help index)
      # @param options [Hash] filter options
      # @return [Hash] sections with topics
      def table_of_contents(options = {})
        toc = {}

        query = Helpfile.where(hidden: false)
        query = query.where(admin_only: false) unless options[:admin]
        query = query.where(category: options[:category]) if options[:category]

        query.order(:toc_section, :toc_order, :command_name).each do |helpfile|
          section = helpfile.toc_section || 'General'
          toc[section] ||= []
          toc[section] << {
            command: helpfile.command_name,
            summary: helpfile.summary
          }
        end

        toc
      end

      # List all help topics
      # @param options [Hash] filter options
      # @return [Array<Hash>] all topics
      def list_topics(options = {})
        query = Helpfile.where(hidden: false)
        query = query.where(admin_only: false) unless options[:admin]
        query = query.where(category: options[:category]) if options[:category]

        query.order(:command_name).map do |helpfile|
          {
            command: helpfile.command_name,
            topic: helpfile.topic,
            summary: helpfile.summary,
            category: helpfile.category,
            plugin: helpfile.plugin
          }
        end
      end

      # Sync all commands to helpfiles
      # @return [Integer] number synced
      def sync_commands!
        count = Helpfile.sync_all_commands!

        # Sync synonyms for all helpfiles
        Helpfile.each(&:sync_synonyms!)

        # Clear cache
        clear_cache!

        count
      end

      # Reload help system (clear cache)
      def reload!
        clear_cache!
      end

      private

      def cached_fetch(key)
        return nil unless defined?(REDIS_POOL)

        json = REDIS_POOL.with { |r| r.get("#{CACHE_PREFIX}#{key}") }
        return nil unless json

        JSON.parse(json, symbolize_names: true)
      rescue StandardError => e
        warn "[HelpManager] Failed to read cache for #{key}: #{e.message}"
        nil
      end

      def set_cached(key, value)
        return unless defined?(REDIS_POOL)

        REDIS_POOL.with do |r|
          r.setex("#{CACHE_PREFIX}#{key}", CACHE_TTL, value.to_json)
        end
      rescue StandardError => e
        warn "[HelpManager] Failed to set cache: #{e.message}"
      end

      def clear_cache!
        return unless defined?(REDIS_POOL)

        REDIS_POOL.with do |r|
          keys = r.keys("#{CACHE_PREFIX}*")
          r.del(*keys) if keys.any?
        end
      rescue StandardError => e
        warn "[HelpManager] Failed to clear cache: #{e.message}"
      end
    end
  end
end
