# frozen_string_literal: true

require 'spec_helper'

RSpec.describe CharacterStat do
  let(:universe) { create(:universe) }
  let(:stat_block) { create(:stat_block, universe: universe) }
  let(:stat) { create(:stat, stat_block: stat_block, min_value: 1, max_value: 10, default_value: 5) }
  let(:character_instance) { create(:character_instance) }

  describe 'validations' do
    it 'is valid with valid attributes' do
      character_stat = described_class.create(
        character_instance: character_instance,
        stat: stat,
        base_value: 5
      )
      expect(character_stat).to be_valid
    end

    it 'requires character_instance_id' do
      character_stat = described_class.new(stat: stat, base_value: 5)
      expect(character_stat).not_to be_valid
    end

    it 'requires stat_id' do
      character_stat = described_class.new(character_instance: character_instance, base_value: 5)
      expect(character_stat).not_to be_valid
    end

    it 'requires base_value' do
      character_stat = described_class.new(character_instance: character_instance, stat: stat)
      expect(character_stat).not_to be_valid
    end

    it 'validates uniqueness of character_instance_id and stat_id combination' do
      described_class.create(character_instance: character_instance, stat: stat, base_value: 5)
      duplicate = described_class.new(character_instance: character_instance, stat: stat, base_value: 6)
      expect(duplicate).not_to be_valid
    end

    it 'validates base_value is an integer' do
      character_stat = described_class.new(
        character_instance: character_instance,
        stat: stat,
        base_value: 'not an integer'
      )
      expect(character_stat).not_to be_valid
    end
  end

  describe 'associations' do
    it 'belongs to character_instance' do
      character_stat = create(:character_stat, character_instance: character_instance, stat: stat)
      expect(character_stat.character_instance).to eq(character_instance)
    end

    it 'belongs to stat' do
      character_stat = create(:character_stat, character_instance: character_instance, stat: stat)
      expect(character_stat.stat).to eq(stat)
    end
  end

  describe 'before_save defaults' do
    it 'defaults temp_modifier to 0' do
      character_stat = described_class.create(
        character_instance: character_instance,
        stat: stat,
        base_value: 5
      )
      expect(character_stat.temp_modifier).to eq(0)
    end
  end

  describe '#current_value' do
    let(:character_stat) do
      described_class.create(
        character_instance: character_instance,
        stat: stat,
        base_value: 5,
        temp_modifier: 0
      )
    end

    it 'returns base_value when no modifier' do
      expect(character_stat.current_value).to eq(5)
    end

    it 'includes temp_modifier in calculation' do
      character_stat.update(temp_modifier: 2)
      expect(character_stat.current_value).to eq(7)
    end

    it 'clamps to max_value' do
      character_stat.update(base_value: 9, temp_modifier: 5)
      expect(character_stat.current_value).to eq(10)  # max_value
    end

    it 'clamps to min_value' do
      character_stat.update(base_value: 2, temp_modifier: -5)
      expect(character_stat.current_value).to eq(1)  # min_value
    end
  end

  describe '#apply_modifier' do
    let(:character_stat) do
      described_class.create(
        character_instance: character_instance,
        stat: stat,
        base_value: 5,
        temp_modifier: 0
      )
    end

    it 'increases temp_modifier by amount' do
      character_stat.apply_modifier(3)
      expect(character_stat.temp_modifier).to eq(3)
    end

    it 'stacks with existing modifier' do
      character_stat.update(temp_modifier: 2)
      character_stat.apply_modifier(3)
      expect(character_stat.temp_modifier).to eq(5)
    end

    it 'sets expiration when duration_seconds provided' do
      freeze_time = Time.now
      allow(Time).to receive(:now).and_return(freeze_time)

      character_stat.apply_modifier(2, duration_seconds: 3600)
      expect(character_stat.modifier_expires_at).to be_within(1).of(freeze_time + 3600)
    end

    it 'does not set expiration when duration_seconds not provided' do
      character_stat.apply_modifier(2)
      expect(character_stat.modifier_expires_at).to be_nil
    end
  end

  describe '#clear_expired_modifiers!' do
    let(:character_stat) do
      described_class.create(
        character_instance: character_instance,
        stat: stat,
        base_value: 5,
        temp_modifier: 3,
        modifier_expires_at: Time.now - 1
      )
    end

    it 'clears expired modifiers' do
      character_stat.clear_expired_modifiers!
      expect(character_stat.temp_modifier).to eq(0)
      expect(character_stat.modifier_expires_at).to be_nil
    end

    it 'does not clear non-expired modifiers' do
      character_stat.update(modifier_expires_at: Time.now + 3600)
      character_stat.clear_expired_modifiers!
      expect(character_stat.temp_modifier).to eq(3)
    end

    it 'does not clear modifiers without expiration' do
      character_stat.update(modifier_expires_at: nil)
      character_stat.clear_expired_modifiers!
      expect(character_stat.temp_modifier).to eq(3)
    end
  end

  describe '#increase_base!' do
    let(:character_stat) do
      described_class.create(
        character_instance: character_instance,
        stat: stat,
        base_value: 5
      )
    end

    it 'increases base_value by 1 by default' do
      character_stat.increase_base!
      expect(character_stat.base_value).to eq(6)
    end

    it 'increases base_value by specified amount' do
      character_stat.increase_base!(3)
      expect(character_stat.base_value).to eq(8)
    end

    it 'caps at max_value' do
      character_stat.update(base_value: 9)
      character_stat.increase_base!(5)
      expect(character_stat.base_value).to eq(10)  # max_value
    end
  end

  describe '#at_max?' do
    let(:character_stat) do
      described_class.create(
        character_instance: character_instance,
        stat: stat,
        base_value: 5
      )
    end

    it 'returns false when below max' do
      expect(character_stat.at_max?).to be false
    end

    it 'returns true when at max' do
      character_stat.update(base_value: 10)
      expect(character_stat.at_max?).to be true
    end
  end

  describe '#at_min?' do
    let(:character_stat) do
      described_class.create(
        character_instance: character_instance,
        stat: stat,
        base_value: 5
      )
    end

    it 'returns false when above min' do
      expect(character_stat.at_min?).to be false
    end

    it 'returns true when at min' do
      character_stat.update(base_value: 1)
      expect(character_stat.at_min?).to be true
    end
  end
end
