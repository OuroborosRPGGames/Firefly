# frozen_string_literal: true

return unless DB.table_exists?(:activity_remote_observers)

class ActivityRemoteObserver < Sequel::Model(:activity_remote_observers)
  plugin :validation_helpers
  plugin :timestamps

  ROLES = %w[support oppose].freeze

  SUPPORT_ACTIONS = {
    standard: %w[stat_swap reroll_ones],
    combat: %w[block_damage halve_damage expose_targets],
    persuade: %w[distraction]
  }.freeze

  OPPOSE_ACTIONS = {
    standard: %w[block_explosions damage_on_ones block_willpower],
    combat: %w[redirect_npc aggro_boost npc_damage_boost pc_damage_boost],
    persuade: %w[draw_attention]
  }.freeze

  # Relationships
  many_to_one :activity_instance
  many_to_one :character_instance
  many_to_one :consented_by, class: :CharacterInstance, key: :consented_by_id

  def validate
    super
    validates_presence [:activity_instance_id, :character_instance_id, :role]
    validates_includes ROLES, :role, message: 'must be support or oppose'
  end

  # Role checks
  def supporter?
    role == 'support'
  end

  def opposer?
    role == 'oppose'
  end

  # Action management
  def submit_action!(type:, target_id: nil, secondary_target_id: nil, message: nil)
    update(
      action_type: type,
      action_target_id: target_id,
      action_secondary_target_id: secondary_target_id,
      action_message: message,
      action_submitted_at: Time.now
    )
  end

  def clear_action!
    update(
      action_type: nil,
      action_target_id: nil,
      action_secondary_target_id: nil,
      action_message: nil,
      action_submitted_at: nil
    )
  end

  def has_action?
    !action_type.nil?
  end
  alias action? has_action?

  # Available actions for current round type
  def available_actions(round_type = :standard)
    round_type_sym = round_type.to_sym
    actions_hash = supporter? ? SUPPORT_ACTIONS : OPPOSE_ACTIONS
    actions_hash[round_type_sym] || []
  end

  # Scopes
  dataset_module do
    def active
      where(active: true)
    end

    def supporters
      where(role: 'support', active: true)
    end

    def opposers
      where(role: 'oppose', active: true)
    end

    def for_instance(instance_id)
      where(activity_instance_id: instance_id)
    end
  end
end
