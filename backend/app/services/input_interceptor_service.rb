# frozen_string_literal: true

# InputInterceptorService - Pre-processes input before command routing
#
# Handles shortcuts that bypass normal command lookup:
# - Quickmenu shortcuts: typing "1", "2", etc. when a quickmenu is pending
# - Activity context-aware commands (e.g., "status" -> "activity status")
#
# Usage:
#   result = InputInterceptorService.intercept(char_instance, input)
#   if result
#     # Return the result directly - input was handled
#   else
#     # Pass through to normal command processing
#   end
#
#   rewritten = InputInterceptorService.rewrite_for_context(char_instance, input)
#   # Returns modified input string (e.g., "status" -> "activity status")
#
class InputInterceptorService
  extend StringHelper

  # Activity subcommands that should work without the "activity" prefix
  ACTIVITY_SUBCOMMANDS = %w[
    status stat info
    choose pick select
    recover rest
    effort willpower wp
    ready done
    vote
    heal
    continue
    assess
    action
    persuade
    leave quit exit
  ].freeze

  class << self
    include PersonalizedBroadcastConcern

    # Intercept input before command processing
    # @param char_instance [CharacterInstance] the character
    # @param input [String] the raw input
    # @return [Hash, nil] result hash if intercepted, nil to pass through
    def intercept(char_instance, input)
      return nil if blank?(input)

      cleaned = input.to_s.strip

      # Try quickmenu shortcut first (highest priority)
      quickmenu_result = try_quickmenu_shortcut(char_instance, cleaned)
      return quickmenu_result if quickmenu_result

      # Try activity shortcut (e.g., just typing "2" for choose 2)
      activity_result = try_activity_shortcut(char_instance, cleaned)
      return activity_result if activity_result

      # No interception - pass through to normal command processing
      nil
    end

    # Rewrite input for context-aware command routing
    # Returns modified input string if rewriting applies, otherwise original input
    # @param char_instance [CharacterInstance]
    # @param input [String]
    # @return [String]
    def rewrite_for_context(char_instance, input)
      return input if blank?(input)

      cleaned = input.to_s.strip

      # Check if user is in an activity
      if in_activity?(char_instance)
        rewritten = rewrite_for_activity(cleaned)
        return rewritten if rewritten
      end

      # Return original input unchanged
      input
    end

    private

    # Check if character is in an activity
    def in_activity?(char_instance)
      return false unless char_instance
      return false unless defined?(ActivityService)

      room = char_instance.current_room
      return false unless room

      instance = ActivityService.running_activity(room)
      return false unless instance

      # Don't rewrite to activity commands when paused for combat
      # (player is in a fight and combat commands like 'done' take priority)
      return false if instance.paused_for_combat?

      participant = ActivityService.participant_for(instance, char_instance)
      participant&.active?
    rescue StandardError => e
      warn "[InputInterceptorService] Failed to check activity participation: #{e.message}"
      false
    end

    # Rewrite command for activity context
    # @param input [String] the original input
    # @return [String, nil] rewritten input or nil if no rewrite needed
    def rewrite_for_activity(input)
      words = input.split
      return nil if words.empty?

      first_word = words.first.downcase

      # Check if the first word is an activity subcommand
      if ACTIVITY_SUBCOMMANDS.include?(first_word)
        # Don't rewrite if already prefixed with "activity"
        return nil if first_word == 'activity'

        # Rewrite: "status" -> "activity status"
        "activity #{input}"
      end
    end

    # Check if input matches a pending quickmenu option
    # @param char_instance [CharacterInstance] the character
    # @param input [String] the input
    # @return [Hash, nil] result if matched, nil otherwise
    def try_quickmenu_shortcut(char_instance, input)
      # Get all pending interactions for this character
      pending = OutputHelper.get_pending_interactions(char_instance.id)
      return nil if pending.empty?

      # Find quickmenus only
      quickmenus = pending.select { |i| i[:type] == 'quickmenu' }
      return nil if quickmenus.empty?

      # Take the most recent quickmenu (last created)
      quickmenu = quickmenus.max_by { |q| q[:created_at] || '' }
      return nil unless quickmenu

      # Check if input matches any option key or label
      options = quickmenu[:options] || []
      matched_option = options.find do |opt|
        opt[:key].to_s.downcase == input.downcase ||
          opt[:label].to_s.downcase == input.downcase
      end

      # Also support numeric index (1-based) for keyboard selection
      if matched_option.nil? && input.match?(/\A\d+\z/)
        index = input.to_i - 1
        matched_option = options[index] if index >= 0 && index < options.length
      end

      return nil unless matched_option

      # Handle the quickmenu response
      handle_quickmenu_response(char_instance, quickmenu, matched_option[:key])
    end

    # Simple item commands that all use handle_simple_item_quickmenu
    QUICKMENU_SIMPLE_ITEM_COMMANDS = %w[wear remove drop get].freeze

    # Registry mapping context[:command] || context['command'] to handler methods
    QUICKMENU_COMMAND_HANDLERS = {
      'roll' => :handle_roll_quickmenu,
      'buy' => :handle_buy_quickmenu,
      'use' => :handle_use_quickmenu,
      'give' => :handle_give_quickmenu,
      'show' => :handle_show_quickmenu,
      'memo' => :handle_memo_quickmenu,
      'events' => :handle_events_quickmenu,
      'fight' => :handle_fight_quickmenu,
      'whisper' => :handle_whisper_quickmenu,
      'taxi' => :handle_taxi_quickmenu,
      'clan' => :handle_clan_quickmenu,
      'check_in' => :handle_locatability_quickmenu,
      'quiet' => :handle_quiet_quickmenu,
      'map' => :handle_map_quickmenu,
      'journey' => :handle_journey_quickmenu,
      'permissions' => :handle_permissions_quickmenu,
      'shop' => :handle_shop_quickmenu,
      'shop_buy' => :handle_shop_buy_quickmenu,
      'media' => :handle_media_quickmenu,
      'property' => :handle_property_quickmenu,
      'property_grant' => :handle_property_grant_quickmenu,
      'property_revoke' => :handle_property_revoke_quickmenu,
      'tickets' => :handle_tickets_quickmenu,
      'tickets_list' => :handle_tickets_list_quickmenu,
      'wardrobe' => :handle_wardrobe_quickmenu,
      'wardrobe_store' => :handle_wardrobe_store_quickmenu,
      'wardrobe_retrieve' => :handle_wardrobe_retrieve_quickmenu,
      'wardrobe_transfer' => :handle_wardrobe_transfer_quickmenu,
      'timeline' => :handle_timeline_quickmenu,
      'cards' => :handle_cards_quickmenu,
      'fabricate' => :handle_fabricate_quickmenu,
      'delve' => :handle_delve_quickmenu,
      'travel_choice' => :handle_travel_choice_quickmenu
    }.freeze

    # Registry mapping context[:handler] || context['handler'] to handler methods
    QUICKMENU_HANDLER_DISPATCHERS = {
      'travel_options' => :handle_travel_options_quickmenu,
      'party_invite' => :handle_party_invite_quickmenu,
      'ooc_request' => :handle_ooc_request_quickmenu,
      'attempt' => :handle_attempt_quickmenu
    }.freeze

    # Handle a matched quickmenu response
    # @param char_instance [CharacterInstance]
    # @param quickmenu [Hash] the quickmenu data
    # @param response_key [String] the selected option key
    # @return [Hash] the result
    def handle_quickmenu_response(char_instance, quickmenu, response_key)
      interaction_id = quickmenu[:interaction_id]
      # Normalize all context keys to strings once, avoiding repeated symbol/string checks
      context = (quickmenu[:context] || {}).transform_keys(&:to_s)

      # Mark interaction as complete
      OutputHelper.complete_interaction(char_instance.id, interaction_id)

      # Priority checks for special context keys
      if context['combat']
        return handle_combat_quickmenu(char_instance, context, response_key)
      end
      if context['activity']
        return handle_activity_quickmenu(char_instance, context, response_key)
      end
      if context['action'] == 'walk'
        result = DisambiguationHandler.process_response(char_instance, quickmenu, response_key)
        return { success: result.success, message: result.message, type: :action }
      end
      # Whisper can match on either 'command' or 'action'
      if context['action'] == 'whisper'
        return handle_whisper_quickmenu(char_instance, context, response_key)
      end
      if context['action'] == 'dress_consent'
        return handle_dress_consent_quickmenu(char_instance, context, response_key)
      end

      command = context['command']

      # Simple item commands (wear, remove, drop, get)
      if QUICKMENU_SIMPLE_ITEM_COMMANDS.include?(command)
        return handle_simple_item_quickmenu(char_instance, context, response_key, command)
      end

      # Command registry lookup
      handler = QUICKMENU_COMMAND_HANDLERS[command]
      return send(handler, char_instance, context, response_key) if handler

      # Handler registry lookup
      handler_key = context['handler']
      dispatcher = QUICKMENU_HANDLER_DISPATCHERS[handler_key]
      return send(dispatcher, char_instance, context, response_key) if dispatcher

      # Command-level quickmenu handlers (for commands that provide their own
      # handle_quickmenu_response/handle_quickmenu methods).
      command_dispatch = dispatch_command_quickmenu_handler(char_instance, command, context, response_key)
      return command_dispatch if command_dispatch

      # Generic quickmenu response
      {
        success: true,
        message: "Selected: #{response_key}",
        type: :message,
        data: { response: response_key, context: context }
      }
    end

    # Handle combat quickmenu response
    # @param char_instance [CharacterInstance]
    # @param context [Hash] quickmenu context with combat: true, fight_id, participant_id
    # @param response_key [String] selected option key
    # @return [Hash] result
    def handle_combat_quickmenu(char_instance, context, response_key)
      participant_id = context[:participant_id] || context['participant_id']
      participant = FightParticipant[participant_id] if participant_id
      fight_id = (context[:fight_id] || context['fight_id']).to_i

      unless participant
        return {
          success: false,
          error: 'You are not in combat.',
          type: :error
        }
      end
      unless participant.character_instance_id == char_instance.id
        return {
          success: false,
          error: 'That combat menu does not belong to you.',
          type: :error
        }
      end
      if fight_id.positive? && participant.fight_id != fight_id
        return {
          success: false,
          error: 'Combat interaction is out of sync.',
          type: :error
        }
      end

      result = CombatQuickmenuHandler.handle_response(participant, char_instance, response_key.to_s)

      if result == :round_resolved
        # Round resolved — all combat messages sent via WebSocket, suppress HTTP text
        {
          success: true,
          type: :message
        }
      elsif result.nil?
        # Input complete, waiting for other participants — suppress text output
        {
          success: true,
          type: :message
        }
      else
        # Store as pending interaction so the next response can be routed
        interaction_id = SecureRandom.uuid
        stored = {
          interaction_id: interaction_id,
          type: 'quickmenu',
          prompt: result[:prompt],
          options: result[:options],
          context: result[:context] || {},
          created_at: Time.now.iso8601
        }
        OutputHelper.store_agent_interaction(char_instance, interaction_id, stored)

        {
          success: true,
          type: :quickmenu,
          data: {
            interaction_id: interaction_id,
            prompt: result[:prompt],
            options: result[:options]
          },
          message: format_quickmenu_html(result[:prompt], result[:options])
        }
      end
    rescue StandardError => e
      warn "[InputInterceptorService] Combat quickmenu error: #{e.message}"
      { success: false, error: 'Failed to process combat choice.', type: :error }
    end

    # Handle activity quickmenu response
    # @param char_instance [CharacterInstance]
    # @param context [Hash] quickmenu context
    # @param response_key [String] selected option
    # @return [Hash] result
    def handle_activity_quickmenu(char_instance, context, response_key)
      participant_id = context[:participant_id] || context['participant_id']
      participant = ActivityParticipant[participant_id] if participant_id

      unless participant
        return {
          success: false,
          error: 'You are not in an activity.',
          type: :error
        }
      end
      unless participant.char_id == char_instance.character_id
        return {
          success: false,
          error: 'That activity menu does not belong to you.',
          type: :error
        }
      end

      # Use the quickmenu handler
      result = ActivityQuickmenuHandler.handle_response(participant, char_instance, response_key.to_s)

      if result.nil?
        # Input complete
        {
          success: true,
          message: 'Your choice has been recorded.',
          type: :message
        }
      else
        # Store as pending interaction so the next response can be routed
        interaction_id = SecureRandom.uuid
        stored = {
          interaction_id: interaction_id,
          type: 'quickmenu',
          prompt: result[:prompt],
          options: result[:options],
          context: result[:context] || {},
          created_at: Time.now.iso8601
        }
        OutputHelper.store_agent_interaction(char_instance, interaction_id, stored)

        {
          success: true,
          type: :quickmenu,
          data: {
            interaction_id: interaction_id,
            prompt: result[:prompt],
            options: result[:options]
          },
          message: format_quickmenu_html(result[:prompt], result[:options])
        }
      end
    rescue StandardError => e
      warn "[InputInterceptorService] Activity quickmenu error: #{e.message}"
      { success: false, error: 'Failed to process activity choice.', type: :error }
    end

    # Handle roll quickmenu response
    # @param char_instance [CharacterInstance]
    # @param context [Hash] quickmenu context with stats array
    # @param response_key [String] selected option key
    # @return [Hash] result
    def handle_roll_quickmenu(char_instance, context, response_key)
      stats = context[:stats] || context['stats'] || []

      # Handle cancel
      if response_key.downcase == 'q'
        return {
          success: true,
          message: 'Roll cancelled.',
          type: :message
        }
      end

      # Handle combine option - prompt user to type stat names
      if response_key.downcase == 'c'
        return {
          success: true,
          message: "Type: roll <STAT>+<STAT> (e.g., roll STR+DEX)",
          type: :message
        }
      end

      # Numeric selection - look up the stat
      idx = response_key.to_i - 1
      if idx >= 0 && idx < stats.length
        stat = stats[idx]
        stat_abbr = stat[:abbr] || stat['abbr']

        # Execute the roll command with the selected stat
        execute_roll_command(char_instance, stat_abbr)
      else
        {
          success: false,
          error: "Invalid selection. Type 'roll' to see options again.",
          type: :error
        }
      end
    rescue StandardError => e
      warn "[InputInterceptorService] Roll quickmenu error: #{e.message}"
      { success: false, error: 'Failed to process roll selection.', type: :error }
    end

    # Execute the roll command for a stat
    # @param char_instance [CharacterInstance]
    # @param stat_abbr [String] the stat abbreviation
    # @return [Hash] result
    def execute_roll_command(char_instance, stat_abbr)
      # Execute roll command with the stat abbreviation
      result = Commands::Base::Registry.execute_command(char_instance, "roll #{stat_abbr}")

      if result[:success]
        {
          success: true,
          message: result[:message],
          type: result[:type] || :message,
          data: result[:data]
        }
      else
        {
          success: false,
          error: result[:error] || result[:message],
          type: :error
        }
      end
    rescue StandardError => e
      warn "[InputInterceptorService] Execute roll error: #{e.message}"
      { success: false, error: 'Failed to execute roll.', type: :error }
    end

    # Handle buy quickmenu response
    # @param char_instance [CharacterInstance]
    # @param context [Hash] quickmenu context with items array
    # @param response_key [String] selected option key
    # @return [Hash] result
    def handle_buy_quickmenu(char_instance, context, response_key)
      # Handle cancel
      if response_key.downcase == 'q'
        return {
          success: true,
          message: 'Purchase cancelled.',
          type: :message
        }
      end

      # Determine item reference from context type
      idx = response_key.to_i - 1
      match_ids = context[:match_ids] || context['match_ids']
      items = context[:items] || context['items'] || []

      item_ref = if match_ids && idx >= 0 && idx < match_ids.length
                   # Disambiguation menu - use ID-based targeting
                   "##{match_ids[idx]}"
                 elsif idx >= 0 && idx < items.length
                   # Item selection menu - use item name
                   item = items[idx]
                   item[:name] || item['name']
                 end

      unless item_ref
        return {
          success: false,
          error: "Invalid selection. Type 'buy' to see available items.",
          type: :error
        }
      end

      # Execute the buy command with the item reference
      result = Commands::Base::Registry.execute_command(char_instance, "buy #{item_ref}")

      if result[:success]
        {
          success: true,
          message: result[:message],
          type: result[:type] || :message,
          data: result[:data]
        }
      else
        {
          success: false,
          error: result[:error] || result[:message],
          type: :error
        }
      end
    rescue StandardError => e
      warn "[InputInterceptorService] Buy quickmenu error: #{e.message}"
      { success: false, error: 'Failed to process purchase.', type: :error }
    end

    # Handle use quickmenu response (two-stage: item selection, then action selection)
    # @param char_instance [CharacterInstance]
    # @param context [Hash] quickmenu context with stage, items, or item_id
    # @param response_key [String] selected option key
    # @return [Hash] result
    def handle_use_quickmenu(char_instance, context, response_key)
      stage = context[:stage] || context['stage']

      # Handle cancel at any stage
      if response_key.downcase == 'q'
        return {
          success: true,
          message: 'Cancelled.',
          type: :message
        }
      end

      case stage
      when 'select_item'
        handle_use_item_selection(char_instance, context, response_key)
      when 'select_action'
        handle_use_action_selection(char_instance, context, response_key)
      when 'select_game_branch'
        handle_use_game_branch_selection(char_instance, context, response_key)
      else
        { success: false, error: 'Invalid use menu state.', type: :error }
      end
    rescue StandardError => e
      warn "[InputInterceptorService] Use quickmenu error: #{e.message}"
      { success: false, error: 'Failed to process item action.', type: :error }
    end

    # Handle item selection in use menu
    def handle_use_item_selection(char_instance, context, response_key)
      items = context[:items] || context['items'] || []

      idx = response_key.to_i - 1
      if idx >= 0 && idx < items.length
        item_data = items[idx]
        item_name = item_data[:name] || item_data['name']

        # Execute use command with the item name to show action menu
        result = Commands::Base::Registry.execute_command(char_instance, "use #{item_name}")

        if result[:success]
          {
            success: true,
            type: result[:type] || :quickmenu,
            message: result[:message],
            interaction_id: result[:interaction_id],
            prompt: result[:prompt],
            options: result[:options],
            data: result[:data]
          }
        else
          {
            success: false,
            error: result[:error] || result[:message],
            type: :error
          }
        end
      else
        {
          success: false,
          error: "Invalid selection. Type 'use' to see your items.",
          type: :error
        }
      end
    end

    # Handle action selection in use menu
    def handle_use_action_selection(char_instance, context, response_key)
      item_id = context[:item_id] || context['item_id']
      item_name = context[:item_name] || context['item_name']

      # Find the item
      item = char_instance.objects_dataset.first(id: item_id)
      unless item
        return {
          success: false,
          error: "You no longer have that item.",
          type: :error
        }
      end

      # Map action key to command
      command = case response_key.downcase
                when 'h' then "hold #{item_name}"
                when 'r' then "release #{item_name}"
                when 'w'
                  item.worn? ? "remove #{item_name}" : "wear #{item_name}"
                when 'c' then "consume #{item_name}"
                when 'd' then "drop #{item_name}"
                when 'e' then "look at #{item_name}"
                when 'g' then "give #{item_name}"  # Will need target - shows give menu
                when 's' then "show #{item_name}"  # Will need target - shows show menu
                else nil
                end

      unless command
        return {
          success: false,
          error: "Invalid action. Type 'use #{item_name}' to see options.",
          type: :error
        }
      end

      # Execute the command
      result = Commands::Base::Registry.execute_command(char_instance, command)

      if result[:success]
        {
          success: true,
          message: result[:message],
          type: result[:type] || :message,
          data: result[:data]
        }
      else
        {
          success: false,
          error: result[:error] || result[:message],
          type: :error
        }
      end
    end

    # Handle game branch selection in use menu
    # @param char_instance [CharacterInstance]
    # @param context [Hash] contains game_instance_id and branches array
    # @param response_key [String] selected option key (1-based index)
    # @return [Hash] result
    def handle_use_game_branch_selection(char_instance, context, response_key)
      game_instance_id = context[:game_instance_id] || context['game_instance_id']
      branches = context[:branches] || context['branches'] || []

      idx = response_key.to_i - 1
      if idx >= 0 && idx < branches.length
        branch_data = branches[idx]
        branch_id = branch_data[:id] || branch_data['id']

        game_instance = GameInstance[game_instance_id]
        return { success: false, error: 'Game not found.', type: :error } unless game_instance

        branch = GamePatternBranch[branch_id]
        return { success: false, error: 'Game option not found.', type: :error } unless branch

        result = GamePlayService.play(game_instance, branch, char_instance)
        return { success: false, error: result[:error], type: :error } unless result[:success]

        # Format output same as in use.rb
        output = format_game_result(result)
        { success: true, message: output, type: :message }
      else
        { success: false, error: 'Invalid selection.', type: :error }
      end
    rescue StandardError => e
      warn "[InputInterceptorService] Game branch selection error: #{e.message}"
      { success: false, error: 'Failed to process game selection.', type: :error }
    end

    # Format game play result for display
    # @param result [Hash] from GamePlayService.play
    # @return [String] formatted output
    def format_game_result(result)
      lines = []
      lines << "[ #{result[:game_name]} - #{result[:branch_name]} ]"
      lines << ''
      lines << result[:message]

      if result[:total_score]
        score_line = result[:points] > 0 ? "+#{result[:points]} points" : "#{result[:points]} points"
        lines << ''
        lines << "#{score_line} | Your score: #{result[:total_score]} points"
      end

      lines.join("\n")
    end

    # Handle give quickmenu response (two-stage: item selection, then target selection)
    # @param char_instance [CharacterInstance]
    # @param context [Hash] quickmenu context with stage and data
    # @param response_key [String] selected option key
    # @return [Hash] result
    def handle_give_quickmenu(char_instance, context, response_key)
      handle_give_or_show_quickmenu(char_instance, context, response_key, action: 'give')
    end

    # Handle show quickmenu response (same pattern as give)
    def handle_show_quickmenu(char_instance, context, response_key)
      handle_give_or_show_quickmenu(char_instance, context, response_key, action: 'show')
    end

    # Shared handler for give/show quickmenus
    def handle_give_or_show_quickmenu(char_instance, context, response_key, action:)
      stage = context[:stage] || context['stage']

      # Handle cancel at any stage
      if response_key.downcase == 'q'
        return {
          success: true,
          message: 'Cancelled.',
          type: :message
        }
      end

      case stage
      when 'select_item'
        handle_give_item_selection(char_instance, context, response_key, action)
      when 'select_target'
        handle_give_target_selection(char_instance, context, response_key, action)
      else
        { success: false, error: "Invalid #{action} menu state.", type: :error }
      end
    rescue StandardError => e
      warn "[InputInterceptorService] #{action.capitalize} quickmenu error: #{e.message}"
      { success: false, error: "Failed to process #{action}.", type: :error }
    end

    # Handle item selection for give/show
    def handle_give_item_selection(char_instance, context, response_key, action)
      items = context[:items] || context['items'] || []

      idx = response_key.to_i - 1
      if idx >= 0 && idx < items.length
        item_data = items[idx]
        item_id = item_data[:id] || item_data['id']
        item_name = item_data[:name] || item_data['name']

        # Get target menu - execute the command to show target selection
        result = target_menu(char_instance, item_id, item_name, action)
        result
      else
        {
          success: false,
          error: "Invalid selection. Type '#{action}' to see your items.",
          type: :error
        }
      end
    end

    # Get the target selection menu for give/show
    def target_menu(char_instance, item_id, item_name, action)
      room = char_instance.current_room
      others = room.character_instances_dataset
                   .exclude(id: char_instance.id)
                   .all

      if others.empty?
        return {
          success: false,
          error: "There's no one here to #{action} things to.",
          type: :error
        }
      end

      options = others.each_with_index.map do |ci, idx|
        {
          key: (idx + 1).to_s,
          label: ci.character.display_name_for(char_instance),
          description: ci.character.short_desc || ''
        }
      end
      options << { key: 'q', label: 'Cancel', description: 'Close menu' }

      char_data = others.map do |ci|
        { id: ci.id, character_id: ci.id, name: ci.character.display_name_for(char_instance) }
      end

      interaction_id = SecureRandom.uuid
      menu_data = {
        type: 'quickmenu',
        interaction_id: interaction_id,
        prompt: "#{action.capitalize} #{item_name} to whom?",
        options: options,
        context: {
          command: action,
          stage: 'select_target',
          item_id: item_id,
          item_name: item_name,
          characters: char_data
        },
        created_at: Time.now.iso8601
      }

      OutputHelper.store_agent_interaction(char_instance, interaction_id, menu_data)

      {
        success: true,
        type: :quickmenu,
        interaction_id: interaction_id,
        prompt: menu_data[:prompt],
        options: options,
        message: format_quickmenu_html(menu_data[:prompt], options)
      }
    end

    def format_quickmenu_html(prompt, options)
      html = "<div class='quickmenu'>"
      html += "<p class='quickmenu-prompt'>#{prompt}</p>"
      html += "<ul class='quickmenu-options'>"
      options.each do |opt|
        html += "<li><button data-key='#{opt[:key]}'>"
        html += "<span class='key'>[#{opt[:key]}]</span> "
        html += "<span class='label'>#{opt[:label]}</span>"
        html += "<span class='desc'>#{opt[:description]}</span>" if opt[:description]
        html += "</button></li>"
      end
      html += "</ul></div>"
      html
    end

    # Handle target selection for give/show
    def handle_give_target_selection(char_instance, context, response_key, action)
      characters = context[:characters] || context['characters'] || []
      item_id = context[:item_id] || context['item_id']
      item_name = context[:item_name] || context['item_name']

      idx = response_key.to_i - 1
      if idx >= 0 && idx < characters.length
        char_data = characters[idx]
        target_name = char_data[:name] || char_data['name']

        # Execute the command
        command = "#{action} #{item_name} to #{target_name}"
        result = Commands::Base::Registry.execute_command(char_instance, command)

        if result[:success]
          {
            success: true,
            message: result[:message],
            type: result[:type] || :message,
            data: result[:data]
          }
        else
          {
            success: false,
            error: result[:error] || result[:message],
            type: :error
          }
        end
      else
        {
          success: false,
          error: "Invalid selection. Type '#{action}' to try again.",
          type: :error
        }
      end
    end

    # Handle events quickmenu response
    # @param char_instance [CharacterInstance]
    # @param context [Hash] quickmenu context with events array
    # @param response_key [String] selected option key
    # @return [Hash] result
    def handle_events_quickmenu(char_instance, context, response_key)
      events = context[:events] || context['events'] || []

      # Handle cancel
      if response_key.downcase == 'q'
        return {
          success: true,
          message: 'Calendar closed.',
          type: :message
        }
      end

      # Handle create
      if response_key.downcase == 'c'
        result = Commands::Base::Registry.execute_command(char_instance, "events create")
        return {
          success: result[:success],
          type: result[:type] || :form,
          message: result[:message],
          interaction_id: result[:interaction_id],
          data: result[:data]
        }
      end

      # Handle my events
      if response_key.downcase == 'm'
        result = Commands::Base::Registry.execute_command(char_instance, "events my")
        return {
          success: result[:success],
          message: result[:message],
          type: result[:type] || :message,
          data: result[:data]
        }
      end

      # Handle events here
      if response_key.downcase == 'h'
        result = Commands::Base::Registry.execute_command(char_instance, "events here")
        return {
          success: result[:success],
          message: result[:message],
          type: result[:type] || :message,
          data: result[:data]
        }
      end

      # Numeric selection - show event info
      idx = response_key.to_i - 1
      if idx >= 0 && idx < events.length
        event_data = events[idx]
        event_name = event_data[:name] || event_data['name']

        # Execute event info command
        result = Commands::Base::Registry.execute_command(char_instance, "event info #{event_name}")

        {
          success: result[:success],
          message: result[:message] || result[:error],
          type: result[:type] || :message,
          data: result[:data]
        }
      else
        {
          success: false,
          error: "Invalid selection. Type 'events' to see the calendar.",
          type: :error
        }
      end
    rescue StandardError => e
      warn "[InputInterceptorService] Events quickmenu error: #{e.message}"
      { success: false, error: 'Failed to process event selection.', type: :error }
    end

    # Handle memo quickmenu response
    # @param char_instance [CharacterInstance]
    # @param context [Hash] quickmenu context with memos array
    # @param response_key [String] selected option key
    # @return [Hash] result
    def handle_memo_quickmenu(char_instance, context, response_key)
      memos = context[:memos] || context['memos'] || []

      # Handle cancel
      if response_key.downcase == 'q'
        return {
          success: true,
          message: 'Inbox closed.',
          type: :message
        }
      end

      # Handle new memo
      if response_key.downcase == 'n'
        return {
          success: true,
          message: "To compose a memo:\n  send memo <name> <subject>=<body>\n\nExample:\n  send memo Alice Meeting=Want to meet at the tavern?",
          type: :message
        }
      end

      # Numeric selection - read the selected memo
      idx = response_key.to_i - 1
      if idx >= 0 && idx < memos.length
        memo_data = memos[idx]
        memo_id = memo_data[:id] || memo_data['id']

        # Get the memo and read it
        memo = Memo[memo_id]
        unless memo
          return {
            success: false,
            error: "That memo no longer exists.",
            type: :error
          }
        end

        # Mark as read
        memo.mark_read!

        sender_name = memo.sender&.full_name || 'Unknown'
        memo_num = idx + 1

        content = [
          "<h4>Memo ##{memo_num}</h4>",
          "<div><strong>From:</strong> #{sender_name}</div>",
          "<div><strong>Subject:</strong> #{memo.subject}</div>",
          "<div class=\"text-sm opacity-70\">#{memo.sent_at&.strftime('%Y-%m-%d %H:%M')}</div>",
          "<div class=\"divider my-1\"></div>",
          memo.body,
          "",
          "Commands: delete memo #{memo_num} | memos (back to inbox)"
        ].join("\n")

        {
          success: true,
          message: content,
          type: :message,
          data: {
            action: 'read_memo',
            memo_id: memo.id,
            sender: sender_name,
            subject: memo.subject
          }
        }
      else
        {
          success: false,
          error: "Invalid selection. Type 'memos' to see your inbox.",
          type: :error
        }
      end
    rescue StandardError => e
      warn "[InputInterceptorService] Memo quickmenu error: #{e.message}"
      { success: false, error: 'Failed to read memo.', type: :error }
    end

    # Handle simple item quickmenu (wear, remove, drop, get)
    # These all follow the same pattern: select item, execute command
    # Supports two context types:
    #   - item_selection_menu: context has items: [{id, name}, ...]
    #   - disambiguation menu: context has match_ids: [id1, id2, ...] and disambiguation: true
    # @param char_instance [CharacterInstance]
    # @param context [Hash] quickmenu context with items array or match_ids
    # @param response_key [String] selected option key
    # @param command [String] the command to execute
    # @return [Hash] result
    def handle_simple_item_quickmenu(char_instance, context, response_key, command)
      # Handle cancel
      if response_key.downcase == 'q'
        return {
          success: true,
          message: 'Cancelled.',
          type: :message
        }
      end

      # Determine item identifier from context type
      idx = response_key.to_i - 1
      match_ids = context[:match_ids] || context['match_ids']
      items = context[:items] || context['items'] || []

      item_ref = if match_ids && idx >= 0 && idx < match_ids.length
                   # Disambiguation menu - use ID-based targeting
                   "##{match_ids[idx]}"
                 elsif idx >= 0 && idx < items.length
                   # Item selection menu - use item name
                   item_data = items[idx]
                   item_data[:name] || item_data['name']
                 end

      unless item_ref
        return {
          success: false,
          error: "Invalid selection. Type '#{command}' to see options.",
          type: :error
        }
      end

      # Execute the command with the item reference
      result = Commands::Base::Registry.execute_command(char_instance, "#{command} #{item_ref}")

      if result[:success]
        {
          success: true,
          message: result[:message],
          type: result[:type] || :message,
          data: result[:data]
        }
      else
        {
          success: false,
          error: result[:error] || result[:message],
          type: :error
        }
      end
    rescue StandardError => e
      warn "[InputInterceptorService] #{command.capitalize} quickmenu error: #{e.message}"
      { success: false, error: "Failed to process #{command}.", type: :error }
    end

    # Handle fight quickmenu response
    # @param char_instance [CharacterInstance]
    # @param context [Hash] quickmenu context with targets array
    # @param response_key [String] selected option key
    # @return [Hash] result
    def handle_fight_quickmenu(char_instance, context, response_key)
      targets = context[:targets] || context['targets'] || []

      # Handle cancel
      if response_key.downcase == 'q'
        return {
          success: true,
          message: 'Combat cancelled.',
          type: :message
        }
      end

      # Numeric selection
      idx = response_key.to_i - 1
      if idx >= 0 && idx < targets.length
        target_data = targets[idx]
        target_name = target_data[:name] || target_data['name']

        # Execute the fight command
        result = Commands::Base::Registry.execute_command(char_instance, "fight #{target_name}")

        if result[:success]
          {
            success: true,
            message: result[:message],
            type: result[:type] || :message,
            data: result[:data]
          }
        else
          {
            success: false,
            error: result[:error] || result[:message],
            type: :error
          }
        end
      else
        {
          success: false,
          error: "Invalid selection. Type 'fight' to see targets.",
          type: :error
        }
      end
    rescue StandardError => e
      warn "[InputInterceptorService] Fight quickmenu error: #{e.message}"
      { success: false, error: 'Failed to start combat.', type: :error }
    end

    # Handle whisper quickmenu response (two-stage: target selection, then message prompt)
    # @param char_instance [CharacterInstance]
    # @param context [Hash] quickmenu context
    # @param response_key [String] selected option key
    # @return [Hash] result
    def handle_whisper_quickmenu(char_instance, context, response_key)
      # Handle cancel
      if response_key.downcase == 'q'
        return {
          success: true,
          message: 'Cancelled.',
          type: :message
        }
      end

      idx = response_key.to_i - 1
      match_ids = context[:match_ids] || context['match_ids']
      characters = context[:characters] || context['characters'] || []
      stored_message = context[:message] || context['message']

      if match_ids && idx >= 0 && idx < match_ids.length
        # Disambiguation menu - use ID-based targeting
        if stored_message
          # Execute whisper with #id target and stored message
          result = Commands::Base::Registry.execute_command(char_instance, "whisper ##{match_ids[idx]} #{stored_message}")
          if result[:success]
            { success: true, message: result[:message], type: result[:type] || :message, data: result[:data] }
          else
            { success: false, error: result[:error] || result[:message], type: :error }
          end
        else
          # No stored message - look up name for prompt
          target = CharacterInstance[match_ids[idx]]
          target_name = target&.character&.full_name || "them"
          { success: true, message: "Whisper to #{target_name}:\n  Type: whisper #{target_name} <your message>", type: :message }
        end
      elsif idx >= 0 && idx < characters.length
        # Character selection menu - prompt for message
        char_data = characters[idx]
        target_name = char_data[:name] || char_data['name']
        { success: true, message: "Whisper to #{target_name}:\n  Type: whisper #{target_name} <your message>", type: :message }
      else
        {
          success: false,
          error: "Invalid selection. Type 'whisper' to see people here.",
          type: :error
        }
      end
    rescue StandardError => e
      warn "[InputInterceptorService] Whisper quickmenu error: #{e.message}"
      { success: false, error: 'Failed to select target.', type: :error }
    end

    # Handle taxi quickmenu response
    # @param char_instance [CharacterInstance]
    # @param context [Hash] quickmenu context with destinations array
    # @param response_key [String] selected option key
    # @return [Hash] result
    def handle_taxi_quickmenu(char_instance, context, response_key)
      destinations = context[:destinations] || context['destinations'] || []

      # Handle cancel
      if response_key.downcase == 'q'
        return {
          success: true,
          message: 'Taxi cancelled.',
          type: :message
        }
      end

      # Handle call taxi (no destination)
      if response_key.downcase == 'c'
        result = Commands::Base::Registry.execute_command(char_instance, "taxi")
        return {
          success: result[:success],
          message: result[:message] || result[:error],
          type: result[:type] || :message,
          data: result[:data]
        }
      end

      # Numeric selection
      idx = response_key.to_i - 1
      if idx >= 0 && idx < destinations.length
        dest_data = destinations[idx]
        dest_name = dest_data[:name] || dest_data['name']

        # Execute taxi to destination
        result = Commands::Base::Registry.execute_command(char_instance, "taxi to #{dest_name}")

        if result[:success]
          {
            success: true,
            message: result[:message],
            type: result[:type] || :message,
            data: result[:data]
          }
        else
          {
            success: false,
            error: result[:error] || result[:message],
            type: :error
          }
        end
      else
        {
          success: false,
          error: "Invalid selection. Type 'taxi' to see destinations.",
          type: :error
        }
      end
    rescue StandardError => e
      warn "[InputInterceptorService] Taxi quickmenu error: #{e.message}"
      { success: false, error: 'Failed to take taxi.', type: :error }
    end

    # Handle locatability quickmenu response (from check_in command)
    # @param char_instance [CharacterInstance]
    # @param context [Hash] quickmenu context
    # @param response_key [String] selected option key ('yes', 'favorites', 'no', 'q')
    # @return [Hash] result
    def handle_locatability_quickmenu(char_instance, context, response_key)
      # Handle cancel
      if response_key.downcase == 'q'
        return {
          success: true,
          message: 'Locatability unchanged.',
          type: :message
        }
      end

      # Map response to locatability value
      locatability = case response_key.downcase
                     when '1', 'yes' then 'yes'
                     when '2', 'favorites' then 'favorites'
                     when '3', 'no' then 'no'
                     else nil
                     end

      unless locatability
        return {
          success: false,
          error: "Invalid selection. Type 'check in' to see options.",
          type: :error
        }
      end

      # Update character instance locatability
      char_instance.update(locatability: locatability)

      messages = {
        'yes' => "Your locatability is now set to: Yes (anyone can find you).",
        'favorites' => "Your locatability is now set to: Favorites Only (only players who have favorited you can see you in 'where').",
        'no' => "Your locatability is now set to: No (you are hidden from 'where' unless someone has marked you as 'always see')."
      }

      {
        success: true,
        message: messages[locatability],
        type: :message,
        data: {
          action: 'set_locatability',
          locatability: locatability
        }
      }
    rescue StandardError => e
      warn "[InputInterceptorService] Locatability quickmenu error: #{e.message}"
      { success: false, error: 'Failed to set locatability.', type: :error }
    end

    # Handle quiet mode catch-up quickmenu response
    # @param char_instance [CharacterInstance]
    # @param context [Hash] quickmenu context with quiet_mode_since timestamp
    # @param response_key [String] 'yes' or 'no'
    # @return [Hash] result
    def handle_quiet_quickmenu(char_instance, context, response_key)
      since_str = context[:quiet_mode_since] || context['quiet_mode_since']
      since = since_str ? Time.parse(since_str) : nil

      # Clear quiet mode first
      char_instance.clear_quiet_mode!

      # Broadcast the status change
      room_id = char_instance.current_room_id
      character = char_instance.character
      if room_id && character
        broadcast_personalized_to_room(
          room_id,
          "#{character.full_name} takes off their headphones. [Quiet Mode Off]",
          exclude: [char_instance.id],
          extra_characters: [char_instance]
        )
      end

      if response_key.downcase == 'yes' && since
        # Fetch and deliver missed messages
        messages = fetch_missed_channel_messages(since)

        if messages.empty?
          return {
            success: true,
            message: 'Quiet mode disabled. No missed messages.',
            type: :message,
            data: { action: 'quiet_disabled', missed_count: 0 }
          }
        end

        # Format catch-up summary
        summary = format_catchup_messages(messages)

        {
          success: true,
          message: "Quiet mode disabled.<br><br><h4>Missed Messages</h4>#{summary}",
          type: :message,
          data: {
            action: 'quiet_disabled',
            missed_count: messages.count,
            catch_up: true
          }
        }
      else
        {
          success: true,
          message: 'Quiet mode disabled.',
          type: :message,
          data: { action: 'quiet_disabled', missed_count: 0 }
        }
      end
    rescue StandardError => e
      warn "[InputInterceptorService] Quiet quickmenu error: #{e.message}"
      { success: false, error: 'Failed to process quiet mode exit.', type: :error }
    end

    # Fetch missed channel messages since a timestamp
    # @param since [Time] timestamp to fetch messages from
    # @return [Array<Message>] up to 100 missed messages
    def fetch_missed_channel_messages(since)
      channel_types = %w[ooc channel broadcast global area group]

      Message.where(message_type: channel_types)
             .where { created_at >= since }
             .order(:created_at)
             .limit(100)
             .all
    end

    # Format catch-up messages for display
    # @param messages [Array<Message>] messages to format
    # @return [String] formatted message summary
    def format_catchup_messages(messages)
      messages.map do |msg|
        time = msg.created_at.strftime('%H:%M')
        "[#{time}] #{msg.content}"
      end.join("\n")
    end

    # Handle clan disambiguation quickmenu response
    # @param char_instance [CharacterInstance]
    # @param context [Hash] quickmenu context with clan_ids and action
    # @param response_key [String] selected option key
    # @return [Hash] result
    def handle_clan_quickmenu(char_instance, context, response_key)
      # Handle cancel
      if response_key.downcase == 'q'
        return {
          success: true,
          message: 'Action cancelled.',
          type: :message
        }
      end

      # Use the clan disambiguation handler
      result = ClanDisambiguationHandler.process_response(char_instance, { context: context }, response_key)

      {
        success: result[:success],
        message: result[:message] || result[:error],
        type: result[:success] ? :message : :error
      }
    rescue StandardError => e
      warn "[InputInterceptorService] Clan quickmenu error: #{e.message}"
      { success: false, error: 'Failed to process clan selection.', type: :error }
    end

    # Handle party invite quickmenu response
    # @param char_instance [CharacterInstance]
    # @param context [Hash] quickmenu context with party_id, member_id
    # @param response_key [String] 'accept' or 'decline'
    # @return [Hash] result
    def handle_party_invite_quickmenu(char_instance, context, response_key)
      member_id = context[:member_id] || context['member_id']
      member = TravelPartyMember[member_id]

      unless member && member.character_instance_id == char_instance.id
        return {
          success: false,
          error: 'Invalid party invite.',
          type: :error
        }
      end

      party = member.party

      case response_key.downcase
      when 'accept'
        if member.accept!
          # Notify party leader
          BroadcastService.to_character(
            party.leader,
            "#{char_instance.character.full_name} has accepted your travel party invitation.",
            type: :social
          )

          {
            success: true,
            message: "You have joined #{party.leader&.character&.full_name}'s travel party to #{party.destination&.name}.",
            type: :message
          }
        else
          {
            success: false,
            error: 'Could not accept the invitation.',
            type: :error
          }
        end
      when 'decline'
        if member.decline!
          # Notify party leader
          BroadcastService.to_character(
            party.leader,
            "#{char_instance.character.full_name} has declined your travel party invitation.",
            type: :social
          )

          {
            success: true,
            message: "You have declined the invitation to travel to #{party.destination&.name}.",
            type: :message
          }
        else
          {
            success: false,
            error: 'Could not decline the invitation.',
            type: :error
          }
        end
      else
        {
          success: false,
          error: "Invalid response. Type 'accept' or 'decline'.",
          type: :error
        }
      end
    rescue StandardError => e
      warn "[InputInterceptorService] Party invite quickmenu error: #{e.message}"
      { success: false, error: 'Failed to process party invitation.', type: :error }
    end

    # Handle travel options quickmenu response
    # @param char_instance [CharacterInstance]
    # @param context [Hash] quickmenu context with destination_id, origin_id, travel_mode
    # @param response_key [String] selected option
    #   (standard, assemble_party, flashback_basic, flashback_return, flashback_backloaded, cancel)
    # @return [Hash] result
    def handle_travel_options_quickmenu(char_instance, context, response_key)
      selected_option = response_key.to_s.downcase

      # Handle cancel
      if selected_option == 'cancel'
        return {
          success: true,
          message: 'Journey cancelled.',
          type: :message
        }
      end

      valid_options = %w[standard assemble_party flashback_basic flashback_return flashback_backloaded]
      unless valid_options.include?(selected_option)
        return {
          success: false,
          error: "Invalid response. Choose one of: #{valid_options.join(', ')}.",
          type: :error
        }
      end

      destination_id = context[:destination_id] || context['destination_id']
      travel_mode = context[:travel_mode] || context['travel_mode']

      destination = Location[destination_id]
      unless destination
        return {
          success: false,
          error: 'Destination no longer exists.',
          type: :error
        }
      end

      if selected_option == 'assemble_party'
        existing_party = TravelParty.where(leader_id: char_instance.id, status: 'assembling').first
        if existing_party
          return {
            success: false,
            error: 'You already have an assembling party.',
            type: :error
          }
        end

        party = TravelParty.create_for(
          char_instance,
          destination,
          travel_mode: travel_mode
        )

        return {
          success: true,
          message: "Travel party assembled for #{destination.name}. Invite others with 'journey invite <name>', then use 'journey launch' when ready.",
          type: :travel_party,
          data: {
            action: 'party_created',
            party_id: party.id,
            destination: destination.name
          }
        }
      end

      # Determine flashback mode based on selection
      flashback_mode = case selected_option
                       when 'standard' then nil
                       when 'flashback_basic' then :basic
                       when 'flashback_return' then :return
                       when 'flashback_backloaded' then :backloaded
                       end

      # Start the journey
      result = JourneyService.start_journey(
        char_instance,
        destination: destination,
        travel_mode: travel_mode,
        flashback_mode: flashback_mode
      )

      if result[:success]
        {
          success: true,
          message: result[:message],
          type: :world_travel,
          data: {
            action: 'journey_started',
            destination: destination.name,
            instanced: result[:instanced] || false
          }
        }
      else
        {
          success: false,
          error: result[:error],
          type: :error
        }
      end
    rescue StandardError => e
      warn "[InputInterceptorService] Travel options quickmenu error: #{e.message}"
      { success: false, error: 'Failed to start journey.', type: :error }
    end

    # Handle OOC request quickmenu response
    # @param char_instance [CharacterInstance]
    # @param context [Hash] quickmenu context with request_id
    # @param response_key [String] 'accept' or 'decline'
    # @return [Hash] result
    def handle_ooc_request_quickmenu(char_instance, context, response_key)
      request_id = context[:request_id] || context['request_id']
      request = OocRequest[request_id]

      unless request
        char_instance.clear_pending_ooc_request!
        return {
          success: false,
          error: 'The OOC request is no longer valid.',
          type: :error
        }
      end

      sender_name = request.sender_character&.full_name || 'Unknown'

      case response_key.downcase
      when 'accept'
        # Accept the request
        request.accept!
        char_instance.clear_pending_ooc_request!

        # Notify sender if online
        notify_ooc_request_sender(request, :accepted, char_instance)

        {
          success: true,
          message: "Accepted OOC request from #{sender_name}. They can now PM you.",
          type: :system,
          data: { action: 'ooc_request_accepted', request_id: request.id }
        }
      when 'decline'
        # Decline the request
        request.decline!
        char_instance.clear_pending_ooc_request!

        # Notify sender if online
        notify_ooc_request_sender(request, :declined, char_instance)

        cooldown = defined?(OocRequest::COOLDOWN_HOURS) ? OocRequest::COOLDOWN_HOURS : 1
        {
          success: true,
          message: "Declined OOC request from #{sender_name}. They cannot request again for #{cooldown} hour(s).",
          type: :system,
          data: { action: 'ooc_request_declined', request_id: request.id }
        }
      else
        {
          success: false,
          error: 'Invalid response.',
          type: :error
        }
      end
    rescue StandardError => e
      warn "[InputInterceptorService] OOC request quickmenu error: #{e.message}"
      { success: false, error: 'Failed to process OOC request response.', type: :error }
    end

    # Notify the OOC request sender about the response
    def notify_ooc_request_sender(request, status, responder_instance)
      # Find sender's online instance via their character
      sender_character = request.sender_character
      return unless sender_character

      sender_instance = CharacterInstance.where(
        character_id: sender_character.id,
        online: true
      ).first
      return unless sender_instance

      target_name = responder_instance.character.display_name_for(sender_instance)
      message = if status == :accepted
                  "#{target_name} accepted your OOC request. You can now PM them."
                else
                  "#{target_name} declined your OOC request."
                end

      BroadcastService.to_character(sender_instance, message, type: :system)
    end

    # Handle map quickmenu response
    # @param char_instance [CharacterInstance]
    # @param context [Hash] quickmenu context
    # @param response_key [String] 'room', 'area', 'city', or 'mini'
    # @return [Hash] result
    def handle_map_quickmenu(char_instance, context, response_key)
      # Execute the map command with the selected type
      result = Commands::Base::Registry.execute_command(char_instance, "map #{response_key}")

      if result[:success]
        {
          success: true,
          message: result[:message],
          type: result[:type] || :message,
          data: result[:data],
          target_panel: result[:target_panel],
          output_category: result[:output_category]
        }.compact
      else
        {
          success: false,
          error: result[:error] || result[:message],
          type: :error
        }
      end
    rescue StandardError => e
      warn "[InputInterceptorService] Map quickmenu error: #{e.message}"
      { success: false, error: 'Failed to display map.', type: :error }
    end

    # Handle journey quickmenu response
    # @param char_instance [CharacterInstance]
    # @param context [Hash] quickmenu context with action ('traveling' or 'flashback')
    # @param response_key [String] selected action
    # @return [Hash] result
    def handle_journey_quickmenu(char_instance, context, response_key)
      # Execute the journey command with the selected action
      result = Commands::Base::Registry.execute_command(char_instance, "journey #{response_key}")

      if result[:success]
        {
          success: true,
          message: result[:message],
          type: result[:type] || :message,
          data: result[:data]
        }
      else
        {
          success: false,
          error: result[:error] || result[:message],
          type: :error
        }
      end
    rescue StandardError => e
      warn "[InputInterceptorService] Journey quickmenu error: #{e.message}"
      { success: false, error: 'Failed to process journey action.', type: :error }
    end

    # Handle permissions quickmenu response
    # @param char_instance [CharacterInstance]
    # @param context [Hash] quickmenu context
    # @param response_key [String] 'general', 'blocks', or 'consent'
    # @return [Hash] result
    def handle_permissions_quickmenu(char_instance, context, response_key)
      # Map menu option to command
      cmd = "permissions #{response_key}"

      result = Commands::Base::Registry.execute_command(char_instance, cmd)

      if result[:success]
        {
          success: true,
          message: result[:message],
          type: result[:type] || :message,
          data: result[:data]
        }
      else
        {
          success: false,
          error: result[:error] || result[:message],
          type: :error
        }
      end
    rescue StandardError => e
      warn "[InputInterceptorService] Permissions quickmenu error: #{e.message}"
      { success: false, error: 'Failed to process permissions action.', type: :error }
    end

    # Handle attempt/consent quickmenu response
    # @param char_instance [CharacterInstance]
    # @param context [Hash] quickmenu context with attempter_id, emote_text
    # @param response_key [String] 'allow' or 'deny'
    # @return [Hash] result
    def handle_attempt_quickmenu(char_instance, context, response_key)
      attempter_id = context[:attempter_id] || context['attempter_id']
      emote_text = context[:emote_text] || context['emote_text']
      sender_name = context[:sender_name] || context['sender_name']

      attempter = CharacterInstance[attempter_id]

      unless attempter
        char_instance.clear_pending_attempt!
        return {
          success: false,
          error: 'The person who made the request is no longer available.',
          type: :error
        }
      end

      case response_key.downcase
      when 'allow'
        # Build base emote with proper punctuation
        base_emote = "#{attempter.character.full_name} #{emote_text}"
        base_emote += '.' unless base_emote.match?(/[.!?]["'""'']*$/)

        room_id = char_instance.current_room_id

        # Get all online witnesses for personalized delivery
        witnesses = CharacterInstance.where(
          current_room_id: room_id, online: true
        ).eager(:character).all

        # Send personalized message to each viewer
        witnesses.each do |viewer|
          personalized = MessagePersonalizationService.personalize(
            message: base_emote,
            viewer: viewer,
            room_characters: witnesses
          )
          accepter_name = char_instance.character.display_name_for(viewer)
          tagged = "#{personalized} <sup class=\"emote-tag\">(Accepted by #{accepter_name})</sup>"
          BroadcastService.to_character_raw(viewer, tagged, type: :emote)
        end

        # Log base (unpersonalized) content to RP logs
        RpLoggingService.log_to_room(
          room_id,
          base_emote,
          sender: attempter,
          type: 'attempt'
        )

        # Notify the attempter
        BroadcastService.to_character_raw(
          attempter,
          "#{char_instance.character.display_name_for(attempter)} accepted your action request.",
          type: :attempt_response
        )

        # Clear the attempt on both sides
        char_instance.clear_pending_attempt!
        attempter.clear_attempt!

        {
          success: true,
          message: 'You allowed the action.',
          type: :message,
          data: {
            action: 'attempt_accepted',
            attempter_id: attempter.id,
            attempter_name: attempter.character.display_name_for(char_instance)
          }
        }
      when 'deny'
        # Notify the attempter
        BroadcastService.to_character(
          attempter,
          "#{char_instance.character.display_name_for(attempter)} denied your action request.",
          type: :attempt_response
        )

        # Clear the attempt on both sides
        char_instance.clear_pending_attempt!
        attempter.clear_attempt!

        {
          success: true,
          message: 'You denied the action request.',
          type: :message,
          data: {
            action: 'attempt_denied',
            attempter_id: attempter.id,
            attempter_name: attempter.character.display_name_for(char_instance)
          }
        }
      else
        {
          success: false,
          error: 'Invalid response.',
          type: :error
        }
      end
    rescue StandardError => e
      warn "[InputInterceptorService] Attempt quickmenu error: #{e.message}"
      { success: false, error: 'Failed to process action request response.', type: :error }
    end

    # Handle dress consent quickmenu response
    # @param char_instance [CharacterInstance] consenting target
    # @param context [Hash] quickmenu context with dresser_id, item_id, room_id
    # @param response_key [String] 'yes' or 'no'
    # @return [Hash] result
    def handle_dress_consent_quickmenu(char_instance, context, response_key)
      dresser_id = context[:dresser_id] || context['dresser_id']
      item_id = context[:item_id] || context['item_id']
      room_id = (context[:room_id] || context['room_id'] || char_instance.current_room_id).to_i

      dresser = CharacterInstance[dresser_id]
      unless dresser&.online
        return {
          success: false,
          error: 'The person who made this request is no longer available.',
          type: :error
        }
      end

      if room_id.positive? && (char_instance.current_room_id != room_id || dresser.current_room_id != room_id)
        return {
          success: false,
          error: 'This request is no longer valid because someone moved rooms.',
          type: :error
        }
      end

      target_name_for_dresser = char_instance.character.display_name_for(dresser)
      dresser_name_for_target = dresser.character.display_name_for(char_instance)
      item_name = Item[item_id]&.name || 'that item'

      case response_key.to_s.downcase
      when 'yes', 'accept', 'allow'
        InteractionPermissionService.grant_temporary_permission(
          char_instance,
          dresser,
          'dress',
          room_id: room_id
        )

        BroadcastService.to_character(
          dresser,
          "#{target_name_for_dresser} allowed you to dress them. Try the action again.",
          type: :system
        )

        {
          success: true,
          message: "You allow #{dresser_name_for_target} to dress you in #{item_name}.",
          type: :system,
          data: { action: 'dress_permission_granted', dresser_id: dresser.id, item_id: item_id }
        }
      when 'no', 'decline', 'deny'
        BroadcastService.to_character(
          dresser,
          "#{target_name_for_dresser} declined your request to dress them.",
          type: :system
        )

        {
          success: true,
          message: "You decline #{dresser_name_for_target}'s request.",
          type: :system,
          data: { action: 'dress_permission_denied', dresser_id: dresser.id, item_id: item_id }
        }
      else
        {
          success: false,
          error: 'Invalid response.',
          type: :error
        }
      end
    rescue StandardError => e
      warn "[InputInterceptorService] Dress consent quickmenu error: #{e.message}"
      { success: false, error: 'Failed to process dress consent.', type: :error }
    end

    # Handle shop main menu quickmenu response
    # @param char_instance [CharacterInstance]
    # @param context [Hash] quickmenu context with shop_id
    # @param response_key [String] 'browse', 'buy', or 'stock'
    # @return [Hash] result
    def handle_shop_quickmenu(char_instance, context, response_key)
      # Map menu option to command
      cmd = case response_key.downcase
            when 'browse' then 'shop list'
            when 'buy' then 'shop buy'
            when 'stock' then 'shop stock'
            else "shop #{response_key}"
            end

      result = Commands::Base::Registry.execute_command(char_instance, cmd)

      if result[:success]
        {
          success: true,
          message: result[:message],
          type: result[:type] || :message,
          data: result[:data]
        }
      else
        {
          success: false,
          error: result[:error] || result[:message],
          type: :error
        }
      end
    rescue StandardError => e
      warn "[InputInterceptorService] Shop quickmenu error: #{e.message}"
      { success: false, error: 'Failed to process shop action.', type: :error }
    end

    # Handle shop buy quickmenu response
    # @param char_instance [CharacterInstance]
    # @param context [Hash] quickmenu context with shop_id and items array
    # @param response_key [String] numeric selection or 'q' to cancel
    # @return [Hash] result
    def handle_shop_buy_quickmenu(char_instance, context, response_key)
      items = context[:items] || context['items'] || []

      # Handle cancel
      if response_key.downcase == 'q'
        return {
          success: true,
          message: 'Purchase cancelled.',
          type: :message
        }
      end

      # Numeric selection
      idx = response_key.to_i - 1
      if idx >= 0 && idx < items.length
        item_data = items[idx]
        item_name = item_data[:name] || item_data['name']

        # Execute the buy command
        result = Commands::Base::Registry.execute_command(char_instance, "shop buy #{item_name}")

        if result[:success]
          {
            success: true,
            message: result[:message],
            type: result[:type] || :message,
            data: result[:data]
          }
        else
          {
            success: false,
            error: result[:error] || result[:message],
            type: :error
          }
        end
      else
        {
          success: false,
          error: "Invalid selection. Type 'shop buy' to see available items.",
          type: :error
        }
      end
    rescue StandardError => e
      warn "[InputInterceptorService] Shop buy quickmenu error: #{e.message}"
      { success: false, error: 'Failed to process purchase.', type: :error }
    end

    # Handle media quickmenu response
    # @param char_instance [CharacterInstance]
    # @param context [Hash] quickmenu context
    # @param response_key [String] selected action
    # @return [Hash] result
    def handle_media_quickmenu(char_instance, context, response_key)
      # Map menu option to command
      cmd = case response_key.downcase
            when 'play' then 'media play'
            when 'pause' then 'media pause'
            when 'stop' then 'media stop'
            when 'status' then 'media status'
            when 'jukebox' then 'media player'
            when 'playlist' then 'media playlist'
            when 'share_screen' then 'media share screen'
            when 'share_tab' then 'media share tab'
            else "media #{response_key}"
            end

      result = Commands::Base::Registry.execute_command(char_instance, cmd)

      if result[:success]
        {
          success: true,
          message: result[:message],
          type: result[:type] || :message,
          data: result[:data]
        }
      else
        {
          success: false,
          error: result[:error] || result[:message],
          type: :error
        }
      end
    rescue StandardError => e
      warn "[InputInterceptorService] Media quickmenu error: #{e.message}"
      { success: false, error: 'Failed to process media action.', type: :error }
    end

    # Handle property quickmenu response
    # @param char_instance [CharacterInstance]
    # @param context [Hash] quickmenu context
    # @param response_key [String] selected action
    # @return [Hash] result
    def handle_property_quickmenu(char_instance, context, response_key)
      # Map menu option to command
      cmd = case response_key.downcase
            when 'list' then 'property list'
            when 'access' then 'property access'
            when 'lock' then 'property lock'
            when 'unlock' then 'property unlock'
            when 'lock_doors' then 'property lock doors'
            when 'unlock_doors' then 'property unlock doors'
            when 'grant' then 'property grant'
            when 'revoke' then 'property revoke'
            else "property #{response_key}"
            end

      result = Commands::Base::Registry.execute_command(char_instance, cmd)

      if result[:success]
        {
          success: true,
          message: result[:message],
          type: result[:type] || :message,
          data: result[:data]
        }
      else
        {
          success: false,
          error: result[:error] || result[:message],
          type: :error
        }
      end
    rescue StandardError => e
      warn "[InputInterceptorService] Property quickmenu error: #{e.message}"
      { success: false, error: 'Failed to process property action.', type: :error }
    end

    # Handle property grant quickmenu response
    # @param char_instance [CharacterInstance]
    # @param context [Hash] quickmenu context with characters array
    # @param response_key [String] numeric selection or 'q' to cancel
    # @return [Hash] result
    def handle_property_grant_quickmenu(char_instance, context, response_key)
      characters = context[:characters] || context['characters'] || []

      # Handle cancel
      if response_key.downcase == 'q'
        return {
          success: true,
          message: 'Cancelled.',
          type: :message
        }
      end

      # Numeric selection
      idx = response_key.to_i - 1
      if idx >= 0 && idx < characters.length
        char_data = characters[idx]
        char_name = char_data[:name] || char_data['name']

        result = Commands::Base::Registry.execute_command(char_instance, "property grant #{char_name}")

        if result[:success]
          {
            success: true,
            message: result[:message],
            type: result[:type] || :message,
            data: result[:data]
          }
        else
          {
            success: false,
            error: result[:error] || result[:message],
            type: :error
          }
        end
      else
        {
          success: false,
          error: "Invalid selection. Type 'property grant' to see options.",
          type: :error
        }
      end
    rescue StandardError => e
      warn "[InputInterceptorService] Property grant quickmenu error: #{e.message}"
      { success: false, error: 'Failed to grant access.', type: :error }
    end

    # Handle property revoke quickmenu response
    # @param char_instance [CharacterInstance]
    # @param context [Hash] quickmenu context with characters array
    # @param response_key [String] numeric selection or 'q' to cancel
    # @return [Hash] result
    def handle_property_revoke_quickmenu(char_instance, context, response_key)
      characters = context[:characters] || context['characters'] || []

      # Handle cancel
      if response_key.downcase == 'q'
        return {
          success: true,
          message: 'Cancelled.',
          type: :message
        }
      end

      # Numeric selection
      idx = response_key.to_i - 1
      if idx >= 0 && idx < characters.length
        char_data = characters[idx]
        char_name = char_data[:name] || char_data['name']

        result = Commands::Base::Registry.execute_command(char_instance, "property revoke #{char_name}")

        if result[:success]
          {
            success: true,
            message: result[:message],
            type: result[:type] || :message,
            data: result[:data]
          }
        else
          {
            success: false,
            error: result[:error] || result[:message],
            type: :error
          }
        end
      else
        {
          success: false,
          error: "Invalid selection. Type 'property revoke' to see options.",
          type: :error
        }
      end
    rescue StandardError => e
      warn "[InputInterceptorService] Property revoke quickmenu error: #{e.message}"
      { success: false, error: 'Failed to revoke access.', type: :error }
    end

    # Handle tickets main menu quickmenu response
    # @param char_instance [CharacterInstance]
    # @param context [Hash] quickmenu context
    # @param response_key [String] selected option key
    # @return [Hash] result
    def handle_tickets_quickmenu(char_instance, context, response_key)
      case response_key.downcase
      when 'list'
        result = Commands::Base::Registry.execute_command(char_instance, 'tickets list')
        format_command_result(result)
      when 'all'
        result = Commands::Base::Registry.execute_command(char_instance, 'tickets all')
        format_command_result(result)
      when 'new'
        result = Commands::Base::Registry.execute_command(char_instance, 'tickets new')
        format_command_result(result)
      when 'q'
        { success: true, message: 'Menu closed.', type: :message }
      else
        { success: false, error: "Unknown option: #{response_key}", type: :error }
      end
    rescue StandardError => e
      warn "[InputInterceptorService] Tickets quickmenu error: #{e.message}"
      { success: false, error: 'Failed to process tickets selection.', type: :error }
    end

    # Handle tickets list quickmenu response
    # @param char_instance [CharacterInstance]
    # @param context [Hash] quickmenu context with tickets array
    # @param response_key [String] ticket ID or action
    # @return [Hash] result
    def handle_tickets_list_quickmenu(char_instance, context, response_key)
      tickets = context[:tickets] || context['tickets'] || []

      case response_key.downcase
      when 'new'
        result = Commands::Base::Registry.execute_command(char_instance, 'tickets new')
        format_command_result(result)
      when 'q'
        { success: true, message: 'Menu closed.', type: :message }
      else
        # Numeric selection - view ticket
        ticket_id = response_key.to_i
        if ticket_id > 0
          result = Commands::Base::Registry.execute_command(char_instance, "tickets view #{ticket_id}")
          format_command_result(result)
        else
          { success: false, error: "Invalid selection. Type 'tickets' to see options.", type: :error }
        end
      end
    rescue StandardError => e
      warn "[InputInterceptorService] Tickets list quickmenu error: #{e.message}"
      { success: false, error: 'Failed to process ticket selection.', type: :error }
    end

    # Handle wardrobe main menu quickmenu response
    # @param char_instance [CharacterInstance]
    # @param context [Hash] quickmenu context
    # @param response_key [String] selected option key
    # @return [Hash] result
    def handle_wardrobe_quickmenu(char_instance, context, response_key)
      case response_key.downcase
      when 'list'
        result = Commands::Base::Registry.execute_command(char_instance, 'wardrobe list')
        format_command_result(result)
      when 'store'
        result = Commands::Base::Registry.execute_command(char_instance, 'wardrobe store')
        format_command_result(result)
      when 'retrieve'
        result = Commands::Base::Registry.execute_command(char_instance, 'wardrobe retrieve')
        format_command_result(result)
      when 'retrieve_all'
        result = Commands::Base::Registry.execute_command(char_instance, 'wardrobe retrieve all')
        format_command_result(result)
      when 'transfer'
        result = Commands::Base::Registry.execute_command(char_instance, 'wardrobe transfer')
        format_command_result(result)
      when 'status'
        result = Commands::Base::Registry.execute_command(char_instance, 'wardrobe status')
        format_command_result(result)
      when 'q'
        { success: true, message: 'Menu closed.', type: :message }
      else
        { success: false, error: "Unknown option: #{response_key}", type: :error }
      end
    rescue StandardError => e
      warn "[InputInterceptorService] Wardrobe quickmenu error: #{e.message}"
      { success: false, error: 'Failed to process wardrobe selection.', type: :error }
    end

    # Handle wardrobe store quickmenu response
    # @param char_instance [CharacterInstance]
    # @param context [Hash] quickmenu context with items array
    # @param response_key [String] item index or 'all'
    # @return [Hash] result
    def handle_wardrobe_store_quickmenu(char_instance, context, response_key)
      items = context[:items] || context['items'] || []

      case response_key.downcase
      when 'all'
        result = Commands::Base::Registry.execute_command(char_instance, 'wardrobe store all')
        format_command_result(result)
      when 'q'
        { success: true, message: 'Menu closed.', type: :message }
      else
        # Numeric selection
        idx = response_key.to_i - 1
        if idx >= 0 && idx < items.length
          item_name = items[idx][:name] || items[idx]['name']
          result = Commands::Base::Registry.execute_command(char_instance, "wardrobe store #{item_name}")
          format_command_result(result)
        else
          { success: false, error: "Invalid selection. Type 'wardrobe store' to see options.", type: :error }
        end
      end
    rescue StandardError => e
      warn "[InputInterceptorService] Wardrobe store quickmenu error: #{e.message}"
      { success: false, error: 'Failed to store item.', type: :error }
    end

    # Handle wardrobe retrieve quickmenu response
    # @param char_instance [CharacterInstance]
    # @param context [Hash] quickmenu context with items array
    # @param response_key [String] item index or 'all'
    # @return [Hash] result
    def handle_wardrobe_retrieve_quickmenu(char_instance, context, response_key)
      items = context[:items] || context['items'] || []

      case response_key.downcase
      when 'all'
        result = Commands::Base::Registry.execute_command(char_instance, 'wardrobe retrieve all')
        format_command_result(result)
      when 'q'
        { success: true, message: 'Menu closed.', type: :message }
      else
        # Numeric selection
        idx = response_key.to_i - 1
        if idx >= 0 && idx < items.length
          item_name = items[idx][:name] || items[idx]['name']
          result = Commands::Base::Registry.execute_command(char_instance, "wardrobe retrieve #{item_name}")
          format_command_result(result)
        else
          { success: false, error: "Invalid selection. Type 'wardrobe retrieve' to see options.", type: :error }
        end
      end
    rescue StandardError => e
      warn "[InputInterceptorService] Wardrobe retrieve quickmenu error: #{e.message}"
      { success: false, error: 'Failed to retrieve item.', type: :error }
    end

    # Handle wardrobe transfer quickmenu response
    # @param char_instance [CharacterInstance]
    # @param context [Hash] quickmenu context with locations array
    # @param response_key [String] location index or 'status'
    # @return [Hash] result
    def handle_wardrobe_transfer_quickmenu(char_instance, context, response_key)
      locations = context[:locations] || context['locations'] || []

      case response_key.downcase
      when 'status'
        result = Commands::Base::Registry.execute_command(char_instance, 'wardrobe status')
        format_command_result(result)
      when 'q'
        { success: true, message: 'Menu closed.', type: :message }
      else
        # Numeric selection
        idx = response_key.to_i - 1
        if idx >= 0 && idx < locations.length
          room_name = locations[idx][:room_name] || locations[idx]['room_name']
          result = Commands::Base::Registry.execute_command(char_instance, "wardrobe transfer from #{room_name}")
          format_command_result(result)
        else
          { success: false, error: "Invalid selection. Type 'wardrobe transfer' to see options.", type: :error }
        end
      end
    rescue StandardError => e
      warn "[InputInterceptorService] Wardrobe transfer quickmenu error: #{e.message}"
      { success: false, error: 'Failed to initiate transfer.', type: :error }
    end

    # Handle timeline quickmenu response
    # @param char_instance [CharacterInstance]
    # @param context [Hash] quickmenu context
    # @param response_key [String] selected option key
    # @return [Hash] result
    def handle_timeline_quickmenu(char_instance, context, response_key)
      stage = context[:stage] || context['stage']

      case stage
      when 'main_menu'
        handle_timeline_main_menu(char_instance, response_key)
      when 'enter_select'
        handle_timeline_enter_select(char_instance, context, response_key)
      when 'delete_select'
        handle_timeline_delete_select(char_instance, context, response_key)
      else
        { success: false, error: 'Unknown timeline menu stage.', type: :error }
      end
    rescue StandardError => e
      warn "[InputInterceptorService] Timeline quickmenu error: #{e.class}: #{e.message}"
      warn e.backtrace.first(5).join("\n")
      { success: false, error: 'Failed to process timeline selection.', type: :error }
    end

    # Handle timeline main menu selections
    def handle_timeline_main_menu(char_instance, response_key)
      case response_key.downcase
      when 'view'
        # Call the list_timelines method from the command
        result = list_timelines_for(char_instance)
        { success: true, message: result, type: :message }
      when 'enter'
        # Show enter timeline menu
        show_timeline_enter_menu(char_instance)
      when 'create'
        # Show create snapshot form
        show_timeline_create_form(char_instance)
      when 'leave'
        # Leave current timeline
        leave_current_timeline(char_instance)
      when 'info'
        # Show timeline info
        show_timeline_info(char_instance)
      when 'delete'
        # Show delete menu
        show_timeline_delete_menu(char_instance)
      when 'q'
        { success: true, message: 'Menu closed.', type: :message }
      else
        { success: false, error: "Unknown option: #{response_key}", type: :error }
      end
    end

    # Handle timeline enter selection
    def handle_timeline_enter_select(char_instance, context, response_key)
      snapshots = context[:snapshots] || context['snapshots'] || []

      case response_key.downcase
      when 'h'
        # Show historical timeline form
        show_timeline_historical_form(char_instance)
      when 'q'
        { success: true, message: 'Menu closed.', type: :message }
      else
        # Numeric selection
        idx = response_key.to_i - 1
        if idx >= 0 && idx < snapshots.length
          snapshot_id = snapshots[idx][:id] || snapshots[idx]['id']
          snapshot = CharacterSnapshot[snapshot_id]

          unless snapshot
            return { success: false, error: 'Snapshot not found.', type: :error }
          end

          character = char_instance.character
          unless snapshot.can_enter?(character)
            return { success: false, error: "You weren't present when this snapshot was created.", type: :error }
          end

          instance = TimelineService.enter_snapshot_timeline(character, snapshot)

          lines = []
          lines << "You've entered the timeline '#{snapshot.name}'."
          lines << ""
          lines << "<h4>Timeline Restrictions</h4>"
          lines << "- Deaths are disabled"
          lines << "- Prisoner mechanics are disabled"
          lines << "- XP gain is disabled"
          lines << "- Room modifications are disabled"
          lines << ""
          lines << "Actions here won't affect your present self."
          lines << "Type 'timeline' and select 'Leave Timeline' to return to the present."

          { success: true, message: lines.join("\n"), type: :message, data: { instance_id: instance.id } }
        else
          { success: false, error: "Invalid selection.", type: :error }
        end
      end
    rescue TimelineService::NotAllowedError => e
      { success: false, error: e.message, type: :error }
    rescue StandardError => e
      warn "[InputInterceptorService] Timeline enter error: #{e.message}"
      { success: false, error: 'Failed to enter timeline.', type: :error }
    end

    # Handle timeline delete selection
    def handle_timeline_delete_select(char_instance, context, response_key)
      snapshots = context[:snapshots] || context['snapshots'] || []

      case response_key.downcase
      when 'q'
        { success: true, message: 'Menu closed.', type: :message }
      else
        idx = response_key.to_i - 1
        if idx >= 0 && idx < snapshots.length
          snapshot_id = snapshots[idx][:id] || snapshots[idx]['id']
          snapshot = CharacterSnapshot[snapshot_id]

          unless snapshot
            return { success: false, error: 'Snapshot not found.', type: :error }
          end

          unless snapshot.character_id == char_instance.character.id
            return { success: false, error: 'You can only delete your own snapshots.', type: :error }
          end

          snapshot_name = snapshot.name
          TimelineService.delete_snapshot(snapshot)

          { success: true, message: "Deleted snapshot '#{snapshot_name}'.", type: :message }
        else
          { success: false, error: "Invalid selection.", type: :error }
        end
      end
    rescue TimelineService::TimelineError => e
      { success: false, error: e.message, type: :error }
    rescue StandardError => e
      warn "[InputInterceptorService] Timeline delete error: #{e.message}"
      { success: false, error: 'Failed to delete snapshot.', type: :error }
    end

    # Helper: List timelines for a character
    def list_timelines_for(char_instance)
      character = char_instance.character
      snapshots = TimelineService.snapshots_for(character)
      accessible = TimelineService.accessible_snapshots_for(character)
      active_instances = TimelineService.active_timelines_for(character)

      lines = []
      lines << "<h3>Your Timelines</h3>"

      if snapshots.any?
        lines << ""
        lines << "Your Snapshots:"
        snapshots.each do |snap|
          active = active_instances.any? { |ci| ci.source_snapshot_id == snap.id && ci.online }
          status = active ? " [ACTIVE]" : ""
          lines << "  - #{snap.name}#{status} (#{snap.snapshot_taken_at.strftime('%Y-%m-%d %H:%M')})"
          lines << "    #{snap.description}" if snap.description && !snap.description.to_s.strip.empty?
        end
      end

      other_accessible = accessible - snapshots
      if other_accessible.any?
        lines << ""
        lines << "Snapshots You Can Join:"
        other_accessible.each do |snap|
          creator = snap.character&.full_name || "Unknown"
          active = active_instances.any? { |ci| ci.source_snapshot_id == snap.id && ci.online }
          status = active ? " [ACTIVE]" : ""
          lines << "  - #{snap.name}#{status} by #{creator}"
        end
      end

      if active_instances.any?
        lines << ""
        lines << "Your Active Timeline Instances:"
        active_instances.each do |ci|
          timeline = ci.timeline
          online_status = ci.online ? "[ONLINE]" : "[OFFLINE]"
          lines << "  - #{timeline&.display_name || 'Unknown'} #{online_status}"
        end
      end

      if snapshots.empty? && other_accessible.empty? && active_instances.empty?
        lines << ""
        lines << "You have no snapshots or active timelines."
      end

      lines << ""
      lines << "Type 'timeline' to open the timeline menu."

      lines.join("\n")
    end

    # Helper: Show timeline enter menu
    def show_timeline_enter_menu(char_instance)
      if char_instance.in_past_timeline?
        return { success: false, error: "You're already in a past timeline. Leave first.", type: :error }
      end

      character = char_instance.character
      own_snapshots = TimelineService.snapshots_for(character)
      other_snapshots = TimelineService.accessible_snapshots_for(character) - own_snapshots
      all_snapshots = own_snapshots + other_snapshots

      options = []
      all_snapshots.each_with_index do |snap, idx|
        owner_info = snap.character_id == character.id ? '' : " (by #{snap.character&.full_name || 'Unknown'})"
        options << {
          key: (idx + 1).to_s,
          label: snap.name,
          description: "#{snap.snapshot_taken_at.strftime('%Y-%m-%d')}#{owner_info}"
        }
      end

      options << { key: 'h', label: 'Historical Timeline', description: 'Enter a specific year and zone' }
      options << { key: 'q', label: 'Cancel', description: 'Return to main menu' }

      snapshot_data = all_snapshots.map { |s| { id: s.id, name: s.name } }

      interaction_id = SecureRandom.uuid
      menu_data = {
        type: 'quickmenu',
        interaction_id: interaction_id,
        prompt: 'Select a timeline to enter:',
        options: options,
        context: { command: 'timeline', stage: 'enter_select', snapshots: snapshot_data },
        created_at: Time.now.iso8601
      }

      OutputHelper.store_agent_interaction(char_instance, interaction_id, menu_data)

      {
        success: true,
        type: :quickmenu,
        prompt: 'Select a timeline to enter:',
        options: options,
        interaction_id: interaction_id,
        context: { command: 'timeline', stage: 'enter_select', snapshots: snapshot_data }
      }
    end

    # Helper: Show create snapshot form
    def show_timeline_create_form(char_instance)
      if char_instance.in_past_timeline?
        return { success: false, error: "You cannot create snapshots while in a past timeline.", type: :error }
      end

      interaction_id = SecureRandom.uuid
      form_data = {
        type: 'form',
        interaction_id: interaction_id,
        title: 'Create Snapshot',
        description: "Capture this moment to return to later. Others present can also join this timeline.",
        fields: [
          { name: 'name', label: 'Snapshot Name', type: 'text', required: true, placeholder: 'e.g., "Before the battle"', max_length: 100 },
          { name: 'description', label: 'Description (optional)', type: 'textarea', required: false, placeholder: 'A brief note about this moment', max_length: 500 }
        ],
        context: { command: 'timeline', stage: 'create_snapshot' },
        created_at: Time.now.iso8601
      }

      OutputHelper.store_agent_interaction(char_instance, interaction_id, form_data)

      {
        success: true,
        type: :form,
        title: 'Create Snapshot',
        fields: form_data[:fields],
        interaction_id: interaction_id,
        context: { command: 'timeline', stage: 'create_snapshot' }
      }
    end

    # Helper: Leave current timeline
    def leave_current_timeline(char_instance)
      unless char_instance.in_past_timeline?
        return { success: false, error: "You're not in a past timeline.", type: :error }
      end

      timeline_name = char_instance.timeline_display_name
      TimelineService.leave_timeline(char_instance)

      lines = []
      lines << "You've left the timeline '#{timeline_name}'."
      lines << ""
      lines << "You've returned to the present."

      { success: true, message: lines.join("\n"), type: :message }
    end

    # Helper: Show timeline info
    def show_timeline_info(char_instance)
      unless char_instance.in_past_timeline?
        return { success: false, error: "You're not in a past timeline.", type: :error }
      end

      timeline = char_instance.timeline
      lines = []
      lines << "<h3>Current Timeline</h3>"
      lines << "Name: #{timeline.display_name}"
      lines << "Type: #{timeline.timeline_type.capitalize}"

      if timeline.historical?
        lines << "Year: #{timeline.year}"
        lines << "Zone: #{timeline.zone&.name}"
      elsif timeline.snapshot?
        snap = timeline.snapshot
        lines << "Snapshot by: #{snap&.character&.full_name}"
        lines << "Taken at: #{snap&.snapshot_taken_at&.strftime('%Y-%m-%d %H:%M')}"
      end

      lines << ""
      lines << "Restrictions:"
      lines << "  No Death: #{timeline.no_death? ? 'Yes' : 'No'}"
      lines << "  No Prisoner: #{timeline.no_prisoner? ? 'Yes' : 'No'}"
      lines << "  No XP: #{timeline.no_xp? ? 'Yes' : 'No'}"
      lines << "  Rooms Read-Only: #{timeline.rooms_read_only? ? 'Yes' : 'No'}"

      { success: true, message: lines.join("\n"), type: :message }
    end

    # Helper: Show delete menu
    def show_timeline_delete_menu(char_instance)
      character = char_instance.character
      snapshots = TimelineService.snapshots_for(character)

      if snapshots.empty?
        return { success: false, error: "You have no snapshots to delete.", type: :error }
      end

      options = snapshots.each_with_index.map do |snap, idx|
        { key: (idx + 1).to_s, label: snap.name, description: snap.snapshot_taken_at.strftime('%Y-%m-%d %H:%M') }
      end
      options << { key: 'q', label: 'Cancel', description: 'Return to main menu' }

      snapshot_data = snapshots.map { |s| { id: s.id, name: s.name } }

      interaction_id = SecureRandom.uuid
      menu_data = {
        type: 'quickmenu',
        interaction_id: interaction_id,
        prompt: 'Select a snapshot to delete:',
        options: options,
        context: { command: 'timeline', stage: 'delete_select', snapshots: snapshot_data },
        created_at: Time.now.iso8601
      }

      OutputHelper.store_agent_interaction(char_instance, interaction_id, menu_data)

      {
        success: true,
        type: :quickmenu,
        prompt: 'Select a snapshot to delete:',
        options: options,
        interaction_id: interaction_id,
        context: { command: 'timeline', stage: 'delete_select', snapshots: snapshot_data }
      }
    end

    # Helper: Show historical timeline form
    def show_timeline_historical_form(char_instance)
      if char_instance.in_past_timeline?
        return { success: false, error: "You're already in a past timeline. Leave first.", type: :error }
      end

      interaction_id = SecureRandom.uuid
      form_data = {
        type: 'form',
        interaction_id: interaction_id,
        title: 'Enter Historical Timeline',
        description: "Travel back in time to a specific year and location.",
        fields: [
          { name: 'year', label: 'Year', type: 'number', required: true, placeholder: 'e.g., 1892', min: 1, max: 9999 },
          { name: 'zone', label: 'Zone Name', type: 'text', required: true, placeholder: 'e.g., Downtown' }
        ],
        context: { command: 'timeline', stage: 'historical_entry' },
        created_at: Time.now.iso8601
      }

      OutputHelper.store_agent_interaction(char_instance, interaction_id, form_data)

      {
        success: true,
        type: :form,
        title: 'Enter Historical Timeline',
        fields: form_data[:fields],
        interaction_id: interaction_id,
        context: { command: 'timeline', stage: 'historical_entry' }
      }
    end

    # Check if input is a simple activity shortcut
    # Allows typing just a number when in an activity to choose that action
    # @param char_instance [CharacterInstance]
    # @param input [String]
    # @return [Hash, nil]
    def try_activity_shortcut(char_instance, input)
      # Only intercept simple numeric input (1, 2, 3, etc.)
      return nil unless input.match?(/^\d+$/)

      # Check if character is in an activity
      room = char_instance.current_room
      return nil unless room

      instance = ActivityService.running_activity(room)
      return nil unless instance

      participant = ActivityService.participant_for(instance, char_instance)
      return nil unless participant
      return nil unless participant.active?

      # User typed a number while in an activity - treat as action choice
      round = instance.current_round
      return nil unless round

      actions = if round.respond_to?(:all_actions)
                  round.all_actions
                else
                  round.available_actions
                end
      idx = input.to_i - 1

      if idx >= 0 && idx < actions.length
        action = actions[idx]

        # Submit the choice
        ActivityService.submit_choice(
          participant,
          action_id: action.id
        )

        {
          success: true,
          message: "You chose: #{action.choice_text}\nUse 'activity willpower <0-2>' to spend willpower dice, or wait for the round to resolve.",
          type: :message,
          data: { action_id: action.id }
        }
      else
        # Invalid number - show available actions
        lines = ['Invalid action number. Available actions:']
        actions.each_with_index do |a, i|
          lines << "  #{i + 1}. #{a.choice_text}"
        end
        {
          success: false,
          error: lines.join("\n"),
          type: :error
        }
      end
    rescue StandardError => e
      warn "[InputInterceptorService] Activity shortcut error: #{e.message}"
      nil # Fall through to normal command processing
    end

    # Handle cards quickmenu response
    # @param char_instance [CharacterInstance]
    # @param context [Hash] quickmenu context
    # @param response_key [String] selected option
    # @return [Hash] result
    def handle_cards_quickmenu(char_instance, context, response_key)
      result = CardsQuickmenuHandler.handle_response(char_instance, context, response_key.to_s)

      if result.nil?
        { success: true, message: 'Card action complete.', type: :message }
      elsif result[:type] == :quickmenu
        # Store the follow-up quickmenu as a new interaction for MCP agents
        interaction_id = SecureRandom.uuid
        OutputHelper.store_agent_interaction(
          char_instance,
          interaction_id,
          {
            interaction_id: interaction_id,
            type: 'quickmenu',
            prompt: result[:prompt],
            options: result[:options],
            context: result[:context],
            created_at: Time.now.iso8601
          }
        )

        {
          success: true,
          type: :quickmenu,
          display_type: :quickmenu,
          message_type: 'quickmenu',
          prompt: result[:prompt],
          options: result[:options],
          context: result[:context],
          message: result[:message],
          data: {
            interaction_id: interaction_id,
            prompt: result[:prompt],
            options: result[:options],
            context: result[:context],
            result_data: result[:data]
          },
          interaction_id: interaction_id
        }
      else
        result
      end
    rescue StandardError => e
      warn "[InputInterceptorService] Cards quickmenu error: #{e.message}"
      { success: false, error: 'Failed to process card action.', type: :error }
    end

    # Handle fabricate command quickmenu responses (delivery choice and deck selection)
    # @param char_instance [CharacterInstance]
    # @param context [Hash] quickmenu context
    # @param response_key [String] selected option key
    # @return [Hash] result
    def handle_fabricate_quickmenu(char_instance, context, response_key)
      action = context[:action] || context['action']

      case action
      when 'fabricate_delivery_choice'
        handle_fabricate_delivery_choice(char_instance, context, response_key)
      when 'fabricate_deck'
        handle_fabricate_deck_choice(char_instance, context, response_key)
      else
        { success: false, error: 'Unknown fabrication action.', type: :error }
      end
    rescue StandardError => e
      warn "[InputInterceptorService] Fabricate quickmenu error: #{e.message}"
      { success: false, error: 'Failed to process fabrication action.', type: :error }
    end

    # Handle delivery method selection for fabrication orders
    def handle_fabricate_delivery_choice(char_instance, context, response_key)
      pattern_id = context[:pattern_id] || context['pattern_id']
      pattern = Pattern[pattern_id]
      return { success: false, error: 'Pattern not found.', type: :error } unless pattern

      case response_key
      when 'cancel', '3'
        { success: true, message: 'Fabrication cancelled.', type: :message }
      when 'pickup', '1'
        order = FabricationService.start_fabrication(
          char_instance, pattern,
          delivery_method: 'pickup',
          delivery_room: nil
        )
        time = FabricationService.calculate_time(pattern)
        message = FabricationService.crafting_started_message(pattern, time)
        {
          success: true, message: message,
          type: :fabrication_started,
          data: {
            action: 'fabrication_started', order_id: order.id,
            pattern_id: pattern.id, pattern_name: pattern.description,
            delivery_method: 'pickup',
            completes_at: order.completes_at&.iso8601,
            time_display: order.time_remaining_display
          }
        }
      when 'delivery', '2'
        home_room_id = context[:home_room_id] || context['home_room_id']
        home_room = Room[home_room_id]
        return { success: false, error: "You don't have a home to deliver to.", type: :error } unless home_room

        order = FabricationService.start_fabrication(
          char_instance, pattern,
          delivery_method: 'delivery',
          delivery_room: home_room
        )
        time = FabricationService.calculate_time(pattern)
        message = FabricationService.delivery_started_message(pattern, home_room, time)
        {
          success: true, message: message,
          type: :fabrication_started,
          data: {
            action: 'fabrication_started', order_id: order.id,
            pattern_id: pattern.id, pattern_name: pattern.description,
            delivery_method: 'delivery', delivery_room_name: home_room.name,
            completes_at: order.completes_at&.iso8601,
            time_display: order.time_remaining_display
          }
        }
      else
        { success: false, error: 'Invalid selection.', type: :error }
      end
    end

    # Handle deck pattern selection for fabrication
    def handle_fabricate_deck_choice(char_instance, context, response_key)
      match_ids = context[:match_ids] || context['match_ids'] || []
      idx = response_key.to_i - 1

      if idx >= 0 && idx < match_ids.length
        pattern = DeckPattern[match_ids[idx]]
      else
        pattern = DeckPattern[response_key.to_i]
      end

      return { success: false, error: 'Deck pattern not found.', type: :error } unless pattern

      deck = pattern.create_deck_for(char_instance)
      {
        success: true,
        message: "You conjure #{pattern.name} with #{deck.remaining_count} cards.",
        type: :message,
        data: {
          action: 'fabricate_deck', deck_id: deck.id,
          pattern_id: pattern.id, pattern_name: pattern.name,
          card_count: deck.remaining_count
        }
      }
    end

    # Handle delve quickmenu response - execute the corresponding delve subcommand
    # @param char_instance [CharacterInstance]
    # @param context [Hash] quickmenu context
    # @param response_key [String] selected option key
    # @return [Hash] result
    def handle_travel_choice_quickmenu(char_instance, context, response_key)
      destination_id = context[:destination_id] || context['destination_id']
      destination_name = context[:destination_name] || context['destination_name']
      adverb = context[:adverb] || context['adverb'] || 'walk'

      destination = Room[destination_id]
      unless destination
        return { success: false, message: "Destination no longer available.", type: :message }
      end

      case response_key.downcase
      when 'walk'
        # Use move_to_room with skip_autodrive to avoid re-prompting
        result = MovementService.move_to_room(char_instance, destination, adverb: adverb, skip_autodrive: true)
        { success: result.success, message: result.message, type: :action }
      when 'drive'
        result = Commands::Base::Registry.execute_command(char_instance, "drive to #{destination_name}")
        format_command_result(result)
      when 'taxi'
        result = Commands::Base::Registry.execute_command(char_instance, "taxi to #{destination_name}")
        format_command_result(result)
      else
        { success: false, message: "Unknown travel option: #{response_key}", type: :message }
      end
    end

    def handle_delve_quickmenu(char_instance, context, response_key)
      command_map = {
        'n' => 'delve north', 'e' => 'delve east', 's' => 'delve south', 'w' => 'delve west',
        'd' => 'delve down', 'f' => 'delve fight', 'g' => 'delve grab',
        'p' => 'delve solve', 'r' => 'delve recover', 'o' => 'delve focus',
        'm' => 'delve map', 'x' => 'delve flee'
      }

      cmd = command_map[response_key.downcase]

      unless cmd
        return {
          success: false,
          message: "Unknown delve option: #{response_key}",
          type: :message
        }
      end

      result = Commands::Base::Registry.execute_command(char_instance, cmd)
      format_command_result(result)
    end

    # Format a command execution result for quickmenu response
    # @param result [Hash] command execution result
    # @return [Hash] formatted result
    def format_command_result(result)
      return if result.nil?

      {
        success: result[:success],
        message: result[:message],
        type: result[:type] || :message,
        data: result[:data]
      }.compact
    end

    # Dispatch quickmenu responses to command classes that implement their own
    # quickmenu handlers.
    def dispatch_command_quickmenu_handler(char_instance, command_name, context, response_key)
      return nil if command_name.nil? || command_name.to_s.strip.empty?

      command_class = Commands::Base::Registry.find_by_context(command_name)
      return nil unless command_class

      command = command_class.new(char_instance)

      if command.respond_to?(:handle_quickmenu_response, true)
        result = command.send(:handle_quickmenu_response, response_key.to_s, context)
        normalize_interaction_response(result)
      end
    rescue StandardError => e
      warn "[InputInterceptorService] Command quickmenu dispatch error for '#{command_name}': #{e.message}"
      { success: false, error: 'Failed to process menu selection.', type: :error }
    end

    def normalize_interaction_response(result)
      return result unless result.is_a?(Hash)
      return result unless result[:type] == :quickmenu && result[:data].is_a?(Hash)

      prompt = result[:prompt] || result[:data][:prompt] || result[:data]['prompt']
      options = result[:options] || result[:data][:options] || result[:data]['options']
      context = result[:context] || result[:data][:context] || result[:data]['context']

      result.merge(
        prompt: prompt,
        options: options,
        context: context
      )
    end
  end
end
