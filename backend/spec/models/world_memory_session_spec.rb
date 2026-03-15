# frozen_string_literal: true

require 'spec_helper'

RSpec.describe WorldMemorySession do
  let(:room) { create(:room) }
  let(:character) { create(:character) }
  let(:other_character) { create(:character) }

  describe 'constants' do
    it 'defines STATUSES' do
      expect(described_class::STATUSES).to eq(%w[active finalizing finalized abandoned])
    end

    it 'defines INACTIVITY_TIMEOUT_HOURS' do
      expect(described_class::INACTIVITY_TIMEOUT_HOURS).to eq(2)
    end

    it 'defines MIN_MESSAGES_FOR_MEMORY' do
      expect(described_class::MIN_MESSAGES_FOR_MEMORY).to eq(5)
    end
  end

  describe 'associations' do
    it 'belongs to room' do
      session = create(:world_memory_session, room: room)
      expect(session.room).to eq(room)
    end

    it 'belongs to event (optional)' do
      event = create(:event)
      session = create(:world_memory_session, room: room, event: event)
      expect(session.event).to eq(event)
    end

    it 'belongs to parent_session (optional)' do
      parent = create(:world_memory_session, room: room)
      child_room = create(:room)
      child = create(:world_memory_session, room: child_room, parent_session: parent)
      expect(child.parent_session).to eq(parent)
    end

    it 'has many child_sessions' do
      parent = create(:world_memory_session, room: room)
      child_room1 = create(:room)
      child_room2 = create(:room)
      child1 = create(:world_memory_session, room: child_room1, parent_session: parent)
      child2 = create(:world_memory_session, room: child_room2, parent_session: parent)

      expect(parent.child_sessions).to include(child1, child2)
    end

    it 'has many session_characters' do
      session = create(:world_memory_session, room: room)
      sc = create(:world_memory_session_character, session: session, character: character)

      expect(session.session_characters).to include(sc)
    end

    it 'has many session_rooms' do
      session = create(:world_memory_session, room: room)
      other_room = create(:room)
      sr = create(:world_memory_session_room, session: session, room: other_room)

      expect(session.session_rooms).to include(sr)
    end
  end

  describe 'validations' do
    it 'requires room_id' do
      session = described_class.new(
        started_at: Time.now,
        last_activity_at: Time.now
      )
      expect(session.valid?).to be false
      expect(session.errors[:room_id]).not_to be_empty
    end

    it 'requires started_at' do
      session = described_class.new(
        room_id: room.id,
        last_activity_at: Time.now
      )
      expect(session.valid?).to be false
      expect(session.errors[:started_at]).not_to be_empty
    end

    it 'requires last_activity_at' do
      session = described_class.new(
        room_id: room.id,
        started_at: Time.now
      )
      expect(session.valid?).to be false
      expect(session.errors[:last_activity_at]).not_to be_empty
    end

    it 'validates status is in STATUSES' do
      session = build(:world_memory_session, room: room, status: 'invalid')
      expect(session.valid?).to be false
    end

    it 'accepts valid status values' do
      described_class::STATUSES.each do |status|
        session = build(:world_memory_session, room: room, status: status)
        expect(session.valid?).to be true
      end
    end
  end

  describe '#active?' do
    it 'returns true for active status' do
      session = create(:world_memory_session, :active, room: room)
      expect(session.active?).to be true
    end

    it 'returns false for finalizing status' do
      session = create(:world_memory_session, :finalizing, room: room)
      expect(session.active?).to be false
    end

    it 'returns false for finalized status' do
      session = create(:world_memory_session, :finalized, room: room)
      expect(session.active?).to be false
    end

    it 'returns false for abandoned status' do
      session = create(:world_memory_session, :abandoned, room: room)
      expect(session.active?).to be false
    end
  end

  describe '#finalizing?' do
    it 'returns true for finalizing status' do
      session = create(:world_memory_session, :finalizing, room: room)
      expect(session.finalizing?).to be true
    end

    it 'returns false for other statuses' do
      session = create(:world_memory_session, :active, room: room)
      expect(session.finalizing?).to be false
    end
  end

  describe '#finalized?' do
    it 'returns true for finalized status' do
      session = create(:world_memory_session, :finalized, room: room)
      expect(session.finalized?).to be true
    end

    it 'returns false for other statuses' do
      session = create(:world_memory_session, :active, room: room)
      expect(session.finalized?).to be false
    end
  end

  describe '#abandoned?' do
    it 'returns true for abandoned status' do
      session = create(:world_memory_session, :abandoned, room: room)
      expect(session.abandoned?).to be true
    end

    it 'returns false for other statuses' do
      session = create(:world_memory_session, :active, room: room)
      expect(session.abandoned?).to be false
    end
  end

  describe '#stale?' do
    it 'returns true when active and inactive for 2+ hours' do
      session = create(:world_memory_session, :stale, room: room)
      expect(session.stale?).to be true
    end

    it 'returns false when recently active' do
      session = create(:world_memory_session, :active, room: room, last_activity_at: Time.now)
      expect(session.stale?).to be false
    end

    it 'returns false when not active status' do
      session = create(:world_memory_session, :finalized, room: room,
                                              last_activity_at: Time.now - (3 * 3600))
      expect(session.stale?).to be false
    end
  end

  describe '#hours_since_activity' do
    it 'calculates hours since last activity' do
      session = create(:world_memory_session, room: room,
                                              last_activity_at: Time.now - 7200) # 2 hours ago
      expect(session.hours_since_activity).to be_within(0.1).of(2.0)
    end
  end

  describe '#sufficient_for_memory?' do
    it 'returns true when message_count >= MIN_MESSAGES_FOR_MEMORY' do
      session = create(:world_memory_session, :sufficient_for_memory, room: room)
      expect(session.sufficient_for_memory?).to be true
    end

    it 'returns false when message_count < MIN_MESSAGES_FOR_MEMORY' do
      session = create(:world_memory_session, :insufficient_for_memory, room: room)
      expect(session.sufficient_for_memory?).to be false
    end
  end

  describe '#active_character_count' do
    let(:session) { create(:world_memory_session, room: room) }

    it 'returns count of active characters' do
      create(:world_memory_session_character, session: session, character: character, is_active: true)
      create(:world_memory_session_character, session: session, character: other_character, is_active: true)

      expect(session.active_character_count).to eq(2)
    end

    it 'excludes inactive characters' do
      create(:world_memory_session_character, session: session, character: character, is_active: true)
      create(:world_memory_session_character, :inactive, session: session, character: other_character)

      expect(session.active_character_count).to eq(1)
    end

    it 'returns 0 when no characters' do
      expect(session.active_character_count).to eq(0)
    end
  end

  describe '#active_character_ids' do
    let(:session) { create(:world_memory_session, room: room) }

    it 'returns IDs of active characters' do
      create(:world_memory_session_character, session: session, character: character, is_active: true)
      create(:world_memory_session_character, :inactive, session: session, character: other_character)

      expect(session.active_character_ids).to eq([character.id])
    end

    it 'returns empty array when no active characters' do
      expect(session.active_character_ids).to eq([])
    end
  end

  describe '#add_character!' do
    let(:session) { create(:world_memory_session, room: room) }

    it 'creates a new session character record' do
      expect { session.add_character!(character) }.to change {
        WorldMemorySessionCharacter.where(session_id: session.id).count
      }.by(1)
    end

    it 'marks character as active' do
      sc = session.add_character!(character)
      expect(sc.is_active).to be true
    end

    it 'sets joined_at timestamp' do
      sc = session.add_character!(character)
      expect(sc.joined_at).not_to be_nil
    end

    it 'reactivates existing inactive character' do
      sc = create(:world_memory_session_character, :inactive, session: session, character: character)
      session.add_character!(character)
      sc.refresh

      expect(sc.is_active).to be true
      expect(sc.left_at).to be_nil
    end

    it 'does not create duplicate when character already active' do
      create(:world_memory_session_character, session: session, character: character)

      expect { session.add_character!(character) }.not_to change {
        WorldMemorySessionCharacter.where(session_id: session.id).count
      }
    end
  end

  describe '#remove_character!' do
    let(:session) { create(:world_memory_session, room: room) }

    it 'marks character as inactive' do
      sc = create(:world_memory_session_character, session: session, character: character)
      session.remove_character!(character)
      sc.refresh

      expect(sc.is_active).to be false
    end

    it 'sets left_at timestamp' do
      sc = create(:world_memory_session_character, session: session, character: character)
      session.remove_character!(character)
      sc.refresh

      expect(sc.left_at).not_to be_nil
    end

    it 'does nothing when character not in session' do
      expect { session.remove_character!(character) }.not_to raise_error
    end
  end

  describe '#increment_character_messages!' do
    let(:session) { create(:world_memory_session, room: room) }

    it 'increments message count for character' do
      sc = create(:world_memory_session_character, session: session, character: character, message_count: 5)
      session.increment_character_messages!(character)
      sc.refresh

      expect(sc.message_count).to eq(6)
    end

    it 'handles nil message_count' do
      sc = create(:world_memory_session_character, session: session, character: character, message_count: nil)
      session.increment_character_messages!(character)
      sc.refresh

      expect(sc.message_count).to eq(1)
    end

    it 'does nothing when character not in session' do
      expect { session.increment_character_messages!(character) }.not_to raise_error
    end
  end

  describe '#add_room!' do
    let(:session) { create(:world_memory_session, room: room) }
    let(:other_room) { create(:room) }

    it 'creates a new session room record' do
      expect { session.add_room!(other_room) }.to change {
        WorldMemorySessionRoom.where(session_id: session.id).count
      }.by(1)
    end

    it 'sets first_seen_at and last_seen_at' do
      sr = session.add_room!(other_room)
      expect(sr.first_seen_at).not_to be_nil
      expect(sr.last_seen_at).not_to be_nil
    end

    it 'updates last_seen_at for existing room' do
      sr = create(:world_memory_session_room, session: session, room: other_room,
                                              first_seen_at: Time.now - 3600,
                                              last_seen_at: Time.now - 3600)
      original_first = sr.first_seen_at
      original_last = sr.last_seen_at

      session.add_room!(other_room)
      sr.refresh

      expect(sr.first_seen_at).to eq(original_first)
      expect(sr.last_seen_at).to be > original_last
    end
  end

  describe '#update_room_activity!' do
    let(:session) { create(:world_memory_session, room: room) }
    let(:other_room) { create(:room) }

    it 'increments message count and updates last_seen_at' do
      sr = create(:world_memory_session_room, session: session, room: other_room,
                                              message_count: 5,
                                              last_seen_at: Time.now - 3600)
      original_last = sr.last_seen_at

      session.update_room_activity!(other_room)
      sr.refresh

      expect(sr.message_count).to eq(6)
      expect(sr.last_seen_at).to be > original_last
    end

    it 'handles nil message_count' do
      sr = create(:world_memory_session_room, session: session, room: other_room, message_count: nil)
      session.update_room_activity!(other_room)
      sr.refresh

      expect(sr.message_count).to eq(1)
    end
  end

  describe '#append_log!' do
    let(:session) { create(:world_memory_session, room: room, message_count: 0, log_buffer: '') }

    it 'appends formatted content to log buffer' do
      session.append_log!('Hello world!', sender_name: 'Alice', type: :say, timestamp: Time.parse('2024-01-01 12:00:00'))

      expect(session.log_buffer).to include('[12:00] Alice (say): Hello world!')
    end

    it 'increments message count' do
      session.append_log!('Test', sender_name: 'Bob', type: :emote)

      expect(session.message_count).to eq(1)
    end

    it 'updates last_activity_at' do
      original_activity = session.last_activity_at
      session.append_log!('Test', sender_name: 'Carol', type: :say)

      expect(session.last_activity_at).to be >= original_activity
    end

    it 'does not append when has_private_content is true' do
      private_session = create(:world_memory_session, :private_content, room: room)
      original_buffer = private_session.log_buffer

      private_session.append_log!('Secret stuff', sender_name: 'Eve', type: :whisper)

      expect(private_session.log_buffer).to eq(original_buffer)
    end
  end

  describe '#mark_private!' do
    let(:session) { create(:world_memory_session, :with_messages, room: room) }

    it 'sets has_private_content to true' do
      session.mark_private!
      expect(session.has_private_content).to be true
    end

    it 'replaces log buffer with excluded message' do
      session.mark_private!
      expect(session.log_buffer).to eq('[PRIVATE CONTENT EXCLUDED]')
    end
  end

  describe '#update_publicity!' do
    let(:session) { create(:world_memory_session, room: room, publicity_level: 'public') }

    it 'updates to more restrictive level' do
      # PUBLICITY_LEVELS = %w[private secluded semi_public public private_event public_event]
      # Lower index = more restrictive
      session.update_publicity!('secluded')
      expect(session.publicity_level).to eq('secluded')
    end

    it 'does not update to less restrictive level' do
      session.update(publicity_level: 'private')
      session.update_publicity!('public')
      expect(session.publicity_level).to eq('private')
    end
  end

  describe '#finalize!' do
    let(:session) { create(:world_memory_session, :active, room: room) }

    it 'changes status to finalizing' do
      session.finalize!
      expect(session.status).to eq('finalizing')
    end

    it 'sets ended_at timestamp' do
      session.finalize!
      expect(session.ended_at).not_to be_nil
    end
  end

  describe '#mark_finalized!' do
    let(:session) { create(:world_memory_session, :finalizing, room: room) }

    it 'changes status to finalized' do
      session.mark_finalized!
      expect(session.status).to eq('finalized')
    end
  end

  describe '#abandon!' do
    let(:session) { create(:world_memory_session, :active, room: room) }

    it 'changes status to abandoned' do
      session.abandon!
      expect(session.status).to eq('abandoned')
    end

    it 'sets ended_at timestamp' do
      session.abandon!
      expect(session.ended_at).not_to be_nil
    end
  end

  describe '.active_for_room' do
    it 'returns active session for room' do
      session = create(:world_memory_session, :active, room: room)
      create(:world_memory_session, :finalized, room: room)

      result = described_class.active_for_room(room.id)
      expect(result).to eq(session)
    end

    it 'returns nil when no active session' do
      create(:world_memory_session, :finalized, room: room)

      result = described_class.active_for_room(room.id)
      expect(result).to be_nil
    end

    it 'does not return sessions from other rooms' do
      other_room = create(:room)
      create(:world_memory_session, :active, room: other_room)

      result = described_class.active_for_room(room.id)
      expect(result).to be_nil
    end
  end

  describe '.active_for_room_context' do
    it 'returns active session for matching room and event_id' do
      matching_event = create(:event)
      matching = create(:world_memory_session, :active, room: room, event: matching_event)
      create(:world_memory_session, :active, room: room, event_id: nil)

      result = described_class.active_for_room_context(room.id, matching_event.id)
      expect(result).to eq(matching)
    end

    it 'returns nil when context does not match' do
      event = create(:event)
      create(:world_memory_session, :active, room: room, event: event)

      result = described_class.active_for_room_context(room.id, nil)
      expect(result).to be_nil
    end
  end

  describe '.stale_sessions' do
    it 'returns active sessions inactive for 2+ hours' do
      stale = create(:world_memory_session, :stale, room: room)
      _recent = create(:world_memory_session, :active, room: create(:room))

      results = described_class.stale_sessions.all
      expect(results).to include(stale)
    end

    it 'excludes finalized sessions' do
      old_finalized = create(:world_memory_session, :finalized, room: room,
                                                    last_activity_at: Time.now - (3 * 3600))

      results = described_class.stale_sessions.all
      expect(results).not_to include(old_finalized)
    end
  end

  describe '.pending_finalization' do
    it 'returns sessions with finalizing status' do
      finalizing = create(:world_memory_session, :finalizing, room: room)
      _active = create(:world_memory_session, :active, room: create(:room))

      results = described_class.pending_finalization.all
      expect(results).to include(finalizing)
      expect(results.length).to eq(1)
    end
  end

  describe 'integration: full session lifecycle' do
    let(:session) { create(:world_memory_session, :active, room: room) }

    it 'tracks characters joining, messaging, and leaving' do
      # Characters join
      session.add_character!(character)
      session.add_character!(other_character)
      expect(session.active_character_count).to eq(2)

      # Characters send messages
      session.append_log!('Hello!', sender_name: character.full_name, type: :say)
      session.increment_character_messages!(character)

      session.append_log!('Hi back!', sender_name: other_character.full_name, type: :say)
      session.increment_character_messages!(other_character)

      expect(session.message_count).to eq(2)

      # One character leaves
      session.remove_character!(other_character)
      expect(session.active_character_count).to eq(1)
      expect(session.active_character_ids).to eq([character.id])

      # Session finalizes
      session.finalize!
      expect(session.finalizing?).to be true

      session.mark_finalized!
      expect(session.finalized?).to be true
    end

    it 'handles room tracking across multiple rooms' do
      other_room = create(:room)
      third_room = create(:room)

      session.add_room!(other_room)
      session.add_room!(third_room)

      session.update_room_activity!(other_room)
      session.update_room_activity!(other_room)
      session.update_room_activity!(third_room)

      other_room_record = session.session_rooms_dataset.where(room_id: other_room.id).first
      third_room_record = session.session_rooms_dataset.where(room_id: third_room.id).first

      expect(other_room_record.message_count).to eq(2)
      expect(third_room_record.message_count).to eq(1)
    end
  end
end
