# frozen_string_literal: true

require 'spec_helper'

RSpec.describe NpcSpawnService do
  let(:room) { create(:room) }
  let(:reality) { create(:reality, reality_type: 'primary') }

  # Helper to create an NPC character
  def create_npc_character(attrs = {})
    create(:character, :npc, attrs)
  end

  # ========================================
  # spawn_unique_npc
  # ========================================

  describe '.spawn_unique_npc' do
    let(:npc) { create_npc_character }

    it 'returns nil when character is nil' do
      expect(described_class.spawn_unique_npc(nil, room)).to be_nil
    end

    it 'returns nil when room is nil' do
      expect(described_class.spawn_unique_npc(npc, nil)).to be_nil
    end

    it 'returns nil when character is not an NPC' do
      player_char = create(:character, is_npc: false)
      expect(described_class.spawn_unique_npc(player_char, room)).to be_nil
    end

    context 'with valid NPC and room' do
      before do
        # Ensure a reality exists
        reality
      end

      it 'creates a character instance if none exists' do
        expect {
          described_class.spawn_unique_npc(npc, room, reality: reality)
        }.to change { CharacterInstance.where(character_id: npc.id).count }.by(1)
      end

      it 'creates an NpcSpawnInstance record' do
        expect {
          described_class.spawn_unique_npc(npc, room, reality: reality)
        }.to change { NpcSpawnInstance.count }.by(1)
      end

      it 'returns the spawn instance' do
        result = described_class.spawn_unique_npc(npc, room, reality: reality)
        expect(result).to be_a(NpcSpawnInstance)
        expect(result.character_id).to eq(npc.id)
        expect(result.room_id).to eq(room.id)
        expect(result.active).to be true
      end

      it 'sets the character instance online' do
        result = described_class.spawn_unique_npc(npc, room, reality: reality)
        instance = CharacterInstance.first(id: result.character_instance_id)
        expect(instance).not_to be_nil
        expect(instance.online).to be true
      end

      it 'uses provided activity as roomtitle' do
        result = described_class.spawn_unique_npc(npc, room, reality: reality, activity: 'guarding the door')
        expect(result.activity).to eq('guarding the door')
      end

      it 'uses provided despawn_at time' do
        despawn_time = Time.now + 3600
        result = described_class.spawn_unique_npc(npc, room, reality: reality, despawn_at: despawn_time)
        expect(result.despawn_at).to be_within(1).of(despawn_time)
      end

      it 'uses provided schedule_id when nil' do
        result = described_class.spawn_unique_npc(npc, room, reality: reality, schedule_id: nil)
        expect(result.npc_schedule_id).to be_nil
      end
    end
  end

  # ========================================
  # spawn_from_template
  # ========================================

  describe '.spawn_from_template' do
    let(:archetype) { create(:npc_archetype, spawn_health_range: '80-80', spawn_level_range: '3-3') }
    let(:template_npc) do
      create(
        :character,
        :npc,
        forename: 'Template Guard',
        is_unique_npc: false,
        npc_archetype: archetype
      )
    end

    before { reality }

    it 'spawns from a template character' do
      result = described_class.spawn_from_template(template_npc, room, reality: reality, activity: 'patrolling')

      expect(result).to be_a(NpcSpawnInstance)
      expect(result.character_id).to eq(template_npc.id)
      expect(result.activity).to eq('patrolling')
    end

    it 'accepts an archetype and creates/uses a template character' do
      result = described_class.spawn_from_template(archetype, room, options: { reality: reality })

      expect(result).to be_a(NpcSpawnInstance)
      expect(Character[result.character_id].template_npc?).to be true
      expect(Character[result.character_id].npc_archetype_id).to eq(archetype.id)
    end
  end

  # ========================================
  # spawn_at_room
  # ========================================

  describe '.spawn_at_room' do
    let(:archetype) { create(:npc_archetype) }
    let(:unique_npc) { create(:character, :npc, npc_archetype: archetype) }
    let(:template_npc) { create(:character, :npc, is_unique_npc: false, npc_archetype: archetype) }

    before { reality }

    it 'spawns a unique npc by IDs' do
      result = described_class.spawn_at_room(character_id: unique_npc.id, room_id: room.id, options: { reality: reality })
      expect(result).to be_a(NpcSpawnInstance)
      expect(result.character_id).to eq(unique_npc.id)
    end

    it 'spawns template npc by IDs' do
      result = described_class.spawn_at_room(character_id: template_npc.id, room_id: room.id, options: { reality: reality })
      expect(result).to be_a(NpcSpawnInstance)
      expect(result.character_id).to eq(template_npc.id)
    end
  end

  # ========================================
  # despawn_npc
  # ========================================

  describe '.despawn_npc' do
    let(:npc) { create_npc_character }
    let(:spawn_instance) do
      described_class.spawn_unique_npc(npc, room, reality: reality)
    end

    before { reality }

    it 'returns false when spawn_instance is nil' do
      expect(described_class.despawn_npc(nil)).to be false
    end

    it 'returns true on successful despawn' do
      instance = spawn_instance
      expect(described_class.despawn_npc(instance)).to be true
    end

    it 'marks spawn instance as inactive' do
      instance = spawn_instance
      described_class.despawn_npc(instance)
      instance.reload
      expect(instance.active).to be false
    end

    it 'sets character instance offline' do
      instance = spawn_instance
      char_instance = CharacterInstance.first(id: instance.character_instance_id)
      expect(char_instance.online).to be true

      described_class.despawn_npc(instance)
      char_instance.reload
      expect(char_instance.online).to be false
    end
  end

  # ========================================
  # despawn_all
  # ========================================

  describe '.despawn_all' do
    let(:npc) { create_npc_character }

    before { reality }

    it 'returns 0 when character is nil' do
      expect(described_class.despawn_all(nil)).to eq(0)
    end

    it 'returns 0 when character has no active spawns' do
      expect(described_class.despawn_all(npc)).to eq(0)
    end

    it 'returns count of despawned instances' do
      # Spawn the NPC twice in different rooms
      room2 = create(:room)
      described_class.spawn_unique_npc(npc, room, reality: reality)

      count = described_class.despawn_all(npc)
      expect(count).to eq(1)
    end

    it 'despawns all active instances' do
      described_class.spawn_unique_npc(npc, room, reality: reality)

      described_class.despawn_all(npc)

      active_count = NpcSpawnInstance.where(character_id: npc.id, active: true).count
      expect(active_count).to eq(0)
    end
  end

  # ========================================
  # kill_npc!
  # ========================================

  describe '.kill_npc!' do
    let(:npc) { create_npc_character }
    let(:npc_instance) do
      create(:character_instance, character: npc, current_room: room, reality: reality, online: true, status: 'alive')
    end

    before { reality }

    it 'returns false when character_instance is nil' do
      expect(described_class.kill_npc!(nil)).to be false
    end

    it 'returns false when character is not an NPC' do
      player = create(:character, is_npc: false)
      player_instance = create(:character_instance, character: player, current_room: room, reality: reality)
      expect(described_class.kill_npc!(player_instance)).to be false
    end

    it 'sets instance offline' do
      described_class.kill_npc!(npc_instance)
      npc_instance.reload
      expect(npc_instance.online).to be false
    end

    it 'sets instance status to dead' do
      described_class.kill_npc!(npc_instance)
      npc_instance.reload
      expect(npc_instance.status).to eq('dead')
    end

    it 'returns true on success' do
      expect(described_class.kill_npc!(npc_instance)).to be true
    end

    it 'deactivates associated spawn instance' do
      spawn = NpcSpawnInstance.create(
        character_id: npc.id,
        character_instance_id: npc_instance.id,
        room_id: room.id,
        spawned_at: Time.now,
        active: true
      )

      described_class.kill_npc!(npc_instance)
      spawn.reload
      expect(spawn.active).to be false
    end
  end

  # ========================================
  # active_in_room
  # ========================================

  describe '.active_in_room' do
    let(:npc) { create_npc_character }

    before { reality }

    it 'returns empty array when room is nil' do
      expect(described_class.active_in_room(nil)).to eq([])
    end

    it 'returns empty array when no active spawns in room' do
      expect(described_class.active_in_room(room)).to eq([])
    end

    it 'returns active spawn instances in room' do
      spawn = described_class.spawn_unique_npc(npc, room, reality: reality)

      result = described_class.active_in_room(room)
      expect(result).to include(spawn)
    end

    it 'does not include inactive spawns' do
      spawn = described_class.spawn_unique_npc(npc, room, reality: reality)
      described_class.despawn_npc(spawn)

      result = described_class.active_in_room(room)
      expect(result).to be_empty
    end

    it 'does not include spawns from other rooms' do
      other_room = create(:room)
      described_class.spawn_unique_npc(npc, other_room, reality: reality)

      result = described_class.active_in_room(room)
      expect(result).to be_empty
    end
  end

  # ========================================
  # spawned?
  # ========================================

  describe '.spawned?' do
    let(:npc) { create_npc_character }

    before { reality }

    it 'returns false when character is nil' do
      expect(described_class.spawned?(nil)).to be false
    end

    it 'returns false when character has no active spawns' do
      expect(described_class.spawned?(npc)).to be false
    end

    it 'returns true when character has active spawn' do
      described_class.spawn_unique_npc(npc, room, reality: reality)
      expect(described_class.spawned?(npc)).to be true
    end

    it 'returns false after despawn' do
      spawn = described_class.spawn_unique_npc(npc, room, reality: reality)
      described_class.despawn_npc(spawn)
      expect(described_class.spawned?(npc)).to be false
    end
  end

  # ========================================
  # process_schedules!
  # ========================================

  describe '.process_schedules!' do
    it 'returns a hash with spawned, despawned, and errors keys' do
      result = described_class.process_schedules!
      expect(result).to have_key(:spawned)
      expect(result).to have_key(:despawned)
      expect(result).to have_key(:errors)
    end

    it 'returns empty arrays when no schedules exist' do
      result = described_class.process_schedules!
      expect(result[:spawned]).to eq([])
      expect(result[:despawned]).to eq([])
      expect(result[:errors]).to eq([])
    end

    it 'spawns at most one active schedule per NPC when schedules overlap' do
      reality
      npc = create_npc_character
      room_two = create(:room)
      create(:npc_schedule, character: npc, room: room, is_active: true, weekdays: 'all', probability: 100)
      create(:npc_schedule, character: npc, room: room_two, is_active: true, weekdays: 'all', probability: 100)

      described_class.process_schedules!

      active_spawns = NpcSpawnInstance.where(character_id: npc.id, active: true).all
      expect(active_spawns.length).to eq(1)
    end

    it 'clears stale current flags when selecting an overlapping schedule' do
      reality
      npc = create_npc_character
      room_two = create(:room)
      first = create(:npc_schedule, character: npc, room: room, is_active: true, weekdays: 'all', probability: 100, current: true)
      second = create(:npc_schedule, character: npc, room: room_two, is_active: true, weekdays: 'all', probability: 100, current: true)

      described_class.process_schedules!

      first.reload
      second.reload
      expect([first.current, second.current].count(true)).to be <= 1
    end
  end
end
