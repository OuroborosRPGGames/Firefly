# frozen_string_literal: true

require 'spec_helper'

RSpec.describe CharacterAbility do
  let(:location) { create(:location) }
  let(:room) { create(:room, location: location) }
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }
  let(:character_instance) { create(:character_instance, character: character, current_room: room) }
  let(:ability) { create(:ability, :with_cooldown) }

  describe 'associations' do
    it 'belongs to character_instance' do
      ca = create(:character_ability, character_instance: character_instance, ability: ability)
      expect(ca.character_instance).to eq(character_instance)
    end

    it 'belongs to ability' do
      ca = create(:character_ability, character_instance: character_instance, ability: ability)
      expect(ca.ability).to eq(ability)
    end
  end

  describe 'validations' do
    it 'requires character_instance_id' do
      ca = CharacterAbility.new(ability_id: ability.id)
      expect(ca.valid?).to be false
      expect(ca.errors[:character_instance_id]).not_to be_empty
    end

    it 'requires ability_id' do
      ca = CharacterAbility.new(character_instance_id: character_instance.id)
      expect(ca.valid?).to be false
      expect(ca.errors[:ability_id]).not_to be_empty
    end

    it 'validates unique combination of character_instance and ability' do
      create(:character_ability, character_instance: character_instance, ability: ability)
      duplicate = CharacterAbility.new(character_instance_id: character_instance.id, ability_id: ability.id)
      expect(duplicate.valid?).to be false
    end
  end

  describe 'before_save defaults' do
    it 'sets learned_at if not provided' do
      ca = CharacterAbility.new(character_instance_id: character_instance.id, ability_id: ability.id)
      ca.save
      expect(ca.learned_at).not_to be_nil
    end

    it 'sets uses_today to 0 if not provided' do
      ca = CharacterAbility.new(character_instance_id: character_instance.id, ability_id: ability.id)
      ca.save
      expect(ca.uses_today).to eq(0)
    end

    it 'preserves learned_at if already set' do
      past_time = Time.now - 3600
      ca = CharacterAbility.new(
        character_instance_id: character_instance.id,
        ability_id: ability.id,
        learned_at: past_time
      )
      ca.save
      expect(ca.learned_at.to_i).to eq(past_time.to_i)
    end
  end

  describe '#on_cooldown?' do
    let(:character_ability) { create(:character_ability, character_instance: character_instance, ability: ability) }

    context 'when last_used_at is nil' do
      it 'returns false' do
        expect(character_ability.on_cooldown?).to be false
      end
    end

    context 'when ability has no cooldown' do
      let(:ability_no_cooldown) { create(:ability, cooldown_seconds: 0) }
      let(:character_ability) { create(:character_ability, character_instance: character_instance, ability: ability_no_cooldown) }

      it 'returns false even with last_used_at set' do
        character_ability.update(last_used_at: Time.now)
        expect(character_ability.on_cooldown?).to be false
      end
    end

    context 'when ability is on cooldown' do
      it 'returns true when within cooldown period' do
        character_ability.update(last_used_at: Time.now - 30)
        expect(character_ability.on_cooldown?).to be true
      end

      it 'returns false when cooldown has expired' do
        character_ability.update(last_used_at: Time.now - 120)
        expect(character_ability.on_cooldown?).to be false
      end
    end
  end

  describe '#cooldown_ends_at' do
    let(:character_ability) { create(:character_ability, character_instance: character_instance, ability: ability) }

    it 'returns nil when last_used_at is nil' do
      expect(character_ability.cooldown_ends_at).to be_nil
    end

    it 'returns nil when ability has no cooldown' do
      ability_no_cooldown = create(:ability, cooldown_seconds: 0)
      ca = create(:character_ability, character_instance: character_instance, ability: ability_no_cooldown, last_used_at: Time.now)
      expect(ca.cooldown_ends_at).to be_nil
    end

    it 'returns correct end time when on cooldown' do
      used_at = Time.now - 30
      character_ability.update(last_used_at: used_at)
      expected_end = used_at + ability.cooldown_seconds
      expect(character_ability.cooldown_ends_at.to_i).to eq(expected_end.to_i)
    end
  end

  describe '#cooldown_remaining' do
    let(:character_ability) { create(:character_ability, character_instance: character_instance, ability: ability) }

    it 'returns 0 when not on cooldown' do
      expect(character_ability.cooldown_remaining).to eq(0)
    end

    it 'returns remaining seconds when on cooldown' do
      character_ability.update(last_used_at: Time.now)
      remaining = character_ability.cooldown_remaining
      expect(remaining).to be > 0
      expect(remaining).to be <= ability.cooldown_seconds
    end
  end

  describe '#trigger_cooldown!' do
    let(:character_ability) { create(:character_ability, character_instance: character_instance, ability: ability) }

    it 'sets last_used_at to current time' do
      expect(character_ability.last_used_at).to be_nil
      character_ability.trigger_cooldown!
      expect(character_ability.last_used_at).not_to be_nil
    end

    it 'does nothing when ability has no cooldown' do
      ability_no_cooldown = create(:ability, cooldown_seconds: nil)
      allow(ability_no_cooldown).to receive(:has_cooldown?).and_return(false)
      ca = create(:character_ability, character_instance: character_instance, ability: ability_no_cooldown)
      ca.trigger_cooldown!
      expect(ca.last_used_at).to be_nil
    end
  end

  describe '#reset_cooldown!' do
    let(:character_ability) { create(:character_ability, character_instance: character_instance, ability: ability, last_used_at: Time.now) }

    it 'sets last_used_at to nil' do
      expect(character_ability.last_used_at).not_to be_nil
      character_ability.reset_cooldown!
      expect(character_ability.last_used_at).to be_nil
    end
  end

  describe '#can_use?' do
    let(:character_ability) { create(:character_ability, character_instance: character_instance, ability: ability) }

    context 'when not on cooldown' do
      it 'returns true for basic ability' do
        expect(character_ability.can_use?).to be true
      end
    end

    context 'when on cooldown' do
      it 'returns false' do
        character_ability.update(last_used_at: Time.now)
        expect(character_ability.can_use?).to be false
      end
    end

    context 'when ability has legacy willpower cost data' do
      let(:ability_with_legacy_cost) do
        create(:ability, cooldown_seconds: 0, costs: { 'willpower_cost' => 2 })
      end
      let(:character_ability) { create(:character_ability, character_instance: character_instance, ability: ability_with_legacy_cost) }

      before do
        allow(ability_with_legacy_cost).to receive(:has_cooldown?).and_return(false)
      end

      it 'still allows use when not on cooldown' do
        expect(character_ability.can_use?).to be true
      end
    end
  end
end
