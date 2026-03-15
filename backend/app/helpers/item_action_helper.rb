# frozen_string_literal: true

# Helper for standardized item actions (drop, get, wear, remove, hold, etc.)
# Reduces duplication across inventory/clothing commands
module ItemActionHelper
  # Parse input that may contain multiple item names separated by commas or "and"
  # Examples:
  #   "hat" => ["hat"]
  #   "hat, scarf, gloves" => ["hat", "scarf", "gloves"]
  #   "hat and scarf" => ["hat", "scarf"]
  #   "hat, scarf, and gloves" => ["hat", "scarf", "gloves"]
  # @param input [String] The user input
  # @return [Array<String>] Array of individual item names
  def parse_multi_item_input(input)
    return [] if input.nil? || input.strip.empty?

    # Split by comma first, then handle "and" in each part
    parts = input.split(/,/).map(&:strip).reject(&:empty?)

    # For each part, split by " and " (with spaces to avoid splitting "hand")
    # Also handle the case where part starts with "and " (from ", and gloves" pattern)
    items = parts.flat_map do |part|
      # Strip leading "and " from part (handles ", and gloves" case)
      part = part.sub(/^and\s+/i, '')
      part.split(/\s+and\s+/i).map(&:strip).reject(&:empty?)
    end

    items.uniq
  end
  # Perform a single item action with standard broadcasting pattern
  # @param item [Item] The item to act on
  # @param action_method [Symbol] Method to call on item (e.g., :drop!, :wear!, :hold!)
  # @param action_name [String] Name for data hash (e.g., 'drop', 'wear')
  # @param self_verb [String] Verb for self message (e.g., "drop", "put on")
  # @param other_verb [String] Verb for broadcast message (e.g., "drops", "puts on")
  # @param preposition [String] Optional preposition (e.g., "up" for "picks up")
  # @return [Hash] Success result
  def perform_item_action(item:, action_method:, action_name:, self_verb:, other_verb:, preposition: nil)
    # Call the action method on item (wear!, hold!, remove!, etc.)
    if action_method.is_a?(Proc)
      action_method.call(item)
    else
      item.send(action_method)
    end

    # Build messages
    item_ref = preposition ? "#{preposition} #{item.name}" : item.name
    self_msg = "You #{self_verb} #{item_ref}."
    other_msg = "#{character.full_name} #{other_verb} #{item_ref}."

    broadcast_to_room(other_msg, exclude_character: character_instance)

    success_result(
      self_msg,
      type: :message,
      data: { action: action_name, item_id: item.id, item_name: item.name }
    )
  end

  # Perform action on all items in a collection
  # @param items [Array<Item>] Items to act on
  # @param action_method [Symbol, Proc] Method to call on each item
  # @param action_name [String] Action name for data (e.g., 'drop_all')
  # @param self_verb [String] Verb for self message (e.g., "drop")
  # @param other_verb [String] Verb for broadcast (e.g., "drops")
  # @param empty_error [String] Error message if items empty
  # @return [Hash] Success or error result
  def perform_bulk_action(items:, action_method:, action_name:, self_verb:, other_verb:, empty_error:)
    return error_result(empty_error) if items.empty?

    collected_names = []
    items.each do |item|
      if action_method.is_a?(Proc)
        action_method.call(item)
      else
        item.send(action_method)
      end
      collected_names << item.name
    end

    broadcast_to_room(
      "#{character.full_name} #{other_verb} several items.",
      exclude_character: character_instance
    )

    success_result(
      "You #{self_verb} #{collected_names.join(', ')}.",
      type: :message,
      data: { action: action_name, items: collected_names }
    )
  end

  # Handle 'all' variant with fallback to single item
  # @param input [String] The user input (may be 'all' or item name)
  # @param all_handler [Proc] Handler for 'all' case
  # @param single_handler [Proc] Handler for single item case
  # @return [Hash] Result from appropriate handler
  def handle_all_or_single(input, all_handler:, single_handler:)
    if input.to_s.strip.downcase == 'all'
      all_handler.call
    else
      single_handler.call(input)
    end
  end

  # Perform action on multiple items specified by user
  # Resolves each item name, performs action on matches, reports results
  # @param input [String] Comma/and-separated item names (e.g., "hat, scarf, gloves")
  # @param candidates [Array<Item>] Items to search in
  # @param action_method [Symbol, Proc] Method to call on each item
  # @param action_name [String] Action name for data (e.g., 'wear')
  # @param self_verb [String] Verb for self message (e.g., "put on")
  # @param other_verb [String] Verb for broadcast (e.g., "puts on")
  # @param not_found_error [String] Error template for not found (use %{input})
  # @param check_condition [Proc, nil] Optional condition check for each item (returns error string or nil)
  # @return [Hash] Success result with all processed items, or error if none found
  def perform_multi_item_action(input:, candidates:, action_method:, action_name:, self_verb:, other_verb:,
                                 not_found_error: "You don't have '%{input}'.",
                                 check_condition: nil)
    item_names = parse_multi_item_input(input)
    return error_result("Please specify what to #{action_name}.") if item_names.empty?

    # If only one item, delegate to standard single-item flow
    if item_names.length == 1
      return item_action_with_disambiguation(
        input: item_names.first,
        candidates: candidates,
        action_method: action_method,
        action_name: action_name,
        self_verb: self_verb,
        other_verb: other_verb,
        not_found_error: not_found_error
      )
    end

    # Multiple items - process each one
    successes = []
    failures = []

    item_names.each do |item_name|
      # Find the item
      item = TargetResolverService.resolve(
        query: item_name,
        candidates: candidates,
        name_field: :name
      )

      unless item
        failures << { name: item_name, reason: not_found_error % { input: item_name } }
        next
      end

      # Check condition if provided
      if check_condition
        error_msg = check_condition.call(item)
        if error_msg
          failures << { name: item.name, reason: error_msg }
          next
        end
      end

      # Perform the action
      if action_method.is_a?(Proc)
        action_method.call(item)
      else
        item.send(action_method)
      end

      successes << item
    end

    # Build result
    if successes.empty?
      # All failed - return first error
      return error_result(failures.first[:reason])
    end

    # Build success message
    success_names = successes.map(&:name)
    broadcast_to_room(
      "#{character.full_name} #{other_verb} #{success_names.join(', ')}.",
      exclude_character: character_instance
    )

    message = "You #{self_verb} #{success_names.join(', ')}."

    # Add failure notes if any
    if failures.any?
      failure_notes = failures.map { |f| "#{f[:name]}: #{f[:reason]}" }.join('; ')
      message += "\n(Could not process: #{failure_notes})"
    end

    success_result(
      message,
      type: :message,
      data: {
        action: action_name,
        items: success_names,
        item_ids: successes.map(&:id),
        failed: failures.map { |f| f[:name] }
      }
    )
  end

  # Standard item action with disambiguation support
  # Handles: find item -> resolve with menu -> perform action
  # @param input [String] Item name to search for
  # @param candidates [Array<Item>] Items to search in
  # @param action_method [Symbol] Method to call on found item
  # @param action_name [String] Name for data hash
  # @param self_verb [String] Verb for self message
  # @param other_verb [String] Verb for broadcast
  # @param not_found_error [String] Error if no item found (use %{input} for substitution)
  # @param disambiguation_prompt [String] Prompt for disambiguation (use %{input} for substitution)
  # @param preposition [String] Optional preposition for messages
  # @return [Hash] Result
  def item_action_with_disambiguation(input:, candidates:, action_method:, action_name:, self_verb:, other_verb:,
                                      not_found_error: "You don't have '%{input}'.",
                                      disambiguation_prompt: "Which '%{input}' do you want?",
                                      preposition: nil)
    result = resolve_item_with_menu(input, candidates)

    if result[:disambiguation]
      return disambiguation_result(result[:result], disambiguation_prompt % { input: input })
    end

    if result[:error]
      return error_result(result[:error] || not_found_error % { input: input })
    end

    perform_item_action(
      item: result[:match],
      action_method: action_method,
      action_name: action_name,
      self_verb: self_verb,
      other_verb: other_verb,
      preposition: preposition
    )
  end

  # Complete item command flow with empty input menu, 'all' handling, and single/multi item action
  # @param input [String] User input
  # @param items_getter [Proc] Proc that returns items collection
  # @param action_method [Symbol] Method to call on item
  # @param action_name [String] Action name for data
  # @param menu_prompt [String] Prompt for empty input menu
  # @param self_verb [String] Verb for self message
  # @param other_verb [String] Verb for broadcast
  # @param empty_error [String] Error when no items available
  # @param not_found_error [String] Error when item not found (use %{input})
  # @param allow_all [Boolean] Whether to support 'all' keyword
  # @param allow_multiple [Boolean] Whether to support comma/and-separated item lists
  # @param description_field [Symbol, Proc] Field for menu item descriptions
  # @return [Hash] Result
  def standard_item_command(input:, items_getter:, action_method:, action_name:, menu_prompt:,
                            self_verb:, other_verb:, empty_error:, not_found_error: nil,
                            allow_all: false, allow_multiple: false, description_field: :item_type, preposition: nil)
    items = items_getter.call

    # Empty items check
    return error_result(empty_error) if items.empty?

    # No input - show menu
    if blank?(input)
      return item_selection_menu(items, menu_prompt, command: action_name, description_field: description_field)
    end

    input = input.strip

    # Handle 'all' keyword
    if allow_all && input.downcase == 'all'
      return perform_bulk_action(
        items: items,
        action_method: action_method,
        action_name: "#{action_name}_all",
        self_verb: self_verb,
        other_verb: "#{other_verb.chomp('s')}s",
        empty_error: empty_error
      )
    end

    # Check for multiple items (contains comma or " and ")
    if allow_multiple && (input.include?(',') || input.match?(/\s+and\s+/i))
      return perform_multi_item_action(
        input: input,
        candidates: items,
        action_method: action_method,
        action_name: action_name,
        self_verb: self_verb,
        other_verb: other_verb,
        not_found_error: not_found_error || "You don't have '%{input}'."
      )
    end

    # Single item action with disambiguation
    item_action_with_disambiguation(
      input: input,
      candidates: items,
      action_method: action_method,
      action_name: action_name,
      self_verb: self_verb,
      other_verb: other_verb,
      not_found_error: not_found_error || "You don't have '#{input}'.",
      preposition: preposition
    )
  end
end
