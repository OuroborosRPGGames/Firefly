# frozen_string_literal: true

require 'spec_helper'

RSpec.describe BattleMapViewService do
  let(:room) { create(:room, min_x: 0, max_x: 100, min_y: 0, max_y: 100) }
  let(:character) { create(:character, forename: 'Test', surname: 'Fighter') }
  let(:viewer_instance) { create(:character_instance, character: character, current_room: room, online: true) }

  let(:fight) do
    double('Fight',
           id: 1,
           room: room,
           round_number: 2,
           status: 'input',
           arena_width: 10,
           arena_height: 10,
           battle_map_generating: false,
           uses_battle_map: true,
           has_monster: false,
           lit_battle_map_url: nil,
           fight_participants: [],
           active_participants: [])
  end

  let(:service) { described_class.new(fight, viewer_instance) }

  describe 'constants' do
    it 'has MIN_HEX_WIDTH defined' do
      expect(described_class::MIN_HEX_WIDTH).to be_a(Numeric)
    end

    it 'has MAX_HEX_WIDTH defined' do
      expect(described_class::MAX_HEX_WIDTH).to be_a(Numeric)
    end

    it 'has CONTAINER_WIDTH defined' do
      expect(described_class::CONTAINER_WIDTH).to be_a(Numeric)
    end

    it 'has HAZARD_SYMBOLS with fire emoji' do
      expect(described_class::HAZARD_SYMBOLS['fire']).to eq("\u{1F525}")
    end

    it 'has HAZARD_SYMBOLS with electricity' do
      expect(described_class::HAZARD_SYMBOLS['electricity']).to eq("\u{26A1}")
    end

    it 'has HAZARD_SYMBOLS with poison' do
      expect(described_class::HAZARD_SYMBOLS['poison']).to eq("\u{2620}")
    end

    it 'has HAZARD_SYMBOLS with trap' do
      expect(described_class::HAZARD_SYMBOLS['trap']).to eq("\u{26A0}")
    end

    it 'has HAZARD_SYMBOLS with cold' do
      expect(described_class::HAZARD_SYMBOLS['cold']).to eq("\u{2744}")
    end
  end

  describe '#build_map_state' do
    before do
      allow(room).to receive(:battle_map_image_url).and_return('/images/battle_map.png')
      allow(room).to receive(:parsed_battle_map_config).and_return({})
      allow(room).to receive(:has_battle_map).and_return(true)
      allow(room).to receive(:is_clipped?).and_return(false)
      allow(room).to receive(:has_custom_polygon?).and_return(false)
    end

    it 'returns success true' do
      result = service.build_map_state
      expect(result[:success]).to be true
    end

    it 'includes fight_id' do
      result = service.build_map_state
      expect(result[:fight_id]).to eq(1)
    end

    it 'includes round_number' do
      result = service.build_map_state
      expect(result[:round_number]).to eq(2)
    end

    it 'includes status' do
      result = service.build_map_state
      expect(result[:status]).to eq('input')
    end

    it 'includes arena dimensions' do
      result = service.build_map_state
      expect(result[:arena_width]).to eq(10)
      expect(result[:arena_height]).to eq(10)
    end

    it 'includes hex_scale' do
      result = service.build_map_state
      expect(result[:hex_scale]).to be_a(Numeric)
    end

    it 'includes background_url' do
      result = service.build_map_state
      expect(result[:background_url]).to eq('/images/battle_map.png')
    end

    it 'includes background_contrast' do
      result = service.build_map_state
      expect(result[:background_contrast]).to eq('dark')
    end

    it 'includes hexes array' do
      result = service.build_map_state
      expect(result[:hexes]).to be_an(Array)
    end

    it 'includes participants array' do
      result = service.build_map_state
      expect(result[:participants]).to be_an(Array)
    end

    it 'includes monsters array' do
      result = service.build_map_state
      expect(result[:monsters]).to be_an(Array)
    end

    it 'includes pending_animation flag' do
      result = service.build_map_state
      expect(result[:pending_animation]).to be true
    end

    it 'includes animation_round' do
      result = service.build_map_state
      expect(result[:animation_round]).to eq(1)
    end

    it 'includes timestamp in ISO8601 format' do
      result = service.build_map_state
      expect(result[:timestamp]).to match(/\d{4}-\d{2}-\d{2}T/)
    end

    context 'when status is not input' do
      before do
        allow(fight).to receive(:status).and_return('resolving')
      end

      it 'sets pending_animation to false' do
        result = service.build_map_state
        expect(result[:pending_animation]).to be false
      end
    end

    context 'when round_number is 1' do
      before do
        allow(fight).to receive(:round_number).and_return(1)
      end

      it 'sets pending_animation to false' do
        result = service.build_map_state
        expect(result[:pending_animation]).to be false
      end
    end

    context 'when no background image' do
      before do
        allow(room).to receive(:battle_map_image_url).and_return(nil)
      end

      it 'sets background_contrast to dark' do
        result = service.build_map_state
        expect(result[:background_contrast]).to eq('dark')
      end
    end

    context 'with cached contrast' do
      before do
        allow(room).to receive(:parsed_battle_map_config).and_return({ 'background_contrast' => 'light' })
      end

      it 'uses cached contrast value' do
        result = service.build_map_state
        expect(result[:background_contrast]).to eq('light')
      end
    end
  end

  describe 'hex scale calculation' do
    before do
      allow(room).to receive(:battle_map_image_url).and_return(nil)
      allow(room).to receive(:parsed_battle_map_config).and_return({})
      allow(room).to receive(:is_clipped?).and_return(false)
      allow(room).to receive(:has_custom_polygon?).and_return(false)
    end

    context 'with small arena' do
      before do
        allow(fight).to receive(:arena_width).and_return(5)
        allow(fight).to receive(:arena_height).and_return(5)
      end

      it 'calculates hex_scale within bounds' do
        result = service.build_map_state
        expect(result[:hex_scale]).to be <= described_class::MAX_HEX_WIDTH
      end

      it 'sets viewport_centered to false' do
        result = service.build_map_state
        expect(result[:viewport_centered]).to be false
      end
    end

    context 'with large arena' do
      before do
        allow(fight).to receive(:arena_width).and_return(100)
        allow(fight).to receive(:arena_height).and_return(100)
      end

      it 'clamps hex_scale to minimum' do
        result = service.build_map_state
        expect(result[:hex_scale]).to be >= described_class::MIN_HEX_WIDTH
      end
    end
  end

  describe 'hex data building' do
    # Use valid hex offset coordinates: y=6 (y/2=3, odd) requires odd x, so x=5 is valid
    let(:room_hex) do
      double('RoomHex',
             hex_x: 5,
             hex_y: 6,
             hex_type: 'cover',
             cover_object: 'boulder',
             has_cover: true,
             elevation_level: 2,
             hazard_type: 'fire',
             water_type: nil,
             difficult_terrain: false,
             traversable: true,
             surface_type: 'stone',
             wall_feature: nil,
             type_description: 'Large boulder')
    end

    before do
      allow(room).to receive(:battle_map_image_url).and_return(nil)
      allow(room).to receive(:parsed_battle_map_config).and_return({})
      allow(room).to receive(:is_clipped?).and_return(false)
      allow(room).to receive(:has_custom_polygon?).and_return(false)
      allow(RoomHex).to receive(:where).and_return(double(all: [room_hex]))
    end

    it 'builds hex data for each valid hex position' do
      result = service.build_map_state
      # With one hex record at (5,6), grid extent is just that single position
      expect(result[:hexes].length).to eq(1)
    end

    it 'includes hex type for matching position' do
      result = service.build_map_state
      matching_hex = result[:hexes].find { |h| h[:x] == 5 && h[:y] == 6 }
      expect(matching_hex[:type]).to eq('cover')
    end

    it 'includes cover_object' do
      result = service.build_map_state
      matching_hex = result[:hexes].find { |h| h[:x] == 5 && h[:y] == 6 }
      expect(matching_hex[:cover_object]).to eq('boulder')
    end

    it 'includes has_cover' do
      result = service.build_map_state
      matching_hex = result[:hexes].find { |h| h[:x] == 5 && h[:y] == 6 }
      expect(matching_hex[:has_cover]).to eq(true)
    end

    it 'includes elevation' do
      result = service.build_map_state
      matching_hex = result[:hexes].find { |h| h[:x] == 5 && h[:y] == 6 }
      expect(matching_hex[:elevation]).to eq(2)
    end

    it 'includes hazard_type' do
      result = service.build_map_state
      matching_hex = result[:hexes].find { |h| h[:x] == 5 && h[:y] == 6 }
      expect(matching_hex[:hazard_type]).to eq('fire')
    end

    it 'includes hazard_symbol for fire' do
      result = service.build_map_state
      matching_hex = result[:hexes].find { |h| h[:x] == 5 && h[:y] == 6 }
      expect(matching_hex[:hazard_symbol]).to eq("\u{1F525}")
    end

    it 'includes traversable flag' do
      result = service.build_map_state
      matching_hex = result[:hexes].find { |h| h[:x] == 5 && h[:y] == 6 }
      expect(matching_hex[:traversable]).to be true
    end

    it 'includes surface_type' do
      result = service.build_map_state
      matching_hex = result[:hexes].find { |h| h[:x] == 5 && h[:y] == 6 }
      expect(matching_hex[:surface_type]).to eq('stone')
    end

    it 'includes description' do
      result = service.build_map_state
      matching_hex = result[:hexes].find { |h| h[:x] == 5 && h[:y] == 6 }
      expect(matching_hex[:description]).to eq('Large boulder')
    end

    context 'with zone boundary' do
      before do
        allow(room).to receive(:is_clipped?).and_return(true)
        allow(room).to receive(:has_custom_polygon?).and_return(false)
        allow(room).to receive(:position_valid?).and_return(false)
      end

      it 'renders outside hexes as off_map' do
        result = service.build_map_state
        boundary_hex = result[:hexes].find { |h| h[:type] == 'off_map' && h[:wall_type] == 'zone_boundary' }
        expect(boundary_hex).not_to be_nil
      end

      it 'marks zone boundary as non-traversable' do
        result = service.build_map_state
        boundary_hex = result[:hexes].find { |h| h[:wall_type] == 'zone_boundary' }
        expect(boundary_hex[:traversable]).to be false
      end
    end
  end

  describe 'participant data building' do
    let(:other_character) { create(:character, forename: 'Enemy', surname: 'Fighter') }
    let(:other_instance) { create(:character_instance, character: other_character, current_room: room) }

    let(:viewer_participant) do
      double('FightParticipant',
             id: 1,
             character_instance_id: viewer_instance.id,
             character_instance: viewer_instance,
             is_npc: false,
             hex_x: 3,
             hex_y: 4,
             is_knocked_out: false,
             current_hp: 5,
             max_hp: 6,
             wound_penalty: 1,
             is_mounted: false,
             available_main_abilities: [],
             available_tactical_abilities: [],
             ability_id: nil,
             melee_weapon: nil,
             ranged_weapon: nil,
             autobattle_style: nil,
             ignore_hazard_avoidance: false,
             side: 1,
             main_action_set: false,
             willpower_dice: 1.5)
    end

    let(:enemy_participant) do
      double('FightParticipant',
             id: 2,
             character_instance_id: other_instance.id,
             character_instance: other_instance,
             is_npc: false,
             hex_x: 7,
             hex_y: 8,
             is_knocked_out: true,
             current_hp: 0,
             max_hp: 6,
             wound_penalty: 6)
    end

    before do
      allow(room).to receive(:battle_map_image_url).and_return(nil)
      allow(room).to receive(:parsed_battle_map_config).and_return({})
      allow(room).to receive(:is_clipped?).and_return(false)
      allow(room).to receive(:has_custom_polygon?).and_return(false)
      allow(RoomHex).to receive(:where).and_return(double(all: []))
      allow(fight).to receive(:fight_participants).and_return([viewer_participant, enemy_participant])
      allow(StatusEffectService).to receive(:has_effect?).and_return(false)
      allow(StatusEffectService).to receive(:is_prone?).and_return(false)
    end

    it 'builds participant data for all participants' do
      result = service.build_map_state
      expect(result[:participants].length).to eq(2)
    end

    it 'includes participant id' do
      result = service.build_map_state
      viewer_data = result[:participants].find { |p| p[:id] == 1 }
      expect(viewer_data[:id]).to eq(1)
    end

    it 'includes character name' do
      result = service.build_map_state
      viewer_data = result[:participants].find { |p| p[:id] == 1 }
      expect(viewer_data[:name]).to eq('Test Fighter')
    end

    it 'includes short_name (first 3 letters uppercase)' do
      result = service.build_map_state
      viewer_data = result[:participants].find { |p| p[:id] == 1 }
      expect(viewer_data[:short_name]).to eq('TES')
    end

    it 'includes hex coordinates' do
      result = service.build_map_state
      viewer_data = result[:participants].find { |p| p[:id] == 1 }
      expect(viewer_data[:hex_x]).to eq(3)
      expect(viewer_data[:hex_y]).to eq(4)
    end

    it 'marks viewer as current character' do
      result = service.build_map_state
      viewer_data = result[:participants].find { |p| p[:id] == 1 }
      expect(viewer_data[:is_current_character]).to be true
    end

    it 'marks other as not current character' do
      result = service.build_map_state
      enemy_data = result[:participants].find { |p| p[:id] == 2 }
      expect(enemy_data[:is_current_character]).to be false
    end

    it 'includes knocked out status' do
      result = service.build_map_state
      enemy_data = result[:participants].find { |p| p[:id] == 2 }
      expect(enemy_data[:is_knocked_out]).to be true
    end

    it 'includes current_hp' do
      result = service.build_map_state
      viewer_data = result[:participants].find { |p| p[:id] == 1 }
      expect(viewer_data[:current_hp]).to eq(5)
    end

    it 'includes max_hp' do
      result = service.build_map_state
      viewer_data = result[:participants].find { |p| p[:id] == 1 }
      expect(viewer_data[:max_hp]).to eq(6)
    end

    it 'includes injury_level (wound_penalty)' do
      result = service.build_map_state
      viewer_data = result[:participants].find { |p| p[:id] == 1 }
      expect(viewer_data[:injury_level]).to eq(1)
    end

    context 'extended data for viewer' do
      it 'includes is_burning from status effect' do
        result = service.build_map_state
        viewer_data = result[:participants].find { |p| p[:id] == 1 }
        expect(viewer_data[:is_burning]).to be false
      end

      it 'includes is_prone from status effect' do
        result = service.build_map_state
        viewer_data = result[:participants].find { |p| p[:id] == 1 }
        expect(viewer_data[:is_prone]).to be false
      end

      it 'includes is_mounted' do
        result = service.build_map_state
        viewer_data = result[:participants].find { |p| p[:id] == 1 }
        expect(viewer_data[:is_mounted]).to be false
      end

      it 'includes willpower_dice' do
        result = service.build_map_state
        viewer_data = result[:participants].find { |p| p[:id] == 1 }
        expect(viewer_data[:willpower_dice]).to eq(1.5)
      end

      it 'includes main_action_set' do
        result = service.build_map_state
        viewer_data = result[:participants].find { |p| p[:id] == 1 }
        expect(viewer_data[:main_action_set]).to be false
      end

      it 'includes side' do
        result = service.build_map_state
        viewer_data = result[:participants].find { |p| p[:id] == 1 }
        expect(viewer_data[:side]).to eq(1)
      end

      it 'includes current_melee' do
        result = service.build_map_state
        viewer_data = result[:participants].find { |p| p[:id] == 1 }
        expect(viewer_data[:current_melee]).to eq('Unarmed')
      end

      it 'includes current_ranged' do
        result = service.build_map_state
        viewer_data = result[:participants].find { |p| p[:id] == 1 }
        expect(viewer_data[:current_ranged]).to be_nil
      end
    end
  end

  describe 'NPC participant rendering' do
    let(:npc_participant) do
      double('FightParticipant',
             id: 3,
             character_instance_id: nil,
             character_instance: nil,
             is_npc: true,
             npc_name: 'Spider',
             hex_x: 4,
             hex_y: 4,
             is_knocked_out: false,
             current_hp: 8,
             max_hp: 8,
             wound_penalty: 0,
             side: 2)
    end

    before do
      allow(room).to receive(:battle_map_image_url).and_return(nil)
      allow(room).to receive(:parsed_battle_map_config).and_return({})
      allow(room).to receive(:is_clipped?).and_return(false)
      allow(room).to receive(:has_custom_polygon?).and_return(false)
      allow(RoomHex).to receive(:where).and_return(double(all: []))
      allow(fight).to receive(:fight_participants).and_return([npc_participant])
    end

    it 'uses npc_name for name' do
      result = service.build_map_state
      npc_data = result[:participants].find { |p| p[:id] == 3 }
      expect(npc_data[:name]).to eq('Spider')
    end

    it 'uses first 3 letters for short_name' do
      result = service.build_map_state
      npc_data = result[:participants].find { |p| p[:id] == 3 }
      expect(npc_data[:short_name]).to eq('SPI')
    end

    it 'has a red signature color' do
      result = service.build_map_state
      npc_data = result[:participants].find { |p| p[:id] == 3 }
      expect(npc_data[:signature_color]).to eq('#c04040')
    end

    it 'marks as enemy relationship' do
      result = service.build_map_state
      npc_data = result[:participants].find { |p| p[:id] == 3 }
      expect(npc_data[:relationship]).to eq(:enemy)
    end

    it 'marks as NPC' do
      result = service.build_map_state
      npc_data = result[:participants].find { |p| p[:id] == 3 }
      expect(npc_data[:is_npc]).to be true
    end
  end

  describe 'relationship determination' do
    let(:ally_character) { create(:character, forename: 'Ally', surname: 'Friend') }
    let(:ally_instance) { create(:character_instance, character: ally_character, current_room: room) }

    let(:ally_participant) do
      double('FightParticipant',
             id: 2,
             character_instance_id: ally_instance.id,
             character_instance: ally_instance,
             is_npc: false,
             hex_x: 5,
             hex_y: 5,
             is_knocked_out: false,
             current_hp: 6,
             max_hp: 6,
             wound_penalty: 0)
    end

    before do
      allow(room).to receive(:battle_map_image_url).and_return(nil)
      allow(room).to receive(:parsed_battle_map_config).and_return({})
      allow(room).to receive(:is_clipped?).and_return(false)
      allow(room).to receive(:has_custom_polygon?).and_return(false)
      allow(RoomHex).to receive(:where).and_return(double(all: []))
      allow(fight).to receive(:fight_participants).and_return([ally_participant])
    end

    it 'returns self for viewer character' do
      viewer_participant = double('FightParticipant',
                                  id: 1,
                                  character_instance_id: viewer_instance.id,
                                  character_instance: viewer_instance,
                                  is_npc: false,
                                  hex_x: 1,
                                  hex_y: 1,
                                  is_knocked_out: false,
                                  current_hp: 6,
                                  max_hp: 6,
                                  wound_penalty: 0,
                                  is_mounted: false,
                                  available_main_abilities: [],
                                  available_tactical_abilities: [],
                                  ability_id: nil,
                                  melee_weapon: nil,
                                  ranged_weapon: nil,
                                  autobattle_style: nil,
                                  ignore_hazard_avoidance: false,
                                  side: 1,
                                  main_action_set: false,
                                  willpower_dice: 0)
      allow(fight).to receive(:fight_participants).and_return([viewer_participant])
      allow(StatusEffectService).to receive(:has_effect?).and_return(false)
      allow(StatusEffectService).to receive(:is_prone?).and_return(false)

      result = service.build_map_state
      viewer_data = result[:participants].find { |p| p[:id] == 1 }
      expect(viewer_data[:relationship]).to eq('self')
    end

    it 'returns neutral when no relationship exists' do
      allow(Relationship).to receive(:blocked_between?).and_return(false)
      allow(Relationship).to receive(:between).and_return(nil)

      result = service.build_map_state
      ally_data = result[:participants].find { |p| p[:id] == 2 }
      expect(ally_data[:relationship]).to eq('neutral')
    end

    it 'returns enemy when blocked' do
      allow(Relationship).to receive(:blocked_between?).and_return(true)

      result = service.build_map_state
      ally_data = result[:participants].find { |p| p[:id] == 2 }
      expect(ally_data[:relationship]).to eq('enemy')
    end

    it 'returns ally when relationship is accepted' do
      rel = double('Relationship', accepted?: true)
      allow(Relationship).to receive(:blocked_between?).and_return(false)
      allow(Relationship).to receive(:between).and_return(rel)

      result = service.build_map_state
      ally_data = result[:participants].find { |p| p[:id] == 2 }
      expect(ally_data[:relationship]).to eq('ally')
    end
  end

  describe 'monster data building' do
    let(:monster_template) do
      double('MonsterTemplate',
             name: 'Dragon',
             monster_type: 'boss',
             hex_width: 3,
             hex_height: 3,
             image_url: '/images/dragon.png')
    end

    let(:segment_template) do
      double('MonsterSegmentTemplate',
             name: 'Head',
             segment_type: 'weak_point',
             is_weak_point: true)
    end

    let(:segment_instance) do
      seg = double('MonsterSegmentInstance',
                   id: 1,
                   monster_segment_template: segment_template,
                   hp_percent: 75,
                   status: 'healthy',
                   can_attack: true)
      allow(segment_template).to receive(:position_at).and_return([5, 6])
      seg
    end

    let(:monster_instance) do
      double('LargeMonsterInstance',
             id: 1,
             fight_id: 1,
             monster_template: monster_template,
             center_hex_x: 5,
             center_hex_y: 5,
             facing_direction: 0,
             current_hp: 100,
             max_hp: 150,
             current_hp_percent: 66,
             status: 'healthy',
             occupied_hexes: [[4, 4], [5, 4], [6, 4], [4, 5], [5, 5], [6, 5]],
             monster_segment_instances: [segment_instance])
    end

    before do
      allow(room).to receive(:battle_map_image_url).and_return(nil)
      allow(room).to receive(:parsed_battle_map_config).and_return({})
      allow(room).to receive(:is_clipped?).and_return(false)
      allow(room).to receive(:has_custom_polygon?).and_return(false)
      allow(RoomHex).to receive(:where).and_return(double(all: []))
      allow(fight).to receive(:fight_participants).and_return([])
      allow(fight).to receive(:has_monster).and_return(true)
      allow(LargeMonsterInstance).to receive(:where).and_return(double(eager: double(all: [monster_instance])))
    end

    it 'includes monster id' do
      result = service.build_map_state
      expect(result[:monsters][0][:id]).to eq(1)
    end

    it 'includes monster name' do
      result = service.build_map_state
      expect(result[:monsters][0][:name]).to eq('Dragon')
    end

    it 'includes monster_type' do
      result = service.build_map_state
      expect(result[:monsters][0][:monster_type]).to eq('boss')
    end

    it 'includes center position' do
      result = service.build_map_state
      expect(result[:monsters][0][:center_hex_x]).to eq(5)
      expect(result[:monsters][0][:center_hex_y]).to eq(5)
    end

    it 'includes hex dimensions' do
      result = service.build_map_state
      expect(result[:monsters][0][:hex_width]).to eq(3)
      expect(result[:monsters][0][:hex_height]).to eq(3)
    end

    it 'includes facing_direction' do
      result = service.build_map_state
      expect(result[:monsters][0][:facing_direction]).to eq(0)
    end

    it 'includes image_url' do
      result = service.build_map_state
      expect(result[:monsters][0][:image_url]).to eq('/images/dragon.png')
    end

    it 'includes health stats' do
      result = service.build_map_state
      expect(result[:monsters][0][:current_hp]).to eq(100)
      expect(result[:monsters][0][:max_hp]).to eq(150)
      expect(result[:monsters][0][:hp_percent]).to eq(66)
    end

    it 'includes status' do
      result = service.build_map_state
      expect(result[:monsters][0][:status]).to eq('healthy')
    end

    it 'includes occupied_hexes' do
      result = service.build_map_state
      expect(result[:monsters][0][:occupied_hexes].length).to eq(6)
    end

    it 'includes segment data' do
      result = service.build_map_state
      expect(result[:monsters][0][:segments].length).to eq(1)
    end

    it 'includes segment weak point flag' do
      result = service.build_map_state
      segment = result[:monsters][0][:segments][0]
      expect(segment[:is_weak_point]).to be true
    end

    context 'when no monster in fight' do
      before do
        allow(fight).to receive(:has_monster).and_return(false)
      end

      it 'returns empty array' do
        result = service.build_map_state
        expect(result[:monsters]).to eq([])
      end
    end

    context 'when LargeMonsterInstance query fails' do
      before do
        allow(LargeMonsterInstance).to receive(:where).and_raise(StandardError.new('DB error'))
      end

      it 'returns empty array and logs error' do
        result = service.build_map_state
        expect(result[:monsters]).to eq([])
      end
    end
  end

  describe 'ability building' do
    let(:ability) do
      double('Ability',
             id: 1,
             name: 'Fireball',
             short_description: 'Throws a ball of fire',
             description: 'A powerful fire spell that damages enemies in an area',
             respond_to?: true)
    end

    let(:viewer_participant) do
      double('FightParticipant',
             id: 1,
             character_instance_id: viewer_instance.id,
             character_instance: viewer_instance,
             is_npc: false,
             hex_x: 3,
             hex_y: 4,
             is_knocked_out: false,
             current_hp: 5,
             max_hp: 6,
             wound_penalty: 1,
             is_mounted: false,
             available_main_abilities: [ability],
             available_tactical_abilities: [],
             ability_id: nil,
             melee_weapon: nil,
             ranged_weapon: nil,
             autobattle_style: nil,
             ignore_hazard_avoidance: false,
             side: 1,
             main_action_set: false,
             willpower_dice: 0)
    end

    before do
      allow(room).to receive(:battle_map_image_url).and_return(nil)
      allow(room).to receive(:parsed_battle_map_config).and_return({})
      allow(room).to receive(:is_clipped?).and_return(false)
      allow(room).to receive(:has_custom_polygon?).and_return(false)
      allow(RoomHex).to receive(:where).and_return(double(all: []))
      allow(fight).to receive(:fight_participants).and_return([viewer_participant])
      allow(StatusEffectService).to receive(:has_effect?).and_return(false)
      allow(StatusEffectService).to receive(:is_prone?).and_return(false)
      allow(ability).to receive(:on_cooldown?).and_return(false)
    end

    it 'includes main_abilities array' do
      result = service.build_map_state
      viewer_data = result[:participants].find { |p| p[:id] == 1 }
      expect(viewer_data[:main_abilities].length).to eq(1)
    end

    it 'includes ability id' do
      result = service.build_map_state
      viewer_data = result[:participants].find { |p| p[:id] == 1 }
      expect(viewer_data[:main_abilities][0][:id]).to eq(1)
    end

    it 'includes ability name' do
      result = service.build_map_state
      viewer_data = result[:participants].find { |p| p[:id] == 1 }
      expect(viewer_data[:main_abilities][0][:name]).to eq('Fireball')
    end

    it 'includes ability description' do
      result = service.build_map_state
      viewer_data = result[:participants].find { |p| p[:id] == 1 }
      expect(viewer_data[:main_abilities][0][:description]).to eq('Throws a ball of fire')
    end

    it 'includes on_cooldown flag' do
      result = service.build_map_state
      viewer_data = result[:participants].find { |p| p[:id] == 1 }
      expect(viewer_data[:main_abilities][0][:on_cooldown]).to be false
    end

    context 'when ability is on cooldown' do
      before do
        allow(ability).to receive(:on_cooldown?).and_return(true)
      end

      it 'sets on_cooldown to true' do
        result = service.build_map_state
        viewer_data = result[:participants].find { |p| p[:id] == 1 }
        expect(viewer_data[:main_abilities][0][:on_cooldown]).to be true
      end
    end
  end

  describe 'hex_distance calculation' do
    it 'returns 0 for same position' do
      distance = service.send(:hex_distance, 5, 5, 5, 5)
      expect(distance).to eq(0)
    end

    it 'returns 1 for adjacent hex' do
      distance = service.send(:hex_distance, 5, 5, 6, 5)
      expect(distance).to eq(1)
    end

    it 'returns correct distance for diagonal' do
      distance = service.send(:hex_distance, 0, 0, 3, 3)
      expect(distance).to eq(3)
    end
  end

  describe 'short name building' do
    it 'returns UNK for nil character' do
      short = service.send(:build_short_name, nil)
      expect(short).to eq('UNK')
    end

    it 'returns first 3 letters uppercase' do
      short = service.send(:build_short_name, character)
      expect(short).to eq('TES')
    end

    it 'handles names shorter than 3 chars' do
      char = double('Character', full_name: 'Jo')
      short = service.send(:build_short_name, char)
      expect(short).to eq('JO')
    end
  end

  describe 'character intro building' do
    it 'returns nil for nil character' do
      intro = service.send(:build_character_intro, nil, nil)
      expect(intro).to be_nil
    end

    it 'returns short_desc if present' do
      char = double('Character',
                    short_desc: 'A tall fighter',
                    height_cm: nil,
                    body_type: nil,
                    hair_color: nil,
                    eye_color: nil)
      allow(char).to receive(:short_desc).and_return('A tall fighter')

      intro = service.send(:build_character_intro, char, nil)
      expect(intro).to eq('A tall fighter')
    end

    it 'builds from physical attributes if no short_desc' do
      char = double('Character',
                    short_desc: '',
                    height_cm: 180,
                    body_type: 'athletic',
                    hair_color: 'black',
                    eye_color: 'blue')

      intro = service.send(:build_character_intro, char, nil)
      expect(intro).to include('180cm')
      expect(intro).to include('athletic')
      expect(intro).to include('black hair')
      expect(intro).to include('blue eyes')
    end
  end
end
