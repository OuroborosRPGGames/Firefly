# frozen_string_literal: true

module Commands
  module Staff
    class ArrangeScene < ::Commands::Base::Command
      command_name 'arrangescene'
      aliases 'arrange scene', 'setupscene', 'createscene'
      category :staff
      help_text 'Arrange a private meeting scene between an NPC and a PC (staff only)'
      usage 'arrangescene <npc> for <pc> meeting <room1> rp <room2>'
      examples(
        'arrangescene merchant for Alice meeting reception rp office',
        'arrangescene Bob for Carol at tavern'
      )

      protected

      def perform_command(parsed_input)
        error = require_staff
        return error if error

        text = parsed_input[:text]
        error = require_input(text, usage_message)
        return error if error

        # Parse the command
        parsed = parse_scene_command(text)
        unless parsed[:success]
          return error_result(parsed[:message])
        end

        # Resolve NPC
        npc = find_npc(parsed[:npc_name])
        unless npc
          return error_result("Could not find an NPC named '#{parsed[:npc_name]}'.")
        end

        # Resolve PC
        pc = find_pc(parsed[:pc_name])
        unless pc
          return error_result("Could not find a PC named '#{parsed[:pc_name]}'.")
        end

        # Resolve meeting room
        meeting_room = find_room(parsed[:meeting_room])
        unless meeting_room
          return error_result("Could not find a room named '#{parsed[:meeting_room]}'.")
        end

        # Resolve RP room (defaults to meeting room)
        rp_room = if parsed[:rp_room]
                    found = find_room(parsed[:rp_room])
                    unless found
                      return error_result("Could not find a room named '#{parsed[:rp_room]}'.")
                    end
                    found
                  else
                    meeting_room
                  end

        # Create the scene
        result = ArrangedSceneService.create_scene(
          npc_character: npc,
          pc_character: pc,
          meeting_room: meeting_room,
          rp_room: rp_room,
          created_by: character,
          scene_name: "Meeting with #{npc.full_name}"
        )

        if result[:success]
          scene = result[:scene]
          success_result(
            "Arranged scene created:\n" \
            "  Scene: #{scene.display_name}\n" \
            "  NPC: #{npc.full_name}\n" \
            "  PC: #{pc.full_name}\n" \
            "  Meeting Room: #{meeting_room.name}\n" \
            "  RP Room: #{rp_room.name}\n\n" \
            "The PC has been sent an invitation.\n" \
            "Use 'sceneinstructions #{scene.id} = <instructions>' to set NPC instructions.",
            type: :status,
            data: {
              action: 'scene_created',
              scene_id: scene.id,
              npc_id: npc.id,
              pc_id: pc.id
            }
          )
        else
          error_result(result[:message])
        end
      end

      private

      def usage_message
        "Usage: arrangescene <npc> for <pc> meeting <room1> rp <room2>\n" \
        "   or: arrangescene <npc> for <pc> at <room>\n\n" \
        "Examples:\n" \
        "  arrangescene merchant for Alice meeting reception rp office\n" \
        "  arrangescene Bob for Carol at tavern"
      end

      def parse_scene_command(text)
        # Try format: <npc> for <pc> meeting <room1> rp <room2>
        match = text.match(/^(.+?)\s+for\s+(.+?)\s+meeting\s+(.+?)\s+rp\s+(.+)$/i)
        if match
          return {
            success: true,
            npc_name: match[1].strip,
            pc_name: match[2].strip,
            meeting_room: match[3].strip,
            rp_room: match[4].strip
          }
        end

        # Try format: <npc> for <pc> at <room> (same room for both)
        match = text.match(/^(.+?)\s+for\s+(.+?)\s+at\s+(.+)$/i)
        if match
          return {
            success: true,
            npc_name: match[1].strip,
            pc_name: match[2].strip,
            meeting_room: match[3].strip,
            rp_room: nil
          }
        end

        { success: false, message: usage_message }
      end

      def find_npc(name)
        find_character_by_type(name, is_npc: true)
      end

      def find_pc(name)
        find_character_by_type(name, is_npc: false)
      end

      def find_room(name)
        name_lower = name.downcase

        rooms = Room.all

        # Exact match
        match = rooms.find { |r| r.name.downcase == name_lower }
        return match if match

        # Prefix match
        match = rooms.find { |r| r.name.downcase.start_with?(name_lower) }
        return match if match

        # Partial match
        rooms.find { |r| r.name.downcase.include?(name_lower) }
      end

      def find_character_by_type(name, is_npc:)
        candidates = Character.where(is_npc: is_npc).all
        TargetResolverService.resolve_character(
          query: name,
          candidates: candidates,
          forename_field: :forename,
          full_name_method: :full_name
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Staff::ArrangeScene)
