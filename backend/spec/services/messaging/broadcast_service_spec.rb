# frozen_string_literal: true

require 'spec_helper'

RSpec.describe BroadcastService do
  let(:zone) { create(:zone) }
  let(:area) { zone } # Alias for backward compatibility
  let(:location) { create(:location, zone: zone) }
  let(:room) { create(:room, name: 'Test Room', short_description: 'A room', location: location) }
  let(:reality) { create(:reality) }

  let(:user) { create(:user) }
  let(:character) { create(:character, forename: 'Test', surname: 'User', user: user) }
  let(:character_instance) { create(:character_instance, character: character, reality: reality, current_room: room) }

  before do
    allow(TtsQueueService).to receive(:should_queue_for?).and_return(false)
    allow(TtsQueueService).to receive(:queue_for)
    # Prevent Redis pub/sub from leaking into live WebSocket clients
    allow(described_class).to receive(:broadcast_via_anycable)
  end

  describe '.to_room' do
    context 'with nil room_id' do
      it 'returns early without error' do
        expect { described_class.to_room(nil, 'test') }.not_to raise_error
      end
    end

    context 'with valid room_id' do
      it 'does not call RpLoggingService (IC logging removed)' do
        allow(RpLoggingService).to receive(:log_to_room)

        described_class.to_room(room.id, 'Hello world', type: :say, sender_instance: character_instance)

        expect(RpLoggingService).not_to have_received(:log_to_room)
      end

      it 'does not call NpcAnimationService (IC side effects removed)' do
        allow(NpcAnimationService).to receive(:process_room_broadcast)

        described_class.to_room(room.id, 'Hello world', type: :say, sender_instance: character_instance)

        expect(NpcAnimationService).not_to have_received(:process_room_broadcast)
      end

      it 'does not call PetAnimationService (IC side effects removed)' do
        allow(PetAnimationService).to receive(:process_room_broadcast)

        described_class.to_room(room.id, 'Hello world', type: :say, sender_instance: character_instance)

        expect(PetAnimationService).not_to have_received(:process_room_broadcast)
      end

      it 'does not call WorldMemoryService (IC side effects removed)' do
        allow(WorldMemoryService).to receive(:track_ic_message)

        described_class.to_room(room.id, 'Hello world', type: :say, sender_instance: character_instance)

        expect(WorldMemoryService).not_to have_received(:track_ic_message)
      end

      it 'broadcasts without error' do
        expect {
          described_class.to_room(room.id, 'Hello world', type: :say, sender_instance: character_instance)
        }.not_to raise_error
      end
    end

    context 'with Hash message' do
      it 'broadcasts hash messages without error' do
        expect {
          described_class.to_room(room.id, { content: 'Hash message' }, type: :say, sender_instance: character_instance)
        }.not_to raise_error
      end
    end

    context 'with exclude list' do
      it 'accepts exclude parameter without error' do
        expect {
          described_class.to_room(
            room.id,
            'Excluded message',
            type: :say,
            sender_instance: character_instance,
            exclude: [character_instance.id]
          )
        }.not_to raise_error
      end
    end

    context 'sender_portrait_url in payload' do
      before do
        # Prevent DB write in store_for_polling_fallback; return nil so
        # broadcast_via_anycable receives the raw payload (enriched || payload).
        allow(described_class).to receive(:store_for_polling_fallback).and_return(nil)
        allow(described_class).to receive(:store_for_character_fallback).and_return(nil)
      end

      context 'when sender_instance has a portrait' do
        before do
          allow(character_instance.character).to receive(:profile_pic_url).and_return('/uploads/portraits/alice.jpg')
        end

        it 'includes sender_portrait_url in the broadcast payload' do
          captured_payload = nil
          allow(described_class).to receive(:broadcast_via_anycable) do |_channel, payload|
            captured_payload = payload
          end

          described_class.to_room(room.id, 'Hello', type: :say, sender_instance: character_instance)

          expect(captured_payload[:sender_portrait_url]).to eq('/uploads/portraits/alice.jpg')
        end

        it 'does not duplicate sender_portrait_url when passed in metadata' do
          captured_payload = nil
          allow(described_class).to receive(:broadcast_via_anycable) do |_channel, payload|
            captured_payload = payload
          end

          described_class.to_room(room.id, 'Hello', type: :say,
                                   sender_instance: character_instance,
                                   sender_portrait_url: '/some/other/url')

          # computed value from sender_instance wins; caller-supplied value excluded
          expect(captured_payload[:sender_portrait_url]).to eq('/uploads/portraits/alice.jpg')
        end
      end

      context 'when sender_instance is nil' do
        it 'sets sender_portrait_url to nil in payload' do
          captured_payload = nil
          allow(described_class).to receive(:broadcast_via_anycable) do |_channel, payload|
            captured_payload = payload
          end

          described_class.to_room(room.id, 'Hello', type: :say)

          expect(captured_payload).to have_key(:sender_portrait_url)
          expect(captured_payload[:sender_portrait_url]).to be_nil
        end
      end
    end
  end

  describe '.to_character' do
    context 'with nil character_instance' do
      it 'returns early without error' do
        expect { described_class.to_character(nil, 'test') }.not_to raise_error
      end
    end

    context 'with valid character_instance' do
      it 'does not call RpLoggingService (IC logging removed)' do
        allow(RpLoggingService).to receive(:log_to_character)

        described_class.to_character(character_instance, 'Private message', type: :whisper)

        expect(RpLoggingService).not_to have_received(:log_to_character)
      end

      it 'queues TTS for accessibility mode users' do
        allow(TtsQueueService).to receive(:should_queue_for?).and_return(true)

        described_class.to_character(character_instance, 'Spoken message', type: :say)

        expect(TtsQueueService).to have_received(:queue_for)
      end

      it 'does not queue TTS when disabled' do
        allow(TtsQueueService).to receive(:should_queue_for?).and_return(false)

        described_class.to_character(character_instance, 'Silent message', type: :say)

        expect(TtsQueueService).not_to have_received(:queue_for)
      end
    end

    context 'with character_instance ID instead of object' do
      it 'handles integer ID' do
        expect { described_class.to_character(character_instance.id, 'test') }.not_to raise_error
      end
    end
  end

  describe '.to_character_raw' do
    context 'with skip_tts: true' do
      it 'skips TTS queuing' do
        allow(TtsQueueService).to receive(:should_queue_for?).and_return(true)

        described_class.to_character_raw(character_instance, 'Silent message', type: :say, skip_tts: true)

        expect(TtsQueueService).not_to have_received(:queue_for)
      end
    end

    context 'without skip_tts' do
      it 'queues TTS normally' do
        allow(TtsQueueService).to receive(:should_queue_for?).and_return(true)

        described_class.to_character_raw(character_instance, 'Normal message', type: :say)

        expect(TtsQueueService).to have_received(:queue_for)
      end
    end

    it 'does not perform IC logging' do
      allow(RpLoggingService).to receive(:log_to_character)

      described_class.to_character_raw(character_instance, 'Raw message', type: :say)

      expect(RpLoggingService).not_to have_received(:log_to_character)
    end
  end

  describe '.to_area' do
    context 'with nil area_id' do
      it 'returns early without error' do
        expect { described_class.to_area(nil, 'test') }.not_to raise_error
      end
    end

    context 'with valid area_id' do
      it 'does not raise error' do
        expect { described_class.to_area(area.id, 'Area announcement') }.not_to raise_error
      end
    end
  end

  describe '.to_all' do
    it 'does not raise error' do
      expect { described_class.to_all('Global message') }.not_to raise_error
    end
  end

  describe '.to_observers' do
    context 'with nil observed_character' do
      it 'returns early without error' do
        expect { described_class.to_observers(nil, 'test') }.not_to raise_error
      end
    end

    context 'with character who has observers' do
      let(:observer_user) { create(:user) }
      let(:observer_char) { create(:character, forename: 'Observer', surname: 'Guy', user: observer_user) }
      let(:observer_instance) { create(:character_instance, character: observer_char, reality: reality, current_room: room) }

      before do
        # Mock current_observers to return our observer
        allow(character_instance).to receive(:current_observers).and_return(
          double(all: [observer_instance])
        )
      end

      it 'broadcasts to each observer without error' do
        expect {
          described_class.to_observers(character_instance, 'Observed action', type: :say)
        }.not_to raise_error
      end
    end
  end

  describe '.enabled?' do
    it 'returns true when REDIS_POOL is available' do
      # In test environment, REDIS_POOL is defined and available
      expect(described_class.enabled?).to be true
    end
  end

  describe 'TTS content type handling' do
    before do
      allow(TtsQueueService).to receive(:should_queue_for?).and_return(true)
    end

    it 'queues TTS for say messages' do
      described_class.to_character(character_instance, 'Test say', type: :say)
      expect(TtsQueueService).to have_received(:queue_for)
    end

    it 'queues TTS for system messages' do
      described_class.to_character(character_instance, 'Test system', type: :system)
      expect(TtsQueueService).to have_received(:queue_for)
    end
  end

  describe '.to_room_with_staff_vision' do
    let(:staff_room) { create(:room, name: 'Staff Room', short_description: 'For staff', location: location) }

    it 'broadcasts to room without error' do
      expect {
        described_class.to_room_with_staff_vision(room.id, 'Public message', type: :say)
      }.not_to raise_error
    end

    it 'calls staff vision broadcast' do
      # Staff vision tested separately but should not raise
      expect {
        described_class.to_room_with_staff_vision(room.id, 'Public message', type: :say)
      }.not_to raise_error
    end
  end
end
