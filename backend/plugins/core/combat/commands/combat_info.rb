# frozen_string_literal: true

module Commands
  module Combat
    # Combat information command for accessibility mode
    # Provides text-based combat status, enemy/ally lists, and target recommendations
    class CombatInfo < Commands::Base::Command
      command_name 'combat'
      aliases 'cb', 'ci', 'fight status', 'battle'
      category :combat
      help_text 'Get combat information (enemies, allies, status, recommendations)'
      usage 'combat [enemies|allies|recommend|status|actions|help]'
      examples 'combat', 'combat enemies', 'combat recommend', 'combat status'

      protected

      def perform_command(parsed_input)
        args = parsed_input[:args] || []
        subcommand = args.first&.downcase

        # Find active fight
        fight = FightService.find_active_fight(character_instance)

        unless fight
          return error_result(
            "You are not in combat.\nUse 'attack <target>' to start a fight."
          )
        end

        # Get participant
        participant = fight.fight_participants_dataset
                           .where(character_instance_id: character_instance.id)
                           .first

        service = AccessibleCombatService.new(fight, participant)

        case subcommand
        when 'enemies', 'e', 'foes'
          show_enemies(service)
        when 'allies', 'a', 'friends'
          show_allies(service)
        when 'recommend', 'rec', 'target', 'suggest'
          show_recommendation(service)
        when 'status', 's', nil
          show_status(service)
        when 'actions', 'act', 'options'
          show_actions(service)
        when 'menu', 'm'
          show_quick_menu(service)
        when 'help', 'h', '?'
          show_help
        else
          error_result("Unknown combat command '#{subcommand}'. Use 'combat help' for options.")
        end
      end

      private

      def show_status(service)
        result = service.combat_status

        success_result(
          result[:accessible_text],
          type: :status,
          structured: result,
          format: result[:format]
        )
      end

      def show_enemies(service)
        result = service.list_enemies

        success_result(
          result[:accessible_text],
          type: :status,
          structured: result,
          format: result[:format]
        )
      end

      def show_allies(service)
        result = service.list_allies

        success_result(
          result[:accessible_text],
          type: :status,
          structured: result,
          format: result[:format]
        )
      end

      def show_recommendation(service)
        result = service.recommend_target

        if result[:recommendation]
          success_result(
            result[:accessible_text],
            type: :status,
            structured: result,
            format: result[:format]
          )
        else
          success_result(
            result[:accessible_text],
            type: :status,
            structured: result,
            format: result[:format]
          )
        end
      end

      def show_actions(service)
        result = service.available_actions

        success_result(
          result[:accessible_text],
          type: :status,
          structured: result,
          format: result[:format]
        )
      end

      def show_quick_menu(service)
        result = service.quick_menu

        success_result(
          result[:accessible_text],
          type: :quickmenu,
          structured: result.merge(display_type: :quickmenu),
          format: result[:format]
        )
      end

      def show_help
        lines = []
        lines << "<h3>Combat Commands</h3>"
        lines << ""
        lines << "Information:"
        lines << "  combat              - Show full combat status"
        lines << "  combat status       - Show your status and round info"
        lines << "  combat enemies      - List all enemies with HP and distance"
        lines << "  combat allies       - List all allies with HP and distance"
        lines << "  combat recommend    - Get target recommendation"
        lines << "  combat actions      - Show available actions"
        lines << "  combat menu         - Show quick menu options"
        lines << ""
        lines << "Actions:"
        lines << "  attack <target>     - Set attack target"
        lines << ""
        lines << "Accessibility:"
        lines << "  All combat info is screen-reader friendly"
        lines << "  Distances shown in hexes"
        lines << "  HP shown as current/max"

        success_result(
          lines.join("\n"),
          type: :system
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Combat::CombatInfo)
