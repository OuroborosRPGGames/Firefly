# frozen_string_literal: true

module AutoGm
  # Shared archetype lookup and generation logic for Auto-GM services.
  #
  # Used by AutoGmActionExecutor and AutoGmInciteService to avoid code
  # duplication for NPC archetype resolution and adversary generation.
  #
  # Usage:
  #   class AutoGmMyService
  #     extend AutoGm::AutoGmArchetypeConcern
  #   end
  #
  module AutoGmArchetypeConcern
    # Find an NPC archetype matching the hint
    # @param hint [String, nil] archetype hint (name or description fragment)
    # @return [NpcArchetype, nil]
    def find_archetype(hint)
      return nil unless hint && defined?(NpcArchetype)

      # Try exact name match first
      archetype = NpcArchetype.where(name: hint).first
      return archetype if archetype

      # Try fuzzy search (escape LIKE special characters to prevent injection)
      escaped_hint = QueryHelper.escape_like(hint)
      NpcArchetype.where(Sequel.ilike(:name, "%#{escaped_hint}%")).first ||
        NpcArchetype.where(Sequel.ilike(:description, "%#{escaped_hint}%")).first
    rescue StandardError => e
      warn "[#{name}] Failed to find archetype by hint '#{hint}': #{e.message}"
      nil
    end

    # Generate a new adversary archetype with abilities and optionally monster template
    # @param session [AutoGmSession] the session
    # @param params [Hash] spawn parameters (keys: 'name'/'npc_name', 'description'/'npc_description',
    #   'role'/'npc_role', 'archetype_hint'/'npc_archetype_hint', 'disposition'/'npc_disposition',
    #   'difficulty')
    # @return [NpcArchetype, nil] the generated archetype
    def generate_adversary_archetype(session, params)
      return nil unless defined?(Generators::AdversaryGeneratorService)

      name = params['npc_name'] || params['name'] || params['npc_archetype_hint'] || params['archetype_hint']
      description = params['npc_description'] || params['description'] || params['npc_archetype_hint'] || params['archetype_hint']
      role = params['npc_role'] || params['role'] || 'minion'

      return nil unless name

      # Determine setting from session sketch
      setting = session.sketch&.dig('setting', 'flavor')&.to_sym || :fantasy

      # Determine difficulty from params, sketch, or default
      difficulty = (params['difficulty'] || session.sketch&.dig('difficulty') || 'normal').to_sym

      result = Generators::AdversaryGeneratorService.generate_adversary(
        adversary: {
          'name' => name,
          'description' => description,
          'role' => role,
          'behavior' => params['npc_disposition'] || params['disposition'] || 'aggressive'
        },
        setting: setting,
        difficulty: difficulty,
        activity_id: nil,
        options: {}
      )

      result[:success] ? result[:archetype] : nil
    rescue StandardError => e
      warn "[#{name}] Failed to generate adversary: #{e.message}"
      nil
    end
  end
end
