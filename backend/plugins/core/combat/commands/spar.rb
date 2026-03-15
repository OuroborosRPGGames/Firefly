# frozen_string_literal: true

require_relative '../concerns/combat_initiation_concern'

module Commands
  module Combat
    # Spar command - initiates a friendly sparring match
    # Works like combat but tracks "touches" instead of HP damage
    class Spar < Commands::Base::Command
      include CombatInitiationConcern
      command_name 'spar'
      aliases 'sparring'
      category :combat
      help_text 'Challenge someone to a friendly sparring match'
      usage 'spar <target>'
      examples 'spar Bob', 'spar guard'

      requires_alive
      requires_standing

      protected

      def perform_command(parsed_input)
        target_name = parsed_input[:text]

        existing_fight = FightService.find_active_fight(character_instance)
        if existing_fight
          return error_result("You're already in combat! Finish your current fight first.")
        end

        if blank?(target_name)
          return show_spar_menu
        end

        # find_combat_target includes NPCs
        target = find_combat_target(target_name)
        return error_result("You don't see #{target_name} here to spar with.") unless target
        return error_result("You can't spar with yourself!") if target.id == character_instance.id
        return error_result("You can't spar with NPCs.") if target.character.npc?

        target_fight = FightService.find_active_fight(target)
        if target_fight
          return error_result("#{target.character.full_name} is already in combat!")
        end

        conflicting_fight = FightService.find_conflicting_mode_fight_in_room(location, mode: 'spar')
        if conflicting_fight && (conflicting_fight.mode.nil? || conflicting_fight.mode == 'normal')
          return error_result('Active combat is already in progress here. Sparring is unavailable right now.')
        end

        fight_service = FightService.start_fight(room: location, initiator: character_instance, target: target, mode: 'spar')
        participant = fight_service.participant_for(character_instance)

        broadcast_message = "#{character.full_name} challenges #{target.character.full_name} to a sparring match!"
        broadcast_to_room(
          broadcast_message,
          exclude_character: character_instance,
          type: :combat,
          fight_id: fight_service.fight.id,
          initiator: character.full_name,
          target: target.character.full_name,
          mode: 'spar'
        )

        target_display = target.character.display_name_for(character_instance)

        if fight_service.fight.battle_map_generating
          success_result(
            "You challenge #{target_display} to a sparring match! Generating battle map...",
            type: :message,
            data: {
              action: :spar_started,
              fight_id: fight_service.fight.id,
              target: target.character.full_name,
              mode: 'spar',
              battle_map_generating: true
            }
          )
        else
          menu_data = CombatQuickmenuHandler.show_menu(participant, character_instance)

          push_combat_menu_to_target(fight_service, target,
            broadcast_text: "You've been challenged to a sparring match! Choose your combat action.")

          success_result(
            "You challenge #{target_display} to a sparring match!",
            type: :message,
            data: {
              action: :spar_started,
              fight_id: fight_service.fight.id,
              target: target.character.full_name,
              mode: 'spar',
              quickmenu: menu_data
            }
          )
        end
      end

      private

      def show_spar_menu
        build_target_selection_menu(
          prompt_text: "Who do you want to spar with?",
          command_name: 'spar',
          exclude_in_combat: true
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Combat::Spar)
