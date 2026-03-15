# frozen_string_literal: true

require_relative '../../../../app/helpers/room_display_helper'

module Commands
  module Navigation
    class Look < Commands::Base::Command
      include RoomDisplayHelper
      command_name 'look'
      aliases 'l', 'examine', 'ex', 'look at'
      category :navigation
      output_category :info
      help_text 'Look at your surroundings, an object, or another character'
      usage 'look [target] or look [character] [item] or look [character]\'s [item]'
      examples 'look', 'look door', 'look John', 'look John sword', "look John's sword"

      protected

      def perform_command(parsed_input)
        target = parsed_input[:text]&.strip

        # Check for display mode flag (used by move command)
        if target&.start_with?('--mode=')
          mode = target.sub('--mode=', '').to_sym
          result = look_at_room(mode: mode)
        elsif target.nil? || target.empty?
          result = look_at_room(mode: :full)
        elsif target.downcase == 'self' || target.downcase == 'me'
          result = look_at_self
        elsif self_item_target?(target)
          result = look_at_self_item(target)
        elsif possessive_target?(target)
          result = look_at_others_item(target)
        elsif compound_target?(target)
          result = look_at_compound_target(target)
        else
          result = look_at_target(target)
        end

        # Look results are viewer-specific; skip room sync to prevent leaking
        # another player's room description into the main RP feed on resync
        result[:skip_room_sync] = true if result[:success]
        result
      end

      private

      # @param mode [Symbol] Display mode - :full, :arrival, or :transit
      def look_at_room(mode: :full)
        # Check if blindfolded - can only perceive sounds
        if character_instance.blindfolded?
          return look_at_room_blindfolded
        end

        # Check if on a world journey - show traveling room instead
        if character_instance.traveling?
          return look_at_traveling_room
        end

        # Check if in a vehicle - show vehicle interior instead
        if character_instance.current_vehicle_id
          return look_at_vehicle_interior
        end

        # Check if in a delve - delegate to delve room display
        if defined?(DelveParticipant)
          delve_participant = DelveParticipant.first(
            character_instance_id: character_instance.id,
            status: 'active'
          )
          if delve_participant&.current_room
            result = DelveMovementService.look(delve_participant)
            if result.success
              return success_result(
                result.message,
                type: :message,
                data: result.data
              )
            end
          end
        end

        service = RoomDisplayService.for(location, character_instance, mode: mode)
        room_data = service.build_display

        # Add Ravencroft-style nearby areas text with distance tags (only for full mode)
        if mode == :full
          nearby_areas = build_nearby_areas_text(room_data[:exits])
          room_data[:nearby_areas_text] = nearby_areas if nearby_areas
        end

        # Apply accessibility transform if mode is enabled
        if character_instance.accessibility_mode?
          room_data = AccessibilityOutputService.transform_room(room_data, character_instance)
          return success_result(
            room_data[:accessible_text],
            type: :room,
            structured: room_data,
            room_id: location.id,
            format: :accessible
          )
        end

        room_result(room_data, room_id: location.id, target_panel: Firefly::Panels::RIGHT_OBSERVE)
      end

      def look_at_room_blindfolded
        lines = []
        lines << "You can't see anything through your blindfold."
        lines << ""

        # Count characters in room (voices/presence)
        chars_here = location.characters_here(character_instance.reality_id, viewer: character_instance)
                             .exclude(id: character_instance.id)
                             .where(online: true)
                             .all

        if chars_here.any?
          if chars_here.count == 1
            lines << "You can hear someone nearby."
          else
            lines << "You can hear #{chars_here.count} people nearby."
          end
        else
          lines << "You don't hear anyone nearby."
        end

        # Mention if in a place
        if character_instance.current_place_id
          place = Place.first(id: character_instance.current_place_id)
          lines << "You feel like you're sitting or lying somewhere." if place
        end

        blindfolded_data = {
          blindfolded: true,
          people_nearby: chars_here.count,
          display_type: :blindfolded_room
        }

        success_result(
          lines.join("\n"),
          type: :room,
          structured: blindfolded_data,
          blindfolded: true
        )
      end

      def look_at_vehicle_interior
        vehicle = character_instance.current_vehicle
        return look_at_room_fallback unless vehicle

        lines = []
        lines << "<h3>#{vehicle.name || 'Vehicle Interior'}</h3>"
        lines << ""

        # Interior description
        if vehicle.in_desc && !vehicle.in_desc.to_s.empty?
          lines << vehicle.in_desc
        else
          lines << vehicle_type_interior_description(vehicle)
        end

        lines << ""
        lines << "The city passes by outside the windows."

        # Show other passengers
        passengers = vehicle.passengers.reject { |p| p.id == character_instance.id }
        if passengers.any?
          lines << ""
          lines << "Also here:"
          passengers.each do |p|
            lines << "  #{p.character.full_name}"
          end
        end

        vehicle_data = {
          id: vehicle.id,
          name: vehicle.name || 'Vehicle',
          vehicle_type: vehicle.vtype,
          interior_description: vehicle.in_desc,
          passengers: passengers.map { |p| { name: p.character.full_name, id: p.id } },
          display_type: :vehicle_interior
        }

        success_result(
          lines.join("\n"),
          type: :room,
          structured: vehicle_data,
          in_vehicle: true,
          vehicle_id: vehicle.id
        )
      end

      def look_at_room_fallback
        service = RoomDisplayService.for(location, character_instance)
        room_data = service.build_display
        room_result(room_data, room_id: location.id, target_panel: Firefly::Panels::RIGHT_OBSERVE)
      end

      def look_at_traveling_room
        journey = character_instance.current_world_journey
        return look_at_room_fallback unless journey

        lines = []
        vehicle = journey.vehicle_type.tr('_', ' ').capitalize

        # Build room name based on travel mode
        room_name = case journey.travel_mode
                    when 'water'
                      "Aboard the #{vehicle}"
                    when 'air'
                      "In Flight - #{vehicle}"
                    when 'rail'
                      "#{vehicle} Cabin"
                    else
                      "Traveling by #{vehicle}"
                    end

        lines << "<h3>#{room_name}</h3>"
        lines << ""

        # Vehicle interior description
        lines << journey.vehicle_description
        lines << ""

        # Current terrain/view
        terrain_desc = journey.terrain_description
        lines << case journey.travel_mode
                 when 'water'
                   "The #{vehicle.downcase} sails across #{terrain_desc}."
                 when 'air'
                   "Looking down, you see #{terrain_desc} far below."
                 when 'rail'
                   "Through the window, #{terrain_desc} passes by."
                 else
                   "Outside, the #{terrain_desc} stretches in all directions."
                 end

        lines << ""

        # Journey info
        destination = journey.destination_location&.display_name || 'Unknown destination'
        eta = journey.time_remaining_display
        lines << "Destination: #{destination}"
        lines << "ETA: #{eta}"

        # Show other passengers
        passengers = journey.passengers.reject { |p| p.id == character_instance.id }
        if passengers.any?
          lines << ""
          lines << "Fellow travelers:"
          passengers.each do |p|
            driver_note = journey.driver&.id == p.id ? ' (driving)' : ''
            lines << "  #{p.full_name}#{driver_note}"
          end
        end

        traveling_data = {
          journey_id: journey.id,
          name: room_name,
          vehicle_type: journey.vehicle_type,
          travel_mode: journey.travel_mode,
          terrain: terrain_desc,
          destination: destination,
          eta: eta,
          current_globe_hex_id: journey.current_globe_hex_id,
          passengers: passengers.map { |p| { name: p.full_name, id: p.id } },
          display_type: :traveling_room
        }

        success_result(
          lines.join("\n"),
          type: :room,
          structured: traveling_data,
          traveling: true,
          journey_id: journey.id
        )
      end

      def vehicle_type_interior_description(vehicle)
        case vehicle.vtype&.downcase
        when 'taxi', 'cab'
          "You're in the back of a taxi. The driver occasionally glances in the rearview mirror."
        when 'limo', 'limousine'
          "You're in a spacious limousine. Tinted windows provide privacy."
        when 'car', 'sedan', 'coupe'
          "You're in the passenger area of a car. The seats are comfortable."
        when 'truck', 'pickup'
          "You're in the cab of a truck. It smells faintly of gasoline."
        when 'bus'
          "You're on a bus. Seats line both sides of the aisle."
        when 'hovertaxi', 'hovercar'
          "You're in a hover vehicle. The city spreads out below through the transparent floor panels."
        when 'autocab'
          "You're in an autonomous vehicle. Screens display the route ahead."
        when 'carriage', 'hansom'
          "You're in a horse-drawn carriage. The leather seats creak with every bump."
        else
          "You're inside a vehicle."
        end
      end

      def look_at_self
        service = CharacterDisplayService.new(character_instance, viewer_instance: character_instance)
        char_data = service.build_display

        # Apply accessibility transform if mode is enabled
        if character_instance.accessibility_mode?
          char_data = AccessibilityOutputService.transform_character(char_data, character_instance)
          return success_result(
            char_data[:accessible_text],
            type: :message,
            structured: char_data.merge(display_type: :character),
            target: 'self',
            format: :accessible
          )
        end

        success_result(
          format_character_display(char_data),
          type: :message,
          structured: char_data.merge(display_type: :character),
          target: 'self'
        )
      end

      def self_item_target?(text)
        words = text.downcase.split
        return false unless words.length >= 2

        %w[self me].include?(words[0])
      end

      def look_at_self_item(text)
        # Can't look at specific things while blindfolded
        if character_instance.blindfolded?
          return error_result("You can't see anything through your blindfold.")
        end

        words = text.split
        item_name = words[1..].join(' ')

        item = find_item_on_character(character_instance, item_name)

        if item
          look_at_item(item, owner: character)
        else
          error_result("You don't have '#{item_name}' visible.")
        end
      end

      def look_at_character(target_instance)
        service = CharacterDisplayService.new(target_instance, viewer_instance: character_instance)
        char_data = service.build_display

        # Apply accessibility transform if mode is enabled
        if character_instance.accessibility_mode?
          char_data = AccessibilityOutputService.transform_character(char_data, character_instance)
          return success_result(
            char_data[:accessible_text],
            type: :message,
            structured: char_data.merge(display_type: :character),
            target: char_data[:name],
            target_id: target_instance.character.id,
            format: :accessible
          )
        end

        success_result(
          format_character_display(char_data),
          type: :message,
          structured: char_data.merge(display_type: :character),
          target: char_data[:name],
          target_id: target_instance.character.id
        )
      end

      def possessive_target?(text)
        text.include?("'s ") || text.include?("' ")
      end

      def look_at_others_item(text)
        # Can't look at specific things while blindfolded
        if character_instance.blindfolded?
          return error_result("You can't see anything through your blindfold.")
        end

        # Parse "John's sword" or "John' sword"
        parts = text.split(/'s?\s+/, 2)
        return error_result("Invalid target format.\nType 'help look' for usage examples.") if parts.length != 2

        char_name = parts[0]
        item_name = parts[1]

        target_char = find_character_by_name(char_name)
        return not_found_error(char_name) unless target_char

        target_instance = find_character_instance(target_char)
        return not_found_error(char_name) unless target_instance

        item = find_item_on_character(target_instance, item_name)
        return error_result("#{char_name} doesn't have '#{item_name}'.") unless item

        look_at_item(item, owner: target_char)
      end

      def compound_target?(text)
        words = text.split
        return false unless words.length >= 2

        !find_character_by_name(words[0]).nil?
      end

      def look_at_compound_target(text)
        # Can't look at specific things while blindfolded
        if character_instance.blindfolded?
          return error_result("You can't see anything through your blindfold.")
        end

        words = text.split
        char_name = words[0]
        item_name = words[1..].join(' ')

        target_char = find_character_by_name(char_name)
        return not_found_error(char_name) unless target_char

        target_instance = find_character_instance(target_char)
        return not_found_error(char_name) unless target_instance

        # If item_name is empty, just look at the character
        if item_name.empty?
          return look_at_character(target_instance)
        end

        item = find_item_on_character(target_instance, item_name)

        if item
          look_at_item(item, owner: target_char)
        else
          # Just looking at the character
          look_at_character(target_instance)
        end
      end

      def look_at_target(target_name)
        # Can't look at specific things while blindfolded
        if character_instance.blindfolded?
          return error_result("You can't see anything through your blindfold.")
        end

        # Collect all possible matches
        matches = collect_possible_matches(target_name)

        case matches.length
        when 0
          not_found_error(target_name)
        when 1
          look_at_match(matches.first)
        else
          disambiguation_result(matches, target_name)
        end
      end

      def not_found_error(target_name)
        error_result(
          "You don't see '#{target_name}' here.\n" \
          "Type 'help look' for usage examples."
        )
      end

      def look_at_match(match)
        case match[:type]
        when :character
          instance = CharacterInstance.first(id: match[:id])
          look_at_character(instance)
        when :place
          place = Place.first(id: match[:id])
          look_at_place(place)
        when :decoration
          decoration = Decoration.first(id: match[:id])
          look_at_decoration(decoration)
        when :spatial_exit
          look_at_spatial_exit(match[:direction], match[:room_id])
        when :object
          obj = Item.first(id: match[:id])
          look_at_object(obj)
        when :feature
          feature = RoomFeature.first(id: match[:id])
          look_at_feature(feature)
        when :delve_monster
          monster = DelveMonster.first(id: match[:id])
          look_at_delve_monster(monster)
        else
          not_found_error(match[:label])
        end
      end

      def look_at_place(place)
        chars_here = place.characters_here(character_instance.reality_id, viewer: character_instance)
                         .exclude(id: character_instance.id)
                         .eager(:character)
                         .all

        place_data = {
          id: place.id,
          name: place.name,
          description: place.description,
          place_type: place.place_type,
          is_furniture: place.furniture?,
          characters: chars_here.map do |ci|
            {
              name: ci.character.display_name_for(character_instance),
              short_desc: ci.character.short_desc,
              profile_pic_url: ci.character.profile_pic_url
            }
          end
        }

        success_result(
          format_place_display(place_data),
          type: :message,
          structured: place_data.merge(display_type: :place),
          target: place.name
        )
      end

      def look_at_decoration(decoration)
        dec_data = {
          id: decoration.id,
          name: decoration.name,
          description: decoration.description,
          image_url: decoration.image_url,
          has_image: decoration.has_image?
        }

        success_result(
          format_decoration_display(dec_data),
          type: :message,
          structured: dec_data.merge(display_type: :decoration),
          target: decoration.name
        )
      end

      def look_at_item(item, owner: nil)
        item_data = {
          id: item.id,
          name: item.name,
          description: item.description,
          condition: item.condition,
          image_url: item.image_url,
          thumbnail_url: item.thumbnail_url,
          owner: owner&.full_name
        }

        success_result(
          format_item_display(item_data),
          type: :message,
          structured: item_data.merge(display_type: :item),
          object_id: item.id,
          target: item.name
        )
      end

      def look_at_object(object)
        look_at_item(object)
      end

      def look_at_spatial_exit(direction, room_id)
        to_room = Room[room_id]
        return error_result("That exit no longer exists.") unless to_room

        output = []
        output << "You look #{direction}:"
        output << "The exit leads #{direction} to #{to_room.name}."

        # Check for closed door features in that direction (own side)
        door_features = location.room_features_dataset
                                .where(direction: direction.to_s)
                                .where(feature_type: %w[door gate hatch])
                                .all

        # Also check inbound features (doors on the other room's side connecting here)
        opposite_dir = CanvasHelper.opposite_direction(direction.to_s)
        inbound_doors = RoomFeature.where(connected_room_id: location.id, direction: opposite_dir)
                                   .where(feature_type: %w[door gate hatch])
                                   .all

        all_doors = door_features + inbound_doors
        closed_door = all_doors.find { |d| !d.open? }
        output << "The door is closed." if closed_door

        exit_data = {
          direction: direction,
          to_room_name: to_room.name,
          to_room_id: to_room.id,
          exit_type: :spatial,
          closed: !closed_door.nil?
        }

        success_result(
          output.join("\n"),
          type: :message,
          structured: exit_data.merge(display_type: :exit),
          target: direction
        )
      end

      def look_at_feature(feature)
        output = []
        output << "You look at #{feature.name}:"

        if feature.description && !feature.description.empty?
          output << feature.description
        else
          output << "A #{feature.feature_type}."
        end

        if feature.connected_room && feature.allows_sight_through?
          output << ""
          output << "Through it, you can see into #{feature.connected_room.name}."
        end

        feature_data = {
          id: feature.id,
          name: feature.name,
          feature_type: feature.feature_type,
          description: feature.description
        }

        success_result(
          output.join("\n"),
          type: :message,
          structured: feature_data.merge(display_type: :feature),
          target: feature.name,
          feature_id: feature.id
        )
      end

      def look_at_delve_monster(monster)
        return not_found_error('monster') unless monster

        lines = []
        lines << "<h3>#{monster.display_name}</h3>"
        lines << ""
        lines << "A #{monster.difficulty_text} #{monster.monster_type}."
        lines << "HP: #{monster.hp}/#{monster.max_hp}"

        monster_data = {
          id: monster.id,
          name: monster.display_name,
          monster_type: monster.monster_type,
          difficulty: monster.difficulty_text,
          hp: monster.hp,
          max_hp: monster.max_hp
        }

        success_result(
          lines.join("\n"),
          type: :message,
          structured: monster_data.merge(display_type: :delve_monster),
          target: monster.display_name
        )
      end

      def disambiguation_result(matches, query)
        disambiguation_data = {
          query: query,
          matches: matches.map.with_index(1) { |m, i| m.merge(key: i.to_s) },
          callback_command: 'look'
        }

        success_result(
          "Which '#{query}' do you mean?",
          type: :message,
          structured: disambiguation_data.merge(display_type: :quickmenu)
        )
      end

      def collect_possible_matches(name)
        matches = []
        name_lower = name.downcase

        # Characters - match by forename, full name, short description, or display name
        location.characters_here(character_instance.reality_id, viewer: character_instance)
                .exclude(id: character_instance.id)
                .eager(:character).all.each do |ci|
          char = ci.character
          char_forename = strip_html(char.forename)&.downcase
          char_name = strip_html(char.full_name)
          char_name_lower = char_name&.downcase
          char_desc = strip_html(char.short_desc)&.downcase

          # Also match by display name (what the viewer actually sees in the room)
          display_name = char.display_name_for(character_instance)
          display_name_lower = strip_html(display_name)&.downcase

          # Match by: forename prefix, forename exact, full name contains, short_desc contains, or display name contains
          forename_match = char_forename && (
            char_forename == name_lower ||                    # Exact forename
            char_forename.start_with?(name_lower) ||          # Forename prefix (e.g., "test" matches "Testbot")
            (name_lower.length >= 3 && char_forename.include?(name_lower))  # Forename contains
          )
          name_match = char_name_lower&.include?(name_lower)
          desc_match = char_desc&.include?(name_lower)
          display_match = display_name_lower&.include?(name_lower)

          if forename_match || name_match || desc_match || display_match
            matches << { type: :character, id: ci.id, label: display_name || char_name }
          end
        end

        # Places
        location.visible_places.all.each do |p|
          place_name = strip_html(p.name)
          if place_name&.downcase&.include?(name_lower)
            matches << { type: :place, id: p.id, label: place_name }
          end
        end

        # Decorations
        location.visible_decorations.all.each do |d|
          dec_name = strip_html(d.name)
          if dec_name&.downcase&.include?(name_lower)
            matches << { type: :decoration, id: d.id, label: dec_name }
          end
        end

        # Spatial Exits (show all visible exits, including blocked ones like closed doors)
        RoomAdjacencyService.visible_exits(location).each do |direction, rooms|
          rooms.each do |room|
            exit_direction = direction.to_s
            exit_room_name = room.name
            if exit_direction.downcase == name_lower || exit_room_name&.downcase&.include?(name_lower)
              matches << {
                type: :spatial_exit,
                direction: exit_direction,
                room_id: room.id,
                label: "#{exit_direction.capitalize} (#{exit_room_name})"
              }
            end
          end
        end

        # Objects on ground
        location.objects_here.all.each do |obj|
          obj_name = strip_html(obj.name)
          if obj_name&.downcase&.include?(name_lower)
            matches << { type: :object, id: obj.id, label: obj_name }
          end
        end

        # Room features (including inbound from adjacent rooms)
        RoomFeature.visible_from(location).each do |feature|
          feature_name = strip_html(feature.name)
          feature_type = strip_html(feature.feature_type)
          if feature_name&.downcase&.include?(name_lower) ||
             feature_type&.downcase == name_lower
            matches << { type: :feature, id: feature.id, label: feature_name || feature_type }
          end
        end

        # Delve monsters in current room
        if defined?(DelveParticipant)
          dp = DelveParticipant.first(character_instance_id: character_instance.id, status: 'active')
          if dp
            delve = dp.delve
            room = dp.current_room
            if delve && room
              delve.monsters_in_room(room).each do |monster|
                monster_name = monster.display_name&.downcase
                monster_type = monster.monster_type&.downcase
                if monster_name&.include?(name_lower) || monster_type&.include?(name_lower)
                  matches << { type: :delve_monster, id: monster.id, label: monster.display_name }
                end
              end
            end
          end
        end

        matches
      end

      # Note: strip_html is now available via StringHelper (included in base command)

      def find_character_instance(character)
        CharacterInstance.first(
          character_id: character.id,
          current_room_id: location.id
        )
      end

      def find_item_on_character(char_instance, item_name)
        return nil unless char_instance

        worn = char_instance.worn_items.all
        held = char_instance.held_items.all

        # Include holstered weapons from visible (non-concealed) holsters
        visible_holsters = worn.select { |i| i.pattern&.holster? && !i.concealed? }
        holstered_weapons = visible_holsters.flat_map { |h| h.holstered_weapons.to_a }

        visible_items = worn + held + holstered_weapons

        TargetResolverService.resolve(
          query: item_name,
          candidates: visible_items,
          name_field: :name
        )
      end

      def format_character_display(data)
        lines = []
        lines << "You look at #{data[:name]}:"
        lines << data[:short_desc] if data[:short_desc] && !data[:short_desc].to_s.empty?
        lines << data[:intro] if data[:intro] && !data[:intro].to_s.empty?

        if data[:descriptions]&.any?
          lines << ""
          data[:descriptions].each do |desc|
            lines << desc[:content] if desc[:content_type] == 'text'
          end
        end

        if data[:clothing]&.any?
          lines << ""
          lines << "Wearing:"
          data[:clothing].each do |item|
            display = item[:display_name] || item[:name]
            lines << "  - #{display}"
          end
        end

        if data[:held_items]&.any?
          lines << ""
          lines << "Holding:"
          data[:held_items].each { |item| lines << "  #{item[:name]} (#{item[:hand]})" }
        end

        lines.join("\n")
      end

      def format_place_display(data)
        lines = []
        lines << "You look at #{data[:name]}:"
        lines << data[:description] if data[:description] && !data[:description].to_s.empty?

        if data[:characters]&.any?
          lines << ""
          lines << "Here:"
          data[:characters].each do |c|
            parts = [c[:name]]
            parts << c[:short_desc] if c[:short_desc] && !c[:name_is_short_desc]
            parts << c[:status_line] if c[:status_line]
            lines << "  #{parts.join(', ')}"
          end
        else
          lines << "Nobody is here."
        end

        lines.join("\n")
      end

      def format_decoration_display(data)
        lines = []
        lines << "You look at #{data[:name]}:"
        lines << data[:description] if data[:description] && !data[:description].to_s.empty?
        lines.join("\n")
      end

      def format_item_display(data)
        lines = []
        prefix = data[:owner] ? "You look at #{data[:owner]}'s #{data[:name]}:" : "You look at #{data[:name]}:"
        lines << prefix
        lines << data[:description] if data[:description] && !data[:description].to_s.empty?
        lines << "Condition: #{data[:condition]}" if data[:condition] && !data[:condition].to_s.empty?
        lines.join("\n")
      end

    end
  end
end

# Auto-register the command when the file is loaded
Commands::Base::Registry.register(Commands::Navigation::Look)
