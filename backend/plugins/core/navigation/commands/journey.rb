# frozen_string_literal: true

module Commands
  module Navigation
    class Journey < Commands::Base::Command
      command_name 'journey'
      aliases 'world_travel', 'voyage', 'travel'
      category :navigation
      help_text 'Plan and manage world travel journeys'
      usage 'journey [to <dest>|party|return|disembark|invite <name>|launch|cancel]'
      examples 'journey', 'journey to Ravencroft', 'journey party', 'journey return', 'journey disembark'

      requires :not_in_combat, message: "You can't do that while in combat!"

      protected

      def perform_command(parsed_input)
        text = parsed_input[:text]&.strip || ''

        case text
        when ''
          # No args: show status or open travel GUI
          show_journey_status
        when /^to\s+(.+)$/i
          # journey to <dest>: show options for destination
          show_travel_options(Regexp.last_match(1).strip)
        when /^party$/i, /^passengers$/i
          # journey party: show party status or passengers
          show_party_or_passengers
        when /^return$/i, /^freturn$/i, /^fr$/i
          # journey return: return from flashback
          flashback_return
        when /^disembark$/i, /^leave$/i, /^exit$/i
          # journey disembark: leave journey early
          disembark
        when /^invite\s+(.+)$/i
          # journey invite <name>
          invite_to_party(Regexp.last_match(1).strip)
        when /^launch$/i
          # journey launch: start party journey
          launch_party
        when /^cancel$/i
          # journey cancel: cancel party
          cancel_party
        else
          # Treat as destination name (strip "to " prefix if present)
          dest = text.sub(/^to\s*/i, '').strip
          if dest.empty?
            show_journey_status
          else
            show_travel_options(dest)
          end
        end
      end

      private

      def show_journey_status
        # If traveling, show journey status with quickmenu options
        if character_instance.traveling?
          return show_current_journey_menu
        end

        # If in flashback instance, show flashback status with options
        if character_instance.flashback_instanced?
          return show_flashback_status_menu
        end

        # Otherwise, open travel GUI
        success_result(
          'Opening world travel map...',
          type: :open_gui,
          data: { gui: 'travel_map' }
        )
      end

      def show_current_journey_menu
        journey = character_instance.current_world_journey
        return error_result("Journey data not found.") unless journey

        dest_name = journey.destination_location&.display_name || 'Unknown'
        eta = journey.time_remaining_display

        options = [
          { key: 'party', label: 'View Passengers', description: 'See who is traveling with you' },
          { key: 'disembark', label: 'Disembark', description: 'Leave the journey early (wilderness)' }
        ]

        create_quickmenu(
          character_instance,
          "Traveling to #{dest_name}\nETA: #{eta}",
          options,
          context: { command: 'journey', action: 'traveling' }
        )
      end

      def show_flashback_status_menu
        mode = character_instance.flashback_travel_mode
        origin_room = character_instance.flashback_origin_room
        origin_name = origin_room&.name || 'your origin'
        reserved_time = character_instance.flashback_time_reserved

        prompt = "You are in a flashback instance.\nOrigin: #{origin_name}"

        if mode == 'return' && reserved_time
          prompt += "\nReserved return time: #{FlashbackTimeService.format_time(reserved_time)}"
        end

        options = [
          { key: 'return', label: 'Return', description: 'Return to your origin instantly' }
        ]

        create_quickmenu(
          character_instance,
          prompt,
          options,
          context: { command: 'journey', action: 'flashback' }
        )
      end

      def show_travel_options(destination_text)
        # Check if already traveling
        if character_instance.traveling?
          journey = character_instance.current_world_journey
          dest_name = journey.destination_location&.display_name || 'unknown destination'
          return error_result(
            "You are already on a journey to #{dest_name}. " \
            "Use 'eta' to check progress or 'disembark' to leave early."
          )
        end

        # Check if in flashback instance
        if character_instance.flashback_instanced?
          return error_result(
            "You are in a flashback instance. Use 'journey return' to return to your origin first."
          )
        end

        destination = find_destination(destination_text)

        unless destination
          return error_result(
            "Cannot find a location matching '#{destination_text}'. " \
            'Try specifying a city or major landmark name.'
          )
        end

        # Check if destination is current location
        current_location = character_instance.current_room&.location
        if destination.id == current_location&.id
          return error_result("You're already at #{destination.name}!")
        end

        # Get travel options via JourneyService
        options = JourneyService.travel_options(character_instance, destination)

        unless options[:success]
          return error_result(options[:error])
        end

        # Show quickmenu with travel options
        show_travel_quickmenu(options)
      end

      def show_travel_quickmenu(options)
        dest_name = options[:destination][:name]
        journey_time = options[:journey_time_display]
        flashback = options[:flashback]
        modes = options[:available_modes]

        menu_items = []

        # Add standard travel option
        menu_items << {
          key: 'standard',
          label: "Standard Travel (#{journey_time})",
          description: "Travel normally to #{dest_name}"
        }
        menu_items << {
          key: 'assemble_party',
          label: 'Assemble Party',
          description: "Create a travel party to #{dest_name} and invite others before departure"
        }

        # Add flashback options if available
        if flashback[:available].to_i > 0
          basic = flashback[:basic]
          if basic[:success]
            if basic[:can_instant]
              menu_items << {
                key: 'flashback_basic',
                label: 'Flashback (Instant)',
                description: "Arrive instantly using #{FlashbackTimeService.format_time(basic[:flashback_used])} flashback time"
              }
            else
              menu_items << {
                key: 'flashback_basic',
                label: 'Flashback (Reduced)',
                description: "Travel reduced to #{FlashbackTimeService.format_time(basic[:time_remaining])}"
              }
            end
          end

          return_opt = flashback[:return]
          if return_opt[:success] && return_opt[:can_instant]
            menu_items << {
              key: 'flashback_return',
              label: 'Flashback Return (Instanced)',
              description: "Instant arrival, #{FlashbackTimeService.format_time(return_opt[:reserved_for_return])} reserved for return"
            }
          end

          backloaded = flashback[:backloaded]
          if backloaded[:success]
            menu_items << {
              key: 'flashback_backloaded',
              label: 'Backloaded (Instanced)',
              description: "Instant arrival, #{FlashbackTimeService.format_time(backloaded[:return_debt])} return debt"
            }
          end
        end

        menu_items << { key: 'cancel', label: 'Cancel', description: 'Cancel travel planning' }

        # Build quickmenu data for travel options
        quickmenu_data = {
          prompt: "Journey to #{dest_name}?",
          options: menu_items,
          handler: 'travel_options',
          context: {
            destination_id: options[:destination][:id],
            origin_id: options[:origin][:id],
            travel_mode: modes.first
          }
        }

        disambiguation_result(quickmenu_data, "Select how you'd like to travel to #{dest_name}:")
      end

      def show_party_status
        party = TravelParty.where(leader_id: character_instance.id, status: 'assembling').first

        unless party
          # Check if member of someone else's party
          membership = TravelPartyMember
                       .join(:travel_parties, id: :party_id)
                       .where(character_instance_id: character_instance.id)
                       .where(Sequel[:travel_parties][:status] => 'assembling')
                       .first

          if membership
            party = TravelParty[membership[:party_id]]
            return party_member_status(party)
          end

          return error_result(
            "You don't have an active travel party. " \
            "Use 'journey to <destination>' and select 'Assemble Party' to create one."
          )
        end

        summary = party.status_summary
        destination_name = if summary[:destination].is_a?(Hash)
                             summary[:destination][:name] || 'Unknown'
                           else
                             summary[:destination] || 'Unknown'
                           end
        msg = "Travel Party to #{destination_name}:\n"
        msg += "Travel Mode: #{summary[:travel_mode]}\n" if summary[:travel_mode]
        msg += "Flashback: #{summary[:flashback_mode]}\n" if summary[:flashback_mode] && summary[:flashback_mode] != 'none'
        msg += "\nMembers:\n"

        summary[:members].each do |member|
          status_icon = case member[:status]
                        when 'accepted' then '✓'
                        when 'pending' then '...'
                        when 'declined' then '✗'
                        else '?'
                        end
          leader_tag = member[:is_leader] ? ' [LEADER]' : ''
          msg += "  #{member[:name]}#{leader_tag}: #{status_icon} #{member[:status]}\n"
        end

        msg += "\nUse 'journey invite <name>' to invite, 'journey launch' to depart, or 'journey cancel' to disband."

        success_result(msg)
      end

      def party_member_status(party)
        leader = party.leader
        dest = party.destination

        msg = "You have been invited to travel with #{leader.character.full_name} to #{dest.name}.\n"

        membership = TravelPartyMember.where(party_id: party.id, character_instance_id: character_instance.id).first
        if membership&.pending?
          msg += "Status: Pending - respond to accept or decline the invitation."
        elsif membership&.accepted?
          msg += "Status: Accepted - waiting for the party leader to launch."
        end

        success_result(msg)
      end

      def invite_to_party(name)
        party = TravelParty.where(leader_id: character_instance.id, status: 'assembling').first

        unless party
          return error_result(
            "You don't have an active travel party. " \
            "Use 'journey to <destination>' and select 'Assemble Party' first."
          )
        end

        # Find target character in same location
        target = find_character_in_location(name)

        unless target
          return error_result("Cannot find '#{name}' in this area.")
        end

        if target.id == character_instance.id
          return error_result("You can't invite yourself!")
        end

        # Check if already invited
        if party.member?(target)
          return error_result("#{target.character.full_name} is already in the party.")
        end

        # Send invite
        result = party.invite!(target)

        if result[:success]
          success_result("Invited #{target.character.full_name} to the travel party.")
        else
          error_result(result[:error])
        end
      end

      def launch_party
        party = TravelParty.where(leader_id: character_instance.id, status: 'assembling').first

        unless party
          return error_result("You don't have an active travel party to launch.")
        end

        unless party.can_launch?
          return error_result(
            "Cannot launch yet. You need at least one accepted party member. " \
            "Use 'journey invite <name>' to invite others, or 'journey cancel' to disband."
          )
        end

        result = party.launch!

        if result[:success]
          broadcast_party_departure(party, result)
          success_result(result[:message])
        else
          error_result(result[:error])
        end
      end

      def cancel_party
        party = TravelParty.where(leader_id: character_instance.id, status: 'assembling').first

        unless party
          return error_result("You don't have an active travel party to cancel.")
        end

        party.cancel!

        success_result('Travel party cancelled.')
      end

      # ========== Flashback Return ==========
      def flashback_return
        unless character_instance.flashback_instanced?
          return error_result(
            "You're not in a flashback instance. " \
            "Use 'journey to <destination>' with flashback options to travel using flashback time."
          )
        end

        mode = character_instance.flashback_travel_mode
        origin_room = character_instance.flashback_origin_room
        reserved_time = character_instance.flashback_time_reserved
        return_debt = character_instance.flashback_return_debt

        origin_name = origin_room&.name || 'your origin'

        result = FlashbackTravelService.end_flashback_instance(character_instance)

        if result[:success]
          data = {
            action: 'flashback_return',
            origin: origin_name,
            mode: mode,
            instant: result[:instant] || false
          }

          if mode == 'return'
            data[:reserved_time] = reserved_time
            data[:reserved_time_display] = FlashbackTimeService.format_time(reserved_time)
          elsif mode == 'backloaded'
            data[:return_debt] = return_debt
            data[:return_debt_display] = FlashbackTimeService.format_time(return_debt)
          end

          success_result(
            result[:message],
            type: :flashback_return,
            data: data
          )
        else
          error_result(result[:error])
        end
      end

      # ========== Disembark ==========
      def disembark
        unless character_instance.traveling?
          return error_result("You're not currently on a journey.")
        end

        journey = character_instance.current_world_journey
        unless journey
          return error_result("Journey data not found.")
        end

        vehicle = journey.vehicle_type.tr('_', ' ')
        destination = journey.destination_location&.display_name || 'destination'

        result = WorldTravelService.disembark(character_instance)

        if result[:success]
          room = result[:room]

          notify_other_passengers_of_disembark(journey, vehicle)

          success_result(
            result[:message],
            type: :world_travel,
            data: {
              action: 'disembarked',
              room_id: room.id,
              room_name: room.name,
              original_destination: destination
            }
          )
        else
          error_result(result[:error])
        end
      end

      def notify_other_passengers_of_disembark(journey, vehicle)
        journey.passengers.each do |passenger|
          next if passenger.id == character_instance.id

          BroadcastService.send_system_message(
            passenger,
            "#{character.full_name} disembarks from the #{vehicle}.",
            type: :travel_update
          )
        end
      rescue StandardError => e
        warn "[Journey] Disembark notification error: #{e.message}"
        nil
      end

      # ========== Party/Passengers ==========
      def show_party_or_passengers
        # If currently traveling, show passengers
        if character_instance.traveling?
          return show_passengers
        end

        # Otherwise show party status
        show_party_status
      end

      def show_passengers
        journey = character_instance.current_world_journey
        unless journey
          return error_result("Journey data not found.")
        end

        passengers = journey.passengers
        vehicle = journey.vehicle_type.tr('_', ' ')

        message = build_passengers_message(journey, passengers, vehicle)

        success_result(
          message,
          type: :travel_passengers,
          data: {
            vehicle: journey.vehicle_type,
            passenger_count: passengers.length,
            passengers: passengers.map do |p|
              {
                id: p.id,
                name: p.full_name,
                is_driver: journey.driver&.id == p.id
              }
            end
          }
        )
      end

      def build_passengers_message(journey, passengers, vehicle)
        lines = []
        lines << "<h3>Passengers aboard the #{vehicle.capitalize}</h3>"

        if passengers.empty?
          lines << "There are no other passengers."
        else
          driver = journey.driver

          passengers.each do |passenger|
            if passenger.id == character_instance.id
              if driver&.id == character_instance.id
                lines << "- #{passenger.full_name} (you, driving)"
              else
                lines << "- #{passenger.full_name} (you)"
              end
            elsif driver&.id == passenger.id
              lines << "- #{passenger.full_name} (driving)"
            else
              lines << "- #{passenger.full_name}"
            end
          end
        end

        lines << ""
        lines << "Destination: #{journey.destination_location&.display_name || 'Unknown'}"
        lines << "ETA: #{journey.time_remaining_display}"

        lines.join("\n")
      end

      def find_destination(text)
        world = character_instance.current_room&.location&.world
        return nil unless world

        # First try exact city name match
        location = Location.where(world_id: world.id)
                           .where(Sequel.ilike(:city_name, text))
                           .first

        return location if location

        # Try partial city name match
        location = Location.where(world_id: world.id)
                           .where(Sequel.ilike(:city_name, "%#{text}%"))
                           .exclude(id: character_instance.current_room&.location_id)
                           .first

        return location if location

        # Try location name match
        location = Location.where(world_id: world.id)
                           .where(Sequel.ilike(:name, "%#{text}%"))
                           .exclude(id: character_instance.current_room&.location_id)
                           .first

        return location if location

        # Try zone name and get first location
        zone = Zone.where(world_id: world.id)
                   .where(Sequel.ilike(:name, "%#{text}%"))
                   .first

        zone&.locations_dataset&.first
      end

      def find_character_in_location(name)
        current_location = character_instance.current_room&.location
        return nil unless current_location

        # Search for character in the same location
        CharacterInstance
          .join(:characters, id: :character_id)
          .join(:rooms, id: Sequel[:character_instances][:current_room_id])
          .where(Sequel[:rooms][:location_id] => current_location.id)
          .where(Sequel[:character_instances][:online] => true)
          .where(Sequel.ilike(Sequel[:characters][:name], "%#{name}%"))
          .exclude(Sequel[:character_instances][:id] => character_instance.id)
          .select_all(:character_instances)
          .first
      end

      def broadcast_party_departure(party, _result)
        travelers = resolve_party_traveler_names(party)
        dest_name = party.destination.name
        count = travelers.count

        if count == 1
          message = "#{travelers.first} departs on a journey to #{dest_name}."
        else
          names = travelers.count > 2 ?
            "#{travelers[0..-2].join(', ')}, and #{travelers.last}" :
            travelers.join(' and ')
          message = "#{names} depart together on a journey to #{dest_name}."
        end

        broadcast_to_room(message, exclude_character: character)
      end

      def resolve_party_traveler_names(party)
        travelers = if party.respond_to?(:accepted_character_instances)
                      party.accepted_character_instances
                    else
                      party.accepted_members.map do |member|
                        member.respond_to?(:character_instance) ? member.character_instance : member
                      end
                    end

        names = travelers.filter_map { |ci| ci&.character&.full_name || ci&.full_name }
        return names if names.any?

        [character.full_name]
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Navigation::Journey)
