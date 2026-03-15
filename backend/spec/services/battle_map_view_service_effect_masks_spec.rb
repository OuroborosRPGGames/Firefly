# frozen_string_literal: true

require 'spec_helper'

RSpec.describe BattleMapViewService do
  describe '#build_map_state effect masks' do
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

    before do
      allow(room).to receive(:battle_map_image_url).and_return('/images/battle_map.png')
      allow(room).to receive(:parsed_battle_map_config).and_return({})
      allow(room).to receive(:has_battle_map).and_return(true)
      allow(room).to receive(:is_clipped?).and_return(false)
      allow(room).to receive(:has_custom_polygon?).and_return(false)
      allow(GameSetting).to receive(:boolean).and_call_original
      allow(GameSetting).to receive(:boolean).with('battle_map_effects_enabled').and_return(true)
      allow(GameSetting).to receive(:boolean).with('dynamic_lighting_enabled').and_return(true)
    end

    it 'includes water_mask_url when room has one' do
      room.update(battle_map_water_mask_url: '/maps/room_1/water_mask.png')
      result = service.build_map_state
      expect(result[:water_mask_url]).to eq('/maps/room_1/water_mask.png')
    end

    it 'includes foliage_mask_url when room has one' do
      room.update(battle_map_foliage_mask_url: '/maps/room_1/foliage_mask.png')
      result = service.build_map_state
      expect(result[:foliage_mask_url]).to eq('/maps/room_1/foliage_mask.png')
    end

    it 'includes light_sources from room' do
      lights = [{ 'type' => 'torch', 'center_x' => 100, 'center_y' => 200, 'radius_px' => 50,
                  'color' => [1.0, 0.7, 0.3], 'intensity' => 0.8 }]
      room.update(detected_light_sources: Sequel.pg_jsonb_wrap(lights))
      result = service.build_map_state
      expect(result[:light_sources]).to eq(lights)
    end

    it 'returns nil mask urls when not set' do
      result = service.build_map_state
      expect(result[:water_mask_url]).to be_nil
      expect(result[:foliage_mask_url]).to be_nil
    end

    it 'returns empty light_sources when none detected' do
      result = service.build_map_state
      expect(result[:light_sources]).to eq([])
    end

    it 'marks client_full lighting mode when prelit background is unavailable' do
      result = service.build_map_state
      expect(result[:lighting_mode]).to eq('client_full')
      expect(result[:apply_client_ambient]).to be(true)
    end

    it 'marks server_prelit mode when fight has a lit background' do
      allow(fight).to receive(:lit_battle_map_url).and_return('/api/fights/1/lit_battlemap.webp')

      result = service.build_map_state

      expect(result[:background_url]).to eq('/api/fights/1/lit_battlemap.webp')
      expect(result[:lighting_mode]).to eq('server_prelit')
      expect(result[:apply_client_ambient]).to be(false)
    end

    it 'forces indoor nighttime map-state flags for temporary delve rooms' do
      delve = create(:delve)
      room.update(room_type: 'standard', is_temporary: true, temp_delve_id: delve.id, indoors: false, is_outdoor: true)
      allow(GameTimeService).to receive(:current_time).and_return(Time.utc(2026, 3, 13, 14, 0, 0))

      result = service.build_map_state

      expect(result[:time_of_day_hour]).to eq(0)
      expect(result[:is_outdoor]).to be(false)
    end
  end
end
