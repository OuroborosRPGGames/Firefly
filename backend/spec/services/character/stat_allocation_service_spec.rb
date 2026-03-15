# frozen_string_literal: true

require 'spec_helper'

RSpec.describe StatAllocationService do
  let!(:reality) { Reality.first || create(:reality) }
  let!(:universe) { Universe.first || create(:universe) }
  let!(:stat_block) do
    StatBlock.create(
      universe_id: universe.id,
      name: 'Test Stats',
      block_type: 'single',
      total_points: 50,
      min_stat_value: 1,
      max_stat_value: 10,
      cost_formula: 'doubling_every_other',
      is_active: true
    )
  end
  let!(:strength) do
    Stat.create(
      stat_block_id: stat_block.id,
      name: 'Strength',
      abbreviation: 'STR',
      stat_category: 'primary',
      display_order: 1
    )
  end
  let!(:dexterity) do
    Stat.create(
      stat_block_id: stat_block.id,
      name: 'Dexterity',
      abbreviation: 'DEX',
      stat_category: 'primary',
      display_order: 2
    )
  end
  let!(:character_instance) { create(:character_instance, reality: reality) }

  # The character_instance factory's after_create hook calls initialize_stats_from_character,
  # which auto-creates CharacterStat records for active stat blocks. We need to clear those
  # before tests that create their own stats to avoid unique constraint violations.
  before do
    CharacterStat.where(character_instance_id: character_instance.id).delete
    character_instance.reload
  end

  describe '.create_stats_for_character' do
    it 'creates CharacterStat records for valid allocations' do
      allocations = {
        stat_block.id => {
          strength.id => 5,
          dexterity.id => 3
        }
      }

      result = described_class.create_stats_for_character(character_instance, allocations)

      expect(result.length).to eq(2)
      expect(CharacterStat.where(character_instance_id: character_instance.id).count).to eq(2)
    end

    it 'raises an error for invalid allocations exceeding points' do
      allocations = {
        stat_block.id => {
          strength.id => 10, # Costs 30 points
          dexterity.id => 10 # Another 30 points = 60 total, exceeds 50
        }
      }

      expect {
        described_class.create_stats_for_character(character_instance, allocations)
      }.to raise_error(StatAllocationService::AllocationError)
    end
  end

  describe '.initialize_default_stats' do
    it 'creates stats at minimum values for all active stat blocks' do
      result = described_class.initialize_default_stats(character_instance, stat_blocks: [stat_block])

      expect(result.length).to eq(2)
      result.each do |char_stat|
        expect(char_stat.base_value).to eq(stat_block.min_stat_value)
      end
    end

    it 'does not duplicate existing stats' do
      CharacterStat.create(
        character_instance_id: character_instance.id,
        stat_id: strength.id,
        base_value: 5
      )

      result = described_class.initialize_default_stats(character_instance, stat_blocks: [stat_block])

      expect(result.length).to eq(1) # Only dexterity created
      expect(CharacterStat.where(character_instance_id: character_instance.id).count).to eq(2)
    end
  end

  describe '.parse_form_allocations' do
    it 'parses form parameters into allocations hash' do
      params = {
        'stat_allocations' => {
          '1' => { '10' => '5', '11' => '3' },
          '2' => { '20' => '4' }
        }
      }

      result = described_class.parse_form_allocations(params)

      expect(result).to eq({
        1 => { 10 => 5, 11 => 3 },
        2 => { 20 => 4 }
      })
    end

    it 'returns empty hash for missing stat_allocations' do
      result = described_class.parse_form_allocations({})
      expect(result).to eq({})
    end
  end

  describe '.get_stat_value' do
    before do
      CharacterStat.create(
        character_instance_id: character_instance.id,
        stat_id: strength.id,
        base_value: 7
      )
    end

    it 'finds stat by name' do
      value = described_class.get_stat_value(character_instance, 'Strength')
      expect(value).to eq(7)
    end

    it 'finds stat by abbreviation (case insensitive)' do
      value = described_class.get_stat_value(character_instance, 'str')
      expect(value).to eq(7)
    end

    it 'returns nil for unknown stat' do
      value = described_class.get_stat_value(character_instance, 'Unknown')
      expect(value).to be_nil
    end
  end

  describe '.calculate_roll_modifier' do
    before do
      CharacterStat.create(
        character_instance_id: character_instance.id,
        stat_id: strength.id,
        base_value: 6
      )
      CharacterStat.create(
        character_instance_id: character_instance.id,
        stat_id: dexterity.id,
        base_value: 4
      )
    end

    it 'returns single stat value for one stat' do
      result = described_class.calculate_roll_modifier(character_instance, ['STR'])

      expect(result[:success]).to be true
      expect(result[:modifier]).to eq(6.0)
    end

    it 'averages multiple stats and adds bonus' do
      result = described_class.calculate_roll_modifier(character_instance, ['STR', 'DEX'])

      # Average: (6+4)/2 = 5, bonus: 0.5 for each extra stat = 0.5
      # Total: 5.5
      expect(result[:success]).to be true
      expect(result[:modifier]).to eq(5.5)
    end

    it 'returns error for unknown stats' do
      result = described_class.calculate_roll_modifier(character_instance, ['UNKNOWN'])

      expect(result[:success]).to be false
      expect(result[:error]).to include('Unknown stats')
    end
  end
end
