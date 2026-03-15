# frozen_string_literal: true

module Commands
  module Crafting
    class Make < Commands::Base::Command
      command_name 'make'
      category :crafting
      help_text 'Create meta-structures like events, societies, memos, scenes, and building elements (not physical items - use design for that)'
      usage 'make <type> [options]'
      examples 'make event', 'make society', 'make memo', 'make scene', 'make entrance'

      SUBCOMMAND_MAP = {
        'event' => :make_event,
        'calendar' => :make_event,
        'society' => :make_society,
        'club' => :make_society,
        'group' => :make_society,
        'memo' => :make_memo,
        'note' => :make_memo,
        'scene' => :make_scene,
        'story' => :make_scene,
        'entrance' => :make_entrance,
        'library' => :make_library,
        'space' => :make_space,
        'floor' => :make_floor
      }.freeze

      protected

      def perform_command(parsed_input)
        text = parsed_input[:text]
        return show_help if blank?(text)

        parts = text.strip.split(/\s+/, 2)
        subcommand = parts[0].downcase
        args = parts[1]

        handler = SUBCOMMAND_MAP[subcommand]
        return error_result("Unknown type '#{subcommand}'. Valid types: #{SUBCOMMAND_MAP.keys.uniq.join(', ')}") unless handler

        send(handler, args)
      end

      private

      def show_help
        types = SUBCOMMAND_MAP.keys.uniq.sort.join(', ')
        success_result(
          "Make what? Available types: #{types}\n\nExamples:\n  make event - Create a scheduled event\n  make society - Create a social group\n  make memo - Create a personal note\n  make scene - Start a roleplay scene",
          type: :message
        )
      end

      # ===== Subcommand Handlers =====

      def make_event(_args)
        success_result(
          "Event creation is available through the web interface. Visit your character's calendar page to create events.",
          type: :message,
          data: { action: 'make_event', redirect: '/calendar/new' }
        )
      end

      def make_society(_args)
        success_result(
          "Society/club creation is available through the web interface. Visit the Societies page to create a new group.",
          type: :message,
          data: { action: 'make_society', redirect: '/societies/new' }
        )
      end

      def make_memo(args)
        if blank?(args)
          return error_result("What do you want to write? Use: make memo <your note>")
        end

        memo_text = args.strip
        char = character_instance.character

        # Create a self-memo (note to self)
        memo = Memo.create(
          sender_id: char.id,
          recipient_id: char.id,
          subject: memo_text.length > 50 ? "#{memo_text[0..47]}..." : memo_text,
          content: memo_text
        )

        success_result(
          "Memo saved: \"#{memo_text}\"",
          type: :message,
          data: {
            action: 'make_memo',
            memo_id: memo.id,
            memo_content: memo_text
          }
        )
      end

      def make_scene(args)
        scene_name = args&.strip
        if blank?(scene_name)
          scene_name = "Scene in #{location.name}"
        end

        success_result(
          "You begin a new scene: '#{scene_name}'. Other players can now join your roleplay.",
          type: :message,
          data: {
            action: 'make_scene',
            scene_name: scene_name,
            room_id: location.id,
            creator_id: character_instance.id
          }
        )
      end

      def make_entrance(_args)
        room = location
        outer_room = room.respond_to?(:outer_room) ? room.outer_room : room

        unless outer_room.respond_to?(:owned_by?) && outer_room.owned_by?(character_instance.character)
          return error_result("You can only mark entrances in rooms you own.")
        end

        success_result(
          "This room is now marked as an entrance. Visitors will arrive here.",
          type: :message,
          data: { action: 'make_entrance', room_id: outer_room.id }
        )
      end

      def make_library(_args)
        room = location
        outer_room = room.respond_to?(:outer_room) ? room.outer_room : room

        unless outer_room.respond_to?(:owned_by?) && outer_room.owned_by?(character_instance.character)
          return error_result("You can only designate libraries in rooms you own.")
        end

        success_result(
          "This room is now designated as an arcane library. Magic users can study here.",
          type: :message,
          data: { action: 'make_library', room_id: outer_room.id }
        )
      end

      def make_space(_args)
        success_result(
          "Room space configuration is available through the building interface. Use 'build' commands to modify room properties.",
          type: :message,
          data: { action: 'make_space', redirect: '/building' }
        )
      end

      def make_floor(_args)
        success_result(
          "Floor configuration is available through the building interface. Use 'build' commands to add floors.",
          type: :message,
          data: { action: 'make_floor', redirect: '/building' }
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Crafting::Make)
