# frozen_string_literal: true

# Service for calculating and applying remote observer effects to activities.
# Remote observers can support or oppose participants, applying various effects
# to dice rolls, damage, and persuasion checks.
class ObserverEffectService
  # Action types that map to specific effects
  EFFECT_ACTIONS = {
    # Support actions (standard)
    'reroll_ones' => :reroll_ones,
    'stat_swap' => :stat_swap,
    # Opposition actions (standard)
    'block_explosions' => :block_explosions,
    'damage_on_ones' => :damage_on_ones,
    'block_willpower' => :block_willpower
  }.freeze

  # Combat-specific action mappings
  COMBAT_ACTIONS = {
    'block_damage' => :block_damage,
    'halve_damage' => :halve_damage_from,
    'expose_targets' => :expose_targets,
    'redirect_npc' => :forced_target,
    'aggro_boost' => :aggro_boost,
    'npc_damage_boost' => :damage_dealt_mult,
    'pc_damage_boost' => :damage_taken_mult
  }.freeze

  # Get effects targeting a specific participant
  #
  # @param participant [ActivityParticipant] The participant to get effects for
  # @param round_type [Symbol] The current round type (:standard, :combat, :persuade)
  # @return [Hash] Hash of effect_name => true for applicable effects
  def self.effects_for(participant, round_type: :standard)
    return {} if participant.nil?

    instance = ActivityInstance[participant.instance_id]
    return {} if instance.nil?

    effects = {}

    # Query active observers with actions targeting this participant
    observers = instance.remote_observers_dataset
                        .where(active: true)
                        .exclude(action_type: nil)
                        .where(action_target_id: participant.id)
                        .all

    observers.each do |observer|
      action_type = observer.action_type
      next if action_type.nil?

      # Check standard effects
      if EFFECT_ACTIONS.key?(action_type)
        effects[EFFECT_ACTIONS[action_type]] = true
      end
    end

    effects
  end

  # Get persuade-specific effects for an instance
  #
  # @param instance [ActivityInstance] The activity instance
  # @return [Hash] Hash with :distractions and :attention_draws arrays
  def self.effects_for_persuade(instance)
    result = {
      distractions: [],
      attention_draws: []
    }

    return result if instance.nil?

    observers = instance.remote_observers_dataset
                        .where(active: true)
                        .exclude(action_type: nil)
                        .all

    observers.each do |observer|
      case observer.action_type
      when 'distraction'
        message = observer.action_message
        result[:distractions] << message if message && !message.strip.empty?
      when 'draw_attention'
        message = observer.action_message
        result[:attention_draws] << message if message && !message.strip.empty?
      end
    end

    result
  end

  # Get combat-specific effects for an instance
  #
  # @param instance [ActivityInstance] The activity instance
  # @return [Hash] Hash of participant_id => effects hash
  def self.effects_for_combat(instance)
    result = {}

    return result if instance.nil?

    observers = instance.remote_observers_dataset
                        .where(active: true)
                        .exclude(action_type: nil)
                        .exclude(action_target_id: nil)
                        .all

    observers.each do |observer|
      action_type = observer.action_type
      target_id = observer.action_target_id
      next if action_type.nil? || target_id.nil?

      # Only process combat actions
      next unless COMBAT_ACTIONS.key?(action_type)

      result[target_id] ||= {}
      effect_key = COMBAT_ACTIONS[action_type]

      case effect_key
      when :halve_damage_from
        # For halve_damage, we track the source (secondary target) if provided
        result[target_id][:halve_damage_from] ||= []
        result[target_id][:halve_damage_from] << observer.action_secondary_target_id
      when :forced_target
        result[target_id][:forced_target] = observer.action_secondary_target_id
      when :damage_dealt_mult, :damage_taken_mult
        # Multiplier effects stack multiplicatively
        result[target_id][effect_key] = (result[target_id][effect_key] || 1.0) * 1.5
      else
        result[target_id][effect_key] = true
      end
    end

    result
  end

  # Clear all observer actions for an instance
  # Delegates to instance method for consistency
  #
  # @param instance [ActivityInstance] The activity instance
  def self.clear_actions!(instance)
    return if instance.nil?

    instance.clear_observer_actions!
  end

  # Get formatted messages from observers with action messages
  #
  # @param instance [ActivityInstance] The activity instance
  # @return [Array<String>] Array of formatted messages
  def self.emit_observer_messages(instance)
    return [] if instance.nil?

    messages = []

    observers = instance.remote_observers_dataset
                        .where(active: true)
                        .exclude(action_type: nil)
                        .exclude(action_message: nil)
                        .all

    observers.each do |observer|
      message = observer.action_message
      next if message.nil? || message.strip.empty?

      prefix = observer.supporter? ? '[Remote Support]' : '[Remote Opposition]'
      messages << "#{prefix} #{message}"
    end

    messages
  end

  # Calculate DC modifier for persuade rounds based on observer actions
  # Each distraction: -2 DC (easier)
  # Each draw_attention: +2 DC (harder)
  #
  # @param instance [ActivityInstance] The activity instance
  # @return [Integer] Net DC modifier
  def self.persuade_dc_modifier(instance)
    return 0 if instance.nil?

    modifier = 0

    observers = instance.remote_observers_dataset
                        .where(active: true)
                        .exclude(action_type: nil)
                        .all

    observers.each do |observer|
      case observer.action_type
      when 'distraction'
        modifier -= 2
      when 'draw_attention'
        modifier += 2
      end
    end

    modifier
  end
end
