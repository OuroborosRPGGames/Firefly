# frozen_string_literal: true

# Processes combat actions submitted via the interactive battle map.
# Provides an alternative input method to the quickmenu system.
# Both input methods modify the same FightParticipant fields.
class CombatActionService
  # Max willpower dice that can be spent (matches CombatQuickmenuHandler)
  MAX_WILLPOWER_SPEND = 2

  attr_reader :participant, :fight

  def self.process_map_action(participant, action_type, value)
    new(participant).process(action_type, value)
  end

  def initialize(participant)
    @participant = participant
    @fight = participant.fight
  end

  def process(action_type, value)
    if fight.round_locked?
      return {
        success: false,
        error: 'Combat round is resolving. Wait for the next round to change your choices.'
      }
    end

    unless fight.can_accept_combat_input?
      return {
        success: false,
        error: 'Combat input is currently closed for this round.'
      }
    end

    case action_type
    when 'move_to_hex'
      process_move_to_hex(value)
    when 'move_toward'
      process_move_toward(value)
    when 'move_away'
      process_move_away(value)
    when 'stand_still'
      process_stand_still
    when 'set_target'
      process_set_target(value)
    when 'attack'
      process_attack(value)
    when 'defend'
      process_defend
    when 'use_ability'
      process_use_ability(value)
    when 'willpower_attack'
      process_willpower(:attack, value)
    when 'willpower_defense'
      process_willpower(:defense, value)
    when 'willpower_ability'
      process_willpower(:ability, value)
    when 'willpower_skip'
      process_willpower_skip
    when 'tactical_boost'
      # Legacy - redirect to tactical
      process_tactical(value)
    when 'tactical'
      process_tactical(value)
    when 'use_tactical_ability'
      process_use_tactical_ability(value)
    when 'dodge'
      process_dodge
    when 'sprint'
      process_sprint
    when 'pass'
      process_pass
    when 'surrender'
      process_surrender
    when 'flee'
      process_flee(value)
    when 'extinguish'
      process_extinguish
    when 'stand_up'
      process_stand_up
    when 'maintain_distance'
      process_maintain_distance(value)
    when 'mount'
      process_mount(value)
    when 'climb'
      process_climb
    when 'cling'
      process_cling
    when 'dismount'
      process_dismount
    when 'select_melee'
      process_select_weapon(:melee)
    when 'select_ranged'
      process_select_weapon(:ranged)
    when 'toggle_autobattle'
      process_toggle_autobattle
    when 'toggle_hazard'
      process_toggle_hazard
    when 'change_side'
      process_change_side(value)
    when 'submit_round', 'done'
      process_done
    else
      { success: false, error: "Unknown action: #{action_type}" }
    end
  end

  private

  # === Movement Actions ===

  def process_move_to_hex(value)
    raw_x = value.is_a?(Hash) ? (value['hex_x'] || value[:hex_x]) : nil
    raw_y = value.is_a?(Hash) ? (value['hex_y'] || value[:hex_y]) : nil
    return { success: false, error: 'Invalid payload for move_to_hex' } if raw_x.nil? || raw_y.nil?

    raw_x = raw_x.to_i
    raw_y = raw_y.to_i

    # Snap to valid hex coordinates (offset coordinate system)
    hex_x, hex_y = HexGrid.to_hex_coords(raw_x, raw_y)

    # Store target hex for direct movement
    participant.update(
      movement_action: 'move_to_hex',
      target_hex_x: hex_x,
      target_hex_y: hex_y,
      movement_target_participant_id: nil,
      movement_set: true,
      input_stage: 'main_menu'
    )

    { success: true, message: "Movement set: Move to hex (#{hex_x}, #{hex_y})" }
  end

  def process_move_toward(value)
    target_id = value.to_i
    target = find_participant(target_id)
    return { success: false, error: 'Target not found' } unless target

    participant.update(
      movement_action: 'towards_person',
      movement_target_participant_id: target_id,
      target_hex_x: nil,
      target_hex_y: nil,
      movement_set: true,
      input_stage: 'main_menu'
    )

    { success: true, message: "Movement set: Move toward #{target.character_name}" }
  end

  def process_move_away(value)
    target_id = value.to_i
    target = find_participant(target_id)
    return { success: false, error: 'Target not found' } unless target

    participant.update(
      movement_action: 'away_from',
      movement_target_participant_id: target_id,
      target_hex_x: nil,
      target_hex_y: nil,
      movement_set: true,
      input_stage: 'main_menu'
    )

    { success: true, message: "Movement set: Move away from #{target.character_name}" }
  end

  def process_stand_still
    participant.update(
      movement_action: 'stand_still',
      movement_target_participant_id: nil,
      target_hex_x: nil,
      target_hex_y: nil,
      movement_set: true,
      input_stage: 'main_menu'
    )

    { success: true, message: 'Movement set: Stand still' }
  end

  # === Main Action ===

  def process_set_target(value)
    target_id = value.to_i
    target = find_participant(target_id)
    return { success: false, error: 'Target not found' } unless target
    return { success: false, error: 'Cannot target yourself' } if target_id == participant.id
    return { success: false, error: 'Target is knocked out' } if target.is_knocked_out
    invalid_reason = invalid_attack_target_reason(target)
    return { success: false, error: invalid_reason } if invalid_reason

    participant.update(
      target_participant_id: target_id,
      ability_target_participant_id: target_id,
      main_action_set: true,
      input_stage: 'main_menu'
    )

    { success: true, message: "Target set: #{target.character_name}" }
  end

  def process_attack(value)
    target_id = value&.to_i

    updates = {
      main_action: 'attack',
      main_action_set: true,
      ability_id: nil,
      ability_choice: nil,
      pending_action_name: 'Attack',
      input_stage: 'main_menu'
    }

    if target_id && target_id > 0
      target = find_participant(target_id)
      return { success: false, error: 'Target not found' } unless target
      return { success: false, error: 'Cannot target yourself' } if target.id == participant.id
      return { success: false, error: 'Target is knocked out' } if target.is_knocked_out
      invalid_reason = invalid_attack_target_reason(target)
      return { success: false, error: invalid_reason } if invalid_reason

      updates[:target_participant_id] = target_id
      updates[:ability_target_participant_id] = target_id
    end

    participant.update(updates)
    target_name = target_id && target_id > 0 ? find_participant(target_id)&.character_name : nil
    message = target_name ? "Attack set: #{target_name}" : 'Attack action selected'

    { success: true, message: message }
  end

  def process_defend
    participant.update(
      main_action: 'defend',
      main_action_set: true,
      target_participant_id: nil,
      ability_target_participant_id: nil,
      ability_id: nil,
      ability_choice: nil,
      pending_action_name: 'Full Defense',
      input_stage: 'main_menu'
    )

    { success: true, message: 'Main action set: Full Defense' }
  end

  def process_use_ability(value)
    ability_id_raw = value.is_a?(Hash) ? (value['ability_id'] || value[:ability_id] || value['id'] || value[:id]) : nil
    target_id_raw = value.is_a?(Hash) ? (value['target_id'] || value[:target_id]) : nil
    return { success: false, error: 'Invalid payload for use_ability' } if ability_id_raw.nil?

    ability_id = ability_id_raw.to_i
    target_id = target_id_raw&.to_i

    ability = Ability[ability_id]
    return { success: false, error: 'Ability not found' } unless ability

    # Check if ability is available
    unless participant.available_main_abilities.include?(ability) ||
           participant.available_tactical_abilities.include?(ability)
      return { success: false, error: 'Ability not available' }
    end

    updates = {
      ability_id: ability_id,
      ability_choice: ability.name.downcase,
      pending_action_name: ability.name,
      input_stage: 'main_menu'
    }

    # Determine if this is a main or tactical ability
    if participant.available_main_abilities.include?(ability)
      updates[:main_action] = 'ability'
      updates[:main_action_set] = true
    else
      updates[:tactical_ability_id] = ability_id
      updates[:tactical_action_set] = true
    end

    target_name = nil

    if ability.target_type == 'self'
      updates[:target_participant_id] = participant.id
      updates[:ability_target_participant_id] = participant.id
    else
      resolved_target_id = target_id&.positive? ? target_id : participant.target_participant_id
      target = find_participant(resolved_target_id) if resolved_target_id && resolved_target_id.positive?

      if target_id && target_id.positive? && target.nil?
        return { success: false, error: 'Target not found' }
      end

      return { success: false, error: 'Target required for this ability' } unless target
      return { success: false, error: 'Target is knocked out' } if target.is_knocked_out
      return { success: false, error: 'Invalid target for this ability' } unless valid_target_for_ability?(ability, target)
      return { success: false, error: 'Target out of range for this ability' } unless target_in_ability_range?(ability, target)

      updates[:target_participant_id] = target.id
      updates[:ability_target_participant_id] = target.id
      target_name = target.character_name
    end

    participant.update(updates)

    message = target_name ? "#{ability.name} targeting #{target_name}" : "#{ability.name} selected"

    { success: true, message: message }
  end

  # === Willpower ===

  def process_willpower(type, value)
    dice_count = value.to_i
    available = [participant.available_willpower_dice + participant.allocated_willpower_dice, MAX_WILLPOWER_SPEND].min

    return { success: false, error: 'No willpower dice available' } if available == 0
    return { success: false, error: "Can spend max #{available} dice" } if dice_count > available
    return { success: false, error: 'Must spend at least 1 die' } if dice_count < 1

    allocations = { attack: 0, defense: 0, ability: 0, movement: 0 }
    case type
    when :attack
      allocations[:attack] = dice_count
      message = "Willpower: +#{dice_count}d8 attack damage (explodes on 8)"
    when :defense
      allocations[:defense] = dice_count
      message = "Willpower: #{dice_count}d8 defense"
    when :ability
      allocations[:ability] = dice_count
      message = "Willpower: +#{dice_count}d8 ability damage (explodes on 8)"
    when :movement
      allocations[:movement] = dice_count
      message = "Willpower: #{dice_count}d8÷2 bonus movement hexes (explodes on 8)"
    end

    unless participant.set_willpower_allocation!(**allocations)
      return { success: false, error: 'No willpower dice available' }
    end

    participant.update(
      willpower_set: true,
      input_stage: 'main_menu'
    )

    { success: true, message: message }
  end

  def process_willpower_skip
    participant.set_willpower_allocation!(attack: 0, defense: 0, ability: 0, movement: 0)
    participant.update(
      willpower_set: true,
      input_stage: 'main_menu'
    )

    { success: true, message: 'Willpower: Saving dice for later' }
  end

  # === Tactical ===

  def process_tactical(value)
    stance = value.to_s

    valid_stances = %w[aggressive defensive quick guard back_to_back none]
    return { success: false, error: 'Invalid tactical stance' } unless valid_stances.include?(stance)

    if stance == 'none'
      participant.update(
        tactic_choice: nil,
        tactic_target_participant_id: nil,
        tactical_ability_id: nil,
        tactical_action_set: true,
        input_stage: 'main_menu'
      )
      return { success: true, message: 'Tactical action: None' }
    end

    # Guard and back_to_back need a target - just set the stance and let quickmenu handle target
    updates = {
      tactic_choice: stance,
      tactical_ability_id: nil,
      tactical_action_set: true,
      input_stage: 'main_menu'
    }

    # Clear target for non-protection stances
    if %w[aggressive defensive quick].include?(stance)
      updates[:tactic_target_participant_id] = nil
    end

    participant.update(updates)

    labels = {
      'aggressive' => 'Aggressive (+2 dealt, +2 taken)',
      'defensive' => 'Defensive (-2 dealt, -2 taken)',
      'quick' => 'Quick (+1 movement)',
      'guard' => 'Guard (protect ally)',
      'back_to_back' => 'Back to Back'
    }

    { success: true, message: "Tactical action: #{labels[stance]}" }
  end

  def process_use_tactical_ability(value)
    if value.is_a?(Hash)
      ability_id = (value['ability_id'] || value[:ability_id] || value['id'] || value[:id]).to_i
      target_id = (value['target_id'] || value[:target_id]).to_i
    else
      ability_id = value.to_i
      target_id = 0
    end

    ability = Ability[ability_id]
    return { success: false, error: 'Ability not found' } unless ability

    # Check if ability is available
    unless participant.available_tactical_abilities.include?(ability)
      return { success: false, error: 'Tactical ability not available' }
    end

    updates = {
      tactical_ability_id: ability_id,
      tactic_choice: nil,
      tactical_action_set: true,
      input_stage: 'main_menu'
    }

    # Self-targeted abilities don't need target selection.
    # Non-self tactical abilities require an explicit/valid target.
    if ability.target_type == 'self'
      updates[:tactic_target_participant_id] = participant.id
    else
      resolved_target_id = target_id.positive? ? target_id : participant.target_participant_id
      target = find_participant(resolved_target_id) if resolved_target_id
      return { success: false, error: 'Target required for this tactical ability' } unless target
      return { success: false, error: 'Target is knocked out' } if target.is_knocked_out

      valid_target = case ability.target_type
                     when 'ally', 'allies'
                       target.side == participant.side
                     when 'enemy', 'enemies'
                       target.side != participant.side
                     else
                       true
                     end
      return { success: false, error: 'Invalid target for this tactical ability' } unless valid_target
      return { success: false, error: 'Target out of range for this tactical ability' } unless target_in_ability_range?(ability, target)

      updates[:tactic_target_participant_id] = target.id
    end

    participant.update(updates)

    { success: true, message: "Tactical ability: #{ability.name}" }
  end

  # === Additional Main Actions ===

  def process_dodge
    participant.update(
      main_action: 'dodge',
      main_action_set: true,
      target_participant_id: nil,
      ability_id: nil,
      ability_choice: nil,
      pending_action_name: 'Dodge',
      input_stage: 'main_menu'
    )

    { success: true, message: 'Main action set: Dodge (-5 to incoming attacks)' }
  end

  def process_sprint
    participant.update(
      main_action: 'sprint',
      main_action_set: true,
      target_participant_id: nil,
      ability_id: nil,
      ability_choice: nil,
      pending_action_name: 'Sprint',
      input_stage: 'main_menu'
    )

    { success: true, message: 'Main action set: Sprint (+3 movement, no attack)' }
  end

  def process_pass
    participant.update(
      main_action: 'pass',
      main_action_set: true,
      target_participant_id: nil,
      ability_id: nil,
      ability_choice: nil,
      pending_action_name: 'Pass',
      input_stage: 'main_menu'
    )

    { success: true, message: 'Main action set: Pass' }
  end

  def process_surrender
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

    { success: true, message: 'Main action set: Surrender' }
  end

  def process_flee(value)
    # Value can be a direction string or exit_id
    unless participant.can_flee?
      return { success: false, error: 'Cannot flee - must be at arena edge with valid exit' }
    end

    flee_exits = participant.available_flee_exits

    # Find the exit by direction or ID
    flee_exit = if value.is_a?(Integer) || value.to_s.match?(/^\d+$/)
                  exit_id = value.to_i
                  flee_exits.find { |f| f[:exit].id == exit_id }
                else
                  direction = value.to_s.downcase
                  flee_exits.find { |f| f[:direction].downcase == direction }
                end

    unless flee_exit
      available = flee_exits.map { |f| f[:direction] }.join(', ')
      return { success: false, error: "Invalid flee direction. Available: #{available}" }
    end

    participant.update(
      movement_action: 'flee',
      is_fleeing: true,
      flee_direction: flee_exit[:direction],
      flee_exit_id: flee_exit[:exit].id,
      movement_set: true,
      input_stage: 'main_menu'
    )

    { success: true, message: "Movement set: Flee #{flee_exit[:direction]}" }
  end

  def process_extinguish
    # Check if actually burning
    unless StatusEffectService.has_effect?(participant, 'burning')
      return { success: false, error: 'You are not on fire' }
    end

    # Extinguish sets main action to pass and removes burning
    StatusEffectService.extinguish(participant)

    participant.update(
      main_action: 'pass',
      main_action_set: true,
      ability_id: nil,
      ability_choice: nil,
      pending_action_name: 'Extinguish flames',
      input_stage: 'main_menu'
    )

    { success: true, message: 'Action set: Extinguish flames' }
  end

  def process_stand_up
    # Check if actually prone
    unless StatusEffectService.is_prone?(participant)
      return { success: false, error: 'You are not prone' }
    end

    # Standing up uses movement, not main action
    stand_cost = StatusEffectService.stand_cost(participant)

    participant.update(
      stand_this_round: true,
      input_stage: 'main_menu'
    )

    { success: true, message: "Standing up (uses #{stand_cost} movement)" }
  end

  # === Movement ===

  def process_maintain_distance(value)
    target_id = value.to_i
    target = find_participant(target_id)
    return { success: false, error: 'Target not found' } unless target

    participant.update(
      movement_action: 'maintain_distance',
      movement_target_participant_id: target_id,
      target_hex_x: nil,
      target_hex_y: nil,
      movement_set: true,
      input_stage: 'main_menu'
    )

    { success: true, message: "Movement set: Maintain 6 hex from #{target.character_name}" }
  end

  # === Monster Mounting ===

  def process_mount(value)
    monster_id = value.to_i
    return { success: false, error: 'Monster ID required' } if monster_id.zero?

    monster = begin
      LargeMonsterInstance.where(id: monster_id, fight_id: fight.id, status: 'active').first
    rescue StandardError => e
      warn "[CombatActionService] Failed to find monster #{monster_id}: #{e.message}"
      nil
    end
    return { success: false, error: 'Monster not found' } unless monster

    mounting_service = MonsterMountingService.new(fight)
    result = mounting_service.attempt_mount(participant, monster)
    return { success: false, error: result[:error] || 'Mount failed' } unless result[:success]

    participant.update(
      movement_set: true,
      input_stage: 'main_menu'
    )

    { success: true, message: "Mounting #{monster.display_name}" }
  end

  def process_climb
    return { success: false, error: 'Not mounted' } unless participant.is_mounted && participant.targeting_monster_id

    monster = LargeMonsterInstance[participant.targeting_monster_id]
    return { success: false, error: 'Monster not found' } unless monster

    mount_state = MonsterMountState.first(
      large_monster_instance_id: monster.id,
      fight_participant_id: participant.id
    )
    return { success: false, error: 'Mount state not found' } unless mount_state

    mounting_service = MonsterMountingService.new(fight)
    climb_result = mounting_service.process_climb(mount_state)

    participant.update(
      mount_action: 'climb',
      movement_set: true,
      input_stage: 'main_menu'
    )

    message = climb_result[:at_weak_point] ? 'Movement: Reached the weak point!' : 'Movement: Climbing toward weak point'
    { success: true, message: message }
  end

  def process_cling
    return { success: false, error: 'Not mounted' } unless participant.is_mounted && participant.targeting_monster_id

    monster = LargeMonsterInstance[participant.targeting_monster_id]
    return { success: false, error: 'Monster not found' } unless monster

    mount_state = MonsterMountState.first(
      large_monster_instance_id: monster.id,
      fight_participant_id: participant.id
    )
    return { success: false, error: 'Mount state not found' } unless mount_state

    mounting_service = MonsterMountingService.new(fight)
    mounting_service.process_cling(mount_state)

    participant.update(
      mount_action: 'cling',
      movement_set: true,
      input_stage: 'main_menu'
    )

    { success: true, message: 'Movement: Clinging (immune to shake-off)' }
  end

  def process_dismount
    return { success: false, error: 'Not mounted' } unless participant.is_mounted && participant.targeting_monster_id

    monster = LargeMonsterInstance[participant.targeting_monster_id]
    return { success: false, error: 'Monster not found' } unless monster

    mount_state = MonsterMountState.first(
      large_monster_instance_id: monster.id,
      fight_participant_id: participant.id
    )
    return { success: false, error: 'Mount state not found' } unless mount_state

    mounting_service = MonsterMountingService.new(fight)
    result = mounting_service.process_dismount(mount_state)
    return { success: false, error: 'Dismount failed' } unless result[:success]

    participant.update(
      hex_x: result[:landing_position][0],
      hex_y: result[:landing_position][1],
      is_mounted: false,
      targeting_monster_id: nil,
      targeting_segment_id: nil,
      mount_action: nil,
      movement_set: true,
      input_stage: 'main_menu'
    )

    { success: true, message: 'Movement: Dismounting' }
  end

  # === Options ===

  def process_select_weapon(type)
    # Return available weapons for selection
    weapons = case type
              when :melee
                participant.character_instance&.objects_dataset&.where(is_weapon: true, weapon_type: 'melee')&.all || []
              when :ranged
                participant.character_instance&.objects_dataset&.where(is_weapon: true, weapon_type: 'ranged')&.all || []
              else
                []
              end

    weapon_list = weapons.map { |w| { id: w.id, name: w.name } }
    weapon_list.unshift({ id: nil, name: type == :melee ? 'Unarmed' : 'None' })

    { success: true, message: "Select #{type} weapon", options: weapon_list }
  end

  def process_toggle_autobattle
    styles = [nil, 'aggressive', 'defensive', 'supportive']
    current = participant.autobattle_style
    current_index = styles.index(current) || 0
    next_style = styles[(current_index + 1) % styles.length]

    participant.update(autobattle_style: next_style)

    label = next_style ? next_style.capitalize : 'OFF'
    { success: true, message: "Autobattle: #{label}" }
  end

  def process_toggle_hazard
    new_value = !participant.ignore_hazard_avoidance
    participant.update(ignore_hazard_avoidance: new_value)

    label = new_value ? 'Ignore' : 'Avoid'
    { success: true, message: "Hazard avoidance: #{label}" }
  end

  def process_change_side(value)
    new_side = value.to_i
    return { success: false, error: 'Invalid side' } if new_side < 1

    participant.update(side: new_side)
    { success: true, message: "Changed to Side #{new_side}" }
  end

  def hex_distance(x1, y1, x2, y2)
    return 999 unless x1 && y1 && x2 && y2

    HexGrid.hex_distance(x1, y1, x2, y2)
  end

  # === Done ===

  def process_done
    # Validate required fields
    unless participant.main_action_set
      return { success: false, error: 'Main action required' }
    end

    # Complete the input
    participant.complete_input!

    # Check if round can resolve
    check_round_resolution

    { success: true, message: 'Actions submitted', input_complete: true }
  end

  # === Helpers ===

  def find_participant(id)
    fight.fight_participants.find { |p| p.id == id }
  end

  def valid_target_for_ability?(ability, target)
    case ability.target_type
    when 'ally', 'allies'
      target.id == participant.id || same_team?(target)
    when 'enemy', 'enemies'
      target.id != participant.id && !same_team?(target)
    else
      true
    end
  end

  def target_in_ability_range?(ability, target)
    return true if ability.target_type == 'self'

    distance = participant.hex_distance_to(target)
    return true if distance.nil?

    range = if ability.respond_to?(:aoe_shape) && ability.aoe_shape == 'circle'
              # Circle abilities use aoe_radius for splash size, not cast distance.
              GameConfig::AbilityDefaults::DEFAULT_RANGE_HEXES
            elsif ability.respond_to?(:range_in_hexes)
              ability.range_in_hexes
            else
              GameConfig::AbilityDefaults::DEFAULT_RANGE_HEXES
            end
    distance <= range
  end

  def same_team?(other)
    return false unless participant.respond_to?(:side) && other.respond_to?(:side)
    return false if participant.side.nil? || other.side.nil?

    participant.side == other.side
  end

  def invalid_attack_target_reason(target)
    return 'Cannot attack a participant on your side' if same_team?(target)

    protected_ids = StatusEffectService.cannot_target_ids(participant)
    return 'Target cannot be attacked right now' if protected_ids.include?(target.id)

    nil
  end

  def check_round_resolution
    # Delegate to CombatQuickmenuHandler which handles the full resolution flow:
    # roll display broadcast, narrative generation, status bar updates, round transition
    handler = CombatQuickmenuHandler.new(participant, participant.character_instance)
    handler.send(:check_round_resolution)
  end
end
