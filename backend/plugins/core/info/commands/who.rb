# frozen_string_literal: true

module Commands
  module Info
    class Who < Commands::Base::Command
      command_name 'who'
      aliases 'where'
      category :info
      output_category :info
      help_text 'List online characters'
      usage 'who [here|all]'
      examples 'who', 'who here', 'who all'

      protected

      def perform_command(parsed_input)
        scope = parsed_input[:text]&.strip&.downcase

        case scope
        when 'here'
          who_in_room
        when 'all'
          who_global
        when nil, ''
          who_in_zone
        else
          error_result("Unknown scope '#{scope}'. Use: who, who here, or who all")
        end
      end

      private

      def who_in_room
        characters = online_characters_in_room

        if characters.empty?
          return success_result("You're alone here.", type: :message)
        end

        output = build_room_output(location, characters)
        success_result(output, type: :message, data: { scope: 'room', count: characters.length })
      end

      def who_in_zone
        zone = location.location&.zone
        unless zone
          return who_in_room
        end

        # Get all rooms in this zone
        rooms_in_zone = Room.join(:locations, id: :location_id)
                           .where(Sequel[:locations][:zone_id] => zone.id)
                           .select_all(:rooms)
                           .all

        room_ids = rooms_in_zone.map(&:id)

        # Get online characters in these rooms
        characters_by_room = online_characters_in_rooms(room_ids)

        if characters_by_room.values.flatten.empty?
          return success_result("No one is online in #{zone.name}.", type: :message)
        end

        output = build_zone_output(zone, characters_by_room)
        total = characters_by_room.values.flatten.length
        success_result(output, type: :message, data: { scope: 'zone', zone: zone.name, count: total })
      end

      def who_global
        all_characters = CharacterInstance.where(online: true, status: 'alive')
                                          .exclude(id: character_instance.id)
                                          .eager(:character)
                                          .all

        # Filter out NPCs and apply visibility permissions
        all_characters = all_characters.select { |ci| !ci.character&.is_npc && visible_to_viewer?(ci) }

        if all_characters.empty?
          html = render_wrapper('Online') { render_empty("You're the only one online.") }
          html += render_upcoming_event
          return success_result(html, type: :message)
        end

        # Group by location type (timeline, event, zone)
        by_timeline = {}
        by_event = {}
        by_zone = {}

        all_characters.each do |ci|
          loc_info = location_display_for(ci)

          case loc_info[:type]
          when :timeline
            (by_timeline[loc_info[:name]] ||= []) << ci
          when :event
            (by_event[loc_info[:name]] ||= []) << ci
          else
            zone_name = loc_info[:zone]&.name || 'Unknown'
            (by_zone[zone_name] ||= []) << ci
          end
        end

        html = render_wrapper('Online') do
          sections = []

          by_zone.sort.each do |zone_name, chars|
            sections << render_section(zone_name, chars)
          end

          if by_event.any?
            by_event.sort.each do |event_name, chars|
              sections << render_section("Event: #{event_name}", chars)
            end
          end

          if by_timeline.any?
            by_timeline.sort.each do |timeline_name, chars|
              sections << render_section("Timeline: #{timeline_name}", chars)
            end
          end

          sections << render_count(all_characters.length)
          sections.join
        end

        html += render_upcoming_event

        success_result(html, type: :message, data: { scope: 'global', count: all_characters.length })
      end

      def online_characters_in_room
        characters = CharacterInstance.where(
          current_room_id: location.id,
          reality_id: character_instance.reality_id,
          online: true,
          status: 'alive'
        ).exclude(id: character_instance.id).all

        characters.select { |ci| !ci.character&.is_npc && visible_to_viewer?(ci) }
      end

      def online_characters_in_rooms(room_ids)
        characters = CharacterInstance.where(
          current_room_id: room_ids,
          reality_id: character_instance.reality_id,
          online: true,
          status: 'alive'
        ).exclude(id: character_instance.id).all

        # Filter out NPCs and apply visibility permissions
        characters = characters.select { |ci| !ci.character&.is_npc && visible_to_viewer?(ci) }

        # Group by room
        characters.group_by(&:current_room_id)
      end

      def build_room_output(room, characters)
        render_wrapper(h(room.name)) { characters.map { |ci| render_character(ci) }.join }
      end

      def build_zone_output(zone, characters_by_room)
        render_wrapper(h(zone.name)) do
          sections = []
          characters_by_room.each do |room_id, chars|
            next if chars.empty?
            room = Room[room_id]
            sections << render_section(room&.name || 'Unknown', chars)
          end
          sections.join
        end
      end

      def display_name(ci)
        ci.character.display_name_for(character_instance)
      end

      # --- HTML rendering helpers ---

      def render_wrapper(title)
        <<~HTML
          <div style="font-family: inherit; max-width: 400px;">
            <div style="text-align: center; margin-bottom: 8px;">
              <span style="font-size: 1.1em; font-weight: bold; letter-spacing: 0.5px; opacity: 0.9;">#{h(title)}</span>
            </div>
            <div style="background: rgba(255,255,255,0.04); border: 1px solid rgba(255,255,255,0.08); border-radius: 6px; padding: 8px 12px;">
              #{yield}
            </div>
          </div>
        HTML
      end

      def render_section(heading, chars)
        rows = chars.map { |ci| render_character(ci) }.join
        <<~HTML
          <div style="margin-bottom: 6px;">
            <div style="font-size: 0.75em; text-transform: uppercase; letter-spacing: 1px; opacity: 0.45; margin-bottom: 4px;">#{h(heading)}</div>
            #{rows}
          </div>
        HTML
      end

      def render_character(ci)
        name = h(display_name(ci))
        detail = character_detail(ci)
        detail_html = detail ? " <span style=\"opacity: 0.45; font-size: 0.85em;\">#{h(detail)}</span>" : ''

        <<~HTML
          <div style="padding: 2px 0; display: flex; align-items: baseline;">
            <span style="margin-right: 6px; opacity: 0.3;">&#x2022;</span>
            <span>#{name}#{detail_html}</span>
          </div>
        HTML
      end

      def character_detail(ci)
        parts = []

        stance = ci.current_stance
        parts << stance unless stance == 'standing'

        if ci.current_place
          prep = ci.current_place.default_sit_action || 'at'
          parts << "#{prep} #{ci.current_place.name}"
        end

        parts.any? ? parts.join(' ') : nil
      end

      def render_count(count)
        <<~HTML
          <div style="text-align: right; font-size: 0.8em; opacity: 0.4; margin-top: 4px;">#{count} online</div>
        HTML
      end

      def render_empty(message)
        <<~HTML
          <div style="opacity: 0.5; font-style: italic; padding: 4px 0;">#{h(message)}</div>
        HTML
      end

      def render_upcoming_event
        next_event = Event.public_upcoming(limit: 1).first
        return '' unless next_event

        time_diff = next_event.starts_at - Time.now
        hours = (time_diff / 3600).floor

        time_str = if hours < 1
                     'starting soon'
                   elsif hours < 24
                     "in #{hours} hour#{hours == 1 ? '' : 's'}"
                   else
                     next_event.starts_at.strftime('%b %d at %I:%M %p')
                   end

        event_location = next_event.room&.name || next_event.location&.name || 'TBD'

        <<~HTML
          <div style="max-width: 400px; margin-top: 8px; padding: 6px 12px; background: rgba(96,165,250,0.08); border: 1px solid rgba(96,165,250,0.15); border-radius: 6px; font-size: 0.85em;">
            <span style="opacity: 0.5;">Next Event:</span> #{h(next_event.name)} at #{h(event_location)} <span style="opacity: 0.5;">— #{h(time_str)}</span>
          </div>
        HTML
      end

      def h(text)
        ERB::Util.html_escape(text.to_s)
      end

      # Check if target character instance is visible to the viewer based on permissions
      # @param target_ci [CharacterInstance] The character to check visibility for
      # @return [Boolean] True if target is visible to viewer
      def visible_to_viewer?(target_ci)
        target_user = target_ci.character&.user
        return false unless target_user # No user = NPC, hidden from who

        viewer_user = character.user
        return true if target_user.id == viewer_user.id # Always see your own alts

        # Check private mode - hidden if in private mode
        return false if target_ci.private_mode?

        # Check room publicity - only secluded rooms are hidden
        # public and semi_public rooms both show location
        target_room = target_ci.current_room
        return false if target_room&.secluded?

        # Check event/timeline visibility - returns :hidden if can't see
        loc_info = location_display_for(target_ci)
        return false if loc_info[:type] == :hidden

        # Existing locatability check
        target_locatability = target_ci.locatability || 'yes'
        UserPermission.can_see_in_where?(viewer_user, target_user, target_locatability)
      end

      # Determine what location to display for a character
      # @param target_ci [CharacterInstance] The character to get location for
      # @return [Hash] Location info with :type key (:timeline, :event, :location, :hidden)
      def location_display_for(target_ci)
        # If in a different timeline, show timeline info (if accessible)
        if target_ci.timeline_id && target_ci.timeline
          timeline = target_ci.timeline
          if timeline.snapshot?
            # For snapshot timelines, check if viewer can access
            snapshot = timeline.snapshot
            if snapshot&.can_enter?(character)
              return { type: :timeline, name: timeline.display_name }
            else
              return { type: :hidden }
            end
          else
            # Historical timelines are generally accessible
            return { type: :timeline, name: timeline.display_name }
          end
        end

        # If in an event, show event info (if accessible)
        if target_ci.in_event?
          event = target_ci.in_event
          # Show if public OR viewer is attending/was attending OR viewer is organizer
          if event.is_public ||
             event.attending?(character) ||
             event.was_attending?(character) ||
             event.organizer_id == character.id
            return { type: :event, name: event.name, event: event }
          else
            return { type: :hidden }
          end
        end

        # Default: show room/zone
        room = target_ci.current_room
        zone = room&.location&.zone
        { type: :location, room: room, zone: zone }
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Info::Who)
