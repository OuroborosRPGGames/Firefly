# frozen_string_literal: true

module Commands
  module Storage
    class Save < Commands::Base::Command
      command_name 'save'
      category :inventory
      help_text 'Save media from chat to your library'
      usage 'save <type><number> as <name>'
      examples 'save pic1 as sunset', 'save vid2 as funny', 'save tpic1 as portrait'

      MEDIA_TYPE_ALIASES = {
        'pic' => 'pic',
        'picture' => 'pic',
        'image' => 'pic',
        'img' => 'pic',
        'tpic' => 'tpic',
        'textpic' => 'tpic',
        'vid' => 'vid',
        'video' => 'vid',
        'tvid' => 'tvid',
        'textvid' => 'tvid'
      }.freeze

      protected

      def perform_command(parsed_input)
        input = parsed_input[:text]&.strip
        return error_result("Usage: save <type><number> as <name>") if input.nil? || input.empty?

        # Parse input: "pic1 as sunset" or "vid2 as funny"
        media_type, index, name = parse_save_input(input)
        return error_result("Usage: save <type><number> as <name>") unless media_type && index && name

        # Find the media in recent messages
        media_content = find_media_in_chat(media_type, index)
        return error_result("Could not find #{media_type} ##{index} in recent chat.") unless media_content

        # Check for duplicate name
        existing = MediaLibrary.find_by_name(character, name)
        if existing
          return error_result("You already have something saved as '#{name}'. Use 'library delete #{name}' first.")
        end

        # Create media library entry (using actual DB column names)
        MediaLibrary.create(
          character_id: character.id,
          mtype: media_type,
          mname: name,
          mtext: media_content
        )

        success_result(
          "Saved #{media_type} as '#{name}'.",
          type: :message,
          data: {
            action: 'save_media',
            name: name,
            media_type: media_type
          }
        )
      end

      private

      def parse_save_input(input)
        # Match pattern: type + number + "as" + name
        # Examples: "pic1 as sunset", "vid2 as funny"
        match = input.match(/^(\w+?)(\d+)\s+as\s+(.+)$/i)
        return [nil, nil, nil] unless match

        type_alias = match[1].downcase
        index = match[2].to_i
        name = match[3].strip

        media_type = MEDIA_TYPE_ALIASES[type_alias]
        return [nil, nil, nil] unless media_type

        [media_type, index, name]
      end

      def find_media_in_chat(media_type, index)
        # Look for recent messages with media content
        # This searches messages in the current room for the character
        recent_messages = Message.where(character_id: character.id)
                                  .or(target_character_instance_id: character_instance.id)
                                  .order(Sequel.desc(:created_at))
                                  .limit(50)
                                  .all

        # Count media of the specified type
        media_count = 0
        recent_messages.each do |msg|
          content = msg.content
          next unless content

          # Look for media URLs or embedded content
          urls = extract_media_urls(content, media_type)
          urls.each do |url|
            media_count += 1
            return url if media_count == index
          end
        end

        nil
      end

      def extract_media_urls(content, media_type)
        urls = []

        case media_type
        when 'pic', 'tpic'
          # Extract image URLs
          urls += content.scan(%r{https?://[^\s<>"']+\.(?:jpg|jpeg|png|gif|webp)}i)
          # Also look for markdown image syntax
          urls += content.scan(/!\[.*?\]\((https?:\/\/[^\s)]+)\)/).flatten
        when 'vid', 'tvid'
          # Extract video URLs (YouTube, Vimeo, direct video files)
          urls += content.scan(%r{https?://(?:www\.)?youtube\.com/watch\?v=[\w-]+}i)
          urls += content.scan(%r{https?://(?:www\.)?youtu\.be/[\w-]+}i)
          urls += content.scan(%r{https?://(?:www\.)?vimeo\.com/\d+}i)
          urls += content.scan(%r{https?://[^\s<>"']+\.(?:mp4|webm|mov)}i)
        end

        urls.uniq
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Storage::Save)
