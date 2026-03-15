# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RpLoggingService do
  let(:room) { double('Room', id: 100, name: 'Test Room') }

  let(:character) { double('Character', id: 1, full_name: 'Alice Smith') }

  let(:character_instance) do
    double('CharacterInstance',
           id: 1,
           character_id: 1,
           character: character,
           current_room_id: 100,
           current_room: room,
           reality_id: 1,
           private_mode?: false,
           show_private_logs?: true,
           in_event_id: nil,
           timeline: nil,
           update: true)
  end

  let(:sender_instance) do
    double('CharacterInstance',
           id: 2,
           character_id: 2,
           reality_id: 1,
           private_mode?: false,
           in_event_id: nil)
  end

  let(:witnesses_dataset) do
    dataset = double('Dataset')
    allow(dataset).to receive(:where).and_return(dataset)
    allow(dataset).to receive(:exclude).and_return(dataset)
    allow(dataset).to receive(:eager).and_return(dataset)
    allow(dataset).to receive(:all).and_return([character_instance])
    dataset
  end

  before do
    allow(Room).to receive(:[]).with(100).and_return(room)
    allow(room).to receive(:characters_here).and_return(witnesses_dataset)
    allow(RpLog).to receive(:duplicate?).and_return(false)
    allow(RpLog).to receive(:create).and_return(double('RpLog'))
  end

  describe '.log_to_room' do
    it 'creates log entry for each witness' do
      expect(RpLog).to receive(:create).with(hash_including(
        character_instance_id: 1,
        room_id: 100,
        content: 'Test message',
        log_type: 'say'
      ))

      described_class.log_to_room(100, 'Test message', sender: sender_instance, type: :say)
    end

    it 'passes html content when provided' do
      expect(RpLog).to receive(:create).with(hash_including(
        html_content: '<b>Test</b>'
      ))

      described_class.log_to_room(100, 'Test', sender: sender_instance, type: :say, html: '<b>Test</b>')
    end

    context 'with blank content' do
      it 'returns early' do
        expect(RpLog).not_to receive(:create)

        described_class.log_to_room(100, '', sender: sender_instance, type: :say)
      end

      it 'returns early for nil content' do
        expect(RpLog).not_to receive(:create)

        described_class.log_to_room(100, nil, sender: sender_instance, type: :say)
      end
    end

    context 'with nil room_id' do
      it 'returns early' do
        expect(RpLog).not_to receive(:create)

        described_class.log_to_room(nil, 'Test', sender: sender_instance, type: :say)
      end
    end

    context 'with excluded character' do
      it 'excludes specified character instances' do
        expect(witnesses_dataset).to receive(:exclude).with(id: [1]).and_return(witnesses_dataset)

        described_class.log_to_room(100, 'Test', sender: sender_instance, type: :say, exclude: [1])
      end
    end

    context 'with private mode' do
      before do
        allow(sender_instance).to receive(:private_mode?).and_return(true)
      end

      it 'sets is_private to true' do
        expect(RpLog).to receive(:create).with(hash_including(is_private: true))

        described_class.log_to_room(100, 'Test', sender: sender_instance, type: :say)
      end
    end

    context 'with event_id' do
      it 'uses provided event_id' do
        expect(RpLog).to receive(:create).with(hash_including(event_id: 5))

        described_class.log_to_room(100, 'Test', sender: sender_instance, type: :say, event_id: 5)
      end

      it 'auto-detects event_id from sender' do
        allow(sender_instance).to receive(:in_event_id).and_return(10)

        expect(RpLog).to receive(:create).with(hash_including(event_id: 10))

        described_class.log_to_room(100, 'Test', sender: sender_instance, type: :say)
      end
    end

    it 'uses room visibility scoping with sender reality and viewer' do
      expect(room).to receive(:characters_here)
        .with(sender_instance.reality_id, viewer: sender_instance)
        .and_return(witnesses_dataset)

      described_class.log_to_room(100, 'Scoped message', sender: sender_instance, type: :say)
    end
  end

  describe '.log_to_character' do
    it 'creates log entry for specific character' do
      expect(RpLog).to receive(:create).with(hash_including(
        character_instance_id: 1,
        content: 'Private message'
      ))

      described_class.log_to_character(character_instance, 'Private message', sender: sender_instance, type: :whisper)
    end

    context 'with blank content' do
      it 'returns early' do
        expect(RpLog).not_to receive(:create)

        described_class.log_to_character(character_instance, '', sender: sender_instance, type: :whisper)
      end
    end

    context 'with nil character_instance' do
      it 'returns early' do
        expect(RpLog).not_to receive(:create)

        described_class.log_to_character(nil, 'Test', sender: sender_instance, type: :whisper)
      end
    end

    context 'when character is in private mode' do
      before do
        allow(character_instance).to receive(:private_mode?).and_return(true)
      end

      it 'sets is_private to true' do
        expect(RpLog).to receive(:create).with(hash_including(is_private: true))

        described_class.log_to_character(character_instance, 'Test', sender: sender_instance, type: :whisper)
      end
    end
  end

  describe '.log_movement' do
    let(:from_room) { double('Room', id: 100) }
    let(:to_room) { double('Room', id: 200) }

    before do
      allow(LogBreakpoint).to receive(:record_move)
      allow(WorldMemoryService).to receive(:handle_character_movement)
      allow(from_room).to receive(:characters_here).and_return(witnesses_dataset)
      allow(to_room).to receive(:characters_here).and_return(witnesses_dataset)
    end

    it 'logs departure to origin room witnesses' do
      expect(RpLog).to receive(:create).with(hash_including(
        log_type: 'departure',
        content: 'Alice leaves north.'
      ))

      described_class.log_movement(
        character_instance,
        from_room: from_room,
        to_room: to_room,
        departure_message: 'Alice leaves north.'
      )
    end

    it 'logs arrival to destination room witnesses' do
      expect(RpLog).to receive(:create).with(hash_including(
        log_type: 'arrival',
        content: 'Alice arrives from the south.'
      ))

      described_class.log_movement(
        character_instance,
        from_room: from_room,
        to_room: to_room,
        arrival_message: 'Alice arrives from the south.'
      )
    end

    it 'records movement breakpoint' do
      expect(LogBreakpoint).to receive(:record_move).with(character_instance, to_room)

      described_class.log_movement(
        character_instance,
        from_room: from_room,
        to_room: to_room
      )
    end

    it 'notifies world memory service' do
      expect(WorldMemoryService).to receive(:handle_character_movement).with(
        character_instance: character_instance,
        from_room: from_room,
        to_room: to_room
      )

      described_class.log_movement(
        character_instance,
        from_room: from_room,
        to_room: to_room
      )
    end
  end

  describe '.log_room_description' do
    it 'creates room description log entry' do
      expect(RpLog).to receive(:create).with(hash_including(
        log_type: 'room_desc',
        content: 'A dark chamber.',
        sender_character_id: nil
      ))

      described_class.log_room_description(character_instance, room, 'A dark chamber.')
    end

    it 'returns early if character_instance is nil' do
      expect(RpLog).not_to receive(:create)

      described_class.log_room_description(nil, room, 'A dark chamber.')
    end

    it 'returns early if room is nil' do
      expect(RpLog).not_to receive(:create)

      described_class.log_room_description(character_instance, nil, 'A dark chamber.')
    end
  end

  describe '.on_login' do
    before do
      allow(LogBreakpoint).to receive(:record_login)
      allow(described_class).to receive(:backfill_for).and_return([])
    end

    it 'records login breakpoint' do
      expect(LogBreakpoint).to receive(:record_login).with(character_instance)

      described_class.on_login(character_instance)
    end

    it 'returns backfill logs' do
      logs = [{ id: 1, content: 'Old message' }]
      allow(described_class).to receive(:backfill_for).and_return(logs)

      result = described_class.on_login(character_instance)

      expect(result).to eq(logs)
    end

    it 'returns empty array if character_instance is nil' do
      result = described_class.on_login(nil)

      expect(result).to eq([])
    end
  end

  describe '.on_logout' do
    before do
      allow(LogBreakpoint).to receive(:record_logout)
    end

    it 'updates last_logout_at' do
      expect(character_instance).to receive(:update).with(hash_including(:last_logout_at))

      described_class.on_logout(character_instance)
    end

    it 'records logout breakpoint' do
      expect(LogBreakpoint).to receive(:record_logout).with(character_instance)

      described_class.on_logout(character_instance)
    end

    it 'returns early if character_instance is nil' do
      expect(LogBreakpoint).not_to receive(:record_logout)

      described_class.on_logout(nil)
    end
  end

  describe '.backfill_for' do
    let(:log1) { double('RpLog', is_private: false, to_api_hash: { id: 1, content: 'Log 1' }) }
    let(:log2) { double('RpLog', is_private: true, to_api_hash: { id: 2, content: 'Log 2' }) }

    let(:logs_dataset) do
      dataset = double('Dataset')
      allow(dataset).to receive(:order).and_return(dataset)
      allow(dataset).to receive(:limit).and_return(dataset)
      allow(dataset).to receive(:all).and_return([log2, log1])
      dataset
    end

    before do
      allow(RpLog).to receive(:where).and_return(logs_dataset)
    end

    it 'returns formatted log entries' do
      result = described_class.backfill_for(character_instance)

      expect(result).to be_an(Array)
    end

    it 'orders logs chronologically' do
      result = described_class.backfill_for(character_instance)

      # Results are reversed for chronological order
      expect(result.first[:id]).to eq(1)
    end

    context 'when show_private_logs is false' do
      before do
        allow(character_instance).to receive(:show_private_logs?).and_return(false)
      end

      it 'filters out private logs' do
        result = described_class.backfill_for(character_instance)

        expect(result.length).to eq(1)
      end
    end

    it 'returns empty array if character_instance is nil' do
      result = described_class.backfill_for(nil)

      expect(result).to eq([])
    end
  end

  describe '.log_history' do
    let(:log) { double('RpLog', to_api_hash: { id: 1 }) }
    let(:breakpoint) { double('LogBreakpoint', to_api_hash: { id: 1 }) }

    let(:logs_dataset) do
      dataset = double('Dataset')
      allow(dataset).to receive(:order).and_return(dataset)
      allow(dataset).to receive(:limit).and_return(dataset)
      allow(dataset).to receive(:where).and_return(dataset)
      allow(dataset).to receive(:all).and_return([log])
      dataset
    end

    let(:breakpoints_dataset) do
      dataset = double('Dataset')
      allow(dataset).to receive(:order).and_return(dataset)
      allow(dataset).to receive(:limit).and_return(dataset)
      allow(dataset).to receive(:where).and_return(dataset)
      allow(dataset).to receive(:all).and_return([breakpoint])
      dataset
    end

    before do
      allow(RpLog).to receive(:where).and_return(logs_dataset)
      allow(LogBreakpoint).to receive(:where).and_return(breakpoints_dataset)
    end

    it 'returns hash with logs, breakpoints, and has_more' do
      result = described_class.log_history(character_instance)

      expect(result).to have_key(:logs)
      expect(result).to have_key(:breakpoints)
      expect(result).to have_key(:has_more)
    end

    it 'returns empty result if character_instance is nil' do
      result = described_class.log_history(nil)

      expect(result[:logs]).to eq([])
      expect(result[:breakpoints]).to eq([])
      expect(result[:has_more]).to be false
    end
  end

  describe '.logs_for_event' do
    let(:event) { double('Event', id: 1) }
    let(:log) { double('RpLog', text: 'Test', display_timestamp: Time.now, to_api_hash: { id: 1 }) }

    let(:logs_dataset) do
      dataset = double('Dataset')
      allow(dataset).to receive(:order).and_return(dataset)
      allow(dataset).to receive(:limit).and_return(dataset)
      allow(dataset).to receive(:all).and_return([log])
      dataset
    end

    before do
      allow(event).to receive(:can_view_logs?).and_return(true)
      allow(RpLog).to receive(:where).and_return(logs_dataset)
    end

    it 'returns event logs' do
      result = described_class.logs_for_event(event)

      expect(result).to be_an(Array)
      expect(result.first[:id]).to eq(1)
    end

    it 'deduplicates logs within same minute' do
      duplicate_log = double('RpLog', text: 'Test', display_timestamp: Time.now, to_api_hash: { id: 2 })
      allow(logs_dataset).to receive(:all).and_return([log, duplicate_log])

      result = described_class.logs_for_event(event)

      expect(result.length).to eq(1)
    end

    it 'returns empty array if event is nil' do
      result = described_class.logs_for_event(nil)

      expect(result).to eq([])
    end

    context 'when character cannot view logs' do
      before do
        allow(event).to receive(:can_view_logs?).and_return(false)
      end

      it 'returns empty array' do
        result = described_class.logs_for_event(event, character: character)

        expect(result).to eq([])
      end
    end
  end

  describe 'private methods' do
    describe '.any_private_mode?' do
      it 'returns true if sender is in private mode' do
        allow(sender_instance).to receive(:private_mode?).and_return(true)

        result = described_class.send(:any_private_mode?, sender_instance, [])

        expect(result).to be true
      end

      it 'returns true if any witness is in private mode' do
        allow(character_instance).to receive(:private_mode?).and_return(true)

        result = described_class.send(:any_private_mode?, sender_instance, [character_instance])

        expect(result).to be true
      end

      it 'returns false if no one is in private mode' do
        result = described_class.send(:any_private_mode?, sender_instance, [character_instance])

        expect(result).to be false
      end
    end
  end
end
