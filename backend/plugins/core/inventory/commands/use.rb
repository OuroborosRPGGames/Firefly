# frozen_string_literal: true

module Commands
  module Inventory
    class Use < Commands::Base::Command
      command_name 'use'
      aliases 'u'
      category :inventory
      help_text 'Use or interact with an item in your inventory, or play a game'
      usage 'use <item> [branch]'
      examples 'use', 'use sword', 'use dartboard', 'use dartboard aggressive'

      protected

      def perform_command(parsed_input)
        text = parsed_input[:text]

        # Show inventory items quickmenu if no item specified
        if blank?(text)
          return show_inventory_menu
        end

        # Try to find a game first (item or room fixture)
        # This handles parsing item name vs branch name internally
        game_result = find_and_play_game(text)
        return game_result if game_result

        # Fall back to regular item use
        item = find_inventory_item(text)
        unless item
          return error_result("You don't have '#{text}'.")
        end

        # Show action menu for the selected item
        show_item_actions_menu(item)
      end

      private

      # Find a game instance by name (item or room fixture) and play it
      # Handles parsing input like "8-ball serious" where "8-ball" is item and "serious" is branch
      def find_and_play_game(input)
        parts = input.split(/\s+/)

        # Handle reset command first
        if parts.length > 1 && parts.last.downcase == 'reset'
          return handle_game_reset(parts[0..-2].join(' '))
        end

        # Try progressively shorter prefixes to find the game
        # e.g., for "dart board aggressive" try "dart board aggressive", "dart board", "dart"
        game_instance = nil
        branch_name = nil

        parts.length.downto(1) do |i|
          potential_name = parts[0...i].join(' ')
          game_instance = find_game_instance(potential_name)
          if game_instance
            branch_name = parts[i..].join(' ') if i < parts.length
            break
          end
        end

        return nil unless game_instance

        branches = game_instance.branches
        return error_result("This game has no playable options.") if branches.empty?

        # Single branch: play directly
        if branches.count == 1
          return play_game(game_instance, branches.first)
        end

        # Branch specified: find and play it
        if branch_name && !branch_name.empty?
          branch = find_branch(branches, branch_name)
          if branch
            return play_game(game_instance, branch)
          else
            return error_result("Unknown option '#{branch_name}'. Options: #{branches.map(&:name).join(', ')}")
          end
        end

        # Multiple branches, none specified: show quickmenu
        show_branch_quickmenu(game_instance, branches)
      end

      def find_game_instance(name)
        name_lower = name.to_s.downcase

        # Check inventory items first
        item = find_inventory_item(name)
        if item
          game = GameInstance.where(item_id: item.id).first
          return game if game
        end

        # Check room fixtures
        return nil unless location

        room_games = GameInstance.where(room_id: location.id).all
        room_games.find do |gi|
          gi.display_name.downcase.include?(name_lower)
        end
      end

      def find_branch(branches, name)
        name_lower = name.to_s.downcase
        branches.find do |b|
          b.name.downcase == name_lower ||
            b.display_name.downcase.start_with?(name_lower)
        end
      end

      def play_game(game_instance, branch)
        result = GamePlayService.play(game_instance, branch, character_instance)
        return error_result(result[:error]) unless result[:success]

        # Format output
        output = format_game_output(result)
        success_result(output)
      end

      def format_game_output(result)
        lines = []
        lines << "[ #{result[:game_name]} - #{result[:branch_name]} ]"
        lines << ""
        lines << result[:message]

        if result[:total_score]
          score_line = if result[:points] > 0
                         "+#{result[:points]} points"
                       else
                         "#{result[:points]} points"
                       end
          lines << ""
          lines << "#{score_line} | Your score: #{result[:total_score]} points"
        end

        lines.join("\n")
      end

      def show_branch_quickmenu(game_instance, branches)
        options = branches.map.with_index do |branch, idx|
          {
            key: (idx + 1).to_s,
            label: branch.display_name,
            description: branch.description || ''
          }
        end

        options << { key: 'q', label: 'Cancel', description: 'Close menu' }

        create_quickmenu(
          character_instance,
          "How do you want to play?",
          options,
          context: {
            command: 'use',
            stage: 'select_game_branch',
            game_instance_id: game_instance.id,
            branches: branches.map { |b| { id: b.id, name: b.name } }
          }
        )
      end

      def handle_game_reset(item_name)
        game_instance = find_game_instance(item_name)
        return error_result("No game found for '#{item_name}'.") unless game_instance

        score = GameScore.where(
          game_instance_id: game_instance.id,
          character_instance_id: character_instance.id
        ).first

        if score
          score.reset!
          success_result("Your score for #{game_instance.display_name} has been reset.")
        else
          success_result("You don't have a score for #{game_instance.display_name}.")
        end
      end

      # Show a quickmenu of inventory items
      def show_inventory_menu
        items = character_instance.inventory_items.all

        if items.empty?
          return error_result("You aren't carrying anything. Pick something up first.")
        end

        # Build options
        options = items.each_with_index.map do |item, idx|
          status = if item.held?
                     'held'
                   elsif item.worn?
                     'worn'
                   else
                     'carried'
                   end

          label = item.quantity > 1 ? "(x#{item.quantity}) #{item.name}" : item.name

          {
            key: (idx + 1).to_s,
            label: label,
            description: status
          }
        end

        options << {
          key: 'q',
          label: 'Cancel',
          description: 'Close menu'
        }

        # Store plain text names for matching
        item_data = items.map do |i|
          { id: i.id, name: plain_name(i.name) }
        end

        create_quickmenu(
          character_instance,
          "What would you like to use?",
          options,
          context: {
            command: 'use',
            stage: 'select_item',
            items: item_data
          }
        )
      end

      # Show action menu for a selected item
      def show_item_actions_menu(item)
        item_plain_name = plain_name(item.name)

        options = []

        # Build available actions based on item state
        if item.held?
          options << { key: 'r', label: 'Release', description: 'Stop holding this item' }
        else
          options << { key: 'h', label: 'Hold', description: 'Hold in your hand' }
        end

        # Check if item is wearable (clothing, jewelry, tattoo, piercing)
        is_wearable = item.clothing? || item.jewelry? || item.tattoo? || item.piercing?
        if is_wearable && !item.worn?
          options << { key: 'w', label: 'Wear', description: 'Put it on' }
        elsif item.worn?
          options << { key: 'w', label: 'Remove', description: 'Take it off' }
        end

        if item.consumable?
          # Determine consume verb based on item type
          verb = if item.food?
                   'eat'
                 elsif item.drinkable?
                   'drink'
                 elsif item.smokeable?
                   'smoke'
                 else
                   'consume'
                 end
          options << { key: 'c', label: verb.capitalize, description: "#{verb.capitalize} this item" }
        end

        options << { key: 'd', label: 'Drop', description: 'Drop on the ground' }
        options << { key: 'e', label: 'Examine', description: 'Look at it closely' }
        options << { key: 'g', label: 'Give', description: 'Give to someone' }
        options << { key: 's', label: 'Show', description: 'Show to someone' }

        options << { key: 'q', label: 'Cancel', description: 'Close menu' }

        create_quickmenu(
          character_instance,
          "#{item_plain_name} - what do you want to do?",
          options,
          context: {
            command: 'use',
            stage: 'select_action',
            item_id: item.id,
            item_name: item_plain_name
          }
        )
      end

      def find_inventory_item(name)
        items = character_instance.inventory_items.all
        return nil if items.empty?

        # Try exact match first, then prefix match
        name_lower = name.downcase
        items.find do |item|
          item_plain = plain_name(item.name).downcase
          item_plain == name_lower || item_plain.start_with?(name_lower)
        end
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Inventory::Use)
