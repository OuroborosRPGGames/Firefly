# frozen_string_literal: true

module Commands
  module Communication
    class Attempt < Commands::Base::Command
      command_name 'attempt'
      aliases 'propose', 'request'
      category :roleplaying
      help_text 'Propose an action that requires the target\'s permission'
      usage 'attempt <character> <action>'
      examples 'attempt Alice hugs warmly', 'attempt Bob kisses on the cheek', 'propose Charlie gives a high five'

      requires_can_communicate_ic

      protected

      def perform_command(parsed_input)
        text = parsed_input[:text]&.strip

        return error_result("Usage: attempt <character> <action>") if blank?(text)

        # Use normalizer for "to target action" and "action to target" patterns
        normalized = parsed_input[:normalized]
        if normalized[:target] && normalized[:message] && text =~ /\bto\b/i
          text = "#{normalized[:target]} #{normalized[:message]}"
        end

        # Parse target and emote using multi-word matching
        target, target_name, emote_text = find_target_and_message(text, exclude_self: false)

        return error_result("What do you want to attempt?") if blank?(emote_text)

        # Check if attempting on self first
        if target && target.id == character_instance.id
          return error_result("You can't attempt an action on yourself. Just do it!")
        end

        return error_result("You don't see '#{target_name}' here.") unless target

        # Check if target already has a pending attempt from someone
        if target.has_pending_attempt?
          return error_result("#{target.character.full_name} already has a pending action request.")
        end

        # Check if you already have an attempt pending
        if character_instance.attempt_target_id
          return error_result("You already have a pending action request. Wait for a response or cancel it.")
        end

        # Submit the attempt
        character_instance.submit_attempt!(target, emote_text)

        # Notify the target
        send_attempt_request(target, emote_text)

        success_result(
          "You request permission from #{target.character.full_name} to: #{emote_text}",
          type: :message,
          data: {
            action: 'attempt',
            target_id: target.id,
            target_name: target.character.full_name,
            emote_text: emote_text
          }
        )
      end

      private

      # Uses inherited is_self_reference? from base command

      # Uses inherited find_character_in_room from base command with alive_only: true
      # Overriding to add the alive_only filter for consent-based interactions
      def find_character_in_room(name, **opts)
        super(name, **opts, alive_only: true)
      end

      def send_attempt_request(target, emote_text)
        sender_name = character.full_name

        # Create quickmenu for allow/deny
        options = [
          { key: 'allow', label: 'Allow', description: 'Let this action happen' },
          { key: 'deny', label: 'Deny', description: 'Reject this action' }
        ]

        prompt = "#{sender_name} wants your permission: #{sender_name} #{emote_text}"

        quickmenu = create_quickmenu(
          target,
          prompt,
          options,
          context: {
            handler: 'attempt',
            attempter_id: character_instance.id,
            emote_text: emote_text,
            sender_name: sender_name
          }
        )

        # Send the quickmenu to the target via WebSocket
        # Always use HTML message (even in agent mode) since the target may be on webclient
        message_content = quickmenu[:message] || format_quickmenu_html(prompt, quickmenu[:data][:options])
        BroadcastService.to_character(
          target,
          message_content,
          type: :quickmenu,
          notification: {
            title: character.display_name_for(target),
            body: "#{sender_name}: #{emote_text}".slice(0, 100),
            icon: character_instance.character&.profile_pic_url,
            setting: 'notify_emote'
          },
          data: quickmenu[:data],
          target_panel: 'right_observe_window'
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Communication::Attempt)
