# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ObserveRefreshService do
  before do
    described_class.instance_variable_set(:@dirty_rooms, Set.new)
    described_class.instance_variable_set(:@mutex, Mutex.new)
  end

  describe '.mark_room_dirty and .flush_dirty_rooms' do
    it 'refreshes each dirty room once and clears the queue' do
      allow(described_class).to receive(:refresh_observers_for_room)

      described_class.mark_room_dirty(11)
      described_class.mark_room_dirty(11)
      described_class.mark_room_dirty(22)

      described_class.flush_dirty_rooms
      described_class.flush_dirty_rooms

      expect(described_class).to have_received(:refresh_observers_for_room).with(11).once
      expect(described_class).to have_received(:refresh_observers_for_room).with(22).once
    end

    it 'ignores nil room ids' do
      allow(described_class).to receive(:refresh_observers_for_room)

      described_class.mark_room_dirty(nil)
      described_class.flush_dirty_rooms

      expect(described_class).not_to have_received(:refresh_observers_for_room)
    end
  end

  describe '.refresh_observers_for_room' do
    it 'sends room refresh payload to each online room observer' do
      room = create(:room)
      observer = create(:character_instance, current_room: room, observing_room: true, online: true)
      create(:character_instance, current_room: room, observing_room: false, online: true)
      create(:character_instance, current_room: room, observing_room: true, online: false)

      display_data = { room_id: room.id, title: room.name }
      display_service = instance_double(RoomDisplayService, build_display: display_data)

      expect(RoomDisplayService).to receive(:new).with(room, observer, mode: :full).and_return(display_service)
      expect(BroadcastService).to receive(:to_character).with(
        observer,
        { content: 'Room updated.' },
        type: :room,
        target_panel: :left_observe_window,
        data: display_data
      )

      described_class.send(:refresh_observers_for_room, room.id)
    end

    it 'does nothing for unknown rooms' do
      expect(BroadcastService).not_to receive(:to_character)

      described_class.send(:refresh_observers_for_room, -999_999)
    end

    it 'continues when one observer refresh raises an error' do
      room = create(:room)
      first_observer = create(:character_instance, current_room: room, observing_room: true, online: true)
      second_observer = create(:character_instance, current_room: room, observing_room: true, online: true)

      allow(described_class).to receive(:send_room_refresh) do |_room, observer|
        raise StandardError, 'boom' if observer.id == first_observer.id
      end

      described_class.send(:refresh_observers_for_room, room.id)

      expect(described_class).to have_received(:send_room_refresh).with(room, first_observer)
      expect(described_class).to have_received(:send_room_refresh).with(room, second_observer)
    end
  end
end
