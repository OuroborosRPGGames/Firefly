# frozen_string_literal: true

require 'spec_helper'

# These tests implement the prevention strategies from
# docs/solutions/GRADIENT-TEXT-SYSTEM-PREVENTION-STRATEGIES.md

RSpec.describe GradientService, 'prevention strategies' do
  # =========================================
  # 1. Color Space Conversion Accuracy
  # =========================================

  describe 'color space conversions' do
    describe 'D65 reference white constants' do
      it 'uses correct REF_X value' do
        expect(described_class::REF_X).to be_within(0.001).of(95.047)
      end

      it 'uses correct REF_Y value' do
        expect(described_class::REF_Y).to eq(100.0)
      end

      it 'uses correct REF_Z value' do
        expect(described_class::REF_Z).to be_within(0.001).of(108.883)
      end
    end

    describe 'round-trip conversion accuracy' do
      [
        { hex: '#000000', name: 'pure black' },
        { hex: '#ffffff', name: 'pure white' },
        { hex: '#ff0000', name: 'saturated red' },
        { hex: '#00ff00', name: 'saturated green' },
        { hex: '#0000ff', name: 'saturated blue' }
      ].each do |test_case|
        it "converts #{test_case[:name]} accurately" do
          hex = test_case[:hex]
          lab = described_class.hex_to_lab(hex)
          result = described_class.lab_to_hex(*lab)
          expect(result).to eq(hex)
        end
      end

      it 'converts mid-gray within tolerance' do
        hex = '#808080'
        lab = described_class.hex_to_lab(hex)
        result = described_class.lab_to_hex(*lab)

        # Allow 1-value tolerance due to floating point rounding
        r1, g1, b1 = described_class.send(:hex_to_rgb, hex)
        r2, g2, b2 = described_class.send(:hex_to_rgb, result)

        expect((r1 - r2).abs).to be <= 1
        expect((g1 - g2).abs).to be <= 1
        expect((b1 - b2).abs).to be <= 1
      end
    end

    describe 'Lab interpolation hue handling' do
      it 'takes shortest path around hue circle for red to magenta' do
        red = '#ff0000'
        magenta = '#ff00ff'
        mid = described_class.interpolate_lab(red, magenta, 0.5)

        # Should stay on red/magenta side, not go through cyan
        r, _g, b = described_class.send(:hex_to_rgb, mid)
        expect(r).to be > 200 # Red should be high
      end

      it 'takes shortest path for blue to cyan' do
        blue = '#0000ff'
        cyan = '#00ffff'
        mid = described_class.interpolate_lab(blue, cyan, 0.5)

        r, _g, _b = described_class.send(:hex_to_rgb, mid)
        expect(r).to be < 50 # Should not include red
      end
    end
  end

  # =========================================
  # 2. Easing System Correctness
  # =========================================

  describe 'easing system' do
    describe '.apply_easing with linear (100)' do
      [0.0, 0.25, 0.5, 0.75, 1.0].each do |t|
        it "returns #{t} unchanged" do
          expect(described_class.apply_easing(t, 100)).to eq(t)
        end
      end
    end

    describe '.apply_easing with ease-in-out (200)' do
      it 'returns 0 at t=0' do
        expect(described_class.apply_easing(0.0, 200)).to eq(0.0)
      end

      it 'returns 1 at t=1' do
        expect(described_class.apply_easing(1.0, 200)).to eq(1.0)
      end

      it 'is slower at start (eased < t at 0.25)' do
        result = described_class.apply_easing(0.25, 200)
        expect(result).to be < 0.25
      end

      it 'equals approximately 0.5 at midpoint' do
        result = described_class.apply_easing(0.5, 200)
        expect(result).to be_within(0.01).of(0.5)
      end

      it 'is faster at end (eased > t at 0.75)' do
        result = described_class.apply_easing(0.75, 200)
        expect(result).to be > 0.75
      end
    end

    describe '.apply_easing with inverse (50)' do
      it 'returns 0 at t=0' do
        expect(described_class.apply_easing(0.0, 50)).to eq(0.0)
      end

      it 'returns 1 at t=1' do
        expect(described_class.apply_easing(1.0, 50)).to eq(1.0)
      end

      it 'is slower in middle (eased < t at 0.25) due to faster-at-edges curve' do
        result = described_class.apply_easing(0.25, 50)
        # Inverse easing (50) is faster at edges, slower in middle
        expect(result).to be < 0.25
      end
    end

    describe 'boundary conditions for all easing values' do
      [50, 75, 100, 125, 150, 175, 200].each do |easing|
        context "easing value #{easing}" do
          it 'returns 0 when t=0' do
            expect(described_class.apply_easing(0.0, easing)).to eq(0.0)
          end

          it 'returns 1 when t=1' do
            expect(described_class.apply_easing(1.0, easing)).to eq(1.0)
          end

          it 'returns values between 0 and 1 for intermediate t' do
            [0.1, 0.25, 0.5, 0.75, 0.9].each do |t|
              result = described_class.apply_easing(t, easing)
              expect(result).to be_between(0.0, 1.0).inclusive,
                               "t=#{t}, easing=#{easing} returned #{result}"
            end
          end
        end
      end
    end

    describe 'easing index mapping in gradient generation' do
      it 'applies easing only at odd-indexed color stops' do
        colors = ['#ff0000', '#ffff00', '#00ff00', '#00ffff', '#0000ff']
        easings = [150, 175] # For stops at index 1 and 3

        result = described_class.generate_ciede2000_colors(colors, 20, easings)

        expect(result.length).to eq(20)
        result.each do |color|
          expect(color).to match(/^#[0-9a-f]{6}$/)
        end
      end

      it 'uses default easing (100) when easings array is empty' do
        colors = ['#ff0000', '#00ff00']

        result_with_explicit_100 = described_class.generate_ciede2000_colors(colors, 10, [100])
        result_with_empty = described_class.generate_ciede2000_colors(colors, 10, [])

        expect(result_with_explicit_100).to eq(result_with_empty)
      end

      it 'handles fewer easings than expected stops' do
        colors = ['#ff0000', '#00ff00', '#0000ff', '#ffff00', '#ff00ff']
        easings = [120] # Only one easing for first odd stop

        result = described_class.generate_ciede2000_colors(colors, 15, easings)

        expect(result.length).to eq(15)
        # Should not raise, defaults to 100 for missing easings
      end
    end
  end

  # =========================================
  # 3. API Data Validation (via GradientService)
  # =========================================

  describe 'input validation' do
    describe '.valid_hex?' do
      context 'valid hex codes' do
        ['#ff0000', '#FF0000', '#f00', '#F00', 'ff0000', 'f00'].each do |hex|
          it "accepts #{hex.inspect}" do
            expect(described_class.valid_hex?(hex)).to be true
          end
        end
      end

      context 'invalid hex codes' do
        ['#gg0000', '#12345', 'not-a-color', nil, '', '#', '#1234567'].each do |hex|
          it "rejects #{hex.inspect}" do
            expect(described_class.valid_hex?(hex)).to be false
          end
        end
      end
    end

    describe '.normalize_hex' do
      it 'adds hash prefix if missing' do
        expect(described_class.normalize_hex('ff0000')).to eq('#ff0000')
      end

      it 'expands 3-char to 6-char' do
        expect(described_class.normalize_hex('#f00')).to eq('#ff0000')
        expect(described_class.normalize_hex('0f0')).to eq('#00ff00')
      end

      it 'lowercases hex codes' do
        expect(described_class.normalize_hex('#FF00AA')).to eq('#ff00aa')
      end

      it 'returns nil for invalid codes' do
        expect(described_class.normalize_hex('not-valid')).to be_nil
        expect(described_class.normalize_hex(nil)).to be_nil
      end
    end

    describe '.parse_codes' do
      it 'parses comma-separated valid hex codes' do
        result = described_class.parse_codes('#ff0000,#00ff00,#0000ff')
        expect(result).to eq(['#ff0000', '#00ff00', '#0000ff'])
      end

      it 'filters out invalid codes' do
        result = described_class.parse_codes('#ff0000,invalid,#00ff00')
        expect(result).to eq(['#ff0000', '#00ff00'])
      end

      it 'handles spaces around codes' do
        result = described_class.parse_codes('#ff0000 , #00ff00')
        expect(result).to eq(['#ff0000', '#00ff00'])
      end

      it 'normalizes all codes' do
        result = described_class.parse_codes('FF0000,0F0,#0000ff')
        expect(result).to eq(['#ff0000', '#00ff00', '#0000ff'])
      end

      it 'returns empty array for nil input' do
        expect(described_class.parse_codes(nil)).to eq([])
      end

      it 'returns empty array for empty string' do
        expect(described_class.parse_codes('')).to eq([])
      end
    end
  end

  # =========================================
  # 4. CIEDE2000 Gradient Application
  # =========================================

  describe '.apply_ciede2000' do
    let(:colors) { ['#ff0000', '#00ff00', '#0000ff'] }

    it 'returns original text for empty colors' do
      expect(described_class.apply_ciede2000('Hello', [])).to eq('Hello')
    end

    it 'returns original text for nil text' do
      expect(described_class.apply_ciede2000(nil, colors)).to be_nil
    end

    it 'returns original text for empty string' do
      expect(described_class.apply_ciede2000('', colors)).to eq('')
    end

    it 'returns original text for single color' do
      expect(described_class.apply_ciede2000('Hello', ['#ff0000'])).to eq('Hello')
    end

    it 'wraps each visible character in span' do
      result = described_class.apply_ciede2000('AB', ['#ff0000', '#0000ff'])
      expect(result).to include('<span style="color:')
      expect(result.scan(/<span/).count).to eq(2)
    end

    it 'preserves whitespace without wrapping' do
      result = described_class.apply_ciede2000('A B', ['#ff0000', '#0000ff'])
      expect(result).to include(' ')
      # Only 2 spans for visible chars
      expect(result.scan(/<span/).count).to eq(2)
    end

    it 'escapes HTML special characters' do
      result = described_class.apply_ciede2000('<>&"', colors)
      expect(result).to include('&lt;')
      expect(result).to include('&gt;')
      expect(result).to include('&amp;')
      expect(result).to include('&quot;')
    end

    it 'applies easing when provided' do
      text = 'Hello World'
      no_easing = described_class.apply_ciede2000(text, colors, easings: [])
      with_easing = described_class.apply_ciede2000(text, colors, easings: [150])

      # Results should be different due to easing
      expect(no_easing).not_to eq(with_easing)
    end
  end
end
