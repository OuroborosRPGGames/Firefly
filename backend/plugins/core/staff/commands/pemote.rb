# frozen_string_literal: true

require_relative '../concerns/puppet_lookup_concern'

module Commands
  module Staff
    class PEmote < ::Commands::Base::Command
      include Commands::Staff::Concerns::PuppetLookupConcern
      command_name 'pemote'
      aliases 'puppet emote', 'npcemote', 'npc emote'
      category :staff
      help_text 'Make a puppeted NPC perform an emote (staff only)'
      usage 'pemote <emote text> OR pemote <npc name> <emote text>'
      examples 'pemote waves hello', 'pemote Bob smiles warmly'

      protected

      def perform_command(parsed_input)
        error = require_staff
        return error if error

        text = parsed_input[:text]
        error = require_input(text, 'What should the NPC do? Usage: pemote <emote text>')
        return error if error

        puppets_list = character_instance.puppets
        if puppets_list.empty?
          return error_result("You're not puppeting any NPCs. Use 'puppet <npc>' first.")
        end

        # Parse the input - check for "npc = emote" format
        npc_instance, emote_text = parse_pemote_input(text, puppets_list)

        unless npc_instance
          puppet_names = puppets_list.map(&:full_name).join(', ')
          return error_result(
            "Could not determine which NPC to emote as.\n" \
            "Currently puppeting: #{puppet_names}\n" \
            "Use: pemote <npc name> <emote text>"
          )
        end

        error = require_input(emote_text, 'What should the NPC do?')
        return error if error

        # Process the emote
        execute_puppet_emote(npc_instance, emote_text.strip)
      end

      private

      def parse_pemote_input(text, puppets_list)
        text = text.strip

        # Try "=" separator first (backward compat, unambiguous)
        if text.include?('=')
          parts = text.split('=', 2)
          npc_name = parts[0].strip
          emote_text = parts[1]&.strip
          npc_instance = find_puppet_by_name(puppets_list, npc_name)
          return [npc_instance, emote_text] if npc_instance
        end

        # If only one puppet, use them directly
        if puppets_list.length == 1
          return [puppets_list.first, text]
        end

        # Multiple puppets: try to match first word(s) against puppet names
        puppets_list.each do |puppet|
          forename = puppet.character.forename.downcase
          full_name = puppet.full_name.downcase
          text_lower = text.downcase

          if text_lower.start_with?(full_name + ' ')
            return [puppet, text[(full_name.length + 1)..].strip]
          elsif text_lower.start_with?(forename + ' ')
            return [puppet, text[(forename.length + 1)..].strip]
          end
        end

        [nil, nil]
      end

      def execute_puppet_emote(npc_instance, emote_text)
        npc_name = npc_instance.full_name
        npc_room = npc_instance.current_room
        pending_suggestion = npc_instance.pending_puppet_suggestion

        unless npc_room
          return error_result("#{npc_name} is not in a valid room.")
        end

        # Build the emote message
        # If text already starts with NPC name, use as-is
        # Otherwise, prepend the name
        emote_text_lower = emote_text.downcase
        npc_name_lower = npc_name.downcase
        forename_lower = npc_instance.character.forename.downcase

        if emote_text_lower.start_with?(npc_name_lower) ||
           emote_text_lower.start_with?(forename_lower)
          full_emote = emote_text
        else
          full_emote = "#{npc_name} #{emote_text}"
        end

        # Add punctuation if missing
        full_emote = add_punctuation(full_emote)

        # Broadcast to the NPC's room
        BroadcastService.to_room(
          npc_room.id,
          { content: full_emote, html: full_emote },
          type: :emote,
          sender_instance: npc_instance
        )

        # Log the roleplay action
        IcActivityService.record(
          room_id: npc_room.id, content: full_emote,
          sender: npc_instance, type: :emote
        )

        # Apply animation side effects only now (after explicit staff commit).
        if defined?(NpcAnimationHandler)
          NpcAnimationHandler.apply_committed_emote_side_effects(
            npc_instance: npc_instance,
            emote_text: full_emote,
            suggestion_text: pending_suggestion
          )
        end

        # Clear any pending suggestion
        npc_instance.clear_puppet_suggestion!

        # Send confirmation to the staff member
        room_info = npc_room.name

        # If staff is not in the same room, show them what happened
        staff_message = if character_instance.current_room_id == npc_room.id
                          "[Puppet] #{full_emote}"
                        else
                          "[Puppet in #{room_info}] #{full_emote}"
                        end

        success_result(
          staff_message,
          type: :action,
          data: {
            action: 'puppet_emote',
            npc_id: npc_instance.id,
            npc_name: npc_name,
            emote: full_emote,
            room_name: room_info
          }
        )
      end

      def add_punctuation(text)
        return text if text.nil? || text.empty?

        # Check if already has ending punctuation
        last_char = text[-1]
        return text if %w[. ! ? , : ; -].include?(last_char)

        # Add a period
        "#{text}."
      end

    end
  end
end

Commands::Base::Registry.register(Commands::Staff::PEmote)
