# frozen_string_literal: true

# Logs everything that happens during a combat round to daily log files.
# Always-on, auto-cleans files older than 3 days.
#
# Log files: log/combat_rounds_YYYY-MM-DD.log
# Format: human-readable sections with structured data per round
class CombatRoundLogger
  LOG_DIR = File.join(__dir__, '..', '..', '..', 'log')
  RETENTION_DAYS = 3

  def initialize(fight)
    @fight = fight
    @buffer = []
    cleanup_old_logs
  end

  # === Phase Logging Methods ===

  # Log round header with participant states and inputs
  def log_round_start(participants, round_state)
    section('ROUND START', "Fight ##{@fight.id} | Round #{@fight.round_number} | Room: #{@fight.room&.name || @fight.room_id} | Battle Map: #{battle_map_active?}")

    participants.each_value do |p|
      state = round_state[p.id] || {}
      lines = []
      lines << "  #{p.character_name} (ID:#{p.id})"
      lines << "    Position: (#{p.hex_x}, #{p.hex_y}) | HP: #{p.current_hp}/#{p.max_hp} | Wound Penalty: #{p.wound_penalty}"
      lines << "    Movement: #{p.movement_action || 'none'} | Target Hex: (#{p.target_hex_x}, #{p.target_hex_y}) | Target Participant: #{p.movement_target_participant_id}"
      lines << "    Main Action: #{p.main_action} | Target: #{p.target_participant_id} | Tactic: #{p.tactic_choice}"
      lines << "    Willpower: atk=#{p.willpower_attack} def=#{p.willpower_defense} abi=#{p.willpower_ability} mov=#{p.willpower_movement} (dice: #{p.willpower_dice.to_f.round(3)})"
      lines << "    Movement Speed: #{p.movement_speed} | WP Move Bonus: #{state[:willpower_movement_bonus] || 0}"
      if p.tactic_choice && !p.tactic_choice.to_s.empty?
        lines << "    Tactic Effects: outgoing_dmg=#{p.tactic_outgoing_damage_modifier} incoming_dmg=#{p.tactic_incoming_damage_modifier} move_bonus=#{p.tactic_movement_modifier}"
      end
      lines << "    Status: #{p.is_knocked_out ? 'KO' : 'active'} | Snared: #{!p.can_move?}" if p.respond_to?(:can_move?)
      @buffer.concat(lines)
    end
  end

  # Log movement path calculation for a participant
  def log_movement_planning(participant, movement_action, movement_budget, path, method_used)
    line = "  [MOVE PLAN] #{participant.character_name}: action=#{movement_action} budget=#{movement_budget} method=#{method_used} path_length=#{path.length}"
    if path.any?
      coords = path.map { |x, y| "(#{x},#{y})" }.join(' -> ')
      line += "\n    Path: (#{participant.hex_x},#{participant.hex_y}) -> #{coords}"
    else
      line += ' | Path: EMPTY (no movement)'
    end
    @buffer << line
  end

  # Log when movement path calculation fails or falls back
  def log_movement_fallback(participant, primary_method, fallback_method, reason)
    @buffer << "  [MOVE FALLBACK] #{participant.character_name}: #{primary_method} -> #{fallback_method} (#{reason})"
  end

  # Log pathfinding details (A* results)
  def log_pathfinding_detail(participant, full_path_length, budget_limited_length, movement_budget, terrain_costs: nil)
    line = "  [PATHFIND] #{participant.character_name}: A* found #{full_path_length} hexes, budget allows #{budget_limited_length}/#{movement_budget}"
    if terrain_costs
      line += "\n    Terrain costs: #{terrain_costs.map { |c| c.round(1) }.join(', ')}"
    end
    @buffer << line
  end

  # Log why pathfinding failed (empty path)
  def log_pathfinding_failure(participant, from_x, from_y, to_x, to_y, reason)
    @buffer << "  [PATHFIND FAIL] #{participant.character_name}: (#{from_x},#{from_y}) -> (#{to_x},#{to_y}) | #{reason}"
  end

  # Log budget truncation (path was shorter than expected)
  def log_budget_truncation(participant, truncation_info)
    info = truncation_info
    @buffer << "  [PATHFIND TRUNCATED] #{participant.character_name}: #{info[:steps_taken]}/#{info[:path_length]} steps, budget=#{info[:budget]}"
    info[:step_costs]&.each do |sc|
      if sc[:reason]
        @buffer << "    Step to #{sc[:to] || '?'}: #{sc[:reason]}"
      else
        @buffer << "    Step to #{sc[:to]}: cost=#{sc[:cost]}"
      end
    end
  end

  # Log dynamic step resolution failure
  def log_dynamic_step_failure(participant, action, from_x, from_y, target_name, reason)
    @buffer << "  [DYNAMIC STEP FAIL] #{participant.character_name}: #{action} from (#{from_x},#{from_y}) toward #{target_name} | #{reason}"
  end

  # Log scheduled segment events summary
  def log_scheduled_events(segment_events)
    section('SCHEDULED EVENTS')
    counts = Hash.new(0)
    segment_events.each_with_index do |events, seg|
      next if events.nil? || events.empty?

      events.each do |e|
        counts[e[:type]] += 1
        actor_name = e[:actor]&.character_name || e[:actor_name] || '?'
        target_name = e[:target]&.character_name || e.dig(:target_hex)&.then { |h| "(#{h[0]},#{h[1]})" } || ''
        @buffer << "  Seg #{seg}: #{e[:type]} | #{actor_name}#{target_name.empty? ? '' : " -> #{target_name}"}"
      end
    end
    @buffer << "  Totals: #{counts.map { |k, v| "#{k}=#{v}" }.join(', ')}"
  end

  # Log individual movement step execution
  def log_movement_step(participant, step_index, total_steps, old_x, old_y, new_x, new_y)
    @buffer << "  [MOVE] #{participant.character_name}: step #{step_index + 1}/#{total_steps} (#{old_x},#{old_y}) -> (#{new_x},#{new_y})"
  end

  # Log when movement is skipped/blocked
  def log_movement_skipped(participant, reason, step_index: nil, segment: nil)
    step_info = step_index ? " step=#{step_index}" : ''
    seg_info = segment ? " seg=#{segment}" : ''
    @buffer << "  [MOVE SKIP] #{participant.character_name}: #{reason}#{step_info}#{seg_info}"
  end

  # Log full attack resolution with damage breakdown
  def log_attack(segment, actor, target, weapon_type, roll_data, map_mods, final_damage, cumulative_damage, distance, damage_result)
    line = "  [ATTACK] Seg #{segment}: #{actor.character_name} -> #{target.character_name}"
    line += " | weapon=#{weapon_type} dist=#{distance}"

    # Dice roll breakdown
    base_roll = roll_data[:attack_roll]
    line += "\n    Dice: #{base_roll&.respond_to?(:dice_values) ? base_roll.dice_values.inspect : base_roll&.total}"
    line += " + stat=#{roll_data[:round_stat_modifier]}"
    line += " + wp_atk=#{roll_data[:willpower_attack_mod]}"
    line += " - wound=#{actor.wound_penalty}" if actor.wound_penalty > 0
    line += " + all_roll_pen=#{roll_data[:all_roll_penalty]}" if roll_data[:all_roll_penalty] != 0
    line += " - dodge=#{roll_data[:dodge_penalty]}" if roll_data[:dodge_penalty] != 0
    line += " => per_attack=#{roll_data[:total]}"

    # Map modifiers
    if map_mods[:elevation_mod] != 0 || map_mods[:cover_penalty] != 0 || map_mods[:los_penalty] != 0 || map_mods[:cover_damage_multiplier] != 1.0
      line += "\n    Map: elev=#{map_mods[:elevation_mod]} cover=-#{map_mods[:cover_penalty]} los=#{map_mods[:los_penalty]}"
      line += " cover_mult=#{map_mods[:cover_damage_multiplier]}" if map_mods[:cover_damage_multiplier] != 1.0
      line += " cover_obj=#{map_mods[:cover_object]}" if map_mods[:cover_object]
    end

    # Final modifiers
    if roll_data[:outgoing_mod] && roll_data[:outgoing_mod] != 0
      line += "\n    Outgoing mod: +#{roll_data[:outgoing_mod]}"
    end
    if roll_data[:incoming_mod] && roll_data[:incoming_mod] != 0
      line += " Incoming mod: #{roll_data[:incoming_mod]}"
    end

    # Result
    line += "\n    Result: final_dmg=#{final_damage} cumul=#{cumulative_damage}"
    line += " | threshold_crossed=#{damage_result[:threshold_crossed]} hp_lost=#{damage_result[:hp_lost_this_attack]}"

    @buffer << line
  end

  # Log attack out of range
  def log_attack_out_of_range(segment, actor, target, distance, max_range)
    @buffer << "  [ATTACK MISS] Seg #{segment}: #{actor.character_name} -> #{target.character_name} | OUT OF RANGE dist=#{distance} max=#{max_range}"
  end

  # Log attack blocked by cover
  def log_attack_blocked(segment, actor, target, reason)
    @buffer << "  [ATTACK BLOCKED] Seg #{segment}: #{actor.character_name} -> #{target.character_name} | #{reason}"
  end

  # Log ability use
  def log_ability(segment, actor, target, ability_name, roll_total, details: {})
    target_name = target&.character_name || 'self'
    line = "  [ABILITY] Seg #{segment}: #{actor.character_name} uses #{ability_name} on #{target_name} | roll=#{roll_total}"
    if details.any?
      extras = details.map { |k, v| "#{k}=#{v}" }.join(' ')
      line += " | #{extras}"
    end
    @buffer << line
  end

  # Log damage threshold crossing
  def log_damage_threshold(target, cumulative, effective, hp_lost_now, hp_lost_total, remaining_hp, armor: 0, protection: 0, wp_defense: 0)
    @buffer << "  [DAMAGE] #{target.character_name}: cumul=#{cumulative} effective=#{effective} (armor=-#{armor} prot=-#{protection} wp_def=-#{wp_defense}) | HP lost: +#{hp_lost_now} (total #{hp_lost_total}) | HP: #{remaining_hp}"
  end

  # Log knockout
  def log_knockout(participant, segment, total_damage)
    @buffer << "  [KNOCKOUT] #{participant.character_name} at seg #{segment} | total_damage=#{total_damage} | HP: #{participant.current_hp}"
  end

  # Log hazard damage
  def log_hazard_damage(participant, hazard_type, damage, hex_x, hex_y)
    @buffer << "  [HAZARD] #{participant.character_name}: #{hazard_type} at (#{hex_x},#{hex_y}) | damage=#{damage}"
  end

  # Log flee attempt
  def log_flee(participant, success, direction: nil, damage_taken: 0)
    result = success ? 'SUCCESS' : "FAILED (damage=#{damage_taken})"
    @buffer << "  [FLEE] #{participant.character_name}: #{result} dir=#{direction}"
  end

  # Log round end with final states
  def log_round_end(participants, round_state, errors)
    section('ROUND END')

    participants.each_value do |p|
      p.refresh if p.respond_to?(:refresh)
      state = round_state[p.id] || {}
      dmg = state[:cumulative_damage] || 0
      hp_lost = state[:hp_lost_this_round] || 0
      @buffer << "  #{p.character_name}: pos=(#{p.hex_x},#{p.hex_y}) HP=#{p.current_hp}/#{p.max_hp} dmg_taken=#{dmg} hp_lost=#{hp_lost} #{p.is_knocked_out ? '[KO]' : ''}"
    end

    if errors.any?
      @buffer << '  ERRORS:'
      errors.each { |e| @buffer << "    #{e[:step]}: #{e[:error_class]}: #{e[:message]}" }
    end

    @buffer << "  Events generated: #{@fight.fight_events_dataset.where(round_number: @fight.round_number).count rescue '?'}"
  end

  # Log active status effects for all participants at round start
  def log_status_effects(participants)
    any_effects = false
    participants.each_value do |p|
      effects = StatusEffectService.active_effects(p) rescue []
      next if effects.empty?

      any_effects = true
      effect_strs = effects.map do |pse|
        se = pse.status_effect
        name = se&.name || pse.status_effect_id
        "#{name}(type=#{se&.effect_type} expires_round=#{pse.expires_at_round})"
      end
      @buffer << "  [STATUS] #{p.character_name}: #{effect_strs.join(', ')}"
    end
    @buffer << '  [STATUS] (none active)' unless any_effects
  end

  # Log NPC AI decision
  def log_ai_decision(participant, decisions)
    @buffer << "  [AI] #{participant.character_name}: main=#{decisions[:main_action]} target=#{decisions[:target_participant_id]} move=#{decisions[:movement_action]} ability=#{decisions[:ability_id] || 'none'} tactic=#{decisions[:tactic_choice] || 'none'}"
  end

  # Log pre-rolled combat dice for participants
  def log_pre_rolls(pre_rolls, participants)
    section('PRE-ROLLS')
    if pre_rolls.nil? || pre_rolls.empty?
      @buffer << '  (no attackers this round)'
      return
    end
    pre_rolls.each do |pid, pr|
      p = participants[pid]
      name = p&.character_name || "ID:#{pid}"
      base = pr[:base_roll]
      dice_str = base.respond_to?(:dice_values) ? base.dice_values.inspect : base.total.to_s
      wp_str = pr[:willpower_roll] ? " wp_atk=#{pr[:willpower_roll].total}" : ''
      @buffer << "  #{name}: #{pr[:attack_count]} attacks | dice=#{dice_str} stat=#{pr[:total_stat_modifier]} all_pen=#{pr[:all_roll_penalty]}#{wp_str} => round_total=#{pr[:roll_total]}"
    end
  end

  # Log weapon reevaluation (switch between melee/ranged/unarmed)
  def log_weapon_switch(actor, target, distance, old_type, new_type, new_weapon_name)
    @buffer << "  [WEAPON SWITCH] #{actor.character_name} -> #{target.character_name}: dist=#{distance} #{old_type} -> #{new_type} (#{new_weapon_name || 'unarmed'})"
  end

  # Log attack redirection (guard/back-to-back)
  def log_attack_redirect(segment, actor, original_target, new_target, redirect_type)
    @buffer << "  [REDIRECT] Seg #{segment}: #{actor.character_name} -> #{original_target.character_name} redirected to #{new_target.character_name} (#{redirect_type})"
  end

  # Log fight end
  def log_fight_end(reason, winner_name: nil)
    section('FIGHT ENDED')
    @buffer << "  Reason: #{reason}"
    @buffer << "  Winner: #{winner_name}" if winner_name
  end

  # Log spar touch
  def log_spar_touch(participant, touch_count, max_touches)
    @buffer << "  [SPAR TOUCH] #{participant.character_name}: #{touch_count}/#{max_touches}"
  end

  # Log the narrative text generated for the round
  def log_narrative(narrative_text)
    section('NARRATIVE')
    if narrative_text && !narrative_text.strip.empty?
      narrative_text.each_line { |line| @buffer << "  #{line.rstrip}" }
    else
      @buffer << '  (no narrative generated)'
    end
  end

  # Log the damage summary string
  def log_damage_summary(summary)
    @buffer << "  [DAMAGE SUMMARY] #{summary}" if summary && !summary.to_s.strip.empty?
  end

  # Flush buffer to disk
  def flush!
    return if @buffer.empty?

    timestamp = Time.now.strftime('%Y-%m-%dT%H:%M:%S')
    log_path = File.join(LOG_DIR, "combat_rounds_#{Time.now.strftime('%Y-%m-%d')}.log")

    File.open(log_path, 'a') do |f|
      f.puts "=" * 80
      f.puts "[#{timestamp}] Fight ##{@fight.id} Round #{@fight.round_number}"
      f.puts "=" * 80
      @buffer.each { |line| f.puts line }
      f.puts
    end

    @buffer.clear
  rescue StandardError => e
    warn "[CombatRoundLogger] Failed to write log: #{e.message}"
    @buffer.clear
  end

  private

  def section(title, subtitle = nil)
    @buffer << "--- #{title} #{subtitle ? "| #{subtitle} " : ''}---"
  end

  def battle_map_active?
    BattleMapCombatService.new(@fight).battle_map_active?
  rescue StandardError
    'unknown'
  end

  # Delete log files older than RETENTION_DAYS
  def cleanup_old_logs
    cutoff = Time.now - (RETENTION_DAYS * 86_400)
    Dir.glob(File.join(LOG_DIR, 'combat_rounds_*.log')).each do |path|
      File.delete(path) if File.mtime(path) < cutoff
    end
  rescue StandardError => e
    warn "[CombatRoundLogger] Cleanup failed: #{e.message}"
  end
end
