# frozen_string_literal: true

require 'spec_helper'
require 'timeout'

RSpec.describe WorldMemoryService do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area) }
  let(:room) { create(:room, location: location, name: 'Test Room') }
  let(:reality) { create(:reality) }

  let(:user) { create(:user) }
  let(:character) { create(:character, user: user, forename: 'Alice') }
  let(:character2) { create(:character, forename: 'Bob') }
  let(:character_instance) do
    create(:character_instance,
           character: character,
           reality: reality,
           current_room: room,
           online: true,
           status: 'alive')
  end
  let(:character_instance2) do
    create(:character_instance,
           character: character2,
           reality: reality,
           current_room: room,
           online: true,
           status: 'alive')
  end

  before do
    allow(BroadcastService).to receive(:to_room)
    allow(BroadcastService).to receive(:to_character)
    allow(TriggerService).to receive(:check_world_memory_triggers)
    allow(LLM::Client).to receive(:generate).and_return({
      success: true,
      text: 'A summary of the roleplay session.'
    })
    allow(LLM::Client).to receive(:embed).and_return({
      success: true,
      embedding: [0.1] * 1024
    })
    allow(Embedding).to receive(:store)
    allow(Embedding).to receive(:similar_to).and_return([])
  end

  describe 'constants' do
    it 'defines MEMORY_EMBEDDING_TYPE' do
      expect(described_class::MEMORY_EMBEDDING_TYPE).to eq('world_memory')
    end

    it 'defines ABSTRACTION_THRESHOLD' do
      expect(described_class::ABSTRACTION_THRESHOLD).to eq(8)
    end

    # NOTE: MAX_ABSTRACTION_LEVEL was intentionally removed to allow unlimited abstraction levels

    it 'defines RAW_LOG_RETENTION_MONTHS' do
      expect(described_class::RAW_LOG_RETENTION_MONTHS).to eq(6)
    end

    it 'defines IC_MESSAGE_TYPES' do
      expect(described_class::IC_MESSAGE_TYPES).to include(:say, :emote, :whisper)
    end
  end

  describe '.track_ic_message' do
    before do
      # Ensure multiple characters in room
      character_instance
      character_instance2
    end

    context 'with valid message' do
      it 'creates or finds a session' do
        result = described_class.track_ic_message(
          room_id: room.id,
          content: 'Hello everyone!',
          sender: character_instance,
          type: :say
        )

        expect(result).to be_a(WorldMemorySession)
      end

      it 'only counts participants in the same event context' do
        character_instance.update(in_event_id: 123)
        character_instance2.update(in_event_id: nil)

        result = described_class.track_ic_message(
          room_id: room.id,
          content: 'Event-only hello',
          sender: character_instance,
          type: :say
        )

        expect(result).to be_nil
      end

      it 'returns nil for blank content' do
        result = described_class.track_ic_message(
          room_id: room.id,
          content: '',
          sender: character_instance,
          type: :say
        )

        expect(result).to be_nil
      end

      it 'returns nil for non-IC message types' do
        result = described_class.track_ic_message(
          room_id: room.id,
          content: 'Test',
          sender: character_instance,
          type: :system
        )

        expect(result).to be_nil
      end

      it 'returns nil when only one character is in the event/room context' do
        other_room = create(:room, location: location, name: 'Other Room')
        character_instance2.update(current_room_id: other_room.id)

        result = described_class.track_ic_message(
          room_id: room.id,
          content: 'Hello',
          sender: character_instance,
          type: :say
        )

        expect(result).to be_nil
      end
    end

    context 'with private mode' do
      before do
        allow(character_instance).to receive(:private_mode?).and_return(true)
      end

      it 'marks session as private' do
        result = described_class.track_ic_message(
          room_id: room.id,
          content: 'Secret message',
          sender: character_instance,
          type: :say
        )

        expect(result.has_private_content).to be true
      end
    end

    context 'error handling' do
      it 'handles errors gracefully' do
        allow(Room).to receive(:[]).and_raise(StandardError.new('DB error'))

        result = described_class.track_ic_message(
          room_id: room.id,
          content: 'Test',
          sender: character_instance,
          type: :say
        )

        expect(result).to be_nil
      end
    end
  end

  describe '.handle_character_movement' do
    let(:from_room) { room }
    let(:to_room) { create(:room, location: location, name: 'Destination') }

    context 'with active session in source room' do
      let!(:session) do
        WorldMemorySession.create(
          room_id: from_room.id,
          started_at: Time.now,
          last_activity_at: Time.now,
          status: 'active'
        )
      end

      before do
        allow(WorldMemorySession).to receive(:active_for_room_context).with(from_room.id, nil).and_return(session)
        allow(WorldMemorySession).to receive(:active_for_room_context).with(to_room.id, nil).and_return(nil)
        allow(session).to receive(:remove_character!)
        allow(session).to receive(:active_character_count).and_return(2)
      end

      it 'removes character from source session' do
        described_class.handle_character_movement(
          character_instance: character_instance,
          from_room: from_room,
          to_room: to_room
        )

        expect(session).to have_received(:remove_character!)
      end
    end

    context 'with nil rooms' do
      it 'handles nil from_room' do
        expect {
          described_class.handle_character_movement(
            character_instance: character_instance,
            from_room: nil,
            to_room: to_room
          )
        }.not_to raise_error
      end

      it 'handles nil to_room' do
        expect {
          described_class.handle_character_movement(
            character_instance: character_instance,
            from_room: from_room,
            to_room: nil
          )
        }.not_to raise_error
      end
    end
  end

  describe '.finalize_session' do
    let(:session) do
      WorldMemorySession.create(
        room_id: room.id,
        started_at: Time.now - 3600,
        ended_at: Time.now,
        last_activity_at: Time.now,
        status: 'active',
        log_buffer: "Alice says: Hello everyone!\nBob says: Hi there!",
        message_count: 10,
        publicity_level: 'public'
      )
    end

    before do
      allow(session).to receive(:sufficient_for_memory?).and_return(true)
      allow(session).to receive(:session_characters).and_return([])
      allow(session).to receive(:session_rooms).and_return([])
    end

    context 'when session is valid' do
      it 'creates a world memory' do
        memory = described_class.finalize_session(session)

        expect(memory).to be_a(WorldMemory)
        expect(memory.summary).not_to be_nil
      end

      it 'stores embedding for memory' do
        described_class.finalize_session(session)

        expect(Embedding).to have_received(:store)
      end

      it 'triggers world memory triggers' do
        described_class.finalize_session(session)

        expect(TriggerService).to have_received(:check_world_memory_triggers)
      end

      it 'stores the source session id for session-sourced memories' do
        memory = described_class.finalize_session(session)

        expect(memory.source_type).to eq('session')
        expect(memory.source_id).to eq(session.id)
      end
    end

    context 'when session is already finalized' do
      before { session.update(status: 'finalized') }

      it 'returns nil' do
        result = described_class.finalize_session(session)
        expect(result).to be_nil
      end
    end

    context 'when session has private content' do
      before do
        session.update(has_private_content: true)
        allow(session).to receive(:has_private_content).and_return(true)
      end

      it 'abandons the session' do
        described_class.finalize_session(session)

        expect(session.reload.status).to eq('abandoned')
      end
    end

    context 'when summary generation fails' do
      before do
        allow(LLM::Client).to receive(:generate).and_return({
          success: false,
          error: 'API error'
        })
      end

      it 'abandons the session' do
        described_class.finalize_session(session)

        expect(session.reload.status).to eq('abandoned')
      end
    end

    it 'links child memory to parent session memory by source_id' do
      # Finalize the default session first to free up the unique constraint on this room
      described_class.finalize_session(session)

      parent_session = WorldMemorySession.create(
        room_id: room.id,
        started_at: Time.now - 7200,
        ended_at: Time.now - 3600,
        last_activity_at: Time.now - 3600,
        status: 'active',
        log_buffer: "Alice says: Parent memory\nBob says: Still talking",
        message_count: 10,
        publicity_level: 'public'
      )

      # Finalize parent first so it's no longer 'active', avoiding unique constraint violation
      parent_memory = described_class.finalize_session(parent_session)

      child_session = WorldMemorySession.create(
        room_id: room.id,
        started_at: Time.now - 1800,
        ended_at: Time.now,
        last_activity_at: Time.now,
        status: 'active',
        log_buffer: "Alice says: Child memory\nBob says: Continuing",
        message_count: 10,
        publicity_level: 'public',
        parent_session_id: parent_session.id
      )

      child_memory = described_class.finalize_session(child_session)

      expect(parent_memory).not_to be_nil
      expect(child_memory).not_to be_nil
      expect(child_memory.parent_memory_id).to eq(parent_memory.id)
    end
  end

  describe '.finalize_session_async' do
    let(:session) { double('WorldMemorySession') }

    it 'returns a thread' do
      allow(described_class).to receive(:finalize_session)

      thread = described_class.finalize_session_async(session)

      expect(thread).to be_a(Thread)
      thread.join
    end
  end

  describe '.create_from_event_async' do
    let(:event) { double('Event') }

    it 'returns a thread and delegates to create_from_event' do
      allow(described_class).to receive(:create_from_event)

      thread = described_class.create_from_event_async(event)

      expect(thread).to be_a(Thread)
      thread.join
      expect(described_class).to have_received(:create_from_event).with(event)
    end
  end

  describe '.retrieve_relevant' do
    let!(:memory) do
      WorldMemory.create(
        summary: 'A dragon attacked the village',
        importance: 7,
        publicity_level: 'public',
        memory_at: Time.now,
        started_at: Time.now - 3600,
        ended_at: Time.now
      )
    end

    it 'returns relevant memories' do
      # Set up the stub with actual memory id
      embedding_double = double('Embedding', content_id: memory.id)
      allow(Embedding).to receive(:similar_to).and_return([
        { embedding: embedding_double, similarity: 0.9 }
      ])

      # Use include_private to bypass the searchable dataset method issue
      memories = described_class.retrieve_relevant(query: 'dragon attack', limit: 5, include_private: true)

      expect(memories).to include(memory)
    end

    it 'uses searchable scope when include_private is false' do
      embedding_double = double('Embedding', content_id: memory.id)
      allow(Embedding).to receive(:similar_to).and_return([
        { embedding: embedding_double, similarity: 0.9 }
      ])

      expect {
        described_class.retrieve_relevant(query: 'dragon attack', limit: 5, include_private: false)
      }.not_to raise_error
    end

    context 'when embedding fails' do
      before do
        allow(LLM::Client).to receive(:embed).and_return({ success: false })
      end

      it 'returns empty array' do
        memories = described_class.retrieve_relevant(query: 'test', limit: 5)
        expect(memories).to eq([])
      end
    end
  end

  describe '.memories_at_location' do
    let!(:memory) do
      WorldMemory.create(
        summary: 'Test memory',
        importance: 5,
        publicity_level: 'public',
        memory_at: Time.now,
        started_at: Time.now - 3600,
        ended_at: Time.now
      )
    end

    before do
      WorldMemoryLocation.create(
        world_memory_id: memory.id,
        room_id: room.id,
        is_primary: true
      )
    end

    it 'returns memories for the room' do
      allow(WorldMemory).to receive(:for_room).and_return(WorldMemory.where(id: memory.id))

      memories = described_class.memories_at_location(room: room, limit: 10)

      expect(memories.map(&:id)).to include(memory.id)
    end
  end

  describe '.retrieve_for_npc' do
    let(:npc) { create(:character, :npc, forename: 'Guide') }

    it 'returns memories for NPC context' do
      memories = described_class.retrieve_for_npc(
        npc: npc,
        query: 'village history',
        room: room,
        limit: 5
      )

      expect(memories).to be_an(Array)
    end

    it 'returns empty array for nil NPC' do
      memories = described_class.retrieve_for_npc(
        npc: nil,
        query: 'test',
        room: room,
        limit: 5
      )

      expect(memories).to eq([])
    end
  end

  describe 'distance calculation methods' do
    describe '.calculate_location_hex_distance' do
      let(:world) { create(:world) }
      let(:zone) { create(:zone, world: world) }

      it 'returns 0 for same coordinates' do
        origin = create(:location, zone: zone, latitude: 5.0, longitude: 5.0)
        expect(described_class.calculate_location_hex_distance(origin, origin)).to eq(0)
      end

      it 'returns 0 for nil coordinates' do
        origin = create(:location, zone: zone, latitude: nil, longitude: nil)
        destination = create(:location, zone: zone, latitude: 5.0, longitude: 5.0)
        expect(described_class.calculate_location_hex_distance(origin, destination)).to eq(0)
      end

      it 'calculates distance for different coordinates' do
        origin = create(:location, zone: zone, latitude: 0.0, longitude: 0.0)
        destination = create(:location, zone: zone, latitude: 3.0, longitude: 3.0)
        distance = described_class.calculate_location_hex_distance(origin, destination)
        expect(distance).to be > 0
      end
    end

    describe '.calculate_geographic_distance' do
      it 'returns infinity for nil points' do
        expect(described_class.calculate_geographic_distance(nil, nil)).to eq(Float::INFINITY)
      end

      it 'calculates distance between points' do
        point1 = { longitude: 0.0, latitude: 0.0 }
        point2 = { longitude: 3.0, latitude: 4.0 }

        distance = described_class.calculate_geographic_distance(point1, point2)

        expect(distance).to eq(5.0) # 3-4-5 triangle
      end
    end

    describe '.calculate_location_weight' do
      it 'returns 1.0 for distance 0' do
        expect(described_class.calculate_location_weight(0)).to eq(1.0)
      end

      it 'returns 0.95 for distance 1' do
        expect(described_class.calculate_location_weight(1)).to eq(0.95)
      end

      it 'returns 0.1 for very large distance' do
        expect(described_class.calculate_location_weight(100)).to eq(0.1)
      end

      it 'returns decreasing weights for increasing distances' do
        weights = [0, 2, 10, 20, 40, 60].map { |d| described_class.calculate_location_weight(d) }
        expect(weights).to eq(weights.sort.reverse)
      end
    end

    describe '.calculate_distance_modifier' do
      it 'returns 1.0 for nil distance' do
        expect(described_class.calculate_distance_modifier(nil)).to eq(1.0)
      end

      it 'returns 1.0 for infinity distance' do
        expect(described_class.calculate_distance_modifier(Float::INFINITY)).to eq(1.0)
      end

      it 'returns 1.5 for distance 0' do
        expect(described_class.calculate_distance_modifier(0)).to eq(1.5)
      end

      it 'returns 1.2 for same building' do
        expect(described_class.calculate_distance_modifier(0.5)).to eq(1.2)
      end
    end
  end

  describe '.format_for_npc_context' do
    it 'returns empty string for empty memories array' do
      expect(described_class.format_for_npc_context([])).to eq('')
    end

    context 'with memories' do
      let(:memory) do
        WorldMemory.create(
          summary: 'A dragon attacked',
          importance: 7,
          publicity_level: 'public',
          memory_at: Time.now,
          started_at: Time.now - 3600,
          ended_at: Time.now
        )
      end

      before do
        allow(memory).to receive(:primary_room).and_return(room)
        allow(memory).to receive(:recent?).and_return(true)
      end

      it 'formats memories with location' do
        result = described_class.format_for_npc_context([memory])

        expect(result).to include('A dragon attacked')
        expect(result).to include(room.name)
      end

      it 'marks direct involvement for NPC' do
        npc = create(:character, :npc)
        WorldMemoryCharacter.create(
          world_memory_id: memory.id,
          character_id: npc.id,
          role: 'participant'
        )

        result = described_class.format_for_npc_context([memory], npc: npc)

        expect(result).to include('[You witnessed]')
      end

      it 'marks direct involvement when linked via WorldMemoryNpc' do
        npc = create(:character, :npc)
        WorldMemoryNpc.create(
          world_memory_id: memory.id,
          character_id: npc.id,
          role: 'involved'
        )

        result = described_class.format_for_npc_context([memory], npc: npc)

        expect(result).to include('[You witnessed]')
      end
    end
  end

  describe '.memories_for_character' do
    it 'returns memories involving the character' do
      allow(WorldMemory).to receive(:for_character).and_return(WorldMemory.where(id: nil))

      memories = described_class.memories_for_character(character: character, limit: 10)

      expect(memories).to be_an(Array)
    end
  end

  describe 'abstraction methods' do
    describe '.check_and_abstract!' do
      it 'does not raise errors' do
        expect { described_class.check_and_abstract! }.not_to raise_error
      end

      it 'does not loop forever when global abstraction summary generation fails' do
        GameConfig::NpcMemory::ABSTRACTION_THRESHOLD.times do |i|
          create(:world_memory,
                 summary: "Global memory #{i}",
                 abstraction_level: 1,
                 abstracted_into_id: nil,
                 started_at: Time.now - 3600,
                 ended_at: Time.now - 1800)
        end

        allow(described_class).to receive(:generate_abstraction_summary).and_return(nil)

        expect {
          Timeout.timeout(1) { described_class.check_and_abstract! }
        }.not_to raise_error
      end

      it 'does not loop forever when branch abstraction summary generation fails' do
        GameConfig::NpcMemory::ABSTRACTION_THRESHOLD.times do |i|
          memory = create(:world_memory,
                          summary: "Branch memory #{i}",
                          abstraction_level: 1,
                          abstracted_into_id: nil,
                          started_at: Time.now - 3600,
                          ended_at: Time.now - 1800)
          WorldMemoryLocation.create(world_memory_id: memory.id, room_id: room.id, is_primary: true)
        end

        allow(WorldMemory).to receive(:needs_abstraction?).and_return(false)
        allow(described_class).to receive(:generate_abstraction_summary).and_return(nil)

        expect {
          Timeout.timeout(1) { described_class.check_and_abstract! }
        }.not_to raise_error
      end
    end

    describe '.abstract_memories!' do
      context 'at max abstraction level' do
        it 'returns nil' do
          result = described_class.abstract_memories!(level: 4)
          expect(result).to be_nil
        end
      end

      context 'with enough level-1 memories' do
        it 'creates DAG abstraction records for the global branch' do
          GameConfig::NpcMemory::ABSTRACTION_THRESHOLD.times do |i|
            create(:world_memory,
                   summary: "Memory #{i}",
                   abstraction_level: 1,
                   abstracted_into_id: nil,
                   started_at: Time.now - 3600,
                   ended_at: Time.now - 1800)
          end

          abstract = described_class.abstract_memories!(level: 1)

          expect(abstract).to be_a(WorldMemory)
          expect(abstract.branch_type).to eq('global')
          expect(WorldMemoryAbstraction.where(target_memory_id: abstract.id, branch_type: 'global').count)
            .to eq(GameConfig::NpcMemory::ABSTRACTION_THRESHOLD)
        end

        it 'does not recursively call check_and_abstract! from abstract_memories!' do
          GameConfig::NpcMemory::ABSTRACTION_THRESHOLD.times do |i|
            create(:world_memory,
                   summary: "Memory #{i}",
                   abstraction_level: 1,
                   abstracted_into_id: nil,
                   started_at: Time.now - 3600,
                   ended_at: Time.now - 1800)
          end

          expect(described_class).not_to receive(:check_and_abstract!)

          described_class.abstract_memories!(level: 1)
        end
      end
    end
  end

  describe 'private session helpers' do
    describe '.create_session_with_retry' do
      it 'returns existing active session when unique constraint is hit' do
        existing = WorldMemorySession.create(
          room_id: room.id,
          event_id: nil,
          started_at: Time.now - 60,
          last_activity_at: Time.now - 10,
          status: 'active',
          publicity_level: 'public'
        )

        allow(WorldMemorySession).to receive(:create).and_raise(Sequel::UniqueConstraintViolation.new('duplicate'))
        allow(WorldMemorySession).to receive(:active_for_room_context).with(room.id, nil).and_return(existing)

        result = described_class.send(
          :create_session_with_retry,
          room_id: room.id,
          event_id: nil,
          create_attributes: {
            room_id: room.id,
            event_id: nil,
            started_at: Time.now,
            last_activity_at: Time.now,
            status: 'active',
            publicity_level: 'public'
          }
        )

        expect(result).to eq(existing)
      end
    end
  end

  describe 'cleanup methods' do
    describe '.purge_expired_raw_logs!' do
      it 'returns count of purged logs' do
        allow(WorldMemory).to receive(:expired_raw_logs).and_return([])

        count = described_class.purge_expired_raw_logs!

        expect(count).to eq(0)
      end
    end

    describe '.finalize_stale_sessions!' do
      it 'returns count of finalized sessions' do
        allow(WorldMemorySession).to receive(:stale_sessions).and_return([])

        count = described_class.finalize_stale_sessions!

        expect(count).to eq(0)
      end
    end

    describe '.apply_decay!' do
      it 'returns count of decayed memories' do
        count = described_class.apply_decay!

        expect(count).to be >= 0
      end
    end
  end

  describe '.retrieve_nearby_memories' do
    it 'returns array of memory data' do
      result = described_class.retrieve_nearby_memories(room, limit: 10)

      expect(result).to be_an(Array)
    end

    it 'returns empty array for nil room' do
      result = described_class.retrieve_nearby_memories(nil)

      expect(result).to eq([])
    end
  end

  describe '.calculate_memory_distance' do
    let(:memory) { WorldMemory.create(summary: 'Test', publicity_level: 'public', memory_at: Time.now, started_at: Time.now - 3600, ended_at: Time.now) }

    it 'returns infinity when memory has no room' do
      allow(memory).to receive(:primary_room).and_return(nil)

      distance = described_class.calculate_memory_distance(room, memory)

      expect(distance).to eq(Float::INFINITY)
    end

    it 'returns 0 for same room' do
      WorldMemoryLocation.create(world_memory_id: memory.id, room_id: room.id, is_primary: true)
      allow(memory).to receive(:primary_room).and_return(room)

      distance = described_class.calculate_memory_distance(room, memory)

      expect(distance).to eq(0)
    end

    it 'returns 1 for same location different room' do
      other_room = create(:room, location: location, name: 'Other Room')
      WorldMemoryLocation.create(world_memory_id: memory.id, room_id: other_room.id, is_primary: true)
      allow(memory).to receive(:primary_room).and_return(other_room)

      distance = described_class.calculate_memory_distance(room, memory)

      expect(distance).to eq(1)
    end

    it 'handles different zones using room coordinates without raising' do
      other_zone = create(:zone, world: world, name: 'Far Zone')
      far_location = create(:location, zone: other_zone, latitude: 10.0, longitude: 10.0)
      near_location = create(:location, zone: area, latitude: 0.0, longitude: 0.0)
      origin_room = create(:room, location: near_location)
      far_room = create(:room, location: far_location)

      WorldMemoryLocation.create(world_memory_id: memory.id, room_id: far_room.id, is_primary: true)
      allow(memory).to receive(:primary_room).and_return(far_room)

      expect {
        described_class.calculate_memory_distance(origin_room, memory)
      }.not_to raise_error
    end
  end
end
