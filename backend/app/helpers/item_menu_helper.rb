# frozen_string_literal: true

# Helper for building standardized item selection menus
# Reduces duplication across inventory/clothing/equipment commands
module ItemMenuHelper
  # Build a quickmenu for selecting an item from a list
  # @param items [Array<Item>] The items to display
  # @param prompt [String] The menu prompt (e.g., "What would you like to drop?")
  # @param command [String] The command name for context
  # @param description_field [Symbol, Proc] Field name or proc for item description
  # @param context [Hash] Additional context data
  # @return [Hash] The quickmenu result
  def item_selection_menu(items, prompt, command:, description_field: :item_type, context: {})
    options = items.each_with_index.map do |item, idx|
      description = if description_field.is_a?(Proc)
                      description_field.call(item)
                    elsif description_field && item.respond_to?(description_field)
                      item.send(description_field)
                    else
                      'item'
                    end

      {
        key: (idx + 1).to_s,
        label: item.name,
        description: description || 'item'
      }
    end

    options << { key: 'q', label: 'Cancel', description: 'Close menu' }

    item_data = items.map { |i| { id: i.id, name: i.name } }

    create_quickmenu(
      character_instance,
      prompt,
      options,
      context: {
        command: command,
        stage: 'select_item',
        items: item_data
      }.merge(context)
    )
  end

  # Build a quickmenu for selecting a character from a list
  # @param characters [Array<CharacterInstance>] The characters to display
  # @param prompt [String] The menu prompt
  # @param command [String] The command name for context
  # @param context [Hash] Additional context data
  # @return [Hash] The quickmenu result
  def character_selection_menu(characters, prompt, command:, context: {})
    options = characters.each_with_index.map do |ci, idx|
      char = ci.character
      display = char.display_name_for(character_instance)
      {
        key: (idx + 1).to_s,
        label: display,
        description: char.short_desc || char.forename
      }
    end

    options << { key: 'q', label: 'Cancel', description: 'Close menu' }

    char_data = characters.map do |ci|
      { id: ci.id, character_id: ci.character_id, name: ci.character.display_name_for(character_instance) }
    end

    create_quickmenu(
      character_instance,
      prompt,
      options,
      context: {
        command: command,
        stage: 'select_character',
        characters: char_data
      }.merge(context)
    )
  end

  # Build menu for clothing items (uses jewelry? check for description)
  # @param items [Array<Item>] Clothing/jewelry items
  # @param prompt [String] The menu prompt
  # @param command [String] The command name
  # @return [Hash] The quickmenu result
  def clothing_selection_menu(items, prompt, command:, context: {})
    item_selection_menu(
      items,
      prompt,
      command: command,
      description_field: ->(item) { item.jewelry? ? 'jewelry' : 'clothing' },
      context: context
    )
  end

  # Build menu with custom label and description procs
  # @param collection [Array] Items/characters to display
  # @param prompt [String] The menu prompt
  # @param command [String] The command name
  # @param label_proc [Proc] Proc to extract label from item
  # @param description_proc [Proc] Proc to extract description from item
  # @param data_proc [Proc] Proc to build data hash for each item
  # @param context [Hash] Additional context
  # @return [Hash] The quickmenu result
  def custom_selection_menu(collection, prompt, command:, label_proc:, description_proc: nil, data_proc: nil, context: {})
    options = collection.each_with_index.map do |item, idx|
      {
        key: (idx + 1).to_s,
        label: label_proc.call(item),
        description: description_proc&.call(item) || ''
      }
    end

    options << { key: 'q', label: 'Cancel', description: 'Close menu' }

    item_data = if data_proc
                  collection.map { |i| data_proc.call(i) }
                else
                  collection.map { |i| { id: i.id, name: label_proc.call(i) } }
                end

    create_quickmenu(
      character_instance,
      prompt,
      options,
      context: {
        command: command,
        stage: 'select_item',
        items: item_data
      }.merge(context)
    )
  end
end
