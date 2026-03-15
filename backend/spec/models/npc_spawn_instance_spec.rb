# frozen_string_literal: true

require 'spec_helper'

RSpec.describe NpcSpawnInstance, type: :model do
  let(:reality) { create(:reality) }
  let(:location) { create(:location) }
  let(:room) { create(:room, location: location) }
  let(:npc_archetype) { create(:npc_archetype, name: 'Guard') }
  let(:npc_character) { create(:character, :npc, forename: 'Guard', npc_archetype: npc_archetype) }
  let(:character_instance) { create(:character_instance, character: npc_character, reality: reality, current_room: room) }

  describe 'associations' do
    it 'belongs to character' do
      spawn = NpcSpawnInstance.create(
        character: npc_character,
        character_instance: character_instance,
        room: room,
        spawned_at: Time.now
      )
      expect(spawn.character).to eq(npc_character)
    end

    it 'belongs to character_instance' do
      spawn = NpcSpawnInstance.create(
        character: npc_character,
        character_instance: character_instance,
        room: room,
        spawned_at: Time.now
      )
      expect(spawn.character_instance).to eq(character_instance)
    end

    it 'belongs to room' do
      spawn = NpcSpawnInstance.create(
        character: npc_character,
        character_instance: character_instance,
        room: room,
        spawned_at: Time.now
      )
      expect(spawn.room).to eq(room)
    end
  end

  describe 'validations' do
    it 'requires character_id' do
      spawn = NpcSpawnInstance.new(
        character_instance: character_instance,
        room: room,
        spawned_at: Time.now
      )
      expect(spawn.valid?).to be false
    end

    it 'requires character_instance_id' do
      spawn = NpcSpawnInstance.new(
        character: npc_character,
        room: room,
        spawned_at: Time.now
      )
      expect(spawn.valid?).to be false
    end

    it 'requires room_id' do
      spawn = NpcSpawnInstance.new(
        character: npc_character,
        character_instance: character_instance,
        spawned_at: Time.now
      )
      expect(spawn.valid?).to be false
    end

    it 'requires spawned_at' do
      spawn = NpcSpawnInstance.new(
        character: npc_character,
        character_instance: character_instance,
        room: room
      )
      expect(spawn.valid?).to be false
    end
  end

  describe '#should_despawn?' do
    let(:spawn) do
      NpcSpawnInstance.create(
        character: npc_character,
        character_instance: character_instance,
        room: room,
        spawned_at: Time.now,
        active: true
      )
    end

    it 'returns true if inactive' do
      spawn.update(active: false)
      expect(spawn.should_despawn?).to be true
    end

    it 'returns true if despawn_at has passed' do
      spawn.update(despawn_at: Time.now - 3600) # 1 hour ago
      expect(spawn.should_despawn?).to be true
    end

    it 'returns false if active and no despawn_at' do
      expect(spawn.should_despawn?).to be false
    end
  end

  describe '#despawn!' do
    let(:spawn) do
      NpcSpawnInstance.create(
        character: npc_character,
        character_instance: character_instance,
        room: room,
        spawned_at: Time.now,
        active: true
      )
    end

    before do
      character_instance.update(online: true)
    end

    it 'sets active to false' do
      spawn.despawn!
      expect(spawn.reload.active).to be false
    end

    it 'sets character_instance offline' do
      spawn.despawn!
      expect(character_instance.reload.online).to be false
    end

    it 'keeps character_instance online when another active spawn exists for same instance' do
      duplicate_spawn = NpcSpawnInstance.create(
        character: npc_character,
        character_instance: character_instance,
        room: room,
        spawned_at: Time.now,
        active: true
      )
      character_instance.update(online: true)

      spawn.despawn!

      expect(character_instance.reload.online).to be true
      duplicate_spawn.despawn!
      expect(character_instance.reload.online).to be false
    end
  end

  describe '.active_spawns' do
    it 'returns only active spawn instances' do
      active_spawn = NpcSpawnInstance.create(
        character: npc_character,
        character_instance: character_instance,
        room: room,
        spawned_at: Time.now,
        active: true
      )

      # Create a different NPC for the inactive spawn
      another_npc = create(:character, :npc, forename: 'Another Guard', npc_archetype: npc_archetype)
      another_reality = create(:reality)
      another_instance = create(:character_instance, character: another_npc, reality: another_reality, current_room: room)
      inactive_spawn = NpcSpawnInstance.create(
        character: another_npc,
        character_instance: another_instance,
        room: room,
        spawned_at: Time.now,
        active: false
      )

      results = NpcSpawnInstance.active_spawns.all
      expect(results).to include(active_spawn)
      expect(results).not_to include(inactive_spawn)
    end
  end

  describe '.for_room' do
    let(:other_room) { create(:room, location: location) }

    it 'returns only spawns in the specified room' do
      spawn_in_room = NpcSpawnInstance.create(
        character: npc_character,
        character_instance: character_instance,
        room: room,
        spawned_at: Time.now,
        active: true
      )

      # Create a different NPC for the other room spawn
      another_npc = create(:character, :npc, forename: 'Other Guard', npc_archetype: npc_archetype)
      another_reality = create(:reality)
      another_instance = create(:character_instance, character: another_npc, reality: another_reality, current_room: other_room)
      spawn_in_other_room = NpcSpawnInstance.create(
        character: another_npc,
        character_instance: another_instance,
        room: other_room,
        spawned_at: Time.now,
        active: true
      )

      results = NpcSpawnInstance.for_room(room.id).all
      expect(results).to include(spawn_in_room)
      expect(results).not_to include(spawn_in_other_room)
    end
  end
end
