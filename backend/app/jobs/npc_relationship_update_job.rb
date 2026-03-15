# frozen_string_literal: true

require 'sidekiq'

# Sidekiq job for asynchronously updating NPC/PC relationship state
# after an NPC animation response.
#
# Usage:
#   NpcRelationshipUpdateJob.perform_async(npc_character_id, pc_character_id, trigger_content, emote_text)
#
class NpcRelationshipUpdateJob
  include Sidekiq::Job

  sidekiq_options queue: 'npc_animation', retry: 0

  def perform(npc_character_id, pc_character_id, trigger_content, emote_text)
    npc = Character[npc_character_id]
    pc = Character[pc_character_id]

    unless npc && pc
      warn "[NpcRelationshipUpdateJob] NPC #{npc_character_id} or PC #{pc_character_id} not found, skipping"
      return
    end

    rel = NpcRelationship.find_or_create_for(npc: npc, pc: pc)
    archetype = npc.npc_archetype

    deltas = NpcAnimationHandler.send(
      :evaluate_interaction_deltas,
      npc_name: npc.forename,
      personality: archetype&.effective_personality_prompt || 'neutral',
      behavior_pattern: archetype&.behavior_pattern || 'neutral',
      trigger_content: trigger_content.to_s,
      emote_response: emote_text.to_s
    )

    rel.record_interaction(
      sentiment_delta: deltas[:sentiment_delta],
      trust_delta: deltas[:trust_delta],
      notable_event: deltas[:notable_event]
    )
  rescue StandardError => e
    warn "[NpcRelationshipUpdateJob] Failed for NPC #{npc_character_id} / PC #{pc_character_id}: #{e.message}"
  end
end
