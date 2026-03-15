# frozen_string_literal: true

module Commands
  module Events
    class Bounce < Commands::Base::Command
      command_name 'bounce'
      category :events
      help_text 'Remove someone from your event (host/staff only)'
      usage 'bounce <character>'
      examples 'bounce Bob', 'bounce troublemaker'

      protected

      def perform_command(parsed_input)
        target_name = parsed_input[:text]&.strip

        if blank?(target_name)
          return error_result("Bounce whom? Use: bounce <character>")
        end

        # Check if trying to bounce self (by name)
        if target_name.downcase == character.forename.downcase ||
           target_name.downcase == character.full_name.downcase
          return error_result("You can't bounce yourself.")
        end

        # Find target in room
        target = find_character_in_room(target_name)
        unless target
          return error_result("#{target_name} is not here.")
        end

        # Find an active event where we have authority
        event = Event.find_controllable_by(character, location)
        unless event
          return error_result("You're not hosting or staffing an event here.")
        end

        bounce_from_event(target, event)
      end

      private

      def bounce_from_event(target, event)
        target_character = target.character

        # Check if target is already bounced
        existing = EventAttendee.first(event_id: event.id, character_id: target_character.id)
        if existing&.bounced?
          return error_result("#{target_character.forename} is already bounced from this event.")
        end

        # Find or create attendee record and bounce them
        attendee = EventAttendee.find_or_create(event_id: event.id, character_id: target_character.id)
        attendee.bounce!(character)

        # If they're currently in this event, eject them immediately.
        if target.in_event_id == event.id
          EventService.leave_event!(character_instance: target)
        end

        broadcast_to_room(
          "#{character.full_name} bounces #{target_character.forename} from #{event.name}.",
          exclude_character: nil
        )

        # Notify the target
        BroadcastService.to_character(target, {
          type: 'system',
          content: "You have been bounced from #{event.name}. You cannot re-enter this event."
        })

        success_result(
          "You bounce #{target_character.forename} from #{event.name}.",
          type: :message,
          data: {
            action: 'bounce',
            target_id: target.id,
            target_name: target_character.forename,
            event_id: event.id,
            event_name: event.name
          }
        )
      end

      # Uses inherited find_character_in_room from base command
    end
  end
end

Commands::Base::Registry.register(Commands::Events::Bounce)
