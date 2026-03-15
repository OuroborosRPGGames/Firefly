# frozen_string_literal: true

require 'spec_helper'

RSpec.describe BattleMapCombatService do
  let(:room) { create(:room, min_x: 0, max_x: 100, min_y: 0, max_y: 100) }

  let(:fight) do
    double('Fight',
           id: 1,
           room: room,
           uses_battle_map: true,
           round_number: 1,
           active_participants: [],
           triggered_hazards: nil,
           uses_new_hex_system?: true)
  end

  let(:service) { described_class.new(fight) }

  # Create double participants
  let(:attacker) do
    double('FightParticipant',
           id: 1,
           hex_x: 3,
           hex_y: 4,
           hex_z: 0,
           is_prone: false,
           is_swimming: false,
           moved_this_round: false,
           acted_this_round: false,
           update: true,
           take_damage: 1)
  end

  let(:defender) do
    double('FightParticipant',
           id: 2,
           hex_x: 7,
           hex_y: 8,
           hex_z: 0,
           is_prone: false,
           is_swimming: false,
           moved_this_round: false,
           acted_this_round: false,
           update: true,
           take_damage: 1)
  end

  # Helper to inject hexes into the service's in-memory cache, bypassing DB/Redis.
  def stub_hex_cache(svc, hex_map)
    cache = {}
    hex_map.each { |(x, y), hex| cache[[x, y]] = hex }
    svc.instance_variable_set(:@hex_cache, cache)
  end

  before do
    allow(room).to receive(:has_battle_map).and_return(true)
    allow(room).to receive(:room_hexes_dataset).and_return(double(first: nil, all: [], delete: true))
    allow(room).to receive(:hex_details).and_return(nil)
    allow(room).to receive(:explosive_hexes).and_return([])
    # Prevent Redis calls during tests
    allow(service).to receive(:load_hex_cache_from_redis).and_return(nil)
    allow(service).to receive(:save_hex_cache_to_redis)
    allow(service).to receive(:invalidate_redis_hex_cache!)
  end

  describe '#battle_map_active?' do
    context 'when fight uses battle map and room has battle map' do
      it 'returns true' do
        expect(service.battle_map_active?).to be true
      end
    end

    context 'when fight does not use battle map' do
      before do
        allow(fight).to receive(:uses_battle_map).and_return(false)
      end

      it 'returns false' do
        expect(service.battle_map_active?).to be false
      end
    end

    context 'when room does not have battle map' do
      before do
        allow(room).to receive(:has_battle_map).and_return(false)
      end

      it 'returns false' do
        expect(service.battle_map_active?).to be false
      end
    end

    context 'when room is nil' do
      let(:nil_room_fight) { double('Fight', id: 1, room: nil, uses_battle_map: true) }
      let(:nil_room_service) { described_class.new(nil_room_fight) }

      it 'returns false' do
        expect(nil_room_service.battle_map_active?).to be_falsey
      end
    end
  end

  describe '#destroy_cover' do
    let(:destroyable_hex) do
      double('RoomHex', destroyable: true, destroy_cover!: true)
    end

    let(:non_destroyable_hex) do
      double('RoomHex', destroyable: false)
    end

    it 'returns true when hex is destroyable' do
      expect(service.destroy_cover(destroyable_hex)).to be true
    end

    it 'returns false when hex is not destroyable' do
      expect(service.destroy_cover(non_destroyable_hex)).to be false
    end

    it 'calls destroy_cover! on destroyable hex' do
      expect(destroyable_hex).to receive(:destroy_cover!)
      service.destroy_cover(destroyable_hex)
    end
  end

  describe '#damage_cover' do
    let(:hex_with_hp) do
      double('RoomHex', destroyable: true, hit_points: 10, update: true, destroy_cover!: true)
    end

    let(:hex_no_hp) do
      double('RoomHex', destroyable: true, hit_points: nil)
    end

    it 'returns false when not destroyable' do
      hex = double('RoomHex', destroyable: false, hit_points: 10)
      expect(service.damage_cover(hex, 5)).to be false
    end

    it 'returns false when hex has no HP' do
      expect(service.damage_cover(hex_no_hp, 5)).to be false
    end

    it 'reduces hex HP on partial damage' do
      expect(hex_with_hp).to receive(:update).with(hit_points: 5)
      result = service.damage_cover(hex_with_hp, 5)
      expect(result).to be false
    end

    it 'destroys cover when damage exceeds HP' do
      expect(hex_with_hp).to receive(:destroy_cover!)
      result = service.damage_cover(hex_with_hp, 15)
      expect(result).to be true
    end
  end

  describe '#elevation_modifier' do
    let(:high_hex) { double('RoomHex', elevation_level: 2) }
    let(:low_hex) { double('RoomHex', elevation_level: 0) }

    context 'when battle map not active' do
      before do
        allow(service).to receive(:battle_map_active?).and_return(false)
      end

      it 'returns 0' do
        expect(service.elevation_modifier(attacker, defender)).to eq(0)
      end
    end

    context 'when participants have same elevation' do
      before do
        allow(attacker).to receive(:hex_z).and_return(1)
        allow(defender).to receive(:hex_z).and_return(1)
        allow(RoomHex).to receive(:elevation_modifier_for_combat).and_return(0)
      end

      it 'returns 0' do
        expect(service.elevation_modifier(attacker, defender)).to eq(0)
      end
    end

    context 'when attacker is higher' do
      before do
        allow(attacker).to receive(:hex_z).and_return(2)
        allow(defender).to receive(:hex_z).and_return(0)
        allow(RoomHex).to receive(:elevation_modifier_for_combat).with(2, 0).and_return(2)
      end

      it 'returns positive modifier' do
        expect(service.elevation_modifier(attacker, defender)).to eq(2)
      end
    end

    context 'when attacker is lower' do
      before do
        allow(attacker).to receive(:hex_z).and_return(0)
        allow(defender).to receive(:hex_z).and_return(2)
        allow(RoomHex).to receive(:elevation_modifier_for_combat).with(0, 2).and_return(-2)
      end

      it 'returns negative modifier' do
        expect(service.elevation_modifier(attacker, defender)).to eq(-2)
      end
    end

    context 'when hex_z is 0, uses hex elevation' do
      before do
        allow(attacker).to receive(:hex_z).and_return(0)
        allow(defender).to receive(:hex_z).and_return(0)
        allow(room).to receive(:hex_details).with(3, 4).and_return(high_hex)
        allow(room).to receive(:hex_details).with(7, 8).and_return(low_hex)
        allow(RoomHex).to receive(:elevation_modifier_for_combat).with(2, 0).and_return(2)
      end

      it 'uses hex elevation_level' do
        expect(service.elevation_modifier(attacker, defender)).to eq(2)
      end
    end
  end

  describe '#sync_participant_elevation' do
    let(:hex) { double('RoomHex', elevation_level: 3) }

    context 'when battle map not active' do
      before do
        allow(service).to receive(:battle_map_active?).and_return(false)
      end

      it 'does not update participant' do
        expect(attacker).not_to receive(:update)
        service.sync_participant_elevation(attacker)
      end
    end

    context 'when battle map is active' do
      before do
        allow(room).to receive(:hex_details).with(3, 4).and_return(hex)
      end

      it 'updates participant hex_z from hex elevation' do
        expect(attacker).to receive(:update).with(hex_z: 3)
        service.sync_participant_elevation(attacker)
      end
    end
  end

  describe '#has_line_of_sight?' do
    context 'when battle map not active' do
      before do
        allow(service).to receive(:battle_map_active?).and_return(false)
      end

      it 'returns true' do
        expect(service.has_line_of_sight?(attacker, defender)).to be true
      end
    end

    context 'with clear line of sight' do
      before do
        allow(HexGrid).to receive(:hex_distance).and_return(5)
        # Empty cache — no blocking hexes
      end

      it 'returns true' do
        expect(service.has_line_of_sight?(attacker, defender)).to be true
      end
    end

    context 'with blocking hex in path' do
      let(:blocking_hex) { double('RoomHex') }

      before do
        allow(HexGrid).to receive(:hex_distance).and_return(5)
        allow(blocking_hex).to receive(:blocks_los_at_elevation?).and_return(true)
        # Stub cached_hex to return blocking_hex for any intermediate coords
        allow(service).to receive(:cached_hex).and_return(blocking_hex)
      end

      it 'returns false' do
        expect(service.has_line_of_sight?(attacker, defender)).to be false
      end
    end
  end

  describe '#line_of_sight_penalty' do
    it 'returns 0 when line of sight exists' do
      allow(service).to receive(:has_line_of_sight?).and_return(true)
      expect(service.line_of_sight_penalty(attacker, defender)).to eq(0)
    end

    it 'returns -4 when line of sight is blocked' do
      allow(service).to receive(:has_line_of_sight?).and_return(false)
      expect(service.line_of_sight_penalty(attacker, defender)).to eq(-4)
    end
  end

  describe '#process_all_hazard_damage' do
    context 'when battle map not active' do
      before do
        allow(service).to receive(:battle_map_active?).and_return(false)
      end

      it 'returns empty array' do
        expect(service.process_all_hazard_damage).to eq([])
      end
    end

    context 'with active participants' do
      let(:hazard_event) { { participant: attacker, damage: 2 } }

      before do
        allow(fight).to receive(:active_participants).and_return([attacker, defender])
        allow(service).to receive(:process_hazard_damage).with(attacker).and_return(hazard_event)
        allow(service).to receive(:process_hazard_damage).with(defender).and_return(nil)
      end

      it 'collects hazard events from all participants' do
        events = service.process_all_hazard_damage
        expect(events.length).to eq(1)
        expect(events[0]).to eq(hazard_event)
      end
    end
  end

  describe '#process_hazard_damage' do
    let(:hazard_hex) do
      double('RoomHex',
             is_hazard?: true,
             hazard_damage_per_round: 5,
             hazard_save_difficulty: nil,
             hazard_damage_type: 'fire',
             hazard_type: 'fire',
             hex_x: 3,
             hex_y: 4)
    end

    context 'when battle map not active' do
      before do
        allow(service).to receive(:battle_map_active?).and_return(false)
      end

      it 'returns nil' do
        expect(service.process_hazard_damage(attacker)).to be_nil
      end
    end

    context 'when not standing on hazard' do
      it 'returns nil' do
        # Empty cache — no hex at attacker position
        expect(service.process_hazard_damage(attacker)).to be_nil
      end
    end

    context 'when standing on hazard with damage' do
      before do
        stub_hex_cache(service, { [3, 4] => hazard_hex })
        allow(attacker).to receive(:take_damage).with(5).and_return(2)
      end

      it 'returns damage event' do
        event = service.process_hazard_damage(attacker)
        expect(event[:participant]).to eq(attacker)
        expect(event[:damage]).to eq(2)
        expect(event[:damage_type]).to eq('fire')
        expect(event[:hazard_type]).to eq('fire')
        expect(event[:hex_x]).to eq(3)
        expect(event[:hex_y]).to eq(4)
      end
    end

    context 'when hazard has no damage' do
      let(:no_damage_hex) do
        double('RoomHex',
               is_hazard?: true,
               hazard_damage_per_round: 0)
      end

      before do
        stub_hex_cache(service, { [3, 4] => no_damage_hex })
      end

      it 'returns nil' do
        expect(service.process_hazard_damage(attacker)).to be_nil
      end
    end

    context 'with save difficulty (saves disabled)' do
      let(:save_hex) do
        double('RoomHex',
               is_hazard?: true,
               hazard_damage_per_round: 10,
               hazard_damage_type: 'poison',
               hazard_type: 'poison',
               hex_x: 3,
               hex_y: 4)
      end

      before do
        stub_hex_cache(service, { [3, 4] => save_hex })
        allow(attacker).to receive(:take_damage).with(10).and_return(2)
      end

      it 'always applies full damage (no save)' do
        event = service.process_hazard_damage(attacker)
        expect(event[:damage]).to eq(2)
      end
    end
  end

  describe '#trigger_hazard' do
    let(:hazard_hex) { double('RoomHex') }

    it 'calls trigger_potential_hazard! on hex' do
      expect(hazard_hex).to receive(:trigger_potential_hazard!).with('fire')
      service.trigger_hazard(hazard_hex, 'fire')
    end
  end

  describe '#trigger_explosion' do
    let(:explosive_hex) do
      double('RoomHex',
             trigger_explosion!: { center_x: 5, center_y: 5, radius: 2, damage: 10 })
    end

    context 'when battle map not active' do
      before do
        allow(service).to receive(:battle_map_active?).and_return(false)
      end

      it 'returns empty array' do
        expect(service.trigger_explosion(explosive_hex)).to eq([])
      end
    end

    context 'when hex does not explode' do
      let(:dud_hex) { double('RoomHex', trigger_explosion!: nil) }

      it 'returns empty array' do
        expect(service.trigger_explosion(dud_hex)).to eq([])
      end
    end

    context 'when explosion damages participants' do
      before do
        allow(HexGrid).to receive(:hex_distance).and_return(1)
        allow(fight).to receive(:active_participants).and_return([attacker])
        allow(fight).to receive(:respond_to?).with(:triggered_hazards).and_return(false)
      end

      it 'returns damage events' do
        events = service.trigger_explosion(explosive_hex)
        expect(events.length).to eq(1)
        expect(events[0][:damage_type]).to eq('explosion')
      end

      it 'reduces damage with distance' do
        # Distance 1 means damage = 10 - (1 * 2) = 8, which converts to HP lost
        events = service.trigger_explosion(explosive_hex)
        expect(events[0][:distance]).to eq(1)
      end
    end

    context 'with chain explosions' do
      let(:chain_hex) do
        double('RoomHex',
               hex_x: 6,
               hex_y: 6,
               should_explode?: true)
      end

      before do
        allow(HexGrid).to receive(:hex_distance).and_return(1)
        allow(fight).to receive(:active_participants).and_return([])
        allow(fight).to receive(:respond_to?).with(:triggered_hazards).and_return(false)
        # First call returns the chain hex, second call returns empty (preventing infinite loop)
        call_count = 0
        allow(room).to receive(:explosive_hexes) do
          call_count += 1
          call_count == 1 ? [chain_hex] : []
        end
        allow(chain_hex).to receive(:trigger_explosion!).with(fight).and_return(
          { center_x: 6, center_y: 6, radius: 1, damage: 5 }
        )
      end

      it 'triggers chain explosions within radius' do
        expect(chain_hex).to receive(:trigger_explosion!).with(fight)
        service.trigger_explosion(explosive_hex)
      end
    end
  end

  describe '#movement_cost' do
    let(:normal_hex) do
      double('RoomHex',
             traversable: true,
             calculated_movement_cost: 1.0,
             can_transition_to?: true,
             requires_swim_check?: false)
    end

    let(:difficult_hex) do
      double('RoomHex',
             traversable: true,
             calculated_movement_cost: 2.0,
             can_transition_to?: true,
             requires_swim_check?: false)
    end

    context 'when battle map not active' do
      before do
        allow(service).to receive(:battle_map_active?).and_return(false)
      end

      it 'returns Infinity' do
        expect(service.movement_cost(0, 0, 1, 1)).to eq(Float::INFINITY)
      end
    end

    context 'with normal terrain' do
      before do
        allow(room).to receive(:hex_details).and_return(normal_hex)
      end

      it 'returns base movement cost' do
        expect(service.movement_cost(0, 0, 1, 1)).to eq(1.0)
      end
    end

    context 'with difficult terrain' do
      before do
        allow(room).to receive(:hex_details).with(0, 0).and_return(normal_hex)
        allow(room).to receive(:hex_details).with(1, 1).and_return(difficult_hex)
      end

      it 'returns higher movement cost' do
        expect(service.movement_cost(0, 0, 1, 1)).to eq(2.0)
      end
    end

    context 'with impassable terrain' do
      let(:impassable_hex) do
        double('RoomHex', traversable: false)
      end

      before do
        allow(room).to receive(:hex_details).with(0, 0).and_return(normal_hex)
        allow(room).to receive(:hex_details).with(1, 1).and_return(impassable_hex)
      end

      it 'returns Infinity' do
        expect(service.movement_cost(0, 0, 1, 1)).to eq(Float::INFINITY)
      end
    end

    context 'with elevation transition not allowed' do
      let(:no_transition_hex) do
        double('RoomHex',
               traversable: true,
               calculated_movement_cost: 1.0,
               can_transition_to?: false)
      end

      before do
        allow(room).to receive(:hex_details).with(0, 0).and_return(normal_hex)
        allow(room).to receive(:hex_details).with(1, 1).and_return(no_transition_hex)
        allow(normal_hex).to receive(:can_transition_to?).with(no_transition_hex).and_return(false)
      end

      it 'returns Infinity' do
        expect(service.movement_cost(0, 0, 1, 1)).to eq(Float::INFINITY)
      end
    end

    context 'with deep water for non-swimmer' do
      let(:deep_water_hex) do
        double('RoomHex',
               traversable: true,
               calculated_movement_cost: 1.0,
               can_transition_to?: true,
               requires_swim_check?: true,
               water_type: 'deep')
      end

      before do
        allow(room).to receive(:hex_details).with(0, 0).and_return(normal_hex)
        allow(room).to receive(:hex_details).with(1, 1).and_return(deep_water_hex)
        allow(normal_hex).to receive(:can_transition_to?).with(deep_water_hex).and_return(true)
        allow(attacker).to receive(:is_swimming).and_return(false)
      end

      it 'returns Infinity' do
        expect(service.movement_cost(0, 0, 1, 1, attacker)).to eq(Float::INFINITY)
      end
    end
  end

  describe '#can_move_through?' do
    let(:normal_hex) do
      double('RoomHex',
             traversable: true,
             requires_swim_check?: false)
    end

    context 'when battle map not active' do
      before do
        allow(service).to receive(:battle_map_active?).and_return(false)
      end

      it 'returns true' do
        expect(service.can_move_through?(5, 5)).to be true
      end
    end

    context 'with traversable hex' do
      before do
        allow(room).to receive(:hex_details).and_return(normal_hex)
      end

      it 'returns true' do
        expect(service.can_move_through?(5, 5)).to be true
      end
    end

    context 'with non-traversable hex' do
      let(:wall_hex) { double('RoomHex', traversable: false) }

      before do
        allow(room).to receive(:hex_details).and_return(wall_hex)
      end

      it 'returns false' do
        expect(service.can_move_through?(5, 5)).to be false
      end
    end

    context 'with deep water and non-swimmer' do
      let(:deep_water) do
        double('RoomHex',
               traversable: true,
               requires_swim_check?: true,
               water_type: 'deep')
      end

      before do
        allow(room).to receive(:hex_details).and_return(deep_water)
        allow(attacker).to receive(:is_swimming).and_return(false)
      end

      it 'returns false' do
        expect(service.can_move_through?(5, 5, attacker)).to be false
      end
    end
  end

  describe '#update_swimming_state' do
    context 'when battle map not active' do
      before do
        allow(service).to receive(:battle_map_active?).and_return(false)
      end

      it 'does not update participant' do
        expect(attacker).not_to receive(:update)
        service.update_swimming_state(attacker)
      end
    end

    context 'when entering water hex' do
      let(:water_hex) do
        double('RoomHex', requires_swim_check?: true)
      end

      before do
        allow(room).to receive(:hex_details).and_return(water_hex)
        allow(attacker).to receive(:is_swimming).and_return(false)
      end

      it 'sets swimming to true' do
        expect(attacker).to receive(:update).with(is_swimming: true)
        service.update_swimming_state(attacker)
      end
    end

    context 'when leaving water hex' do
      let(:land_hex) do
        double('RoomHex', requires_swim_check?: false)
      end

      before do
        allow(room).to receive(:hex_details).and_return(land_hex)
        allow(attacker).to receive(:is_swimming).and_return(true)
      end

      it 'sets swimming to false' do
        expect(attacker).to receive(:update).with(is_swimming: false)
        service.update_swimming_state(attacker)
      end
    end
  end

  describe '#go_prone' do
    it 'sets participant as prone' do
      expect(attacker).to receive(:update).with(is_prone: true)
      service.go_prone(attacker)
    end
  end

  describe '#stand_up' do
    it 'clears prone status' do
      expect(attacker).to receive(:update).with(is_prone: false)
      service.stand_up(attacker)
    end
  end

  describe '#prone_modifier' do
    context 'when defender not prone' do
      it 'returns 0' do
        expect(service.prone_modifier(attacker, defender)).to eq(0)
      end
    end

    context 'when defender is prone' do
      before do
        allow(defender).to receive(:is_prone).and_return(true)
      end

      context 'melee range (distance <= 1)' do
        before do
          allow(HexGrid).to receive(:hex_distance).and_return(1)
        end

        it 'returns +2 bonus' do
          expect(service.prone_modifier(attacker, defender)).to eq(2)
        end
      end

      context 'ranged (distance > 1)' do
        before do
          allow(HexGrid).to receive(:hex_distance).and_return(5)
        end

        it 'returns -2 penalty' do
          expect(service.prone_modifier(attacker, defender)).to eq(-2)
        end
      end
    end
  end

  describe '#elevation_damage_bonus' do
    context 'when battle map not active' do
      before do
        allow(service).to receive(:battle_map_active?).and_return(false)
      end

      it 'returns 0' do
        expect(service.elevation_damage_bonus(attacker, defender)).to eq(0)
      end
    end

    context 'when attacker 2+ levels higher' do
      before do
        allow(service).to receive(:participant_elevation).with(attacker).and_return(4)
        allow(service).to receive(:participant_elevation).with(defender).and_return(1)
      end

      it 'returns +2 bonus' do
        expect(service.elevation_damage_bonus(attacker, defender)).to eq(2)
      end
    end

    context 'when elevation difference less than 2' do
      before do
        allow(service).to receive(:participant_elevation).with(attacker).and_return(2)
        allow(service).to receive(:participant_elevation).with(defender).and_return(1)
      end

      it 'returns 0' do
        expect(service.elevation_damage_bonus(attacker, defender)).to eq(0)
      end
    end
  end

  describe '#shot_passes_through_cover?' do
    context 'when battle map not active' do
      before do
        allow(service).to receive(:battle_map_active?).and_return(false)
      end

      it 'returns false' do
        expect(service.shot_passes_through_cover?(attacker, defender)).to be false
      end
    end

    context 'with no cover in path' do
      before do
        allow(HexGrid).to receive(:hex_distance).and_return(5)
        # Empty cache — no cover hexes
      end

      it 'returns false' do
        expect(service.shot_passes_through_cover?(attacker, defender)).to be false
      end
    end

    context 'with cover in path but adjacent to attacker' do
      it 'returns false (shooting FROM cover is allowed)' do
        # Use valid hex coords: attacker at (0,0), cover at (1,2) (NE neighbor), defender at (4,0)
        allow(attacker).to receive(:hex_x).and_return(0)
        allow(attacker).to receive(:hex_y).and_return(0)
        allow(defender).to receive(:hex_x).and_return(4)
        allow(defender).to receive(:hex_y).and_return(0)

        cover_hex = double('RoomHex', provides_cover?: true, hex_x: 1, hex_y: 2)
        stub_hex_cache(service, { [1, 2] => cover_hex })

        # Cover at (1,2) is adjacent to attacker at (0,0) — should not block
        expect(service.shot_passes_through_cover?(attacker, defender)).to be false
      end
    end
  end

  describe '#find_cover_hexes' do
    context 'when battle map not active' do
      before do
        allow(service).to receive(:battle_map_active?).and_return(false)
      end

      it 'returns empty array' do
        expect(service.find_cover_hexes(attacker, [defender])).to eq([])
      end
    end

    context 'when searching for cover' do
      let(:traversable_hex) do
        double('RoomHex', traversable: true, blocks_movement?: false)
      end

      let(:cover_hex) do
        double('RoomHex', provides_cover?: true)
      end

      before do
        allow(HexGrid).to receive(:hex_distance).and_return(2)
        # Stub cached_hex to return traversable hex for any coord lookup
        allow(service).to receive(:cached_hex).and_return(traversable_hex)
        allow(HexGrid).to receive(:hex_neighbor_by_direction).and_return([4, 5])
        allow(service).to receive(:find_adjacent_cover_directions).and_return(['NE'])
      end

      it 'returns hexes with cover directions' do
        hexes = service.find_cover_hexes(attacker, [defender], max_distance: 2)
        expect(hexes).to be_an(Array)
      end
    end
  end

  describe '#find_clear_los_hexes' do
    context 'when battle map not active' do
      before do
        allow(service).to receive(:battle_map_active?).and_return(false)
      end

      it 'returns empty array' do
        expect(service.find_clear_los_hexes(attacker, defender)).to eq([])
      end
    end

    context 'when searching for clear positions' do
      let(:traversable_hex) do
        double('RoomHex', traversable: true, blocks_movement?: false)
      end

      before do
        allow(HexGrid).to receive(:hex_distance).and_return(2)
        allow(service).to receive(:cached_hex).and_return(traversable_hex)
        allow(service).to receive(:shot_passes_through_cover?).and_return(false)
      end

      it 'returns candidate positions' do
        hexes = service.find_clear_los_hexes(attacker, defender, max_distance: 2)
        expect(hexes).to be_an(Array)
      end
    end
  end

  describe '#score_ranged_position' do
    context 'when battle map not active' do
      before do
        allow(service).to receive(:battle_map_active?).and_return(false)
      end

      it 'returns -100' do
        expect(service.score_ranged_position(5, 5, attacker, defender, [])).to eq(-100)
      end
    end

    context 'when scoring position' do
      before do
        allow(HexGrid).to receive(:hex_distance).and_return(5)
        allow(service).to receive(:shot_passes_through_cover?).and_return(false)
        allow(service).to receive(:find_adjacent_cover_directions).and_return([])
      end

      it 'returns a numeric score' do
        score = service.score_ranged_position(5, 5, attacker, defender, [defender])
        expect(score).to be_a(Numeric)
      end

      it 'gives bonus for clear LoS' do
        allow(service).to receive(:shot_passes_through_cover?).and_return(false)
        score_clear = service.score_ranged_position(5, 5, attacker, defender, [])

        allow(service).to receive(:shot_passes_through_cover?).and_return(true)
        score_blocked = service.score_ranged_position(5, 5, attacker, defender, [])

        expect(score_clear).to be > score_blocked
      end

      it 'gives bonus for having cover' do
        allow(service).to receive(:find_adjacent_cover_directions).and_return([])
        score_no_cover = service.score_ranged_position(5, 5, attacker, defender, [defender])

        allow(service).to receive(:find_adjacent_cover_directions).and_return(['NE'])
        score_with_cover = service.score_ranged_position(5, 5, attacker, defender, [defender])

        expect(score_with_cover).to be > score_no_cover
      end
    end
  end

  describe 'private direction methods' do
    describe '#direction_from_coords' do
      it 'returns NE for positive dx and dy' do
        dir = service.send(:direction_from_coords, 0, 0, 1, 1)
        expect(dir).to eq('NE')
      end

      it 'returns NE for positive dx only (no pure E in hex grid)' do
        dir = service.send(:direction_from_coords, 0, 0, 1, 0)
        expect(dir).to eq('NE')
      end

      it 'returns NW for negative dx only (no pure W in hex grid)' do
        dir = service.send(:direction_from_coords, 0, 0, -1, 0)
        expect(dir).to eq('NW')
      end

      it 'returns SW for negative dx and dy' do
        dir = service.send(:direction_from_coords, 0, 0, -1, -1)
        expect(dir).to eq('SW')
      end
    end

    describe '#adjacent_direction?' do
      it 'returns true for NE and SE (adjacent in hex ring)' do
        result = service.send(:adjacent_direction?, 'NE', 'SE')
        expect(result).to be true
      end

      it 'returns true for N and NW (wrapping)' do
        result = service.send(:adjacent_direction?, 'N', 'NW')
        expect(result).to be true
      end

      it 'returns false for NE and SW (opposite)' do
        result = service.send(:adjacent_direction?, 'NE', 'SW')
        expect(result).to be false
      end

      it 'returns false for invalid directions' do
        result = service.send(:adjacent_direction?, 'NE', 'INVALID')
        expect(result).to be false
      end
    end

    describe '#hexes_in_line' do
      it 'returns empty for adjacent hexes' do
        allow(HexGrid).to receive(:hex_distance).and_return(1)
        hexes = service.send(:hexes_in_line, 0, 0, 1, 0)
        expect(hexes).to eq([])
      end

      it 'returns intermediate hexes for longer distances' do
        allow(HexGrid).to receive(:hex_distance).and_return(5)
        allow(HexGrid).to receive(:to_hex_coords).and_return([2, 2])
        hexes = service.send(:hexes_in_line, 0, 0, 4, 4)
        expect(hexes).to be_an(Array)
      end
    end
  end

  # ============================================
  # Additional Edge Case Tests
  # ============================================

  describe '#track_explosion' do
    context 'when fight does not respond to triggered_hazards' do
      before do
        allow(fight).to receive(:respond_to?).with(:triggered_hazards).and_return(false)
      end

      it 'does not update fight' do
        expect(fight).not_to receive(:update)
        service.send(:track_explosion, { center_x: 5, center_y: 5, radius: 2 })
      end
    end

    context 'when fight has empty triggered_hazards' do
      before do
        allow(fight).to receive(:respond_to?).with(:triggered_hazards).and_return(true)
        allow(fight).to receive(:triggered_hazards).and_return(nil)
        allow(fight).to receive(:update)
      end

      it 'creates new hazards array with explosion' do
        expect(fight).to receive(:update) do |args|
          hazards = args[:triggered_hazards]
          expect(hazards).to be_truthy
        end
        service.send(:track_explosion, { center_x: 5, center_y: 5, radius: 2 })
      end
    end

    context 'when fight has existing triggered_hazards' do
      let(:existing_hazards) { [{ type: 'fire', x: 1, y: 1 }] }

      before do
        allow(fight).to receive(:respond_to?).with(:triggered_hazards).and_return(true)
        allow(fight).to receive(:triggered_hazards).and_return(existing_hazards)
        allow(fight).to receive(:update)
      end

      it 'appends explosion to existing hazards' do
        expect(fight).to receive(:update) do |args|
          hazards = args[:triggered_hazards]
          expect(hazards).to be_truthy
        end
        service.send(:track_explosion, { center_x: 5, center_y: 5, radius: 2 })
      end
    end
  end

  describe '#participant_elevation' do
    context 'when participant has explicit hex_z' do
      before do
        allow(attacker).to receive(:hex_z).and_return(3)
      end

      it 'returns hex_z' do
        expect(service.participant_elevation(attacker)).to eq(3)
      end
    end

    context 'when participant hex_z is 0' do
      let(:elevated_hex) { double('RoomHex', elevation_level: 5) }

      before do
        allow(attacker).to receive(:hex_z).and_return(0)
        allow(room).to receive(:hex_details).and_return(elevated_hex)
      end

      it 'returns hex elevation_level' do
        expect(service.participant_elevation(attacker)).to eq(5)
      end
    end

    context 'when hex is nil' do
      before do
        allow(attacker).to receive(:hex_z).and_return(0)
        allow(room).to receive(:hex_details).and_return(nil)
      end

      it 'returns 0' do
        expect(service.participant_elevation(attacker)).to eq(0)
      end
    end
  end

  describe '#find_adjacent_cover_directions (edge cases)' do
    context 'when battle map not active' do
      before do
        allow(service).to receive(:battle_map_active?).and_return(false)
      end

      it 'returns empty array' do
        expect(service.find_adjacent_cover_directions(5, 5, [defender])).to eq([])
      end
    end

    context 'when no adjacent hexes have cover' do
      before do
        allow(HexGrid).to receive(:hex_neighbor_by_direction).and_return([4, 5])
        # Empty cache — no cover hexes
      end

      it 'returns empty array' do
        expect(service.find_adjacent_cover_directions(5, 5, [defender])).to eq([])
      end
    end

    context 'when cover does not block any enemy' do
      let(:cover_hex) { double('RoomHex', provides_cover?: true) }

      before do
        allow(HexGrid).to receive(:hex_neighbor_by_direction).and_return([4, 5])
        stub_hex_cache(service, { [4, 5] => cover_hex })
        allow(CanvasHelper).to receive(:opposite_direction).and_return('sw')
        # Enemy is far away in opposite direction
        allow(defender).to receive(:hex_x).and_return(100)
        allow(defender).to receive(:hex_y).and_return(100)
      end

      it 'may return empty if cover direction doesnt help' do
        result = service.find_adjacent_cover_directions(5, 5, [defender])
        expect(result).to be_an(Array)
      end
    end
  end

  describe '#process_hazard_damage (edge cases)' do
    let(:hazard_hex_no_save) do
      double('RoomHex',
             is_hazard?: true,
             hazard_damage_per_round: 10,
             hazard_damage_type: 'fire',
             hazard_type: 'fire',
             hex_x: 3,
             hex_y: 4)
    end

    context 'when hazard always applies full damage (saves disabled)' do
      before do
        stub_hex_cache(service, { [3, 4] => hazard_hex_no_save })
        allow(attacker).to receive(:take_damage).with(10).and_return(2)
      end

      it 'applies full damage without save' do
        expect(attacker).to receive(:take_damage).with(10)
        service.process_hazard_damage(attacker)
      end
    end

    context 'when hex is_hazard? returns false' do
      let(:not_hazard) { double('RoomHex', is_hazard?: false) }

      before do
        stub_hex_cache(service, { [3, 4] => not_hazard })
      end

      it 'returns nil' do
        expect(service.process_hazard_damage(attacker)).to be_nil
      end
    end
  end

  describe '#trigger_explosion (edge cases)' do
    context 'when participants outside explosion radius' do
      let(:explosive_hex) do
        double('RoomHex',
               trigger_explosion!: { center_x: 50, center_y: 50, radius: 2, damage: 10 })
      end

      before do
        allow(HexGrid).to receive(:hex_distance).and_return(10)  # Far from explosion
        allow(fight).to receive(:active_participants).and_return([attacker])
        allow(fight).to receive(:respond_to?).with(:triggered_hazards).and_return(false)
      end

      it 'does not damage participants outside radius' do
        events = service.trigger_explosion(explosive_hex)
        expect(events).to eq([])
      end
    end

    context 'when tracking explosion with round number' do
      let(:explosive_hex) do
        double('RoomHex',
               trigger_explosion!: { center_x: 5, center_y: 5, radius: 2, damage: 10 })
      end

      before do
        allow(HexGrid).to receive(:hex_distance).and_return(10)
        allow(fight).to receive(:active_participants).and_return([])
        allow(fight).to receive(:respond_to?).with(:triggered_hazards).and_return(true)
        allow(fight).to receive(:triggered_hazards).and_return([])
        allow(fight).to receive(:round_number).and_return(3)
        allow(fight).to receive(:update)
      end

      it 'records round number in tracked hazard' do
        expect(fight).to receive(:update) do |args|
          hazards = args[:triggered_hazards]
          expect(hazards).to be_truthy
        end
        service.trigger_explosion(explosive_hex)
      end
    end
  end

  describe '#movement_cost (edge cases)' do
    let(:shallow_water) do
      double('RoomHex',
             traversable: true,
             calculated_movement_cost: 1.5,
             can_transition_to?: true,
             requires_swim_check?: true,
             water_type: 'shallow')
    end

    context 'with shallow water for non-swimmer' do
      before do
        allow(room).to receive(:hex_details).and_return(shallow_water)
        allow(attacker).to receive(:is_swimming).and_return(false)
      end

      it 'allows movement through shallow water' do
        expect(service.movement_cost(0, 0, 1, 1, attacker)).to eq(1.5)
      end
    end

    context 'without participant' do
      let(:normal_hex) do
        double('RoomHex',
               traversable: true,
               calculated_movement_cost: 1.0,
               can_transition_to?: true,
               requires_swim_check?: false)
      end

      before do
        allow(room).to receive(:hex_details).and_return(normal_hex)
      end

      it 'returns movement cost without swimming check' do
        expect(service.movement_cost(0, 0, 1, 1)).to eq(1.0)
      end
    end
  end

  describe '#can_move_through? (edge cases)' do
    context 'with shallow water for non-swimmer' do
      let(:shallow_water) do
        double('RoomHex',
               traversable: true,
               requires_swim_check?: true,
               water_type: 'shallow')
      end

      before do
        allow(room).to receive(:hex_details).and_return(shallow_water)
        allow(attacker).to receive(:is_swimming).and_return(false)
      end

      it 'returns true (shallow water is passable)' do
        expect(service.can_move_through?(5, 5, attacker)).to be true
      end
    end

    context 'with deep water for swimmer' do
      let(:deep_water) do
        double('RoomHex',
               traversable: true,
               requires_swim_check?: true,
               water_type: 'deep')
      end

      before do
        allow(room).to receive(:hex_details).and_return(deep_water)
        allow(attacker).to receive(:is_swimming).and_return(true)
      end

      it 'returns true for swimmers' do
        expect(service.can_move_through?(5, 5, attacker)).to be true
      end
    end
  end

  describe '#update_swimming_state (edge cases)' do
    context 'when hex is nil' do
      before do
        allow(room).to receive(:hex_details).and_return(nil)
        allow(attacker).to receive(:is_swimming).and_return(false)
      end

      it 'does not crash and treats as non-water' do
        expect { service.update_swimming_state(attacker) }.not_to raise_error
      end
    end

    context 'when swimming state already matches' do
      let(:water_hex) { double('RoomHex', requires_swim_check?: true) }

      before do
        allow(room).to receive(:hex_details).and_return(water_hex)
        allow(attacker).to receive(:is_swimming).and_return(true)  # Already swimming
      end

      it 'does not update participant' do
        expect(attacker).not_to receive(:update)
        service.update_swimming_state(attacker)
      end
    end
  end

  describe '#direction_from (private)' do
    it 'returns N for positive dy and zero dx' do
      mock_from = double(hex_x: 5, hex_y: 5)
      mock_to = double(hex_x: 5, hex_y: 8)
      dir = service.send(:direction_from, mock_from, mock_to)
      expect(dir).to eq('N')
    end

    it 'returns S for negative dy and zero dx' do
      mock_from = double(hex_x: 5, hex_y: 8)
      mock_to = double(hex_x: 5, hex_y: 5)
      dir = service.send(:direction_from, mock_from, mock_to)
      expect(dir).to eq('S')
    end

    it 'returns SE for positive dx and negative dy' do
      mock_from = double(hex_x: 5, hex_y: 8)
      mock_to = double(hex_x: 8, hex_y: 5)
      dir = service.send(:direction_from, mock_from, mock_to)
      expect(dir).to eq('SE')
    end

    it 'returns NW for negative dx and positive dy' do
      mock_from = double(hex_x: 8, hex_y: 5)
      mock_to = double(hex_x: 5, hex_y: 8)
      dir = service.send(:direction_from, mock_from, mock_to)
      expect(dir).to eq('NW')
    end
  end

  describe '#opposite_direction (private)' do
    it 'returns uppercase opposite direction' do
      result = service.send(:opposite_direction, 'NE')
      expect(result).to eq('SOUTHWEST')
    end

    it 'handles lowercase input' do
      result = service.send(:opposite_direction, 'ne')
      expect(result).to eq('SOUTHWEST')
    end

    it 'returns uppercase original when direction is unknown' do
      result = service.send(:opposite_direction, 'INVALID')
      expect(result).to eq('INVALID')
    end
  end

  describe '#has_line_of_sight? (pixel path)' do
    let(:wall_mask) { instance_double(WallMaskService) }

    before do
      allow(WallMaskService).to receive(:for_room).with(room).and_return(wall_mask)
      allow(wall_mask).to receive(:hex_to_pixel).with(attacker.hex_x, attacker.hex_y).and_return([30, 40])
      allow(wall_mask).to receive(:hex_to_pixel).with(defender.hex_x, defender.hex_y).and_return([70, 80])
      allow(room).to receive(:min_x).and_return(0)
      allow(room).to receive(:min_y).and_return(0)
      # Empty cache — no blocking hexes for fallback path
    end

    context 'when wall mask is present and ray is clear' do
      before do
        allow(wall_mask).to receive(:ray_los_clear?).and_return(true)
      end

      it 'returns true' do
        expect(service.has_line_of_sight?(attacker, defender)).to be true
      end
    end

    context 'when wall mask is present and ray hits a wall' do
      before do
        allow(wall_mask).to receive(:ray_los_clear?).and_return(false)
      end

      it 'returns false' do
        expect(service.has_line_of_sight?(attacker, defender)).to be false
      end
    end

    context 'when room has no wall mask' do
      before do
        allow(WallMaskService).to receive(:for_room).with(room).and_return(nil)
      end

      it 'falls back to hex-level LOS' do
        # Empty cache — no blocking hexes, should return true
        expect(service.has_line_of_sight?(attacker, defender)).to be true
      end
    end
  end
end
