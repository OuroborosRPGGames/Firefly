# frozen_string_literal: true

require_relative '../../../../app/helpers/dice_roll_broadcast_helper'

module Commands
  module Dice
    class Diceroll < Commands::Base::Command
      include DiceRollBroadcastHelper
      command_name 'diceroll'
      aliases 'dr', 'dice'
      category :entertainment
      help_text 'Roll custom dice'
      usage 'diceroll <count>d<sides> [+modifier]'
      examples 'diceroll 2d6', 'dr 1d20', 'diceroll 3d8+5'

      # Limits to prevent abuse (from centralized config)
      MAX_DICE = GameConfig::Dice::LIMITS[:max_count]
      MAX_SIDES = GameConfig::Dice::LIMITS[:max_sides]
      MIN_SIDES = GameConfig::Dice::LIMITS[:min_sides]

      protected

      def perform_command(parsed_input)
        dice_input = parsed_input[:text]&.strip&.downcase

        return error_result("What dice would you like to roll? Usage: diceroll 2d6") if dice_input.nil? || dice_input.empty?

        # Dice notation: XdY, XdY+Z, or XdY-Z
        match = dice_input.match(/^(\d+)d(\d+)(?:([+-])(\d+))?$/)

        unless match
          return error_result("Invalid dice format. Use format like: 2d6, 1d20, or 3d8+5")
        end

        count = match[1].to_i
        sides = match[2].to_i
        modifier_sign = match[3]
        modifier_value = match[4]&.to_i || 0
        modifier = modifier_sign == '-' ? -modifier_value : modifier_value

        if count < 1 || count > MAX_DICE
          return error_result("Number of dice must be between 1 and #{MAX_DICE}.")
        end

        if sides < MIN_SIDES || sides > MAX_SIDES
          return error_result("Number of sides must be between #{MIN_SIDES} and #{MAX_SIDES}.")
        end

        roll_result = DiceRollService.roll(count, sides, modifier: modifier)

        # Name is added per-viewer by the broadcast layer
        animation_data = DiceRollService.generate_animation_data(
          roll_result,
          character_name: "rolls #{dice_input}",
          color: character.distinctive_color || '#ffffff'
        )

        roll_desc = build_roll_description(roll_result, dice_input)
        broadcast_dice_roll(animation_data, roll_desc, roll_result, modifier)

        success_result(
          roll_desc,
          animation_data: animation_data,
          roll_modifier: modifier,
          roll_total: roll_result.total
        )
      end

      private

      def build_roll_description(roll_result, dice_notation)
        dice_str = roll_result.dice.join(', ')
        modifier = roll_result.modifier

        parts = ["#{character.full_name} rolls #{dice_notation}:"]
        parts << "[#{dice_str}]"

        if modifier != 0
          sign = modifier > 0 ? '+' : ''
          parts << "#{sign}#{modifier}"
        end

        parts << "= #{roll_result.total}"

        parts.join(' ')
      end

    end
  end
end

Commands::Base::Registry.register(Commands::Dice::Diceroll)
