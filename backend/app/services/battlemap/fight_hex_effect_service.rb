# frozen_string_literal: true

module Battlemap
  class FightHexEffectService
    attr_reader :fight, :events

    def initialize(fight)
      @fight = fight
      @events = []
    end

    # Called per hex during movement or forced movement
    # Options: prone: true (for push-while-prone triggers)
    def on_hex_enter(participant, hex_x, hex_y, opts = {})
      fight_hexes = FightHex.at(fight.id, hex_x, hex_y)
      room_hex = RoomHex.where(room_id: fight.room_id, hex_x: hex_x, hex_y: hex_y).first

      # Check FightHex overlays (oil, fire, sharp_ground, puddle, long_fall, open_window)
      fight_hexes.each do |fh|
        process_fight_hex_entry(participant, fh, opts)
      end

      # Check BattleMapElement objects at this hex (mushrooms, lotus - persistent elements)
      BattleMapElement.where(fight_id: fight.id, hex_x: hex_x, hex_y: hex_y, state: 'intact').each do |el|
        process_element_entry(participant, el)
      end

      # Check RoomHex water terrain (persistent puddle/wading/etc.)
      if room_hex&.hex_type == 'water'
        process_water_entry(participant, hex_x, hex_y, opts)
      end
    end

    # Called at segment 100 for participants on hazardous hexes
    def end_of_round
      fight.active_participants.each do |participant|
        next if participant.hex_x.nil? || participant.hex_y.nil?

        fight_hexes = FightHex.at(fight.id, participant.hex_x, participant.hex_y)
        fight_hexes.each do |fh|
          process_end_of_round_hex(participant, fh)
        end

        # Check persistent elements (mushrooms, lotus reapplication)
        BattleMapElement.where(fight_id: fight.id, hex_x: participant.hex_x, hex_y: participant.hex_y, state: 'intact').each do |el|
          process_element_entry(participant, el)
        end
      end

      @events
    end

    # Called at segment ~20 to resolve break/detonate/ignite tactics
    def resolve_tactic(participant)
      case participant.tactic_choice
      when 'break'
        resolve_break(participant)
      when 'detonate'
        resolve_detonate(participant)
      when 'ignite'
        resolve_ignite(participant)
      end

      @events
    end

    private

    def process_fight_hex_entry(participant, fight_hex, opts)
      case fight_hex.hex_type
      when 'fire'
        process_fire_entry(participant)
      when 'puddle'
        process_water_entry(participant, fight_hex.hex_x, fight_hex.hex_y, opts)
      when 'long_fall'
        apply_dangling(participant, fight_hex.hex_x, fight_hex.hex_y)
      when 'oil'
        process_oil_entry(participant, opts)
      when 'sharp_ground'
        process_sharp_ground_entry(participant, opts)
      end
    end

    # Handle stepping onto a BattleMapElement (mushrooms, lotus)
    def process_element_entry(participant, element)
      case element.element_type
      when 'toxic_mushrooms'
        apply_poisoned(participant)
      when 'lotus_pollen'
        apply_intoxicated(participant)
      end
    end

    def process_fire_entry(participant)
      # Fire clears wet
      if StatusEffectService.has_effect?(participant, 'wet')
        StatusEffectService.remove_effect(participant, 'wet')
        @events << { type: 'wet_cleared', participant: participant,
                     message: "The flames dry #{participant.character_name}." }
      end

      if StatusEffectService.has_effect?(participant, 'oil_slicked')
        StatusEffectService.remove_effect(participant, 'oil_slicked')
        apply_on_fire(participant)
        @events << { type: 'oil_ignition', participant: participant, message: "#{participant.character_name}'s oil ignites!" }
      end
    end

    def process_water_entry(participant, hex_x, hex_y, opts)
      if StatusEffectService.has_effect?(participant, 'on_fire')
        StatusEffectService.extinguish(participant)
        apply_wet(participant)
        @events << { type: 'auto_extinguish', participant: participant, hex_x: hex_x, hex_y: hex_y,
                     message: "#{participant.character_name} rolls through the water, extinguishing the flames!" }
        return :stop_movement
      end

      if StatusEffectService.has_effect?(participant, 'oil_slicked')
        StatusEffectService.remove_effect(participant, 'oil_slicked')
        @events << { type: 'oil_washed', participant: participant,
                     message: "#{participant.character_name} washes off the oil." }
      end

      if opts[:prone]
        apply_wet(participant)
        @events << { type: 'prone_in_water', participant: participant,
                     message: "#{participant.character_name} is soaked!" }
      end
    end

    def process_oil_entry(participant, opts)
      if opts[:prone]
        apply_oil_slicked(participant)
        @events << { type: 'prone_in_oil', participant: participant,
                     message: "#{participant.character_name} is coated in oil!" }
      end
    end

    def process_sharp_ground_entry(participant, opts)
      if opts[:prone]
        # 15 raw bonus damage through threshold system
        @events << { type: 'sharp_ground_damage', participant: participant,
                     damage: 15, message: "#{participant.character_name} is cut by sharp debris!" }
      end
    end

    def process_end_of_round_hex(participant, fight_hex)
      case fight_hex.hex_type
      when 'fire'
        # Fire hex end-of-round: if oil_slicked, ignite; otherwise apply on_fire status
        process_fire_entry(participant)
        unless StatusEffectService.has_effect?(participant, 'on_fire')
          apply_on_fire(participant)
        end
      end
      # Note: mushroom/lotus end-of-round handled via BattleMapElement check in end_of_round
    end

    # --- Break/Detonate/Ignite Resolution ---

    def resolve_break(participant)
      element_id = participant.tactic_target_element_id
      target_hex = participant.tactic_target_hex

      if element_id
        element = BattleMapElement.where(id: element_id, fight_id: fight.id).first
        return unless element&.intact?
        return unless within_range?(participant, element.hex_x, element.hex_y, 1)

        case element.element_type
        when 'water_barrel'
          break_water_barrel(element, participant)
        when 'oil_barrel'
          break_oil_barrel(element, participant)
        when 'vase'
          break_vase(element, participant)
        end
      elsif target_hex
        # Breaking a window (RoomHex target)
        break_window(target_hex[0], target_hex[1], participant)
      end
    end

    def resolve_detonate(participant)
      element_id = participant.tactic_target_element_id
      return unless element_id

      element = BattleMapElement.where(id: element_id, fight_id: fight.id).first
      return unless element&.detonatable?
      return unless within_range?(participant, element.hex_x, element.hex_y, 1)

      detonate_munitions(element, participant)
    end

    def resolve_ignite(participant)
      target_hex = participant.tactic_target_hex
      return unless target_hex
      return unless within_range?(participant, target_hex[0], target_hex[1], 1)

      ignite_oil_at(target_hex[0], target_hex[1], participant)
    end

    # --- Element Break Effects ---

    def break_water_barrel(element, actor)
      element.break!
      spread_to_hex_and_neighbors(element.hex_x, element.hex_y, 'puddle')
      @events << { type: 'element_break', element_type: 'water_barrel', actor: actor,
                   hex_x: element.hex_x, hex_y: element.hex_y,
                   message: "#{actor.character_name} smashes the water barrel!" }
    end

    def break_oil_barrel(element, actor)
      element.break!
      spread_to_hex_and_neighbors(element.hex_x, element.hex_y, 'oil')
      @events << { type: 'element_break', element_type: 'oil_barrel', actor: actor,
                   hex_x: element.hex_x, hex_y: element.hex_y,
                   message: "#{actor.character_name} smashes the oil barrel!" }
    end

    def break_vase(element, actor)
      element.break!
      spread_to_hex_and_neighbors(element.hex_x, element.hex_y, 'sharp_ground')
      @events << { type: 'element_break', element_type: 'vase', actor: actor,
                   hex_x: element.hex_x, hex_y: element.hex_y,
                   message: "#{actor.character_name} shatters the vase!" }
    end

    def break_window(hex_x, hex_y, actor)
      room_hex = RoomHex.where(room_id: fight.room_id, hex_x: hex_x, hex_y: hex_y).first
      return unless room_hex&.hex_type == 'window'

      # Make window traversable for fight duration
      FightHex.create(fight_id: fight.id, hex_x: hex_x, hex_y: hex_y, hex_type: 'open_window')

      # Spread sharp ground to adjacent traversable hexes
      neighbors = HexGrid.hex_neighbors(hex_x, hex_y)
      neighbors.each do |nx, ny|
        neighbor_room_hex = RoomHex.where(room_id: fight.room_id, hex_x: nx, hex_y: ny).first
        if neighbor_room_hex&.traversable
          FightHex.create(fight_id: fight.id, hex_x: nx, hex_y: ny, hex_type: 'sharp_ground')
        else
          # BFS to find closest traversable hex within 3
          closest = find_closest_traversable(nx, ny, 3)
          if closest
            FightHex.create(fight_id: fight.id, hex_x: closest[0], hex_y: closest[1], hex_type: 'sharp_ground')
          end
        end
      end

      @events << { type: 'window_break', actor: actor, hex_x: hex_x, hex_y: hex_y,
                   message: "#{actor.character_name} smashes the window!" }
    end

    # --- Munitions Detonation ---

    def detonate_munitions(element, actor)
      element.detonate!
      center_x, center_y = element.hex_x, element.hex_y

      # Ring 0 + Ring 1: 30 raw damage
      ring_0_1 = [[center_x, center_y]] + HexGrid.hex_neighbors(center_x, center_y).to_a
      # Ring 2: 15 raw damage
      ring_2 = hexes_at_distance(center_x, center_y, 2)
      # Ring 3: 5 raw damage
      ring_3 = hexes_at_distance(center_x, center_y, 3)

      apply_explosion_damage(ring_0_1, 30, actor)
      apply_explosion_damage(ring_2, 15, actor)
      apply_explosion_damage(ring_3, 5, actor)

      # Chain reactions: break/detonate other elements in blast radius
      all_blast_hexes = ring_0_1 + ring_2 + ring_3
      trigger_chain_reactions(all_blast_hexes, actor)

      @events << { type: 'element_detonate', actor: actor, hex_x: center_x, hex_y: center_y,
                   message: "#{actor.character_name} detonates the munitions crate! BOOM!" }
    end

    def apply_explosion_damage(hex_list, raw_damage, actor)
      hex_list.each do |hx, hy|
        fight.active_participants.each do |p|
          next unless p.hex_x == hx && p.hex_y == hy

          @events << { type: 'explosion_damage', participant: p, damage: raw_damage,
                       actor: actor, message: "#{p.character_name} is caught in the explosion!" }
        end
      end
    end

    def trigger_chain_reactions(blast_hexes, actor)
      blast_set = blast_hexes.map { |hx, hy| "#{hx},#{hy}" }.to_set

      BattleMapElement.where(fight_id: fight.id).each do |el|
        next unless el.intact?
        next unless el.hex_x && el.hex_y
        next unless blast_set.include?("#{el.hex_x},#{el.hex_y}")

        case el.element_type
        when 'munitions_crate'
          detonate_munitions(el, actor)
        when 'water_barrel'
          break_water_barrel(el, actor)
        when 'oil_barrel'
          break_oil_barrel(el, actor)
        when 'vase'
          break_vase(el, actor)
        end
      end
    end

    # --- Ignite Oil ---

    def ignite_oil_at(hex_x, hex_y, actor)
      # Convert the targeted oil FightHex to fire (ignite tactic targets one hex within 1 of actor)
      oil_hex = FightHex.where(fight_id: fight.id, hex_x: hex_x, hex_y: hex_y, hex_type: 'oil').first
      return unless oil_hex

      oil_hex.update(hex_type: 'fire', hazard_type: 'fire')

      @events << { type: 'oil_ignite', actor: actor, hex_x: hex_x, hex_y: hex_y,
                   message: "#{actor.character_name} sets the oil ablaze!" }
    end

    # --- Status Effect Application ---

    def apply_poisoned(participant)
      return if StatusEffectService.has_effect?(participant, 'poisoned')

      duration = 2
      duration += 2 if StatusEffectService.has_effect?(participant, 'wet')

      StatusEffectService.apply_by_name(
        participant: participant, effect_name: 'poisoned',
        duration_rounds: duration
      )
      @events << { type: 'status_applied', effect: 'poisoned', participant: participant,
                   message: "#{participant.character_name} is poisoned by toxic spores!" }
    end

    def apply_intoxicated(participant)
      return if StatusEffectService.has_effect?(participant, 'intoxicated')

      duration = 2
      duration += 2 if StatusEffectService.has_effect?(participant, 'wet')

      StatusEffectService.apply_by_name(
        participant: participant, effect_name: 'intoxicated',
        duration_rounds: duration
      )
      @events << { type: 'status_applied', effect: 'intoxicated', participant: participant,
                   message: "#{participant.character_name} breathes in lotus pollen and becomes intoxicated!" }
    end

    def apply_wet(participant)
      StatusEffectService.apply_by_name(
        participant: participant, effect_name: 'wet',
        duration_rounds: 5
      )
    end

    def apply_oil_slicked(participant)
      StatusEffectService.apply_by_name(
        participant: participant, effect_name: 'oil_slicked',
        duration_rounds: 99
      )
    end

    def apply_on_fire(participant)
      StatusEffectService.apply_by_name(
        participant: participant, effect_name: 'on_fire',
        duration_rounds: 99
      )
      @events << { type: 'status_applied', effect: 'on_fire', participant: participant,
                   message: "#{participant.character_name} is on fire!" }
    end

    def apply_dangling(participant, hex_x, hex_y)
      StatusEffectService.apply_by_name(
        participant: participant, effect_name: 'dangling',
        duration_rounds: 1
      )

      # Store climb-back position in tactic_target_data JSONB (reusing existing column)
      climb_back_hex = find_random_traversable_near(hex_x, hex_y, 3, 5)
      if climb_back_hex
        participant.update(
          tactic_target_data: Sequel.pg_jsonb_wrap({
            climb_back_x: climb_back_hex[0],
            climb_back_y: climb_back_hex[1]
          })
        )
      end

      @events << { type: 'dangling', participant: participant, hex_x: hex_x, hex_y: hex_y,
                   message: "#{participant.character_name} goes over the edge and is left dangling!" }
    end

    # --- Utility Methods ---

    def spread_to_hex_and_neighbors(center_x, center_y, hex_type)
      hexes = [[center_x, center_y]] + HexGrid.hex_neighbors(center_x, center_y).to_a
      hexes.each do |hx, hy|
        room_hex = RoomHex.where(room_id: fight.room_id, hex_x: hx, hex_y: hy).first
        next unless room_hex&.traversable

        FightHex.create(fight_id: fight.id, hex_x: hx, hex_y: hy, hex_type: hex_type)
      end
    end

    def within_range?(participant, target_x, target_y, max_distance)
      HexGrid.hex_distance(participant.hex_x, participant.hex_y, target_x, target_y) <= max_distance
    end

    def hexes_at_distance(center_x, center_y, distance)
      all_nearby = []
      (-distance..distance).each do |dx|
        (-distance..distance).each do |dy|
          hx = center_x + dx
          hy = center_y + dy
          # Note: HexGrid exposes `valid_hex_coords?`, not `valid_hex?` — the
          # latter would raise NoMethodError and silently kill the round via
          # process_segments' rescue block, causing detonate chain reactions
          # to no-op.
          next unless HexGrid.valid_hex_coords?(hx, hy)
          next unless HexGrid.hex_distance(center_x, center_y, hx, hy) == distance

          all_nearby << [hx, hy]
        end
      end
      all_nearby
    end

    def find_closest_traversable(from_x, from_y, max_radius)
      (1..max_radius).each do |r|
        candidates = hexes_at_distance(from_x, from_y, r)
        traversable = candidates.select do |hx, hy|
          room_hex = RoomHex.where(room_id: fight.room_id, hex_x: hx, hex_y: hy).first
          room_hex&.traversable
        end
        return traversable.sample if traversable.any?
      end
      nil
    end

    def find_random_traversable_near(center_x, center_y, initial_radius, expanded_radius)
      [initial_radius, expanded_radius].each do |radius|
        candidates = []
        (1..radius).each do |r|
          hexes_at_distance(center_x, center_y, r).each do |hx, hy|
            room_hex = RoomHex.where(room_id: fight.room_id, hex_x: hx, hex_y: hy).first
            next unless room_hex&.traversable
            next if FightHex.has_type_at?(fight.id, hx, hy, 'long_fall')

            candidates << [hx, hy]
          end
        end
        return candidates.sample if candidates.any?
      end
      nil
    end
  end
end
