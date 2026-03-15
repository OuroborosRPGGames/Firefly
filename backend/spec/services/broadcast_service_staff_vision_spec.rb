# frozen_string_literal: true

require 'spec_helper'

RSpec.describe BroadcastService, 'staff vision' do
  let(:room) { create(:room) }
  let(:other_room) { create(:room) }
  let(:reality) { create(:reality) }

  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }
  let(:character_instance) { create(:character_instance, character: character, current_room: room, reality: reality) }

  let(:staff_user) do
    u = create(:user)
    u.grant_permission!('can_create_staff_characters')
    u.grant_permission!('can_see_all_rp')
    u
  end
  let(:staff_character) { create(:character, user: staff_user, is_staff_character: true) }
  let(:staff_instance) do
    create(:character_instance,
           character: staff_character,
           current_room: other_room,
           reality: reality,
           online: true,
           staff_vision_enabled: true)
  end

  describe '.to_staff_vision' do
    context 'when room is nil' do
      it 'returns early without error' do
        expect { BroadcastService.to_staff_vision(nil, 'test message') }.not_to raise_error
      end
    end

    context 'when room is in private mode' do
      before { room.enable_private_mode! }

      it 'does not broadcast to staff' do
        staff_instance # Create staff instance
        expect(BroadcastService).not_to receive(:to_character)
        BroadcastService.to_staff_vision(room, 'test message')
      end
    end

    context 'when room is public' do
      before { staff_instance } # Ensure staff instance exists

      it 'broadcasts to staff with vision enabled' do
        # The to_character call should be made for staff
        expect(BroadcastService).to receive(:to_character).with(
          anything,
          hash_including(room_id: room.id, staff_vision: true),
          hash_including(type: :staff_vision)
        )
        BroadcastService.to_staff_vision(room, 'test message')
      end
    end

    context 'staff eligibility' do
      it 'does not include non-staff characters' do
        regular_instance = character_instance
        regular_instance.update(staff_vision_enabled: true)

        expect(BroadcastService).not_to receive(:to_character).with(
          regular_instance, anything, anything
        )
        BroadcastService.to_staff_vision(room, 'test')
      end

      it 'does not include staff without vision enabled' do
        staff_instance.update(staff_vision_enabled: false)

        expect(BroadcastService).not_to receive(:to_character)
        BroadcastService.to_staff_vision(room, 'test')
      end

      it 'does not include offline staff' do
        staff_instance.update(online: false)

        expect(BroadcastService).not_to receive(:to_character)
        BroadcastService.to_staff_vision(room, 'test')
      end

      it 'does not include staff in the same room' do
        staff_instance.update(current_room: room)

        expect(BroadcastService).not_to receive(:to_character)
        BroadcastService.to_staff_vision(room, 'test')
      end

      it 'does not include staff without can_see_all_rp permission' do
        staff_user.revoke_permission!('can_see_all_rp')
        staff_instance # Force refresh

        expect(BroadcastService).not_to receive(:to_character)
        BroadcastService.to_staff_vision(room, 'test')
      end
    end
  end

  describe '.to_room_with_staff_vision' do
    before { staff_instance }

    it 'calls to_room' do
      expect(BroadcastService).to receive(:to_room).with(
        room.id, 'test message', exclude: [], type: :message
      )
      BroadcastService.to_room_with_staff_vision(room.id, 'test message')
    end

    it 'calls to_staff_vision' do
      expect(BroadcastService).to receive(:to_staff_vision).with(
        room, 'test message', type: :message
      )
      BroadcastService.to_room_with_staff_vision(room.id, 'test message')
    end

    it 'passes exclude option to to_room' do
      expect(BroadcastService).to receive(:to_room).with(
        room.id, 'test', exclude: [character_instance.id], type: :message
      )
      BroadcastService.to_room_with_staff_vision(room.id, 'test', exclude: [character_instance.id])
    end

    it 'passes type option' do
      expect(BroadcastService).to receive(:to_room).with(
        room.id, 'test', exclude: [], type: :emote
      )
      expect(BroadcastService).to receive(:to_staff_vision).with(
        room, 'test', type: :emote
      )
      BroadcastService.to_room_with_staff_vision(room.id, 'test', type: :emote)
    end
  end

  describe '.find_staff_vision_recipients (private method)' do
    before { staff_instance }

    it 'finds eligible staff' do
      recipients = BroadcastService.send(:find_staff_vision_recipients, room)
      expect(recipients).to include(staff_instance)
    end

    it 'excludes staff in the specified room' do
      staff_instance.update(current_room: room)
      recipients = BroadcastService.send(:find_staff_vision_recipients, room)
      expect(recipients).not_to include(staff_instance)
    end
  end

  describe '.build_staff_vision_message (private method)' do
    it 'includes required fields' do
      message = BroadcastService.send(:build_staff_vision_message, room, 'test', :say)
      expect(message[:room_id]).to eq(room.id)
      expect(message[:room_name]).to eq(room.name)
      expect(message[:message]).to eq('test')
      expect(message[:original_type]).to eq(:say)
      expect(message[:staff_vision]).to be true
      expect(message[:timestamp]).not_to be_nil
    end
  end
end
