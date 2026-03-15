# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ActionCooldown do
  let(:universe) { Universe.create(name: "Test Universe #{SecureRandom.hex(4)}", theme: 'fantasy') }
  let(:world) { World.create(name: 'Test World', universe: universe, gravity_multiplier: 1.0, world_size: 100.0) }
  let(:area) { Area.create(name: 'Test Area', world: world, zone_type: 'wilderness', danger_level: 1) }
  let(:location) { Location.create(name: 'Test Location', zone: area, location_type: 'outdoor') }
  let(:room) { Room.create(name: 'Test Room', short_description: 'A test room', location: location, room_type: 'standard') }
  let(:reality) { Reality.create(name: "Test Reality #{SecureRandom.hex(4)}", reality_type: 'primary', time_offset: 0) }
  let(:user) { create(:user) }
  let(:character) { Character.create(forename: 'Test', user: user) }
  let(:char_instance) do
    CharacterInstance.create(
      character: character,
      reality: reality,
      current_room: room,
      level: 1,
      experience: 0,
      health: 100,
      max_health: 100,
      mana: 50,
      max_mana: 50
    )
  end

  describe 'validations' do
    it 'requires essential fields' do
      cooldown = ActionCooldown.new
      expect(cooldown.valid?).to be false
      expect(cooldown.errors[:character_instance_id]).to include('is not present')
      expect(cooldown.errors[:ability_name]).to include('is not present')
      expect(cooldown.errors[:expires_at]).to include('is not present')
    end
  end

  describe '.set' do
    it 'creates a new cooldown' do
      cooldown = ActionCooldown.set(char_instance, 'fireball', 5000)

      expect(cooldown.ability_name).to eq('fireball')
      expect(cooldown.duration_ms).to eq(5000)
      expect(cooldown.expires_at).to be > Time.now
    end

    it 'updates existing cooldown' do
      ActionCooldown.set(char_instance, 'fireball', 1000)
      cooldown = ActionCooldown.set(char_instance, 'fireball', 5000)

      count = ActionCooldown.where(
        character_instance_id: char_instance.id,
        ability_name: 'fireball'
      ).count

      expect(count).to eq(1)
      expect(cooldown.duration_ms).to eq(5000)
    end
  end

  describe '.available?' do
    it 'returns true when no cooldown exists' do
      expect(ActionCooldown.available?(char_instance, 'fireball')).to be true
    end

    it 'returns false when cooldown is active' do
      ActionCooldown.set(char_instance, 'fireball', 60_000)
      expect(ActionCooldown.available?(char_instance, 'fireball')).to be false
    end

    it 'returns true when cooldown has expired' do
      now = Time.now
      allow(Time).to receive(:now).and_return(now)
      ActionCooldown.set(char_instance, 'fireball', 1)
      allow(Time).to receive(:now).and_return(now + 0.01)
      expect(ActionCooldown.available?(char_instance, 'fireball')).to be true
    end
  end

  describe '.remaining_ms' do
    it 'returns 0 when no cooldown exists' do
      expect(ActionCooldown.remaining_ms(char_instance, 'fireball')).to eq(0)
    end

    it 'returns remaining time for active cooldown' do
      ActionCooldown.set(char_instance, 'fireball', 5000)
      remaining = ActionCooldown.remaining_ms(char_instance, 'fireball')

      expect(remaining).to be > 0
      expect(remaining).to be <= 5000
    end
  end

  describe '.active_for_character' do
    it 'returns only active cooldowns' do
      now = Time.now
      allow(Time).to receive(:now).and_return(now)
      ActionCooldown.set(char_instance, 'fireball', 60_000)
      ActionCooldown.set(char_instance, 'heal', 1)
      allow(Time).to receive(:now).and_return(now + 0.01)

      active = ActionCooldown.active_for_character(char_instance.id)
      abilities = active.map(&:ability_name)

      expect(abilities).to include('fireball')
      expect(abilities).not_to include('heal')
    end
  end

  describe '.clear' do
    it 'removes a specific cooldown' do
      ActionCooldown.set(char_instance, 'fireball', 60_000)
      result = ActionCooldown.clear(char_instance, 'fireball')

      expect(result).to be true
      expect(ActionCooldown.available?(char_instance, 'fireball')).to be true
    end
  end

  describe '.clear_all' do
    it 'removes all cooldowns for character' do
      ActionCooldown.set(char_instance, 'fireball', 60_000)
      ActionCooldown.set(char_instance, 'heal', 60_000)

      cleared = ActionCooldown.clear_all(char_instance.id)

      expect(cleared).to eq(2)
      expect(ActionCooldown.active_for_character(char_instance.id)).to be_empty
    end
  end

  describe '.cleanup_expired!' do
    it 'removes expired cooldowns' do
      now = Time.now
      allow(Time).to receive(:now).and_return(now)
      ActionCooldown.set(char_instance, 'expired', 1)
      ActionCooldown.set(char_instance, 'active', 60_000)
      allow(Time).to receive(:now).and_return(now + 0.01)

      cleaned = ActionCooldown.cleanup_expired!

      expect(cleaned).to eq(1)
      expect(ActionCooldown.where(ability_name: 'active').count).to eq(1)
    end
  end

  describe '#to_api_format' do
    it 'returns API-friendly hash' do
      cooldown = ActionCooldown.set(char_instance, 'fireball', 5000)
      result = cooldown.to_api_format

      expect(result[:ability_name]).to eq('fireball')
      expect(result[:active]).to be true
      expect(result[:remaining_ms]).to be > 0
    end
  end
end
