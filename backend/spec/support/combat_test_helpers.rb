# frozen_string_literal: true

# Helper methods for combat testing
# Include this module in tests tagged with :combat
#
# @example
#   RSpec.describe "Combat", :combat do
#     include CombatTestHelpers
#
#     it "tests melee" do
#       position_for_melee(attacker_p, defender_p)
#     end
#   end
module CombatTestHelpers
  # Position attacker adjacent to defender for melee range (distance = 1)
  # @param attacker_p [FightParticipant] the attacker
  # @param defender_p [FightParticipant] the defender
  def position_for_melee(attacker_p, defender_p)
    attacker_p.update(hex_x: defender_p.hex_x, hex_y: defender_p.hex_y - 1)
  end

  # Position attacker at a specific distance from defender
  # @param attacker_p [FightParticipant] the attacker
  # @param defender_p [FightParticipant] the defender
  # @param distance [Integer] hex distance (default: 5)
  def position_at_range(attacker_p, defender_p, distance: 5)
    attacker_p.update(hex_x: defender_p.hex_x + distance, hex_y: defender_p.hex_y)
  end

  # Position both participants at specific coordinates
  # @param attacker_p [FightParticipant] the attacker
  # @param defender_p [FightParticipant] the defender
  # @param attacker_pos [Array<Integer>] [x, y] for attacker
  # @param defender_pos [Array<Integer>] [x, y] for defender
  def position_participants(attacker_p, defender_p, attacker_pos:, defender_pos:)
    attacker_p.update(hex_x: attacker_pos[0], hex_y: attacker_pos[1])
    defender_p.update(hex_x: defender_pos[0], hex_y: defender_pos[1])
  end

  # Create and equip a ranged weapon for a participant
  # @param participant [FightParticipant] the participant to arm
  # @param range [Integer] weapon range in hexes (default: 5)
  # @return [Item] the created weapon
  def give_ranged_weapon(participant, range: 5)
    # Create unified_object_type with weapon category
    weapon_type = create(:unified_object_type, category: 'weapon', subcategory: 'ranged')
    # Map range to weapon_range string
    weapon_range = case range
                   when 0..2 then 'melee'
                   when 3..7 then 'short'
                   when 8..12 then 'medium'
                   else 'long'
                   end
    pattern = create(:pattern, unified_object_type: weapon_type,
                     is_ranged: true, is_melee: false, weapon_range: weapon_range)
    weapon = create(:item,
                    pattern: pattern,
                    character_instance: participant.character_instance,
                    equipped: true)
    participant.update(ranged_weapon_id: weapon.id)
    weapon
  end

  # Create and equip a melee weapon for a participant
  # @param participant [FightParticipant] the participant to arm
  # @param speed [Integer] attack speed (default: 5)
  # @return [Item] the created weapon
  def give_melee_weapon(participant, speed: 5)
    # Create unified_object_type with weapon category
    weapon_type = create(:unified_object_type, category: 'weapon', subcategory: 'melee')
    pattern = create(:pattern, unified_object_type: weapon_type,
                     is_melee: true, is_ranged: false, attack_speed: speed, weapon_range: 'melee')
    weapon = create(:item,
                    pattern: pattern,
                    character_instance: participant.character_instance,
                    equipped: true)
    participant.update(melee_weapon_id: weapon.id)
    weapon
  end

  # Assert that an attacker can hit their target (within range)
  # Fails with helpful positioning suggestion if out of range
  # @param attacker_p [FightParticipant] the attacker
  # @param target_p [FightParticipant] the target
  def assert_attack_can_hit(attacker_p, target_p)
    distance = attacker_p.hex_distance_to(target_p)
    weapon = attacker_p.effective_weapon
    max_range = weapon&.pattern&.range_in_hexes || 1

    expect(distance).to be <= max_range,
                        "Attack will fail: distance #{distance} > max_range #{max_range}. " \
                        "Position attacker at hex_x: #{target_p.hex_x}, " \
                        "hex_y: #{target_p.hex_y - 1} for melee range, or give a ranged weapon."
  end

  # Set up a complete combat turn with target and action
  # @param participant [FightParticipant] the participant
  # @param target [FightParticipant] the target
  # @param action [String] main action (default: 'attack')
  def setup_combat_turn(participant, target, action: 'attack')
    participant.update(
      target_participant_id: target.id,
      main_action: action,
      movement_action: 'stand_still'
    )
  end

  # Complete a full combat round for all participants
  # @param fight_service [FightService] the fight service
  # @return [Hash] the resolution result with :events and :roll_display
  def complete_combat_round(fight_service)
    fight = fight_service.fight

    # Mark all participants as input complete
    fight.active_participants.each(&:complete_input!)

    # Resolve the round
    result = fight_service.resolve_round!

    # Check if fight should continue
    unless fight_service.should_end?
      fight_service.next_round!
    end

    result
  end

  # Start a fight with both participants positioned for melee
  # @param room [Room] the room for the fight
  # @param attacker [CharacterInstance] the attacker
  # @param defender [CharacterInstance] the defender
  # @return [Hash] with :fight_service, :attacker_p, :defender_p
  def start_melee_ready_fight(room, attacker, defender)
    fight_service = FightService.start_fight(room: room, initiator: attacker, target: defender)

    attacker_p = fight_service.participant_for(attacker)
    defender_p = fight_service.participant_for(defender)

    # Position for melee combat
    position_for_melee(attacker_p, defender_p)

    # Set up initial targets
    setup_combat_turn(attacker_p, defender_p)
    setup_combat_turn(defender_p, attacker_p)

    {
      fight_service: fight_service,
      fight: fight_service.fight,
      attacker_p: attacker_p,
      defender_p: defender_p
    }
  end

  # Clean up any stale fights for a character instance
  # @param character_instance [CharacterInstance] the character
  def cleanup_fights_for(character_instance)
    FightParticipant.where(character_instance_id: character_instance.id)
                    .eager(:fight)
                    .all
                    .each do |fp|
      fp.fight.update(status: 'complete') if fp.fight&.ongoing?
    end
  end

  # Count events of a specific type from resolution result
  # @param result [Hash] the resolution result
  # @param event_type [String] the event type to count
  # @return [Integer] count of matching events
  def count_events(result, event_type)
    (result[:events] || []).count { |e| e[:event_type] == event_type }
  end

  # Get all events of a specific type from resolution result
  # @param result [Hash] the resolution result
  # @param event_type [String] the event type to filter
  # @return [Array<Hash>] matching events
  def filter_events(result, event_type)
    (result[:events] || []).select { |e| e[:event_type] == event_type }
  end

  # Verify no out_of_range events occurred
  # @param result [Hash] the resolution result
  def assert_no_range_failures(result)
    range_failures = filter_events(result, 'out_of_range')
    expect(range_failures).to be_empty,
                              "Unexpected range failures: #{range_failures.map { |e| "#{e[:actor_name]} -> #{e[:target_name]}" }.join(', ')}"
  end
end

RSpec.configure do |config|
  config.include CombatTestHelpers, :combat
end
