# frozen_string_literal: true

# TravelPartyMember - Tracks membership and invite status in travel parties
#
# Members go through states:
# - pending: Invited but hasn't responded
# - accepted: Agreed to join the journey
# - declined: Refused the invitation
#
class TravelPartyMember < Sequel::Model
  include StatusEnum

  many_to_one :party, class: 'TravelParty', key: :party_id
  many_to_one :character_instance, class: 'CharacterInstance', key: :character_instance_id

  status_enum :status, %w[pending accepted declined]

  # Accept the invitation
  # @return [Boolean] success
  def accept!
    return false unless status == 'pending'
    return false unless party&.status == 'assembling'

    update(status: 'accepted', responded_at: Time.now)
    true
  end

  # Decline the invitation
  # @return [Boolean] success
  def decline!
    return false unless status == 'pending'
    return false unless party&.status == 'assembling'

    update(status: 'declined', responded_at: Time.now)
    true
  end

  # Check if this is the party leader
  # @return [Boolean]
  def leader?
    party&.leader_id == character_instance_id
  end

  # Get display status for UI
  # @return [String]
  def display_status
    case status
    when 'pending' then 'Invited'
    when 'accepted' then 'Ready'
    when 'declined' then 'Declined'
    else status.capitalize
    end
  end
end
