# frozen_string_literal: true

class Card < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  # Associations
  many_to_one :deck_pattern

  def validate
    super
    validates_presence [:deck_pattern_id, :name]
    validates_max_length 255, :name
    validates_max_length 50, :suit if suit
    validates_max_length 50, :rank if rank
  end

  # Display name for the card (e.g., "Ace of Spades" or just the name)
  def display_name
    # For Major Arcana and other named cards, use the name directly
    return name if suit == 'Major Arcana' || suit == 'Joker' || suit.nil?

    # For standard playing cards and minor arcana, use "rank of suit" format
    if rank
      "#{rank} of #{suit}"
    else
      name
    end
  end

  # Short display (e.g., "A♠" for Ace of Spades)
  def short_display
    return name unless suit && rank

    suit_symbol = case suit.downcase
                  when 'hearts' then "\u2665"
                  when 'diamonds' then "\u2666"
                  when 'clubs' then "\u2663"
                  when 'spades' then "\u2660"
                  else suit[0]
                  end

    rank_short = case rank.downcase
                 when 'ace' then 'A'
                 when 'jack' then 'J'
                 when 'queen' then 'Q'
                 when 'king' then 'K'
                 else rank
                 end

    "#{rank_short}#{suit_symbol}"
  end

  # Check if this is a face card
  def face_card?
    return false unless rank

    %w[jack queen king].include?(rank.downcase)
  end

  # Numeric value for comparing cards (Ace high)
  def numeric_value
    return nil unless rank

    case rank.downcase
    when 'ace' then 14
    when 'king' then 13
    when 'queen' then 12
    when 'jack' then 11
    else
      rank.to_i
    end
  end
end
