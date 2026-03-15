# frozen_string_literal: true

require 'spec_helper'

RSpec.describe StatFormulaService do
  describe '.evaluate' do
    it 'handles simple addition' do
      expect(described_class.evaluate('STR + 5', { 'STR' => 14 })).to eq(19)
    end

    it 'handles simple subtraction' do
      expect(described_class.evaluate('STR - 5', { 'STR' => 14 })).to eq(9)
    end

    it 'handles multiplication' do
      expect(described_class.evaluate('STR * 2', { 'STR' => 14 })).to eq(28)
    end

    it 'handles division' do
      expect(described_class.evaluate('STR / 2', { 'STR' => 14 })).to eq(7)
    end

    it 'handles multiple stats' do
      expect(described_class.evaluate('STR + DEX', { 'STR' => 14, 'DEX' => 12 })).to eq(26)
    end

    it 'handles parentheses' do
      expect(described_class.evaluate('(STR + DEX) / 2', { 'STR' => 14, 'DEX' => 12 })).to eq(13)
    end

    it 'respects operator precedence' do
      # 14 + 12 * 2 = 14 + 24 = 38
      expect(described_class.evaluate('STR + DEX * 2', { 'STR' => 14, 'DEX' => 12 })).to eq(38)
    end

    it 'handles floor function' do
      expect(described_class.evaluate('floor(CON / 2)', { 'CON' => 15 })).to eq(7)
    end

    it 'handles ceil function' do
      expect(described_class.evaluate('ceil(CON / 2)', { 'CON' => 15 })).to eq(8)
    end

    it 'handles complex formulas' do
      result = described_class.evaluate('floor((STR + DEX) / 2) + 5', { 'STR' => 14, 'DEX' => 12 })
      expect(result).to eq(18)
    end

    it 'handles decimal numbers' do
      expect(described_class.evaluate('STR + 0.5', { 'STR' => 14 })).to eq(15)
    end

    it 'rounds result to integer' do
      expect(described_class.evaluate('STR / 3', { 'STR' => 14 })).to eq(5)
    end

    it 'is case insensitive for stat names' do
      expect(described_class.evaluate('str + 5', { 'STR' => 14 })).to eq(19)
    end

    it 'is case insensitive for functions' do
      expect(described_class.evaluate('FLOOR(STR / 2)', { 'STR' => 15 })).to eq(7)
    end

    it 'returns nil for unknown stats' do
      expect(described_class.evaluate('UNKNOWN + 5', {})).to be_nil
    end

    it 'returns 0 for empty formula' do
      expect(described_class.evaluate('', {})).to eq(0)
    end

    it 'handles whitespace' do
      expect(described_class.evaluate('  STR   +   5  ', { 'STR' => 14 })).to eq(19)
    end

    context 'security' do
      it 'rejects unknown functions' do
        expect(described_class.evaluate('system("ls")', {})).to be_nil
      end

      it 'rejects backticks' do
        expect(described_class.evaluate('`rm -rf /`', {})).to be_nil
      end

      it 'rejects eval-like patterns' do
        expect(described_class.evaluate('eval(STR)', { 'STR' => 14 })).to be_nil
      end

      it 'rejects special characters' do
        expect(described_class.evaluate('STR; system("ls")', { 'STR' => 14 })).to be_nil
      end
    end
  end

  describe '.validate' do
    it 'identifies valid formulas' do
      result = described_class.validate('STR + 5')
      expect(result[:valid]).to be true
    end

    it 'returns stat references' do
      result = described_class.validate('STR + DEX')
      expect(result[:stat_references]).to contain_exactly('STR', 'DEX')
    end

    it 'identifies invalid characters' do
      result = described_class.validate('STR; DROP TABLE')
      expect(result[:valid]).to be false
    end

    it 'identifies unknown functions' do
      result = described_class.validate('evil(STR)')
      expect(result[:valid]).to be false
    end

    it 'returns empty stat_references for empty formula' do
      result = described_class.validate('')
      expect(result[:stat_references]).to eq([])
    end
  end
end
