# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Universe do
  describe 'associations' do
    let(:universe) { create(:universe) }

    it 'has many worlds' do
      world = create(:world, universe: universe)
      expect(universe.worlds).to include(world)
    end

    it 'has many stat_blocks' do
      stat_block = create(:stat_block, universe: universe)
      expect(universe.stat_blocks).to include(stat_block)
    end

    it 'has many currencies' do
      currency = create(:currency, universe: universe)
      expect(universe.currencies).to include(currency)
    end

    it 'has many channels' do
      channel = create(:channel, universe: universe)
      expect(universe.channels).to include(channel)
    end
  end

  describe 'validations' do
    it 'requires name' do
      universe = Universe.new
      expect(universe.valid?).to be false
      expect(universe.errors[:name]).not_to be_empty
    end

    it 'validates uniqueness of name' do
      unique_name = "Test Universe #{SecureRandom.hex(4)}"
      Universe.create(name: unique_name, theme: 'fantasy')
      duplicate = Universe.new(name: unique_name, theme: 'fantasy')
      expect(duplicate.valid?).to be false
      expect(duplicate.errors[:name]).not_to be_empty
    end

    it 'validates name max length of 100' do
      universe = Universe.new(name: 'a' * 101)
      expect(universe.valid?).to be false
      expect(universe.errors[:name]).not_to be_empty
    end

    it 'validates theme is in allowed values' do
      universe = Universe.new(name: 'Test', theme: 'invalid_theme')
      expect(universe.valid?).to be false
      expect(universe.errors[:theme]).not_to be_empty
    end

    describe 'valid themes' do
      %w[fantasy sci-fi modern post-apocalyptic steampunk cyberpunk].each do |theme|
        it "accepts #{theme} as a valid theme" do
          universe = Universe.new(name: "#{theme.capitalize} Universe", theme: theme)
          expect(universe.valid?).to be true
        end
      end
    end

    it 'is valid with required fields' do
      universe = Universe.new(name: 'Simple Universe', theme: 'fantasy')
      expect(universe.valid?).to be true
    end
  end

  describe '#active_worlds' do
    let(:universe) { create(:universe) }

    it 'returns only active worlds' do
      active_world = create(:world, universe: universe, active: true)
      inactive_world = create(:world, universe: universe, active: false)

      result = universe.active_worlds

      expect(result).to include(active_world)
      expect(result).not_to include(inactive_world)
    end

    it 'returns empty dataset when no active worlds exist' do
      create(:world, universe: universe, active: false)
      expect(universe.active_worlds.count).to eq(0)
    end

    it 'returns all worlds when all are active' do
      world1 = create(:world, universe: universe, active: true)
      world2 = create(:world, universe: universe, active: true)

      result = universe.active_worlds

      expect(result).to include(world1)
      expect(result).to include(world2)
      expect(result.count).to eq(2)
    end
  end
end
