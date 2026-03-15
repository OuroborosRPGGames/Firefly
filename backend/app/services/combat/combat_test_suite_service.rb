# frozen_string_literal: true

# Automated combat test suite that runs fight configurations through the real
# combat pipeline (FightService, CombatResolutionService, CombatRoundLogger).
#
# Usage:
#   service = CombatTestSuiteService.new(repetitions: 1)
#   results = service.run_all!
#   service.print_report(results)
#
class CombatTestSuiteService
  MAX_ROUNDS = 50

  # Ordered simplest-first for easier debugging
  FIGHT_CONFIGS = [
    { name: '1v1 PC',           pc_sides: { 1 => 1, 2 => 1 }, npc_sides: {} },
    { name: '1 PC vs 1 NPC',    pc_sides: { 1 => 1 },         npc_sides: { 2 => 1 } },
    { name: '3v1 PC',           pc_sides: { 1 => 3, 2 => 1 }, npc_sides: {} },
    { name: '1 PC vs 5 NPCs',   pc_sides: { 1 => 1 },         npc_sides: { 2 => 5 } },
    { name: '3v3 PC',           pc_sides: { 1 => 3, 2 => 3 }, npc_sides: {} },
    { name: '3 PCs vs 5 NPCs',  pc_sides: { 1 => 3 },         npc_sides: { 2 => 5 } },
  ].freeze

  # Weapon loadouts reference existing pattern IDs.
  # Populated at runtime from actual weapon patterns in the DB.
  # Each loadout is { melee: Pattern|nil, ranged: Pattern|nil }

  attr_reader :repetitions, :use_battlemaps

  def initialize(repetitions: 1, use_battlemaps: true)
    @repetitions = repetitions
    @use_battlemaps = use_battlemaps
    @weapon_loadouts = nil
  end

  def run_all!
    rooms = select_rooms
    archetypes = load_delve_archetypes
    if archetypes.empty?
      warn '[CombatTestSuite] No Delve NpcArchetype records found — NPC fights will be skipped'
    end

    agents = load_test_agents
    if agents.size < 6
      warn "[CombatTestSuite] Only #{agents.size} test agents available (need up to 6) — some configs may be skipped"
    end

    @weapon_loadouts = build_weapon_loadouts
    puts "  Weapon loadouts: #{@weapon_loadouts.map { |l| l[:label] }.join(', ')}"

    results = []

    FIGHT_CONFIGS.each do |config|
      total_pcs = config[:pc_sides].values.sum
      total_npcs = config[:npc_sides].values.sum

      if total_pcs > agents.size
        warn "[CombatTestSuite] Skipping '#{config[:name]}' — needs #{total_pcs} PCs but only #{agents.size} agents"
        next
      end

      if total_npcs > 0 && archetypes.empty?
        warn "[CombatTestSuite] Skipping '#{config[:name]}' — no Delve NPC archetypes available"
        next
      end

      repetitions.times do |rep|
        room = rooms.sample
        result = run_fight(config, room, agents, archetypes, rep + 1)
        results << result
        puts "  #{result[:status] == :ok ? '✓' : '✗'} #{config[:name]} (rep #{rep + 1}) — " \
             "#{result[:rounds]} rounds, room #{room.id} #{room.has_battle_map ? '[battlemap]' : ''}"
      end
    end

    results
  end

  def print_report(results)
    puts ''
    puts '=' * 100
    puts 'COMBAT TEST SUITE REPORT'
    puts '=' * 100
    puts ''

    fmt = '%-20s %-6s %-10s %-8s %-8s %-10s %s'
    puts format(fmt, 'Config', 'Rep', 'Room', 'Map?', 'Rounds', 'Status', 'Winner/Error')
    puts '-' * 100

    results.each do |r|
      winner_info = if r[:error]
                      r[:error][0..40]
                    elsif r[:winner_side]
                      "Side #{r[:winner_side]}"
                    else
                      'draw/timeout'
                    end

      puts format(fmt,
                  r[:config_name][0..19],
                  r[:rep],
                  r[:room_id],
                  r[:has_battlemap] ? 'yes' : 'no',
                  r[:rounds],
                  r[:status],
                  winner_info)
    end

    puts ''

    results.each do |r|
      next unless r[:participants]&.any?

      puts "--- #{r[:config_name]} (rep #{r[:rep]}, fight ##{r[:fight_id]}) ---"
      r[:participants].each do |p|
        weapons = [p[:melee_weapon], p[:ranged_weapon]].compact.join(' + ')
        weapons = 'unarmed' if weapons.empty?
        puts "  Side #{p[:side]} | #{p[:name].to_s.ljust(20)} | HP: #{p[:current_hp]}/#{p[:max_hp]} | " \
             "KO: #{p[:knocked_out]} | #{weapons}"
      end
      puts ''
    end

    ok_count = results.count { |r| r[:status] == :ok }
    error_count = results.count { |r| r[:status] == :error }
    puts "Total: #{results.size} fights | #{ok_count} OK | #{error_count} errors"
    avg_rounds = results.select { |r| r[:rounds] }.map { |r| r[:rounds] }.then { |rr| rr.any? ? (rr.sum.to_f / rr.size).round(1) : 0 }
    puts "Average rounds: #{avg_rounds}"
    puts ''
  end

  private

  def select_rooms
    rooms = []

    if use_battlemaps
      battlemap_rooms = Room.where(has_battle_map: true).all
      rooms.concat(battlemap_rooms)
    end

    non_battlemap_rooms = Room.where(has_battle_map: false)
                              .exclude(min_x: nil)
                              .limit(5)
                              .all
    rooms.concat(non_battlemap_rooms)

    rooms = Room.exclude(min_x: nil).limit(10).all if rooms.empty?
    raise 'No suitable rooms found for combat testing' if rooms.empty?

    rooms
  end

  def load_delve_archetypes
    NpcArchetype.where(Sequel.like(:name, 'Delve %')).all
  end

  def load_test_agents
    config_path = File.join(File.dirname(__FILE__), '..', '..', '..', 'config', 'test_agent_tokens.json')
    return [] unless File.exist?(config_path)

    config = JSON.parse(File.read(config_path))
    (config['agents'] || []).filter_map do |a|
      CharacterInstance[a['instance_id']].tap do |ci|
        warn "[CombatTestSuite] Test agent instance #{a['instance_id']} not found" unless ci
      end
    end
  end

  # Build weapon loadouts from existing patterns in the DB
  def build_weapon_loadouts
    melee_patterns = Pattern.where(is_melee: true).eager(:unified_object_type).all
    ranged_patterns = Pattern.where(is_ranged: true).eager(:unified_object_type).all

    loadouts = []

    # Melee-only loadouts
    melee_patterns.each do |p|
      loadouts << { label: p.name || p.description, melee: p, ranged: nil }
    end

    # Ranged-only loadouts
    ranged_patterns.each do |p|
      loadouts << { label: p.name || p.description, melee: nil, ranged: p }
    end

    # Combined loadouts (each melee with each ranged)
    melee_patterns.each do |m|
      ranged_patterns.each do |r|
        loadouts << { label: "#{m.name || m.description} + #{r.name || r.description}", melee: m, ranged: r }
      end
    end

    # Always include unarmed
    loadouts << { label: 'unarmed', melee: nil, ranged: nil }

    if loadouts.size <= 1
      warn '[CombatTestSuite] No weapon patterns found — all agents will fight unarmed'
    end

    loadouts
  end

  def reset_character(ci, room)
    max_hp = GameConfig::Mechanics::DEFAULT_HP[:max]

    # Clean up old fight participants so stale records can't interfere
    FightParticipant.where(character_instance_id: ci.id).delete

    ci.update(
      current_room_id: room.id,
      max_health: max_hp,
      health: max_hp,
      status: 'alive',
      fled_from_fight_id: nil,
      surrendered_from_fight_id: nil
    )

    # Clear abilities — test agents shouldn't use NPC abilities
    CharacterAbility.where(character_instance_id: ci.id).delete

    # Remove old test weapons
    Item.where(character_instance_id: ci.id).where(
      Sequel.like(:name, '%[test]%')
    ).delete

    # Equip a random weapon loadout from existing patterns
    loadout = @weapon_loadouts.sample
    equip_from_pattern(ci, loadout[:melee], 'melee') if loadout[:melee]
    equip_from_pattern(ci, loadout[:ranged], 'ranged') if loadout[:ranged]

    ci.reload

    # Final sanity check — ensure HP is at max after all setup
    if ci.health.nil? || ci.health <= 0 || ci.health != max_hp
      ci.update(health: max_hp, max_health: max_hp)
      ci.reload
    end
  end

  def equip_from_pattern(ci, pattern, slot)
    item = pattern.instantiate(
      name: "#{pattern.name || pattern.description} [test]",
      character_instance: ci
    )
    item.update(equipped: true, held: true)
  end

  def run_fight(config, room, agents, archetypes, rep)
    result = {
      config_name: config[:name],
      rep: rep,
      room_id: room.id,
      has_battlemap: !!room.has_battle_map,
      fight_id: nil,
      rounds: 0,
      status: :ok,
      winner_side: nil,
      error: nil,
      participants: []
    }

    begin
      fight = Fight.create(
        room_id: room.id,
        battle_map_generating: false
      )
      result[:fight_id] = fight.id

      fight_service = FightService.new(fight)

      # Add PC participants with randomized positions
      pc_index = 0
      config[:pc_sides].each do |side, count|
        count.times do
          ci = agents[pc_index]
          break unless ci

          reset_character(ci, room)
          randomize_position!(ci, room)
          fight_service.add_participant(ci, side: side)
          pc_index += 1
        end
      end

      # Add NPC participants (Delve archetypes only)
      config[:npc_sides].each do |side, count|
        count.times do
          archetype = archetypes.sample
          FightService.spawn_npc_combatant(fight, archetype, side: side)
        end
      end

      rounds = resolve_fight_loop(fight_service)
      result[:rounds] = rounds

      # Determine winner (complete! marks everyone KO, so check HP > 0)
      fight.reload
      standing = fight.fight_participants_dataset.all.select { |p| p.current_hp.to_i > 0 }
      result[:winner_side] = standing.first.side if standing.any?

      fight.fight_participants_dataset.eager(:melee_weapon, :ranged_weapon).all.each do |p|
        result[:participants] << {
          name: p.is_npc ? p.npc_name : p.character_instance&.character&.full_name,
          side: p.side,
          current_hp: p.current_hp,
          max_hp: p.max_hp,
          knocked_out: p.is_knocked_out,
          is_npc: p.is_npc,
          melee_weapon: p.melee_weapon&.name,
          ranged_weapon: p.ranged_weapon&.name
        }
      end

    rescue StandardError => e
      result[:status] = :error
      result[:error] = "#{e.class}: #{e.message}"
      warn "[CombatTestSuite] Fight '#{config[:name]}' rep #{rep} failed: #{e.message}"
      warn e.backtrace&.first(5)&.join("\n")
    ensure
      begin
        fight&.reload
        fight.update(status: 'complete', combat_ended_at: Time.now) if fight&.ongoing?
      rescue StandardError
        # ignore cleanup errors
      end
    end

    result
  end

  # Place character at a random position within room bounds
  def randomize_position!(ci, room)
    return unless room.min_x && room.max_x && room.min_y && room.max_y

    range_x = room.max_x - room.min_x
    range_y = room.max_y - room.min_y
    ci.update(
      x: room.min_x + rand * range_x,
      y: room.min_y + rand * range_y
    )
  end

  def resolve_fight_loop(fight_service)
    fight = fight_service.fight
    rounds = 0

    loop do
      rounds += 1
      break if rounds > MAX_ROUNDS

      fight.reload
      fight.fight_participants_dataset.where(is_knocked_out: false, input_complete: false).each do |p|
        CombatAIService.new(p).apply_decisions!
      end

      fight_service.resolve_round!
      fight_service.generate_narrative

      fight.reload
      break if fight.status == 'complete'

      if fight_service.should_end?
        fight_service.end_fight!
        break
      end

      fight_service.next_round!
    end

    rounds
  end
end
