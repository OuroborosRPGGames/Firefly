# frozen_string_literal: true

require_relative '../concerns/time_format_concern'

module Commands
  module Staff
    class Reputation < Commands::Base::Command
      include Commands::Staff::Concerns::TimeFormatConcern
      command_name 'reputation'
      aliases 'rep', 'pcrep'
      category :staff
      help_text 'View a PC\'s reputation tiers and linked world memories'
      usage 'reputation <character name>'
      examples 'reputation Alice', 'rep bob smith'

      def perform_command(parsed_input)
        error = require_staff
        return error if error

        args = parsed_input[:text] || ''
        name = args.strip
        return error_result('Usage: reputation <character name>') if name.empty?

        pc = find_pc(name)
        return error_result("No PC found matching '#{name}'.") unless pc

        lines = build_output(pc)
        success_result(lines.join("\n"), type: :status, data: { action: 'reputation', character_id: pc.id })
      end

      private

      def find_pc(name)
        name_lower = name.downcase
        pcs = Character.where(is_npc: false).all

        # Exact match, forename, prefix, partial
        pcs.find { |c| c.full_name.downcase == name_lower } ||
          pcs.find { |c| c.forename.downcase == name_lower } ||
          pcs.find { |c| c.full_name.downcase.start_with?(name_lower) } ||
          pcs.find { |c| c.full_name.downcase.include?(name_lower) }
      end

      def build_output(pc)
        lines = ["<h3>Reputation: #{pc.full_name}</h3>", '']

        # Tier 1
        lines << 'TIER 1 (Public Knowledge):'
        lines << (pc.tier_1_reputation.to_s.strip.empty? ? 'Nothing notable.' : pc.tier_1_reputation)
        lines << ''

        # Tier 2
        lines << 'TIER 2 (Social Circles):'
        lines << (pc.tier_2_reputation.to_s.strip.empty? ? 'None recorded.' : pc.tier_2_reputation)
        lines << ''

        # Tier 3
        lines << 'TIER 3 (Close Associates):'
        lines << (pc.tier_3_reputation.to_s.strip.empty? ? 'None recorded.' : pc.tier_3_reputation)
        lines << ''

        if pc.reputation_updated_at
          lines << "Last Updated: #{pc.reputation_updated_at.strftime('%Y-%m-%d %H:%M')}"
        else
          lines << 'Last Updated: Never'
        end

        # Top 10 memories
        lines << ''
        lines << '<h4>Top 10 World Memories</h4>'
        lines << ''

        memories = fetch_top_memories(pc, 10)
        if memories.empty?
          lines << 'No world memories linked to this character.'
        else
          memories.each do |m|
            age = format_age(m.memory_at)
            lines << "[##{m.id}] (Importance: #{m.importance || 5}, #{age}) #{m.publicity_level}"
            lines << m.summary.to_s.strip
            lines << ''
          end
        end

        lines
      end

      def fetch_top_memories(pc, limit)
        return [] unless defined?(WorldMemory)

        # Get memories involving this PC, scored by relevance_score (importance 60% + recency 40%)
        WorldMemory.for_character(pc, limit: limit * 2)
                   .exclude(publicity_level: WorldMemory::PRIVATE_PUBLICITY_LEVELS)
                   .all
                   .sort_by { |m| -m.relevance_score }
                   .first(limit)
      end

    end
  end
end

Commands::Base::Registry.register(Commands::Staff::Reputation)
