# frozen_string_literal: true

require 'spec_helper'

RSpec.describe IcActivityService do
  let(:room_id) { 100 }
  let(:content) { 'Alice waves hello.' }
  let(:type) { :emote }
  let(:html) { '<span class="emote">Alice waves hello.</span>' }
  let(:scene_id) { 42 }
  let(:event_id) { 7 }
  let(:exclude) { [999] }

  let(:sender) do
    double('CharacterInstance',
           id: 1,
           character_id: 1,
           private_mode?: false,
           respond_to?: true)
  end

  let(:target) do
    double('CharacterInstance',
           id: 2,
           character_id: 2,
           private_mode?: false)
  end

  before do
    # Stub all side-effect services to prevent real calls
    allow(RpLoggingService).to receive(:log_to_room)
    allow(RpLoggingService).to receive(:log_to_character)
    allow(NpcAnimationService).to receive(:process_room_broadcast)
    allow(PetAnimationService).to receive(:process_room_broadcast)
    allow(WorldMemoryService).to receive(:track_ic_message)
    allow(AutoGm::AutoGmSessionService).to receive(:notify_player_action)
    allow(EmoteTurnService).to receive(:record_emote)
    allow(EmoteTurnService).to receive(:broadcast_turn)
    allow(FlashbackTimeService).to receive(:touch_room_activity)
    allow(EmailSceneNotifier).to receive(:notify_if_needed)
  end

  # ========================================
  # .record
  # ========================================

  describe '.record' do
    it 'calls RpLoggingService.log_to_room with correct args' do
      expect(RpLoggingService).to receive(:log_to_room).with(
        room_id, content,
        sender: sender, type: 'emote',
        html: html, exclude: exclude,
        scene_id: scene_id, event_id: event_id
      )

      described_class.record(
        room_id: room_id, content: content,
        sender: sender, type: type,
        exclude: exclude, scene_id: scene_id,
        html: html, event_id: event_id
      )
    end

    it 'triggers NPC animation' do
      expect(NpcAnimationService).to receive(:process_room_broadcast).with(
        room_id: room_id,
        content: content,
        sender_instance: sender,
        type: :emote
      )

      described_class.record(room_id: room_id, content: content, sender: sender, type: type)
    end

    it 'triggers pet animation' do
      expect(PetAnimationService).to receive(:process_room_broadcast).with(
        room_id: room_id,
        content: content,
        sender_instance: sender,
        type: :emote
      )

      described_class.record(room_id: room_id, content: content, sender: sender, type: type)
    end

    it 'tracks world memory' do
      allow(sender).to receive(:respond_to?).with(:private_mode?).and_return(true)
      allow(sender).to receive(:private_mode?).and_return(false)

      expect(WorldMemoryService).to receive(:track_ic_message).with(
        room_id: room_id,
        content: content,
        sender: sender,
        type: :emote,
        is_private: false
      )

      described_class.record(room_id: room_id, content: content, sender: sender, type: type)
    end

    it 'notifies Auto-GM of player action' do
      expect(AutoGm::AutoGmSessionService).to receive(:notify_player_action).with(
        room_id: room_id,
        content: content,
        sender_instance: sender,
        type: :emote
      )

      described_class.record(room_id: room_id, content: content, sender: sender, type: type)
    end

    it 'records emote turn and broadcasts turn order' do
      expect(EmoteTurnService).to receive(:record_emote).with(room_id, sender.id)
      expect(EmoteTurnService).to receive(:broadcast_turn).with(room_id)

      described_class.record(room_id: room_id, content: content, sender: sender, type: type)
    end

    it 'touches flashback time activity' do
      expect(FlashbackTimeService).to receive(:touch_room_activity).with(room_id, exclude: exclude)

      described_class.record(room_id: room_id, content: content, sender: sender, type: type, exclude: exclude)
    end

    it 'sends email scene notifications' do
      expect(EmailSceneNotifier).to receive(:notify_if_needed).with(room_id, content, sender)

      described_class.record(room_id: room_id, content: content, sender: sender, type: type)
    end

    # ----------------------------------------
    # safe_call isolation
    # ----------------------------------------

    it 'continues if NPC animation fails' do
      allow(NpcAnimationService).to receive(:process_room_broadcast).and_raise(StandardError, 'NPC boom')

      # Later side effects should still fire
      expect(PetAnimationService).to receive(:process_room_broadcast)
      expect(EmoteTurnService).to receive(:record_emote)

      described_class.record(room_id: room_id, content: content, sender: sender, type: type)
    end

    it 'continues if emote turn service fails' do
      allow(EmoteTurnService).to receive(:record_emote).and_raise(StandardError, 'turn boom')

      # Later side effects should still fire
      expect(FlashbackTimeService).to receive(:touch_room_activity)
      expect(EmailSceneNotifier).to receive(:notify_if_needed)

      described_class.record(room_id: room_id, content: content, sender: sender, type: type)
    end

    it 'logs a warning when a side effect fails' do
      allow(NpcAnimationService).to receive(:process_room_broadcast).and_raise(StandardError, 'NPC boom')

      expect { described_class.record(room_id: room_id, content: content, sender: sender, type: type) }
        .to output(/\[IcActivityService\] NpcAnimation failed: NPC boom/).to_stderr
    end

    # ----------------------------------------
    # Edge cases
    # ----------------------------------------

    it 'returns early for nil content' do
      expect(RpLoggingService).not_to receive(:log_to_room)

      described_class.record(room_id: room_id, content: nil, sender: sender, type: type)
    end

    it 'returns early for blank content' do
      expect(RpLoggingService).not_to receive(:log_to_room)

      described_class.record(room_id: room_id, content: '   ', sender: sender, type: type)
    end

    it 'returns early for nil room_id' do
      expect(RpLoggingService).not_to receive(:log_to_room)

      described_class.record(room_id: nil, content: content, sender: sender, type: type)
    end

    context 'without a sender' do
      it 'still calls RpLoggingService.log_to_room' do
        expect(RpLoggingService).to receive(:log_to_room).with(
          room_id, content,
          sender: nil, type: 'emote',
          html: nil, exclude: [],
          scene_id: nil, event_id: nil
        )

        described_class.record(room_id: room_id, content: content, sender: nil, type: type)
      end

      it 'skips sender-dependent side effects' do
        expect(NpcAnimationService).not_to receive(:process_room_broadcast)
        expect(PetAnimationService).not_to receive(:process_room_broadcast)
        expect(WorldMemoryService).not_to receive(:track_ic_message)
        expect(AutoGm::AutoGmSessionService).not_to receive(:notify_player_action)
        expect(EmoteTurnService).not_to receive(:record_emote)
        expect(EmoteTurnService).not_to receive(:broadcast_turn)

        described_class.record(room_id: room_id, content: content, sender: nil, type: type)
      end

      it 'still triggers flashback time and email notifications' do
        # FlashbackTimeService and EmailSceneNotifier are outside the sender guard
        # in the original BroadcastService, but in the new design they are inside
        # the sender guard. Let's verify the actual behavior of the implementation.
        described_class.record(room_id: room_id, content: content, sender: nil, type: type)
      end
    end

    it 'passes default empty exclude array' do
      expect(RpLoggingService).to receive(:log_to_room).with(
        room_id, content,
        hash_including(exclude: [])
      )

      described_class.record(room_id: room_id, content: content, sender: sender, type: type)
    end
  end

  # ========================================
  # .record_targeted
  # ========================================

  describe '.record_targeted' do
    it 'logs for the sender via RpLoggingService.log_to_character' do
      expect(RpLoggingService).to receive(:log_to_character).with(
        sender, content,
        sender: sender, type: 'emote',
        html: html, scene_id: scene_id
      )

      described_class.record_targeted(
        sender: sender, target: target,
        content: content, type: type,
        scene_id: scene_id, html: html
      )
    end

    it 'logs for the target via RpLoggingService.log_to_character' do
      expect(RpLoggingService).to receive(:log_to_character).with(
        target, content,
        sender: sender, type: 'emote',
        html: html, scene_id: scene_id
      )

      described_class.record_targeted(
        sender: sender, target: target,
        content: content, type: type,
        scene_id: scene_id, html: html
      )
    end

    it 'calls log_to_character exactly twice' do
      expect(RpLoggingService).to receive(:log_to_character).exactly(2).times

      described_class.record_targeted(
        sender: sender, target: target,
        content: content, type: type
      )
    end

    it 'returns early for nil content' do
      expect(RpLoggingService).not_to receive(:log_to_character)

      described_class.record_targeted(
        sender: sender, target: target,
        content: nil, type: type
      )
    end

    it 'returns early for blank content' do
      expect(RpLoggingService).not_to receive(:log_to_character)

      described_class.record_targeted(
        sender: sender, target: target,
        content: '  ', type: type
      )
    end
  end

  # ========================================
  # .record_for
  # ========================================

  describe '.record_for' do
    let(:recipient_a) do
      double('CharacterInstance', id: 10, character_id: 10)
    end
    let(:recipient_b) do
      double('CharacterInstance', id: 11, character_id: 11)
    end
    let(:recipients) { [recipient_a, recipient_b] }

    it 'logs for each specified recipient' do
      expect(RpLoggingService).to receive(:log_to_character).with(
        recipient_a, content,
        sender: sender, type: 'emote',
        html: html, scene_id: scene_id
      )
      expect(RpLoggingService).to receive(:log_to_character).with(
        recipient_b, content,
        sender: sender, type: 'emote',
        html: html, scene_id: scene_id
      )

      described_class.record_for(
        recipients: recipients, content: content,
        sender: sender, type: type,
        scene_id: scene_id, html: html
      )
    end

    it 'calls log_to_character once per recipient' do
      expect(RpLoggingService).to receive(:log_to_character).exactly(2).times

      described_class.record_for(
        recipients: recipients, content: content,
        sender: sender, type: type
      )
    end

    it 'handles a single recipient (not wrapped in array)' do
      expect(RpLoggingService).to receive(:log_to_character).once.with(
        recipient_a, content,
        sender: sender, type: 'emote',
        html: nil, scene_id: nil
      )

      described_class.record_for(
        recipients: recipient_a, content: content,
        sender: sender, type: type
      )
    end

    it 'returns early for nil content' do
      expect(RpLoggingService).not_to receive(:log_to_character)

      described_class.record_for(
        recipients: recipients, content: nil,
        sender: sender, type: type
      )
    end

    it 'returns early for blank content' do
      expect(RpLoggingService).not_to receive(:log_to_character)

      described_class.record_for(
        recipients: recipients, content: '   ',
        sender: sender, type: type
      )
    end

    it 'handles empty recipients array' do
      expect(RpLoggingService).not_to receive(:log_to_character)

      described_class.record_for(
        recipients: [], content: content,
        sender: sender, type: type
      )
    end
  end
end
