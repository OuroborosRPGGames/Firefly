# frozen_string_literal: true

require 'spec_helper'

RSpec.describe DeathService do
  let(:room) { create(:room) }
  let(:death_room) { create(:room, room_type: 'death', name: 'The Void') }
  let(:spawn_room) do
    room = create(:room, name: 'Spawn Point')
    GameSetting.set('tutorial_spawn_room_id', room.id, type: 'integer')
    room
  end
  let(:character) { create(:character) }
  let(:character_instance) { create(:character_instance, character: character, current_room: room, status: 'alive') }

  describe '.kill' do
    before { death_room } # Ensure death room exists

    it 'moves character to death room' do
      described_class.kill(character_instance)
      character_instance.reload
      expect(character_instance.current_room_id).to eq(death_room.id)
    end

    it 'sets character status to dead' do
      described_class.kill(character_instance)
      character_instance.reload
      expect(character_instance.status).to eq('dead')
    end

    it 'resets character position to origin' do
      character_instance.update(x: 10.0, y: 20.0, z: 5.0)
      described_class.kill(character_instance)
      character_instance.reload
      expect(character_instance.x).to eq(0.0)
      expect(character_instance.y).to eq(0.0)
      expect(character_instance.z).to eq(0.0)
    end

    it 'raises AlreadyDead if character is already dead' do
      character_instance.update(status: 'dead')
      expect { described_class.kill(character_instance) }.to raise_error(DeathService::AlreadyDead)
    end

    it 'raises DeathRoomNotConfigured if no death room exists' do
      death_room.destroy
      expect { described_class.kill(character_instance) }.to raise_error(DeathService::DeathRoomNotConfigured)
    end

    context 'with a cause of death' do
      it 'accepts optional cause parameter' do
        expect { described_class.kill(character_instance, cause: 'was slain by a dragon') }.not_to raise_error
      end
    end
  end

  describe '.resurrect' do
    before do
      death_room
      spawn_room
      character_instance.update(status: 'dead', current_room_id: death_room.id)
    end

    it 'moves character to spawn room by default' do
      described_class.resurrect(character_instance)
      character_instance.reload
      expect(character_instance.current_room_id).to eq(spawn_room.id)
    end

    it 'moves character to specified destination room' do
      destination = create(:room, name: 'Temple')
      described_class.resurrect(character_instance, destination)
      character_instance.reload
      expect(character_instance.current_room_id).to eq(destination.id)
    end

    it 'sets character status to alive' do
      described_class.resurrect(character_instance)
      character_instance.reload
      expect(character_instance.status).to eq('alive')
    end

    it 'raises NotDead if character is not dead' do
      character_instance.update(status: 'alive')
      expect { described_class.resurrect(character_instance) }.to raise_error(DeathService::NotDead)
    end
  end

  describe '.death_room' do
    it 'returns room with room_type death' do
      death_room
      expect(described_class.death_room).to eq(death_room)
    end

    it 'returns nil if no death room configured' do
      expect(described_class.death_room).to be_nil
    end
  end

  describe '.dead?' do
    it 'returns true for dead characters' do
      character_instance.update(status: 'dead')
      expect(described_class.dead?(character_instance)).to be true
    end

    it 'returns false for alive characters' do
      expect(described_class.dead?(character_instance)).to be false
    end
  end

  describe '.can_communicate_ic?' do
    it 'returns true for alive characters in normal rooms' do
      expect(described_class.can_communicate_ic?(character_instance)).to be true
    end

    it 'returns false for dead characters' do
      character_instance.update(status: 'dead')
      expect(described_class.can_communicate_ic?(character_instance)).to be false
    end

    it 'returns false for characters in rooms that block IC communication' do
      death_room
      character_instance.update(current_room_id: death_room.id)
      expect(described_class.can_communicate_ic?(character_instance)).to be false
    end
  end
end
