# frozen_string_literal: true

# Helper module for testing synchronization between CombatQuickmenuHandler and CombatActionService.
# Both systems modify the same FightParticipant fields, so they must stay synchronized.
module CombatSyncHelpers
  # Documented intentional differences between quickmenu and battlemap.
  # These actions exist in only one system by design, not by accident.
  INTENTIONAL_GAPS = {
    quickmenu_only: {
      # All main actions now available in both systems
    },
    battlemap_only: {
      'move_to_hex' => 'Requires hex coordinate click - no quickmenu equivalent'
    }
  }.freeze

  # Fields that must match between systems for equivalent actions.
  # When the same action is executed via both systems, these fields should be identical.
  COMBAT_STATE_FIELDS = %i[
    main_action
    main_action_set
    ability_id
    ability_choice
    pending_action_name
    target_participant_id
    ability_target_participant_id
    tactic_choice
    tactic_target_participant_id
    tactical_ability_id
    tactical_action_set
    movement_action
    movement_target_participant_id
    movement_set
    willpower_attack
    willpower_defense
    willpower_ability
    willpower_set
    input_stage
  ].freeze

  # Main actions available in quickmenu (build_main_action_options)
  # These are always available (not conditional on status effects)
  QUICKMENU_MAIN_ACTIONS = %w[
    attack
    defend
    dodge
    sprint
    pass
    surrender
  ].freeze

  # Conditional main actions (appear based on status effects)
  # These are available in BOTH systems when the condition is met
  CONDITIONAL_MAIN_ACTIONS = {
    'extinguish' => :burning,  # quickmenu: 'extinguish', battlemap: 'extinguish'
    'stand' => :prone          # quickmenu: 'stand', battlemap: 'stand_up'
  }.freeze

  # Main actions available in battlemap (CombatActionService#process)
  # These are always available (not conditional on status effects)
  BATTLEMAP_MAIN_ACTIONS = %w[
    attack
    defend
    dodge
    sprint
    pass
    surrender
  ].freeze

  # Conditional battlemap actions (parallel to CONDITIONAL_MAIN_ACTIONS)
  BATTLEMAP_CONDITIONAL_MAIN_ACTIONS = %w[
    extinguish
    stand_up
  ].freeze

  # Movement actions available in quickmenu
  # Note: These use quickmenu naming conventions
  QUICKMENU_MOVEMENT_ACTIONS = %w[
    stand_still
    towards_person
    away_from
    maintain_distance
    flee
    mount_monster
    climb
    cling
    dismount
  ].freeze

  # Movement actions available in battlemap
  # Note: These use battlemap naming conventions
  BATTLEMAP_MOVEMENT_ACTIONS = %w[
    stand_still
    move_toward
    move_away
    maintain_distance
    move_to_hex
    mount
    climb
    cling
    dismount
    flee
  ].freeze

  # Action name mappings between systems (quickmenu_key => battlemap_key)
  # Used to normalize action names for comparison
  ACTION_MAPPINGS = {
    'towards_person' => 'move_toward',
    'away_from' => 'move_away',
    'stand' => 'stand_up',
    'mount_monster' => 'mount'
  }.freeze

  # Reverse mapping for convenience
  REVERSE_ACTION_MAPPINGS = ACTION_MAPPINGS.invert.freeze

  # Tactical stances available in both systems
  TACTICAL_STANCES = %w[
    aggressive
    defensive
    quick
    guard
    back_to_back
    none
  ].freeze

  # Willpower allocation types
  WILLPOWER_TYPES = %w[
    attack
    defense
    ability
  ].freeze

  # Options available in both systems
  SHARED_OPTIONS = %w[
    melee_weapon
    ranged_weapon
    autobattle
    hazard_avoidance
    side
  ].freeze

  class << self
    # Returns main actions that exist in both systems (excluding intentional gaps)
    def shared_main_actions
      quickmenu = QUICKMENU_MAIN_ACTIONS - INTENTIONAL_GAPS[:quickmenu_only].keys
      battlemap = BATTLEMAP_MAIN_ACTIONS - INTENTIONAL_GAPS[:battlemap_only].keys

      # Normalize action names using mappings
      normalized_quickmenu = quickmenu.map { |a| ACTION_MAPPINGS[a] || a }
      normalized_battlemap = battlemap.map { |a| ACTION_MAPPINGS.invert[a] || a }

      # Find intersection
      (normalized_quickmenu & normalized_battlemap).sort
    end

    # Returns movement actions that exist in both systems
    def shared_movement_actions
      quickmenu = QUICKMENU_MOVEMENT_ACTIONS - INTENTIONAL_GAPS[:quickmenu_only].keys
      battlemap = BATTLEMAP_MOVEMENT_ACTIONS - INTENTIONAL_GAPS[:battlemap_only].keys

      # Normalize action names
      normalized_quickmenu = quickmenu.map { |a| ACTION_MAPPINGS[a] || a }
      normalized_battlemap = battlemap.map { |a| ACTION_MAPPINGS.invert[a] || a }

      (normalized_quickmenu & normalized_battlemap).sort
    end

    # Finds actions that exist in quickmenu but not battlemap (excluding intentional)
    def missing_in_battlemap
      quickmenu = QUICKMENU_MAIN_ACTIONS - INTENTIONAL_GAPS[:quickmenu_only].keys
      battlemap = BATTLEMAP_MAIN_ACTIONS

      normalized_quickmenu = quickmenu.map { |a| ACTION_MAPPINGS[a] || a }

      (normalized_quickmenu - battlemap).sort
    end

    # Finds actions that exist in battlemap but not quickmenu (excluding intentional)
    def missing_in_quickmenu
      battlemap = BATTLEMAP_MAIN_ACTIONS - INTENTIONAL_GAPS[:battlemap_only].keys
      quickmenu = QUICKMENU_MAIN_ACTIONS

      normalized_battlemap = battlemap.map { |a| ACTION_MAPPINGS.invert[a] || a }

      (normalized_battlemap - quickmenu).sort
    end

    # Normalizes an action key to the canonical form
    def normalize_action(action)
      ACTION_MAPPINGS[action] || ACTION_MAPPINGS.invert[action] || action
    end

    # Extracts combat state from a participant for comparison
    def extract_combat_state(participant)
      COMBAT_STATE_FIELDS.each_with_object({}) do |field, hash|
        hash[field] = participant.respond_to?(field) ? participant.send(field) : nil
      end
    end

    # Compares two participants and returns differences
    def compare_combat_state(participant_a, participant_b)
      state_a = extract_combat_state(participant_a)
      state_b = extract_combat_state(participant_b)

      differences = {}
      COMBAT_STATE_FIELDS.each do |field|
        next if state_a[field] == state_b[field]

        differences[field] = {
          participant_a: state_a[field],
          participant_b: state_b[field]
        }
      end
      differences
    end
  end
end
