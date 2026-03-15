# frozen_string_literal: true

# Service for managing prisoner and restraint mechanics
# Handles: helpless states, unconsciousness, restraints, dragging/carrying, inventory manipulation
class PrisonerService
  # Constants now in GameConfig::Prisoner
  WAKE_DELAY_SECONDS = GameConfig::Prisoner::WAKE_DELAY_SECONDS
  AUTO_WAKE_SECONDS = GameConfig::Prisoner::AUTO_WAKE_SECONDS
  DRAG_SPEED_MODIFIER = GameConfig::Prisoner::DRAG_SPEED_MODIFIER

  class << self
    # ========================================
    # Helpless State Management
    # ========================================

    # Make a character helpless
    # @param character_instance [CharacterInstance]
    # @param reason [String] 'unconscious', 'bound_hands', 'voluntary'
    # @return [Hash] { success: Boolean, error: String? }
    def make_helpless!(character_instance, reason:)
      character_instance.update(
        is_helpless: true,
        helpless_reason: reason
      )

      # Stop any following when becoming helpless
      character_instance.update(following_id: nil)

      { success: true }
    rescue StandardError => e
      warn "[PrisonerService] make_helpless! failed: #{e.message}"
      { success: false, error: e.message }
    end

    # Clear helpless state if no longer needed
    # @param character_instance [CharacterInstance]
    # @return [Hash] { success: Boolean, error: String? }
    def clear_helpless!(character_instance)
      # Check if character should remain helpless
      if character_instance.unconscious?
        return { success: false, error: 'Character is still unconscious.' }
      end

      if character_instance.hands_bound?
        # Hands bound = stay helpless
        character_instance.update(helpless_reason: 'bound_hands')
        return { success: false, error: 'Hands are still bound.' }
      end

      # Clear helpless state
      character_instance.update(
        is_helpless: false,
        helpless_reason: nil
      )

      { success: true }
    rescue StandardError => e
      warn "[PrisonerService] clear_helpless! failed: #{e.message}"
      { success: false, error: e.message }
    end

    # Check if a target can be restrained/manipulated
    # @param target [CharacterInstance]
    # @return [Boolean]
    def can_restrain?(target)
      target.helpless?
    end

    # Check if actor can manipulate target (search, dress, etc.)
    # @param actor [CharacterInstance]
    # @param target [CharacterInstance]
    # @return [Boolean]
    def can_manipulate?(actor, target)
      return false unless target.helpless?
      return false unless actor.current_room_id == target.current_room_id
      return false if actor.id == target.id

      true
    end

    # ========================================
    # Unconsciousness System
    # ========================================

    # Check if a character is knocked out in an active fight
    # Characters cannot wake up while combat is still ongoing
    # @param character_instance [CharacterInstance]
    # @return [Boolean]
    def in_active_combat?(character_instance)
      FightParticipant.where(character_instance_id: character_instance.id, is_knocked_out: true)
                      .eager(:fight)
                      .all
                      .any? { |p| p.fight&.ongoing? }
    end

    # Reset wake timers for a character (called when combat ends)
    # This restarts the wake countdown from when combat ended
    # @param character_instance [CharacterInstance]
    # @return [Hash] { success: Boolean }
    def reset_wake_timers!(character_instance)
      return { success: false, error: 'Not unconscious' } unless character_instance.unconscious?

      now = Time.now
      character_instance.update(
        can_wake_at: now + WAKE_DELAY_SECONDS,
        auto_wake_at: now + AUTO_WAKE_SECONDS
      )

      { success: true }
    rescue StandardError => e
      warn "[PrisonerService] Failed to reset wake timers: #{e.message}"
      { success: false, error: e.message }
    end

    # Process combat knockout - transition to unconscious state
    # @param character_instance [CharacterInstance]
    # @return [Hash] { success: Boolean }
    def process_knockout!(character_instance)
      now = Time.now

      character_instance.update(
        status: 'unconscious',
        is_helpless: true,
        helpless_reason: 'unconscious',
        knocked_out_at: now,
        can_wake_at: now + WAKE_DELAY_SECONDS,
        auto_wake_at: now + AUTO_WAKE_SECONDS,
        # Stop any movement/observation
        following_id: nil,
        observing_id: nil,
        observing_place_id: nil,
        observing_room: false,
        stance: 'lying'
      )

      { success: true }
    rescue StandardError => e
      warn "[PrisonerService] process_knockout! failed: #{e.message}"
      { success: false, error: e.message }
    end

    # Process a surrender in combat - makes the character helpless but conscious
    # Unlike knockout, they surrendered willingly so they stay 'conscious' status
    # @param character_instance [CharacterInstance]
    # @return [Hash] { success: Boolean }
    def process_surrender!(character_instance)
      return { success: false, error: 'No character instance' } unless character_instance

      now = Time.now

      character_instance.update(
        status: 'alive', # Not unconscious - they surrendered willingly
        is_helpless: true,
        helpless_reason: 'surrendered',
        knocked_out_at: now,
        can_wake_at: now + WAKE_DELAY_SECONDS,
        auto_wake_at: now + AUTO_WAKE_SECONDS,
        stance: 'sitting' # Surrender posture (kneeling not in valid stances)
      )

      { success: true }
    rescue StandardError => e
      warn "[PrisonerService] process_surrender! failed: #{e.message}"
      { success: false, error: e.message }
    end

    # Manually wake an unconscious character
    # @param target [CharacterInstance]
    # @param waker [CharacterInstance, nil]
    # @return [Hash] { success: Boolean, error: String? }
    def wake!(target, waker: nil)
      target_name = waker && target.character ? target.character.display_name_for(waker) : target.full_name

      unless target.unconscious?
        return { success: false, error: "#{target_name} is not unconscious." }
      end

      # Cannot wake during active combat - must wait for fight to end
      if in_active_combat?(target)
        return { success: false, error: "#{target_name} cannot be woken while combat is still ongoing." }
      end

      unless target.can_wake?
        seconds_left = target.seconds_until_wakeable
        return { success: false, error: "#{target_name} cannot be woken yet. Try again in #{seconds_left} seconds." }
      end

      # Wake up
      target.update(
        status: 'alive',
        knocked_out_at: nil,
        can_wake_at: nil,
        auto_wake_at: nil
      )

      # Check if should still be helpless (hands bound)
      if target.hands_bound?
        target.update(helpless_reason: 'bound_hands')
      else
        clear_helpless!(target)
      end

      { success: true, waker: waker }
    rescue StandardError => e
      warn "[PrisonerService] wake! failed: #{e.message}"
      { success: false, error: e.message }
    end

    # Process automatic wake-ups (called by scheduler)
    # Skips characters in active combat - they wake when combat ends
    # @return [Hash] { woken: Integer, skipped_combat: Integer, errors: Array }
    def process_auto_wakes!
      woken = 0
      skipped_combat = 0
      errors = []

      # Find all unconscious characters past auto-wake time
      CharacterInstance.where(status: 'unconscious')
                       .where { auto_wake_at <= Time.now }
                       .each do |char_inst|
        # Skip characters still in active combat - their timer will reset when combat ends
        if in_active_combat?(char_inst)
          skipped_combat += 1
          next
        end

        result = wake!(char_inst)
        if result[:success]
          woken += 1
          # Notify the character they've woken up
          BroadcastService.to_character(
            char_inst,
            'You regain consciousness and slowly open your eyes.',
            type: :system
          )
          # Notify the room (personalized per viewer)
          if char_inst.current_room_id
            wake_msg = "#{char_inst.full_name} stirs and regains consciousness."

            room_chars = CharacterInstance.where(
              current_room_id: char_inst.current_room_id,
              online: true
            ).exclude(id: char_inst.id).eager(:character).all

            all_chars = room_chars + [char_inst]

            room_chars.each do |viewer|
              personalized = MessagePersonalizationService.personalize(
                message: wake_msg,
                viewer: viewer,
                room_characters: all_chars
              )
              BroadcastService.to_character(viewer, personalized)
            end
          end
        else
          errors << { character_id: char_inst.id, error: result[:error] }
        end
      end

      { woken: woken, skipped_combat: skipped_combat, errors: errors }
    end

    # Check if character can be woken
    # @param character_instance [CharacterInstance]
    # @return [Boolean]
    def can_be_woken?(character_instance)
      character_instance.unconscious? && character_instance.can_wake?
    end

    # ========================================
    # Restraint System
    # ========================================

    # Apply a restraint to a helpless target
    # @param target [CharacterInstance]
    # @param restraint_type [String] 'hands', 'feet', 'gag', 'blindfold'
    # @param actor [CharacterInstance]
    # @return [Hash] { success: Boolean, error: String? }
    def apply_restraint!(target, restraint_type, actor:)
      unless can_manipulate?(actor, target)
        return { success: false, error: 'You can only restrain helpless characters in the same room.' }
      end

      target_name = target.character.display_name_for(actor)

      case restraint_type.to_s.downcase
      when 'hands'
        if target.hands_bound?
          return { success: false, error: "#{target_name}'s hands are already bound." }
        end

        target.update(hands_bound: true)
        # Hands bound = helpless
        make_helpless!(target, reason: 'bound_hands') unless target.helpless?

      when 'feet'
        if target.feet_bound?
          return { success: false, error: "#{target_name}'s feet are already bound." }
        end

        target.update(feet_bound: true)

      when 'gag'
        if target.gagged?
          return { success: false, error: "#{target_name} is already gagged." }
        end

        target.update(is_gagged: true)

      when 'blindfold'
        if target.blindfolded?
          return { success: false, error: "#{target_name} is already blindfolded." }
        end

        target.update(is_blindfolded: true)

      else
        return { success: false, error: "Unknown restraint type: #{restraint_type}" }
      end

      { success: true, restraint_type: restraint_type }
    rescue StandardError => e
      warn "[PrisonerService] apply_restraint! failed: #{e.message}"
      { success: false, error: e.message }
    end

    # Remove a restraint from a character
    # @param target [CharacterInstance]
    # @param restraint_type [String] 'hands', 'feet', 'gag', 'blindfold', 'all'
    # @param actor [CharacterInstance]
    # @return [Hash] { success: Boolean, error: String?, removed: Array }
    def remove_restraint!(target, restraint_type, actor:)
      # Actor must be in same room and not be the target
      unless actor.current_room_id == target.current_room_id
        return { success: false, error: 'You must be in the same room.' }
      end

      if actor.id == target.id
        return { success: false, error: "You can't untie yourself." }
      end

      target_name = target.character.display_name_for(actor)
      removed = []

      case restraint_type.to_s.downcase
      when 'hands'
        unless target.hands_bound?
          return { success: false, error: "#{target_name}'s hands are not bound." }
        end

        target.update(hands_bound: false)
        removed << 'hands'

        # Check if no longer helpless
        clear_helpless!(target) unless target.unconscious?

      when 'feet'
        unless target.feet_bound?
          return { success: false, error: "#{target_name}'s feet are not bound." }
        end

        target.update(feet_bound: false)
        removed << 'feet'

      when 'gag'
        unless target.gagged?
          return { success: false, error: "#{target_name} is not gagged." }
        end

        target.update(is_gagged: false)
        removed << 'gag'

      when 'blindfold'
        unless target.blindfolded?
          return { success: false, error: "#{target_name} is not blindfolded." }
        end

        target.update(is_blindfolded: false)
        removed << 'blindfold'

      when 'all'
        removed << 'hands' if target.hands_bound?
        removed << 'feet' if target.feet_bound?
        removed << 'gag' if target.gagged?
        removed << 'blindfold' if target.blindfolded?

        if removed.empty?
          return { success: false, error: "#{target_name} has no restraints to remove." }
        end

        target.update(
          hands_bound: false,
          feet_bound: false,
          is_gagged: false,
          is_blindfolded: false
        )

        # Check if no longer helpless
        clear_helpless!(target) unless target.unconscious?

      else
        return { success: false, error: "Unknown restraint type: #{restraint_type}" }
      end

      { success: true, removed: removed }
    rescue StandardError => e
      warn "[PrisonerService] remove_restraint! failed: #{e.message}"
      { success: false, error: e.message }
    end

    # ========================================
    # Drag/Carry System
    # ========================================

    # Start dragging a helpless character
    # @param dragger [CharacterInstance]
    # @param target [CharacterInstance]
    # @return [Hash] { success: Boolean, error: String? }
    def start_drag!(dragger, target)
      unless can_manipulate?(dragger, target)
        return { success: false, error: 'You can only drag helpless characters in the same room.' }
      end

      if target.being_moved?
        return { success: false, error: "#{target.character.display_name_for(dragger)} is already being moved by someone." }
      end

      if dragger.dragging_someone? || dragger.carrying_someone?
        return { success: false, error: 'You are already moving someone.' }
      end

      target.update(being_dragged_by_id: dragger.id, being_carried_by_id: nil)

      { success: true }
    rescue StandardError => e
      warn "[PrisonerService] start_drag! failed: #{e.message}"
      { success: false, error: e.message }
    end

    # Stop dragging a character
    # @param dragger [CharacterInstance]
    # @return [Hash] { success: Boolean, error: String?, released: CharacterInstance? }
    def stop_drag!(dragger)
      prisoner = CharacterInstance.first(being_dragged_by_id: dragger.id)

      unless prisoner
        return { success: false, error: 'You are not dragging anyone.' }
      end

      prisoner.update(being_dragged_by_id: nil)

      { success: true, released: prisoner }
    rescue StandardError => e
      warn "[PrisonerService] stop_drag! failed: #{e.message}"
      { success: false, error: e.message }
    end

    # Pick up (carry) a helpless character
    # @param carrier [CharacterInstance]
    # @param target [CharacterInstance]
    # @return [Hash] { success: Boolean, error: String? }
    def pick_up!(carrier, target)
      unless can_manipulate?(carrier, target)
        return { success: false, error: 'You can only carry helpless characters in the same room.' }
      end

      # Check if being moved by someone OTHER than the carrier
      if target.being_moved? && target.captor&.id != carrier.id
        return { success: false, error: "#{target.character.display_name_for(carrier)} is already being moved by someone." }
      end

      # Check if moving someone OTHER than the target (allow upgrading drag to carry)
      already_dragging_target = target.being_dragged_by_id == carrier.id
      if !already_dragging_target && (carrier.dragging_someone? || carrier.carrying_someone?)
        return { success: false, error: 'You are already moving someone.' }
      end

      target.update(being_carried_by_id: carrier.id, being_dragged_by_id: nil)

      { success: true }
    rescue StandardError => e
      warn "[PrisonerService] pick_up! failed: #{e.message}"
      { success: false, error: e.message }
    end

    # Put down a carried character
    # @param carrier [CharacterInstance]
    # @return [Hash] { success: Boolean, error: String?, released: CharacterInstance? }
    def put_down!(carrier)
      prisoner = CharacterInstance.first(being_carried_by_id: carrier.id)

      unless prisoner
        return { success: false, error: 'You are not carrying anyone.' }
      end

      prisoner.update(being_carried_by_id: nil)

      { success: true, released: prisoner }
    rescue StandardError => e
      warn "[PrisonerService] put_down! failed: #{e.message}"
      { success: false, error: e.message }
    end

    # Get movement speed modifier for a character
    # Returns 1.0 for normal, higher for slower (e.g., 1.5 = 50% slower)
    # @param character_instance [CharacterInstance]
    # @return [Float]
    def movement_speed_modifier(character_instance)
      return DRAG_SPEED_MODIFIER if character_instance.dragging_someone?
      return DRAG_SPEED_MODIFIER if character_instance.carrying_someone?

      1.0
    end

    # Move prisoners along with their captor
    # Called by MovementService when a character moves rooms
    # @param captor [CharacterInstance]
    # @param new_room [Room]
    # @return [Array<CharacterInstance>] prisoners that were moved
    def move_prisoners!(captor, new_room)
      moved = []

      captor.prisoners.each do |prisoner|
        prisoner.teleport_to_room!(new_room)
        moved << prisoner
      end

      moved
    end

    # ========================================
    # Inventory Manipulation
    # ========================================

    # Search a helpless character's inventory
    # @param actor [CharacterInstance]
    # @param target [CharacterInstance]
    # @return [Hash] { success: Boolean, error: String?, items: Array, worn: Array, money: Hash }
    def search_inventory(actor, target)
      unless can_manipulate?(actor, target)
        return { success: false, error: 'You can only search helpless characters in the same room.' }
      end

      items = target.inventory_items.map do |item|
        { id: item.id, name: item.name, quantity: item.quantity }
      end

      worn = target.worn_items.map do |item|
        { id: item.id, name: item.name }
      end

      # Get wallet info
      money = {}
      target.wallets.each do |wallet|
        money[wallet.currency.code] = wallet.amount
      end

      {
        success: true,
        items: items,
        worn: worn,
        money: money
      }
    end

    # Take an item from a helpless character
    # @param actor [CharacterInstance]
    # @param target [CharacterInstance]
    # @param item [Item]
    # @return [Hash] { success: Boolean, error: String? }
    def take_item!(actor, target, item)
      unless can_manipulate?(actor, target)
        return { success: false, error: 'You can only take from helpless characters in the same room.' }
      end

      unless item.character_instance_id == target.id
        return { success: false, error: "#{target.character.display_name_for(actor)} doesn't have that item." }
      end

      # If worn, remove first
      item.update(worn: false) if item.worn?

      # Transfer to actor
      item.move_to_character(actor)

      { success: true, item: item }
    rescue StandardError => e
      warn "[PrisonerService] take_item! failed: #{e.message}"
      { success: false, error: e.message }
    end

    # Put clothing on a helpless character
    # @param actor [CharacterInstance]
    # @param target [CharacterInstance]
    # @param item [Item]
    # @return [Hash] { success: Boolean, error: String? }
    def dress_item!(actor, target, item)
      unless can_manipulate?(actor, target)
        return { success: false, error: 'You can only dress helpless characters in the same room.' }
      end

      unless item.character_instance_id == actor.id
        return { success: false, error: "You don't have that item." }
      end

      unless item.clothing? || item.jewelry?
        return { success: false, error: "#{item.name} is not wearable." }
      end

      # Piercings require the target to have a piercing hole - too complex for this flow
      if item.piercing?
        return { success: false, error: "Piercings cannot be put on someone else - they require a specific body position." }
      end

      # Transfer and wear
      item.move_to_character(target)
      wear_result = item.wear!
      return { success: false, error: wear_result } if wear_result.is_a?(String)

      { success: true, item: item }
    rescue StandardError => e
      warn "[PrisonerService] dress_item! failed: #{e.message}"
      { success: false, error: e.message }
    end

    # Remove clothing from a helpless character
    # @param actor [CharacterInstance]
    # @param target [CharacterInstance]
    # @param item [Item, nil] if nil, removes all worn items
    # @return [Hash] { success: Boolean, error: String?, removed: Array }
    def undress_item!(actor, target, item = nil)
      unless can_manipulate?(actor, target)
        return { success: false, error: 'You can only undress helpless characters in the same room.' }
      end

      removed = []

      if item
        unless item.character_instance_id == target.id && item.worn?
          return { success: false, error: "#{target.character.display_name_for(actor)} is not wearing that." }
        end

        item.remove!
        removed << item
      else
        # Remove all worn items
        target.worn_items.each do |worn_item|
          worn_item.remove!
          removed << worn_item
        end
      end

      { success: true, removed: removed }
    rescue StandardError => e
      warn "[PrisonerService] undress_item! failed: #{e.message}"
      { success: false, error: e.message }
    end

    # ========================================
    # Sensory Restrictions
    # ========================================

    # Check if character can speak
    # @param character_instance [CharacterInstance]
    # @return [Boolean]
    def can_speak?(character_instance)
      !character_instance.gagged?
    end

    # Check if character can see the world (not blindfolded)
    # @param character_instance [CharacterInstance]
    # @return [Boolean]
    def can_see?(character_instance)
      !character_instance.blindfolded?
    end

    # Check if character can move independently
    # @param character_instance [CharacterInstance]
    # @return [Boolean]
    def can_move_independently?(character_instance)
      character_instance.can_move_independently?
    end

    # Get a blindfolded character's description of the room (hearing only)
    # @param character_instance [CharacterInstance]
    # @param room [Room]
    # @return [String]
    def blindfolded_room_description(character_instance, room)
      # Count people in room
      char_count = CharacterInstance.where(
        current_room_id: room.id,
        online: true
      ).exclude(id: character_instance.id).count

      parts = ["You can't see anything through the blindfold."]

      if char_count.zero?
        parts << 'The room seems quiet and empty.'
      elsif char_count == 1
        parts << 'You hear someone nearby.'
      else
        parts << "You hear #{char_count} people nearby."
      end

      # Could add more ambient sounds based on room type here

      parts.join(' ')
    end

    # ========================================
    # Voluntary Helpless Toggle
    # ========================================

    # Toggle voluntary helpless state
    # @param character_instance [CharacterInstance]
    # @param enable [Boolean, nil] if nil, toggles current state
    # @return [Hash] { success: Boolean, enabled: Boolean }
    def toggle_helpless!(character_instance, enable: nil)
      # Can't toggle if unconscious or bound
      if character_instance.unconscious?
        return { success: false, error: "You can't do that while unconscious." }
      end

      if character_instance.hands_bound?
        return { success: false, error: 'Your hands are bound - you are already helpless.' }
      end

      current_state = character_instance.helpless?
      new_state = enable.nil? ? !current_state : enable

      if new_state
        make_helpless!(character_instance, reason: 'voluntary')
      else
        clear_helpless!(character_instance)
      end

      { success: true, enabled: new_state }
    end
  end
end
