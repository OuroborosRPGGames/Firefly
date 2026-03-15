# frozen_string_literal: true

# FormHandlerService - Processes form submissions from interactions
#
# Usage:
#   result = FormHandlerService.process(char_instance, context, form_data)
#
class FormHandlerService
  extend QueryHelper

  class << self
    # Process a form submission based on context
    # @param char_instance [CharacterInstance] the character submitting the form
    # @param context [Hash] the form context (command, ids, etc.)
    # @param form_data [Hash] the submitted field values
    # @return [Hash] result with :success, :message/:error
    def process(char_instance, context, form_data)
      command = context[:command] || context['command']

      case command
      when 'consent'
        process_consent_form(char_instance, context, form_data)
      when 'event'
        process_event_form(char_instance, context, form_data)
      when 'edit_room'
        process_edit_room_form(char_instance, context, form_data)
      when 'create_item'
        process_create_item_form(char_instance, context, form_data)
      when 'send_memo'
        process_send_memo_form(char_instance, context, form_data)
      when 'build_city'
        process_build_city_form(char_instance, context, form_data)
      when 'accessibility'
        process_accessibility_form(char_instance, context, form_data)
      when 'discord'
        process_discord_form(char_instance, context, form_data)
      when 'ticket'
        process_ticket_form(char_instance, context, form_data)
      when 'permissions'
        process_permissions_form(char_instance, context, form_data)
      when 'timeline'
        process_timeline_form(char_instance, context, form_data)
      when 'aesthete'
        process_aesthete_form(char_instance, context, form_data)
      when 'customize'
        process_customize_form(char_instance, context, form_data)
      else
        dispatch_command_form_handler(char_instance, command, context, form_data)
      end
    rescue StandardError => e
      warn "[FormHandlerService] Error processing form: #{e.message}"
      { success: false, error: 'Failed to process form submission.' }
    end

    private

    def dispatch_command_form_handler(char_instance, command_name, context, form_data)
      command_class = Commands::Base::Registry.find_by_context(command_name)
      unless command_class
        return { success: false, error: "Unknown form command: #{command_name}" }
      end

      command = command_class.new(char_instance)
      unless command.respond_to?(:handle_form_response, true)
        return { success: false, error: "Unknown form command: #{command_name}" }
      end

      command.send(:handle_form_response, form_data, context)
    end


    # Process the customize form - updates character appearance fields
    def process_customize_form(char_instance, _context, form_data)
      character = char_instance.character
      updates = []
      errors = []

      # Description (short_desc)
      desc_raw = form_data['description'] || form_data[:description]
      if desc_raw
        desc = desc_raw.is_a?(String) ? desc_raw.strip : nil
        if desc && !desc.empty?
          max = GameConfig::Forms::MAX_LENGTHS[:description]
          if desc.length > max
            errors << "Description too long (max #{max} characters)"
          else
            character.update(short_desc: desc)
            updates << 'Description updated'
          end
        end
      end

      # Roomtitle
      rt_raw = form_data['roomtitle'] || form_data[:roomtitle]
      if rt_raw
        rt = rt_raw.is_a?(String) ? rt_raw.strip : nil
        if rt && !rt.empty?
          max = GameConfig::Forms::MAX_LENGTHS[:roomtitle]
          if rt.length > max
            errors << "Room title too long (max #{max} characters)"
          else
            char_instance.update(roomtitle: rt)
            updates << 'Room title updated'
          end
        end
      end

      # Handle (display name - stripped HTML must match character full name)
      handle_raw = form_data['handle'] || form_data[:handle]
      if handle_raw
        handle = handle_raw.is_a?(String) ? handle_raw.strip : nil
        if handle && !handle.empty?
          stripped = strip_html(handle)
          if stripped.downcase == character.full_name.downcase
            character.update(nickname: handle)
            updates << 'Display name updated'
          else
            errors << 'Handle must match your name'
          end
        end
      end

      # Picture URL
      pic_raw = form_data['picture'] || form_data[:picture]
      if pic_raw
        pic = pic_raw.is_a?(String) ? pic_raw.strip : nil
        if pic && !pic.empty?
          max = GameConfig::Forms::MAX_LENGTHS[:picture_url]
          if !pic.match?(%r{^https?://})
            errors << 'Picture URL must start with http:// or https://'
          elsif pic.length > max
            errors << 'Picture URL too long'
          else
            character.update(picture_url: pic)
            updates << 'Profile picture updated'
          end
        end
      end

      # Speech color
      color_raw = form_data['color'] || form_data[:color]
      if color_raw
        color = color_raw.is_a?(String) ? color_raw.strip : nil
        if color
          if %w[clear none reset].include?(color.downcase)
            character.update(distinctive_color: nil)
            updates << 'Speech color cleared'
          else
            normalized = color.start_with?('#') ? color : "##{color}"
            if normalized.match?(/^#[0-9A-Fa-f]{3}([0-9A-Fa-f]{3})?$/)
              normalized = "##{normalized[1..].upcase}"
              character.update(distinctive_color: normalized)
              updates << 'Speech color updated'
            else
              errors << 'Invalid color format (use #RGB or #RRGGBB)'
            end
          end
        end
      end

      if errors.any? && updates.empty?
        { success: false, error: errors.join('. ') }
      elsif errors.any?
        { success: true, message: updates.join('. '), error: errors.join('. ') }
      elsif updates.any?
        { success: true, message: updates.join('. ') }
      else
        { success: true, message: 'No changes made.' }
      end
    end

    # Process the consent form submission
    def process_consent_form(char_instance, context, form_data)
      character = char_instance.character
      user = character&.user
      return { success: false, error: 'You must be logged in to change consent settings.' } unless user

      restriction_codes = context[:restriction_codes] || context['restriction_codes'] || []
      generic_perm = UserPermission.generic_for(user)
      consents = (generic_perm.content_consents || {}).dup

      updates = []

      restriction_codes.each do |code|
        # Get the submitted value (checkbox returns true/false or string "true"/"false")
        raw_value = form_data[code] || form_data[code.to_s]

        # Normalize the value - checkboxes can come as true/false/string/"on"/nil
        consenting = normalize_checkbox(raw_value)

        restriction = ContentRestriction.first(code: code.upcase, is_active: true)
        next unless restriction

        old_value = generic_perm.content_consent_for(restriction.code)
        new_value = consenting ? 'yes' : 'no'
        next if old_value == new_value

        consents[restriction.code] = new_value
        updates << "#{restriction.name}: #{consenting ? 'ON' : 'OFF'}"
      end

      if updates.empty?
        { success: true, message: "No changes to consent settings." }
      else
        generic_perm.update(content_consents: consents)
        { success: true, message: "Updated consent settings:\n#{updates.join("\n")}" }
      end
    end

    # Process the event form submission
    def process_event_form(char_instance, context, form_data)
      character = char_instance.character
      room_id = context[:room_id] || context['room_id']
      organizer_id = context[:organizer_id] || context['organizer_id']

      # Get form values
      name = form_data['name'] || form_data[:name]
      description = form_data['description'] || form_data[:description]
      event_type = form_data['event_type'] || form_data[:event_type] || 'party'
      is_public = normalize_checkbox(form_data['is_public'] || form_data[:is_public])
      start_delay = (form_data['start_delay'] || form_data[:start_delay] || '60').to_i

      # Validate required fields
      if StringHelper.blank?(name)
        return { success: false, error: "Event name is required." }
      end

      name = name.to_s.strip
      max_event_name = GameConfig::Forms::MAX_LENGTHS[:event_name]
      if name.length > max_event_name
        return { success: false, error: "Event name too long (max #{max_event_name} characters)." }
      end

      # Get the room
      room = Room[room_id]
      unless room
        return { success: false, error: "Invalid location." }
      end

      # Calculate start time
      starts_at = Time.now + (start_delay * 60)

      # Create the event
      event = Event.create(
        name: name,
        description: description&.strip,
        event_type: event_type,
        is_public: is_public,
        starts_at: starts_at,
        room_id: room.id,
        location_id: room.location_id,
        organizer_id: character.id,
        status: 'scheduled',
        logs_visible_to: is_public ? 'public' : 'attendees'
      )

      # Auto-add creator as attendee
      event.add_attendee(character, rsvp: 'yes')

      time_desc = if start_delay == 0
                    "right now"
                  elsif start_delay < 60
                    "in #{start_delay} minutes"
                  elsif start_delay == 60
                    "in 1 hour"
                  elsif start_delay < 1440
                    "in #{start_delay / 60} hours"
                  else
                    "tomorrow"
                  end

      {
        success: true,
        message: "Event '#{name}' created!\nLocation: #{room.name}\nStarting: #{time_desc}\n\nUse 'event info #{name}' to see details or 'start event' when ready."
      }
    rescue StandardError => e
      warn "[FormHandlerService] Event creation error: #{e.message}"
      { success: false, error: "Failed to create event." }
    end

    # Normalize checkbox values from forms (can be true/false/string/"on"/nil)
    def normalize_checkbox(value)
      return false if value.nil?
      return value if value == true || value == false
      return true if value.to_s.downcase.match?(/^(true|on|yes|1)$/)

      false
    end

    def strip_html(text)
      text.gsub(/<[^>]+>/, '').gsub(/&lt;/, '<').gsub(/&gt;/, '>').gsub(/&amp;/, '&').gsub(/&quot;/, '"')
    end

    # Process the edit room form submission
    def process_edit_room_form(char_instance, context, form_data)
      room_id = context[:room_id] || context['room_id']
      room = Room[room_id]

      unless room
        return { success: false, error: 'Room no longer exists.' }
      end

      # Check ownership (via outer_room for apartments)
      outer_room = room.outer_room
      unless outer_room.owned_by?(char_instance.character)
        return { success: false, error: "You don't own this room." }
      end

      # Validate name
      new_name = (form_data['name'] || form_data[:name])&.strip
      if new_name.nil? || new_name.empty?
        return { success: false, error: 'Room name is required.' }
      end

      max_lengths = GameConfig::Forms::MAX_LENGTHS
      if new_name.length > max_lengths[:room_name]
        return { success: false, error: "Room name must be #{max_lengths[:room_name]} characters or less." }
      end

      # Validate descriptions
      short_desc = (form_data['short_description'] || form_data[:short_description])&.strip || ''
      long_desc = (form_data['long_description'] || form_data[:long_description])&.strip || ''

      if short_desc.length > max_lengths[:room_short_desc]
        return { success: false, error: "Short description must be #{max_lengths[:room_short_desc]} characters or less." }
      end

      if long_desc.length > max_lengths[:room_long_desc]
        return { success: false, error: "Long description must be #{max_lengths[:room_long_desc]} characters or less." }
      end

      # Validate room type
      room_type = (form_data['room_type'] || form_data[:room_type])&.strip&.downcase || 'standard'
      unless Room::VALID_ROOM_TYPES.include?(room_type)
        room_type = 'standard'
      end

      # Validate background URL
      bg_url = (form_data['background_url'] || form_data[:background_url])&.strip
      if bg_url && !bg_url.empty?
        unless bg_url.match?(%r{^https?://})
          return { success: false, error: 'Background URL must start with http:// or https://' }
        end
        if bg_url.length > max_lengths[:background_url]
          return { success: false, error: "Background URL too long (max #{max_lengths[:background_url]} characters)." }
        end
      else
        bg_url = nil
      end

      # Update room
      room.update(
        name: new_name,
        short_description: short_desc.empty? ? nil : short_desc,
        long_description: long_desc.empty? ? nil : long_desc,
        room_type: room_type,
        default_background_url: bg_url
      )

      { success: true, message: 'Room updated successfully.' }
    rescue StandardError => e
      warn "[FormHandlerService] Edit room error: #{e.message}"
      { success: false, error: 'Failed to update room.' }
    end

    # Process the create item form submission
    def process_create_item_form(char_instance, context, form_data)
      room_id = context[:room_id] || context['room_id']
      room = Room[room_id]

      unless room
        return { success: false, error: 'Room no longer exists.' }
      end

      # Check staff permission
      character = char_instance.character
      unless character.staff? || character.admin?
        return { success: false, error: 'Creating items requires staff access.' }
      end

      # Validate name
      name = (form_data['name'] || form_data[:name])&.strip
      if name.nil? || name.empty?
        return { success: false, error: 'Item name is required.' }
      end

      max_lengths = GameConfig::Forms::MAX_LENGTHS
      if name.length > max_lengths[:item_name]
        return { success: false, error: "Item name must be #{max_lengths[:item_name]} characters or less." }
      end

      # Validate description
      description = (form_data['description'] || form_data[:description])&.strip || ''
      if description.length > max_lengths[:item_description]
        return { success: false, error: "Description must be #{max_lengths[:item_description]} characters or less." }
      end

      # Validate quantity
      quantity = (form_data['quantity'] || form_data[:quantity] || '1').to_i
      quantity = 1 if quantity < 1
      quantity = 999 if quantity > 999

      # Validate condition
      condition = (form_data['condition'] || form_data[:condition])&.strip || 'good'
      unless %w[excellent good fair poor broken].include?(condition)
        condition = 'good'
      end

      # Parse item type for properties
      item_type = (form_data['item_type'] || form_data[:item_type])&.strip || 'generic'
      properties = build_item_properties(item_type)

      # Validate image URL
      image_url = (form_data['image_url'] || form_data[:image_url])&.strip
      if image_url && !image_url.empty?
        unless image_url.match?(%r{^https?://})
          return { success: false, error: 'Image URL must start with http:// or https://' }
        end
        if image_url.length > max_lengths[:url]
          return { success: false, error: "Image URL too long (max #{max_lengths[:url]} characters)." }
        end
      else
        image_url = nil
      end

      # Create the item
      Item.create(
        name: name,
        description: description.empty? ? nil : description,
        room_id: room.id,
        quantity: quantity,
        condition: condition,
        properties: properties,
        image_url: image_url,
        item_type: item_type,
        is_clothing: item_type == 'clothing',
        is_jewelry: item_type == 'jewelry'
      )

      message = "Created: #{name}"
      message += " (x#{quantity})" if quantity > 1

      { success: true, message: message }
    rescue StandardError => e
      warn "[FormHandlerService] Create item error: #{e.message}"
      { success: false, error: 'Failed to create item.' }
    end

    def build_item_properties(item_type)
      properties = {}

      case item_type
      when 'weapon'
        properties['damage_dice'] = '1d6'
        properties['weapon_type'] = 'melee'
      when 'armor'
        properties['armor_value'] = 1
        properties['armor_type'] = 'light'
      when 'container'
        properties['capacity'] = 10
        properties['container'] = true
      when 'food'
        properties['consume_type'] = 'food'
        properties['consume_time'] = 5
      when 'drink'
        properties['consume_type'] = 'drink'
        properties['consume_time'] = 3
      when 'key'
        properties['key_id'] = SecureRandom.hex(8)
      end

      properties
    end

    # Process the send memo form submission
    def process_send_memo_form(char_instance, context, form_data)
      character = char_instance.character

      # Validate recipient
      recipient_name = (form_data['recipient'] || form_data[:recipient])&.strip
      if recipient_name.nil? || recipient_name.empty?
        return { success: false, error: 'Recipient is required.' }
      end

      recipient = find_character_by_name(recipient_name)
      unless recipient
        return { success: false, error: "No character found named '#{recipient_name}'." }
      end

      if recipient.id == character.id
        return { success: false, error: "You can't send a memo to yourself." }
      end

      # Validate subject
      max_lengths = GameConfig::Forms::MAX_LENGTHS
      subject = (form_data['subject'] || form_data[:subject])&.strip
      if subject.nil? || subject.empty?
        return { success: false, error: 'Subject is required.' }
      end

      if subject.length > max_lengths[:memo_subject]
        return { success: false, error: "Subject too long (max #{max_lengths[:memo_subject]} characters)." }
      end

      # Validate body
      body = (form_data['body'] || form_data[:body])&.strip
      if body.nil? || body.empty?
        return { success: false, error: 'Message body is required.' }
      end

      if body.length > max_lengths[:memo_body]
        return { success: false, error: "Message too long (max #{max_lengths[:memo_body].to_s.gsub(/(\d)(?=(\d{3})+$)/, '\\1,')} characters)." }
      end

      # Create the memo
      memo = Memo.create(
        sender_id: character.id,
        recipient_id: recipient.id,
        subject: subject,
        content: body
      )

      # Send notification
      recipient_instance = recipient.character_instances_dataset.where(online: true).first
      NotificationService.notify_memo(recipient_instance, memo) if defined?(NotificationService) && recipient_instance

      { success: true, message: "Memo sent to #{recipient.full_name}.\nSubject: #{subject}" }
    rescue StandardError => e
      warn "[FormHandlerService] Send memo error: #{e.message}"
      { success: false, error: 'Failed to send memo.' }
    end

    def find_character_by_name(name)
      name_lower = name.downcase

      # Exact match on forename first
      exact = Character.where(ilike_match(:forename, name_lower)).first
      return exact if exact

      # Try full name match (database query instead of loading all)
      exact = Character.where(ilike_concat_match([:forename, :surname], name_lower)).first
      return exact if exact

      # Prefix match (min 3 chars)
      return nil if name_lower.length < 3

      # Prefix match on full name (database query)
      Character.where(ilike_concat_prefix([:forename, :surname], name_lower)).first
    end

    # Process build city form submission
    def process_build_city_form(char_instance, context, form_data)
      location_id = context[:location_id] || context['location_id']
      current_location = Location[location_id]

      unless current_location
        return { success: false, error: 'Location no longer exists.' }
      end

      # Check permission
      character = char_instance.character
      unless CityBuilderService.can_build?(character, :build_city)
        return { success: false, error: 'You must be staff with building permission.' }
      end

      # Parse form data
      params = {
        city_name: (form_data['city_name'] || form_data[:city_name])&.strip,
        horizontal_streets: (form_data['horizontal_streets'] || form_data[:horizontal_streets]).to_i,
        vertical_streets: (form_data['vertical_streets'] || form_data[:vertical_streets]).to_i,
        max_building_height: (form_data['max_building_height'] || form_data[:max_building_height]).to_i
      }

      longitude = form_data['longitude'] || form_data[:longitude]
      latitude = form_data['latitude'] || form_data[:latitude]
      params[:longitude] = longitude.to_f if longitude && !longitude.to_s.empty?
      params[:latitude] = latitude.to_f if latitude && !latitude.to_s.empty?

      use_llm = form_data['use_llm_names'] || form_data[:use_llm_names]
      params[:use_llm_names] = use_llm == 'true' if use_llm && use_llm != 'auto'

      # Validate parameters
      params[:horizontal_streets] ||= 10
      params[:vertical_streets] ||= 10
      params[:max_building_height] ||= 200

      if params[:horizontal_streets] < 2 || params[:horizontal_streets] > 50
        return { success: false, error: 'Streets must be between 2 and 50.' }
      end

      if params[:vertical_streets] < 2 || params[:vertical_streets] > 50
        return { success: false, error: 'Avenues must be between 2 and 50.' }
      end

      # Build the city
      result = CityBuilderService.build_city(
        location: current_location,
        params: params,
        character: character
      )

      unless result[:success]
        return { success: false, error: "Failed to build city: #{result[:error]}" }
      end

      # Calculate stats
      street_count = result[:streets].length
      avenue_count = result[:avenues].length
      intersection_count = result[:intersections].length

      # Find origin intersection
      origin = result[:intersections].find { |i| i.grid_x == 0 && i.grid_y == 0 }
      if origin
        char_instance.update(current_room_id: origin.id, x: 0.0, y: 0.0, z: 0.0)
      end

      city_name = params[:city_name] || current_location.name

      {
        success: true,
        message: "You have built #{city_name}!\n\n" \
                 "Created:\n" \
                 "  - #{street_count} streets (E-W)\n" \
                 "  - #{avenue_count} avenues (N-S)\n" \
                 "  - #{intersection_count} intersections"
      }
    rescue StandardError => e
      warn "[FormHandlerService] Build city error: #{e.message}"
      { success: false, error: 'Failed to build city.' }
    end

    # Process accessibility settings form
    def process_accessibility_form(char_instance, _context, form_data)
      user = char_instance.character&.user
      return { success: false, error: 'You must be logged in to change accessibility settings.' } unless user

      # Apply accessibility settings
      user.configure_accessibility!(
        mode: normalize_checkbox(form_data['accessibility_mode']),
        screen_reader: normalize_checkbox(form_data['screen_reader']),
        high_contrast: normalize_checkbox(form_data['high_contrast']),
        reduced_effects: normalize_checkbox(form_data['reduced_effects']),
        pause_on_typing: normalize_checkbox(form_data['pause_on_typing']),
        auto_resume: normalize_checkbox(form_data['auto_resume'])
      )

      # Handle TTS speed separately
      speed = (form_data['tts_speed'] || form_data[:tts_speed])&.to_f
      if speed && speed >= 0.25 && speed <= 4.0
        user.set_narrator_voice!(
          type: user.narrator_settings[:voice_type],
          pitch: user.narrator_settings[:voice_pitch],
          speed: speed
        )
      end

      { success: true, message: 'Accessibility settings updated.' }
    rescue StandardError => e
      warn "[FormHandlerService] Accessibility form error: #{e.message}"
      { success: false, error: 'Failed to update accessibility settings.' }
    end

    # Process discord settings form
    def process_discord_form(char_instance, _context, form_data)
      user = char_instance.character&.user
      return { success: false, error: 'You must be logged in to change Discord settings.' } unless user

      # Handle webhook URL
      webhook_url = (form_data['webhook_url'] || form_data[:webhook_url])&.strip
      if webhook_url && !webhook_url.empty?
        unless DiscordWebhookService.valid_webhook_url?(webhook_url)
          return { success: false, error: "Invalid webhook URL. It should look like:\nhttps://discord.com/api/webhooks/123456/abcdef..." }
        end
        user.update(discord_webhook_url: webhook_url)
      elsif normalize_checkbox(form_data['clear_webhook'])
        user.update(discord_webhook_url: nil)
      end

      # Handle Discord handle
      username_input = form_data['username'] || form_data[:username] ||
                       form_data['handle'] || form_data[:handle] ||
                       form_data['discord_username'] || form_data[:discord_username]
      username = username_input&.strip
      if username && !username.empty?
        normalized_handle = User.normalize_discord_handle(username)
        return { success: false, error: User::DISCORD_HANDLE_ERROR } unless normalized_handle

        user.update(discord_username: normalized_handle)
      elsif normalize_checkbox(form_data['clear_username']) || normalize_checkbox(form_data['clear_handle'])
        user.update(discord_username: nil)
      end

      # Apply notification toggles
      user.update(
        discord_notify_offline: normalize_checkbox(form_data['notify_offline']),
        discord_notify_online: normalize_checkbox(form_data['notify_online']),
        discord_notify_memos: normalize_checkbox(form_data['notify_memos']),
        discord_notify_pms: normalize_checkbox(form_data['notify_pms']),
        discord_notify_mentions: normalize_checkbox(form_data['notify_mentions'])
      )

      { success: true, message: 'Discord settings updated.' }
    rescue StandardError => e
      warn "[FormHandlerService] Discord form error: #{e.message}"
      { success: false, error: 'Failed to update Discord settings.' }
    end

    # Process ticket form submission
    def process_ticket_form(char_instance, _context, form_data)
      character = char_instance.character
      return { success: false, error: 'You must be logged in to submit a ticket.' } unless character

      category = (form_data['category'] || form_data[:category])&.strip
      subject = (form_data['subject'] || form_data[:subject])&.strip
      content = (form_data['content'] || form_data[:content])&.strip

      # Validate category
      unless Ticket::CATEGORIES.include?(category)
        return { success: false, error: 'Invalid category.' }
      end

      # Validate subject
      max_lengths = GameConfig::Forms::MAX_LENGTHS
      if subject.nil? || subject.empty?
        return { success: false, error: 'Subject is required.' }
      end

      if subject.length > max_lengths[:ticket_subject]
        return { success: false, error: "Subject too long (max #{max_lengths[:ticket_subject]} characters)." }
      end

      # Validate content
      if content.nil? || content.empty?
        return { success: false, error: 'Description is required.' }
      end

      if content.length > max_lengths[:ticket_content]
        return { success: false, error: "Description too long (max #{max_lengths[:ticket_content].to_s.gsub(/(\d)(?=(\d{3})+$)/, '\\1,')} characters)." }
      end

      # Build game context
      context_lines = []
      context_lines << "Room: #{char_instance.current_room.name} (ID: #{char_instance.current_room_id})" if char_instance.current_room
      context_lines << "Character: #{character.full_name}"
      context_lines << "Time: #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}"
      game_context = context_lines.join("\n")

      # Create ticket
      ticket = Ticket.create(
        user_id: character.user_id,
        category: category,
        subject: subject,
        content: content,
        status: 'open',
        room_id: char_instance.current_room_id,
        game_context: game_context
      )

      # Alert staff
      StaffAlertService.broadcast_to_staff(
        "[TICKET] New #{category.upcase} ticket ##{ticket.id} from #{character.user.username}: #{subject}"
      )

      {
        success: true,
        message: "Ticket ##{ticket.id} submitted. Staff will review it shortly.\nUse 'tickets' to view your open tickets."
      }
    rescue StandardError => e
      warn "[FormHandlerService] Ticket form error: #{e.message}"
      { success: false, error: 'Failed to submit ticket.' }
    end

    # Process user permissions form submission
    def process_permissions_form(char_instance, context, form_data)
      user = char_instance.character&.user
      return { success: false, error: 'You must be logged in to change permissions.' } unless user

      permission_id = context[:permission_id] || context['permission_id']
      perm = UserPermission[permission_id] if permission_id
      unless perm
        return { success: false, error: 'Permission record not found.' }
      end

      # Verify ownership
      unless perm.user_id == user.id
        return { success: false, error: 'You do not own this permission record.' }
      end

      updates = {}
      changes = []

      # Process visibility
      visibility = (form_data['visibility'] || form_data[:visibility])&.strip
      if visibility && UserPermission::VISIBILITY_VALUES.include?(visibility)
        if visibility != perm.visibility
          updates[:visibility] = visibility
          changes << "Visibility: #{visibility}"
        end
      end

      # Process OOC messaging
      ooc = (form_data['ooc_messaging'] || form_data[:ooc_messaging])&.strip
      if ooc && UserPermission::OOC_VALUES.include?(ooc)
        if ooc != perm.ooc_messaging
          updates[:ooc_messaging] = ooc
          changes << "OOC Messaging: #{ooc}"
        end
      end

      # Process IC messaging
      ic = (form_data['ic_messaging'] || form_data[:ic_messaging])&.strip
      if ic && UserPermission::IC_VALUES.include?(ic)
        if ic != perm.ic_messaging
          updates[:ic_messaging] = ic
          changes << "IC Messaging: #{ic}"
        end
      end

      # Process lead/follow
      lead_follow = (form_data['lead_follow'] || form_data[:lead_follow])&.strip
      if lead_follow && UserPermission::LEAD_FOLLOW_VALUES.include?(lead_follow)
        if lead_follow != perm.lead_follow
          updates[:lead_follow] = lead_follow
          changes << "Lead/Follow: #{lead_follow}"
        end
      end

      # Process dress/style
      dress_style = (form_data['dress_style'] || form_data[:dress_style])&.strip
      if dress_style && UserPermission::DRESS_STYLE_VALUES.include?(dress_style)
        if dress_style != perm.dress_style
          updates[:dress_style] = dress_style
          changes << "Dress/Style: #{dress_style}"
        end
      end

      # Process channel muting
      channel_muting = (form_data['channel_muting'] || form_data[:channel_muting])&.strip
      if channel_muting && UserPermission::CHANNEL_VALUES.include?(channel_muting)
        if channel_muting != perm.channel_muting
          updates[:channel_muting] = channel_muting
          changes << "Channel Muting: #{channel_muting}"
        end
      end

      # Process group preference
      group_pref = (form_data['group_preference'] || form_data[:group_preference])&.strip
      if group_pref && UserPermission::GROUP_VALUES.include?(group_pref)
        if group_pref != perm.group_preference
          updates[:group_preference] = group_pref
          changes << "Group Preference: #{group_pref}"
        end
      end

      # Process content consent fields
      content_updates = {}
      allowed_content_values = perm.generic? ? %w[yes no] : %w[yes no generic]
      form_data.each do |key, value|
        str_key = key.to_s
        next unless str_key.start_with?('content_')

        code = UserPermission.normalize_content_code(str_key.sub('content_', ''))
        next unless allowed_content_values.include?(value.to_s)

        current = perm.content_consent_for(code)
        if value.to_s != current
          content_updates[code] = value.to_s
          changes << "Content (#{code}): #{value}"
        end
      end

      if content_updates.any?
        updates[:content_consents] = (perm.content_consents || {}).merge(content_updates)
      end

      if updates.empty?
        { success: true, message: 'No changes made to permissions.' }
      else
        perm.update(updates)
        target_name = perm.generic? ? 'Generic' : perm.display_character&.full_name || 'User'
        { success: true, message: "#{target_name} permissions updated:\n#{changes.join("\n")}" }
      end
    rescue StandardError => e
      warn "[FormHandlerService] Permissions form error: #{e.message}"
      { success: false, error: 'Failed to update permissions.' }
    end

    # Process the timeline form submission
    # @param char_instance [CharacterInstance] the character submitting the form
    # @param context [Hash] the form context (stage determines create vs historical)
    # @param form_data [Hash] the submitted field values
    # @return [Hash] result with :success, :message/:error
    def process_timeline_form(char_instance, context, form_data)
      stage = context[:stage] || context['stage']

      case stage
      when 'create_snapshot'
        process_create_snapshot_form(char_instance, form_data)
      when 'historical_entry'
        process_historical_timeline_form(char_instance, form_data)
      else
        { success: false, error: 'Unknown timeline form stage.' }
      end
    end

    # Process create snapshot form
    def process_create_snapshot_form(char_instance, form_data)
      # Don't allow snapshots in past timelines
      if char_instance.in_past_timeline?
        return { success: false, error: "You cannot create snapshots while in a past timeline." }
      end

      name = (form_data['name'] || form_data[:name])&.strip
      if name.nil? || name.empty?
        return { success: false, error: 'Snapshot name is required.' }
      end

      max_lengths = GameConfig::Forms::MAX_LENGTHS
      if name.length > max_lengths[:snapshot_name]
        return { success: false, error: "Snapshot name too long (max #{max_lengths[:snapshot_name]} characters)." }
      end

      description = (form_data['description'] || form_data[:description])&.strip
      if description && description.length > max_lengths[:snapshot_description]
        return { success: false, error: "Description too long (max #{max_lengths[:snapshot_description]} characters)." }
      end

      # Check for duplicate name
      existing = CharacterSnapshot.first(character_id: char_instance.character.id, name: name)
      if existing
        return { success: false, error: "You already have a snapshot named '#{name}'." }
      end

      # Create the snapshot
      snapshot = TimelineService.create_snapshot(
        char_instance,
        name: name,
        description: description
      )

      lines = []
      lines << "Created snapshot '#{snapshot.name}'."
      lines << ""
      lines << "This snapshot captures:"
      lines << "- Your current room: #{char_instance.current_room&.name}"
      lines << "- Characters present when created"
      lines << ""
      lines << "Anyone who was in the room can enter this timeline."
      lines << "Type 'timeline' and select 'Enter Timeline' to visit this snapshot."

      { success: true, message: lines.join("\n"), data: { snapshot_id: snapshot.id } }
    rescue StandardError => e
      warn "[FormHandlerService] Create snapshot error: #{e.message}"
      { success: false, error: 'Failed to create snapshot.' }
    end

    # Process historical timeline entry form
    def process_historical_timeline_form(char_instance, form_data)
      # Don't allow entering timelines from past timelines
      if char_instance.in_past_timeline?
        return { success: false, error: "You're already in a past timeline. Leave first." }
      end

      year = (form_data['year'] || form_data[:year])&.to_i
      if year.nil? || year <= 0
        return { success: false, error: 'Year is required.' }
      end

      if year > 9999
        return { success: false, error: 'Year must be 9999 or less.' }
      end

      zone_name = (form_data['zone'] || form_data[:zone])&.strip
      if zone_name.nil? || zone_name.empty?
        return { success: false, error: 'Zone name is required.' }
      end

      # Find the zone in the character's current world to avoid cross-world ambiguity
      current_location = char_instance.current_room&.location
      current_world_id = current_location&.world_id || current_location&.zone&.world_id
      zone_scope = Zone.where(Sequel.ilike(:name, "%#{zone_name}%"))
      zone_scope = zone_scope.where(world_id: current_world_id) if current_world_id
      zone = zone_scope.first
      unless zone
        return { success: false, error: "Zone '#{zone_name}' not found." }
      end

      character = char_instance.character
      instance = TimelineService.enter_historical_timeline(character, year: year, zone: zone)

      lines = []
      lines << "You've entered the year #{year} in #{zone.name}."
      lines << ""
      lines << "<h4>Timeline Restrictions</h4>"
      lines << "- Deaths are disabled"
      lines << "- Prisoner mechanics are disabled"
      lines << "- XP gain is disabled"
      lines << "- Room modifications are disabled"
      lines << ""
      lines << "Actions here won't affect your present self."
      lines << "Type 'timeline' and select 'Leave Timeline' to return to the present."
      lines << ""
      lines << "Others entering this same year/zone will be able to interact with you."

      { success: true, message: lines.join("\n"), data: { instance_id: instance.id } }
    rescue TimelineService::NotAllowedError => e
      { success: false, error: e.message }
    rescue StandardError => e
      warn "[FormHandlerService] Historical timeline error: #{e.message}"
      { success: false, error: 'Failed to enter historical timeline.' }
    end

    # Process the aesthete form submission (tattoo, style, makeup)
    # @param char_instance [CharacterInstance] the character performing the action
    # @param context [Hash] the form context (aesthete_type, target_character_id, description_id)
    # @param form_data [Hash] the submitted field values
    # @return [Hash] result with :success, :message/:error
    def process_aesthete_form(char_instance, context, form_data)
      aesthete_type = context[:aesthete_type] || context['aesthete_type']
      target_character_id = context[:target_character_id] || context['target_character_id']
      description_id = context[:description_id] || context['description_id']

      unless CharacterDefaultDescription::DESCRIPTION_TYPES.include?(aesthete_type)
        return { success: false, error: "Invalid aesthete type: #{aesthete_type}" }
      end

      # Find the target character
      target_character = Character[target_character_id]
      unless target_character
        return { success: false, error: 'Target character not found.' }
      end

      performer = char_instance.character

      # Check permission (using dress_style permission)
      if target_character.id != performer.id
        unless has_dress_style_permission?(performer, target_character)
          return { success: false, error: "You don't have permission to modify #{target_character.full_name}'s appearance." }
        end
      end

      # Extract form data
      content = (form_data['content'] || form_data[:content])&.strip
      image_url = (form_data['image_url'] || form_data[:image_url])&.strip
      concealed = normalize_checkbox(form_data['concealed_by_clothing'] || form_data[:concealed_by_clothing])
      display_order = (form_data['display_order'] || form_data[:display_order] || '0').to_i
      body_position_ids = extract_position_ids(form_data)

      # Validate content
      if content.nil? || content.empty?
        return { success: false, error: 'Description content is required.' }
      end

      if content.length > 10_000
        return { success: false, error: 'Description too long (max 10,000 characters).' }
      end

      # Validate image URL if provided
      max_url_length = GameConfig::Forms::MAX_LENGTHS[:url]
      if image_url && !image_url.empty?
        unless image_url.match?(%r{^https?://})
          return { success: false, error: 'Image URL must start with http:// or https://' }
        end
        if image_url.length > max_url_length
          return { success: false, error: "Image URL too long (max #{max_url_length} characters)." }
        end
      else
        image_url = nil
      end

      # Validate body positions based on type
      validation_result = validate_positions_for_type(aesthete_type, body_position_ids)
      return validation_result unless validation_result[:success]

      positions = validation_result[:positions]

      # Create or update the description
      if description_id
        update_aesthete_description(target_character, description_id, aesthete_type, content,
                                    image_url, concealed, display_order, positions, performer)
      else
        create_aesthete_description(target_character, aesthete_type, content, image_url,
                                    concealed, display_order, positions, performer, char_instance)
      end
    rescue StandardError => e
      warn "[FormHandlerService] Aesthete form error: #{e.message}"
      { success: false, error: 'Failed to save description.' }
    end

    # Check if performer has dress_style permission for target
    def has_dress_style_permission?(performer, target)
      # Check for explicit permission
      perm = UserPermission.first(
        user_id: target.user_id,
        character_id: performer.id
      )

      if perm
        return perm.dress_style == 'yes'
      end

      # Check generic permissions
      generic = UserPermission.first(
        user_id: target.user_id,
        character_id: nil
      )

      if generic
        return generic.dress_style == 'yes'
      end

      # Default to no permission
      false
    end

    # Extract position IDs from form data
    def extract_position_ids(form_data)
      # Can come as array or comma-separated string
      positions = form_data['body_position_ids'] || form_data[:body_position_ids]

      return [] if positions.nil?

      if positions.is_a?(Array)
        positions.map(&:to_i).reject(&:zero?)
      elsif positions.is_a?(String)
        positions.split(',').map(&:to_i).reject(&:zero?)
      else
        []
      end
    end

    # Validate positions are valid for the given aesthetic type
    def validate_positions_for_type(aesthete_type, position_ids)
      if position_ids.empty?
        return { success: false, error: 'At least one body position must be selected.' }
      end

      positions = BodyPosition.where(id: position_ids).all
      if positions.empty?
        return { success: false, error: 'No valid body positions found.' }
      end

      valid_ids = CharacterDefaultDescription.valid_position_ids_for_type(aesthete_type)
      invalid = positions.reject { |p| valid_ids.include?(p.id) }

      unless invalid.empty?
        invalid_labels = invalid.map { |p| p.label.tr('_', ' ').split.map(&:capitalize).join(' ') }.join(', ')

        case aesthete_type
        when 'makeup'
          return { success: false, error: "Makeup can only be applied to face positions. Invalid: #{invalid_labels}" }
        when 'hairstyle'
          return { success: false, error: "Hairstyle can only be applied to scalp. Invalid: #{invalid_labels}" }
        end
      end

      { success: true, positions: positions }
    end

    # Create a new aesthete description
    def create_aesthete_description(target_character, aesthete_type, content, image_url,
                                    concealed, display_order, positions, performer, char_instance)
      DB.transaction do
        # Create the default description on the Character
        desc = CharacterDefaultDescription.create(
          character_id: target_character.id,
          body_position_id: positions.first&.id, # Legacy single position
          content: content,
          image_url: image_url,
          concealed_by_clothing: concealed,
          display_order: display_order,
          description_type: aesthete_type,
          active: true
        )

        # Add positions to join table for multi-position support
        positions.each do |pos|
          CharacterDescriptionPosition.create(
            character_default_description_id: desc.id,
            body_position_id: pos.id
          )
        end

        # Sync to target's current instance (if they're logged in)
        target_instance = CharacterInstance.where(character_id: target_character.id, online: true).first
        DescriptionCopyService.sync_single(target_character, target_instance, desc.id) if target_instance

        type_label = aesthete_type_label(aesthete_type)
        position_labels = positions.map { |p| p.label.tr('_', ' ').split.map(&:capitalize).join(' ') }.join(', ')

        if performer.id == target_character.id
          message = "You've added a new #{type_label} on your #{position_labels}."
        else
          message = "You've given #{target_character.full_name} a new #{type_label} on their #{position_labels}."
        end

        { success: true, message: message, data: { description_id: desc.id } }
      end
    end

    # Update an existing aesthete description
    def update_aesthete_description(target_character, description_id, aesthete_type, content,
                                    image_url, concealed, display_order, positions, performer)
      desc = CharacterDefaultDescription.first(id: description_id, character_id: target_character.id)
      unless desc
        return { success: false, error: 'Description not found.' }
      end

      DB.transaction do
        desc.update(
          content: content,
          image_url: image_url,
          concealed_by_clothing: concealed,
          display_order: display_order,
          description_type: aesthete_type
        )

        # Update positions in join table
        CharacterDescriptionPosition.where(character_default_description_id: desc.id).delete
        positions.each do |pos|
          CharacterDescriptionPosition.create(
            character_default_description_id: desc.id,
            body_position_id: pos.id
          )
        end

        # Also update legacy body_position_id
        desc.update(body_position_id: positions.first&.id)

        # Sync to target's current instance (if they're logged in)
        target_instance = CharacterInstance.where(character_id: target_character.id, online: true).first
        DescriptionCopyService.sync_single(target_character, target_instance, desc.id) if target_instance

        type_label = aesthete_type_label(aesthete_type)

        if performer.id == target_character.id
          message = "You've updated your #{type_label}."
        else
          message = "You've updated #{target_character.full_name}'s #{type_label}."
        end

        { success: true, message: message }
      end
    end

    # Human-readable label for aesthete type
    def aesthete_type_label(type)
      case type
      when 'tattoo' then 'tattoo'
      when 'makeup' then 'makeup'
      when 'hairstyle' then 'hairstyle'
      else 'description'
      end
    end
  end
end
