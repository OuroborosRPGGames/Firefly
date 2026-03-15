# frozen_string_literal: true

module Commands
  module Building
    class EditRoom < Commands::Base::Command
      command_name 'edit room'
      aliases 'editroom', 'room edit', 'roomsettings', 'room settings'
      category :building
      help_text 'Edit room properties in a pop-out form'
      usage 'edit room'
      examples 'edit room', 'editroom', 'room settings'

      requires_can_modify_rooms

      protected

      def perform_command(_parsed_input)
        room = location
        outer_room = room.outer_room

        # Check ownership
        unless outer_room.owned_by?(character_instance.character)
          return error_result("You don't own this room.")
        end

        show_room_editor_form(room)
      end

      # Handle form submission
      def handle_form_response(form_data, context)
        room = Room[context['room_id']]
        unless room
          return error_result('Room no longer exists.')
        end

        # Re-validate ownership (may have changed since form was shown)
        outer_room = room.outer_room
        unless outer_room.owned_by?(character_instance.character)
          return error_result("You no longer own this room.")
        end

        # Validate name
        new_name = form_data['name']&.strip
        if new_name.nil? || new_name.empty?
          return error_result('Room name is required.')
        end

        if new_name.length > 100
          return error_result('Room name must be 100 characters or less.')
        end

        # Validate descriptions
        short_desc = form_data['short_description']&.strip || ''
        long_desc = form_data['long_description']&.strip || ''

        if short_desc.length > 500
          return error_result('Short description must be 500 characters or less.')
        end

        if long_desc.length > 5000
          return error_result('Long description must be 5000 characters or less.')
        end

        # Validate room type
        room_type = form_data['room_type']&.strip&.downcase || 'standard'
        unless Room::VALID_ROOM_TYPES.include?(room_type)
          room_type = 'standard'
        end

        # Validate background URL
        bg_url = form_data['background_url']&.strip
        if bg_url && !bg_url.empty?
          unless bg_url.match?(%r{^https?://})
            return error_result('Background URL must start with http:// or https://')
          end
          if bg_url.length > 2048
            return error_result('Background URL too long (max 2048 characters).')
          end
        else
          bg_url = nil
        end

        # Update room
        old_name = room.name
        room.update(
          name: new_name,
          short_description: short_desc.empty? ? nil : short_desc,
          long_description: long_desc.empty? ? nil : long_desc,
          room_type: room_type,
          default_background_url: bg_url
        )

        # Broadcast if name changed
        if old_name != new_name
          BroadcastService.to_room(
            room.id,
            "#{character.full_name} updates the room.",
            exclude: [character_instance.id],
            type: :message
          )
        end

        success_result(
          "Room updated successfully.",
          type: :message,
          data: {
            action: 'edit_room',
            room_id: room.id,
            changes: {
              name: new_name,
              short_description: short_desc,
              room_type: room_type,
              has_background: !bg_url.nil?
            }
          }
        )
      end

      private

      def show_room_editor_form(room)
        # Build room type options grouped by category
        room_type_options = Room::ROOM_TYPES.flat_map do |category, types|
          types.map do |type|
            { value: type, label: "#{type.tr('_', ' ').capitalize} (#{category})" }
          end
        end

        fields = [
          {
            name: 'name',
            label: 'Room Name',
            type: 'text',
            required: true,
            default: room.name,
            placeholder: 'e.g., Cozy Living Room'
          },
          {
            name: 'short_description',
            label: 'Short Description',
            type: 'text',
            required: false,
            default: room.short_description,
            placeholder: 'Brief description shown in room list'
          },
          {
            name: 'long_description',
            label: 'Long Description',
            type: 'textarea',
            required: false,
            default: room.long_description,
            placeholder: 'Detailed description shown when looking at the room'
          },
          {
            name: 'room_type',
            label: 'Room Type',
            type: 'select',
            required: true,
            default: room.room_type || 'standard',
            options: room_type_options
          },
          {
            name: 'background_url',
            label: 'Background Image URL',
            type: 'text',
            required: false,
            default: room.default_background_url,
            placeholder: 'https://example.com/image.jpg'
          }
        ]

        create_form(
          character_instance,
          'Edit Room',
          fields,
          context: {
            command: 'edit_room',
            room_id: room.id
          }
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Building::EditRoom)
