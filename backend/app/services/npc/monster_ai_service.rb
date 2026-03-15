# frozen_string_literal: true

# AI decision-making for monsters in combat.
# Selects which segments attack, when to shake off, and targeting.
#
# Tactical priorities:
# 1. Weak point attackers (highest threat - 3x damage)
# 2. Active climbers (approaching weak point)
# 3. Mounted participants (on segments)
# 4. Ground targets (standard combat)
#
# @example
#   ai = MonsterAIService.new(monster_instance)
#   decisions = ai.decide_actions
#   # => { attacking_segments: [...], should_shake_off: true, shake_off_segment: 47 }
#
class MonsterAIService
  def initialize(monster_instance)
    @monster = monster_instance
    @template = monster_instance.monster_template
    @fight = monster_instance.fight
    @mount_states = @monster.monster_mount_states.to_a
  end

  # Decide all actions for this round
  # @return [Hash] { attacking_segments: Array, should_shake_off: Boolean, shake_off_segment: Integer,
  #                  should_turn: Boolean, turn_direction: Integer, should_move: Boolean,
  #                  move_target: Array, movement_segment: Integer }
  def decide_actions
    threats = assess_threats

    {
      attacking_segments: select_attacking_segments(threats),
      should_shake_off: should_shake_off?(threats),
      shake_off_segment: shake_off_segment_number(threats),
      # Movement and turning decisions
      should_turn: should_turn?(threats),
      turn_direction: decide_turn_direction(threats),
      should_move: should_move?(threats),
      move_target: decide_move_target(threats),
      movement_segment: rand(35..50)
    }
  end

  # Assess current threat levels from mounted participants
  # @return [Hash] categorized threat information
  def assess_threats
    at_weak_point = []
    climbing = []
    mounted = []

    @mount_states.each do |ms|
      case ms.mount_status
      when 'at_weak_point'
        at_weak_point << ms
      when 'climbing'
        climbing << ms
      when 'mounted'
        mounted << ms
      end
    end

    {
      at_weak_point: at_weak_point,
      climbing: climbing,
      mounted: mounted,
      total_mounted: @mount_states.count { |ms| ms.mount_status != 'thrown' && ms.mount_status != 'dismounted' }
    }
  end

  # Select which segments will attack this round
  # Uses tactical selection based on threat assessment
  # @param threats [Hash] from assess_threats
  # @return [Array<MonsterSegmentInstance>]
  def select_attacking_segments(threats = nil)
    threats ||= assess_threats
    available = filter_available_segments

    return [] if available.empty?

    # Tactical selection based on threats
    if threats[:at_weak_point].any?
      # EMERGENCY: All available segments focus on weak point threats
      prioritize_weak_point_defenders(available, threats)
    elsif threats[:climbing].any?
      # HIGH PRIORITY: Balance between climber targeting and ground defense
      balance_climber_targeting(available, threats)
    else
      # NORMAL: Spread attacks among ground targets
      spread_ground_attacks(available)
    end
  end

  # Determine if monster should attempt shake-off this round
  # Triggers earlier when climbers approach weak point
  # @param threats [Hash] from assess_threats
  # @return [Boolean]
  def should_shake_off?(threats = nil)
    threats ||= assess_threats

    # URGENT: Always shake off if anyone at weak point
    return true if threats[:at_weak_point].any?

    # PROACTIVE: Lower threshold when climbers are actively climbing
    base_threshold = @template.shake_off_threshold
    climbing_count = threats[:climbing].count

    # Reduce threshold by 1 for each climber (min threshold of 1)
    adjusted_threshold = [base_threshold - climbing_count, 1].max

    threats[:total_mounted] >= adjusted_threshold
  end

  # Determine at which segment (1-100) the shake-off occurs
  # @param threats [Hash] from assess_threats
  # @return [Integer, nil]
  def shake_off_segment_number(threats = nil)
    threats ||= assess_threats
    return nil unless should_shake_off?(threats)

    # URGENT shake-off happens early (15-25) if at weak point
    if threats[:at_weak_point].any?
      return rand(15..25)
    end

    # Normal shake-off happens mid-round (45-55)
    rand(45..55)
  end

  # Select target for a segment attack using tactical priorities
  # @param segment [MonsterSegmentInstance]
  # @return [FightParticipant, nil]
  def select_target_for_segment(segment)
    # Priority 1: Anyone at the weak point (extreme threat)
    target = find_weak_point_attacker(segment)
    return target if target

    # Priority 2: Active climbers (approaching weak point)
    target = find_closest_climber(segment)
    return target if target

    # Priority 3: Anyone mounted on this specific segment
    target = find_mounted_on_segment(segment)
    return target if target

    # Priority 4: Ground targets using profile-based selection
    select_ground_target(segment)
  end

  # Check if a segment can hit a specific target (range check)
  # Mounted targets are always in range of segments on the same monster
  # @param segment [MonsterSegmentInstance]
  # @param target [FightParticipant]
  # @return [Boolean]
  def segment_can_hit?(segment, target)
    # Mounted targets are always hittable (they're on the monster)
    return true if target.is_mounted && target.targeting_monster_id == @monster.id

    segment_pos = segment.hex_position
    reach = segment.monster_segment_template.reach
    distance = HexGrid.hex_distance(segment_pos[0], segment_pos[1], target.hex_x, target.hex_y)

    distance <= reach
  end

  private

  # Filter segments that can attack this round
  # Excludes segments with mounted players (can't hit your own mount point)
  # @return [Array<MonsterSegmentInstance>]
  def filter_available_segments
    available = @monster.segments_that_can_attack

    # Don't attack with segments that have mounted players on them
    # (those players are protected from that segment's attacks)
    mounted_segment_ids = @mount_states.map(&:current_segment_id).compact
    available.reject { |s| mounted_segment_ids.include?(s.id) }
  end

  # All available segments attack weak point threats
  # @param available [Array<MonsterSegmentInstance>]
  # @param threats [Hash]
  # @return [Array<MonsterSegmentInstance>]
  def prioritize_weak_point_defenders(available, threats)
    # Use ALL available segments when weak point is threatened
    # This is an emergency response
    available
  end

  # Balance between targeting climbers and maintaining ground defense
  # @param available [Array<MonsterSegmentInstance>]
  # @param threats [Hash]
  # @return [Array<MonsterSegmentInstance>]
  def balance_climber_targeting(available, threats)
    range = @template.segment_attack_count_range
    count = rand(range[0]..range[1])
    count = [count, available.count].min

    # Prioritize segments that can reach climbers
    climber_participant_ids = threats[:climbing].map(&:fight_participant_id)
    climber_participants = @fight.fight_participants.select { |p| climber_participant_ids.include?(p.id) }

    # Score segments by ability to hit climbers
    scored = available.map do |segment|
      climber_score = climber_participants.count { |cp| segment_can_hit?(segment, cp) }
      [segment, climber_score]
    end

    # Sort by score (highest first) and take top segments
    scored.sort_by { |_s, score| -score }.take(count).map(&:first)
  end

  # Spread attacks among ground targets (normal combat)
  # @param available [Array<MonsterSegmentInstance>]
  # @return [Array<MonsterSegmentInstance>]
  def spread_ground_attacks(available)
    range = @template.segment_attack_count_range
    count = rand(range[0]..range[1])
    count = [count, available.count].min

    # Random selection for normal combat
    available.sample(count)
  end

  # Find participant at the weak point that segment can hit
  # @param segment [MonsterSegmentInstance]
  # @return [FightParticipant, nil]
  def find_weak_point_attacker(segment)
    @mount_states.each do |ms|
      next unless ms.mount_status == 'at_weak_point'

      participant = @fight.fight_participants.find { |p| p.id == ms.fight_participant_id }
      next unless participant && !participant.is_knocked_out

      return participant if segment_can_hit?(segment, participant)
    end

    nil
  end

  # Find closest active climber that segment can hit
  # @param segment [MonsterSegmentInstance]
  # @return [FightParticipant, nil]
  def find_closest_climber(segment)
    climbers = @mount_states.select { |ms| ms.mount_status == 'climbing' }
    return nil if climbers.empty?

    # Sort by climb progress (highest = closest to weak point = most dangerous)
    climbers.sort_by { |ms| -(ms.climb_progress || 0) }.each do |ms|
      participant = @fight.fight_participants.find { |p| p.id == ms.fight_participant_id }
      next unless participant && !participant.is_knocked_out

      return participant if segment_can_hit?(segment, participant)
    end

    nil
  end

  # Find anyone mounted on this specific segment
  # @param segment [MonsterSegmentInstance]
  # @return [FightParticipant, nil]
  def find_mounted_on_segment(segment)
    @mount_states.each do |ms|
      next unless ms.current_segment_id == segment.id
      next unless %w[mounted climbing].include?(ms.mount_status)

      participant = @fight.fight_participants.find { |p| p.id == ms.fight_participant_id }
      return participant if participant && !participant.is_knocked_out
    end

    nil
  end

  # Select ground target using AI profile-based selection
  # @param segment [MonsterSegmentInstance]
  # @return [FightParticipant, nil]
  def select_ground_target(segment)
    valid_targets = @fight.fight_participants.select do |p|
      next false if p.is_knocked_out
      next false if p.character_instance&.character&.npc?  # Don't attack other NPCs
      next false if p.is_mounted  # Already handled mounted targets above

      segment_can_hit?(segment, p)
    end

    return nil if valid_targets.empty?

    # Prioritize based on AI profile from archetype
    ai_profile = @template.npc_archetype&.ai_profile || 'aggressive'

    case ai_profile
    when 'aggressive', 'berserker'
      # Target weakest (lowest HP) - finish them off
      valid_targets.min_by(&:current_hp)
    when 'defensive', 'guardian'
      # Target whoever is threatening most
      valid_targets.max_by { |t| threat_score(t, segment) }
    else
      # Balanced: target closest
      segment_pos = segment.hex_position
      valid_targets.min_by do |t|
        dx = t.hex_x - segment_pos[0]
        dy = t.hex_y - segment_pos[1]
        Math.sqrt(dx * dx + dy * dy)
      end
    end
  end

  # Calculate threat score for a participant
  # Higher score = more threatening
  # @param participant [FightParticipant]
  # @param segment [MonsterSegmentInstance]
  # @return [Integer]
  def threat_score(participant, segment)
    score = 0

    # Mounted players are more threatening
    if participant.is_mounted
      score += 20

      # Even more if they're on this segment
      score += 10 if segment && participant.targeting_segment_id == segment.id

      # Most threatening if at weak point
      mount_state = @mount_states.find { |ms| ms.fight_participant_id == participant.id }
      score += 30 if mount_state&.at_weak_point?
    end

    # Closer = more threatening
    if segment
      segment_pos = segment.hex_position
      distance = HexGrid.hex_distance(segment_pos[0], segment_pos[1], participant.hex_x, participant.hex_y)
    else
      distance = HexGrid.hex_distance(@monster.center_hex_x, @monster.center_hex_y, participant.hex_x, participant.hex_y)
    end
    score += (10 - [distance, 10].min).to_i

    # Damaged players are less threatening (focus elsewhere)
    score -= participant.wound_penalty

    score
  end

  # Determine if monster should turn this round
  # @param threats [Hash] from assess_threats
  # @return [Boolean]
  def should_turn?(threats)
    return false if @monster.collapsed?

    # Always turn to face weak point attackers
    return true if threats[:at_weak_point].any?

    # Turn to face highest threat ground target if not already facing
    highest_threat = find_ground_targets.first
    return false unless highest_threat

    desired_dir = direction_to(highest_threat.hex_x, highest_threat.hex_y)
    desired_dir != (@monster.facing_direction || 0)
  end

  # Decide which direction to turn
  # @param threats [Hash] from assess_threats
  # @return [Integer] 0-5 direction
  def decide_turn_direction(threats)
    # Priority: weak point attackers, then highest threat ground target
    target = threats[:at_weak_point].first&.fight_participant ||
             find_ground_targets.first
    return @monster.facing_direction || 0 unless target

    direction_to(target.hex_x, target.hex_y)
  end

  # Determine if monster should move this round
  # @param threats [Hash] from assess_threats
  # @return [Boolean]
  def should_move?(threats)
    return false if @monster.collapsed?

    # Chase if targets are out of reach
    targets = find_ground_targets
    return false if targets.empty?

    closest = targets.min_by { |t| distance_to(t) }
    distance_to(closest) > max_segment_reach
  end

  # Decide where to move
  # @param threats [Hash] from assess_threats
  # @return [Array<Integer>, nil] [x, y] target position or nil
  def decide_move_target(threats)
    return nil unless should_move?(threats)

    target = find_ground_targets.min_by { |t| distance_to(t) }
    return nil unless target

    # Move toward target using hex stepping
    dx = target.hex_x - @monster.center_hex_x
    dy = target.hex_y - @monster.center_hex_y
    return nil if dx == 0 && dy == 0

    # Use Euclidean for direction vector (needed for fractional step calculation)
    dist = Math.sqrt(dx * dx + dy * dy)
    step = 2 # Move 2 hexes per action
    new_x = @monster.center_hex_x + (dx.to_f / dist * step).round
    new_y = @monster.center_hex_y + (dy.to_f / dist * step).round

    # Clamp to valid arena hex bounds
    clamp_to_arena_hex(new_x, new_y)
  end

  # Find all valid ground targets (not mounted, not KO'd, not NPCs)
  # @return [Array<FightParticipant>] sorted by threat (highest first)
  def find_ground_targets
    @fight.fight_participants.reject do |p|
      p.is_knocked_out || p.is_mounted || p.character_instance&.character&.npc?
    end.sort_by { |t| -threat_score(t, nil) }
  end

  # Calculate distance from monster center to a participant
  # @param participant [FightParticipant]
  # @return [Float]
  def distance_to(participant)
    HexGrid.hex_distance(
      @monster.center_hex_x, @monster.center_hex_y,
      participant.hex_x, participant.hex_y
    )
  end

  # Get direction from monster to target position
  # @param target_x [Integer]
  # @param target_y [Integer]
  # @return [Integer] 0-5 direction
  def direction_to(target_x, target_y)
    @monster.direction_to(target_x, target_y)
  end

  # Get maximum reach of any segment
  # @return [Integer]
  def max_segment_reach
    @monster.monster_segment_instances.map { |s| s.monster_segment_template.reach }.max || 1
  end

  def clamp_to_arena_hex(hex_x, hex_y)
    HexGrid.clamp_to_arena(hex_x, hex_y, @fight.arena_width, @fight.arena_height)
  end
end
