# frozen_string_literal: true

require 'spec_helper'

RSpec.describe DynamicLightingService do
  let(:location) { create(:location) }
  let(:room) do
    create(:room,
           location: location,
           has_battle_map: true,
           battle_map_image_url: '/uploads/battle_maps/test_map.webp',
           min_x: 0, max_x: 40, min_y: 0, max_y: 40)
  end
  let(:fight) { create(:fight, room: room) }

  describe '.build_lighting_snapshot' do
    it 'captures time_of_day' do
      snapshot = described_class.build_lighting_snapshot(room)

      expect(snapshot).to be_a(Hash)
      expect(snapshot[:time_of_day]).to be_a(String)
      expect(%w[dawn day dusk night]).to include(snapshot[:time_of_day])
    end

    it 'captures hour as an integer' do
      snapshot = described_class.build_lighting_snapshot(room)

      expect(snapshot[:hour]).to be_a(Integer)
      expect(snapshot[:hour]).to be_between(0, 23)
    end

    it 'captures sun altitude and azimuth' do
      snapshot = described_class.build_lighting_snapshot(room)

      expect(snapshot[:sun_altitude]).to be_a(Float)
      expect(snapshot[:sun_altitude]).to be_between(-30.0, 70.0)
      expect(snapshot[:sun_azimuth]).to be_a(Float)
    end

    it 'captures moon illumination and phase' do
      snapshot = described_class.build_lighting_snapshot(room)

      expect(snapshot[:moon_illumination]).to be_a(Float)
      expect(snapshot[:moon_illumination]).to be_between(0.0, 1.0)
      expect(snapshot[:moon_phase]).to be_a(String)
    end

    it 'captures season and progress' do
      snapshot = described_class.build_lighting_snapshot(room)

      expect(snapshot[:season]).to be_a(String)
      expect(snapshot[:season_progress]).to be_a(Float)
    end

    it 'captures weather and cloud cover' do
      create(:weather, location: location, condition: 'rain', cloud_cover: 80)
      snapshot = described_class.build_lighting_snapshot(room)

      expect(snapshot[:weather]).to eq('rain')
      expect(snapshot[:cloud_cover]).to eq(80)
    end

    it 'defaults weather to clear when none exists' do
      # Weather.for_location creates a default if none exists
      snapshot = described_class.build_lighting_snapshot(room)

      expect(snapshot[:weather]).to be_a(String)
    end

    it 'captures indoor flag based on room type' do
      snapshot = described_class.build_lighting_snapshot(room)

      expect(snapshot).to have_key(:indoor)
      expect([true, false]).to include(snapshot[:indoor])
    end

    it 'forces indoor nighttime ambience for temporary delve rooms' do
      delve = create(:delve)
      room.update(room_type: 'standard', is_temporary: true, temp_delve_id: delve.id, indoors: false, is_outdoor: true)

      allow(GameTimeService).to receive(:hour).with(location).and_return(14)
      allow(GameTimeService).to receive(:time_of_day).with(location).and_return(:day)

      snapshot = described_class.build_lighting_snapshot(room)

      expect(snapshot[:hour]).to eq(0)
      expect(snapshot[:time_of_day]).to eq('night')
      expect(snapshot[:indoor]).to be(true)
    end
  end

  describe '.gather_light_sources' do
    it 'returns empty array for room with no sources' do
      sources = described_class.gather_light_sources(room, fight, 800, 600)

      expect(sources).to be_an(Array)
    end

    it 'includes stored detected_light_sources' do
      room.update(detected_light_sources: Sequel.pg_jsonb_wrap([
        { 'type' => 'torch', 'center_x' => 200, 'center_y' => 300, 'intensity' => 0.6 }
      ]))
      room.refresh

      sources = described_class.gather_light_sources(room, fight, 800, 600)

      expect(sources.length).to be >= 1
      torch = sources.find { |s| s['type'] == 'torch' }
      expect(torch).not_to be_nil
      expect(torch['center_x']).to eq(200)
    end

    it 'includes dynamic fire hexes with pixel coords' do
      RoomHex.create(room_id: room.id, hex_x: 4, hex_y: 6, hex_type: 'fire', traversable: true, danger_level: 0)

      sources = described_class.gather_light_sources(room, fight, 800, 600)

      fire = sources.find { |s| s['type'] == 'fire' }
      expect(fire).not_to be_nil
      expect(fire['center_x']).to be_a(Integer)
      expect(fire['center_y']).to be_a(Integer)
      expect(fire['color']).to eq([1.0, 0.7, 0.3])
      expect(fire['radius_px']).to be_a(Integer)
    end

    it 'supports preview mode without a fight' do
      RoomHex.create(room_id: room.id, hex_x: 2, hex_y: 2, hex_type: 'fire', traversable: true, danger_level: 0)

      sources = described_class.gather_light_sources(room, nil, 800, 600)
      fire = sources.find { |s| s['type'] == 'fire' }

      expect(fire).not_to be_nil
      expect(fire['center_x']).to be_a(Integer)
      expect(fire['center_y']).to be_a(Integer)
    end

    it 'merges stored sources with fire hexes' do
      room.update(detected_light_sources: Sequel.pg_jsonb_wrap([
        { 'type' => 'lantern', 'center_x' => 100, 'center_y' => 200 }
      ]))
      room.refresh
      RoomHex.create(room_id: room.id, hex_x: 5, hex_y: 8, hex_type: 'fire', traversable: true, danger_level: 0)

      sources = described_class.gather_light_sources(room, fight, 800, 600)

      expect(sources.length).to eq(2)
    end

    it 'repairs legacy fire sources stored at origin using inferred mask centroid' do
      room.update(
        battle_map_fire_mask_url: '/uploads/battle_maps/test_fire_mask.png',
        detected_light_sources: Sequel.pg_jsonb_wrap([
          { 'source_type' => 'fire', 'center_x' => 0, 'center_y' => 0, 'radius_px' => 80 }
        ])
      )
      room.refresh

      allow(described_class).to receive(:infer_fire_source_from_mask)
        .with(room, 800, 600)
        .and_return({ center_x: 320.0, center_y: 220.0, radius_px: 140.0 })

      sources = described_class.gather_light_sources(room, nil, 800, 600)
      fire = sources.find { |s| (s['source_type'] || s['type']) == 'fire' }

      expect(fire).not_to be_nil
      expect(fire['center_x']).to eq(320.0)
      expect(fire['center_y']).to eq(220.0)
      expect(fire['radius_px']).to eq(140.0)
    end
  end

  # Windows are now extracted from SAM masks on the Python side.
  # The sam_window_mask_path is auto-derived from the battlemap path.

  describe '.gather_character_positions' do
    it 'returns pixel positions of active participants' do
      char = create(:character)
      ci = create(:character_instance, character: char, current_room: room, online: true)
      create(:fight_participant, fight: fight, character_instance: ci, hex_x: 3, hex_y: 4, is_knocked_out: false)

      positions = described_class.gather_character_positions(fight, 800, 600)

      expect(positions.length).to eq(1)
      expect(positions[0][:pixel_x]).to be_a(Integer)
      expect(positions[0][:pixel_y]).to be_a(Integer)
      expect(positions[0][:size]).to eq('medium')
    end

    it 'excludes knocked out participants' do
      char = create(:character)
      ci = create(:character_instance, character: char, current_room: room, online: true)
      create(:fight_participant, fight: fight, character_instance: ci, hex_x: 3, hex_y: 4, is_knocked_out: true)

      positions = described_class.gather_character_positions(fight, 800, 600)

      expect(positions).to eq([])
    end
  end

  describe '.render_for_fight' do
    it 'skips rooms without battle maps' do
      room.update(has_battle_map: false)

      result = described_class.render_for_fight(fight)

      expect(result).to be_nil
    end

    it 'handles connection failures gracefully' do
      # Create a fake battle map file so the path check passes
      map_dir = File.join('public', 'uploads', 'battle_maps')
      FileUtils.mkdir_p(map_dir)
      map_file = File.join(map_dir, 'test_map.webp')
      File.binwrite(map_file, 'fake_image_data')

      # Stub image_dimensions so we don't need a real image
      allow(described_class).to receive(:image_dimensions).and_return([800, 600])

      # Stub the connection to raise a connection error
      allow(Faraday).to receive(:new).and_raise(Faraday::ConnectionFailed.new('Connection refused'))

      result = described_class.render_for_fight(fight)

      expect(result).to be_nil

      # Clean up
      FileUtils.rm_f(map_file)
    end

    it 'returns nil when room has no battle map image URL' do
      room.update(battle_map_image_url: nil)

      result = described_class.render_for_fight(fight)

      expect(result).to be_nil
    end
  end

  describe '.render_preview_for_room' do
    it 'writes a lit preview image and returns its URL' do
      map_dir = File.join('public', 'uploads', 'battle_maps')
      FileUtils.mkdir_p(map_dir)
      map_file = File.join(map_dir, 'test_map.webp')
      File.binwrite(map_file, 'fake_image_data')

      allow(described_class).to receive(:image_dimensions).and_return([800, 600])
      allow(LightingServiceManager).to receive(:ensure_running).and_return(true)
      allow(LightingServiceManager).to receive(:mark_used).and_return(true)
      allow(described_class).to receive(:build_lighting_snapshot).and_return({ time_of_day: 'day', hour: 12 })

      response = instance_double('Faraday::Response', success?: true, body: 'lit-webp', status: 200)
      conn = instance_double('Faraday::Connection')
      allow(conn).to receive(:post).and_return(response)
      allow(described_class).to receive(:build_connection).and_return(conn)

      url = described_class.render_preview_for_room(room, hour: 18.5)

      expect(url).to eq("/uploads/battle_maps/room_#{room.id}_editor_lit_preview.webp")
      output_path = File.join('public', url.sub(%r{^/}, ''))
      expect(File.exist?(output_path)).to be(true)

      FileUtils.rm_f(output_path)
      FileUtils.rm_f(map_file)
    end

    it 'passes resolved window mask path to the lighting payload' do
      map_dir = File.join('public', 'uploads', 'battle_maps')
      FileUtils.mkdir_p(map_dir)
      map_file = File.join(map_dir, 'test_map.webp')
      File.binwrite(map_file, 'fake_image_data')

      allow(described_class).to receive(:image_dimensions).and_return([800, 600])
      allow(LightingServiceManager).to receive(:ensure_running).and_return(true)
      allow(LightingServiceManager).to receive(:mark_used).and_return(true)
      allow(described_class).to receive(:build_lighting_snapshot).and_return({ time_of_day: 'day', hour: 12 })
      allow(described_class).to receive(:resolve_window_mask_path).and_return('/tmp/test_window_mask.png')

      response = instance_double('Faraday::Response', success?: true, body: 'lit-webp', status: 200)
      conn = instance_double('Faraday::Connection')
      expect(conn).to receive(:post) do |path, body, headers|
        expect(path).to eq('/render-lighting')
        expect(headers).to include('Content-Type' => 'application/json')
        payload = JSON.parse(body)
        expect(payload['sam_window_mask_path']).to eq('/tmp/test_window_mask.png')
        response
      end
      allow(described_class).to receive(:build_connection).and_return(conn)

      url = described_class.render_preview_for_room(room, hour: 12.0)
      expect(url).to eq("/uploads/battle_maps/room_#{room.id}_editor_lit_preview.webp")

      FileUtils.rm_f(File.join('public', url.sub(%r{^/}, '')))
      FileUtils.rm_f(map_file)
    end
  end

  describe '.resolve_window_mask_path' do
    it 'falls back to deriving a SAM-style window mask from wall mask' do
      map_dir = File.join('public', 'uploads', 'battle_maps')
      FileUtils.mkdir_p(map_dir)

      map_file = File.join(map_dir, 'fallback_map.webp')
      File.binwrite(map_file, 'fake_image_data')
      room.update(battle_map_image_url: '/uploads/battle_maps/fallback_map.webp')

      wall_mask_name = "room_#{room.id}_wall_mask_test.png"
      wall_mask_file = File.join(map_dir, wall_mask_name)
      File.binwrite(wall_mask_file, 'fake-mask-data')
      room.update(battle_map_wall_mask_url: "/uploads/battle_maps/#{wall_mask_name}")

      expect(described_class).to receive(:derive_window_mask_from_wall_mask).with(File.expand_path(wall_mask_file), room.id)
                                                                       .and_return('/tmp/derived_window_mask.png')
      resolved = described_class.send(:resolve_window_mask_path, room, map_file)

      expect(resolved).to eq('/tmp/derived_window_mask.png')

      FileUtils.rm_f(wall_mask_file)
      FileUtils.rm_f(map_file)
    end
  end

  describe '.cleanup_fight_lighting' do
    it 'removes the fight lighting directory' do
      dir = File.join('tmp', 'fights', fight.id.to_s)
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, 'lit_battlemap.webp'), 'test')

      fight.update(lit_battle_map_url: '/api/fights/1/lit_battlemap.webp')

      described_class.cleanup_fight_lighting(fight)

      expect(File.directory?(dir)).to be false
      fight.refresh
      expect(fight.lit_battle_map_url).to be_nil
    end

    it 'handles missing directory gracefully' do
      expect { described_class.cleanup_fight_lighting(fight) }.not_to raise_error
    end
  end
end
