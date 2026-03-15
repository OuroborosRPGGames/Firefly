# frozen_string_literal: true

require_relative 'concerns/base_quickmenu_handler'

# Manages combat quickmenu flow for participants.
# Uses a hub-style menu where players can configure their round in any order.
class CombatQuickmenuHandler
  include BaseQuickmenuHandler
  include PersonalizedBroadcastConcern

  # Stage configuration with prompts
  STAGES = {
    'main_menu' => { prompt: 'Combat Actions:' },
    'main_action' => { prompt: 'Choose your action:' },
    'main_target' => { prompt: 'Choose your target:' },
    'tactical_action' => { prompt: 'Choose your tactic:' },
    'tactical_target' => { prompt: 'Choose ally to protect:' },
    'tactical_ability_target' => { prompt: 'Choose target for ability:' },
    'movement' => { prompt: 'Choose your movement:' },
    'willpower' => { prompt: 'Spend willpower dice:' },
    'options' => { prompt: 'Combat Options:' },
    'weapon_melee' => { prompt: 'Select melee weapon:' },
    'weapon_ranged' => { prompt: 'Select ranged weapon:' },
    'autobattle' => { prompt: 'Select Autobattle Style:' },
    'side_select' => { prompt: 'Choose your side:' }
  }.freeze

  # Max willpower dice that can be spent (from centralized config)
  MAX_WILLPOWER_SPEND = GameConfig::Mechanics::WILLPOWER[:max_spend_per_action]

  attr_reader :fight

  # Start next round from a class-method context (used by FightService.try_advance_round)
  # Creates a temporary handler instance to reuse the instance-level start_next_round logic
  def self.start_next_round_for(fight_service)
    fight = fight_service.fight
    # Pick any active participant to serve as handler context
    sample_participant = fight.active_participants.first
    return unless sample_participant

    ci = sample_participant.character_instance
    handler = new(sample_participant, ci)
    handler.send(:start_next_round, fight_service)
  end

  # Get status text for a participant (HP or Touches in spar mode)
  def self.status_text(participant)
    if participant.fight&.spar_mode?
      "Touches: #{participant.touch_count || 0}/#{participant.max_hp}"
    else
      "HP: #{participant.current_hp}/#{participant.max_hp}"
    end
  end

  private

  def after_initialize
    @fight = participant.fight
  end

  # Instance method version of status_text
  def status_text(p)
    self.class.status_text(p)
  end

  def current_stage
    participant.input_stage
  end

  def menu_context
    {
      combat: true,
      fight_id: fight.id,
      participant_id: participant.id
    }
  end

  def can_complete?
    # Validation handled by participant.complete_input!
    true
  end

  def complete_input!
    participant.complete_input!
  end

  def return_to_main_menu
    participant.update(input_stage: 'main_menu')
  end

  def check_round_resolution
    fight.reload

    # Check if all participants are done
    if fight.all_inputs_complete?
      FightService.try_advance_round(fight)
    end
  end

  # Process choice for a given stage
  def process_stage_choice(stage, response)
    case stage
    when 'main_menu'
      handle_main_menu_choice(response)
    when 'main_action'
      handle_main_action_choice(response)
    when 'main_target'
      handle_main_target_choice(response)
    when 'tactical_action'
      handle_tactical_action_choice(response)
    when 'tactical_target'
      handle_tactical_target_choice(response)
    when 'tactical_ability_target'
      handle_tactical_ability_target_choice(response)
    when 'movement'
      handle_movement_choice(response)
    when 'willpower'
      handle_willpower_choice(response)
    when 'options'
      handle_options_choice(response)
    when 'side_select'
      handle_side_select_choice(response)
    when 'weapon_melee'
      handle_weapon_choice(response, :melee)
    when 'weapon_ranged'
      handle_weapon_choice(response, :ranged)
    when 'autobattle'
      handle_autobattle_choice(response)
    end
  end

  # Build options for a given input stage
  def build_options_for_stage(stage)
    case stage
    when 'main_menu'
      build_main_menu_options
    when 'main_action'
      build_main_action_options
    when 'main_target'
      build_main_target_options
    when 'tactical_action'
      build_tactical_action_options
    when 'tactical_target'
      build_tactical_target_options
    when 'tactical_ability_target'
      build_tactical_ability_target_options
    when 'movement'
      build_movement_options
    when 'willpower'
      build_willpower_options
    when 'options'
      build_options_submenu
    when 'side_select'
      build_side_select_options
    when 'weapon_melee'
      build_weapon_options(:melee)
    when 'weapon_ranged'
      build_weapon_options(:ranged)
    when 'autobattle'
      build_autobattle_options
    else
      []
    end
  end

  # === Main Menu (Hub) ===

  def build_main_menu_options
    [
      {
        key: 'main',
        label: "Action #{checkmark(:main_action_set)}",
        description: main_action_summary
      },
      {
        key: 'tactical',
        label: "Tactic #{checkmark(:tactical_action_set)}",
        description: tactical_action_summary
      },
      {
        key: 'movement',
        label: "Movement #{checkmark(:movement_set)}",
        description: movement_summary
      },
      {
        key: 'willpower',
        label: "Use Willpower #{checkmark(:willpower_set)}",
        description: willpower_summary
      },
      {
        key: 'options',
        label: 'Options',
        description: 'Weapons, reckless movement'
      },
      {
        key: 'done',
        label: 'Done',
        description: done_validation_message
      }
    ]
  end

  def handle_main_menu_choice(response)
    case response
    when 'main'
      participant.update(input_stage: 'main_action')
    when 'tactical'
      participant.update(input_stage: 'tactical_action')
    when 'movement'
      participant.update(input_stage: 'movement')
    when 'willpower'
      participant.update(input_stage: 'willpower')
    when 'options'
      participant.update(input_stage: 'options')
    when 'done'
      # Mark input as complete and trigger round resolution
      complete_input!
      check_round_resolution
    end
  end

  # === Main Action Submenu ===

  def build_main_action_options
    # Check if stunned (blocks main actions)
    unless StatusEffectService.can_use_main_action?(participant)
      return [
        { key: 'stunned', label: 'STUNNED', description: 'You cannot take main actions while stunned', disabled: true },
        { key: 'back', label: '← Back', description: 'Return to main menu' }
      ]
    end

    options = [
      { key: 'attack', label: 'Attack', description: 'Attack with weapons' },
      { key: 'defend', label: 'Full Defense', description: 'Focus on defense, no attacks' },
      { key: 'dodge', label: 'Dodge', description: '-5 to each incoming attack against you' },
      { key: 'sprint', label: 'Sprint', description: '+3 movement (7 total), no other action' },
      { key: 'pass', label: 'Pass', description: 'Take no action (fight ends if all pass)' },
      { key: 'surrender', label: 'Surrender', description: 'Give up. Become helpless until after the fight.' }
    ]

    # Add extinguish option if burning
    if StatusEffectService.has_effect?(participant, 'burning')
      options << { key: 'extinguish', label: 'Extinguish', description: 'Spend your action to put out the flames' }
    end

    # Add stand up option if prone
    if StatusEffectService.is_prone?(participant)
      stand_cost = StatusEffectService.stand_cost(participant)
      options << { key: 'stand', label: 'Stand Up', description: "Spend #{stand_cost} movement to get up (required before moving)" }
    end

    # Add all available main action abilities
    participant.available_main_abilities.each do |ability|
      options << {
        key: "ability_#{ability.id}",
        label: ability.name,
        description: ability_description(ability)
      }
    end

    # Show unavailable abilities (grayed out)
    unavailable_main_abilities.each do |ability|
      options << {
        key: "ability_#{ability.id}",
        label: ability.name,
        description: "#{ability_cooldown_text(ability)} - Unavailable",
        disabled: true
      }
    end

    options << { key: 'back', label: '← Back', description: 'Return to main menu' }
    options
  end

  def handle_main_action_choice(response)
    case response
    when 'extinguish'
      # Spend action to remove burning
      if StatusEffectService.extinguish(participant)
        participant.update(
          main_action: 'pass',
          main_action_set: true,
          ability_id: nil,
          ability_choice: nil,
          pending_action_name: 'Extinguish flames',
          input_stage: 'main_menu'
        )
      else
        return_to_main_menu
      end
    when 'stand'
      # Remove prone status (costs movement handled separately)
      StatusEffectService.remove_effect(participant, 'prone')
      participant.update(
        main_action: 'stand',
        main_action_set: true,
        ability_id: nil,
        ability_choice: nil,
        pending_action_name: 'Stand up',
        input_stage: 'main_menu'
      )
    when 'attack'
      participant.update(
        main_action: 'attack',
        main_action_set: true,
        ability_id: nil,
        ability_choice: nil,
        pending_action_name: 'Attack',
        input_stage: 'main_target'
      )
    when 'defend'
      participant.update(
        main_action: 'defend',
        main_action_set: true,
        ability_id: nil,
        ability_choice: nil,
        pending_action_name: nil,
        input_stage: 'main_menu'
      )
    when 'dodge'
      participant.update(
        main_action: 'dodge',
        main_action_set: true,
        ability_id: nil,
        ability_choice: nil,
        pending_action_name: nil,
        target_participant_id: nil,
        input_stage: 'main_menu'
      )
    when 'pass'
      participant.update(
        main_action: 'pass',
        main_action_set: true,
        ability_id: nil,
        ability_choice: nil,
        pending_action_name: nil,
        target_participant_id: nil,
        input_stage: 'main_menu'
      )
    when 'sprint'
      participant.update(
        main_action: 'sprint',
        main_action_set: true,
        ability_id: nil,
        ability_choice: nil,
        pending_action_name: nil,
        target_participant_id: nil,
        input_stage: 'main_menu'
      )
    when 'surrender'
      participant.update(
        main_action: 'surrender',
        is_surrendering: true,
        main_action_set: true,
        ability_id: nil,
        ability_choice: nil,
        pending_action_name: nil,
        target_participant_id: nil,
        input_stage: 'main_menu'
      )
    when /^ability_(\d+)$/
      ability_id = ::Regexp.last_match(1).to_i
      ability = Ability[ability_id]
      return unless ability
      return unless ability_available_for_slot?(ability, :main)

      participant.update(
        main_action: 'ability',
        ability_id: ability_id,
        ability_choice: ability.name.downcase,
        pending_action_name: ability.name
      )

      # Check if ability needs target selection
      if ability.target_type == 'self'
        # Self-targeted: no target needed
        participant.update(
          main_action_set: true,
          ability_target_participant_id: participant.id,
          input_stage: 'main_menu'
        )
      else
        # Needs target selection
        participant.update(input_stage: 'main_target')
      end
    end
  end

  # === Main Target Submenu ===

  def build_main_target_options
    action_name = participant.pending_action_name || 'action'
    ability = participant.selected_ability

    # Reset taunt tracking
    @taunt_penalty = nil
    @must_target_id = nil

    options = eligible_targets_for_action(ability).map do |p|
      distance = participant.hex_distance_to(p)
      distance_int = distance.is_a?(Numeric) ? distance.round : distance.to_i

      # Check weapon range for attack action
      max_range = if ability
                    ability.range_in_hexes || 1
                  else
                    # Attack uses selected weapon
                    weapon = participant.melee_weapon || participant.ranged_weapon
                    weapon&.pattern&.range_in_hexes || 1
                  end

      # Build description with range warning
      desc = "#{status_text(p)}, #{distance_int} hex#{distance_int == 1 ? '' : 'es'} away"
      if distance_int > max_range
        desc = "⚠ OUT OF RANGE! #{desc} (need range #{max_range}, move closer or use ranged weapon)"
      end

      # Add taunt warnings
      if @must_target_id && p.id == @must_target_id
        desc = "⚠ TAUNTED - Must attack! #{desc}"
      elsif @must_target_id && @taunt_penalty
        desc = "#{desc} (#{@taunt_penalty} penalty if not attacking taunter)"
      end

      {
        key: p.id.to_s,
        label: p.character_name,
        description: desc
      }
    end

    # Add monsters as potential targets (for attacks)
    if ability.nil? || ability.target_type == 'enemy'
      targetable_monsters.each do |monster|
        hp_percent = monster.current_hp_percent
        options << {
          key: "monster_#{monster.id}",
          label: monster.display_name,
          description: "HP: #{hp_percent}%, #{monster_segment_status(monster)}"
        }
      end
    end

    options << { key: 'back', label: '← Back', description: 'Return to main action selection' }
    options
  end

  # Get targetable monsters in the fight
  def targetable_monsters
    return [] unless fight.has_monster

    LargeMonsterInstance.where(fight_id: fight.id, status: 'active').all
  end

  # Summary of monster segment status
  def monster_segment_status(monster)
    active = monster.active_segments.count
    total = monster.monster_segment_instances.count
    "#{active}/#{total} segments"
  end

  def handle_main_target_choice(response)
    ability = participant.selected_ability

    # Handle monster targeting
    if response =~ /^monster_(\d+)$/
      monster_id = ::Regexp.last_match(1).to_i
      monster = monster_for_fight(monster_id, active_only: true)
      can_target_monsters = ability.nil? || ability.target_type == 'enemy'
      return unless can_target_monsters

      if monster
        # Determine which segment to target
        segment = if participant.is_mounted && participant.targeting_monster_id == monster_id
                    # If mounted on this monster, target current segment
                    MonsterSegmentInstance[participant.targeting_segment_id]
                  else
                    # Otherwise, target closest segment
                    monster.closest_segment_to(participant.hex_x, participant.hex_y)
                  end

        participant.update(
          target_participant_id: nil,
          targeting_monster_id: monster_id,
          targeting_segment_id: segment&.id,
          ability_target_participant_id: nil,
          main_action_set: true,
          input_stage: 'main_menu'
        )
      end
      return
    end

    # Handle normal participant targeting
    target_id = response.to_i
    target = FightParticipant.first(id: target_id, fight_id: fight.id)
    valid_target = valid_main_target_for_action?(target, ability)

    if valid_target
      participant.update(
        target_participant_id: target_id,
        targeting_monster_id: nil,
        targeting_segment_id: nil,
        ability_target_participant_id: target_id,
        main_action_set: true,
        input_stage: 'main_menu'
      )
    end
  end

  # === Tactical Action Submenu ===

  def build_tactical_action_options
    # Check if dazed/stunned (blocks tactical actions)
    unless StatusEffectService.can_use_tactical_action?(participant)
      return [
        { key: 'dazed', label: 'DAZED', description: 'You cannot use tactical actions while dazed', disabled: true },
        { key: 'back', label: '← Back', description: 'Return to main menu' }
      ]
    end

    options = []

    # Add tactical abilities first (healing spells, buffs, etc.)
    participant.available_tactical_abilities.each do |ability|
      options << {
        key: "tactical_ability_#{ability.id}",
        label: ability.name,
        description: ability_description(ability)
      }
    end

    # Add separator if we have abilities
    if options.any?
      options << { key: 'divider', label: '── Stances ──', description: '', disabled: true }
    end

    # Add tactical stances
    options.concat([
      { key: 'aggressive', label: 'Aggressive', description: '+2 damage dealt, +2 damage taken' },
      { key: 'defensive', label: 'Defensive', description: '-2 damage dealt, -2 damage taken' },
      { key: 'quick', label: 'Quick', description: '+1 movement, -1 dealt, +1 taken' },
      { key: 'guard', label: 'Guard', description: 'Protect adjacent ally (50% redirect, +2 dmg)' },
      { key: 'back_to_back', label: 'Back to Back', description: '25% redirect both ways, 50% if mutual' },
      { key: 'none', label: 'None', description: 'No tactical stance or ability' },
      { key: 'back', label: '← Back', description: 'Return to main menu' }
    ])

    options
  end

  def handle_tactical_action_choice(response)
    case response
    when 'aggressive', 'defensive', 'quick'
      # Simple tactics - set directly and return to main menu
      participant.update(
        tactic_choice: response,
        tactic_target_participant_id: nil,
        tactical_action_set: true,
        tactical_ability_id: nil,
        input_stage: 'main_menu'
      )
    when 'guard', 'back_to_back'
      # Protection tactics - need ally target selection
      participant.update(
        tactic_choice: response,
        tactical_ability_id: nil,
        input_stage: 'tactical_target'
      )
    when 'none'
      participant.update(
        tactic_choice: nil,
        tactic_target_participant_id: nil,
        tactical_action_set: true,
        tactical_ability_id: nil,
        input_stage: 'main_menu'
      )
    when /^tactical_ability_(\d+)$/
      # Tactical ability selected
      ability_id = ::Regexp.last_match(1).to_i
      ability = Ability[ability_id]
      return unless ability
      return unless ability_available_for_slot?(ability, :tactical)

      participant.update(
        tactical_ability_id: ability_id,
        tactic_choice: nil # Clear any stance when using an ability
      )

      # Check if ability needs target selection
      if ability.target_type == 'self'
        # Self-targeted: no target needed
        participant.update(
          tactical_action_set: true,
          tactic_target_participant_id: participant.id,
          input_stage: 'main_menu'
        )
      else
        # Needs target selection
        participant.update(input_stage: 'tactical_ability_target')
      end
    end
  end

  # === Tactical Target Submenu ===

  def build_tactical_target_options
    # For Guard/Back-to-Back, show allies on same side (not self)
    allies = fight.active_participants
                  .where(side: participant.side)
                  .exclude(id: participant.id)

    options = allies.map do |p|
      distance = participant.hex_distance_to(p)
      adjacent_text = distance <= 1 ? '(adjacent)' : "(#{distance} hexes)"
      {
        key: p.id.to_s,
        label: p.character_name,
        description: "#{status_text(p)} #{adjacent_text}"
      }
    end

    options << { key: 'back', label: '← Back', description: 'Return to tactical action selection' }
    options
  end

  def handle_tactical_target_choice(response)
    target_id = response.to_i
    target = FightParticipant.first(id: target_id, fight_id: fight.id)
    valid_target = target && target.id != participant.id
    if valid_target && target.respond_to?(:side) && participant.respond_to?(:side)
      valid_target = (target.side == participant.side)
    end

    if valid_target
      participant.update(
        tactic_target_participant_id: target_id,
        tactical_action_set: true,
        input_stage: 'main_menu'
      )

      # Send immediate notification to the protected ally
      send_protection_notification(target)
    end
  end

  # Notify ally that they're being protected
  def send_protection_notification(target_participant)
    message = case participant.tactic_choice
              when 'guard'
                "#{participant.character_name} is guarding you!"
              when 'back_to_back'
                "#{participant.character_name} wants to fight back-to-back with you!"
              end

    return unless message

    BroadcastService.to_character(
      target_participant.character_instance,
      message,
      type: :combat
    )
  end

  # === Tactical Ability Target Submenu ===

  def build_tactical_ability_target_options
    ability = Ability[participant.tactical_ability_id]
    return [{ key: 'back', label: '← Back', description: 'Return to tactical action selection' }] unless ability

    # Get eligible targets based on ability type
    targets = eligible_targets_for_tactical_ability(ability)

    options = targets.map do |p|
      # Safe distance calculation - nil if positions unknown
      distance = participant.respond_to?(:hex_distance_to) ? participant.hex_distance_to(p) : nil
      distance = distance&.to_i

      # Check range - treat nil distance as in-range, use config default for nil range
      ability_range = ability.respond_to?(:range_in_hexes) ? ability.range_in_hexes : nil
      ability_range ||= GameConfig::AbilityDefaults::DEFAULT_RANGE_HEXES
      in_range = distance.nil? || distance <= ability_range
      range_text = in_range ? '' : ' (out of range)'

      {
        key: p.id.to_s,
        label: p.character_name,
        description: "#{status_text(p)}#{range_text}",
        disabled: !in_range
      }
    end

    options << { key: 'back', label: '← Back', description: 'Return to tactical action selection' }
    options
  end

  def eligible_targets_for_tactical_ability(ability)
    case ability.target_type
    when 'ally', 'allies'
      # Target allies on same side (including self)
      fight.active_participants.where(side: participant.side).to_a
    when 'enemy', 'enemies'
      # Target enemies on different sides
      fight.active_participants.exclude(side: participant.side).to_a
    when 'self'
      # Only self
      [participant]
    else
      # Default: can target anyone
      fight.active_participants.to_a
    end
  end

  def handle_tactical_ability_target_choice(response)
    if response == 'back'
      participant.update(input_stage: 'tactical_action')
      return
    end

    target_id = response.to_i
    target = FightParticipant.first(id: target_id, fight_id: fight.id)
    ability = Ability[participant.tactical_ability_id]
    return unless ability
    valid_target = valid_tactical_ability_target?(target, ability)

    if valid_target && tactical_ability_target_in_range?(ability, target)
      participant.update(
        tactic_target_participant_id: target_id,
        tactical_action_set: true,
        input_stage: 'main_menu'
      )
    end
  end

  # === Movement Submenu ===

  def build_movement_options
    # If mounted on a monster, show mounted movement options
    if participant.is_mounted && participant.targeting_monster_id
      return build_mounted_movement_options
    end

    options = [
      { key: 'stand_still', label: 'Stand Still', description: 'Hold your position' }
    ]

    # Add flee options if at arena edge with valid exit
    if participant.can_flee?
      participant.available_flee_exits.each do |flee_opt|
        destination = flee_opt[:exit]&.name || 'adjacent room'
        options << {
          key: "flee_#{flee_opt[:direction]}",
          label: "Flee #{flee_opt[:direction].capitalize}",
          description: "Escape to #{destination}. Must take no damage."
        }
      end
    end

    # Check for adjacent monsters that can be mounted
    adjacent_monsters.each do |monster|
      options << {
        key: "mount_monster_#{monster.id}",
        label: "Mount #{monster.display_name}",
        description: 'Climb onto the monster'
      }
    end

    # Add options for each other participant
    fight.active_participants.exclude(id: participant.id).each do |p|
      distance = participant.hex_distance_to(p)
      options << {
        key: "towards_#{p.id}",
        label: "Move toward #{p.character_name}",
        description: "Currently #{distance} hex#{distance == 1 ? '' : 'es'} away"
      }
      options << {
        key: "away_#{p.id}",
        label: "Move away from #{p.character_name}",
        description: 'Retreat and create distance'
      }
      options << {
        key: "maintain_6_#{p.id}",
        label: "Maintain 6 hex from #{p.character_name}",
        description: 'Keep optimal ranged distance'
      }
    end

    options << { key: 'back', label: '← Back', description: 'Return to main menu' }
    options
  end

  # Movement options when mounted on a monster
  def build_mounted_movement_options
    monster = monster_for_fight(participant.targeting_monster_id)
    mount_state = MonsterMountState.first(
      large_monster_instance_id: monster&.id,
      fight_participant_id: participant.id
    )

    options = []

    # Climbing progress info
    if mount_state
      progress = mount_state.climb_progress || 0
      total = monster&.monster_template&.climb_distance || 3
      at_weak_point = mount_state.at_weak_point?

      if at_weak_point
        options << {
          key: 'at_weak_point',
          label: '⚔ At Weak Point!',
          description: 'Your next attack deals 3x damage to ALL segments!',
          disabled: true
        }
      else
        options << {
          key: 'climb',
          label: 'Climb',
          description: "Progress toward weak point (#{progress}/#{total})"
        }
      end
    else
      options << {
        key: 'climb',
        label: 'Climb',
        description: 'Progress toward weak point'
      }
    end

    options << {
      key: 'cling',
      label: 'Cling',
      description: 'Hold position safely (immune to shake-off)'
    }

    options << {
      key: 'dismount',
      label: 'Dismount',
      description: 'Safely drop to an adjacent hex'
    }

    options << { key: 'back', label: '← Back', description: 'Return to main menu' }
    options
  end

  # Find monsters adjacent to the participant that can be mounted
  def adjacent_monsters
    return [] unless fight.has_monster

    LargeMonsterInstance.where(fight_id: fight.id, status: 'active').all.select do |monster|
      hex_service = MonsterHexService.new(monster)
      hex_service.adjacent_to_monster?(participant)
    end
  end

  def handle_movement_choice(response)
    case response
    when 'stand_still'
      participant.update(
        movement_action: 'stand_still',
        movement_target_participant_id: nil,
        movement_set: true,
        input_stage: 'main_menu'
      )
    when /^towards_(\d+)$/
      target_id = ::Regexp.last_match(1).to_i
      participant.update(
        movement_action: 'towards_person',
        movement_target_participant_id: target_id,
        movement_set: true,
        input_stage: 'main_menu'
      )
    when /^away_(\d+)$/
      target_id = ::Regexp.last_match(1).to_i
      participant.update(
        movement_action: 'away_from',
        movement_target_participant_id: target_id,
        movement_set: true,
        input_stage: 'main_menu'
      )
    when /^maintain_6_(\d+)$/
      target_id = ::Regexp.last_match(1).to_i
      participant.update(
        movement_action: 'maintain_distance',
        movement_target_participant_id: target_id,
        maintain_distance_range: 6,
        movement_set: true,
        input_stage: 'main_menu'
      )
    when /^mount_monster_(\d+)$/
      # Mount a monster
      monster_id = ::Regexp.last_match(1).to_i
      process_mount_action(monster_id)
      participant.update(
        movement_set: true,
        input_stage: 'main_menu'
      )
    when 'climb'
      # Climb toward weak point while mounted
      process_climb_action
      participant.update(
        mount_action: 'climb',
        movement_set: true,
        input_stage: 'main_menu'
      )
    when 'cling'
      # Cling to monster (safe from shake-off)
      process_cling_action
      participant.update(
        mount_action: 'cling',
        movement_set: true,
        input_stage: 'main_menu'
      )
    when 'dismount'
      # Dismount from monster
      process_dismount_action
      participant.update(
        movement_set: true,
        input_stage: 'main_menu'
      )
    when /^flee_(\w+)$/
      # Flee toward an exit
      direction = ::Regexp.last_match(1)
      flee_exit = participant.available_flee_exits.find { |f| f[:direction] == direction }
      if flee_exit
        participant.update(
          movement_action: 'flee',
          is_fleeing: true,
          flee_direction: direction,
          flee_exit_id: flee_exit[:exit].id,
          movement_set: true,
          input_stage: 'main_menu'
        )
      end
    end
  end

  # === Monster Mount Actions ===

  def process_mount_action(monster_id)
    monster = monster_for_fight(monster_id, active_only: true)
    return unless monster

    mounting_service = MonsterMountingService.new(fight)
    result = mounting_service.attempt_mount(participant, monster)

    if result[:success]
      participant.update(
        targeting_monster_id: monster.id,
        targeting_segment_id: result[:segment]&.id,
        is_mounted: true,
        mount_action: 'cling'
      )
    end
  end

  def process_climb_action
    return unless participant.is_mounted && participant.targeting_monster_id

    monster = monster_for_fight(participant.targeting_monster_id)
    return unless monster

    mount_state = MonsterMountState.first(
      large_monster_instance_id: monster.id,
      fight_participant_id: participant.id
    )
    return unless mount_state

    mounting_service = MonsterMountingService.new(fight)
    mounting_service.process_climb(mount_state)
  end

  def process_cling_action
    return unless participant.is_mounted && participant.targeting_monster_id

    monster = monster_for_fight(participant.targeting_monster_id)
    return unless monster

    mount_state = MonsterMountState.first(
      large_monster_instance_id: monster.id,
      fight_participant_id: participant.id
    )
    return unless mount_state

    mounting_service = MonsterMountingService.new(fight)
    mounting_service.process_cling(mount_state)
  end

  def process_dismount_action
    return unless participant.is_mounted && participant.targeting_monster_id

    monster = monster_for_fight(participant.targeting_monster_id)
    return unless monster

    mount_state = MonsterMountState.first(
      large_monster_instance_id: monster.id,
      fight_participant_id: participant.id
    )
    return unless mount_state

    mounting_service = MonsterMountingService.new(fight)
    result = mounting_service.process_dismount(mount_state)

    if result[:success]
      participant.update(
        hex_x: result[:landing_position][0],
        hex_y: result[:landing_position][1],
        is_mounted: false,
        targeting_monster_id: nil,
        targeting_segment_id: nil,
        mount_action: nil
      )
    end
  end

  # Resolve monster IDs strictly within the current fight.
  # Prevents cross-fight targeting via crafted quickmenu responses.
  def monster_for_fight(monster_id, active_only: false)
    return nil unless monster_id

    # Prefer direct lookup for compatibility with mocked/unit-test paths.
    monster = LargeMonsterInstance[monster_id]
    if monster
      if monster.respond_to?(:fight_id) && monster.fight_id && monster.fight_id != fight.id
        return nil
      end
      return nil if active_only && monster.respond_to?(:status) && monster.status != 'active'

      return monster
    end

    dataset = LargeMonsterInstance.where(id: monster_id, fight_id: fight.id)
    dataset = dataset.where(status: 'active') if active_only
    dataset.first
  end

  # === Willpower Submenu ===

  def build_willpower_options
    available = [participant.available_willpower_dice, MAX_WILLPOWER_SPEND].min

    if available == 0
      return [
        { key: 'skip', label: 'No willpower available', description: 'You have no dice to spend' },
        { key: 'back', label: '← Back', description: 'Return to main menu' }
      ]
    end

    options = []

    # Attack options (willpower adds extra d8s to attack roll)
    (1..available).each do |n|
      options << {
        key: "attack_#{n}",
        label: "Attack +#{n}d8",
        description: "Spend #{n} #{n == 1 ? 'die' : 'dice'} to roll #{n}d8 extra attack damage (explodes on 8)"
      }
    end

    # Defense options (willpower rolls defense dice as armor)
    (1..available).each do |n|
      options << {
        key: "defense_#{n}",
        label: "Defense #{n}d8",
        description: "Spend #{n} #{n == 1 ? 'die' : 'dice'} to roll #{n}d8 armor (explodes on 8)"
      }
    end

    # Movement options (willpower rolls d8s, gives half as bonus movement)
    (1..available).each do |n|
      options << {
        key: "movement_#{n}",
        label: "Movement #{n}d8÷2",
        description: "Spend #{n} #{n == 1 ? 'die' : 'dice'} to roll #{n}d8, gain half as bonus hexes (explodes on 8)"
      }
    end

    # Ability options (only if main action is ability)
    if participant.main_action == 'ability'
      (1..available).each do |n|
        options << {
          key: "ability_#{n}",
          label: "Ability +#{n}d8",
          description: "Spend #{n} #{n == 1 ? 'die' : 'dice'} to roll #{n}d8 extra ability damage (explodes on 8)"
        }
      end
    end

    options << { key: 'skip', label: 'Skip', description: "Save all #{participant.available_willpower_dice} dice for later" }
    options << { key: 'back', label: '← Back', description: 'Return to main menu' }
    options
  end

  def handle_willpower_choice(response)
    case response
    when 'skip'
      participant.set_willpower_allocation!(attack: 0, defense: 0, ability: 0, movement: 0)
      participant.update(
        willpower_set: true,
        input_stage: 'main_menu'
      )
    when /^(attack|defense|movement|ability)_(\d+)$/
      type = ::Regexp.last_match(1)
      count = ::Regexp.last_match(2).to_i

      allocations = { attack: 0, defense: 0, ability: 0, movement: 0 }
      allocations[type.to_sym] = count

      participant.set_willpower_allocation!(**allocations)
      participant.update(
        willpower_set: true,
        input_stage: 'main_menu'
      )
    end
  end

  # === Options Submenu ===

  def build_options_submenu
    hazard_status = participant.ignore_hazard_avoidance ? 'ON' : 'OFF'
    options = [
      { key: 'melee', label: 'Select Melee Weapon', description: current_melee_weapon_name },
      { key: 'ranged', label: 'Select Ranged Weapon', description: current_ranged_weapon_name }
    ]

    # Autobattle option
    options << {
      key: 'autobattle',
      label: "Autobattle [#{autobattle_status}]",
      description: 'Let AI control your combat choices'
    }

    # Only show hazard toggle if battle map is active
    if battle_map_active?
      options << {
        key: 'ignore_hazard',
        label: "Ignore Hazard Avoidance [#{hazard_status}]",
        description: 'Path through fire/hazards when chasing'
      }
    end

    # Show current side and allow switching
    side_count = side_fighter_counts
    options << {
      key: 'side',
      label: "Change Side [Currently: #{participant.side}]",
      description: side_count.map { |s, c| "Side #{s}: #{c}" }.join(', ')
    }

    options << { key: 'back', label: '← Back', description: 'Return to main menu' }
    options
  end

  def handle_options_choice(response)
    case response
    when 'melee'
      participant.update(input_stage: 'weapon_melee')
    when 'ranged'
      participant.update(input_stage: 'weapon_ranged')
    when 'autobattle'
      participant.update(input_stage: 'autobattle')
    when 'ignore_hazard'
      new_value = !participant.ignore_hazard_avoidance
      participant.update(ignore_hazard_avoidance: new_value, input_stage: 'options')
      participant.character_instance&.set_combat_preference(:ignore_hazard_avoidance, new_value)
    when 'side'
      participant.update(input_stage: 'side_select')
    end
  end

  # Get count of fighters on each side
  def side_fighter_counts
    fight.active_participants.group_and_count(:side).to_hash(:side, :count)
  end

  # === Side Selection ===

  def build_side_select_options
    side_counts = side_fighter_counts
    current_sides = side_counts.keys.sort

    options = current_sides.map do |side|
      count = side_counts[side]
      is_current = side == participant.side
      label = is_current ? "Side #{side} (Current)" : "Side #{side}"
      {
        key: side.to_s,
        label: label,
        description: "#{count} fighter#{count == 1 ? '' : 's'}"
      }
    end

    # Option to create a new side
    next_side = (current_sides.max || 0) + 1
    options << {
      key: 'new',
      label: "Create Side #{next_side}",
      description: 'Start a new faction'
    }

    options << { key: 'back', label: '← Back', description: 'Return to options' }
    options
  end

  def handle_side_select_choice(response)
    if response == 'back'
      participant.update(input_stage: 'options')
      return
    end

    if response == 'new'
      # Create a new side
      max_side = fight.fight_participants_dataset.max(:side) || 1
      participant.update(side: max_side + 1, input_stage: 'options')
    else
      # Switch to existing side
      new_side = response.to_i
      if new_side > 0
        participant.update(side: new_side, input_stage: 'options')
      end
    end
  end

  # Check if battle map features are active
  def battle_map_active?
    return false unless fight

    fight.uses_battle_map && fight.room&.has_battle_map
  end

  # === Weapon Selection ===

  def build_weapon_options(weapon_type)
    weapons = find_available_weapons(weapon_type)

    options = weapons.map do |w|
      speed = w.pattern&.attack_speed || 5
      range = w.pattern&.weapon_range || 'melee'
      plain_name = w.name.to_s.gsub(/<[^>]*>/, '')
      {
        key: w.id.to_s,
        label: plain_name,
        description: "Speed: #{speed}, Range: #{range}"
      }
    end

    if weapon_type == :melee
      options << {
        key: 'unarmed',
        label: 'Unarmed',
        description: 'Fight with fists (Speed 5, Melee only)'
      }
    else
      options << {
        key: 'none',
        label: 'No Ranged Weapon',
        description: 'Skip ranged attacks'
      }
    end

    options << { key: 'back', label: '← Back', description: 'Return to options' }
    options
  end

  def handle_weapon_choice(response, weapon_type)
    if response == 'back'
      participant.update(input_stage: 'options')
      return
    end

    ci = participant.character_instance
    if weapon_type == :melee
      if response == 'unarmed'
        participant.update(melee_weapon_id: nil, input_stage: 'options')
        ci&.set_combat_preference(:melee_weapon_id, nil)
      else
        weapon_id = response.to_i
        participant.update(melee_weapon_id: weapon_id, input_stage: 'options')
        ci&.set_combat_preference(:melee_weapon_id, weapon_id)
      end
    else
      if response == 'none'
        participant.update(ranged_weapon_id: nil, input_stage: 'options')
        ci&.set_combat_preference(:ranged_weapon_id, nil)
      else
        weapon_id = response.to_i
        participant.update(ranged_weapon_id: weapon_id, input_stage: 'options')
        ci&.set_combat_preference(:ranged_weapon_id, weapon_id)
      end
    end
  end

  # === Helper Methods ===

  def return_to_main_menu
    participant.update(input_stage: 'main_menu')
  end

  def checkmark(field)
    participant.send(field) ? '✓' : ''
  end

  def can_complete?
    # Main action is required
    participant.main_action_set
  end

  def done_validation_message
    return 'Ready to submit' if can_complete?

    'Choose a main action first'
  end

  def main_action_summary
    return 'Not set' unless participant.main_action_set

    case participant.main_action
    when 'attack'
      if participant.targeting_monster_id
        monster = monster_for_fight(participant.targeting_monster_id)
        segment = MonsterSegmentInstance[participant.targeting_segment_id]
        if monster
          segment_info = segment ? " (#{segment.name})" : ''
          "Attack #{monster.display_name}#{segment_info}"
        else
          'Attack monster'
        end
      else
        target = participant.target_participant
        target ? "Attack #{target.character_name}" : 'Attack'
      end
    when 'defend'
      'Full Defense'
    when 'dodge'
      'Dodge (-5 to incoming)'
    when 'pass'
      'Pass (no action)'
    when 'sprint'
      'Sprint (+3 movement)'
    when 'ability'
      ability = participant.selected_ability
      ability ? ability.name : 'Ability'
    else
      'Set'
    end
  end

  def tactical_action_summary
    return 'Not set' unless participant.tactical_action_set

    # Check for tactical ability first
    if participant.tactical_ability_id
      ability = Ability[participant.tactical_ability_id]
      if ability
        target = participant.tactic_target_participant
        return target ? "#{ability.name} → #{target.character_name}" : ability.name
      end
    end

    case participant.tactic_choice
    when 'aggressive'
      'Aggressive (+2/-2)'
    when 'defensive'
      'Defensive (-2/+2)'
    when 'quick'
      'Quick (+1 move)'
    when 'guard'
      target = participant.tactic_target_participant
      target ? "Guard #{target.character_name}" : 'Guard'
    when 'back_to_back'
      target = participant.tactic_target_participant
      target ? "Back-to-Back with #{target.character_name}" : 'Back to Back'
    else
      'None'
    end
  end

  def movement_summary
    return 'Not set' unless participant.movement_set

    case participant.movement_action
    when 'stand_still'
      'Stand Still'
    when 'towards_person'
      target = FightParticipant[participant.movement_target_participant_id]
      target ? "Toward #{target.character_name}" : 'Moving toward target'
    when 'away_from'
      target = FightParticipant[participant.movement_target_participant_id]
      target ? "Away from #{target.character_name}" : 'Moving away'
    when 'maintain_distance'
      "Maintain #{participant.maintain_distance_range || 6} hex"
    else
      'Set'
    end
  end

  def willpower_summary
    available = participant.available_willpower_dice
    return "#{available} dice available" unless participant.willpower_set

    if (participant.willpower_attack || 0) > 0
      "Attack +#{participant.willpower_attack}d8"
    elsif (participant.willpower_defense || 0) > 0
      "Defense #{participant.willpower_defense}d8"
    elsif (participant.willpower_movement || 0) > 0
      "Movement #{participant.willpower_movement}d8÷2"
    elsif (participant.willpower_ability || 0) > 0
      "Ability +#{participant.willpower_ability}d8"
    else
      'Skipped'
    end
  end

  def ability_description(ability)
    parts = []

    # Show damage range (e.g., "2d6 fire [2-12]" or "1d8+2 [3-10]")
    if ability.base_damage_dice
      dice_str = ability.base_damage_dice
      min_dmg = ability.min_damage
      max_dmg = ability.max_damage
      damage_info = "#{dice_str} [#{min_dmg}-#{max_dmg}]"
      damage_info += " #{ability.damage_type}" if ability.damage_type
      parts << damage_info
    end

    # Special effects
    parts << 'heals' if ability.healing_ability?
    parts << "AoE:#{ability.aoe_shape}" if ability.has_aoe?
    parts << 'chain' if ability.has_chain?
    parts << 'lifesteal' if ability.has_lifesteal?
    parts << 'execute' if ability.has_execute?
    parts << 'knockdown' if ability.applies_prone
    parts << 'push' if ability.has_forced_movement?

    # Cooldown info
    parts << ability_cooldown_text(ability) unless ability_cooldown_text(ability).empty?

    parts.join(', ')
  end

  def ability_cooldown_text(ability)
    parts = []
    parts << "#{ability.specific_cooldown_rounds}rd CD" if ability.specific_cooldown_rounds > 0
    parts << "#{ability.global_cooldown_rounds}rd GCD" if ability.global_cooldown_rounds > 0
    if ability.ability_penalty_config.any?
      amount = ability.ability_penalty_config['amount']
      parts << "#{amount} penalty"
    end
    parts.empty? ? '' : "[#{parts.join(', ')}]"
  end

  def eligible_targets_for_action(ability)
    targets = if ability.nil?
                # Attack - targets enemies (on different sides)
                fight.active_participants
                     .exclude(side: participant.side)
                     .exclude(id: participant.id)
              elsif ability.target_type == 'ally'
                # Heal/buff - targets self and allies (same side)
                fight.active_participants.where(side: participant.side)
              elsif ability.target_type == 'enemy'
                # Offensive - enemies only (different sides)
                fight.active_participants.exclude(side: participant.side)
              else
                # Self - shouldn't get here, but just in case
                [participant]
              end

    # Filter out protected targets (cannot be targeted due to effects like Sanctuary)
    targets = filter_targets_by_protection(targets)

    # Apply taunt restrictions (if taunted, must target taunter or suffer penalty)
    filter_targets_by_taunt(targets)
  end

  # Filter out targets that are protected from being targeted
  # Effects with cannot_target_id prevent specific participants from being attacked
  def filter_targets_by_protection(targets)
    protected_ids = StatusEffectService.cannot_target_ids(participant)
    return targets if protected_ids.empty?

    targets.reject { |t| protected_ids.include?(t.id) }
  end

  # Filter targets by taunt effects
  # If taunted, prioritize the taunter but still show others with warning
  def filter_targets_by_taunt(targets)
    must_target_id = StatusEffectService.must_target(participant)
    return targets unless must_target_id

    # Find the taunter
    taunter = targets.find { |t| t.id == must_target_id }
    return targets unless taunter

    # Reorder so taunter is first, add penalty warning to others
    penalty = StatusEffectService.taunt_penalty(participant)
    reordered = [taunter] + targets.reject { |t| t.id == must_target_id }

    # Mark non-taunter targets with penalty info (handled in build_main_target_options)
    @taunt_penalty = penalty
    @must_target_id = must_target_id
    reordered
  end

  def tactical_ability_target_in_range?(ability, target)
    distance = participant.respond_to?(:hex_distance_to) ? participant.hex_distance_to(target) : nil
    range = ability.respond_to?(:range_in_hexes) ? ability.range_in_hexes : nil
    range ||= GameConfig::AbilityDefaults::DEFAULT_RANGE_HEXES
    distance.nil? || distance <= range
  end

  def valid_main_target_for_action?(target, ability)
    return false unless target
    return false if target.id == participant.id
    return false if StatusEffectService.cannot_target_ids(participant).include?(target.id)
    if ability && !ability.self_targeted? && !tactical_ability_target_in_range?(ability, target)
      return false
    end

    return true unless target.respond_to?(:side) && participant.respond_to?(:side)

    if ability.nil?
      target.side != participant.side
    elsif ability.target_type == 'ally'
      target.side == participant.side
    elsif ability.target_type == 'enemy'
      target.side != participant.side
    else
      true
    end
  end

  def valid_tactical_ability_target?(target, ability)
    return false unless target
    return false if StatusEffectService.cannot_target_ids(participant).include?(target.id)
    return true unless target.respond_to?(:side) && participant.respond_to?(:side)

    case ability.target_type
    when 'ally', 'allies'
      target.side == participant.side
    when 'enemy', 'enemies'
      target.side != participant.side
    when 'self'
      target.id == participant.id
    else
      true
    end
  end

  def unavailable_main_abilities
    all_main = participant.all_combat_abilities.select(&:main_action?)
    available = participant.available_main_abilities
    all_main - available
  end

  # Validate chosen ability against currently available abilities.
  # If availability list is empty (legacy/test flows), allow by fallback.
  def ability_available_for_slot?(ability, slot)
    available = if slot == :tactical
                  participant.available_tactical_abilities
                else
                  participant.available_main_abilities
                end
    available_list = available.respond_to?(:to_a) ? available.to_a : Array(available)
    return true if available_list.empty?

    available_list.any? { |candidate| candidate&.id == ability.id }
  end


  def current_melee_weapon_name
    weapon = participant.melee_weapon
    weapon ? weapon.name.to_s.gsub(/<[^>]*>/, '') : 'Unarmed'
  end

  def current_ranged_weapon_name
    weapon = participant.ranged_weapon
    weapon ? weapon.name.to_s.gsub(/<[^>]*>/, '') : 'None'
  end

  def find_available_weapons(weapon_type)
    Item.where(character_instance_id: char_instance.id)
        .eager(:pattern)
        .all
        .select do |item|
          pattern = item.pattern
          next false unless pattern&.weapon?

          if weapon_type == :melee
            pattern.is_melee
          else
            pattern.is_ranged
          end
        end
  end

  # === Autobattle System ===

  def autobattle_status
    return 'OFF' unless participant.autobattle_enabled?

    participant.autobattle_style.upcase
  end

  def build_autobattle_options
    [
      {
        key: 'aggressive',
        label: 'Aggressive',
        description: '+2 dmg dealt/taken, prioritize attacks, charge enemies'
      },
      {
        key: 'defensive',
        label: 'Defensive',
        description: '-2 dmg dealt/taken, prioritize survival, retreat when hurt'
      },
      {
        key: 'supportive',
        label: 'Supportive',
        description: 'Prioritize healing/buffs, protect allies, stay back'
      },
      {
        key: 'off',
        label: 'Turn Off',
        description: 'Return to manual combat control'
      },
      {
        key: 'back',
        label: '← Back',
        description: 'Return to options'
      }
    ]
  end

  def handle_autobattle_choice(response)
    case response
    when 'aggressive', 'defensive', 'supportive'
      begin
        participant.update(autobattle_style: response)
        apply_and_submit_autobattle!
      rescue StandardError => e
        warn "[AUTOBATTLE] Error in handle_autobattle_choice: #{e.class}: #{e.message}"
        warn e.backtrace.first(10).join("\n")
        raise e
      end
    when 'off'
      participant.update(autobattle_style: nil, input_stage: 'main_menu')
    when 'back'
      participant.update(input_stage: 'options')
    end
  end

  def apply_and_submit_autobattle!
    # Apply AI decisions
    ai = AutobattleAIService.new(participant)
    decisions = ai.decide!

    # Filter out keys that don't exist as columns (tactical_action comes from base class but column is tactic_choice)
    valid_keys = %i[
      main_action main_action_set ability_id ability_choice ability_target_participant_id
      target_participant_id tactic_choice tactic_target_participant_id tactical_action_set
      tactical_ability_id movement_action movement_target_participant_id movement_set
      maintain_distance_range willpower_attack willpower_defense willpower_ability willpower_set
    ]
    filtered_decisions = decisions.compact.select { |k, _| valid_keys.include?(k) }

    # Mark actions as set
    filtered_decisions[:main_action_set] = true if filtered_decisions[:main_action]
    filtered_decisions[:tactical_action_set] = true if filtered_decisions[:tactic_choice]
    filtered_decisions[:movement_set] = true if filtered_decisions[:movement_action]
    filtered_decisions[:willpower_set] = true

    # Update participant with decisions
    participant.update(filtered_decisions)

    # Build summary message
    summary = build_autobattle_summary(decisions)

    # Complete input (auto-submit)
    participant.complete_input!

    # Send summary to player
    send_autobattle_feedback(summary)

    # Check if round can advance
    check_round_resolution
  end

  def build_autobattle_summary(decisions)
    style = participant.autobattle_style.capitalize
    parts = []

    # Action + target
    if decisions[:ability_id]
      ability = Ability[decisions[:ability_id]]
      parts << (ability&.name || 'Ability')
    else
      parts << (decisions[:main_action] || 'pass').capitalize
    end

    if decisions[:target_participant_id]
      target = FightParticipant[decisions[:target_participant_id]]
      parts << target.character_name if target
    end

    # Movement (skip if holding position - not interesting)
    movement = decisions[:movement_action] || 'stand_still'
    unless movement == 'stand_still'
      movement_desc = case movement
                      when 'towards_person' then 'Charge'
                      when 'away_from' then 'Retreat'
                      when 'maintain_distance' then 'Keep distance'
                      else movement.tr('_', ' ').capitalize
                      end
      parts << movement_desc
    end

    # Willpower (skip if 0)
    wp_total = (decisions[:willpower_attack] || 0) +
               (decisions[:willpower_defense] || 0) +
               (decisions[:willpower_ability] || 0)
    parts << "+#{wp_total} WP" if wp_total > 0

    "<span class=\"opacity-60\">[Auto/#{style}] #{parts.join(' &middot; ')}</span>"
  end

  def send_autobattle_feedback(summary)
    BroadcastService.to_character(
      participant.character_instance,
      summary,
      type: :system
    )
  end

  # === Round Resolution ===

  def check_round_resolution
    fight.reload
    fight_service = FightService.new(fight)

    return unless fight_service.ready_to_resolve?

    @round_resolved = true
    resolution_result = nil
    narrative = nil
    resolution_error = nil

    # Step 1: Resolve the round (updates fight status to 'resolving' then 'narrative')
    begin
      resolution_result = fight_service.resolve_round!
    rescue StandardError => e
      resolution_error = e
      log_resolution_error('resolve_round', e)
    end

    if resolution_error
      force_recovery_transition(fight_service)
      return
    end

    # Step 2: Broadcast roll display and calculate dice animation duration
    dice_duration_ms = 0
    if resolution_result.is_a?(Hash) && resolution_result[:roll_display]
      begin
        broadcast_roll_display(resolution_result[:roll_display])
        # Calculate max animation duration across all participants' dice
        resolution_result[:roll_display].each do |roll_data|
          (roll_data[:animations] || []).each do |anim|
            dur = DiceRollService.calculate_animation_duration_ms(anim)
            dice_duration_ms = dur if dur > dice_duration_ms
          end
        end
        # Add 1s buffer for the +1000ms the client adds after animation
        dice_duration_ms += 1000 if dice_duration_ms > 0
      rescue StandardError => e
        log_resolution_error('broadcast_roll_display', e)
      end
    end

    # Step 3: Generate narrative
    narrative = fight_service.generate_narrative

    # Step 4: Broadcast narrative + damage summary as single message (non-critical)
    # Combined into one message to guarantee ordering (WebSocket pub/sub can reorder rapid separate messages)
    # Include dice_duration_ms so client can delay display until dice animation completes
    begin
      combined = narrative
      if resolution_result.is_a?(Hash) && resolution_result[:damage_summary]
        combined = "#{narrative}\n<dmg>#{resolution_result[:damage_summary]}</dmg>"
      end
      broadcast_combat_narrative(combined, dice_duration_ms: dice_duration_ms)

      # Save narrative to RP log (without damage summary - that's OOC info)
      RpLoggingService.log_to_room(
        fight.room_id, narrative,
        sender: nil, type: 'combat',
        html: narrative
      )
    rescue StandardError => e
      log_resolution_error('broadcast_narrative', e)
    end

    # Personal combat summaries (e.g., "You dealt 3 damage to Bob") removed -
    # the narrative + damage summary brackets already convey this information

    # Step 4.75: Push updated status bar (HP) to all participants
    begin
      push_status_bar_updates
    rescue StandardError => e
      log_resolution_error('status_bar_push', e)
    end

    # Step 5: Transition to next state - THIS MUST SUCCEED
    # If we got here, the round has been processed. We MUST transition the fight.
    begin
      fight.reload
      if fight.status == 'complete'
        # Fight already ended during resolution (e.g., knockout)
        broadcast_fight_ended
        handle_delve_fight_end if fight.has_monster
      elsif fight_service.should_end?
        end_fight(fight_service)
      else
        start_next_round(fight_service)
      end
    rescue StandardError => e
      log_resolution_error('state_transition', e)
      # Critical: Force a valid state transition if normal path fails
      force_recovery_transition(fight_service)
    end
  end

  # Force a state transition to prevent fights getting stuck
  def force_recovery_transition(fight_service)
    fight.reload

    # If fight is stuck in resolving/narrative, force transition
    if %w[resolving narrative].include?(fight.status)
      if fight_service.should_end?
        # Force complete
        fight.update(status: 'complete', last_action_at: Time.now)
        BroadcastService.to_room(fight.room_id, 'The fight has ended!', type: :combat, fight_id: fight.id)
      else
        # Force to next round input
        fight.update(status: 'input', round_number: fight.round_number + 1, last_action_at: Time.now)
        fight.fight_participants.each { |p| p.reset_menu_state! if p.respond_to?(:reset_menu_state!) }
        BroadcastService.to_room(fight.room_id, "Round #{fight.round_number} begins!", type: :combat, fight_id: fight.id)
      end
    end
  rescue StandardError => e
    log_resolution_error('force_recovery_transition', e)
    # Last resort: just set to complete to prevent infinite stuck state
    begin
      fight.update(status: 'complete', last_action_at: Time.now)
    rescue Sequel::DatabaseError => db_error
      log_resolution_error('force_recovery_final_update', db_error)
    end
  end

  def log_resolution_error(step, error)
    timestamp = Time.now.iso8601
    error_message = "[COMBAT_RESOLUTION_ERROR] #{step}: #{error.class}: #{error.message}"

    warn error_message
    warn error.backtrace.first(5).join("\n") if error.backtrace

    # Use configured log directory or fall back to backend/log/
    log_dir = ENV['LOG_DIR'] || File.join(File.dirname(__FILE__), '..', '..', 'log')
    log_file = File.join(log_dir, 'combat_resolution_errors.log')

    File.open(log_file, 'a') do |f|
      f.puts "#{timestamp} #{error_message}"
      f.puts error.backtrace.first(5).join("\n") if error.backtrace
    end
  rescue Errno::EACCES, Errno::ENOENT, IOError => e
    # Log to stderr if file logging fails
    warn "[COMBAT_RESOLUTION] Failed to write to log file: #{e.message}"
  end

  def broadcast_roll_display(roll_display)
    return if roll_display.nil? || roll_display.empty?

    # Broadcast each combatant's roll personalized per viewer
    # so each viewer sees the roller's name as they know them
    room_chars = CharacterInstance.where(
      current_room_id: fight.room_id, online: true
    ).eager(:character).all

    roll_display.each do |roll_data|
      animations = roll_data[:animations] || []
      next if animations.empty?

      # Combine multiple animations (base roll + willpower) into a single roll display
      # joined by ||||| separator so they appear on one line
      combined_animation = animations.join('|||||')

      # Find the rolling participant for name personalization
      roller_participant = fight.fight_participants.find { |p| p.character_instance_id == roll_data[:character_id] }

      room_chars.each do |viewer|
        # Personalize the roller's name for this viewer
        viewer_name = if roller_participant&.character_instance&.character
                        roller_participant.character_instance.character.display_name_for(viewer) ||
                          roll_data[:character_name]
                      else
                        roll_data[:character_name]
                      end

        BroadcastService.to_character(
          viewer,
          {
            type: 'dice_roll',
            combat_roll: true,
            character_id: roll_data[:character_id],
            character_name: viewer_name,
            animation_data: combined_animation,
            roll_modifier: roll_data[:modifier] || 0,
            roll_total: roll_data[:total],
            timestamp: Time.now.iso8601
          },
          type: :dice_roll
        )
      end
    end
  end

  def broadcast_damage_summary(summary)
    return if summary.nil? || summary.empty?

    # Use per-character delivery (same path as narrative) to maintain message order
    room_chars = CharacterInstance.where(
      current_room_id: fight.room_id, online: true
    ).eager(:character).all

    room_chars.each do |viewer|
      personalized = MessagePersonalizationService.personalize(
        message: summary,
        viewer: viewer,
        room_characters: room_chars
      )

      BroadcastService.to_character(
        viewer,
        {
          type: 'combat_damage_summary',
          content: personalized,
          html: "<div class='combat-damage-summary text-xs text-base-content/50'>#{personalized}</div>",
          ephemeral: true
        },
        type: :combat_damage_summary
      )
    end
  end

  def broadcast_combat_narrative(narrative, dice_duration_ms: 0)
    broadcast_personalized_combat(narrative, round: fight.round_number, dice_duration_ms: dice_duration_ms)
  end

  # Broadcast a combat message personalized per viewer
  def broadcast_personalized_combat(message, **metadata)
    room_chars = CharacterInstance.where(
      current_room_id: fight.room_id, online: true
    ).eager(:character).all

    room_chars.each do |viewer|
      personalized = MessagePersonalizationService.personalize(
        message: message,
        viewer: viewer,
        room_characters: room_chars
      )
      BroadcastService.to_character(
        viewer,
        personalized,
        type: :combat,
        fight_id: fight.id,
        **metadata
      )
    end
  end

  # Push updated status bar data to all participants so HP refreshes
  def push_status_bar_updates
    fight.fight_participants.each do |p|
      ci = p.character_instance
      next unless ci&.online
      next if ci.character&.npc?

      status_data = StatusBarService.new(ci).build_status_data
      next unless status_data

      BroadcastService.to_character(
        ci,
        { type: 'status_bar_update', status_bar: status_data },
        type: :status_bar_update
      )
    rescue StandardError => e
      warn "[CombatQuickmenuHandler] Failed to push status bar to #{p.id}: #{e.message}"
    end
  end

  # Send personalized combat summaries to each participant
  # Shows what they dealt, received, and any status effects
  def send_personal_combat_summaries(events)
    fight.active_participants.each do |p|
      summary = build_personal_summary(p, events)
      next if summary.empty?

      BroadcastService.to_character(
        p.character_instance,
        summary,
        type: :combat_summary,
        fight_id: fight.id,
        round: fight.round_number
      )
    end
  end

  # Build a personal combat summary for a participant
  def build_personal_summary(participant, events)
    lines = []
    pid = participant.id
    viewer_ci = participant.character_instance

    # Damage dealt
    dealt = events.select { |e| e[:actor_id] == pid && %w[hit ability_hit].include?(e[:event_type]) }
    dealt.each do |e|
      dmg = e.dig(:details, :total) || e.dig(:details, :effective_damage) || 0
      target = personalized_target_name(e[:target_name], e[:target_id], viewer_ci)
      ability = e.dig(:details, :ability_name)
      if ability
        lines << "You dealt #{dmg} damage to #{target} with #{ability}."
      else
        lines << "You dealt #{dmg} damage to #{target}."
      end
    end

    # Damage received
    received = events.select { |e| e[:target_id] == pid && %w[hit ability_hit damage_tick hazard_damage].include?(e[:event_type]) }
    total_received = received.sum { |e| e.dig(:details, :total) || e.dig(:details, :effective_damage) || e.dig(:details, :damage) || 0 }
    if total_received > 0
      lines << "You took #{total_received} total damage this round."
    end

    # Healing received
    healed = events.select { |e| e[:target_id] == pid && %w[ability_heal healing_tick].include?(e[:event_type]) }
    total_healed = healed.sum { |e| e.dig(:details, :actual_heal) || e.dig(:details, :amount) || 0 }
    if total_healed > 0
      lines << "You healed #{total_healed} HP."
    end

    # Status effects applied to you
    status_applied = events.select { |e| e[:target_id] == pid && e[:event_type] == 'status_applied' }
    status_applied.each do |e|
      effect = e.dig(:details, :effect_name)
      lines << "You are now affected by #{effect}!" if effect
    end

    # Lifesteal
    lifesteal = events.select { |e| e[:actor_id] == pid && e[:event_type] == 'ability_lifesteal' }
    lifesteal.each do |e|
      amount = e.dig(:details, :amount) || 0
      lines << "You drained #{amount} HP from your target." if amount > 0
    end

    # Knockout
    ko = events.find { |e| e[:target_id] == pid && e[:event_type] == 'knockout' }
    if ko
      lines << "You have been knocked out!"
    end

    # Current HP/Touches reminder
    lines << status_text(participant) if lines.any?

    lines.join("\n")
  end

  # Look up personalized display name for a target in combat summaries
  def personalized_target_name(raw_name, target_participant_id, viewer_ci)
    return raw_name || 'target' unless viewer_ci

    # Find the target participant's character to personalize
    target_p = fight.fight_participants.find { |p| p.id == target_participant_id }
    target_char = target_p&.character_instance&.character
    return raw_name || 'target' unless target_char

    target_char.display_name_for(viewer_ci)
  end

  # Broadcast fight-ended message when resolution already completed the fight (e.g., mutual pass)
  def broadcast_fight_ended
    BroadcastService.to_room(
      fight.room_id,
      'Both fighters stand down. The fight ends peacefully.',
      type: :combat,
      fight_id: fight.id
    )
  end

  def end_fight(fight_service)
    fight_service.end_fight!

    # Handle delve monster cleanup when fight has monsters
    if fight.has_monster
      handle_delve_fight_end
    end

    winner = fight.winner

    if winner
      # Use full_name so personalization can substitute per viewer
      winner_full_name = winner.character_instance&.character&.full_name || winner.character_name
      broadcast_personalized_combat(
        "The fight is over! #{winner_full_name} is victorious!",
        fight_id: fight.id,
        winner_id: winner.id,
        winner_name: winner.character_name
      )
    else
      BroadcastService.to_room(
        fight.room_id,
        'The fight has ended!',
        type: :combat,
        fight_id: fight.id
      )
    end
  end

  # Handle delve-specific fight end: deactivate monsters, award loot, sync HP
  def handle_delve_fight_end
    delve_participant = find_delve_participant
    return unless delve_participant

    delve = delve_participant.delve
    return unless delve

    # Reload fight participants to get current HP after combat resolution
    fresh_fight_participants = FightParticipant.where(fight_id: fight.id).all

    # Get all delve participants in this fight
    participants = fresh_fight_participants
                        .reject(&:is_npc)
                        .map { |fp| delve.delve_participants.find { |dp| dp.character_instance_id == fp.character_instance_id } }
                        .compact

    return if participants.empty?

    # Sync willpower from fight participants back to delve participants
    # (HP is already synced automatically via fight_participant.sync_hp_to_character!)
    participants.each do |dp|
      fp = fresh_fight_participants.find { |f| f.character_instance_id == dp.character_instance_id }
      next unless fp

      # Always sync willpower — combat gains fractional WP, floor for delve integer pool
      new_wp = fp.willpower_dice.to_f.floor
      dp.update(willpower_dice: new_wp) if new_wp >= 0
    end

    # Handle delve combat end (deactivate monsters, award loot)
    DelveCombatService.handle_fight_end!(fight, delve, participants)
  rescue StandardError => e
    warn "[CombatQuickmenuHandler] Delve fight end cleanup failed: #{e.message}"
  end

  def start_next_round(fight_service)
    fight_service.next_round!

    # Re-apply NPC auto-decisions for the new round (next_round! resets all input_complete to false)
    fight.reload.fight_participants.each do |p|
      next unless p.is_npc && !p.is_knocked_out && !p.input_complete
      CombatAIService.new(p).apply_decisions!
    end

    # Process delve combat time and reinforcements if this is a delve fight
    process_delve_round_time if fight.has_monster

    # Push quickmenus directly — no "Round X begins" text clutter

    # Push quickmenus to all active participants via WebSocket
    fight.active_participants.each do |p|
      ci = p.character_instance
      next unless ci&.online
      next if ci.character&.npc?

      begin
        menu_data = self.class.show_menu(p, ci)
        next unless menu_data

        interaction_id = SecureRandom.uuid
        stored = {
          interaction_id: interaction_id,
          type: 'quickmenu',
          prompt: menu_data[:prompt],
          options: menu_data[:options],
          context: menu_data[:context] || {},
          created_at: Time.now.iso8601
        }
        OutputHelper.store_agent_interaction(ci, interaction_id, stored)

        BroadcastService.to_character(
          ci,
          { content: "Round #{fight.round_number} — choose your actions." },
          type: :quickmenu,
          data: {
            interaction_id: interaction_id,
            prompt: menu_data[:prompt],
            options: menu_data[:options]
          }
        )
      rescue StandardError => e
        warn "[CombatQuickmenuHandler] Failed to push round menu to #{p.id}: #{e.message}"
      end
    end
  end

  # Process delve combat time and check for reinforcements
  def process_delve_round_time
    # Find the delve participant for this fight
    delve_participant = find_delve_participant
    return unless delve_participant

    delve = delve_participant.delve
    return unless delve

    # Get all delve participants in this fight
    participants = fight.fight_participants
                        .reject(&:is_npc)
                        .map { |fp| delve.delve_participants.find { |dp| dp.character_instance_id == fp.character_instance_id } }
                        .compact

    return if participants.empty?

    # Process round time (deducts 10 seconds, checks for timeouts and reinforcements)
    events = DelveCombatService.process_round_time!(delve, participants)

    # Handle timeout events
    events.select { |e| e[:type] == :timeout }.each do |event|
      participant = event[:participant]
      broadcast_personalized_to_room(
        fight.room_id,
        "#{participant.character_instance.character.full_name} has run out of time!",
        extra_characters: [participant.character_instance]
      )
    end

    # Handle reinforcement events (monsters entering the fight)
    reinforcement_monsters = events
      .select { |e| e[:type] == :reinforcement }
      .flat_map { |e| [e[:monster]].compact }

    return if reinforcement_monsters.empty?

    # Add reinforcements to the fight
    added_names = DelveCombatService.add_monster_reinforcements!(fight, reinforcement_monsters)

    return if added_names.empty?

    names_html = added_names.map { |n| "<strong>#{n}</strong>" }.join(', ')
    BroadcastService.to_room(
      fight.room_id,
      "<div class='alert alert-warning text-center my-2'><i class='bi bi-exclamation-triangle-fill me-2'></i>Reinforcements arrive! #{names_html} join the battle!</div>",
      type: :combat
    )
  end

  # Find the DelveParticipant for the current fight
  def find_delve_participant
    # Get the first PC participant's character instance
    pc_participant = fight.fight_participants.find { |fp| !fp.is_npc && fp.character_instance_id }
    return nil unless pc_participant

    # Find the DelveParticipant for this character
    DelveParticipant.first(character_instance_id: pc_participant.character_instance_id, status: 'active')
  end
end
