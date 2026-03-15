# frozen_string_literal: true

module Commands
  module Communication
    class Oocrequest < Commands::Base::Command
      command_name 'oocrequest'
      aliases 'oocreq', 'reqooc'
      category :communication
      help_text 'Send an OOC contact request to someone who requires permission'
      usage 'oocrequest <character> <message>'
      examples 'oocrequest Bob Hi, would you like to discuss the plot?'

      protected

      def perform_command(parsed_input)
        args = parsed_input[:text]&.strip || ''

        # Parse: first word is character name, rest is message
        match = args.match(/^(\S+)\s+(.+)$/m)
        unless match
          return error_result("Usage: oocrequest <character> <message>")
        end

        target_name = match[1]
        message = match[2].strip

        max_len = GameConfig::Forms::MAX_LENGTHS[:ooc_message]
        if message.length > max_len
          return error_result("Message too long. Maximum #{max_len} characters.")
        end

        target = find_character_by_name_globally(target_name)
        return error_result("Character '#{target_name}' not found.") unless target

        target_user = target.user

        # Can't request yourself
        if target_user.id == current_user.id
          return error_result("You can't send an OOC request to yourself.")
        end

        # Check cooldown
        if OocRequest.in_cooldown?(current_user, target_user)
          return error_result("You must wait before sending another request to this player.")
        end

        # Check they actually require requests
        perm = UserPermission.ooc_permission(current_user, target_user)
        unless perm == 'ask'
          case perm
          when 'yes'
            return error_result("This player accepts OOC messages. Use 'pm' directly.")
          when 'no'
            return error_result("This player has blocked OOC messages from you.")
          end
        end

        # Create request
        request = OocRequest.create(
          sender_user_id: current_user.id,
          target_user_id: target_user.id,
          sender_character_id: character.id,
          message: message,
          status: 'pending'
        )

        # Notify target if online and set pending request
        notify_target(target_user, request, message)

        success_result(
          "OOC request sent to #{target.full_name}. They will be notified.",
          type: :message,
          data: { action: 'ooc_request_sent', target_id: target.id }
        )
      end

      private

      def notify_target(target_user, request, message)
        # Find online instance for target
        target_char = Character.where(user_id: target_user.id).exclude(is_npc: true).first
        return unless target_char

        target_instance = CharacterInstance.where(
          character_id: target_char.id,
          online: true
        ).first
        return unless target_instance

        # Set pending OOC request on target for quickmenu response
        target_instance.set_pending_ooc_request!(request)

        sender_name = character.full_name

        # Create quickmenu for accept/decline
        options = [
          { key: 'accept', label: 'Accept', description: 'Allow OOC contact from this player' },
          { key: 'decline', label: 'Decline', description: 'Deny this request' }
        ]

        display_msg = message.length > 100 ? "#{message[0..96]}..." : message
        prompt = "#{sender_name} wants to contact you OOC: \"#{display_msg}\""

        quickmenu = create_quickmenu(
          target_instance,
          prompt,
          options,
          context: {
            handler: 'ooc_request',
            request_id: request.id,
            sender_name: sender_name
          }
        )

        # Send the quickmenu to the target
        BroadcastService.to_character(
          target_instance,
          quickmenu[:message],
          type: :quickmenu,
          data: quickmenu[:data]
        )
      end

      def current_user
        character.user
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Communication::Oocrequest)
