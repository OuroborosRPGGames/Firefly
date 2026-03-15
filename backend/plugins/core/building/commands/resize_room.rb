# frozen_string_literal: true

module Commands
  module Building
    class ResizeRoom < Commands::Base::Command
      command_name 'resize room'
      aliases 'resizeroom'
      category :building
      help_text 'Change the dimensions of a room you own'
      usage 'resize room <width> <depth> <height>'
      examples 'resize room 10 10 3', 'resize room 20 15 4'

      protected

      def perform_command(parsed_input)
        room = location
        outer_room = room.outer_room

        # Check ownership
        unless outer_room.owned_by?(character_instance.character)
          return error_result("You don't own this room.")
        end

        # Parse dimensions from text
        text = (parsed_input[:text] || '').strip
        text = text.sub(/^room\s*/i, '') if parsed_input[:command_word] == 'resize'

        raw_parts = text.split(/\s+/)

        if raw_parts.length < 3
          return error_result('Usage: resize room <width> <depth> <height>')
        end

        # Validate numeric format before conversion
        unless raw_parts[0..2].all? { |p| p.match?(/^\d+\.?\d*$/) }
          return error_result('Dimensions must be valid numbers.')
        end

        dimensions = raw_parts[0..2].map(&:to_f)
        width, depth, height = dimensions

        # Check for special float values and bounds
        if [width, depth, height].any? { |d| d.nan? || d.infinite? }
          return error_result('Dimensions must be valid numbers.')
        end

        if width <= 0 || depth <= 0 || height <= 0
          return error_result('Dimensions must be positive numbers.')
        end

        max_dimension = GameConfig::Distance::LIMITS[:max_room_dimension]
        if width > max_dimension || depth > max_dimension || height > max_dimension
          return error_result("Dimensions cannot exceed #{max_dimension.to_i} units.")
        end

        # If this is a nested room, check it fits within the parent room
        if room.inside_room_id
          parent = room.inside_room
          if parent
            parent_width = (parent.max_x - parent.min_x).abs
            parent_depth = (parent.max_y - parent.min_y).abs
            parent_height = parent.max_z && parent.min_z ? (parent.max_z - parent.min_z).abs : nil

            if width > parent_width
              return error_result("Width (#{width}) exceeds parent room width (#{parent_width.round(1)}).")
            end
            if depth > parent_depth
              return error_result("Depth (#{depth}) exceeds parent room depth (#{parent_depth.round(1)}).")
            end
            if parent_height && height > parent_height
              return error_result("Height (#{height}) exceeds parent room height (#{parent_height.round(1)}).")
            end
          end
        end

        # Update room dimensions (centered at 0,0,0)
        half_width = width / 2.0
        half_depth = depth / 2.0

        room.update(
          min_x: -half_width,
          max_x: half_width,
          min_y: -half_depth,
          max_y: half_depth,
          min_z: 0,
          max_z: height
        )

        success_result(
          "You resize the room to #{width}x#{depth}x#{height}.",
          type: :message,
          data: {
            action: 'resize_room',
            room_id: room.id,
            width: width,
            depth: depth,
            height: height
          }
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Building::ResizeRoom)
