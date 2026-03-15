# frozen_string_literal: true

class Deck < Sequel::Model(:deck)
  plugin :validation_helpers
  plugin :timestamps

  # Associations
  many_to_one :deck_pattern
  many_to_one :dealer, class: :CharacterInstance, key: :dealer_id

  def validate
    super
    validates_presence [:deck_pattern_id, :dealer_id]
  end

  def before_save
    super
    # Ensure card_ids is properly wrapped as a PostgreSQL integer array
    if card_ids.nil?
      self.card_ids = Sequel.pg_array([], :integer)
    elsif !card_ids.is_a?(Sequel::Postgres::PGArray)
      self.card_ids = Sequel.pg_array(Array(card_ids), :integer)
    end

    # Ensure center and discard arrays are properly wrapped (if columns exist)
    %i[center_faceup center_facedown discard_pile].each do |field|
      next unless respond_to?(field)

      val = send(field)
      if val.nil?
        send("#{field}=", Sequel.pg_array([], :integer))
      elsif !val.is_a?(Sequel::Postgres::PGArray)
        send("#{field}=", Sequel.pg_array(Array(val), :integer))
      end
    end
  end

  # Shuffle the deck
  def shuffle!
    update(card_ids: Sequel.pg_array(Array(card_ids).shuffle, :integer))
    self
  end

  # Draw cards from the deck (removes them from card_ids)
  def draw(count = 1)
    return [] if count < 1

    current_ids = Array(card_ids)
    return [] if current_ids.empty?

    count = [count, current_ids.length].min
    drawn_ids = current_ids.take(count)
    remaining_ids = current_ids.drop(count)

    update(card_ids: Sequel.pg_array(remaining_ids, :integer))
    drawn_ids
  end

  # Return cards to the deck
  def return_cards(ids)
    current_ids = Array(card_ids)
    update(card_ids: Sequel.pg_array(current_ids + Array(ids), :integer))
  end

  # Number of cards remaining in deck
  def remaining_count
    Array(card_ids).length
  end

  # Check if deck is empty
  def empty?
    remaining_count.zero?
  end

  # Reset deck with all cards from pattern
  def reset!
    all_card_ids = deck_pattern.cards_dataset.order(:display_order, :id).select_map(:id)
    update(card_ids: Sequel.pg_array(all_card_ids.shuffle, :integer))
    self
  end

  # Get all players in this card game (characters with current_deck_id pointing to this deck)
  def players
    CharacterInstance.where(current_deck_id: id)
  end

  # Get card objects for cards in deck
  def cards
    ids = Array(card_ids)
    return [] if ids.empty?

    Card.where(id: ids).all.sort_by { |c| ids.index(c.id) }
  end

  # Display name for the deck
  def display_name
    deck_pattern&.name || 'Card Deck'
  end

  # =====================
  # Center Card Methods
  # =====================

  # Get Card objects for center faceup cards
  def center_faceup_cards
    ids = Array(center_faceup)
    return [] if ids.empty?

    Card.where(id: ids).all.sort_by { |c| ids.index(c.id) }
  end

  # Get Card objects for center facedown cards
  def center_facedown_cards
    ids = Array(center_facedown)
    return [] if ids.empty?

    Card.where(id: ids).all.sort_by { |c| ids.index(c.id) }
  end

  # Get all center cards
  def all_center_cards
    center_faceup_cards + center_facedown_cards
  end

  # Count of center cards
  def center_count
    Array(center_faceup).length + Array(center_facedown).length
  end

  # Add cards to center faceup
  def add_to_center_faceup(card_ids)
    current = Array(center_faceup)
    update(center_faceup: Sequel.pg_array(current + Array(card_ids), :integer))
  end

  # Add cards to center facedown
  def add_to_center_facedown(card_ids)
    current = Array(center_facedown)
    update(center_facedown: Sequel.pg_array(current + Array(card_ids), :integer))
  end

  # Flip center cards from facedown to faceup
  def flip_center_cards(count = nil)
    facedown_ids = Array(center_facedown)
    return [] if facedown_ids.empty?

    to_flip = count ? facedown_ids.first(count) : facedown_ids.dup
    remaining_facedown = facedown_ids - to_flip
    new_faceup = Array(center_faceup) + to_flip

    update(
      center_facedown: Sequel.pg_array(remaining_facedown, :integer),
      center_faceup: Sequel.pg_array(new_faceup, :integer)
    )
    to_flip
  end

  # Clear all center cards, return their IDs
  def clear_center!
    card_ids_to_return = Array(center_faceup) + Array(center_facedown)
    update(
      center_faceup: Sequel.pg_array([], :integer),
      center_facedown: Sequel.pg_array([], :integer)
    )
    card_ids_to_return
  end

  # =====================
  # Discard Pile Methods
  # =====================

  # Get Card objects for discard pile
  def discard_cards
    ids = Array(discard_pile)
    return [] if ids.empty?

    Card.where(id: ids).all.sort_by { |c| ids.index(c.id) }
  end

  # Count of cards in discard pile
  def discard_count
    Array(discard_pile).length
  end

  # Add cards to discard pile
  def add_to_discard(card_ids)
    current = Array(discard_pile)
    update(discard_pile: Sequel.pg_array(current + Array(card_ids), :integer))
  end

  # Return cards from discard pile to bottom of deck
  def return_from_discard(count = nil)
    pile = Array(discard_pile)
    return [] if pile.empty?

    to_return = count ? pile.first(count) : pile.dup
    remaining_pile = pile - to_return
    new_deck = Array(card_ids) + to_return

    update(
      discard_pile: Sequel.pg_array(remaining_pile, :integer),
      card_ids: Sequel.pg_array(new_deck, :integer)
    )
    to_return
  end

  # Clear discard pile, return card IDs
  def clear_discard!
    cards_to_return = Array(discard_pile)
    update(discard_pile: Sequel.pg_array([], :integer))
    cards_to_return
  end

  # =====================
  # Updated collect_all_cards!
  # =====================

  # Collect all cards from players, center, and discard back into deck
  def collect_all_cards!
    all_card_ids = deck_pattern.cards_dataset.select_map(:id)

    # Clear all players' hands
    players.each do |player|
      player.update(
        cards_faceup: Sequel.pg_array([], :integer),
        cards_facedown: Sequel.pg_array([], :integer)
      )
    end

    # Reset deck with shuffled cards, clear center and discard (if columns exist)
    update_hash = { card_ids: Sequel.pg_array(all_card_ids.shuffle, :integer) }

    if respond_to?(:center_faceup)
      update_hash[:center_faceup] = Sequel.pg_array([], :integer)
      update_hash[:center_facedown] = Sequel.pg_array([], :integer)
      update_hash[:discard_pile] = Sequel.pg_array([], :integer)
    end

    update(update_hash)
    self
  end
end
