# frozen_string_literal: true

# Transforms game output for accessibility mode.
# Converts visual/spatial elements to linear, screen-reader-friendly text.
class AccessibilityOutputService
  class << self
    # Transform output based on type
    # @param type [Symbol] :room, :combat, :character, :message, etc.
    # @param data [Hash] the output data
    # @param viewer [CharacterInstance] the viewing character
    # @return [Hash] transformed data with :accessible_text key
    def transform(type, data, viewer)
      return data unless viewer&.accessibility_mode?

      case type
      when :room
        transform_room(data, viewer)
      when :combat
        transform_combat(data, viewer)
      when :character
        transform_character(data, viewer)
      when :message
        transform_message(data, viewer)
      else
        data
      end
    end

    # Transform room output for accessibility mode
    # @param room_data [Hash] room display data from RoomDisplayService
    # @param viewer [CharacterInstance]
    # @return [Hash] with :accessible_text
    def transform_room(room_data, viewer)
      return room_data unless viewer&.accessibility_mode?

      lines = []

      # Location header
      room = room_data[:room] || {}
      lines << "Location: #{room[:name]}"
      lines << ""

      # Description
      description = room[:description] || room[:short_description]
      lines << description if description && !description.to_s.strip.empty?
      lines << ""

      # Time and weather if present
      if room[:time_of_day] || room[:weather]
        env_parts = []
        env_parts << room[:time_of_day] if room[:time_of_day]
        env_parts << room[:weather] if room[:weather]
        lines << "Environment: #{env_parts.join(', ')}" if env_parts.any?
        lines << ""
      end

      # Characters present
      all_chars = collect_all_characters(room_data)
      if all_chars.any?
        lines << "People here (#{all_chars.length}):"
        all_chars.each do |char|
          char_line = "  - #{char[:name]}"
          char_line += " (#{char[:roomtitle]})" if char[:roomtitle] && !char[:roomtitle].to_s.strip.empty?
          char_line += " [NPC]" if char[:is_npc]
          lines << char_line
          lines << "    #{char[:short_desc]}" if char[:short_desc] && !char[:short_desc].to_s.strip.empty?
        end
        lines << ""
      end

      # Places/furniture with occupants
      if room_data[:places]&.any?
        lines << "Places:"
        room_data[:places].each do |place|
          occupant_count = place[:characters]&.length || 0
          place_line = "  - #{place[:name]}"
          place_line += " (#{occupant_count} #{occupant_count == 1 ? 'person' : 'people'})" if occupant_count > 0
          lines << place_line
          if place[:description] && !place[:description].to_s.strip.empty?
            desc_text = place[:description].to_s
            desc_text = desc_text[0, 97] + '...' if desc_text.length > 100
            lines << "    #{desc_text}"
          end
        end
        lines << ""
      end

      # Decorations
      if room_data[:decorations]&.any?
        lines << "Decorations:"
        room_data[:decorations].each do |dec|
          lines << "  - #{dec[:name]}"
        end
        lines << ""
      end

      # Objects
      if room_data[:objects]&.any?
        lines << "Objects:"
        room_data[:objects].each do |obj|
          obj_line = "  - #{obj[:name]}"
          obj_line += " (x#{obj[:quantity]})" if obj[:quantity] && obj[:quantity] > 1
          lines << obj_line
        end
        lines << ""
      end

      # Exits
      if room_data[:exits]&.any?
        exit_list = room_data[:exits].map do |e|
          exit_str = e[:direction] || e[:display_name]
          exit_str += " (locked)" if e[:locked]
          exit_str
        end
        lines << "Exits: #{exit_list.join(', ')}"
      end

      room_data.merge(
        accessible_text: lines.join("\n").strip,
        format: :accessible
      )
    end

    # Transform combat/battle map data for accessibility
    # @param combat_data [Hash] combat state data
    # @param viewer [CharacterInstance]
    # @return [Hash] with :accessible_text
    def transform_combat(combat_data, viewer)
      return combat_data unless viewer&.accessibility_mode?

      lines = []
      lines << "<h4>Combat Status</h4>"

      if combat_data[:round_number]
        lines << "Round: #{combat_data[:round_number]}"
      end
      if combat_data[:status]
        lines << "Status: #{combat_data[:status]}"
      end
      lines << ""

      # List all combatants
      if combat_data[:participants]&.any?
        lines << "Combatants:"
        combat_data[:participants].each do |p|
          lines << build_combatant_line(p, combat_data, viewer)
        end
        lines << ""
      end

      # Current character's options
      your_participant = combat_data[:participants]&.find { |p| p[:is_current_character] }
      if your_participant && !your_participant[:input_complete]
        lines << "Your turn. Available actions:"
        lines << "  1. Attack - attack <target>"
        lines << "  2. Defend - defend"
        lines << "  3. Move - move towards/away <target>"
        lines << "  4. Use ability - ability <name>"
        lines << "  5. Pass - pass"
      end

      combat_data.merge(
        accessible_text: lines.join("\n"),
        format: :accessible,
        quick_commands: build_combat_quick_commands(combat_data)
      )
    end

    # Transform character display for accessibility
    # @param char_data [Hash] character display data
    # @param viewer [CharacterInstance]
    # @return [Hash] with :accessible_text
    def transform_character(char_data, viewer)
      return char_data unless viewer&.accessibility_mode?

      lines = []
      lines << "<h4>#{char_data[:name]}</h4>"
      lines << ""

      if char_data[:short_desc] && !char_data[:short_desc].to_s.strip.empty?
        lines << char_data[:short_desc]
        lines << ""
      end

      if char_data[:intro] && !char_data[:intro].to_s.strip.empty?
        lines << "Appearance:"
        lines << char_data[:intro]
        lines << ""
      end

      # Descriptions
      if char_data[:descriptions]&.any?
        char_data[:descriptions].each do |desc|
          type_name = desc[:type].to_s.gsub('_', ' ').split.map(&:capitalize).join(' ')
          lines << "#{type_name}:"
          lines << desc[:content]
          lines << ""
        end
      end

      # Clothing
      if char_data[:clothing]&.any?
        lines << "Wearing:"
        char_data[:clothing].each do |item|
          display = item[:display_name] || item[:name]
          item_line = "  - #{display}"
          item_line += " (torn)" if item[:torn].to_i.positive?
          lines << item_line
        end
        lines << ""
      end

      # Held items
      if char_data[:held_items]&.any?
        lines << "Holding:"
        char_data[:held_items].each do |item|
          lines << "  - #{item[:name]} (#{item[:hand]})"
        end
        lines << ""
      end

      char_data.merge(
        accessible_text: lines.join("\n").strip,
        format: :accessible
      )
    end

    # Transform message for accessibility
    # Generally messages are already text, but we can enhance them
    # @param msg_data [Hash] message data
    # @param viewer [CharacterInstance]
    # @return [Hash] with :accessible_text
    def transform_message(msg_data, viewer)
      return msg_data unless viewer&.accessibility_mode?

      # Messages are typically already text-based
      # Just ensure we have a clean text version
      text = msg_data[:message] || msg_data[:content] || ''

      # Strip any HTML if present
      clean_text = text.gsub(/<[^>]+>/, ' ').gsub(/\s+/, ' ').strip

      msg_data.merge(
        accessible_text: clean_text,
        format: :accessible
      )
    end

    private

    # Collect all characters from room data (ungrouped + at places)
    # @param room_data [Hash]
    # @return [Array<Hash>]
    def collect_all_characters(room_data)
      all = []
      all.concat(room_data[:characters_ungrouped] || [])
      (room_data[:places] || []).each do |place|
        all.concat(place[:characters] || [])
      end
      # Fallback to :characters if others empty
      all.concat(room_data[:characters] || []) if all.empty?
      all
    end

    # Build a single combatant line for accessible combat display
    # @param participant [Hash]
    # @param combat_data [Hash]
    # @param viewer [CharacterInstance]
    # @return [String]
    def build_combatant_line(participant, combat_data, viewer)
      name = participant[:name] || 'Unknown'
      hp = "#{participant[:current_hp]}/#{participant[:max_hp]}HP"

      # Calculate distance from viewer
      viewer_p = combat_data[:participants]&.find { |p| p[:is_current_character] }
      distance = if viewer_p && participant[:hex_x] && viewer_p[:hex_x]
                   dx = (participant[:hex_x] - viewer_p[:hex_x]).abs
                   dy = ((participant[:hex_y] || 0) - (viewer_p[:hex_y] || 0)).abs
                   "#{dx + dy}hex"
                 else
                   "?hex"
                 end

      relationship = participant[:relationship] || 'neutral'
      status = participant[:is_knocked_out] ? " [KO]" : ""

      "  - #{name}: #{hp}, #{distance}, #{relationship}#{status}"
    end

    # Build quick combat commands for accessibility
    # @param combat_data [Hash]
    # @return [Array<Hash>]
    def build_combat_quick_commands(combat_data)
      commands = []

      # List enemies command
      enemies = combat_data[:participants]&.select { |p| p[:relationship] == 'enemy' }
      if enemies&.any?
        commands << { key: '1', label: 'List enemies', command: 'combat enemies' }
      end

      # List allies command
      allies = combat_data[:participants]&.select { |p| p[:relationship] == 'ally' }
      if allies&.any?
        commands << { key: '2', label: 'List allies', command: 'combat allies' }
      end

      # Recommend target
      commands << { key: '3', label: 'Recommend target', command: 'combat recommend' }

      commands
    end
  end
end
