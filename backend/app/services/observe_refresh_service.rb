# frozen_string_literal: true

# ObserveRefreshService - Pushes updated room/character/place data to observers
#
# Thread-safe dirty-room tracker. When a room's state changes (characters move
# in/out, stance changes, etc.), it's marked dirty. A scheduler task periodically
# flushes dirty rooms, sending fresh display data to any characters observing
# those rooms via the left observe panel.
#
# Usage:
#   ObserveRefreshService.mark_room_dirty(room_id)
#   ObserveRefreshService.flush_dirty_rooms  # Called by scheduler every 5s
#
class ObserveRefreshService
  @dirty_rooms = Set.new
  @mutex = Mutex.new

  class << self
    def mark_room_dirty(room_id)
      return unless room_id

      @mutex.synchronize { @dirty_rooms.add(room_id) }
    end

    def flush_dirty_rooms
      rooms = @mutex.synchronize { r = @dirty_rooms.dup; @dirty_rooms.clear; r }
      rooms.each { |rid| refresh_observers_for_room(rid) }
    end

    private

    def refresh_observers_for_room(room_id)
      room = Room[room_id]
      return unless room

      observers = CharacterInstance.where(
        current_room_id: room_id,
        observing_room: true,
        online: true
      ).all
      return if observers.empty?

      observers.each do |obs|
        send_room_refresh(room, obs)
      rescue StandardError => e
        warn "[ObserveRefresh] Error refreshing for #{obs.id}: #{e.message}"
      end
    rescue StandardError => e
      warn "[ObserveRefresh] Error for room #{room_id}: #{e.message}"
    end

    def send_room_refresh(room, observer)
      service = RoomDisplayService.for(room, observer, mode: :full)
      room_data = service.build_display

      BroadcastService.to_character(
        observer,
        { content: 'Room updated.' },
        type: :room,
        target_panel: :left_observe_window,
        data: room_data
      )
    end
  end
end
