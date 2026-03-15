# frozen_string_literal: true

require 'rack/utils'
require 'securerandom'

module OutputHelper
  # Detect output mode from env (set by middleware or passed through request_env)
  def agent_mode?
    # Trust the middleware to set this flag - do not call request methods
    # as commands don't have access to Roda's request object
    return false unless respond_to?(:env) && env.is_a?(Hash)

    env['firefly.agent_mode'] == true ||
      env['HTTP_X_OUTPUT_MODE'] == 'agent' ||
      env['PATH_INFO']&.start_with?('/api/agent')
  end

  # Render response based on mode
  def render_output(type:, data:, **extras)
    if agent_mode?
      render_agent_output(type, data, extras)
    else
      render_webclient_output(type, data, extras)
    end
  end

  # ====== QUICKMENU SUPPORT ======

  # Create a quickmenu for the character
  # @param char_instance [CharacterInstance] the character receiving the menu
  # @param prompt [String] the prompt/question for the menu
  # @param options [Array<Hash>] array of options, each with :key, :label, :description
  # @param context [Hash] optional context data for the callback
  # @return [Hash] result with interaction_id
  def create_quickmenu(char_instance, prompt, options, context: {})
    interaction_id = SecureRandom.uuid

    menu_data = {
      type: 'quickmenu',
      interaction_id: interaction_id,
      prompt: prompt,
      options: options.map.with_index do |opt, idx|
        o = {
          key: opt[:key] || (idx + 1).to_s,
          label: opt[:label] || opt[:name],
          description: opt[:description]
        }
        o[:html_label] = opt[:html_label] if opt[:html_label]
        o
      end,
      context: context,
      created_at: Time.now.iso8601
    }

    # Store in Redis with 10 minute TTL
    store_agent_interaction(char_instance, interaction_id, menu_data)

    # Return structured data for both agent and webclient
    # Webclient will render client-side, with HTML fallback
    {
      success: true,
      type: :quickmenu,
      display_type: :quickmenu,
      message_type: 'quickmenu',
      output_category: :info,
      interaction_id: interaction_id,
      data: {
        interaction_id: interaction_id,
        prompt: prompt,
        options: menu_data[:options]
      },
      # HTML fallback for older clients
      message: agent_mode? ? nil : format_quickmenu_html(prompt, menu_data[:options]),
      requires_response: true,
      timestamp: Time.now.iso8601
    }.compact
  end

  # ====== POP-OUT FORM SUPPORT ======

  # Create a pop-out form for the character
  # @param char_instance [CharacterInstance] the character receiving the form
  # @param title [String] form title
  # @param fields [Array<Hash>] array of field definitions
  # @param context [Hash] optional context data for the callback
  # @return [Hash] result with interaction_id
  def create_form(char_instance, title, fields, context: {})
    interaction_id = SecureRandom.uuid

    form_data = {
      type: 'form',
      interaction_id: interaction_id,
      title: title,
      fields: fields.map do |field|
        {
          name: field[:name],
          label: field[:label] || field[:name].to_s.capitalize,
          type: field[:type] || 'text',
          required: field[:required] || false,
          default: field[:default],
          options: field[:options], # For select/radio fields
          placeholder: field[:placeholder],
          min: field[:min],
          max: field[:max],
          pattern: field[:pattern]
        }.compact
      end,
      context: context,
      created_at: Time.now.iso8601
    }

    # Store in Redis with 10 minute TTL
    store_agent_interaction(char_instance, interaction_id, form_data)

    # Return structured data for both agent and webclient
    # Webclient will render client-side, with HTML fallback
    {
      success: true,
      type: :form,
      display_type: :form,
      message_type: 'form',
      interaction_id: interaction_id,
      data: {
        interaction_id: interaction_id,
        title: title,
        fields: form_data[:fields]
      },
      # HTML fallback for older clients
      message: agent_mode? ? nil : format_form_html(title, form_data[:fields]),
      requires_response: true,
      timestamp: Time.now.iso8601
    }.compact
  end

  private

  def render_agent_output(type, data, extras)
    formatted = format_output(type, data, html: false)
    result = {
      type: type,
      structured: data,
      timestamp: Time.now.iso8601
    }
    result[:description] = formatted if formatted
    # Include target_panel if provided
    result[:target_panel] = extras[:target_panel] if extras[:target_panel]
    result.merge(extras)
  end

  def render_webclient_output(type, data, extras)
    formatted = format_output(type, data, html: true)
    result = {
      type: type,
      message_type: type.to_s,
      timestamp: Time.now.iso8601
    }
    # Only set message if formatted is non-empty (empty string is truthy in Ruby)
    result[:message] = formatted unless formatted.nil? || formatted.empty?
    # Include target_panel if provided
    result[:target_panel] = extras[:target_panel] if extras[:target_panel]
    result.merge(extras)
  end

  # Unified formatter for both agent and webclient modes (DRY)
  def format_output(type, data, html: false)
    case type
    when :room
      format_room_output(data, html: html)
    when :message
      format_message_output(data, html: html)
    when :error
      format_error_output(data, html: html)
    when :action, :combat, :movement
      format_action_output(data, html: html)
    when :quickmenu
      format_quickmenu_output(data, html: html)
    when :form
      format_form_output(data, html: html)
    else
      # Return nil for unknown types to preserve original message
      nil
    end
  end

  def format_room_output(data, html:)
    room = data[:room] || {}
    name = html ? escape_html(room[:name]) : room[:name]
    # Don't escape description - it may contain intentional HTML from room builders
    desc = room[:description]
    desc = desc&.gsub("\n", '<br>') if html

    # Collect all characters from both ungrouped and places
    all_characters = []
    all_characters.concat(data[:characters_ungrouped] || [])
    (data[:places] || []).each do |place|
      all_characters.concat(place[:characters] || [])
    end
    # Fallback to old :characters key for backwards compatibility
    all_characters.concat(data[:characters] || []) if all_characters.empty?

    if html
      # Order: Name → Description → Weather → Exits → Characters → Items
      output = "<h3>#{name}</h3><p>#{desc}</p>"
      if data[:weather] && data[:weather][:prose]
        weather_text = data[:weather][:prefix] ? "#{escape_html(data[:weather][:prefix])}: #{escape_html(data[:weather][:prose])}" : escape_html(data[:weather][:prose])
        output += "<p class='obs-weather'>#{weather_text}</p>"
      end
      if data[:exits]&.any?
        exits = data[:exits].map do |e|
          dir = e[:direction]
          room_name = e[:to_room_styled_name] || escape_html(e[:to_room_name] || dir)
          arrow = e[:direction_arrow] || ''
          dist = e[:distance] || 0
          tag = dist.positive? && !arrow.empty? ? "<sup>#{dist}#{arrow}</sup>" : ''
          locked_class = e[:locked] ? ' obs-exit-locked' : ''
          "<a href='#' class='obs-exit#{locked_class}' onclick=\"navigateToExit(event, '#{escape_html(dir)}')\">#{room_name}#{tag}</a>"
        end.join(', ')
        output += "<p class='obs-exits'>Exits: #{exits}</p>"
      end
      output += format_room_thumbnails_html(data[:thumbnails]) if data[:thumbnails]&.any?
      if all_characters.any?
        chars = all_characters.map { |c| escape_html(c[:name]) }.join(', ')
        output += "<p>Also here: #{chars}</p>"
      end
      output
    else
      # Order: Name → Description → Weather → Exits → Thumbnails → Characters → Items
      output = "**#{name}**\n#{desc}\n"
      if data[:weather] && data[:weather][:prose]
        weather_text = data[:weather][:prefix] ? "#{data[:weather][:prefix]}: #{data[:weather][:prose]}" : data[:weather][:prose]
        output += "\n#{weather_text}"
      end
      if data[:exits]&.any?
        exits = data[:exits].map do |e|
          room_name = e[:to_room_name] || e[:direction]
          tag = e[:distance_tag]
          tag ? "#{room_name} (#{tag})" : room_name
        end.join(', ')
        output += "\nExits: #{exits}"
      end
      if data[:thumbnails]&.any?
        urls = data[:thumbnails].map { |t| t[:url] }.join(', ')
        output += "\nImages: #{urls}"
      end
      if all_characters.any?
        chars = all_characters.map { |c| c[:name] }.join(', ')
        output += "\nCharacters: #{chars}"
      end
      output
    end
  end

  def format_room_thumbnails_html(thumbnails)
    return '' if thumbnails.nil? || thumbnails.empty?

    html = "<div class='obs-thumbnails'>"
    thumbnails.each do |thumb|
      url = escape_html(thumb[:url])
      alt = escape_html(thumb[:alt] || 'Room image')
      html += "<a href='#{url}' target='_blank' rel='noopener'>"
      html += "<img src='#{url}' class='obs-thumb' alt='#{alt}' title='#{alt}'>"
      html += "</a>"
    end
    html += "</div>"
    html
  end

  def format_message_output(data, html:)
    content = data[:content].to_s
    sender = data[:sender]

    case data[:type]
    when 'say'
      verb = data[:verb] || 'says'
      text = "#{sender} #{verb}, \"#{content}\""
      html ? escape_html(text) : text
    when 'emote', 'subtle', 'private_emote', 'semote'
      # Emotes/subtle/private emotes/semotes come pre-formatted with HTML styling — don't escape
      content
    else
      html ? escape_html(content) : content
    end
  end

  def format_error_output(data, html:)
    message = data[:message].to_s
    if html
      "<span class='error'>#{escape_html(message)}</span>"
    else
      message
    end
  end

  def format_action_output(data, html:)
    # Action types don't override the message - they use the original
    # Just return nil to preserve the original message from success_result
    nil
  end

  def escape_html(text)
    CGI.escapeHTML(text.to_s)
  end

  # ====== QUICKMENU FORMATTERS ======

  def format_quickmenu_output(data, html:)
    prompt = data[:prompt]
    options = data[:options] || []

    if html
      format_quickmenu_html(prompt, options)
    else
      # Agent-friendly text format
      lines = ["**#{prompt}**", ""]
      options.each do |opt|
        line = "  [#{opt[:key]}] #{opt[:label]}"
        line += " - #{opt[:description]}" if opt[:description]
        lines << line
      end
      lines << ""
      lines << "Respond with: respond_to_interaction(interaction_id, selected_key)"
      lines.join("\n")
    end
  end

  def format_quickmenu_html(prompt, options)
    html = "<div class='quickmenu'>"
    html += "<p style='margin:0 0 0.4em;color:#87ceeb'>#{escape_html(prompt)}</p>"
    html += "<ol style='margin:0;padding-left:1.4em'>"
    options.each do |opt|
      next if opt[:key] == 'q' # skip cancel in HTML view
      label = opt[:html_label] || escape_html(opt[:label])
      html += "<li style='margin:0.1em 0'>#{label}"
      html += " <span style='opacity:0.5'>#{escape_html(opt[:description])}</span>" if opt[:description]
      html += "</li>"
    end
    html += "</ol></div>"
    html
  end

  # ====== FORM FORMATTERS ======

  def format_form_output(data, html:)
    title = data[:title]
    fields = data[:fields] || []

    if html
      format_form_html(title, fields)
    else
      # Agent-friendly text format
      lines = ["**#{title}**", ""]
      lines << "Fields:"
      fields.each do |field|
        req = field[:required] ? " (required)" : ""
        line = "  - #{field[:name]} (#{field[:type]})#{req}: #{field[:label]}"
        line += " [default: #{field[:default]}]" if field[:default]
        if field[:options]
          opts = field[:options].map { |o| o.is_a?(Hash) ? o[:label] : o }.join(', ')
          line += " [options: #{opts}]"
        end
        lines << line
      end
      lines << ""
      lines << "Respond with: respond_to_interaction(interaction_id, {field_name: value, ...})"
      lines.join("\n")
    end
  end

  def format_form_html(title, fields)
    html = "<div class='form-popup'>"
    html += "<h3>#{escape_html(title)}</h3>"
    html += "<form class='agent-form'>"
    fields.each do |field|
      html += "<div class='form-field'>"
      html += "<label for='#{escape_html(field[:name])}'>#{escape_html(field[:label])}"
      html += "<span class='required'>*</span>" if field[:required]
      html += "</label>"
      html += render_form_field(field)
      html += "</div>"
    end
    html += "<div class='form-actions'>"
    html += "<button type='submit'>Submit</button>"
    html += "<button type='button' class='cancel'>Cancel</button>"
    html += "</div></form></div>"
    html
  end

  def render_form_field(field)
    name = escape_html(field[:name])
    case field[:type]
    when 'textarea'
      "<textarea name='#{name}' placeholder='#{escape_html(field[:placeholder])}'" \
      "#{' required' if field[:required]}>#{escape_html(field[:default])}</textarea>"
    when 'select'
      html = "<select name='#{name}'#{' required' if field[:required]}>"
      (field[:options] || []).each do |opt|
        val = opt.is_a?(Hash) ? opt[:value] : opt
        label = opt.is_a?(Hash) ? opt[:label] : opt
        sel = field[:default] == val ? ' selected' : ''
        html += "<option value='#{escape_html(val)}'#{sel}>#{escape_html(label)}</option>"
      end
      html += "</select>"
      html
    when 'number'
      "<input type='number' name='#{name}' value='#{escape_html(field[:default])}' " \
      "min='#{field[:min]}' max='#{field[:max]}'#{' required' if field[:required]} />"
    when 'checkbox'
      checked = field[:default] ? ' checked' : ''
      "<input type='checkbox' name='#{name}'#{checked} />"
    else
      "<input type='#{field[:type] || 'text'}' name='#{name}' " \
      "value='#{escape_html(field[:default])}' placeholder='#{escape_html(field[:placeholder])}'" \
      "#{' required' if field[:required]} />"
    end
  end

  # ====== INTERACTION STORAGE ======

  # Store an agent interaction in Redis
  def store_agent_interaction(char_instance, interaction_id, data)
    OutputHelper.store_agent_interaction(char_instance, interaction_id, data)
  end

  # Class method version for external callers
  def self.store_agent_interaction(char_instance, interaction_id, data)
    return unless defined?(REDIS_POOL)

    REDIS_POOL.with do |redis|
      key = "agent_interaction:#{char_instance.id}:#{interaction_id}"
      redis.setex(key, 600, JSON.generate(data)) # 10 minute TTL

      # Also add to the character's pending interactions list
      list_key = "agent_pending:#{char_instance.id}"
      redis.sadd(list_key, interaction_id)
      redis.expire(list_key, 600)
    end
  rescue StandardError => e
    warn "[OutputHelper] Failed to store interaction: #{e.message}"
  end

  # Get a pending interaction
  def self.get_agent_interaction(char_instance_id, interaction_id)
    return nil unless defined?(REDIS_POOL)

    REDIS_POOL.with do |redis|
      key = "agent_interaction:#{char_instance_id}:#{interaction_id}"
      data = redis.get(key)
      return nil unless data

      JSON.parse(data, symbolize_names: true)
    end
  rescue StandardError => e
    warn "[OutputHelper] Failed to get agent interaction: #{e.message}"
    nil
  end

  # Get all pending interactions for a character
  def self.get_pending_interactions(char_instance_id)
    return [] unless defined?(REDIS_POOL)

    REDIS_POOL.with do |redis|
      list_key = "agent_pending:#{char_instance_id}"
      interaction_ids = redis.smembers(list_key)

      interaction_ids.filter_map do |iid|
        key = "agent_interaction:#{char_instance_id}:#{iid}"
        data = redis.get(key)
        next unless data

        JSON.parse(data, symbolize_names: true)
      end
    end
  rescue StandardError => e
    warn "[OutputHelper] Failed to get pending interactions: #{e.message}"
    []
  end

  # Clear all pending interactions for a character
  def self.clear_pending_interactions(char_instance_id)
    return unless defined?(REDIS_POOL)

    REDIS_POOL.with do |redis|
      list_key = "agent_pending:#{char_instance_id}"
      interaction_ids = redis.smembers(list_key)

      interaction_ids.each do |iid|
        redis.del("agent_interaction:#{char_instance_id}:#{iid}")
      end
      redis.del(list_key)
    end
  rescue StandardError => e
    warn "[OutputHelper] Failed to clear pending interactions: #{e.message}"
  end

  # Complete an interaction (remove from pending)
  def self.complete_interaction(char_instance_id, interaction_id)
    return unless defined?(REDIS_POOL)

    REDIS_POOL.with do |redis|
      # Remove from pending list
      list_key = "agent_pending:#{char_instance_id}"
      redis.srem(list_key, interaction_id)

      # Delete the interaction data
      key = "agent_interaction:#{char_instance_id}:#{interaction_id}"
      redis.del(key)
    end
  rescue StandardError => e
    warn "[OutputHelper] Failed to complete interaction: #{e.message}"
  end
end
