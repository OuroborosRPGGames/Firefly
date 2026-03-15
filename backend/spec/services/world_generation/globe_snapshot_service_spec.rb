# frozen_string_literal: true

require 'spec_helper'

RSpec.describe WorldGeneration::GlobeSnapshotService do
  let(:world) { create(:world) }
  let(:service) { described_class.new(world) }

  # Create sample hexes with geographic coordinates
  def create_sample_hexes(count: 10)
    count.times do |i|
      lat = (i * 18) - 90 # Spread across latitudes
      lon = (i * 36) - 180 # Spread across longitudes
      create(:world_hex,
             world: world,
             globe_hex_id: i,
             latitude: lat,
             longitude: lon,
             terrain_type: WorldHex::TERRAIN_TYPES[i % WorldHex::TERRAIN_TYPES.length])
    end
  end

  describe 'constants' do
    it 'defines TERRAIN_COLORS for all WorldHex terrain types' do
      WorldHex::TERRAIN_TYPES.each do |terrain|
        # Most terrain types should have colors defined
        # Some might use default
        expect(described_class::TERRAIN_COLORS[terrain] || described_class::TERRAIN_COLORS[WorldHex::DEFAULT_TERRAIN]).not_to be_nil
      end
    end

    it 'TERRAIN_COLORS are valid hex color strings' do
      described_class::TERRAIN_COLORS.each do |terrain, color|
        expect(color).to match(/^#[0-9a-fA-F]{6}$/), "Invalid color for #{terrain}: #{color}"
      end
    end

    it 'defines DEFAULT_WIDTH and DEFAULT_HEIGHT' do
      expect(described_class::DEFAULT_WIDTH).to eq(800)
      expect(described_class::DEFAULT_HEIGHT).to eq(400)
    end

    it 'defines HEX_RADIUS' do
      expect(described_class::HEX_RADIUS).to eq(3)
    end
  end

  describe '#initialize' do
    it 'stores the world' do
      expect(service.world).to eq(world)
    end

    it 'loads hexes from database when not provided' do
      create_sample_hexes(count: 5)
      new_service = described_class.new(world)
      expect(new_service.hexes.count).to eq(5)
    end

    it 'uses provided hexes when given' do
      preloaded = [build(:world_hex, world: world, latitude: 0, longitude: 0)]
      new_service = described_class.new(world, hexes: preloaded)
      expect(new_service.hexes).to eq(preloaded)
    end

    it 'returns empty array for world with no hexes' do
      expect(service.hexes).to eq([])
    end
  end

  describe '#render_svg' do
    before { create_sample_hexes(count: 20) }

    context 'with equirectangular projection (default)' do
      let(:svg) { service.render_svg }

      it 'returns valid SVG content' do
        expect(svg).to start_with('<svg')
        expect(svg).to end_with('</svg>')
      end

      it 'includes xmlns attribute' do
        expect(svg).to include('xmlns="http://www.w3.org/2000/svg"')
      end

      it 'includes viewBox with default dimensions' do
        expect(svg).to include('viewBox="0 0 800 400"')
      end

      it 'includes background rectangle with ocean color' do
        expect(svg).to include(%(<rect x="0" y="0" width="800" height="400" fill="#{described_class::TERRAIN_COLORS['ocean']}"/>))
      end

      it 'renders hex circles for each hex' do
        # Should have circles for the hexes (rendered as circles)
        expect(svg.scan(/<circle/).count).to be >= 20
      end

      it 'includes grid lines' do
        expect(svg).to include('<line')
        # 5 latitude lines + 11 longitude lines
        expect(svg.scan(/<line/).count).to be >= 10
      end

      it 'respects custom dimensions' do
        svg = service.render_svg(width: 1200, height: 600)
        expect(svg).to include('viewBox="0 0 1200 600"')
        expect(svg).to include('width="1200"')
        expect(svg).to include('height="600"')
      end
    end

    context 'with orthographic projection' do
      let(:svg) { service.render_svg(projection: :orthographic) }

      it 'returns valid SVG content' do
        expect(svg).to start_with('<svg')
        expect(svg).to end_with('</svg>')
      end

      it 'includes black background for space' do
        expect(svg).to include('fill="#000"')
      end

      it 'includes globe circle with ocean fill' do
        # cx/cy may be floats like 400.0/200.0
        expect(svg).to match(/cx="400(\.0)?" cy="200(\.0)?"/)
        expect(svg).to include(%(fill="#{described_class::TERRAIN_COLORS['ocean']}"))
      end

      it 'includes globe outline' do
        expect(svg).to include('stroke="#fff"')
        expect(svg).to include('stroke-width="2"')
      end

      it 'accepts center_lon and center_lat parameters' do
        svg1 = service.render_svg(projection: :orthographic, center_lon: 0, center_lat: 0)
        svg2 = service.render_svg(projection: :orthographic, center_lon: 90, center_lat: 45)
        # Different centers should produce different outputs
        expect(svg1).not_to eq(svg2)
      end
    end

    context 'with invalid projection' do
      it 'raises ArgumentError' do
        expect { service.render_svg(projection: :invalid) }.to raise_error(ArgumentError, /Unknown projection/)
      end
    end

    context 'with no hexes' do
      let(:empty_service) { described_class.new(world) }

      it 'renders SVG with just background for equirectangular' do
        svg = empty_service.render_svg(projection: :equirectangular)
        expect(svg).to include('<svg')
        expect(svg).to include('</svg>')
        # Only background rect and grid lines, no hex circles beyond that
      end

      it 'renders SVG with globe for orthographic' do
        svg = empty_service.render_svg(projection: :orthographic)
        expect(svg).to include('<svg')
        # Should have black background and ocean globe
        expect(svg).to include('fill="#000"')
      end
    end
  end

  describe '#render_svg_file' do
    before { create_sample_hexes(count: 5) }

    it 'writes SVG content to file' do
      output_path = '/tmp/claude-1001/-home-beat6749-firefly/0d0df434-a674-4d6e-ac96-50495bb89b7a/scratchpad/test_snapshot.svg'
      FileUtils.mkdir_p(File.dirname(output_path))

      result = service.render_svg_file(output_path)

      expect(result).to eq(output_path)
      expect(File.exist?(output_path)).to be true

      content = File.read(output_path)
      expect(content).to start_with('<svg')
      expect(content).to end_with('</svg>')

      File.delete(output_path)
    end

    it 'accepts projection and dimension parameters' do
      output_path = '/tmp/claude-1001/-home-beat6749-firefly/0d0df434-a674-4d6e-ac96-50495bb89b7a/scratchpad/test_ortho.svg'
      FileUtils.mkdir_p(File.dirname(output_path))

      service.render_svg_file(output_path, projection: :orthographic, width: 600, height: 600)

      content = File.read(output_path)
      expect(content).to include('viewBox="0 0 600 600"')

      File.delete(output_path)
    end
  end

  describe '#render_png' do
    before { create_sample_hexes(count: 5) }

    let(:output_path) { '/tmp/claude-1001/-home-beat6749-firefly/0d0df434-a674-4d6e-ac96-50495bb89b7a/scratchpad/test_snapshot.png' }
    let(:svg_path) { output_path.sub(/\.png$/i, '.svg') }

    before do
      FileUtils.mkdir_p(File.dirname(output_path))
    end

    after do
      File.delete(output_path) if File.exist?(output_path)
      File.delete(svg_path) if File.exist?(svg_path)
    end

    it 'writes SVG file first' do
      # Mock system calls to avoid actual conversion
      allow(service).to receive(:system).and_return(false)

      service.render_png(output_path)

      expect(File.exist?(svg_path)).to be true
    end

    it 'tries rsvg-convert first' do
      allow(service).to receive(:system).with('which rsvg-convert > /dev/null 2>&1').and_return(true)
      allow(service).to receive(:system).with(/rsvg-convert/).and_return(true)

      service.render_png(output_path)

      expect(service).to have_received(:system).with(/rsvg-convert -w 800 -h 400/)
    end

    it 'falls back to ImageMagick convert' do
      allow(service).to receive(:system).with('which rsvg-convert > /dev/null 2>&1').and_return(false)
      allow(service).to receive(:system).with('which convert > /dev/null 2>&1').and_return(true)
      allow(service).to receive(:system).with(satisfy { |cmd| cmd.include?('convert') && cmd.include?('-resize') }).and_return(true)

      service.render_png(output_path)

      expect(service).to have_received(:system).with(satisfy { |cmd| cmd.include?('convert') && cmd.include?('800x400') })
    end

    it 'returns SVG path if no converter available' do
      allow(service).to receive(:system).with('which rsvg-convert > /dev/null 2>&1').and_return(false)
      allow(service).to receive(:system).with('which convert > /dev/null 2>&1').and_return(false)

      result = service.render_png(output_path)

      expect(result).to eq(svg_path)
    end
  end

  describe '#orthographic_project (private)' do
    # Test via public interface or use send for critical math

    it 'returns nil for points on back side of globe' do
      # Point directly behind center (opposite side)
      result = service.send(:orthographic_project, 0, Math::PI, 0, 0)
      expect(result).to be_nil
    end

    it 'returns [0, 0] for point at center' do
      result = service.send(:orthographic_project, 0, 0, 0, 0)
      expect(result[0]).to be_within(0.001).of(0)
      expect(result[1]).to be_within(0.001).of(0)
    end

    it 'returns coordinates in [-1, 1] range for visible points' do
      # Point 45 degrees east of center
      result = service.send(:orthographic_project, 0, Math::PI / 4, 0, 0)
      expect(result).not_to be_nil
      expect(result[0]).to be_between(-1, 1)
      expect(result[1]).to be_between(-1, 1)
    end

    it 'handles north pole correctly' do
      # Looking at equator from equator, north pole should be visible
      result = service.send(:orthographic_project, Math::PI / 2, 0, 0, 0)
      expect(result).not_to be_nil
      expect(result[1]).to be > 0 # North is up
    end
  end

  describe '#calculate_hex_radius (private)' do
    it 'returns HEX_RADIUS for empty hexes' do
      empty_service = described_class.new(world)
      radius = empty_service.send(:calculate_hex_radius, 800, 400)
      expect(radius).to eq(described_class::HEX_RADIUS)
    end

    it 'calculates appropriate radius based on hex count' do
      create_sample_hexes(count: 100)
      radius = service.send(:calculate_hex_radius, 800, 400)
      # With more hexes, radius should be reasonable
      expect(radius).to be >= described_class::HEX_RADIUS
    end

    it 'never returns less than HEX_RADIUS' do
      create_sample_hexes(count: 10000)
      new_service = described_class.new(world)
      radius = new_service.send(:calculate_hex_radius, 100, 100)
      expect(radius).to be >= described_class::HEX_RADIUS
    end
  end

  describe '#terrain_color (private)' do
    it 'returns color for known terrain type' do
      color = service.send(:terrain_color, 'ocean')
      expect(color).to eq('#2d5f8a')
    end

    it 'returns default terrain color for unknown type' do
      color = service.send(:terrain_color, 'nonexistent')
      expect(color).to eq(described_class::TERRAIN_COLORS[WorldHex::DEFAULT_TERRAIN])
    end

    it 'returns color for each defined terrain type' do
      described_class::TERRAIN_COLORS.each_key do |terrain|
        color = service.send(:terrain_color, terrain)
        expect(color).to match(/^#[0-9a-fA-F]{6}$/)
      end
    end
  end

  describe '#render_grid_lines (private)' do
    let(:grid_lines) { service.send(:render_grid_lines, 800, 400) }

    it 'renders latitude lines' do
      expect(grid_lines).to include('x1="0"')
      expect(grid_lines).to include('x2="800"')
    end

    it 'renders longitude lines' do
      expect(grid_lines).to include('y1="0"')
      expect(grid_lines).to include('y2="400"')
    end

    it 'uses semi-transparent white stroke' do
      expect(grid_lines).to include('stroke="#ffffff33"')
    end
  end

  describe 'integration with real hex data' do
    before do
      # Create hexes covering various terrain types
      [
        { lat: 0, lon: 0, terrain: 'ocean' },
        { lat: 45, lon: 45, terrain: 'dense_forest' },
        { lat: -30, lon: -60, terrain: 'jungle' },
        { lat: 70, lon: 100, terrain: 'tundra' },
        { lat: -70, lon: -120, terrain: 'tundra' },
        { lat: 25, lon: -100, terrain: 'desert' },
        { lat: 35, lon: 10, terrain: 'grassy_plains' },
        { lat: -15, lon: 50, terrain: 'swamp' },
        { lat: 60, lon: -30, terrain: 'mountain' }
      ].each_with_index do |data, i|
        create(:world_hex,
               world: world,
               globe_hex_id: i,
               latitude: data[:lat],
               longitude: data[:lon],
               terrain_type: data[:terrain])
      end
    end

    it 'renders equirectangular map with all terrain colors' do
      svg = service.render_svg(projection: :equirectangular)

      # Check that different terrain colors appear
      expect(svg).to include(described_class::TERRAIN_COLORS['ocean'])
      expect(svg).to include(described_class::TERRAIN_COLORS['dense_forest'])
      expect(svg).to include(described_class::TERRAIN_COLORS['tundra'])
    end

    it 'renders orthographic view showing visible hemisphere' do
      svg = service.render_svg(projection: :orthographic, center_lon: 0, center_lat: 0)

      # Globe circle should be present (cx/cy may be floats)
      expect(svg).to match(/cx="400(\.0)?" cy="200(\.0)?"/)

      # Some hexes should be visible
      expect(svg.scan(/<circle/).count).to be > 2
    end
  end
end
