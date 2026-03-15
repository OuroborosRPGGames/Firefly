# frozen_string_literal: true

# Handles combat between delve participants and monsters.
# Integrates with the existing FightService.
class DelveCombatService
  Result = Struct.new(:success, :message, :data, keyword_init: true)

  COMBAT_ROUND_TIME_SECONDS = 10

  class << self
    # Check for and initiate auto-combat when entering a room with monsters
    # @param delve [Delve] the delve
    # @param participant [DelveParticipant] the participant who moved
    # @param room [DelveRoom] the room entered
    # @return [Hash, nil] fight info if combat started, nil otherwise
    def check_auto_combat!(delve, participant, room, entry_direction: nil)
      monsters = delve.monsters_in_room(room)

      # Also check for static room monsters (rooms with monster_type set via content assignment)
      if monsters.empty? && room.has_monster?
        monster = spawn_static_room_monster!(delve, room)
        monsters = [monster] if monster
      end

      return nil if monsters.empty?

      # Get all active participants in this room
      participants_in_room = delve.delve_participants_dataset.where(
        current_delve_room_id: room.id,
        status: 'active'
      ).all

      # Create fight with all monsters, passing the delve room for real-room and cache support
      create_fight_with_multiple_monsters!(delve, monsters, participants_in_room, delve_room: room, entry_direction: entry_direction)
    end

    # Create a fight with multiple monsters
    # @param delve [Delve] the delve
    # @param monsters [Array<DelveMonster>] all monsters to add
    # @param participants [Array<DelveParticipant>] all participants
    # @param delve_room [DelveRoom, nil] optional delve room for real-room + cache support
    # @return [Hash] fight info
    def create_fight_with_multiple_monsters!(delve, monsters, participants, delve_room: nil, entry_direction: nil)
      # Prefer the delve room's real Room; fall back to the delve location's first room
      real_room = delve_room.respond_to?(:room) ? delve_room.room : nil
      room_id = real_room&.id || delve.location&.rooms_dataset&.first&.id
      return nil unless room_id

      # Always apply the correct battle map template for this delve room shape.
      # Pool rooms may carry stale maps from previous delves with different shapes.
      cache_applied = false
      if real_room
        shape_key = BattleMapTemplateService.delve_shape_key(delve_room)
        cache_applied = BattleMapTemplateService.apply_random!(
          category: 'delve', shape_key: shape_key, room: real_room
        )
      end

      # Create Fight record with has_monster flag
      fight = Fight.create(
        room_id: room_id,
        has_monster: true
      )

      # Calculate arena bounds for participant positioning
      arena_w = fight.respond_to?(:arena_width) ? (fight.arena_width || 10) : 10
      arena_h = fight.respond_to?(:arena_height) ? (fight.arena_height || 10) : 10
      hex_max_y = [(arena_h - 1) * 4 + 2, 2].max

      # Determine placement bias based on entry direction.
      # PCs should appear on the side they entered from; monsters on the opposite side.
      # In hex coords: north = high y, south = low y, east = high x, west = low x.
      pc_side, monster_side = placement_sides_for_entry(entry_direction)

      taken_hexes = []

      # Add all monsters as NPC participants (side 2)
      # Place monsters on the opposite side from where PCs entered
      # Cache the reality lookup once before the loop
      primary_reality = Reality.first(reality_type: 'primary')

      npc_participants = []
      monsters.each do |monster|
        hx, hy = pick_unoccupied_hex(arena_w, hex_max_y, taken_hexes, bias: monster_side, room: real_room)
        taken_hexes << [hx, hy]

        # Look up template character for this monster type to link the NPC archetype
        template_char = find_template_character(monster.monster_type)
        monster_ci = template_char ? create_monster_instance(template_char, room_id, primary_reality, monster) : nil

        participant_attrs = {
          fight_id: fight.id,
          is_npc: true,
          npc_name: monster.display_name,
          npc_damage_bonus: monster.damage_bonus || 0,
          hex_x: hx,
          hex_y: hy,
          side: 2
        }

        if monster_ci
          participant_attrs[:character_instance_id] = monster_ci.id
        else
          if template_char.nil?
            warn "[DelveCombatService] No template character found for monster type '#{monster.monster_type}', creating bare NPC"
          else
            warn "[DelveCombatService] Could not create CharacterInstance for '#{monster.display_name}', creating legacy bare NPC"
          end
          participant_attrs[:max_hp] = monster.max_hp
          participant_attrs[:current_hp] = monster.hp
        end

        npc_participant = FightParticipant.create(participant_attrs)

        npc_participants << npc_participant

        # Link monster to this fight for post-combat cleanup
        monster.update(fight_id: fight.id) if monster.respond_to?(:fight_id=)
      end

      # Add PC participants (side 1)
      # Place PCs on the side they entered from
      participants.each do |p|
        ci = p.character_instance
        FightService.ensure_character_health_defaults!(ci, max_hp: p.max_hp || 6, current_hp: p.current_hp || 6) if ci

        hx, hy = pick_unoccupied_hex(arena_w, hex_max_y, taken_hexes, bias: pc_side, room: real_room)
        taken_hexes << [hx, hy]

        FightParticipant.create(
          fight_id: fight.id,
          character_instance_id: ci.id,
          max_hp: p.max_hp || 6,
          current_hp: p.current_hp || 6,
          willpower_dice: p.willpower_dice || GameConfig::Mechanics::WILLPOWER[:initial_dice],
          hex_x: hx,
          hex_y: hy,
          side: 1
        )
      end

      # Apply NPC AI decisions AFTER all participants are added,
      # so NPCs can see PC enemies and choose targets/movement
      npc_participants.each do |npc_participant|
        CombatAIService.new(npc_participant).apply_decisions!
      end

      # Reset input deadline now that human participants exist (gives 8 minutes, not 30 seconds)
      if fight.respond_to?(:reset_input_deadline!)
        fight.reset_input_deadline!
        fight.save_changes
      end

      # Fall back to procedural generation if no template available
      if real_room && !cache_applied && !real_room.battle_map_ready?
        BattleMapGeneratorService.new(real_room).generate!
      end

      {
        fight_started: true,
        fight_id: fight.id,
        monster_names: monsters.map(&:display_name),
        monster_count: monsters.count
      }
    end

    # Create a fight between participants and a monster (single monster version)
    # @param delve [Delve] the delve
    # @param monster [DelveMonster] the monster
    # @param participants [Array<DelveParticipant>] the participants
    # @param delve_room [DelveRoom, nil] optional delve room for real-room + cache support
    # @return [Hash] fight info
    def create_fight!(delve, monster, participants, delve_room: nil)
      # Use create_fight_with_multiple_monsters! for consistency
      create_fight_with_multiple_monsters!(delve, [monster], participants, delve_room: delve_room)
    end

    # Process time for a combat round
    # @param delve [Delve] the delve
    # @param participants [Array<DelveParticipant>] the participants
    # @return [Array<Hash>] any timeout events
    def process_round_time!(delve, participants)
      time_cost = GameSetting.integer('delve_time_combat_round') || COMBAT_ROUND_TIME_SECONDS
      events = []

      participants.each do |p|
        loot_before = p.respond_to?(:loot_collected) ? (p.loot_collected || 0) : nil
        time_result = p.spend_time_seconds!(time_cost)

        if time_result == :time_expired || p.time_expired?
          loot_lost = if !loot_before.nil? && p.respond_to?(:loot_collected)
                        loot_after = p.loot_collected || 0
                        [loot_before - loot_after, 0].max
                      else
                        p.handle_timeout!
                      end
          events << {
            type: :timeout,
            participant: p,
            loot_lost: loot_lost
          }
        end
      end

      # Tick monster movement for combat time
      collisions = DelveMonsterService.tick_movement!(delve, time_cost)
      events.concat(collisions.map { |c| c.merge(type: :reinforcement) })

      events
    end

    # Add monster reinforcements to an existing fight
    # @param fight [Fight] the active fight
    # @param monsters [Array<DelveMonster>] monsters to add
    # @return [Array<String>] names of monsters added
    def add_monster_reinforcements!(fight, monsters)
      added_names = []

      fight_service = FightService.new(fight)
      primary_reality = Reality.first(reality_type: 'primary') || Reality.first

      monsters.each do |monster|
        # Don't add monsters that are already in the fight
        next if monster.fight_id == fight.id

        # Find an unoccupied hex for the reinforcement (near existing NPCs)
        npc_side = fight.fight_participants_dataset.where(side: 2).first
        desired_x = npc_side&.hex_x || (fight.arena_width || 10) / 2
        desired_y = npc_side&.hex_y || 0
        hex_x, hex_y = fight_service.find_unoccupied_hex(desired_x, desired_y)

        template_char = find_template_character(monster.monster_type)
        monster_ci = template_char ? create_monster_instance(template_char, fight.room_id, primary_reality, monster) : nil

        attrs = {
          fight_id: fight.id,
          is_npc: true,
          npc_name: monster.display_name,
          npc_damage_bonus: monster.damage_bonus || 0,
          side: 2,
          hex_x: hex_x,
          hex_y: hex_y
        }
        if monster_ci
          attrs[:character_instance_id] = monster_ci.id
        else
          if template_char.nil?
            warn "[DelveCombatService] No template character found for monster type '#{monster.monster_type}', creating bare NPC"
          else
            warn "[DelveCombatService] Could not create CharacterInstance for '#{monster.display_name}', creating legacy bare NPC"
          end
          attrs[:max_hp] = monster.max_hp
          attrs[:current_hp] = monster.hp
        end
        npc_participant = FightParticipant.create(attrs)

        # Auto-submit NPC action
        CombatAIService.new(npc_participant).apply_decisions!

        monster.update(fight_id: fight.id) if monster.respond_to?(:fight_id=)
        added_names << monster.display_name
      end

      added_names
    end

    # Handle fight end
    # @param fight [Fight] the completed fight
    # @param delve [Delve] the delve
    # @param participants [Array<DelveParticipant>] the participants
    # @return [Result]
    def handle_fight_end!(fight, delve, participants)
      # Determine outcome
      pc_won = fight_won_by_pcs?(fight)

      if pc_won
        # Deactivate all monsters linked to this fight and clear room flags
        monsters = find_monsters_for_fight(fight, delve)
        monsters.each do |monster|
          monster.deactivate!
          # Clear the room's monster flag so it no longer shows in the UI
          if monster.current_room_id
            dr = DelveRoom[monster.current_room_id]
            dr&.clear_monster! if dr&.has_monster?
          end
        end

        # Award bonus loot
        total_difficulty = monsters.sum { |m| m.difficulty_value || 10 }
        bonus = [total_difficulty / 2, 5].max
        participants.each { |p| p.add_loot!(bonus) }

        # Update participant kill counts
        participants.each(&:add_kill!)

        Result.new(
          success: true,
          message: victory_message(monsters, bonus),
          data: { victory: true, loot_bonus: bonus }
        )
      else
        # PCs defeated — lose loot and exit the delve
        loot_lost = 0
        participants.each do |p|
          loot_lost += p.handle_defeat!

          # Return character to safe non-temporary room
          next unless p.character_instance

          restore_room = safe_destination_for(p)
          p.character_instance.update(current_room_id: restore_room.id) if restore_room
        end

        # Release delve rooms only when no active delvers remain.
        should_release_rooms = if delve.respond_to?(:active_participants)
                                 delve.active_participants.empty?
                               else
                                 true
                               end

        if should_release_rooms
          TemporaryRoomPoolService.release_delve_rooms(delve)
          delve.fail! if delve.respond_to?(:fail!) && delve.respond_to?(:status) && delve.status != 'failed'
        end

        Result.new(
          success: true,
          message: defeat_message(loot_lost),
          data: { victory: false, loot_lost: loot_lost, defeated: true }
        )
      end
    end

    # Spawn a roving DelveMonster from a static room monster (monster_type set)
    # so it can participate in the fight system. Marks the room as cleared.
    # @param delve [Delve] the delve
    # @param room [DelveRoom] the room with a static monster
    # @return [DelveMonster, nil] the spawned monster
    def spawn_static_room_monster!(delve, room)
      return nil unless room.has_monster?

      difficulty = delve.monster_difficulty_for_level(room.level || 1)
      hp = 6 + (difficulty / 20)

      monster = DelveMonster.create(
        delve_id: delve.id,
        current_room_id: room.id,
        level: room.level || 1,
        monster_type: room.monster_type,
        difficulty_value: difficulty,
        hp: hp,
        max_hp: hp,
        damage_bonus: difficulty / 30
      )

      # Mark the static room monster as cleared (it's now a roving monster)
      room.clear_monster!

      monster.pick_direction!
      monster
    rescue StandardError => e
      warn "[DelveCombatService] Failed to spawn static monster: #{e.message}"
      nil
    end

    private

    # Find a safe non-temporary room to return to after leaving a delve.
    def safe_destination_for(participant)
      ci = participant.character_instance
      return nil unless ci

      if participant.pre_delve_room_id
        room = Room[participant.pre_delve_room_id]
        return room if room && !room.temporary?
      end

      ci.safe_fallback_room
    end

    # Find the template Character for a delve monster type.
    # Template characters have forename "Monster:<type>" (titlecased on save).
    # @param monster_type [String] the monster type (e.g. 'rat', 'goblin')
    # @return [Character, nil] the template character, or nil if not found
    def find_template_character(monster_type)
      Character.first(forename: "Monster:#{monster_type}")
    end

    # Create a CharacterInstance for a monster template so combat HP is stored
    # on CharacterInstance.health/max_health.
    # @param template_char [Character] the template character
    # @param room_id [Integer] the room to place the instance in
    # @param reality [Reality] the primary reality record
    # @param monster [DelveMonster] source monster stats (hp/max_hp/display_name)
    # @return [CharacterInstance, nil] the created instance, or nil on failure
    def create_monster_instance(template_char, room_id, reality, monster)
      return nil unless reality

      max_hp = [monster.max_hp.to_i, 1].max
      current_hp = [[monster.hp.to_i, 0].max, max_hp].min

      # CharacterInstance has a unique constraint on (character_id, reality_id),
      # so reuse existing instances from previous fights.
      existing = CharacterInstance.first(character_id: template_char.id, reality_id: reality.id)
      if existing
        attrs = {
          current_room_id: room_id,
          online: false,
          status: 'alive'
        }
        attrs[:health] = current_hp if existing.respond_to?(:health)
        attrs[:max_health] = max_hp if existing.respond_to?(:max_health)
        existing.update(attrs)
        return existing
      end

      CharacterInstance.create(
        character_id: template_char.id,
        reality_id: reality.id,
        current_room_id: room_id,
        health: current_hp,
        max_health: max_hp,
        mana: 50,
        max_mana: 50,
        online: false,
        status: 'alive'
      )
    rescue StandardError => e
      warn "[DelveCombatService] Failed to create monster instance: #{e.message}"
      nil
    end

    # Determine placement sides based on the direction the player traveled.
    # Returns [pc_side, monster_side] bias symbols for pick_unoccupied_hex.
    # PCs appear on the side they entered from; monsters on the opposite side.
    # @param entry_direction [String, nil] the direction traveled (e.g. "south" means came from north)
    # @return [Array(Symbol, Symbol)] [pc_bias, monster_bias]
    def placement_sides_for_entry(entry_direction)
      case entry_direction&.downcase
      when 'south' # Entered from north side
        [:north, :south]
      when 'north' # Entered from south side
        [:south, :north]
      when 'east'  # Entered from west side
        [:west, :east]
      when 'west'  # Entered from east side
        [:east, :west]
      else
        [:south, :north] # Default: PCs south, monsters north
      end
    end

    # Pick an unoccupied, playable hex for placing a fight participant.
    # Starts from a position ~25% inward from the biased edge (not right at
    # the wall) and spirals outward to find the nearest valid hex.
    # @param arena_w [Integer] arena width in hexes
    # @param hex_max_y [Integer] maximum hex y coordinate
    # @param taken [Array<Array(Integer,Integer)>] already-occupied positions
    # @param bias [Symbol] :north (high y), :south (low y), :east (high x), :west (low x)
    # @param room [Room, nil] room to check hex playability against
    # @return [Array(Integer,Integer)] [hex_x, hex_y]
    def pick_unoccupied_hex(arena_w, hex_max_y, taken, bias: :south, room: nil)
      hex_max_x = [arena_w - 1, 0].max
      mid_x = hex_max_x / 2
      mid_y = hex_max_y / 2

      # Start ~25% inward from the biased edge, centered on the other axis
      inset_x = [hex_max_x / 4, 2].min
      inset_y = [hex_max_y / 4, 4].min  # hex y steps by 2, so use larger inset

      target_x, target_y = case bias
                            when :north then [mid_x, hex_max_y - inset_y]
                            when :south then [mid_x, inset_y]
                            when :east  then [hex_max_x - inset_x, mid_y]
                            when :west  then [inset_x, mid_y]
                            else [mid_x, mid_y]
                            end

      # Snap to valid hex coordinates
      target_x, target_y = HexGrid.to_hex_coords(target_x, target_y)

      # Spiral outward from target to find a playable, unoccupied hex
      max_distance = [hex_max_x, hex_max_y / 2].max
      (0..max_distance).each do |dist|
        candidates = if dist == 0
                       [[target_x, target_y]]
                     else
                       spiral_ring(target_x, target_y, dist, hex_max_x, hex_max_y)
                     end

        # Shuffle candidates at same distance for variety
        candidates.shuffle.each do |hx, hy|
          next if taken.include?([hx, hy])
          next if room && !RoomHex.playable_at?(room, hx, hy)
          return [hx, hy]
        end
      end

      # Absolute fallback: center of arena (should never reach here)
      warn "[DelveCombatService] No playable hex found, using arena center"
      HexGrid.to_hex_coords(mid_x, mid_y)
    end

    # Get all valid hex coordinates at exactly the given distance within arena bounds.
    # @param cx [Integer] center hex x
    # @param cy [Integer] center hex y
    # @param distance [Integer] hex distance
    # @param max_x [Integer] max hex x in arena
    # @param max_y [Integer] max hex y in arena
    # @return [Array<Array(Integer,Integer)>]
    def spiral_ring(cx, cy, distance, max_x, max_y)
      result = []
      range = distance * 2 + 2
      (-range..range).each do |dx|
        (-range..range).each do |dy|
          hx, hy = HexGrid.to_hex_coords(cx + dx, cy + dy)
          next if hx < 0 || hy < 0 || hx > max_x || hy > max_y
          next unless HexGrid.hex_distance(cx, cy, hx, hy) == distance
          result << [hx, hy] unless result.include?([hx, hy])
        end
      end
      result
    end

    def fight_won_by_pcs?(fight)
      # Check if any PC participants are still alive
      fight.fight_participants
           .select { |fp| !fp.is_npc }
           .any? { |fp| fp.current_hp.positive? }
    end

    def find_monsters_for_fight(fight, delve)
      # Monsters are linked to fights via fight_id during creation
      DelveMonster.where(fight_id: fight.id, delve_id: delve.id).all
    end

    def victory_message(monsters, bonus)
      names = if monsters.is_a?(Array) && monsters.any?
                monsters.map(&:display_name).join(', ')
              else
                'The monster'
              end
      "#{names} slain! You claim #{bonus} gold."
    end

    def defeat_message(loot_lost)
      "You are defeated! As consciousness fades, you lose #{loot_lost} gold " \
      "and are dragged to safety by unseen forces."
    end
  end
end
