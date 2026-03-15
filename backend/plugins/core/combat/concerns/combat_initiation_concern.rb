# frozen_string_literal: true

# Shared logic for fight and spar commands.
# Extracts the duplicated push_combat_menu_to_target, target selection menu,
# and eligible targets query.
module CombatInitiationConcern
  # Push a combat quickmenu to a non-NPC target via WebSocket
  # @param fight_service [FightService] the fight service instance
  # @param target_instance [CharacterInstance] the target
  # @param broadcast_text [String] the message to send with the quickmenu
  def push_combat_menu_to_target(fight_service, target_instance, broadcast_text:)
    return if target_instance.character&.npc?

    target_participant = fight_service.participant_for(target_instance)
    return unless target_participant

    menu_data = CombatQuickmenuHandler.show_menu(target_participant, target_instance)
    return unless menu_data

    interaction_id = SecureRandom.uuid
    stored = {
      interaction_id: interaction_id,
      type: 'quickmenu',
      prompt: menu_data[:prompt],
      options: menu_data[:options],
      context: menu_data[:context] || {},
      created_at: Time.now.iso8601
    }
    OutputHelper.store_agent_interaction(target_instance, interaction_id, stored)

    BroadcastService.to_character(
      target_instance,
      { content: broadcast_text },
      type: :quickmenu,
      notification: {
        title: character_instance.character&.display_name_for(target_instance),
        body: broadcast_text.to_s.gsub(/<[^>]+>/, '').strip.slice(0, 100),
        icon: character_instance.character&.profile_pic_url,
        setting: 'notify_emote'
      },
      data: {
        interaction_id: interaction_id,
        prompt: menu_data[:prompt],
        options: menu_data[:options]
      }
    )
  rescue StandardError => e
    warn "[CombatInitiation] Failed to push quickmenu to target: #{e.message}"
  end

  # Build a quickmenu for selecting a combat target
  # @param prompt_text [String] e.g. "Who do you want to fight?"
  # @param command_name [String] e.g. "fight" or "spar"
  # @param exclude_in_combat [Boolean] whether to filter out characters already in fights
  # @return quickmenu result
  def build_target_selection_menu(prompt_text:, command_name:, exclude_in_combat: false)
    targets = eligible_combat_targets(exclude_in_combat: exclude_in_combat)

    if targets.empty?
      return error_result("There's no one here to #{command_name}#{command_name == 'spar' ? ' with' : ''}.")
    end

    options = targets.each_with_index.map do |target_inst, idx|
      char = target_inst.character
      desc = char.short_desc || ''
      desc = desc[0..30] + '...' if desc.length > 33
      {
        key: (idx + 1).to_s,
        label: char.full_name,
        description: desc
      }
    end

    options << { key: 'q', label: 'Cancel', description: 'Nevermind' }

    target_data = targets.map { |t| { id: t.id, name: t.character.forename } }

    create_quickmenu(
      character_instance,
      prompt_text,
      options,
      context: {
        command: command_name,
        stage: 'select_target',
        targets: target_data
      }
    )
  end

  # Get eligible combat targets in the current room
  # @param exclude_in_combat [Boolean] whether to filter out characters already in fights
  # @return [Array<CharacterInstance>]
  def eligible_combat_targets(exclude_in_combat: false)
    targets = CharacterInstance.where(current_room_id: location&.id)
                               .exclude(id: character_instance.id)
                               .where(online: true)
                               .eager(:character)
                               .all

    if exclude_in_combat
      targets.reject { |ci| FightService.find_active_fight(ci) }
    else
      targets
    end
  end
end
