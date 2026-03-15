# frozen_string_literal: true

# TravelParty - Manages group journey assembly before departure
#
# A travel party allows a leader to assemble a group of characters
# who will travel together. Members can be invited and must accept
# before the journey can launch.
#
# Usage:
#   party = TravelParty.create_for(character_instance, destination, travel_mode: 'land')
#   party.invite!(other_character)
#   party.launch! if party.can_launch?
#
class TravelParty < Sequel::Model
  include StatusEnum

  many_to_one :leader, class: 'CharacterInstance', key: :leader_id
  many_to_one :destination, class: 'Location', key: :destination_id
  many_to_one :origin_room, class: 'Room', key: :origin_room_id
  one_to_many :members, class: 'TravelPartyMember', key: :party_id

  status_enum :status, %w[assembling departed cancelled]

  plugin :timestamps, update_on_create: true

  # Create a new travel party with the leader as first member
  def self.create_for(character_instance, destination, travel_mode: nil, flashback_mode: nil)
    party = create(
      leader_id: character_instance.id,
      destination_id: destination.id,
      origin_room_id: character_instance.current_room_id,
      travel_mode: travel_mode,
      flashback_mode: flashback_mode,
      status: 'assembling'
    )

    # Leader is automatically a member and accepted
    TravelPartyMember.create(
      party_id: party.id,
      character_instance_id: character_instance.id,
      status: 'accepted',
      responded_at: Time.now
    )

    party
  end

  # Invite a character to join the party
  # @param character_instance [CharacterInstance] The character to invite
  # @return [Hash] Result with success status and member record
  def invite!(character_instance)
    if member?(character_instance)
      return { success: false, error: 'Already a member of this party' }
    end

    unless status == 'assembling'
      return { success: false, error: 'Party is no longer assembling' }
    end

    member = TravelPartyMember.create(
      party_id: id,
      character_instance_id: character_instance.id,
      status: 'pending'
    )

    # Send quickmenu invite to the character
    send_party_invite(character_instance, member)

    { success: true, member: member }
  end

  # Send party invite quickmenu to a character
  # @param character_instance [CharacterInstance]
  # @param member [TravelPartyMember]
  def send_party_invite(character_instance, member)
    leader_name = leader&.character&.full_name || 'Someone'
    dest_name = destination&.name || 'a destination'

    interaction_id = SecureRandom.uuid
    menu_data = {
      type: 'quickmenu',
      interaction_id: interaction_id,
      prompt: "#{leader_name} invites you to travel to #{dest_name}",
      options: [
        { key: 'accept', label: 'Accept', description: 'Join the travel party' },
        { key: 'decline', label: 'Decline', description: 'Refuse the invitation' }
      ],
      context: {
        handler: 'party_invite',
        party_id: id,
        member_id: member.id
      },
      created_at: Time.now.iso8601
    }

    OutputHelper.store_agent_interaction(character_instance, interaction_id, menu_data)

    # Also broadcast a message to the character
    BroadcastService.to_character(
      character_instance,
      "#{leader_name} invites you to travel to #{dest_name}. Type 'accept' or 'decline'.",
      type: :social
    )
  end

  # Remove a member from the party
  # @param character_instance [CharacterInstance]
  def remove_member!(character_instance)
    return if character_instance.id == leader_id # Can't remove leader

    membership = membership_for(character_instance)
    membership&.destroy
  end

  # Check if a character is a member (any status)
  # @param character_instance [CharacterInstance]
  # @return [Boolean]
  def member?(character_instance)
    !membership_for(character_instance).nil?
  end

  # Get the membership record for a character
  # @param character_instance [CharacterInstance]
  # @return [TravelPartyMember, nil]
  def membership_for(character_instance)
    members_dataset.where(character_instance_id: character_instance.id).first
  end

  # Get all members who have accepted
  # @return [Array<TravelPartyMember>]
  def accepted_members
    members_dataset.where(status: 'accepted').all
  end

  # Get character instances of accepted members
  # @return [Array<CharacterInstance>]
  def accepted_character_instances
    accepted_members.map(&:character_instance)
  end

  # Get all pending invites
  # @return [Array<TravelPartyMember>]
  def pending_invites
    members_dataset.where(status: 'pending').all
  end

  # Get all members who declined
  # @return [Array<TravelPartyMember>]
  def declined_members
    members_dataset.where(status: 'declined').all
  end

  # Check if the party can be launched
  # Requires at least the leader to have accepted (which they always have)
  # @return [Boolean]
  def can_launch?
    return false unless status == 'assembling'

    # Must have at least one accepted member (the leader)
    accepted_members.any?
  end

  # Calculate minimum flashback time among accepted members
  # @return [Integer] seconds of flashback time available to all members
  def minimum_flashback_time
    accepted_character_instances.map(&:flashback_time_available).min || 0
  end

  # Launch the journey for all accepted members
  # @return [Hash] Result with success status and journey info
  def launch!
    return { success: false, error: 'Party cannot launch' } unless can_launch?

    # Get all accepted member character instances
    travelers = accepted_character_instances
    co_traveler_ids = travelers.map(&:id)

    # Start journey using JourneyService
    result = JourneyService.start_party_journey(
      travelers: travelers,
      destination: destination,
      travel_mode: travel_mode,
      flashback_mode: flashback_mode,
      co_traveler_ids: co_traveler_ids
    )

    if result[:success]
      update(status: 'departed')
    end

    result
  end

  # Cancel the party
  def cancel!
    update(status: 'cancelled')
  end

  # Get party status summary for display
  # @return [Hash]
  def status_summary
    {
      id: id,
      leader_name: leader&.character&.full_name,
      destination: {
        id: destination_id,
        name: destination&.name,
        city_name: destination&.city_name,
        globe_hex_id: destination&.globe_hex_id
      },
      travel_mode: travel_mode,
      flashback_mode: flashback_mode,
      status: status,
      members: members.map do |m|
        {
          name: m.character_instance&.character&.full_name,
          status: m.status,
          is_leader: m.leader?
        }
      end,
      accepted_count: accepted_members.count,
      pending_count: pending_invites.count,
      can_launch: can_launch?,
      minimum_flashback_time: minimum_flashback_time
    }
  end
end
