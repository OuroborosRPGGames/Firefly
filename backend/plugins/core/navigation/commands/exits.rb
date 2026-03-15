# frozen_string_literal: true

module Commands
  module Navigation
    class Exits < Commands::Base::Command
      command_name 'exits'
      category :navigation
      help_text 'Show all visible exits from this room'
      usage 'exits'
      examples 'exits'

      # Delegate to CanvasHelper for direction arrows (canonical source)
      DIRECTION_ARROWS = CanvasHelper::DIRECTION_ARROWS

      protected

      def perform_command(_parsed_input)
        room = location

        # Get passable spatial exits
        passable_exits = room.passable_spatial_exits

        # Also check for rooms that can be entered (contained rooms)
        contained_rooms = RoomAdjacencyService.contained_rooms(room)
        enterable = contained_rooms.map do |contained|
          { direction: 'enter', room: contained, display: "enter #{contained.name}" }
        end

        if passable_exits.empty? && enterable.empty?
          return success_result(
            'There are no visible exits.',
            type: :message,
            data: { action: 'exits', exits: [] }
          )
        end

        # Build exit display strings
        exit_displays = passable_exits.map do |exit|
          dir = exit[:direction].to_s
          arrow = DIRECTION_ARROWS[dir] || ''
          room_name = exit[:room].name
          "#{arrow} #{dir.capitalize} (#{room_name})"
        end

        # Add enterable rooms
        enterable.each do |entry|
          exit_displays << "⊙ #{entry[:display]}"
        end

        exit_list = exit_displays.join(', ')
        message = "#{room.name} Exits: #{exit_list}"

        # Build structured data for client
        exit_data = passable_exits.map do |exit|
          {
            direction: exit[:direction].to_s,
            direction_arrow: DIRECTION_ARROWS[exit[:direction].to_s] || '',
            to_room_name: exit[:room].name,
            to_room_id: exit[:room].id,
            distance: exit[:distance],
            exit_type: :spatial
          }
        end

        # Add enterable rooms to structured data
        enterable.each do |entry|
          exit_data << {
            direction: 'enter',
            direction_arrow: '⊙',
            to_room_name: entry[:room].name,
            to_room_id: entry[:room].id,
            distance: 0, # Contained rooms are at distance 0 (inside)
            exit_type: :contained
          }
        end

        success_result(
          message,
          type: :message,
          data: {
            action: 'exits',
            room_name: room.name,
            exits: exit_data
          }
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Navigation::Exits)
