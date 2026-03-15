# frozen_string_literal: true

require 'spec_helper'

RSpec.describe DiceNotationService do
  describe '.roll' do
    it 'rolls dice and returns total' do
      # With rand seeded, we can test deterministically
      # But for now, just verify it returns an integer in expected range
      result = described_class.roll('1d6')
      expect(result).to be_between(1, 6)
    end

    it 'adds modifiers correctly' do
      result = described_class.roll('1d6+10')
      expect(result).to be_between(11, 16)
    end

    it 'subtracts modifiers correctly' do
      result = described_class.roll('1d6-1')
      expect(result).to be_between(0, 5)
    end

    it 'handles multiple dice' do
      result = described_class.roll('2d6')
      expect(result).to be_between(2, 12)
    end

    it 'returns 0 for invalid notation instead of crashing' do
      expect(described_class.roll('1d0')).to eq(0)
    end
  end

  describe '.parse' do
    it 'parses standard notation' do
      result = described_class.parse('2d8')
      expect(result[:count]).to eq(2)
      expect(result[:sides]).to eq(8)
      expect(result[:modifier]).to eq(0)
      expect(result[:valid]).to be true
      expect(result[:error]).to be_nil
    end

    it 'parses notation with positive modifier' do
      result = described_class.parse('1d6+3')
      expect(result[:count]).to eq(1)
      expect(result[:sides]).to eq(6)
      expect(result[:modifier]).to eq(3)
    end

    it 'parses notation with negative modifier' do
      result = described_class.parse('3d6-2')
      expect(result[:count]).to eq(3)
      expect(result[:sides]).to eq(6)
      expect(result[:modifier]).to eq(-2)
    end

    it 'defaults count to 1 when omitted' do
      result = described_class.parse('d20')
      expect(result[:count]).to eq(1)
      expect(result[:sides]).to eq(20)
    end

    it 'parses flat numbers as modifier only' do
      result = described_class.parse('5')
      expect(result[:count]).to eq(0)
      expect(result[:sides]).to eq(0)
      expect(result[:modifier]).to eq(5)
      expect(result[:valid]).to be true
    end

    it 'parses negative flat numbers' do
      result = described_class.parse('-3')
      expect(result[:count]).to eq(0)
      expect(result[:sides]).to eq(0)
      expect(result[:modifier]).to eq(-3)
    end

    it 'flags invalid notation with an error' do
      result = described_class.parse('invalid')
      expect(result[:count]).to eq(0)
      expect(result[:sides]).to eq(0)
      expect(result[:modifier]).to eq(0)
      expect(result[:valid]).to be false
      expect(result[:error]).not_to be_nil
    end

    it 'rejects zero-sided dice notation' do
      result = described_class.parse('1d0')
      expect(result[:valid]).to be false
      expect(result[:error]).to include('dice sides')
    end

    it 'handles uppercase notation' do
      result = described_class.parse('2D8')
      expect(result[:count]).to eq(2)
      expect(result[:sides]).to eq(8)
      expect(result[:valid]).to be true
    end

    it 'handles whitespace' do
      result = described_class.parse('  2d8  ')
      expect(result[:count]).to eq(2)
      expect(result[:sides]).to eq(8)
    end

    it 'handles whitespace around modifiers' do
      result = described_class.parse('2d8 + 3')
      expect(result[:count]).to eq(2)
      expect(result[:sides]).to eq(8)
      expect(result[:modifier]).to eq(3)
      expect(result[:valid]).to be true
    end
  end

  describe '#minimum' do
    it 'calculates minimum for standard dice' do
      service = described_class.new('3d6')
      expect(service.minimum).to eq(3) # 3 dice, each showing 1
    end

    it 'accounts for positive modifier' do
      service = described_class.new('2d6+5')
      expect(service.minimum).to eq(7) # 2 + 5
    end

    it 'accounts for negative modifier' do
      service = described_class.new('2d6-1')
      expect(service.minimum).to eq(1) # 2 - 1
    end

    it 'returns modifier for flat numbers' do
      service = described_class.new('10')
      expect(service.minimum).to eq(10)
    end
  end

  describe '#maximum' do
    it 'calculates maximum for standard dice' do
      service = described_class.new('3d6')
      expect(service.maximum).to eq(18) # 3 dice, each showing 6
    end

    it 'accounts for positive modifier' do
      service = described_class.new('2d6+5')
      expect(service.maximum).to eq(17) # 12 + 5
    end

    it 'accounts for negative modifier' do
      service = described_class.new('2d6-1')
      expect(service.maximum).to eq(11) # 12 - 1
    end

    it 'returns modifier for flat numbers' do
      service = described_class.new('10')
      expect(service.maximum).to eq(10)
    end
  end

  describe '#average' do
    it 'calculates average for 1d6' do
      service = described_class.new('1d6')
      expect(service.average).to eq(3.5)
    end

    it 'calculates average for 2d6' do
      service = described_class.new('2d6')
      expect(service.average).to eq(7.0)
    end

    it 'calculates average for d20' do
      service = described_class.new('d20')
      expect(service.average).to eq(10.5)
    end

    it 'accounts for modifiers' do
      service = described_class.new('1d6+2')
      expect(service.average).to eq(5.5) # 3.5 + 2
    end

    it 'returns modifier for flat numbers' do
      service = described_class.new('5')
      expect(service.average).to eq(5.0)
    end
  end

  describe 'integration: roll distribution' do
    it 'rolls within expected range over many iterations' do
      results = Array.new(100) { described_class.roll('2d6') }
      expect(results.min).to be >= 2
      expect(results.max).to be <= 12
    end

    it 'produces varying results (not deterministic)' do
      results = Array.new(20) { described_class.roll('1d20') }
      # Very unlikely all 20 rolls are the same
      expect(results.uniq.size).to be > 1
    end
  end
end
