# frozen_string_literal: true

require 'spec_helper'

RSpec.describe GradientService do
  describe '.valid_hex?' do
    it 'accepts 6-character hex codes with hash' do
      expect(described_class.valid_hex?('#ff0000')).to be true
      expect(described_class.valid_hex?('#00FF00')).to be true
      expect(described_class.valid_hex?('#123456')).to be true
    end

    it 'accepts 3-character hex codes with hash' do
      expect(described_class.valid_hex?('#f00')).to be true
      expect(described_class.valid_hex?('#0F0')).to be true
    end

    it 'accepts hex codes without hash' do
      expect(described_class.valid_hex?('ff0000')).to be true
      expect(described_class.valid_hex?('f00')).to be true
    end

    it 'rejects invalid hex codes' do
      expect(described_class.valid_hex?('#gg0000')).to be false
      expect(described_class.valid_hex?('#12345')).to be false
      expect(described_class.valid_hex?('not-a-color')).to be false
      expect(described_class.valid_hex?(nil)).to be false
    end
  end

  describe '.normalize_hex' do
    it 'adds hash if missing' do
      expect(described_class.normalize_hex('ff0000')).to eq('#ff0000')
    end

    it 'expands 3-char to 6-char' do
      expect(described_class.normalize_hex('#f00')).to eq('#ff0000')
      expect(described_class.normalize_hex('0f0')).to eq('#00ff00')
    end

    it 'lowercases hex codes' do
      expect(described_class.normalize_hex('#FF0000')).to eq('#ff0000')
    end

    it 'returns nil for invalid codes' do
      expect(described_class.normalize_hex('not-valid')).to be_nil
    end
  end

  describe '.parse_codes' do
    it 'parses comma-separated hex codes' do
      result = described_class.parse_codes('#ff0000,#00ff00,#0000ff')
      expect(result).to eq(['#ff0000', '#00ff00', '#0000ff'])
    end

    it 'handles codes without hash' do
      result = described_class.parse_codes('ff0000,00ff00')
      expect(result).to eq(['#ff0000', '#00ff00'])
    end

    it 'handles 3-char codes' do
      result = described_class.parse_codes('#f00,#0f0')
      expect(result).to eq(['#ff0000', '#00ff00'])
    end

    it 'filters out invalid codes' do
      result = described_class.parse_codes('#ff0000,invalid,#00ff00')
      expect(result).to eq(['#ff0000', '#00ff00'])
    end

    it 'handles spaces around codes' do
      result = described_class.parse_codes('#ff0000 , #00ff00')
      expect(result).to eq(['#ff0000', '#00ff00'])
    end

    it 'returns empty array for nil input' do
      expect(described_class.parse_codes(nil)).to eq([])
    end
  end

  describe '.apply' do
    let(:colors) { ['#ff0000', '#00ff00'] }

    context 'with empty or invalid input' do
      it 'returns original text for empty colors' do
        expect(described_class.apply('Hello', [])).to eq('Hello')
      end

      it 'returns original text for nil text' do
        expect(described_class.apply(nil, colors)).to be_nil
      end

      it 'returns original text for empty string' do
        expect(described_class.apply('', colors)).to eq('')
      end

      it 'returns original text for single color' do
        expect(described_class.apply('Hello', ['#ff0000'])).to eq('Hello')
      end
    end

    context 'with smooth gradient (default)' do
      it 'wraps each character in span with interpolated color' do
        result = described_class.apply('AB', colors)
        expect(result).to include('<span style="color:#ff0000">A</span>')
        expect(result).to include('<span style="color:#00ff00">B</span>')
      end

      it 'preserves spaces without coloring' do
        result = described_class.apply('A B', colors)
        expect(result).to include(' ')
        # Only 2 spans for A and B, space is preserved without span
        expect(result.scan(/<span/).count).to eq(2)
      end

      it 'interpolates colors for longer text' do
        result = described_class.apply('Hello', colors)
        expect(result).to include('<span style="color:#ff0000">H</span>')
        expect(result).to include('<span style="color:#00ff00">o</span>')
        # Middle characters should have intermediate colors
        expect(result.scan(/<span/).count).to eq(5)
      end

      it 'escapes HTML special characters' do
        result = described_class.apply('<>', colors)
        expect(result).to include('&lt;')
        expect(result).to include('&gt;')
      end
    end

    context 'with sharp gradient (fast mode)' do
      it 'divides text into sections by color' do
        result = described_class.apply('ABCD', colors, fast: true)
        # With 2 colors and 4 chars, first 2 get color1, last 2 get color2
        expect(result).to include('<span style="color:#ff0000">A</span>')
        expect(result).to include('<span style="color:#ff0000">B</span>')
        expect(result).to include('<span style="color:#00ff00">C</span>')
        expect(result).to include('<span style="color:#00ff00">D</span>')
      end

      it 'handles more colors than characters' do
        result = described_class.apply('AB', ['#ff0000', '#00ff00', '#0000ff'], fast: true)
        expect(result).to include('<span style="color:#ff0000">A</span>')
        expect(result).to include('<span style="color:#00ff00">B</span>')
      end
    end

    context 'with three or more colors' do
      let(:rainbow) { ['#ff0000', '#00ff00', '#0000ff'] }

      it 'interpolates through all colors smoothly' do
        result = described_class.apply('ABC', rainbow)
        expect(result).to include('<span style="color:#ff0000">A</span>')
        expect(result).to include('<span style="color:#00ff00">B</span>')
        expect(result).to include('<span style="color:#0000ff">C</span>')
      end

      it 'divides into sections for sharp mode' do
        result = described_class.apply('ABCDEF', rainbow, fast: true)
        # 6 chars, 3 colors = 2 chars per color
        expect(result.scan(/color:#ff0000/).count).to eq(2)
        expect(result.scan(/color:#00ff00/).count).to eq(2)
        expect(result.scan(/color:#0000ff/).count).to eq(2)
      end
    end
  end
end
