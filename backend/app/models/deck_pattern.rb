# frozen_string_literal: true

class DeckPattern < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  # Associations
  many_to_one :creator, class: :Character
  one_to_many :cards
  one_to_many :decks, class: :Deck
  one_to_many :deck_ownerships, class: :DeckOwnership
  many_to_many :owners, class: :Character, join_table: :deck_ownership, left_key: :deck_pattern_id, right_key: :character_id

  def validate
    super
    validates_presence [:name]
    validates_max_length 255, :name
    validates_numeric :cost, minimum: 0 if cost
  end

  # Create a new deck instance from this pattern for a character
  def create_deck_for(character_instance)
    card_id_list = cards_dataset.order(:display_order, :id).select_map(:id).shuffle
    Deck.create(
      deck_pattern: self,
      dealer_id: character_instance.id,
      card_ids: Sequel.pg_array(card_id_list, :integer)
    )
  end

  # Check if a character owns this deck pattern
  def owned_by?(character)
    return true if is_public
    return true if creator_id == character.id

    deck_ownerships_dataset.where(character_id: character.id).any?
  end

  # Grant ownership to a character
  def grant_to(character)
    return if owned_by?(character)

    DeckOwnership.create(
      deck_pattern_id: id,
      character_id: character.id
    )
  end

  # Card count for display
  def card_count
    cards_dataset.count
  end

  # Create a standard 52-card playing deck pattern
  def self.create_standard_deck(creator:)
    pattern = create(
      name: 'Standard Playing Cards',
      description: 'A standard 52-card deck of playing cards',
      creator: creator,
      is_public: true
    )

    suits = %w[Hearts Diamonds Clubs Spades]
    ranks = %w[Ace 2 3 4 5 6 7 8 9 10 Jack Queen King]

    order = 0
    suits.each do |suit|
      ranks.each do |rank|
        Card.create(
          deck_pattern: pattern,
          name: "#{rank} of #{suit}",
          suit: suit,
          rank: rank,
          display_order: order
        )
        order += 1
      end
    end

    pattern
  end

  # Create a standard 52-card deck with 2 Jokers (54 cards)
  def self.create_standard_deck_with_jokers(creator:)
    pattern = create(
      name: 'Standard Playing Cards (with Jokers)',
      description: 'A standard 54-card deck with two jokers',
      creator: creator,
      is_public: true
    )

    suits = %w[Hearts Diamonds Clubs Spades]
    ranks = %w[Ace 2 3 4 5 6 7 8 9 10 Jack Queen King]

    order = 0
    suits.each do |suit|
      ranks.each do |rank|
        Card.create(
          deck_pattern: pattern,
          name: "#{rank} of #{suit}",
          suit: suit,
          rank: rank,
          display_order: order
        )
        order += 1
      end
    end

    # Add jokers
    Card.create(deck_pattern: pattern, name: 'Red Joker', rank: 'Joker', display_order: 52)
    Card.create(deck_pattern: pattern, name: 'Black Joker', rank: 'Joker', display_order: 53)

    pattern
  end

  # Create a Tarot deck (78 cards: 22 Major Arcana + 56 Minor Arcana)
  def self.create_tarot_deck(creator:)
    pattern = create(
      name: 'Tarot Deck',
      description: 'A 78-card tarot deck with Major and Minor Arcana',
      creator: creator,
      is_public: true
    )

    order = 0

    # Major Arcana (22 cards, numbered 0-21)
    major_arcana = [
      'The Fool', 'The Magician', 'The High Priestess', 'The Empress', 'The Emperor',
      'The Hierophant', 'The Lovers', 'The Chariot', 'Strength', 'The Hermit',
      'Wheel of Fortune', 'Justice', 'The Hanged Man', 'Death', 'Temperance',
      'The Devil', 'The Tower', 'The Star', 'The Moon', 'The Sun',
      'Judgement', 'The World'
    ]

    major_arcana.each_with_index do |name, idx|
      Card.create(
        deck_pattern: pattern,
        name: name,
        suit: 'Major Arcana',
        rank: idx.to_s,
        display_order: order
      )
      order += 1
    end

    # Minor Arcana (56 cards: 4 suits x 14 cards)
    suits = %w[Wands Cups Swords Pentacles]
    ranks = %w[Ace 2 3 4 5 6 7 8 9 10 Page Knight Queen King]

    suits.each do |suit|
      ranks.each do |rank|
        Card.create(
          deck_pattern: pattern,
          name: "#{rank} of #{suit}",
          suit: suit,
          rank: rank,
          display_order: order
        )
        order += 1
      end
    end

    pattern
  end

  # Check if pattern is accessible (owned or public)
  def accessible_by?(character)
    is_public || owned_by?(character)
  end

  # Get all patterns accessible to a character
  def self.accessible_by(character)
    where(is_public: true)
      .or(id: DeckOwnership.where(character_id: character.id).select(:deck_pattern_id))
  end
end
