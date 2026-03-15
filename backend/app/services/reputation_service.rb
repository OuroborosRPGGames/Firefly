# frozen_string_literal: true

# Service for managing PC reputation tiers.
#
# Analyzes WorldMemory entries involving a character and generates
# three tiers of reputation using LLM:
# - Tier 1: Public knowledge (what almost everyone might know)
# - Tier 2: Social circles (what people in similar circles know)
# - Tier 3: Close associates (what friends/investigators know)
#
# Usage:
#   # Regenerate a single character's reputation
#   ReputationService.regenerate_for_character!(character)
#
#   # Regenerate all PC reputations (weekly job)
#   ReputationService.regenerate_all!
#
#   # Get reputation for display based on knowledge tier
#   ReputationService.reputation_for(character, knowledge_tier: 2)
#
module ReputationService
  extend self

  # Regenerate reputation for all PC characters.
  # Called by weekly scheduler job.
  #
  # @return [Hash] { processed: Integer, errors: Integer }
  def regenerate_all!
    pcs = Character.where(is_npc: false).all
    processed = 0
    errors = 0

    pcs.each do |character|
      regenerate_for_character!(character)
      processed += 1
    rescue StandardError => e
      errors += 1
      warn "[ReputationService] Failed to regenerate for #{character.full_name}: #{e.message}"
    end

    { processed: processed, errors: errors }
  end

  # Regenerate reputation for a single character.
  # Analyzes WorldMemory entries and generates three tiers via LLM.
  #
  # @param character [Character] The character to regenerate reputation for
  # @return [Boolean] true if successful
  def regenerate_for_character!(character)
    return false unless character && !character.npc?

    # Retrieve memories involving this character
    memories = fetch_relevant_memories(character)

    # Build context for LLM
    memory_context = build_memory_context(memories)
    narrative_context = fetch_narrative_context(character)

    # Generate tiers via LLM
    result = generate_tiers(character, memory_context, narrative_context)
    return false unless result[:success]

    # Update character
    character.update(
      tier_1_reputation: result[:tier_1],
      tier_2_reputation: result[:tier_2],
      tier_3_reputation: result[:tier_3],
      reputation_updated_at: Time.now
    )

    true
  rescue StandardError => e
    warn "[ReputationService] Error regenerating reputation for #{character&.full_name}: #{e.message}"
    false
  end

  # Get reputation for a character based on knowledge tier.
  #
  # @param character [Character] The character
  # @param knowledge_tier [Integer] The requester's knowledge tier (1, 2, or 3)
  # @return [String, nil] Combined reputation text or nil
  def reputation_for(character, knowledge_tier: 1)
    return nil unless character

    tiers = []
    tiers << character.tier_1_reputation if knowledge_tier >= 1
    tiers << character.tier_2_reputation if knowledge_tier >= 2
    tiers << character.tier_3_reputation if knowledge_tier >= 3

    # Filter out nil and "nothing notable" type entries
    tiers = tiers.compact.reject do |t|
      t.strip.empty? || t.downcase.include?('nothing notable')
    end

    return nil if tiers.empty?

    tiers.join("\n\n")
  end

  private

  # Fetch relevant memories for a character, scored by relevance.
  #
  # @param character [Character]
  # @return [Array<WorldMemory>]
  def fetch_relevant_memories(character)
    return [] unless defined?(WorldMemory)

    # Get memories involving this character
    memories = WorldMemory.for_character(character, limit: 30)
                          .exclude(publicity_level: WorldMemory::PRIVATE_PUBLICITY_LEVELS)
                          .all

    # Score and sort by relevance
    scored = memories.map do |m|
      { memory: m, score: m.relevance_score }
    end

    # Boost reputation-relevant memories from narrative extraction
    if defined?(NarrativeEntityMemory) && defined?(NarrativeEntity)
      entity = NarrativeEntity.find_by_canonical('Character', character.id)
      if entity
        rep_memory_ids = NarrativeEntityMemory
          .where(narrative_entity_id: entity.id, reputation_relevant: true)
          .select_map(:world_memory_id)
        scored.each do |s|
          s[:score] += 2.0 if rep_memory_ids.include?(s[:memory].id)
        end
      end
    end

    # Return top 20 by relevance
    scored.sort_by { |s| -s[:score] }
          .first(20)
          .map { |s| s[:memory] }
  rescue StandardError => e
    warn "[ReputationService] Error fetching memories: #{e.message}"
    []
  end

  # Build memory context string for LLM prompt.
  #
  # @param memories [Array<WorldMemory>]
  # @return [String]
  def build_memory_context(memories)
    return 'No significant world memories found.' if memories.empty?

    memories.map do |m|
      importance_label = m.importance >= 7 ? ' [Important]' : ''
      "- #{m.summary}#{importance_label}"
    end.join("\n")
  end

  # Generate reputation tiers via LLM.
  #
  # @param character [Character]
  # @param memory_context [String]
  # @return [Hash] { success: Boolean, tier_1:, tier_2:, tier_3: }
  # Gather narrative intelligence context for a character.
  # Includes faction ties, notable relationships, and active storyline involvement.
  #
  # @param character [Character]
  # @return [String]
  def fetch_narrative_context(character)
    return '' unless defined?(NarrativeEntity)

    entity = NarrativeEntity.find_by_canonical('Character', character.id)
    return '' unless entity

    lines = []

    # Faction ties
    faction_rels = NarrativeRelationship.current
      .where(source_entity_id: entity.id, relationship_type: 'member_of')
      .all
    faction_rels.each do |rel|
      target = rel.target_entity
      next unless target&.entity_type == 'faction'

      lines << "Faction: Member of #{target.name}"
    end

    # Strong relationships
    strong_rels = NarrativeRelationship.current
      .strong(min_strength: 3.0)
      .where(Sequel.|({ source_entity_id: entity.id }, { target_entity_id: entity.id }))
      .limit(10)
      .all
    strong_rels.each do |rel|
      other = rel.other_entity(entity.id)
      next unless other

      lines << "Relationship: #{rel.relationship_type.tr('_', ' ')} with #{other.name} (strength: #{rel.strength})"
    end

    # Active threads
    thread_entities = NarrativeThreadEntity.where(narrative_entity_id: entity.id).all
    thread_ids = thread_entities.map(&:narrative_thread_id)
    threads = NarrativeThread.where(id: thread_ids).active_threads.by_importance.limit(5).all
    threads.each do |t|
      te = thread_entities.find { |x| x.narrative_thread_id == t.id }
      role_label = te&.role ? " (role: #{te.role})" : ''
      lines << "Active storyline: #{t.name}#{role_label} - #{t.summary || 'ongoing'}"
    end

    lines.any? ? lines.join("\n") : ''
  rescue StandardError => e
    warn "[ReputationService] Error fetching narrative context: #{e.message}"
    ''
  end

  def generate_tiers(character, memory_context, narrative_context = '')
    prompt = GamePrompts.get('reputation.tier_generation',
                             character_name: character.full_name,
                             memory_context: memory_context,
                             narrative_context: narrative_context)

    result = LLM::Client.generate(
      prompt: prompt,
      model: 'gemini-3-flash-preview',
      provider: 'google_gemini',
      options: { max_tokens: 800, temperature: 0.3 },
      json_mode: true
    )

    return { success: false, error: result[:error] } unless result[:success]

    parsed = begin
      JSON.parse(result[:text])
    rescue JSON::ParserError => e
      warn "[ReputationService] Failed to parse LLM JSON response: #{e.message}"
      nil
    end
    return { success: false, error: 'Failed to parse JSON response' } unless parsed

    {
      success: true,
      tier_1: parsed['tier_1'] || '',
      tier_2: parsed['tier_2'] || '',
      tier_3: parsed['tier_3'] || ''
    }
  rescue StandardError => e
    { success: false, error: e.message }
  end
end
