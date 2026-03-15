# frozen_string_literal: true

module Commands
  module Communication
    class Pemit < Commands::Base::Command
      command_name 'pemit'
      aliases 'emit to', 'semit'
      category :communication
      help_text 'Staff: Send a private emit to specific character(s)'
      usage 'pemit <target> <message>'
      examples 'pemit John A chill runs down your spine.', 'pemit Bob, Alice You both feel a strange presence.'

      protected

      def perform_command(parsed_input)
        # Check staff permissions
        unless can_pemit?
          return error_result("You don't have permission to use this command.")
        end

        text = parsed_input[:text]
        return error_result("Usage: pemit <target> <message>") if blank?(text)

        # Handle "emit to" alias - strip "to" prefix if single-word 'emit' command
        text = text.sub(/^to\s+/i, '') if parsed_input[:command_word] == 'emit'

        # Try "=" separator first (backward compat, unambiguous)
        targets_str, message = parse_pemit_input(text)

        # Fall back to normalizer for natural language: "pemit Bob Hello"
        if targets_str.nil? || message.nil?
          normalized = parsed_input[:normalized]
          if normalized[:target] && normalized[:message]
            targets_str = normalized[:target]
            message = normalized[:message]
          else
            # Re-normalize text directly (handles "emit to" alias where
            # normalizer didn't recognize the multi-word command name)
            re_normalized = ArgumentNormalizerService.normalize('pemit', text)
            if re_normalized[:target] && re_normalized[:message]
              targets_str = re_normalized[:target]
              message = re_normalized[:message]
            end
          end
        end

        if targets_str.nil? || message.nil?
          return error_result("Usage: pemit <target> <message>")
        end
        return error_result("What did you want to emit?") if message.strip.empty?

        target_instances = find_targets(targets_str)
        return error_result("None of those characters are here.") if target_instances.empty?

        # Send the emit to each target
        broadcast_pemit(message, target_instances)

        target_names = target_instances.map { |ti| ti.character.full_name }.join(', ')
        log_roleplay("[PEMIT to #{target_names}] #{message}")

        success_result(
          "Privately emitted to: #{target_names}",
          type: :pemit,
          data: {
            targets: target_names,
            message: message,
            target_count: target_instances.size
          }
        )
      end

      private

      def can_pemit?
        # Check if character is a staff character or user is admin
        character.staff? || character.user&.admin?
      end

      def parse_pemit_input(text)
        # Format: "target(s) = message"
        parts = text.split('=', 2)
        return [nil, nil] unless parts.length == 2

        targets_str = parts[0].strip
        message = parts[1].strip

        [targets_str, message]
      end

      def find_targets(targets_str)
        return [] unless location

        # Support comma-separated targets
        target_names = targets_str.split(',').map(&:strip).reject(&:empty?)
        return [] if target_names.empty?

        room_characters = online_room_characters.eager(:character).all

        found_targets = []

        target_names.each do |target_name|
          # Skip self
          next if target_name.downcase == character.full_name.downcase

          # Use centralized resolver for character matching
          target = TargetResolverService.resolve_character(
            query: target_name,
            candidates: room_characters
          )
          found_targets << target if target && !found_targets.include?(target)
        end

        found_targets
      end

      def broadcast_pemit(message, target_instances)
        # Staff sees what they sent
        staff_message = format_staff_confirmation(message, target_instances)
        send_to_character(character_instance, staff_message)

        # Each target sees the emit (wrapped in fieldset for visual distinction)
        formatted_emit = "<fieldset>#{message}</fieldset>"
        target_instances.each do |target|
          send_to_character(target, formatted_emit)
        end
      end

      def format_staff_confirmation(message, target_instances)
        target_names = target_instances.map { |ti| ti.character.full_name }.join(', ')
        "[PEMIT to #{target_names}]: #{message}"
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Communication::Pemit)
