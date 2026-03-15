# frozen_string_literal: true

require_relative '../../../../app/helpers/dice_roll_broadcast_helper'

module Commands
  module Dice
    class Roll < Commands::Base::Command
      include DiceRollBroadcastHelper
      command_name 'roll'
      aliases 'rl', 'dr', 'dice', 'diceroll'
      category :entertainment
      help_text 'Roll dice based on your stats or dice notation'
      usage 'roll <stat> [+stat...] | roll NdN[+/-mod]'
      examples 'roll STR', 'roll STR+DEX', 'roll 2d6', 'roll 1d20+5'

      # Dice notation pattern: NdN with optional +/- modifier
      DICE_NOTATION = /\A(\d+)d(\d+)([+-]\d+)?\z/i

      protected

      def perform_command(parsed_input)
        stat_input = parsed_input[:text]&.strip

        # Show stat picker quickmenu if no stat specified
        if stat_input.nil? || stat_input.empty?
          return show_stat_picker_menu
        end

        # Check for dice notation (e.g., "2d6", "1d20+5")
        if (match = stat_input.match(DICE_NOTATION))
          return handle_dice_notation(match)
        end

        # Parse stat names (e.g., "STR+DEX" -> ["STR", "DEX"])
        stat_names = stat_input.upcase.split('+').map(&:strip).reject(&:empty?)

        return error_result("Please specify at least one stat to roll.") if stat_names.empty?

        # Reject duplicate stats to prevent modifier inflation
        if stat_names.length != stat_names.uniq.length
          return error_result("Cannot use the same stat twice in one roll.")
        end

        # Calculate modifier from stats
        modifier_result = StatAllocationService.calculate_roll_modifier(character_instance, stat_names)

        unless modifier_result[:success]
          return error_result(modifier_result[:error])
        end

        modifier = modifier_result[:modifier]
        stat_block_type = modifier_result[:stat_block_type]
        stats_used = modifier_result[:stats_used]

        # Roll 2d8 with exploding 8s
        roll_result = DiceRollService.roll_2d8_exploding(modifier)

        # Build stats description
        stats_desc = stats_used.map { |s| "#{s[:abbreviation]} (#{s[:value]})" }.join(' + ')

        # Generate animation data - use stats label, not character name
        # (webclient prepends the personalized character name)
        animation_data = DiceRollService.generate_animation_data(
          roll_result,
          character_name: "rolls #{stats_desc}",
          color: character.distinctive_color || '#ffffff'
        )

        # Build the roll description (for text-only clients and history)
        roll_desc = build_roll_description(roll_result, stats_desc, modifier)

        # Broadcast the roll to the room (uses personalized names per viewer)
        broadcast_dice_roll(animation_data, roll_desc, roll_result, modifier)

        # Check for pending Auto-GM roll requests
        check_auto_gm_roll_request(roll_result, stat_names.join('+'))

        # Return result for the roller
        success_result(
          roll_desc,
          animation_data: animation_data,
          roll_modifier: modifier,
          roll_total: roll_result.total
        )
      end

      private

      # Handle dice notation like 2d6, 1d20+5, 3d8-2
      def handle_dice_notation(match)
        count = match[1].to_i
        sides = match[2].to_i
        modifier = match[3].to_i # nil.to_i == 0

        # Validate dice count and sides
        unless (1..20).cover?(count)
          return error_result("Number of dice must be between 1 and 20.")
        end

        unless (2..100).cover?(sides)
          return error_result("Number of sides must be between 2 and 100.")
        end

        # Roll the dice
        roll_result = DiceRollService.roll(count, sides, modifier: modifier)

        # Build notation string
        notation = "#{count}d#{sides}"
        notation += format('%+d', modifier) if modifier != 0

        # Build description
        dice_str = roll_result.dice.join(', ')
        parts = ["#{character.full_name} rolls #{notation}: [#{dice_str}]"]
        if modifier != 0
          parts << format('%+d', modifier)
        end
        parts << "= #{roll_result.total}"
        message = parts.join(' ')

        # Generate animation data
        animation_data = DiceRollService.generate_animation_data(
          roll_result,
          character_name: "rolls #{notation}",
          color: character.distinctive_color || '#ffffff'
        )

        # Broadcast to room
        broadcast_dice_roll(animation_data, message, roll_result, modifier)

        success_result(
          message,
          animation_data: animation_data,
          roll_modifier: modifier,
          roll_total: roll_result.total
        )
      end

      def build_roll_description(roll_result, stats_desc, modifier)
        base_dice = roll_result.base_dice.join(', ')
        explosion_values = roll_result.dice.drop(roll_result.base_dice.length)

        parts = ["#{character.full_name} rolls #{stats_desc}:"]
        parts << "[#{base_dice}]"

        if explosion_values.any?
          explosion_str = explosion_values.map { |value| "+#{value}" }.join('')
          parts << "EXPLODE!#{explosion_str}"
        end

        if modifier != 0
          sign = modifier > 0 ? '+' : ''
          parts << "#{sign}#{modifier.round(1)}"
        end

        parts << "= #{roll_result.total}"

        parts.join(' ')
      end

      # Check for pending Auto-GM roll requests and process if found
      # @param roll_result [DiceRollResult] the roll result
      # @param stats_used [String] the stat(s) used for the roll
      def check_auto_gm_roll_request(roll_result, stats_used)
        # Use fully-qualified constant to avoid finding Commands::AutoGm instead of ::AutoGm
        return unless defined?(::AutoGm::AutoGmRollService)

        result = ::AutoGm::AutoGmRollService.process_roll(
          character_instance,
          roll_result,
          stats_used
        )

        # If the roll was processed against a pending request, notify the player
        if result[:processed]
          outcome = result[:success] ? 'succeeded' : 'failed'
          margin_text = result[:margin] >= 0 ? "+#{result[:margin]}" : result[:margin].to_s

          notify_player(
            "Your roll was evaluated against the GM's request: " \
            "#{result[:total]} vs DC #{result[:dc]} (#{margin_text}) - #{outcome.upcase}!"
          )
        elsif result[:reason] == 'Roll stat mismatch'
          expected = result[:expected_stat] || 'the requested stat'
          notify_player("That roll did not count for the GM request. Please roll using #{expected}.")
        end
      rescue StandardError => e
        # Don't fail the roll if Auto-GM processing fails
        warn "Auto-GM roll processing error: #{e.message}"
      end

      # Send a notification to the player
      # @param message [String] the notification message
      def notify_player(message)
        BroadcastService.to_character(
          character_instance,
          {
            content: message,
            html: "<div class='auto-gm-roll-evaluation'>#{ERB::Util.html_escape(message)}</div>",
            type: 'auto_gm_roll_evaluation'
          },
          type: :auto_gm_notification
        )
      end

      # Show a quickmenu of available stats to roll
      def show_stat_picker_menu
        # Get all character stats with their current values
        stats = character_instance.character_stats.map do |cs|
          stat = cs.stat
          next unless stat
          {
            abbreviation: stat.abbreviation,
            name: stat.name,
            value: cs.current_value
          }
        end.compact

        if stats.empty?
          return error_result("You don't have any stats to roll. Please set up your character's stat block.")
        end

        # Build options for quickmenu
        options = stats.each_with_index.map do |stat, idx|
          {
            key: (idx + 1).to_s,
            label: "#{stat[:abbreviation]} (#{stat[:value]})",
            description: stat[:name]
          }
        end

        # Add combine option
        options << {
          key: 'c',
          label: 'Combine stats',
          description: "Type stat names like 'STR+DEX' to roll multiple"
        }

        options << {
          key: 'q',
          label: 'Cancel',
          description: 'Cancel this roll'
        }

        # Store stats for callback
        @available_stats = stats

        create_quickmenu(
          character_instance,
          "Roll which stat? (Your modifier will be added to 2d8)",
          options,
          context: {
            command: 'roll',
            stats: stats.map { |s| { abbr: s[:abbreviation], val: s[:value] } }
          }
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Dice::Roll)
