# frozen_string_literal: true

require_relative '../concerns/combat_initiation_concern'

module Commands
  module Combat
    # Attack command - set target and attack action during combat
    # If not in combat, this initiates a fight
    class Attack < Commands::Base::Command
      include CombatInitiationConcern
      command_name 'attack'
      aliases 'hit', 'att'
      category :combat
      help_text 'Attack another character or set your combat target'
      usage 'attack [target]'
      examples 'attack', 'attack goblin', 'hit Bob'

      requires_alive
      requires_standing

      protected

      def perform_command(parsed_input)
        target_name = parsed_input[:text]

        fight = FightService.find_active_fight(character_instance)

        if fight
          handle_combat_attack(fight, target_name)
        else
          handle_start_fight(target_name)
        end
      end

      private

      def handle_combat_attack(fight, target_name)
        participant = fight.fight_participants_dataset
                           .where(character_instance_id: character_instance.id)
                           .first
        return error_result("You are not in this fight.") unless participant

        if fight.round_locked?
          return error_result("Combat round is resolving. Wait for the next round to change your choices.")
        end

        if participant.input_complete
          participant.update(input_stage: 'main_menu', input_complete: false)
          menu_data = CombatQuickmenuHandler.show_menu(participant, character_instance)

          return success_result(
            "Reopening your combat menu. You can change your choices until the round resolves.",
            type: :message,
            data: {
              action: :menu_reopened,
              fight_id: fight.id,
              quickmenu: menu_data
            }
          )
        end

        if present?(target_name)
          monster_target = find_fight_monster(fight, target_name)
          if monster_target
            participant.update(
              targeting_monster_id: monster_target.id,
              target_participant_id: nil,
              main_action: 'attack',
              main_action_set: true
            )

            return success_result(
              "You target #{monster_target.display_name}.",
              type: :message,
              data: {
                action: :target_changed,
                fight_id: fight.id,
                target: monster_target.display_name,
                target_type: :monster
              }
            )
          end

          new_target = find_fight_target(fight, target_name)
          return error_result("That target is not in this fight.") unless new_target
          invalid_reason = invalid_attack_target_reason(participant, new_target)
          return error_result(invalid_reason) if invalid_reason

          participant.update(
            target_participant_id: new_target.id,
            targeting_monster_id: nil,
            main_action: 'attack',
            main_action_set: true
          )

          return success_result(
            "You target #{new_target.character_name}.",
            type: :message,
            data: {
              action: :target_changed,
              fight_id: fight.id,
              target: new_target.character_name
            }
          )
        end

        participant.update(main_action: 'attack', main_action_set: true)

        if participant.target_participant
          invalid_reason = invalid_attack_target_reason(participant, participant.target_participant)
          return error_result(invalid_reason) if invalid_reason

          success_result(
            "You prepare to attack #{participant.target_participant.character_name}.",
            type: :message,
            data: {
              action: :attack_confirmed,
              fight_id: fight.id,
              target: participant.target_participant.character_name
            }
          )
        else
          error_result("You need to select a target first. Use 'attack <name>'.")
        end
      end

      def handle_start_fight(target_name)
        return error_result("Who do you want to attack?") if blank?(target_name)

        conflicting_fight = FightService.find_conflicting_mode_fight_in_room(location, mode: 'normal')
        if conflicting_fight&.mode == 'spar'
          return error_result('A sparring match is already in progress here.')
        end

        # Timeline restriction - check if death is allowed
        unless character_instance.can_die?
          return error_result('Combat is disabled in past timelines where death is not allowed.')
        end

        target = find_combat_target(target_name) # includes NPCs
        return error_result("You don't see #{target_name} here.") unless target
        return error_result("You can't attack yourself!") if target.id == character_instance.id

        # Block attacking RP NPCs (only combat-configured NPCs are attackable)
        if target.character.npc?
          archetype = target.character.npc_archetype
          unless archetype&.has_natural_attacks? || (archetype&.combat_ability_ids&.length.to_i > 0)
            return error_result("#{target.character.display_name_for(character_instance)} isn't a combatant.")
          end
        end

        # Start the fight
        fight_service = FightService.start_fight(room: location, initiator: character_instance, target: target)
        participant = fight_service.participant_for(character_instance)

        target_participant = fight_service.participant_for(target)
        participant.update(target_participant_id: target_participant.id, main_action: 'attack', main_action_set: true)
        participant.update(input_stage: 'main_action')

        target_display = target.character.display_name_for(character_instance)

        broadcast_to_room(
          "#{character.full_name} attacks #{target.character.full_name}!",
          exclude_character: character_instance,
          type: :combat,
          fight_id: fight_service.fight.id,
          initiator: character.full_name,
          target: target.character.full_name
        )

        if fight_service.fight.battle_map_generating
          success_result(
            "You attack #{target_display}! Generating battle map...",
            type: :message,
            data: {
              action: :fight_started,
              fight_id: fight_service.fight.id,
              target: target.character.full_name,
              battle_map_generating: true
            }
          )
        else
          # Show the quickmenu to initiator and target
          menu_data = CombatQuickmenuHandler.show_menu(participant, character_instance)
          push_combat_menu_to_target(fight_service, target,
            broadcast_text: "You've been drawn into combat! Choose your combat action.")

          success_result(
            "You attack #{target_display}! Choose your action.",
            type: :message,
            data: {
              action: :fight_started,
              fight_id: fight_service.fight.id,
              target: target.character.full_name,
              quickmenu: menu_data
            }
          )
        end
      end

      def find_fight_target(fight, name)
        candidates = fight.active_participants
                          .where(
                            Sequel.|(
                              { character_instance_id: nil },
                              Sequel.~(character_instance_id: character_instance.id)
                            )
                          )
                          .all

        query = name.downcase

        candidates.find do |p|
          if p.is_npc
            # NPC fight participants (from activity combat) match by npc_name
            npc_name = p.npc_name&.downcase || ''
            npc_name.include?(query)
          elsif p.character_instance
            char_name = p.character_instance.character.full_name&.downcase || ''
            forename = p.character_instance.character.forename&.downcase || ''
            char_name.include?(query) || forename.start_with?(query)
          end
        end
      end

      def find_fight_monster(fight, name)
        return nil unless fight.has_monster

        monsters = LargeMonsterInstance.where(fight_id: fight.id, status: 'active').all
        query = name.downcase

        monsters.find do |m|
          display_name = m.display_name&.downcase || ''
          template_name = m.monster_template&.name&.downcase || ''
          monster_type = m.monster_template&.monster_type&.downcase || ''

          display_name.include?(query) || template_name.include?(query) || monster_type.include?(query)
        end
      end

      def invalid_attack_target_reason(participant, target)
        return "You can't attack your own side." if participant.same_side?(target)

        protected_ids = StatusEffectService.cannot_target_ids(participant)
        return "#{target.character_name} cannot be targeted right now." if protected_ids.include?(target.id)

        nil
      end

      # Uses inherited find_combat_target from base command
    end
  end
end

Commands::Base::Registry.register(Commands::Combat::Attack)
