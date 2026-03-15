# frozen_string_literal: true

class Clue < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps, update_on_create: true

  one_to_many :npc_clues
  one_to_many :clue_shares
  many_to_one :created_by, class: :User, key: :created_by_user_id
  many_to_one :arranged_scene

  def validate
    super
    validates_presence [:name, :content]
    validates_min_length 10, :content
  end

  # Get NPCs who know this clue
  def npcs
    npc_clues.map { |nc| Character[nc.character_id] }.compact
  end

  # Get NPC IDs who know this clue
  def npc_ids
    npc_clues_dataset.select_map(:character_id)
  end

  # Get share likelihood for specific NPC (with override)
  def share_likelihood_for(npc)
    assoc = npc_clues_dataset.where(character_id: npc.id).first
    return share_likelihood unless assoc
    assoc.share_likelihood_override || share_likelihood
  end

  # Get minimum trust for specific NPC (with override)
  def min_trust_for(npc)
    assoc = npc_clues_dataset.where(character_id: npc.id).first
    return min_trust_required unless assoc
    assoc.min_trust_override || min_trust_required
  end

  # Check if clue can be shared based on trust level
  def can_share_to?(pc, npc:)
    return true unless is_secret

    relationship = NpcRelationship.where(
      npc_character_id: npc.id,
      pc_character_id: pc.id
    ).first
    return false unless relationship

    min_trust = min_trust_for(npc)
    relationship.trust >= min_trust
  end

  # Check if this clue was already shared to a PC by an NPC
  def already_shared_to?(pc, npc:)
    clue_shares_dataset.where(
      npc_character_id: npc.id,
      recipient_character_id: pc.id
    ).any?
  end

  # Get share count
  def share_count
    clue_shares_dataset.count
  end

  # Store embedding for semantic search
  def store_embedding!
    Embedding.store(
      content_type: 'clue',
      content_id: id,
      text: "#{name}: #{content}",
      input_type: 'document'
    )
  end

  # Add an NPC who knows this clue
  def add_npc!(character, likelihood_override: nil, trust_override: nil)
    NpcClue.create(
      clue_id: id,
      character_id: character.id,
      share_likelihood_override: likelihood_override,
      min_trust_override: trust_override
    )
  end

  # Remove an NPC from knowing this clue
  def remove_npc!(character)
    npc_clues_dataset.where(character_id: character.id).delete
  end
end
