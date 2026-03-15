# frozen_string_literal: true

# ContactHistoryService provides recent contact lookups for the memo system.
# Returns both people you've sent memos to AND received memos from,
# ordered by most recent contact.
#
# Example usage:
#   ContactHistoryService.recent_contacts(character) # => [{id: 1, name: "Alice", last_contact: Time}]
#
class ContactHistoryService
  class << self
    # Get recent conversation partners (sent OR received memos)
    # @param character [Character] the character to get contacts for
    # @param limit [Integer] maximum number of contacts to return
    # @return [Array<Hash>] array of {id:, name:, last_contact:} hashes
    def recent_contacts(character, limit: 10)
      return [] unless character

      partner_times = {}

      # Get people we've sent memos to
      sent_memos = Memo.where(sender_id: character.id)
                       .select(:recipient_id, Sequel.function(:max, :created_at).as(:last_contact))
                       .group(:recipient_id)
                       .all

      sent_memos.each do |row|
        partner_id = row[:recipient_id]
        next unless partner_id
        partner_times[partner_id] = row[:last_contact]
      end

      # Get people we've received memos from
      received_memos = Memo.where(recipient_id: character.id)
                           .select(:sender_id, Sequel.function(:max, :created_at).as(:last_contact))
                           .group(:sender_id)
                           .all

      received_memos.each do |row|
        partner_id = row[:sender_id]
        next unless partner_id
        next if partner_id == character.id # Skip self

        # Keep the most recent contact time
        existing = partner_times[partner_id]
        new_time = row[:last_contact]
        partner_times[partner_id] = [existing, new_time].compact.max
      end

      # Sort by most recent contact and convert to output format
      sorted = partner_times.sort_by { |_, time| time || Time.at(0) }.reverse

      sorted.first(limit).filter_map do |partner_id, last_contact|
        char = Character[partner_id]
        next unless char

        {
          id: char.id,
          name: char.full_name,
          last_contact: last_contact
        }
      end
    rescue StandardError => e
      warn "[ContactHistoryService] Failed to get recent contacts: #{e.message}"
      []
    end
  end
end
