# frozen_string_literal: true

require 'spec_helper'

RSpec.describe CanvasHelper do
  describe 'module structure' do
    it 'is a module' do
      expect(described_class).to be_a(Module)
    end

    it 'includes StringHelper' do
      expect(described_class.included_modules).to include(StringHelper)
    end
  end

  describe 'constants' do
    it 'defines DIRECTION_ARROWS' do
      expect(described_class::DIRECTION_ARROWS).to be_a(Hash)
      expect(described_class::DIRECTION_ARROWS).to be_frozen
    end

    it 'DIRECTION_ARROWS includes cardinal directions' do
      arrows = described_class::DIRECTION_ARROWS
      expect(arrows['north']).to eq('↑')
      expect(arrows['south']).to eq('↓')
      expect(arrows['east']).to eq('→')
      expect(arrows['west']).to eq('←')
    end

    it 'DIRECTION_ARROWS includes ordinal directions' do
      arrows = described_class::DIRECTION_ARROWS
      expect(arrows['northeast']).to eq('↗')
      expect(arrows['northwest']).to eq('↖')
      expect(arrows['southeast']).to eq('↘')
      expect(arrows['southwest']).to eq('↙')
    end

    it 'DIRECTION_ARROWS includes vertical directions' do
      arrows = described_class::DIRECTION_ARROWS
      expect(arrows['up']).to eq('⇑')
      expect(arrows['down']).to eq('⇓')
    end

    it 'DIRECTION_ARROWS includes short forms' do
      arrows = described_class::DIRECTION_ARROWS
      expect(arrows['n']).to eq('↑')
      expect(arrows['s']).to eq('↓')
      expect(arrows['e']).to eq('→')
      expect(arrows['w']).to eq('←')
    end

    it 'defines ROOM_INDICATORS' do
      expect(described_class::ROOM_INDICATORS).to be_a(Hash)
      expect(described_class::ROOM_INDICATORS).to be_frozen
    end

    it 'ROOM_INDICATORS includes expected types' do
      indicators = described_class::ROOM_INDICATORS
      expect(indicators[:exit]).to eq('v')
      expect(indicators[:entrance]).to eq('^')
      expect(indicators[:monster]).to eq('M')
      expect(indicators[:treasure]).to eq('$')
      expect(indicators[:trap]).to eq('T')
    end

    it 'defines TRANSPORT_INDICATORS' do
      expect(described_class::TRANSPORT_INDICATORS).to be_a(Hash)
      expect(described_class::TRANSPORT_INDICATORS).to be_frozen
    end

    it 'TRANSPORT_INDICATORS includes transport types' do
      indicators = described_class::TRANSPORT_INDICATORS
      expect(indicators[:port]).to eq('⚓')
      expect(indicators[:train_station]).to eq('🚂')
      expect(indicators[:ferry_terminal]).to eq('⛴')
    end
  end

  describe '.sanitize_text' do
    it 'sanitizes text for canvas commands' do
      result = described_class.sanitize_text('<script>alert(1)</script>')
      expect(result).not_to include('<script>')
    end

    it 'handles nil input' do
      result = described_class.sanitize_text(nil)
      expect(result).to be_a(String)
    end
  end

  describe '.truncate_name' do
    it 'returns empty string for nil' do
      expect(described_class.truncate_name(nil)).to eq('')
    end

    it 'returns name unchanged if under max length' do
      expect(described_class.truncate_name('Short', 15)).to eq('Short')
    end

    it 'truncates and adds ellipsis for long names' do
      result = described_class.truncate_name('This is a very long name', 15)
      expect(result).to end_with('...')
      expect(result.length).to eq(15)
    end

    it 'uses default max_length of 15' do
      result = described_class.truncate_name('A very long character name here')
      expect(result.length).to eq(15)
    end
  end

  describe '.direction_arrow' do
    it 'returns arrow for valid direction' do
      expect(described_class.direction_arrow('north')).to eq('↑')
      expect(described_class.direction_arrow('south')).to eq('↓')
    end

    it 'handles case insensitivity' do
      expect(described_class.direction_arrow('NORTH')).to eq('↑')
      expect(described_class.direction_arrow('North')).to eq('↑')
    end

    it 'returns empty string for nil' do
      expect(described_class.direction_arrow(nil)).to eq('')
    end

    it 'returns empty string for unknown direction' do
      expect(described_class.direction_arrow('diagonal')).to eq('')
    end
  end

  describe '.opposite_direction' do
    it 'returns opposite for cardinal directions' do
      expect(described_class.opposite_direction('north')).to eq('south')
      expect(described_class.opposite_direction('south')).to eq('north')
      expect(described_class.opposite_direction('east')).to eq('west')
      expect(described_class.opposite_direction('west')).to eq('east')
    end

    it 'returns opposite for ordinal directions' do
      expect(described_class.opposite_direction('northeast')).to eq('southwest')
      expect(described_class.opposite_direction('northwest')).to eq('southeast')
      expect(described_class.opposite_direction('southeast')).to eq('northwest')
      expect(described_class.opposite_direction('southwest')).to eq('northeast')
    end

    it 'returns opposite for vertical directions' do
      expect(described_class.opposite_direction('up')).to eq('down')
      expect(described_class.opposite_direction('down')).to eq('up')
    end

    it 'returns opposite for in/out' do
      expect(described_class.opposite_direction('in')).to eq('out')
      expect(described_class.opposite_direction('out')).to eq('in')
    end

    it 'returns original for unknown direction' do
      expect(described_class.opposite_direction('unknown')).to eq('unknown')
    end
  end

  describe '.direction_position' do
    it 'returns position for cardinal directions' do
      north = described_class.direction_position('north')
      expect(north[:x]).to eq(0.5)
      expect(north[:y]).to eq(0.15)

      south = described_class.direction_position('south')
      expect(south[:y]).to eq(0.85)
    end

    it 'returns centered position for unknown direction' do
      unknown = described_class.direction_position('unknown')
      expect(unknown[:x]).to eq(0.5)
      expect(unknown[:y]).to eq(0.5)
    end
  end

  describe '.direction_to_canvas_coords' do
    it 'calculates canvas coordinates for direction' do
      x, y = described_class.direction_to_canvas_coords('north', 200, 200)
      expect(x).to be_a(Integer)
      expect(y).to be_a(Integer)
      expect(y).to be < 100 # north should be near top
    end

    it 'respects padding constraints' do
      x, y = described_class.direction_to_canvas_coords('north', 200, 200, padding: 50)
      expect(x).to be >= 50
      expect(y).to be >= 50
    end
  end

  describe '.calculate_bounds' do
    it 'returns default bounds for empty elements' do
      bounds = described_class.calculate_bounds([])
      expect(bounds[:width]).to eq(100)
      expect(bounds[:height]).to eq(100)
    end

    it 'calculates bounds from element coordinates' do
      elements = [
        double(x: 10, y: 20),
        double(x: 50, y: 80)
      ]
      bounds = described_class.calculate_bounds(elements)
      expect(bounds[:min_x]).to eq(10)
      expect(bounds[:max_x]).to eq(50)
      expect(bounds[:min_y]).to eq(20)
      expect(bounds[:max_y]).to eq(80)
      expect(bounds[:width]).to eq(40)
      expect(bounds[:height]).to eq(60)
    end

    it 'supports custom coordinate methods' do
      elements = [
        double(grid_x: 0, grid_y: 0),
        double(grid_x: 10, grid_y: 10)
      ]
      bounds = described_class.calculate_bounds(elements, x_method: :grid_x, y_method: :grid_y)
      expect(bounds[:min_x]).to eq(0)
      expect(bounds[:max_x]).to eq(10)
    end
  end

  describe '.calculate_scale' do
    it 'calculates scale factors for content' do
      scale = described_class.calculate_scale(100, 100, 200, 200)
      expect(scale[:scale_x]).to be > 0
      expect(scale[:scale_y]).to be > 0
      expect(scale[:scale]).to be > 0
    end

    it 'returns unified scale as minimum of x and y' do
      scale = described_class.calculate_scale(100, 50, 200, 200, padding: 0)
      expect(scale[:scale]).to eq([scale[:scale_x], scale[:scale_y]].min)
    end

    it 'handles zero content dimensions' do
      scale = described_class.calculate_scale(0, 0, 200, 200)
      expect(scale[:scale]).to be > 0
    end
  end

  describe '.normalize_direction' do
    it 'expands abbreviations' do
      expect(described_class.normalize_direction('n')).to eq('north')
      expect(described_class.normalize_direction('sw')).to eq('southwest')
      expect(described_class.normalize_direction('d')).to eq('down')
    end

    it 'returns full direction names as-is' do
      expect(described_class.normalize_direction('north')).to eq('north')
      expect(described_class.normalize_direction('exit')).to eq('exit')
    end

    it 'returns nil for unknown input' do
      expect(described_class.normalize_direction(nil)).to be_nil
      expect(described_class.normalize_direction('blah')).to be_nil
    end
  end

  describe '.blend_colors' do
    it 'blends two colors at 0.0 ratio' do
      result = described_class.blend_colors('#ff0000', '#0000ff', 0.0)
      expect(result.downcase).to eq('#ff0000')
    end

    it 'blends two colors at 1.0 ratio' do
      result = described_class.blend_colors('#ff0000', '#0000ff', 1.0)
      expect(result.downcase).to eq('#0000ff')
    end

    it 'blends two colors at 0.5 ratio' do
      result = described_class.blend_colors('#ff0000', '#0000ff', 0.5)
      # Should be purple-ish
      expect(result).to start_with('#')
      expect(result.length).to eq(7)
    end

    it 'handles colors without # prefix' do
      result = described_class.blend_colors('ff0000', '0000ff', 0.5)
      expect(result).to start_with('#')
    end
  end
end
