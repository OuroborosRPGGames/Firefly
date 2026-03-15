# frozen_string_literal: true

require 'spec_helper'

RSpec.describe TimedAction do
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
      action = TimedAction.new
      expect(action.valid?).to be false
      expect(action.errors[:character_instance_id]).to include('is not present')
      expect(action.errors[:action_type]).to include('is not present')
      expect(action.errors[:action_name]).to include('is not present')
    end

    it 'validates action_type' do
      action = TimedAction.new(
        character_instance_id: char_instance.id,
        action_type: 'invalid',
        action_name: 'test',
        started_at: Time.now,
        status: 'active'
      )
      expect(action.valid?).to be false
    end
  end

  describe '.start_delayed' do
    it 'creates a delayed action' do
      action = TimedAction.start_delayed(char_instance, 'craft_sword', 5000)

      expect(action.action_type).to eq('delayed')
      expect(action.action_name).to eq('craft_sword')
      expect(action.duration_ms).to eq(5000)
      expect(action.status).to eq('active')
      expect(action.completes_at).to be > Time.now
    end

    it 'stores action data' do
      action = TimedAction.start_delayed(char_instance, 'craft', 1000, nil, { item: 'sword' })
      expect(action.parsed_action_data[:item]).to eq('sword')
    end
  end

  describe '.start_cast' do
    it 'creates an interruptible cast action' do
      action = TimedAction.start_cast(char_instance, 'heal', 3000)

      expect(action.action_type).to eq('cast')
      expect(action.interruptible).to be true
    end
  end

  describe '#complete?' do
    it 'returns false when not yet complete' do
      action = TimedAction.start_delayed(char_instance, 'test', 60_000)
      expect(action.complete?).to be false
    end

    it 'returns true when time has passed' do
      now = Time.now
      allow(Time).to receive(:now).and_return(now)
      action = TimedAction.start_delayed(char_instance, 'test', 1)
      allow(Time).to receive(:now).and_return(now + 0.01)
      expect(action.complete?).to be true
    end

    it 'returns true when status is completed' do
      action = TimedAction.start_delayed(char_instance, 'test', 60_000)
      action.update(status: 'completed')
      expect(action.complete?).to be true
    end
  end

  describe '#calculate_progress' do
    it 'returns 0 at start' do
      action = TimedAction.start_delayed(char_instance, 'test', 10_000)
      expect(action.calculate_progress).to be < 10
    end

    it 'returns 100 when complete' do
      now = Time.now
      allow(Time).to receive(:now).and_return(now)
      action = TimedAction.start_delayed(char_instance, 'test', 1)
      allow(Time).to receive(:now).and_return(now + 0.01)
      expect(action.calculate_progress).to eq(100)
    end
  end

  describe '#interrupt!' do
    it 'interrupts interruptible actions' do
      action = TimedAction.start_cast(char_instance, 'heal', 5000)
      result = action.interrupt!('moved')

      expect(result).to be true
      expect(action.reload.status).to eq('interrupted')
    end

    it 'does not interrupt non-interruptible actions' do
      action = TimedAction.start_delayed(char_instance, 'craft', 5000)
      result = action.interrupt!

      expect(result).to be false
      expect(action.reload.status).to eq('active')
    end
  end

  describe '#cancel!' do
    it 'cancels active actions' do
      action = TimedAction.start_delayed(char_instance, 'test', 5000)
      result = action.cancel!

      expect(result).to be true
      expect(action.reload.status).to eq('cancelled')
    end
  end

  describe '.ready_to_complete' do
    it 'finds actions that should complete' do
      now = Time.now
      allow(Time).to receive(:now).and_return(now)
      action1 = TimedAction.start_delayed(char_instance, 'fast', 1)
      TimedAction.start_delayed(char_instance, 'slow', 60_000)
      allow(Time).to receive(:now).and_return(now + 0.01)

      ready = TimedAction.ready_to_complete
      expect(ready.map(&:action_name)).to include('fast')
      expect(ready.map(&:action_name)).not_to include('slow')
    end
  end

  describe '.active_for_character' do
    it 'finds active actions for a character' do
      action = TimedAction.start_delayed(char_instance, 'test', 5000)
      active = TimedAction.active_for_character(char_instance.id)

      expect(active).to include(action)
    end
  end

  describe '#to_api_format' do
    it 'returns API-friendly hash' do
      action = TimedAction.start_delayed(char_instance, 'craft', 5000)
      result = action.to_api_format

      expect(result[:action_name]).to eq('craft')
      expect(result[:status]).to eq('active')
      expect(result[:progress_percent]).to be_a(Integer)
      expect(result[:time_remaining_ms]).to be_a(Integer)
    end
  end
end
