# frozen_string_literal: true

require 'spec_helper'

return unless DB.table_exists?(:delve_traps)

RSpec.describe DelveTrap do
  describe 'constants' do
    it 'defines DIRECTIONS' do
      expect(described_class::DIRECTIONS).to eq(%w[north south east west])
    end

    it 'defines THEMES' do
      expect(described_class::THEMES).to include(:medieval, :gaslight, :modern, :near_future, :scifi)
    end
  end

  describe 'associations' do
    it 'belongs to delve_room' do
      expect(described_class.association_reflections[:delve_room]).not_to be_nil
    end
  end

  describe 'instance methods' do
    it 'defines triggered?' do
      expect(described_class.instance_methods).to include(:triggered?)
    end

    it 'defines disabled?' do
      expect(described_class.instance_methods).to include(:disabled?)
    end

    it 'defines active?' do
      expect(described_class.instance_methods).to include(:active?)
    end

    it 'defines trapped_at?' do
      expect(described_class.instance_methods).to include(:trapped_at?)
    end

    it 'defines generate_sequence' do
      expect(described_class.instance_methods).to include(:generate_sequence)
    end

    it 'defines safe_at?' do
      expect(described_class.instance_methods).to include(:safe_at?)
    end

    it 'defines trigger!' do
      expect(described_class.instance_methods).to include(:trigger!)
    end

    it 'defines disable!' do
      expect(described_class.instance_methods).to include(:disable!)
    end

    it 'defines description' do
      expect(described_class.instance_methods).to include(:description)
    end
  end

  describe 'class methods' do
    it 'defines generate_timings' do
      expect(described_class).to respond_to(:generate_timings)
    end

    it 'defines random_theme' do
      expect(described_class).to respond_to(:random_theme)
    end
  end

  describe '#trapped_at? behavior' do
    it 'returns true when tick is multiple of timing_a' do
      trap = described_class.new
      trap.values[:timing_a] = 3
      trap.values[:timing_b] = 7
      expect(trap.trapped_at?(6)).to be true
    end

    it 'returns true when tick is multiple of timing_b' do
      trap = described_class.new
      trap.values[:timing_a] = 3
      trap.values[:timing_b] = 7
      expect(trap.trapped_at?(14)).to be true
    end

    it 'returns false when tick is not multiple of either' do
      trap = described_class.new
      trap.values[:timing_a] = 3
      trap.values[:timing_b] = 7
      expect(trap.trapped_at?(5)).to be false
    end
  end

  describe '#safe_at? behavior' do
    it 'returns true for experienced when tick is safe' do
      trap = described_class.new
      trap.values[:timing_a] = 3
      trap.values[:timing_b] = 7
      expect(trap.safe_at?(5, experienced: true)).to be true
    end

    it 'checks next tick for inexperienced passage' do
      trap = described_class.new
      trap.values[:timing_a] = 3
      trap.values[:timing_b] = 7
      # Tick 5 is safe, tick 6 is trapped (multiple of 3)
      expect(trap.safe_at?(5, experienced: false)).to be false
    end
  end

  describe '.generate_timings' do
    it 'returns array of two integers' do
      result = described_class.generate_timings
      expect(result).to be_an(Array)
      expect(result.size).to eq(2)
      expect(result).to all(be_an(Integer))
    end

    it 'returns sorted coprime numbers' do
      result = described_class.generate_timings
      expect(result[0]).to be <= result[1]
      # GCD should be 1 for coprime numbers
      expect(result[0].gcd(result[1])).to eq(1)
    end
  end

  describe '.random_theme' do
    it 'returns a theme for medieval era' do
      theme = described_class.random_theme(:medieval)
      expect(described_class::THEMES[:medieval]).to include(theme)
    end

    it 'returns a theme for scifi era' do
      theme = described_class.random_theme(:scifi)
      expect(described_class::THEMES[:scifi]).to include(theme)
    end
  end
end
