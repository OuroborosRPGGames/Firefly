# frozen_string_literal: true

# Provides text-based combat information for accessibility mode.
# Converts visual hex-grid combat data into linear, screen-reader-friendly output.
#
# @example
#   service = AccessibleCombatService.new(fight, viewer_participant)
#   service.combat_status   # Full status overview
#   service.list_enemies    # All enemies with details
#   service.recommend_target # Best target suggestion
#
class AccessibleCombatService
  attr_reader :fight, :viewer

  def initialize(fight, viewer_participant)
    @fight = fight
    @viewer = viewer_participant
    # Use _dataset to avoid Sequel association caching
    @participants = fight.fight_participants_dataset.all
  end

  # Get full combat status for accessibility display
  # @return [Hash] combat status data with :accessible_text key
  def combat_status
    lines = []
    lines << "<h4>Combat Status</h4>"
    lines << ""

    # Round and phase info
    lines << "Round: #{fight.round_number}"
    lines << "Phase: #{format_phase(fight.status)}"
    lines << ""

    # Your status
    if viewer
      lines << "Your Status:"
      lines << format_participant_status(viewer, verbose: true)
      lines << ""
    end

    # Quick summary
    enemy_count = enemies.count
    ally_count = allies.count
    monster_list = monsters
    lines << "Enemies: #{enemy_count}"
    lines << "Allies: #{ally_count}" if ally_count > 0

    # Monster info
    if monster_list.any?
      lines << ""
      lines << "<h4>Monsters</h4>"
      monster_list.each do |monster|
        hp_percent = monster.max_hp > 0 ? (monster.current_hp.to_f / monster.max_hp * 100).round : 0
        lines << "#{monster.display_name}: #{monster.current_hp}/#{monster.max_hp}HP (#{hp_percent}%)"
        lines << "  Status: #{monster.status.capitalize}"

        # Show active segments
        active_segments = monster.monster_segment_instances.select { |s| s.status != 'destroyed' }
        if active_segments.any?
          segment_info = active_segments.map do |seg|
            "#{seg.name} (#{seg.current_hp}/#{seg.max_hp})"
          end.join(', ')
          lines << "  Segments: #{segment_info}"
        end
      end
    end
    lines << ""

    # Input status
    if fight.accepting_input?
      if viewer && !viewer.input_complete
        lines << "<strong>Your turn</strong> &mdash; choose your actions"
        lines << ""
        lines << available_actions_text
      else
        waiting = fight.participants_needing_input.count
        lines << "Waiting for #{waiting} #{waiting == 1 ? 'combatant' : 'combatants'} to act..."
      end
    elsif fight.status == 'resolving'
      lines << "Round resolving..."
    elsif fight.status == 'narrative'
      lines << "Combat narrative playing..."
    end

    {
      round: fight.round_number,
      phase: fight.status,
      your_status: viewer ? participant_to_hash(viewer) : nil,
      enemy_count: enemy_count,
      ally_count: ally_count,
      monster_count: monster_list.count,
      monsters: monster_list.map { |m| monster_to_hash(m) },
      accessible_text: lines.join("\n"),
      format: :accessible
    }
  end

  # List all enemies with HP, distance, and status
  # @return [Hash] enemies data with :accessible_text key
  def list_enemies
    enemy_list = enemies

    lines = []
    lines << "<h4>Enemies (#{enemy_list.count})</h4>"
    lines << ""

    if enemy_list.empty?
      lines << "No enemies in combat."
    else
      enemy_list.each_with_index do |enemy, idx|
        lines << "#{idx + 1}. #{format_combatant_line(enemy)}"
        lines << "   #{format_combatant_details(enemy)}"
      end
    end

    {
      enemies: enemy_list.map { |e| participant_to_hash(e) },
      accessible_text: lines.join("\n"),
      format: :accessible
    }
  end

  # List all allies with HP, distance, and status
  # @return [Hash] allies data with :accessible_text key
  def list_allies
    ally_list = allies

    lines = []
    lines << "<h4>Allies (#{ally_list.count})</h4>"
    lines << ""

    if ally_list.empty?
      lines << "No allies in combat."
    else
      ally_list.each_with_index do |ally, idx|
        lines << "#{idx + 1}. #{format_combatant_line(ally)}"
        lines << "   #{format_combatant_details(ally)}"
      end
    end

    {
      allies: ally_list.map { |a| participant_to_hash(a) },
      accessible_text: lines.join("\n"),
      format: :accessible
    }
  end

  # Recommend the best target to attack
  # @return [Hash] recommendation with :accessible_text key
  def recommend_target
    enemy_list = enemies.reject(&:is_knocked_out)

    lines = []
    lines << "<h4>Target Recommendation</h4>"
    lines << ""

    if enemy_list.empty?
      lines << "No valid targets available."
      return {
        recommendation: nil,
        reason: 'No valid targets',
        accessible_text: lines.join("\n"),
        format: :accessible
      }
    end

    # Score each enemy
    scored = enemy_list.map do |enemy|
      {
        participant: enemy,
        score: calculate_target_score(enemy),
        reasons: target_reasons(enemy)
      }
    end

    # Sort by score (highest first)
    scored.sort_by! { |s| -s[:score] }
    best = scored.first

    lines << "Recommended target: #{best[:participant].character_name}"
    lines << ""
    lines << "Reasons:"
    best[:reasons].each { |r| lines << "  - #{r}" }
    lines << ""
    lines << "Other options:"
    scored[1..3].each do |s|
      lines << "  #{s[:participant].character_name} (#{format_hp_percent(s[:participant])} HP)"
    end

    {
      recommendation: participant_to_hash(best[:participant]),
      reason: best[:reasons].first,
      all_reasons: best[:reasons],
      alternatives: scored[1..3].map { |s| participant_to_hash(s[:participant]) },
      accessible_text: lines.join("\n"),
      format: :accessible
    }
  end

  # Get a quick menu of combat options
  # @return [Hash] quick menu data
  def quick_menu
    options = []
    options << { key: '1', label: 'List enemies', command: 'combat enemies' }
    options << { key: '2', label: 'List allies', command: 'combat allies' } if allies.any?
    options << { key: '3', label: 'Recommend target', command: 'combat recommend' }
    options << { key: '4', label: 'Your status', command: 'combat status' }
    options << { key: '5', label: 'Available actions', command: 'combat actions' }

    {
      options: options,
      accessible_text: options.map { |o| "#{o[:key]}. #{o[:label]}" }.join("\n"),
      format: :accessible
    }
  end

  # Get available actions for the viewer
  # @return [Hash] actions data
  def available_actions
    lines = []
    lines << "<h4>Available Actions</h4>"
    lines << ""

    if viewer.nil?
      lines << "You are not in combat."
    elsif viewer.is_knocked_out
      lines << "You are knocked out and cannot act."
    elsif viewer.input_complete
      lines << "You have already submitted your actions for this round."
    else
      lines << available_actions_text
    end

    {
      can_act: viewer && !viewer.is_knocked_out && !viewer.input_complete,
      accessible_text: lines.join("\n"),
      format: :accessible
    }
  end

  private

  # Get enemies (participants not on viewer's side)
  def enemies
    return @participants.reject(&:is_knocked_out) unless viewer

    @participants.reject do |p|
      p.id == viewer.id || p.side == viewer.side || p.is_knocked_out
    end
  end

  # Get monsters in the fight
  def monsters
    return [] unless fight.has_monster

    LargeMonsterInstance.where(fight_id: fight.id, status: 'active').all
  end

  # Get allies (participants on viewer's side)
  def allies
    return [] unless viewer

    @participants.select do |p|
      p.id != viewer.id && p.side == viewer.side && !p.is_knocked_out
    end
  end

  # Format a participant as a single line
  def format_combatant_line(participant)
    name = participant.character_name
    hp = "#{participant.current_hp}/#{participant.max_hp}HP"
    status = participant.is_knocked_out ? ' [KO]' : ''
    distance = viewer ? "#{viewer.hex_distance_to(participant)}hex" : '?hex'

    "#{name}: #{hp}, #{distance}#{status}"
  end

  # Format detailed combatant information
  def format_combatant_details(participant)
    details = []

    # Weapon info
    weapon = participant.melee_weapon || participant.ranged_weapon
    if weapon
      details << "Weapon: #{weapon.name}"
    else
      details << "Unarmed"
    end

    # Status effects
    effects = participant.active_status_effects
    if effects.any?
      effect_names = effects.map { |e| e.status_effect&.name }.compact
      details << "Effects: #{effect_names.join(', ')}" if effect_names.any?
    end

    # Range status
    if viewer && !participant.is_knocked_out
      if viewer.in_melee_range?(participant)
        details << "In melee range"
      else
        details << "At range"
      end
    end

    details.join(' | ')
  end

  # Format participant status (for viewer's own status)
  def format_participant_status(participant, verbose: false)
    lines = []
    lines << "  HP: #{participant.current_hp}/#{participant.max_hp}"
    lines << "  Willpower: #{participant.willpower_dice.to_f.round(1)} dice"

    if verbose
      weapon = participant.melee_weapon || participant.ranged_weapon
      lines << "  Weapon: #{weapon&.name || 'Unarmed'}"

      effects = participant.active_status_effects
      if effects.any?
        effect_names = effects.map { |e| e.status_effect&.name }.compact
        lines << "  Status: #{effect_names.join(', ')}" if effect_names.any?
      end

      if participant.wound_penalty > 0
        lines << "  Wound penalty: -#{participant.wound_penalty}"
      end
    end

    lines.join("\n")
  end

  # Format the combat phase
  def format_phase(status)
    case status
    when 'input'
      'Input Phase - Choose your actions'
    when 'resolving'
      'Resolution Phase - Actions being processed'
    when 'narrative'
      'Narrative Phase - Results being displayed'
    when 'complete'
      'Combat Complete'
    else
      # Convert snake_case to Title Case without Rails .titleize
      status.to_s.split('_').map(&:capitalize).join(' ')
    end
  end

  # Calculate HP percentage
  def format_hp_percent(participant)
    return '0%' if participant.max_hp == 0

    percent = (participant.current_hp.to_f / participant.max_hp * 100).round
    "#{percent}%"
  end

  # Calculate target score (higher = better target)
  def calculate_target_score(enemy)
    score = 0

    # Lower HP = higher priority (vulnerable)
    hp_percent = enemy.current_hp.to_f / enemy.max_hp
    score += (1 - hp_percent) * 50

    # Closer distance = higher priority
    if viewer
      distance = viewer.hex_distance_to(enemy)
      score += [10 - distance, 0].max * 3
    end

    # In melee range is better (can attack without moving)
    if viewer&.in_melee_range?(enemy)
      score += 20
    end

    # Enemies with status effects are easier targets
    if enemy.active_status_effects.any?
      score += 10
    end

    # Enemies that have already acted are slightly lower priority
    if enemy.acted_this_round
      score -= 5
    end

    score
  end

  # Get reasons for recommending a target
  def target_reasons(enemy)
    reasons = []

    hp_percent = enemy.current_hp.to_f / enemy.max_hp
    if hp_percent <= 0.25
      reasons << "Critical HP (#{(hp_percent * 100).round}%)"
    elsif hp_percent <= 0.5
      reasons << "Low HP (#{(hp_percent * 100).round}%)"
    end

    if viewer
      distance = viewer.hex_distance_to(enemy)
      if viewer.in_melee_range?(enemy)
        reasons << "In melee range"
      elsif distance <= 3
        reasons << "Close (#{distance} hexes)"
      end
    end

    if enemy.active_status_effects.any?
      reasons << "Has debuffs"
    end

    reasons << "Full HP, standard target" if reasons.empty?

    reasons
  end

  # Get text for available actions
  def available_actions_text
    lines = []
    lines << "Main actions:"
    lines << "  attack <target> - Attack an enemy"
    lines << "  defend - Focus on defense"
    lines << "  dodge - Attempt to evade attacks"
    lines << "  pass - Take no action"

    if viewer&.available_main_abilities&.any?
      lines << ""
      lines << "Abilities:"
      viewer.available_main_abilities.each do |ability|
        lines << "  #{ability.name} - #{StringHelper.truncate(ability.description, 50)}"
      end
    end

    lines << ""
    lines << "Movement:"
    lines << "  move towards <target> - Move closer"
    lines << "  move away - Move away from threats"
    lines << "  stand still - Hold position"

    lines << ""
    lines << "Other:"
    lines << "  done - Finish your turn"
    lines << "  combat recommend - Get target suggestion"

    lines.join("\n")
  end

  # Convert participant to hash for structured data
  def participant_to_hash(participant)
    {
      id: participant.id,
      name: participant.character_name,
      current_hp: participant.current_hp,
      max_hp: participant.max_hp,
      hp_percent: participant.max_hp > 0 ? (participant.current_hp.to_f / participant.max_hp * 100).round : 0,
      is_knocked_out: participant.is_knocked_out,
      hex_x: participant.hex_x,
      hex_y: participant.hex_y,
      distance: viewer ? viewer.hex_distance_to(participant) : nil,
      in_melee_range: viewer ? viewer.in_melee_range?(participant) : nil,
      willpower: participant.willpower_dice.to_f.round(1),
      weapon: (participant.melee_weapon || participant.ranged_weapon)&.name,
      input_complete: participant.input_complete,
      is_current_character: viewer&.id == participant.id
    }
  end

  # Convert monster to hash for structured data
  def monster_to_hash(monster)
    {
      id: monster.id,
      name: monster.display_name,
      monster_type: monster.monster_template&.monster_type,
      current_hp: monster.current_hp,
      max_hp: monster.max_hp,
      hp_percent: monster.max_hp > 0 ? (monster.current_hp.to_f / monster.max_hp * 100).round : 0,
      status: monster.status,
      hex_x: monster.center_hex_x,
      hex_y: monster.center_hex_y,
      segments: monster.monster_segment_instances.map do |seg|
        {
          id: seg.id,
          name: seg.name,
          current_hp: seg.current_hp,
          max_hp: seg.max_hp,
          status: seg.status,
          can_attack: seg.can_attack,
          is_weak_point: seg.monster_segment_template&.is_weak_point
        }
      end
    }
  end
end
