# frozen_string_literal: true

require 'spec_helper'

RSpec.describe SvgBuilder do
  let(:width) { 800 }
  let(:height) { 600 }
  let(:builder) { described_class.new(width, height) }

  describe '#initialize' do
    it 'sets width and height' do
      svg = builder.to_xml
      expect(svg).to include('width="800"')
      expect(svg).to include('height="600"')
    end

    it 'uses default background' do
      svg = builder.to_xml
      expect(svg).to include('fill="#0d1117"')
    end

    it 'uses custom background' do
      builder = described_class.new(100, 100, background: '#ff0000')
      svg = builder.to_xml
      expect(svg).to include('fill="#ff0000"')
    end
  end

  describe '#rect' do
    it 'adds rectangle element' do
      builder.rect(10, 20, 100, 50)
      svg = builder.to_xml
      expect(svg).to include('<rect')
      expect(svg).to include('x="10"')
      expect(svg).to include('y="20"')
      expect(svg).to include('width="100"')
      expect(svg).to include('height="50"')
    end

    it 'applies fill and stroke options' do
      builder.rect(0, 0, 50, 50, fill: '#ff0000', stroke: '#000000')
      svg = builder.to_xml
      expect(svg).to include('fill="#ff0000"')
      expect(svg).to include('stroke="#000000"')
    end

    it 'applies stroke_width option' do
      builder.rect(0, 0, 50, 50, stroke_width: 2)
      svg = builder.to_xml
      expect(svg).to include('stroke-width="2"')
    end

    it 'applies rx and ry for rounded corners' do
      builder.rect(0, 0, 50, 50, rx: 5, ry: 5)
      svg = builder.to_xml
      expect(svg).to include('rx="5"')
      expect(svg).to include('ry="5"')
    end

    it 'returns self for chaining' do
      result = builder.rect(0, 0, 50, 50)
      expect(result).to eq(builder)
    end
  end

  describe '#circle' do
    it 'adds circle element' do
      builder.circle(100, 100, 50)
      svg = builder.to_xml
      expect(svg).to include('<circle')
      expect(svg).to include('cx="100"')
      expect(svg).to include('cy="100"')
      expect(svg).to include('r="50"')
    end

    it 'applies fill and stroke options' do
      builder.circle(0, 0, 10, fill: '#00ff00', stroke: '#000')
      svg = builder.to_xml
      expect(svg).to include('fill="#00ff00"')
      expect(svg).to include('stroke="#000"')
    end

    it 'returns self for chaining' do
      result = builder.circle(0, 0, 10)
      expect(result).to eq(builder)
    end
  end

  describe '#ellipse' do
    it 'adds ellipse element' do
      builder.ellipse(100, 100, 60, 40)
      svg = builder.to_xml
      expect(svg).to include('<ellipse')
      expect(svg).to include('cx="100"')
      expect(svg).to include('cy="100"')
      expect(svg).to include('rx="60"')
      expect(svg).to include('ry="40"')
    end

    it 'returns self for chaining' do
      result = builder.ellipse(0, 0, 10, 5)
      expect(result).to eq(builder)
    end
  end

  describe '#line' do
    it 'adds line element' do
      builder.line(0, 0, 100, 100)
      svg = builder.to_xml
      expect(svg).to include('<line')
      expect(svg).to include('x1="0"')
      expect(svg).to include('y1="0"')
      expect(svg).to include('x2="100"')
      expect(svg).to include('y2="100"')
    end

    it 'applies stroke options' do
      builder.line(0, 0, 100, 100, stroke: '#fff', stroke_width: 2)
      svg = builder.to_xml
      expect(svg).to include('stroke="#fff"')
      expect(svg).to include('stroke-width="2"')
    end

    it 'returns self for chaining' do
      result = builder.line(0, 0, 10, 10)
      expect(result).to eq(builder)
    end
  end

  describe '#polyline' do
    it 'adds polyline element' do
      points = [[0, 0], [50, 25], [100, 0]]
      builder.polyline(points)
      svg = builder.to_xml
      expect(svg).to include('<polyline')
      expect(svg).to include('points="0,0 50,25 100,0"')
    end

    it 'applies stroke options' do
      builder.polyline([[0, 0], [10, 10]], stroke: '#f00', fill: 'none')
      svg = builder.to_xml
      expect(svg).to include('stroke="#f00"')
      expect(svg).to include('fill="none"')
    end

    it 'returns self for chaining' do
      result = builder.polyline([[0, 0], [10, 10]])
      expect(result).to eq(builder)
    end
  end

  describe '#polygon' do
    it 'adds polygon element' do
      points = [[0, 0], [100, 0], [50, 100]]
      builder.polygon(points)
      svg = builder.to_xml
      expect(svg).to include('<polygon')
      expect(svg).to include('points="0,0 100,0 50,100"')
    end

    it 'applies fill options' do
      builder.polygon([[0, 0], [10, 0], [5, 10]], fill: '#0000ff')
      svg = builder.to_xml
      expect(svg).to include('fill="#0000ff"')
    end

    it 'returns self for chaining' do
      result = builder.polygon([[0, 0], [10, 0], [5, 10]])
      expect(result).to eq(builder)
    end
  end

  describe '#path' do
    it 'adds path element' do
      builder.path('M 0 0 L 100 100 Z')
      svg = builder.to_xml
      expect(svg).to include('<path')
      expect(svg).to include('d="M 0 0 L 100 100 Z"')
    end

    it 'applies fill and stroke options' do
      builder.path('M 0 0 L 10 10', fill: 'none', stroke: '#000')
      svg = builder.to_xml
      expect(svg).to include('fill="none"')
      expect(svg).to include('stroke="#000"')
    end

    it 'returns self for chaining' do
      result = builder.path('M 0 0')
      expect(result).to eq(builder)
    end
  end

  describe '#text' do
    it 'adds text element' do
      builder.text(50, 50, 'Hello World')
      svg = builder.to_xml
      expect(svg).to include('<text')
      expect(svg).to include('x="50"')
      expect(svg).to include('y="50"')
      expect(svg).to include('>Hello World</text>')
    end

    it 'applies font options' do
      builder.text(0, 0, 'Test', font_size: 14, font_family: 'Arial')
      svg = builder.to_xml
      expect(svg).to include('font-size="14"')
      expect(svg).to include('font-family="Arial"')
    end

    it 'applies text_anchor option' do
      builder.text(0, 0, 'Test', text_anchor: 'middle')
      svg = builder.to_xml
      expect(svg).to include('text-anchor="middle"')
    end

    it 'escapes HTML entities' do
      builder.text(0, 0, '<script>alert("xss")</script>')
      svg = builder.to_xml
      expect(svg).to include('&lt;script&gt;')
      expect(svg).not_to include('<script>')
    end

    it 'escapes ampersands' do
      builder.text(0, 0, 'A & B')
      svg = builder.to_xml
      expect(svg).to include('A &amp; B')
    end

    it 'returns self for chaining' do
      result = builder.text(0, 0, 'Test')
      expect(result).to eq(builder)
    end
  end

  describe '#group' do
    it 'wraps elements in g tag' do
      builder.group do
        builder.rect(0, 0, 10, 10)
        builder.circle(5, 5, 3)
      end
      svg = builder.to_xml
      expect(svg).to include('<g>')
      expect(svg).to include('</g>')
    end

    it 'applies transform option' do
      builder.group(transform: 'translate(10,20)') do
        builder.rect(0, 0, 10, 10)
      end
      svg = builder.to_xml
      expect(svg).to include('transform="translate(10,20)"')
    end

    it 'applies id and class options' do
      builder.group(id: 'mygroup', class: 'highlight') do
        builder.circle(0, 0, 5)
      end
      svg = builder.to_xml
      expect(svg).to include('id="mygroup"')
      expect(svg).to include('class="highlight"')
    end

    it 'returns self for chaining' do
      result = builder.group { builder.rect(0, 0, 10, 10) }
      expect(result).to eq(builder)
    end
  end

  describe '#hexagon' do
    it 'creates hexagon polygon' do
      builder.hexagon(100, 100, 20)
      svg = builder.to_xml
      expect(svg).to include('<polygon')
      expect(svg).to include('points=')
    end

    it 'creates 6-sided polygon' do
      builder.hexagon(100, 100, 20)
      svg = builder.to_xml
      # A hexagon has 6 points, so 6 coordinate pairs separated by spaces
      match = svg.match(/points="([^"]+)"/)
      expect(match).not_to be_nil
      points = match[1].split(' ')
      expect(points.length).to eq(6)
    end

    it 'applies fill and stroke options' do
      builder.hexagon(100, 100, 20, fill: '#228b22', stroke: '#000')
      svg = builder.to_xml
      expect(svg).to include('fill="#228b22"')
      expect(svg).to include('stroke="#000"')
    end

    it 'returns self for chaining' do
      result = builder.hexagon(0, 0, 10)
      expect(result).to eq(builder)
    end
  end

  describe '#add_world_hex' do
    let(:hex) do
      double('WorldHex',
             hex_x: 5,
             hex_y: 3,
             terrain_type: 'dense_forest',
             features: ['road'])
    end

    it 'adds hexagon for world hex' do
      builder.add_world_hex(hex, hex_size: 20)
      svg = builder.to_xml
      expect(svg).to include('<polygon')
    end

    it 'uses correct terrain color' do
      builder.add_world_hex(hex, hex_size: 20)
      svg = builder.to_xml
      expect(svg).to include('fill="#3a6632"') # dense_forest color
    end

    it 'adds feature text when features present' do
      builder.add_world_hex(hex, hex_size: 20)
      svg = builder.to_xml
      expect(svg).to include('<text')
      expect(svg).to include('RO')
    end

    it 'handles hex without features' do
      hex_no_features = double('WorldHex', hex_x: 0, hex_y: 0, terrain_type: 'grassy_plains', features: nil)
      builder.add_world_hex(hex_no_features, hex_size: 20)
      svg = builder.to_xml
      expect(svg).to include('<polygon')
    end

    it 'handles empty features array' do
      hex_empty_features = double('WorldHex', hex_x: 0, hex_y: 0, terrain_type: 'mountain', features: [])
      builder.add_world_hex(hex_empty_features, hex_size: 20)
      svg = builder.to_xml
      expect(svg).to include('<polygon')
    end

    it 'uses unknown color for unknown terrain' do
      unknown_hex = double('WorldHex', hex_x: 0, hex_y: 0, terrain_type: 'unknown_terrain', features: nil)
      builder.add_world_hex(unknown_hex, hex_size: 20)
      svg = builder.to_xml
      expect(svg).to include('fill="#4a4a4a"')
    end

    it 'returns self for chaining' do
      result = builder.add_world_hex(hex)
      expect(result).to eq(builder)
    end
  end

  describe '#add_building' do
    let(:room) do
      double('Room',
             min_x: 10,
             min_y: 20,
             max_x: 50,
             max_y: 60,
             room_type: 'shop',
             name: 'General Store')
    end

    it 'adds rectangle for building' do
      builder.add_building(room, scale: 2.0, offset_x: 10, offset_y: 10)
      svg = builder.to_xml
      expect(svg).to include('<rect')
    end

    it 'uses correct building color' do
      builder.add_building(room, scale: 1.0)
      svg = builder.to_xml
      expect(svg).to include('fill="#4682b4"')
    end

    it 'adds label for building' do
      builder.add_building(room, scale: 2.0)
      svg = builder.to_xml
      expect(svg).to include('<text')
      expect(svg).to include('General St')
    end

    it 'handles room without min coordinates' do
      room_no_coords = double('Room', min_x: nil, min_y: nil, max_x: 100, max_y: 100, room_type: 'bar', name: 'Pub')
      result = builder.add_building(room_no_coords)
      expect(result).to eq(builder)
    end

    it 'handles unknown room type' do
      unknown_room = double('Room', min_x: 0, min_y: 0, max_x: 30, max_y: 30, room_type: 'unknown', name: 'Test')
      builder.add_building(unknown_room, scale: 1.0)
      svg = builder.to_xml
      expect(svg).to include('fill="#4a4a4a"')
    end

    it 'returns self for chaining' do
      result = builder.add_building(room)
      expect(result).to eq(builder)
    end
  end

  describe '#add_room_bounds' do
    let(:room) do
      double('Room',
             min_x: 0,
             min_y: 0,
             max_x: 100,
             max_y: 80,
             room_type: 'standard',
             has_custom_polygon?: false,
             room_polygon: nil)
    end

    it 'adds room background rectangle' do
      builder.add_room_bounds(room, width: 400, height: 400)
      svg = builder.to_xml
      expect(svg).to include('<rect')
    end

    it 'uses room type color' do
      builder.add_room_bounds(room, width: 400, height: 400)
      svg = builder.to_xml
      expect(svg).to include('fill="#2d3748"')
    end

    context 'with custom polygon' do
      let(:polygon_room) do
        double('Room',
               min_x: 0,
               min_y: 0,
               max_x: 100,
               max_y: 100,
               room_type: 'exterior',
               has_custom_polygon?: true,
               room_polygon: [[0, 0], [100, 0], [100, 100], [0, 100]])
      end

      it 'adds polygon outline' do
        builder.add_room_bounds(polygon_room, width: 400, height: 400)
        svg = builder.to_xml
        expect(svg).to include('<polygon')
        expect(svg).to include('stroke="#10b981"')
      end
    end

    it 'returns self for chaining' do
      result = builder.add_room_bounds(room, width: 400, height: 400)
      expect(result).to eq(builder)
    end
  end

  describe '#add_furniture' do
    let(:place) do
      double('Place', x: 50, y: 50, name: 'Chair')
    end

    before do
      room = double('Room', min_x: 0, min_y: 0, max_x: 100, max_y: 100, room_type: 'standard', has_custom_polygon?: false, room_polygon: nil)
      builder.add_room_bounds(room, width: 400, height: 400)
    end

    it 'adds rectangle for furniture' do
      builder.add_furniture(place)
      svg = builder.to_xml
      expect(svg.scan('<rect').count).to be >= 2
    end

    it 'adds label for furniture' do
      builder.add_furniture(place)
      svg = builder.to_xml
      expect(svg).to include('CHA')
    end

    it 'returns self without room scale set' do
      fresh_builder = described_class.new(400, 400)
      result = fresh_builder.add_furniture(place)
      expect(result).to eq(fresh_builder)
    end

    it 'returns self for chaining' do
      result = builder.add_furniture(place)
      expect(result).to eq(builder)
    end
  end

  describe '#add_exit' do
    let(:exit) do
      double('RoomExit', from_x: 50, from_y: 0, direction: 'north')
    end

    before do
      room = double('Room', min_x: 0, min_y: 0, max_x: 100, max_y: 100, room_type: 'standard', has_custom_polygon?: false, room_polygon: nil)
      builder.add_room_bounds(room, width: 400, height: 400)
    end

    it 'adds exit arrow with group transform' do
      builder.add_exit(exit)
      svg = builder.to_xml
      expect(svg).to include('<g')
      expect(svg).to include('rotate(-90)')
    end

    it 'adds path for arrow shape' do
      builder.add_exit(exit)
      svg = builder.to_xml
      expect(svg).to include('<path')
    end

    context 'with different directions' do
      %w[south east west northeast northwest southeast southwest up down].each do |dir|
        it "handles #{dir} direction" do
          exit = double('RoomExit', from_x: 50, from_y: 50, direction: dir)
          builder.add_exit(exit)
          svg = builder.to_xml
          expect(svg).to include('<g')
        end
      end
    end

    it 'returns self without room scale set' do
      fresh_builder = described_class.new(400, 400)
      result = fresh_builder.add_exit(exit)
      expect(result).to eq(fresh_builder)
    end

    it 'returns self for chaining' do
      result = builder.add_exit(exit)
      expect(result).to eq(builder)
    end
  end

  describe '#add_city_grid' do
    let(:location) do
      double('Location', horizontal_streets: 5, vertical_streets: 5)
    end

    before do
      stub_const('GridCalculationService::GRID_CELL_SIZE', 100)
      stub_const('GridCalculationService::STREET_WIDTH', 10)
    end

    it 'adds street rectangles' do
      builder.add_city_grid(location, scale: 1.0)
      svg = builder.to_xml
      expect(svg).to include('<rect')
    end

    it 'uses default values when location has nil streets' do
      location_nil = double('Location', horizontal_streets: nil, vertical_streets: nil)
      builder.add_city_grid(location_nil, scale: 1.0)
      svg = builder.to_xml
      expect(svg).to include('<rect')
    end

    it 'returns self for chaining' do
      result = builder.add_city_grid(location)
      expect(result).to eq(builder)
    end
  end

  describe '#to_xml' do
    it 'returns valid SVG XML' do
      svg = builder.to_xml
      expect(svg).to include('<?xml version="1.0"')
      expect(svg).to include('<svg xmlns="http://www.w3.org/2000/svg"')
      expect(svg).to include('</svg>')
    end

    it 'includes viewBox' do
      svg = builder.to_xml
      expect(svg).to include('viewBox="0 0 800 600"')
    end

    it 'includes all added elements' do
      builder.rect(10, 10, 50, 50)
      builder.circle(100, 100, 20)
      builder.text(50, 50, 'Test')
      svg = builder.to_xml
      expect(svg).to include('<rect')
      expect(svg).to include('<circle')
      expect(svg).to include('<text')
    end
  end

  describe 'method chaining' do
    it 'allows chaining multiple elements' do
      result = builder
        .rect(0, 0, 100, 100)
        .circle(50, 50, 20)
        .text(50, 50, 'Test')
        .line(0, 0, 100, 100)

      expect(result).to eq(builder)
      svg = builder.to_xml
      expect(svg).to include('<rect')
      expect(svg).to include('<circle')
      expect(svg).to include('<text')
      expect(svg).to include('<line')
    end
  end

  describe 'TERRAIN_COLORS constant' do
    it 'has water colors' do
      expect(described_class::TERRAIN_COLORS['ocean']).to eq('#2d5f8a')
      expect(described_class::TERRAIN_COLORS['lake']).to eq('#4a8ab5')
    end

    it 'has forest colors' do
      expect(described_class::TERRAIN_COLORS['light_forest']).to eq('#6d9a52')
      expect(described_class::TERRAIN_COLORS['dense_forest']).to eq('#3a6632')
      expect(described_class::TERRAIN_COLORS['jungle']).to eq('#2d5a2d')
    end

    it 'has mountain and hills colors' do
      expect(described_class::TERRAIN_COLORS['mountain']).to eq('#8a7d6b')
      expect(described_class::TERRAIN_COLORS['grassy_hills']).to eq('#96a07a')
      expect(described_class::TERRAIN_COLORS['rocky_hills']).to eq('#9a8d78')
    end

    it 'has urban colors' do
      expect(described_class::TERRAIN_COLORS['urban']).to eq('#7a7a7a')
      expect(described_class::TERRAIN_COLORS['light_urban']).to eq('#9a9a9a')
    end

    it 'has unknown fallback' do
      expect(described_class::TERRAIN_COLORS['unknown']).to eq('#4a4a4a')
    end
  end

  describe 'BUILDING_COLORS constant' do
    it 'has residential building colors' do
      expect(described_class::BUILDING_COLORS[:apartment_tower]).to eq('#6a6a6a')
      expect(described_class::BUILDING_COLORS[:brownstone]).to eq('#8b4513')
      expect(described_class::BUILDING_COLORS[:house]).to eq('#daa520')
    end

    it 'has commercial building colors' do
      expect(described_class::BUILDING_COLORS[:shop]).to eq('#4682b4')
      expect(described_class::BUILDING_COLORS[:cafe]).to eq('#cd853f')
      expect(described_class::BUILDING_COLORS[:bar]).to eq('#800020')
    end

    it 'has service building colors' do
      expect(described_class::BUILDING_COLORS[:hospital]).to eq('#ff6347')
      expect(described_class::BUILDING_COLORS[:police_station]).to eq('#1e90ff')
      expect(described_class::BUILDING_COLORS[:church]).to eq('#f0e68c')
    end
  end

  describe 'ROOM_COLORS constant' do
    it 'has standard room colors' do
      expect(described_class::ROOM_COLORS[:standard]).to eq('#2d3748')
      expect(described_class::ROOM_COLORS[:exterior]).to eq('#4a5568')
    end

    it 'has special room colors' do
      expect(described_class::ROOM_COLORS[:water]).to eq('#3182ce')
      expect(described_class::ROOM_COLORS[:sky]).to eq('#90cdf4')
      expect(described_class::ROOM_COLORS[:underground]).to eq('#1a202c')
    end
  end
end
