# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MapSvgRenderService do
  before do
    stub_const('GridCalculationService::GRID_CELL_SIZE', 100)
    stub_const('GridCalculationService::STREET_WIDTH', 10)
  end

  describe '.render_world' do
    let(:world) { double('World', id: 1, name: 'Test World') }
    let(:bounds) { { min_x: 0, max_x: 5, min_y: 0, max_y: 5 } }

    let(:world_hex) do
      double('WorldHex',
             hex_x: 2,
             hex_y: 2,
             terrain_type: 'dense_forest',
             latitude: 2.0,
             longitude: 2.0)
    end

    let(:hex_dataset) do
      dataset = double('Dataset')
      allow(dataset).to receive(:where).and_return(dataset)
      allow(dataset).to receive(:all).and_return([world_hex])
      allow(dataset).to receive(:first).and_return(world_hex)
      dataset
    end

    before do
      allow(WorldHex).to receive(:where).and_return(hex_dataset)
    end

    it 'returns SVG XML' do
      result = described_class.render_world(world, bounds: bounds)
      expect(result).to include('<?xml version="1.0"')
      expect(result).to include('<svg')
      expect(result).to include('</svg>')
    end

    it 'uses specified dimensions' do
      result = described_class.render_world(world, bounds: bounds, width: 1000, height: 800)
      expect(result).to include('width="1000"')
      expect(result).to include('height="800"')
    end

    it 'queries hexes within bounds' do
      expect(WorldHex).to receive(:where).with(world_id: 1).and_return(hex_dataset)

      described_class.render_world(world, bounds: bounds)
    end

    it 'renders hexagons' do
      result = described_class.render_world(world, bounds: bounds)
      expect(result).to include('<circle')
    end

    it 'includes terrain abbreviations' do
      result = described_class.render_world(world, bounds: bounds)
      expect(result).to include('<text')
    end

    it 'includes world title' do
      result = described_class.render_world(world, bounds: bounds)
      expect(result).to include('Test World')
    end

    it 'includes region coordinates in title' do
      result = described_class.render_world(world, bounds: bounds)
      expect(result).to include('0°')
      expect(result).to include('5°')
    end

    it 'adds legend' do
      result = described_class.render_world(world, bounds: bounds)
      # Legend has small colored rectangles
      expect(result.scan('<rect').count).to be > 1
    end

    context 'with various terrain types' do
      %w[ocean deep_ocean forest mountain grassland desert urban swamp snow].each do |terrain|
        it "renders #{terrain} terrain" do
          hex = double('WorldHex', hex_x: 1, hex_y: 1, terrain_type: terrain, latitude: 1.0, longitude: 1.0)
          allow(hex_dataset).to receive(:all).and_return([hex])
          allow(hex_dataset).to receive(:first).and_return(hex)

          result = described_class.render_world(world, bounds: bounds)
          expect(result).to include('<circle')
        end
      end
    end

    context 'when error occurs' do
      before do
        allow(WorldHex).to receive(:where).and_raise(StandardError.new('Database error'))
      end

      it 'returns error SVG' do
        result = described_class.render_world(world, bounds: bounds)
        expect(result).to include('Error')
        expect(result).to include('World render error')
      end
    end
  end

  describe '.render_city' do
    let(:location) do
      double('Location',
             id: 1,
             name: 'Test City',
             city_name: 'Downtown',
             horizontal_streets: 5,
             vertical_streets: 5,
             street_names_json: ['First St', 'Second St'],
             avenue_names_json: ['Main Ave', 'Oak Ave'])
    end

    let(:building_room) do
      double('Room',
             id: 1,
             min_x: 10,
             min_y: 10,
             max_x: 50,
             max_y: 40,
             room_type: 'shop',
             name: 'General Store')
    end

    let(:room_dataset) do
      dataset = double('Dataset')
      allow(dataset).to receive(:where).and_return(dataset)
      allow(dataset).to receive(:all).and_return([building_room])
      dataset
    end

    before do
      allow(Room).to receive(:where).and_return(room_dataset)
    end

    it 'returns SVG XML' do
      result = described_class.render_city(location)
      expect(result).to include('<?xml version="1.0"')
      expect(result).to include('<svg')
    end

    it 'uses specified dimensions' do
      result = described_class.render_city(location, width: 1000, height: 800)
      expect(result).to include('width="1000"')
      expect(result).to include('height="800"')
    end

    it 'draws street grid' do
      result = described_class.render_city(location)
      # Multiple rectangles for streets
      expect(result.scan('<rect').count).to be > 5
    end

    it 'draws buildings' do
      result = described_class.render_city(location)
      expect(result).to include('<rect')
    end

    it 'adds building labels' do
      result = described_class.render_city(location)
      expect(result).to include('<text')
    end

    it 'includes city name in title' do
      result = described_class.render_city(location)
      expect(result).to include('Downtown')
    end

    it 'draws street names' do
      result = described_class.render_city(location)
      expect(result).to include('First St')
    end

    it 'draws avenue names' do
      result = described_class.render_city(location)
      expect(result).to include('Main Ave')
    end

    it 'excludes intersection rooms' do
      expect(room_dataset).to receive(:where) do |*args|
        if args.first.is_a?(Hash)
          room_dataset
        else
          room_dataset
        end
      end.at_least(:once)

      described_class.render_city(location)
    end

    context 'when building has no coordinates' do
      let(:room_no_coords) do
        double('Room',
               id: 2,
               min_x: nil,
               min_y: nil,
               max_x: nil,
               max_y: nil,
               room_type: 'bar',
               name: 'Pub')
      end

      before do
        allow(room_dataset).to receive(:all).and_return([room_no_coords])
      end

      it 'skips building without coordinates' do
        result = described_class.render_city(location)
        expect(result).to include('<svg')
      end
    end

    context 'when location has nil street names' do
      before do
        allow(location).to receive(:street_names_json).and_return(nil)
        allow(location).to receive(:avenue_names_json).and_return(nil)
      end

      it 'handles nil street names gracefully' do
        result = described_class.render_city(location)
        expect(result).to include('<svg')
      end
    end

    context 'when location has nil street counts' do
      before do
        allow(location).to receive(:horizontal_streets).and_return(nil)
        allow(location).to receive(:vertical_streets).and_return(nil)
      end

      it 'uses default values' do
        result = described_class.render_city(location)
        expect(result).to include('<svg')
      end
    end

    context 'when error occurs' do
      before do
        allow(Room).to receive(:where).and_raise(StandardError.new('Database error'))
      end

      it 'returns error SVG' do
        result = described_class.render_city(location)
        expect(result).to include('Error')
        expect(result).to include('City render error')
      end
    end
  end

  describe '.render_room' do
    let(:place) do
      double('Place', x: 30, y: 30, name: 'Chair')
    end

    let(:north_room) do
      double('Room', id: 2, name: 'North Room', navigable?: true)
    end

    let(:spatial_exit) do
      { direction: :north, room: north_room }
    end

    let(:feature) do
      double('RoomFeature', feature_type: 'door', x: 50, y: 0, width: 5, orientation: 'north')
    end

    let(:room) do
      double('Room',
             id: 1,
             name: 'Common Room',
             min_x: 0,
             min_y: 0,
             max_x: 100,
             max_y: 80,
             room_type: 'standard',
             has_custom_polygon?: false,
             room_polygon: nil,
             places: [place],
             passable_spatial_exits: [spatial_exit],
             respond_to?: true,
             room_features: [feature])
    end

    it 'returns SVG XML' do
      result = described_class.render_room(room)
      expect(result).to include('<?xml version="1.0"')
      expect(result).to include('<svg')
    end

    it 'uses specified dimensions' do
      result = described_class.render_room(room, width: 600, height: 600)
      expect(result).to include('width="600"')
      expect(result).to include('height="600"')
    end

    it 'draws room background' do
      result = described_class.render_room(room)
      expect(result).to include('<rect')
    end

    it 'draws furniture/places' do
      result = described_class.render_room(room)
      expect(result).to include('CHA')
    end

    it 'draws exits' do
      result = described_class.render_room(room)
      expect(result).to include('<circle')
    end

    it 'draws room features' do
      result = described_class.render_room(room)
      expect(result.scan('<rect').count).to be > 2
    end

    it 'includes room name in title' do
      result = described_class.render_room(room)
      expect(result).to include('Common Room')
    end

    it 'includes dimensions label' do
      result = described_class.render_room(room)
      expect(result).to include('100ft x 80ft')
    end

    context 'with custom polygon' do
      let(:polygon_room) do
        double('Room',
               id: 1,
               name: 'L-Shaped Room',
               min_x: 0,
               min_y: 0,
               max_x: 100,
               max_y: 100,
               room_type: 'exterior',
               has_custom_polygon?: true,
               room_polygon: [[0, 0], [50, 0], [50, 50], [100, 50], [100, 100], [0, 100]],
               places: [],
               passable_spatial_exits: [],
               respond_to?: false)
      end

      it 'draws polygon outline' do
        result = described_class.render_room(polygon_room)
        expect(result).to include('<polygon')
        expect(result).to include('stroke="#10b981"')
      end
    end

    context 'with different room types' do
      %i[standard exterior vehicle water sky underground].each do |room_type|
        it "renders #{room_type} room" do
          room = double('Room',
                       id: 1, name: 'Test', min_x: 0, min_y: 0, max_x: 50, max_y: 50,
                       room_type: room_type.to_s, has_custom_polygon?: false, room_polygon: nil,
                       places: [], passable_spatial_exits: [], respond_to?: false)

          result = described_class.render_room(room)
          expect(result).to include('<rect')
        end
      end
    end

    context 'with different exit directions' do
      %w[north south east west northeast northwest southeast southwest].each do |dir|
        it "renders #{dir} exit" do
          dest_room = double('Room', id: 99, name: 'Dest', navigable?: true)
          spatial_exit = { direction: dir.to_sym, room: dest_room }
          room = double('Room',
                       id: 1, name: 'Test', min_x: 0, min_y: 0, max_x: 100, max_y: 100,
                       room_type: 'standard', has_custom_polygon?: false, room_polygon: nil,
                       places: [], passable_spatial_exits: [spatial_exit], respond_to?: false)

          result = described_class.render_room(room)
          expect(result).to include('<circle')
        end
      end
    end

    context 'with different feature types' do
      %w[door window other].each do |feature_type|
        it "renders #{feature_type} feature" do
          feature = double('RoomFeature', feature_type: feature_type, x: 50, y: 50, width: 5, orientation: 'east')
          room = double('Room',
                       id: 1, name: 'Test', min_x: 0, min_y: 0, max_x: 100, max_y: 100,
                       room_type: 'standard', has_custom_polygon?: false, room_polygon: nil,
                       places: [], passable_spatial_exits: [],
                       respond_to?: true, room_features: [feature])

          result = described_class.render_room(room)
          expect(result).to include('<rect')
        end
      end
    end

    context 'when room has nil dimensions' do
      let(:room_nil_dims) do
        double('Room',
               id: 1,
               name: nil,
               min_x: nil,
               min_y: nil,
               max_x: nil,
               max_y: nil,
               room_type: nil,
               has_custom_polygon?: false,
               room_polygon: nil,
               places: [],
               passable_spatial_exits: [],
               respond_to?: false)
      end

      it 'uses default dimensions' do
        result = described_class.render_room(room_nil_dims)
        expect(result).to include('<svg')
      end
    end

    context 'when error occurs' do
      before do
        allow(room).to receive(:max_x).and_raise(StandardError.new('Room error'))
      end

      it 'returns error SVG' do
        result = described_class.render_room(room)
        expect(result).to include('Error')
        expect(result).to include('Room render error')
      end
    end
  end

  describe '.render_battle' do
    let(:participant) do
      character = double('Character', full_name: 'Hero')
      character_instance = double('CharacterInstance', character: character)
      double('FightParticipant',
             hex_x: 3,
             hex_y: 3,
             side: 1,
             is_knocked_out: false,
             character_instance: character_instance)
    end

    let(:enemy_participant) do
      character = double('Character', full_name: 'Enemy')
      character_instance = double('CharacterInstance', character: character)
      double('FightParticipant',
             hex_x: 5,
             hex_y: 3,
             side: 2,
             is_knocked_out: false,
             character_instance: character_instance)
    end

    let(:knocked_out_participant) do
      character = double('Character', full_name: 'Fallen')
      character_instance = double('CharacterInstance', character: character)
      double('FightParticipant',
             hex_x: 4,
             hex_y: 4,
             side: 1,
             is_knocked_out: true,
             character_instance: character_instance)
    end

    let(:fight) do
      double('Fight',
             id: 1,
             room_id: 100,
             round_number: 3,
             arena_width: 10,
             arena_height: 10,
             fight_participants: [participant, enemy_participant, knocked_out_participant])
    end

    let(:room_hex_dataset) do
      dataset = double('Dataset')
      allow(dataset).to receive(:first).and_return(nil)
      dataset
    end

    before do
      allow(RoomHex).to receive(:where).and_return(room_hex_dataset)
    end

    it 'returns SVG XML' do
      result = described_class.render_battle(fight)
      expect(result).to include('<?xml version="1.0"')
      expect(result).to include('<svg')
    end

    it 'uses specified dimensions' do
      result = described_class.render_battle(fight, width: 800, height: 800)
      expect(result).to include('width="800"')
      expect(result).to include('height="800"')
    end

    it 'draws hex grid' do
      result = described_class.render_battle(fight)
      # 10x10 grid = 100 hexagons
      expect(result.scan('<polygon').count).to eq(100)
    end

    it 'draws participants as circles' do
      result = described_class.render_battle(fight)
      expect(result.scan('<circle').count).to eq(3)
    end

    it 'uses green for side 1' do
      result = described_class.render_battle(fight)
      expect(result).to include('fill="#22c55e"')
    end

    it 'uses red for side 2' do
      result = described_class.render_battle(fight)
      expect(result).to include('fill="#ef4444"')
    end

    it 'uses gray for knocked out' do
      result = described_class.render_battle(fight)
      expect(result).to include('fill="#6b7280"')
    end

    it 'includes participant name labels' do
      result = described_class.render_battle(fight)
      expect(result).to include('HER')
      expect(result).to include('ENE')
      expect(result).to include('FAL')
    end

    it 'includes round number in title' do
      result = described_class.render_battle(fight)
      expect(result).to include('Battle - Round 3')
    end

    context 'with room hexes' do
      let(:wall_hex) { double('RoomHex', hex_type: 'wall') }
      let(:water_hex) { double('RoomHex', hex_type: 'water') }
      let(:fire_hex) { double('RoomHex', hex_type: 'fire') }
      let(:cover_hex) { double('RoomHex', hex_type: 'cover') }
      let(:debris_hex) { double('RoomHex', hex_type: 'debris') }
      let(:trap_hex) { double('RoomHex', hex_type: 'trap') }

      it 'renders wall hex color' do
        allow(room_hex_dataset).to receive(:first).and_return(wall_hex)
        result = described_class.render_battle(fight)
        expect(result).to include('fill="#4a4a4a"')
      end

      it 'renders water hex color' do
        allow(room_hex_dataset).to receive(:first).and_return(water_hex)
        result = described_class.render_battle(fight)
        expect(result).to include('fill="#3182ce"')
      end

      it 'renders fire hex color' do
        allow(room_hex_dataset).to receive(:first).and_return(fire_hex)
        result = described_class.render_battle(fight)
        expect(result).to include('fill="#e53e3e"')
      end

      it 'renders cover hex color' do
        allow(room_hex_dataset).to receive(:first).and_return(cover_hex)
        result = described_class.render_battle(fight)
        expect(result).to include('fill="#718096"')
      end

      it 'renders debris hex color' do
        allow(room_hex_dataset).to receive(:first).and_return(debris_hex)
        result = described_class.render_battle(fight)
        expect(result).to include('fill="#a0aec0"')
      end

      it 'renders trap hex color' do
        allow(room_hex_dataset).to receive(:first).and_return(trap_hex)
        result = described_class.render_battle(fight)
        expect(result).to include('fill="#d69e2e"')
      end
    end

    context 'with participant without position' do
      let(:unpositioned_participant) do
        double('FightParticipant',
               hex_x: nil,
               hex_y: nil,
               side: 1,
               is_knocked_out: false,
               character_instance: nil)
      end

      before do
        allow(fight).to receive(:fight_participants).and_return([unpositioned_participant])
      end

      it 'skips unpositioned participants' do
        result = described_class.render_battle(fight)
        expect(result.scan('<circle').count).to eq(0)
      end
    end

    context 'with participant without character_instance' do
      let(:no_instance_participant) do
        double('FightParticipant',
               hex_x: 5,
               hex_y: 5,
               side: 1,
               is_knocked_out: false,
               character_instance: nil)
      end

      before do
        allow(fight).to receive(:fight_participants).and_return([no_instance_participant])
      end

      it 'uses fallback label' do
        result = described_class.render_battle(fight)
        expect(result).to include('???')
      end
    end

    context 'when fight has nil arena dimensions' do
      before do
        allow(fight).to receive(:arena_width).and_return(nil)
        allow(fight).to receive(:arena_height).and_return(nil)
      end

      it 'uses default dimensions' do
        result = described_class.render_battle(fight)
        expect(result).to include('<svg')
      end
    end

    context 'when error occurs' do
      before do
        allow(fight).to receive(:arena_width).and_raise(StandardError.new('Fight error'))
      end

      it 'returns error SVG' do
        result = described_class.render_battle(fight)
        expect(result).to include('Error')
        expect(result).to include('Battle render error')
      end
    end
  end

  describe '.render_blueprint' do
    let(:room) do
      double('Room',
             id: 1,
             name: 'Test Tavern',
             min_x: 0, max_x: 80, min_y: 0, max_y: 60,
             room_type: 'common_room',
             has_custom_polygon?: false,
             room_polygon: nil,
             outdoor_room?: false,
             respond_to?: true,
             places: [],
             room_features: [])
    end

    it 'returns valid SVG XML' do
      svg = described_class.render_blueprint(room)
      expect(svg).to include('<?xml')
      expect(svg).to include('<svg')
      expect(svg).to include('</svg>')
    end

    it 'uses white background' do
      svg = described_class.render_blueprint(room)
      expect(svg).to include('fill="#ffffff"')
    end

    it 'does not include room dimensions (removed for cleaner blueprints)' do
      svg = described_class.render_blueprint(room)
      expect(svg).not_to include('80ft')
      expect(svg).not_to include('60ft')
    end

    it 'does not include room name (removed for cleaner blueprints)' do
      svg = described_class.render_blueprint(room)
      expect(svg).not_to include('Test Tavern')
    end

    it 'does not include compass indicator (removed)' do
      svg = described_class.render_blueprint(room)
      expect(svg).not_to include('>N<')
    end

    context 'with furniture' do
      let(:place) { double('Place', x: 20, y: 30, name: 'Round Table') }

      before do
        allow(room).to receive(:places).and_return([place])
      end

      it 'draws furniture with text label' do
        svg = described_class.render_blueprint(room)
        expect(svg).to include('Round Table')
      end

      it 'draws furniture as shape marker' do
        svg = described_class.render_blueprint(room)
        # Furniture is drawn as a circle or rect with stroke
        expect(svg).to include('stroke="#333333"')
      end
    end

    context 'with room features' do
      let(:door) do
        double('RoomFeature',
               feature_type: 'door', name: 'Front Door',
               x: 40, y: 0, direction: 'south', orientation: 'south')
      end
      let(:window) do
        double('RoomFeature',
               feature_type: 'window', name: 'Side Window',
               x: 0, y: 30, direction: 'west', orientation: 'west')
      end

      before do
        allow(room).to receive(:room_features).and_return([door, window])
      end

      it 'draws door notation label' do
        svg = described_class.render_blueprint(room)
        expect(svg).to include('D1')
      end

      it 'draws window notation label' do
        svg = described_class.render_blueprint(room)
        expect(svg).to include('W2')
      end

      it 'draws both feature labels' do
        svg = described_class.render_blueprint(room)
        expect(svg).to include('D1')
        expect(svg).to include('W2')
      end
    end

    context 'with opening features' do
      let(:opening) do
        double('RoomFeature',
               feature_type: 'opening', name: 'Wide Archway',
               x: 40, y: 60, direction: 'north', orientation: 'north')
      end

      before do
        allow(room).to receive(:room_features).and_return([opening])
      end

      it 'draws opening notation' do
        svg = described_class.render_blueprint(room)
        expect(svg).to include('O1')
      end
    end

    context 'with custom width' do
      it 'respects width parameter' do
        svg = described_class.render_blueprint(room, width: 1024)
        expect(svg).to include('width="1024"')
      end
    end

    context 'when error occurs' do
      before do
        allow(room).to receive(:max_x).and_raise(StandardError.new('test error'))
      end

      it 'returns error SVG' do
        svg = described_class.render_blueprint(room)
        expect(svg).to include('Blueprint error')
      end
    end
  end

  describe '.svg_to_png' do
    it 'converts SVG string to PNG file path' do
      svg = '<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100"><rect width="100" height="100" fill="red"/></svg>'
      png_path = described_class.svg_to_png(svg)
      expect(png_path).to end_with('.png')
      expect(File.exist?(png_path)).to be true
      expect(File.size(png_path)).to be > 0
      File.delete(png_path) if png_path && File.exist?(png_path)
    end

    it 'returns nil on nil input' do
      result = described_class.svg_to_png(nil)
      expect(result).to be_nil
    end

    it 'returns nil on empty string' do
      result = described_class.svg_to_png('')
      expect(result).to be_nil
    end
  end

  describe 'private helper methods' do
    describe '.terrain_abbrev' do
      it 'abbreviates ocean terrain' do
        result = described_class.send(:terrain_abbrev, 'ocean')
        expect(result).to eq('OCN')
      end

      it 'abbreviates deep_ocean terrain' do
        result = described_class.send(:terrain_abbrev, 'deep_ocean')
        expect(result).to eq('OCN')
      end

      it 'abbreviates water terrain' do
        result = described_class.send(:terrain_abbrev, 'shallow_water')
        expect(result).to eq('WTR')
      end

      it 'abbreviates forest terrain' do
        result = described_class.send(:terrain_abbrev, 'forest')
        expect(result).to eq('FOR')
      end

      it 'abbreviates mountain terrain' do
        result = described_class.send(:terrain_abbrev, 'mountain')
        expect(result).to eq('MTN')
      end

      it 'abbreviates grassland terrain' do
        result = described_class.send(:terrain_abbrev, 'grassland')
        expect(result).to eq('GRS')
      end

      it 'abbreviates desert terrain' do
        result = described_class.send(:terrain_abbrev, 'desert')
        expect(result).to eq('DST')
      end

      it 'abbreviates urban terrain' do
        result = described_class.send(:terrain_abbrev, 'urban')
        expect(result).to eq('URB')
      end

      it 'abbreviates swamp terrain' do
        result = described_class.send(:terrain_abbrev, 'swamp')
        expect(result).to eq('SWP')
      end

      it 'abbreviates snow terrain' do
        result = described_class.send(:terrain_abbrev, 'snow')
        expect(result).to eq('SNW')
      end

      it 'handles unknown terrain with first 3 chars' do
        result = described_class.send(:terrain_abbrev, 'custom_terrain')
        expect(result).to eq('CUS')
      end

      it 'handles nil terrain' do
        result = described_class.send(:terrain_abbrev, nil)
        expect(result).to eq('???')
      end
    end

    describe '.hex_type_color' do
      it 'returns wall color' do
        result = described_class.send(:hex_type_color, 'wall')
        expect(result).to eq('#4a4a4a')
      end

      it 'returns water color' do
        result = described_class.send(:hex_type_color, 'water')
        expect(result).to eq('#3182ce')
      end

      it 'returns fire color' do
        result = described_class.send(:hex_type_color, 'fire')
        expect(result).to eq('#e53e3e')
      end

      it 'returns lava color' do
        result = described_class.send(:hex_type_color, 'lava')
        expect(result).to eq('#e53e3e')
      end

      it 'returns cover color' do
        result = described_class.send(:hex_type_color, 'cover')
        expect(result).to eq('#718096')
      end

      it 'returns half_cover color' do
        result = described_class.send(:hex_type_color, 'half_cover')
        expect(result).to eq('#718096')
      end

      it 'returns debris color' do
        result = described_class.send(:hex_type_color, 'debris')
        expect(result).to eq('#a0aec0')
      end

      it 'returns trap color' do
        result = described_class.send(:hex_type_color, 'trap')
        expect(result).to eq('#d69e2e')
      end

      it 'returns default color for unknown type' do
        result = described_class.send(:hex_type_color, 'unknown')
        expect(result).to eq('#1e2228')
      end

      it 'returns default color for nil type' do
        result = described_class.send(:hex_type_color, nil)
        expect(result).to eq('#1e2228')
      end
    end
  end
end
