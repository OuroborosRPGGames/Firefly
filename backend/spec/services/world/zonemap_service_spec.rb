# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ZonemapService do
  describe 'constants' do
    it 'defines CANVAS_SIZE from GameConfig' do
      expect(described_class::CANVAS_SIZE).to eq(GameConfig::Rendering::AREAMAP[:canvas_size])
    end

    it 'defines GRID_SIZE from GameConfig' do
      expect(described_class::GRID_SIZE).to eq(GameConfig::Rendering::AREAMAP[:grid_size])
    end

    it 'defines MARGIN from GameConfig' do
      expect(described_class::MARGIN).to eq(GameConfig::Rendering::AREAMAP[:margin])
    end

    it 'defines hex geometry constants' do
      expect(described_class::HEX_RADIUS).to be > 0
      expect(described_class::HEX_HEIGHT).to be > 0
      expect(described_class::HORIZ_SPACING).to be > 0
      expect(described_class::VERT_SPACING).to eq(described_class::HEX_HEIGHT)
    end

    it 'defines TERRAIN_COLORS with expected terrain types' do
      colors = described_class::TERRAIN_COLORS
      expect(colors).to have_key('ocean')
      expect(colors).to have_key('grassy_plains')
      expect(colors).to have_key('dense_forest')
      expect(colors).to have_key('mountain')
      expect(colors).to have_key('desert')
      expect(colors).to have_key('urban')
      expect(colors.keys.length).to eq(19)
    end

    it 'defines FEATURE_COLORS with expected feature types' do
      colors = described_class::FEATURE_COLORS
      expect(colors['road']).to eq('#7f8c8d')
      expect(colors['highway']).to eq('#f39c12')
      expect(colors['street']).to eq('#95a5a6')
      expect(colors['trail']).to eq('#d7ccc8')
      expect(colors['river']).to eq('#3498db')
      expect(colors['canal']).to eq('#4a8ab5')
      expect(colors['railway']).to eq('#2c3e50')
    end

    it 'defines color constants' do
      expect(described_class::BACKGROUND_COLOR).to eq('#0e1117')
      expect(described_class::TEXT_COLOR).to eq('#ffffff')
      expect(described_class::LABEL_COLOR).to eq('#dddddd')
      expect(described_class::GRID_BORDER_COLOR).to eq('#ffffff26')
      expect(described_class::CENTER_BORDER_COLOR).to eq('#ffcc00')
    end

    it 'defines size constants from GameConfig' do
      expect(described_class::FEATURE_WIDTH).to eq(GameConfig::Rendering::AREAMAP[:feature_width])
      expect(described_class::TITLE_HEIGHT).to eq(GameConfig::Rendering::AREAMAP[:title_height])
    end

    it 'defines FEATURE_EDGE_OFFSETS for all six directions' do
      offsets = described_class::FEATURE_EDGE_OFFSETS
      expect(offsets.keys).to contain_exactly('n', 'ne', 'se', 's', 'sw', 'nw')
    end
  end

  describe '#initialize' do
    let(:world) { double('World', id: 1) }
    let(:location) { double('Location', id: 10) }

    it 'sets world attribute' do
      service = described_class.new(world: world, center_x: 50, center_y: 50, current_location: location)
      expect(service.world).to eq(world)
    end

    it 'sets center_x and center_y' do
      service = described_class.new(world: world, center_x: 100.5, center_y: 200.7, current_location: location)
      expect(service.center_x).to eq(100.5)
      expect(service.center_y).to eq(200.7)
    end

    it 'sets current_location' do
      service = described_class.new(world: world, center_x: 50, center_y: 50, current_location: location)
      expect(service.current_location).to eq(location)
    end
  end

  describe '#hex_to_pixel' do
    let(:world) { double('World', id: 1) }
    let(:location) { double('Location', id: 10) }
    let(:service) { described_class.new(world: world, center_x: 50, center_y: 50, current_location: location) }

    it 'returns [x, y] array' do
      result = service.hex_to_pixel(0, 0)
      expect(result).to be_an(Array)
      expect(result.length).to eq(2)
    end

    it 'places first hex at margin + hex_radius offset' do
      x, _y = service.hex_to_pixel(0, 0)
      expect(x).to eq(described_class::MARGIN + described_class::HEX_RADIUS)
    end

    it 'increases x by HORIZ_SPACING per column' do
      x0, = service.hex_to_pixel(0, 0)
      x1, = service.hex_to_pixel(1, 0)
      expect(x1 - x0).to eq(described_class::HORIZ_SPACING)
    end

    it 'increases y by VERT_SPACING per row' do
      _, y0 = service.hex_to_pixel(0, 0)
      _, y1 = service.hex_to_pixel(0, 1)
      expect(y1 - y0).to eq(described_class::VERT_SPACING)
    end

    it 'staggers odd world columns down by half hex height' do
      # Create service with even center_col so we can predict stagger
      svc = described_class.new(world: world, center_x: 50.0, center_y: 50.0, current_location: location)
      # center_col = 50, half = 4, so world_col for grid col 0 = 50 - 4 = 46 (even)
      # world_col for grid col 1 = 47 (odd) => staggered down
      _, y_even = svc.hex_to_pixel(0, 0)
      _, y_odd = svc.hex_to_pixel(1, 0)
      expect(y_odd - y_even).to eq(described_class::HEX_HEIGHT / 2)
    end
  end

  describe '#render' do
    let(:world) { double('World', id: 1) }
    let(:zone) { double('Zone', name: 'Test Zone') }
    let(:location) { double('Location', id: 10, zone: zone, name: 'Test Location') }
    let(:service) { described_class.new(world: world, center_x: 50, center_y: 50, current_location: location) }

    before do
      allow(DB).to receive(:fetch).and_return(double(all: []))
      allow(Location).to receive(:where).and_return(double(exclude: double(where: double(where: double(all: [])))))
    end

    it 'returns a valid SVG document' do
      result = service.render
      expect(result).to include('<svg')
      expect(result).to include('</svg>')
    end

    it 'includes SVG dimensions' do
      result = service.render
      expect(result).to include("width=\"#{described_class::CANVAS_SIZE}\"")
      expect(result).to include("height=\"#{described_class::CANVAS_SIZE}\"")
    end

    it 'includes zone name in title' do
      result = service.render
      expect(result).to include('Test Zone')
    end

    it 'includes hex cells (polygon elements for 9x9 grid)' do
      result = service.render
      # Should have at least GRID_SIZE^2 polygons for terrain
      polygon_count = result.scan('<polygon').length
      expect(polygon_count).to be >= described_class::GRID_SIZE ** 2
    end

    it 'includes center hex gold border' do
      result = service.render
      expect(result).to include(described_class::CENTER_BORDER_COLOR)
    end

    it 'includes normal hex borders' do
      result = service.render
      expect(result).to include(described_class::GRID_BORDER_COLOR)
    end

    context 'with nil zone' do
      let(:location) { double('Location', id: 10, zone: nil, name: 'Test Location') }

      it 'renders Unknown Zone as fallback' do
        result = service.render
        expect(result).to include('Unknown Zone')
      end
    end

    context 'with nil current_location' do
      let(:service) { described_class.new(world: world, center_x: 50, center_y: 50, current_location: nil) }

      it 'renders without error' do
        result = service.render
        expect(result).to be_a(String)
        expect(result).to include('Unknown Zone')
      end
    end

    context 'with nil world' do
      let(:service) { described_class.new(world: nil, center_x: 50, center_y: 50, current_location: location) }

      it 'renders with default terrain for all cells' do
        result = service.render
        expect(result).to be_a(String)
        # Should still have hex cells with default terrain color
        default_color = described_class::TERRAIN_COLORS[WorldHex::DEFAULT_TERRAIN]
        expect(result).to include(default_color)
      end
    end
  end

  describe '#hex_vertices' do
    let(:world) { double('World', id: 1) }
    let(:location) { double('Location', id: 10, zone: double('Zone', name: 'Test')) }
    let(:service) { described_class.new(world: world, center_x: 50, center_y: 50, current_location: location) }

    it 'returns 6 coordinate pairs' do
      vertices = service.hex_vertices(100, 100, 10)
      expect(vertices.length).to eq(6)
    end

    it 'returns arrays of [x, y] integer pairs' do
      vertices = service.hex_vertices(100, 100, 10)
      vertices.each do |v|
        expect(v).to be_an(Array)
        expect(v.length).to eq(2)
        expect(v[0]).to be_an(Integer)
        expect(v[1]).to be_an(Integer)
      end
    end
  end

  describe 'private #render_hex_cells' do
    let(:world) { double('World', id: 1) }
    let(:location) { double('Location', id: 10, zone: double('Zone', name: 'Test')) }
    let(:service) { described_class.new(world: world, center_x: 50, center_y: 50, current_location: location) }

    before do
      allow(service).to receive(:grid_hexes).and_return({})
    end

    it 'adds polygon elements for every grid cell' do
      svg = SvgBuilder.new(described_class::CANVAS_SIZE, described_class::CANVAS_SIZE)
      service.send(:render_hex_cells, svg)
      output = svg.to_xml
      polygon_count = output.scan('<polygon').length
      # Each cell gets 1 polygon, center cell gets 2 (outer + inner)
      expect(polygon_count).to eq(described_class::GRID_SIZE ** 2 + 1)
    end

    it 'uses default terrain color when no hex data' do
      svg = SvgBuilder.new(described_class::CANVAS_SIZE, described_class::CANVAS_SIZE)
      service.send(:render_hex_cells, svg)
      output = svg.to_xml
      default_color = described_class::TERRAIN_COLORS[WorldHex::DEFAULT_TERRAIN]
      expect(output).to include(default_color)
    end

    it 'highlights center hex with gold border' do
      svg = SvgBuilder.new(described_class::CANVAS_SIZE, described_class::CANVAS_SIZE)
      service.send(:render_hex_cells, svg)
      output = svg.to_xml
      gold_count = output.scan(described_class::CENTER_BORDER_COLOR).length
      # Center hex gets 2 references (outer stroke + inner stroke)
      expect(gold_count).to eq(2)
    end

    context 'with terrain data' do
      let(:hex_data) { { terrain_type: 'ocean', feature_n: nil, feature_ne: nil, feature_se: nil, feature_s: nil, feature_sw: nil, feature_nw: nil } }

      before do
        allow(service).to receive(:grid_hexes).and_return({ [0, 0] => hex_data })
      end

      it 'uses terrain color from hex data' do
        svg = SvgBuilder.new(described_class::CANVAS_SIZE, described_class::CANVAS_SIZE)
        service.send(:render_hex_cells, svg)
        output = svg.to_xml
        ocean_color = described_class::TERRAIN_COLORS['ocean']
        expect(output).to include(ocean_color)
      end
    end
  end

  describe 'private #feature_edge_point' do
    let(:world) { double('World', id: 1) }
    let(:location) { double('Location', id: 10, zone: double('Zone', name: 'Test')) }
    let(:service) { described_class.new(world: world, center_x: 50, center_y: 50, current_location: location) }

    it 'returns point offset from center for north direction' do
      ex, ey = service.send(:feature_edge_point, 100, 100, 'n')
      # North should be above center (lower y)
      expect(ey).to be < 100
      expect(ex).to be_within(2).of(100) # roughly centered horizontally
    end

    it 'returns point offset from center for south direction' do
      ex, ey = service.send(:feature_edge_point, 100, 100, 's')
      # South should be below center (higher y)
      expect(ey).to be > 100
      expect(ex).to be_within(2).of(100)
    end

    it 'returns point offset from center for ne direction' do
      ex, ey = service.send(:feature_edge_point, 100, 100, 'ne')
      expect(ex).to be > 100
      expect(ey).to be < 100
    end

    it 'returns point offset from center for se direction' do
      ex, ey = service.send(:feature_edge_point, 100, 100, 'se')
      expect(ex).to be > 100
      expect(ey).to be > 100
    end

    it 'returns point offset from center for sw direction' do
      ex, ey = service.send(:feature_edge_point, 100, 100, 'sw')
      expect(ex).to be < 100
      expect(ey).to be > 100
    end

    it 'returns point offset from center for nw direction' do
      ex, ey = service.send(:feature_edge_point, 100, 100, 'nw')
      expect(ex).to be < 100
      expect(ey).to be < 100
    end

    it 'returns center for unknown direction' do
      ex, ey = service.send(:feature_edge_point, 100, 100, 'unknown')
      expect([ex, ey]).to eq([100, 100])
    end

    it 'handles uppercase directions' do
      ex, ey = service.send(:feature_edge_point, 100, 100, 'N')
      expect(ey).to be < 100
    end
  end

  describe 'private #render_features' do
    let(:world) { double('World', id: 1) }
    let(:location) { double('Location', id: 10, zone: double('Zone', name: 'Test')) }
    let(:service) { described_class.new(world: world, center_x: 50, center_y: 50, current_location: location) }

    context 'with no features' do
      before do
        allow(service).to receive(:grid_hexes).and_return({
          [4, 4] => { terrain_type: 'grassy_plains', feature_n: nil, feature_ne: nil, feature_se: nil, feature_s: nil, feature_sw: nil, feature_nw: nil }
        })
      end

      it 'adds no line elements' do
        svg = SvgBuilder.new(described_class::CANVAS_SIZE, described_class::CANVAS_SIZE)
        service.send(:render_features, svg)
        output = svg.to_xml
        expect(output).not_to include('<line')
      end
    end

    context 'with directional features' do
      before do
        allow(service).to receive(:grid_hexes).and_return({
          [4, 4] => { terrain_type: 'grassy_plains', feature_n: 'road', feature_ne: nil, feature_se: nil, feature_s: 'river', feature_sw: nil, feature_nw: nil }
        })
      end

      it 'draws lines for each direction with features' do
        svg = SvgBuilder.new(described_class::CANVAS_SIZE, described_class::CANVAS_SIZE)
        service.send(:render_features, svg)
        output = svg.to_xml
        line_count = output.scan('<line').length
        expect(line_count).to eq(2)
      end

      it 'uses correct feature color for roads' do
        svg = SvgBuilder.new(described_class::CANVAS_SIZE, described_class::CANVAS_SIZE)
        service.send(:render_features, svg)
        output = svg.to_xml
        expect(output).to include('#7f8c8d')
      end

      it 'uses correct feature color for rivers' do
        svg = SvgBuilder.new(described_class::CANVAS_SIZE, described_class::CANVAS_SIZE)
        service.send(:render_features, svg)
        output = svg.to_xml
        expect(output).to include('#3498db')
      end
    end
  end

  describe 'private #location_to_grid' do
    let(:world) { double('World', id: 1) }
    let(:location) { double('Location', id: 10) }
    let(:service) { described_class.new(world: world, center_x: 50, center_y: 50, current_location: location) }

    it 'maps center location to center grid cell' do
      # Player at center_x=50, center_y=50 => center_col=50, center_row=50
      # Center grid cell [4,4] covers lon [50,51) lat (49,50]
      # Use exact player position (50.0, 50.0)
      col, row = service.send(:location_to_grid, 50.0, 50.0)
      center = described_class::GRID_SIZE / 2
      expect(col).to eq(center)
      expect(row).to eq(center)
    end

    it 'returns nil for location outside grid' do
      result = service.send(:location_to_grid, 100, 100)
      expect(result).to be_nil
    end

    it 'maps locations to correct relative positions' do
      # Location east of center should have higher col
      col1, = service.send(:location_to_grid, 51.5, 50.5)
      col2, = service.send(:location_to_grid, 49.5, 50.5)
      expect(col1).to be > col2
    end
  end

  describe 'private #render_title' do
    let(:world) { double('World', id: 1) }
    let(:zone) { double('Zone', name: 'Downtown District') }
    let(:location) { double('Location', id: 10, name: 'City Center', zone: zone) }
    let(:service) { described_class.new(world: world, center_x: 50, center_y: 50, current_location: location) }

    it 'includes zone name in SVG text' do
      svg = SvgBuilder.new(described_class::CANVAS_SIZE, described_class::CANVAS_SIZE)
      service.send(:render_title, svg)
      output = svg.to_xml
      expect(output).to include('Downtown District')
    end

    it 'includes location name in title' do
      svg = SvgBuilder.new(described_class::CANVAS_SIZE, described_class::CANVAS_SIZE)
      service.send(:render_title, svg)
      output = svg.to_xml
      expect(output).to include('City Center')
    end

    it 'includes dark background rect behind title' do
      svg = SvgBuilder.new(described_class::CANVAS_SIZE, described_class::CANVAS_SIZE)
      service.send(:render_title, svg)
      output = svg.to_xml
      expect(output).to include('<rect')
      expect(output).to include(described_class::BACKGROUND_COLOR)
    end

    context 'with nil zone' do
      let(:location) { double('Location', id: 10, name: nil, zone: nil) }

      it 'uses Unknown Zone as fallback' do
        svg = SvgBuilder.new(described_class::CANVAS_SIZE, described_class::CANVAS_SIZE)
        service.send(:render_title, svg)
        output = svg.to_xml
        expect(output).to include('Unknown Zone')
      end
    end

    context 'with nil current_location' do
      let(:service) { described_class.new(world: world, center_x: 50, center_y: 50, current_location: nil) }

      it 'uses Unknown Zone as fallback' do
        svg = SvgBuilder.new(described_class::CANVAS_SIZE, described_class::CANVAS_SIZE)
        service.send(:render_title, svg)
        output = svg.to_xml
        expect(output).to include('Unknown Zone')
      end
    end
  end

  describe 'private #grid_hexes' do
    let(:world) { double('World', id: 1) }
    let(:location) { double('Location', id: 10, zone: double('Zone', name: 'Test')) }
    let(:service) { described_class.new(world: world, center_x: 50, center_y: 50, current_location: location) }

    context 'with nil world' do
      let(:service) { described_class.new(world: nil, center_x: 50, center_y: 50, current_location: location) }

      it 'returns empty hash' do
        result = service.send(:grid_hexes)
        expect(result).to eq({})
      end
    end

    context 'with valid world' do
      let(:query_result) do
        [
          { id: 1, terrain_type: 'ocean', cell_x: 0, cell_y: 0, feature_n: nil, feature_ne: nil, feature_se: nil, feature_s: nil, feature_sw: nil, feature_nw: nil },
          { id: 2, terrain_type: 'forest', cell_x: 4, cell_y: 4, feature_n: 'road', feature_ne: nil, feature_se: nil, feature_s: nil, feature_sw: nil, feature_nw: nil }
        ]
      end

      before do
        allow(DB).to receive(:fetch).and_return(double(all: query_result))
      end

      it 'queries DB with DISTINCT ON' do
        expect(DB).to receive(:fetch).with(a_string_matching(/DISTINCT ON/), any_args)
        service.send(:grid_hexes)
      end

      it 'returns hash keyed by [col, row]' do
        result = service.send(:grid_hexes)
        expect(result).to be_a(Hash)
        expect(result[[0, 0]]).to be_a(Hash)
        expect(result[[4, 4]]).to be_a(Hash)
      end

      it 'memoizes the result' do
        first_result = service.send(:grid_hexes)
        second_result = service.send(:grid_hexes)
        expect(first_result).to equal(second_result)
      end

      it 'filters out cells outside grid bounds' do
        out_of_bounds = [
          { id: 3, terrain_type: 'ocean', cell_x: -1, cell_y: 0, feature_n: nil, feature_ne: nil, feature_se: nil, feature_s: nil, feature_sw: nil, feature_nw: nil },
          { id: 4, terrain_type: 'ocean', cell_x: 0, cell_y: 99, feature_n: nil, feature_ne: nil, feature_se: nil, feature_s: nil, feature_sw: nil, feature_nw: nil }
        ]
        allow(DB).to receive(:fetch).and_return(double(all: out_of_bounds))

        result = service.send(:grid_hexes)
        expect(result).to be_empty
      end
    end
  end

  describe 'text helpers (delegated to CanvasHelper)' do
    describe 'CanvasHelper.sanitize_text' do
      it 'returns empty string for nil' do
        expect(CanvasHelper.sanitize_text(nil)).to eq('')
      end

      it 'removes HTML tags' do
        expect(CanvasHelper.sanitize_text('<b>Bold</b> text')).to eq('Bold text')
      end

      it 'replaces pipe characters with spaces' do
        expect(CanvasHelper.sanitize_text('Hello|World')).to eq('Hello World')
      end

      it 'replaces semicolons with spaces' do
        expect(CanvasHelper.sanitize_text('Hello;World')).to eq('Hello World')
      end

      it 'replaces colons with spaces' do
        expect(CanvasHelper.sanitize_text('Hello:World')).to eq('Hello World')
      end

      it 'strips leading and trailing whitespace' do
        expect(CanvasHelper.sanitize_text('  Hello  ')).to eq('Hello')
      end

      it 'handles multiple special characters' do
        expect(CanvasHelper.sanitize_text('<p>Hello|;:World</p>')).to eq('Hello   World')
      end
    end

    describe 'CanvasHelper.truncate_name' do
      it 'returns empty string for nil' do
        expect(CanvasHelper.truncate_name(nil)).to eq('')
      end

      it 'returns short names unchanged' do
        expect(CanvasHelper.truncate_name('Short')).to eq('Short')
      end

      it 'truncates long names with ellipsis' do
        long_name = 'This is a very long name'
        result = CanvasHelper.truncate_name(long_name)
        expect(result).to end_with('...')
      end

      it 'uses default max_length of 15' do
        name = 'A' * 20
        result = CanvasHelper.truncate_name(name)
        expect(result.length).to eq(15)
      end

      it 'accepts custom max_length' do
        name = 'A' * 20
        result = CanvasHelper.truncate_name(name, 10)
        expect(result.length).to eq(10)
        expect(result).to end_with('...')
      end

      it 'returns name at exact max_length unchanged' do
        name = 'A' * 15
        result = CanvasHelper.truncate_name(name, 15)
        expect(result).to eq(name)
      end
    end
  end

  describe 'backward compatibility' do
    it 'has AreamapService alias' do
      expect(defined?(AreamapService)).to eq('constant')
      expect(AreamapService).to eq(ZonemapService)
    end

    it 'can instantiate via alias' do
      world = double('World', id: 1)
      location = double('Location', id: 10, zone: double('Zone', name: 'Test'))

      service = AreamapService.new(world: world, center_x: 50, center_y: 50, current_location: location)
      expect(service).to be_a(ZonemapService)
    end
  end

  describe 'integration' do
    let(:world) { create(:world) }
    let(:zone) { create(:zone, world: world, name: 'Test Zone', polygon_points: [{ x: 0, y: 0 }, { x: 100, y: 0 }, { x: 100, y: 100 }, { x: 0, y: 100 }]) }
    let(:location) { create(:location, zone: zone, world: world, name: 'Test Location', location_type: 'outdoor', globe_hex_id: 1, latitude: 50.0, longitude: 50.0) }

    describe '#render with real database' do
      subject(:service) { described_class.new(world: world, center_x: 50, center_y: 50, current_location: location) }

      it 'returns SVG XML string' do
        result = service.render
        expect(result).to be_a(String)
        expect(result).to include('<svg')
        expect(result).to include('</svg>')
      end

      it 'includes SVG dimensions' do
        result = service.render
        expect(result).to include("width=\"#{described_class::CANVAS_SIZE}\"")
        expect(result).to include("height=\"#{described_class::CANVAS_SIZE}\"")
      end

      it 'includes zone name in title' do
        result = service.render
        expect(result).to include('Test Zone')
      end

      context 'with world hexes' do
        before do
          WorldHex.create(world: world, globe_hex_id: 1, latitude: 48.0, longitude: 50.0, terrain_type: 'dense_forest')
          WorldHex.create(world: world, globe_hex_id: 2, latitude: 50.0, longitude: 51.0, terrain_type: 'grassy_plains')
        end

        it 'renders terrain hexes as polygons' do
          result = service.render
          expect(result).to include('<polygon')
        end
      end
    end
  end
end
