# frozen_string_literal: true

module Commands
  module Storage
    class LibraryDelete < Commands::Base::Command
      command_name 'library delete'
      aliases 'libdelete', 'library del'
      category :inventory
      help_text 'Delete an item from your media library or saved locations'
      usage 'library delete <name>'
      examples 'library delete sunset', 'libdelete old gradient'

      protected

      def perform_command(parsed_input)
        name = parsed_input[:text]&.strip
        return error_result("What do you want to delete? Usage: library delete <name>") if name.nil? || name.empty?

        # Try to find in media library first
        media_item = MediaLibrary.find_by_name(character, name)
        if media_item
          item_type = media_item.media_type
          media_item.destroy
          return success_result(
            "Deleted #{item_type} '#{name}' from your library.",
            type: :message,
            data: {
              action: 'library_delete',
              name: name,
              deleted_type: 'media',
              media_type: item_type
            }
          )
        end

        # Try saved locations
        saved_loc = SavedLocation.find_by_name(character, name)
        if saved_loc
          room_name = saved_loc.room&.name || 'unknown'
          saved_loc.destroy
          return success_result(
            "Deleted saved location '#{name}' (#{room_name}).",
            type: :message,
            data: {
              action: 'library_delete',
              name: name,
              deleted_type: 'location',
              room_name: room_name
            }
          )
        end

        error_result("Nothing found in your library called '#{name}'.")
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Storage::LibraryDelete)
