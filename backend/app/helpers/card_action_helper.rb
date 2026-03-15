# frozen_string_literal: true

# Helper for standardized card game actions (draw, deal, discard, etc.)
# Reduces duplication across card commands
module CardActionHelper
  # Parse draw syntax: [number] [faceup|facedown]
  # @param text [String] Input text to parse
  # @param default_count [Integer] Default card count (default: 1)
  # @param default_facedown [Boolean] Default face orientation (default: true)
  # @return [Hash] { count: Integer, facedown: Boolean }
  def parse_draw_syntax(text, default_count: 1, default_facedown: true)
    count = default_count
    facedown = default_facedown

    return { count: count, facedown: facedown } if blank?(text)

    text = text.strip

    # Parse number
    if text =~ /^(\d+)/
      count = Regexp.last_match(1).to_i
      count = 1 if count < 1
    end

    # Parse face orientation (facedown is default, only check for faceup)
    facedown = !text.match?(/\bface\s*up\b|\bfaceup\b/i)

    { count: count, facedown: facedown }
  end

  # Get display names for cards by their IDs
  # @param card_ids [Array<Integer>] Card IDs
  # @return [Array<String>] Display names
  def card_display_names(card_ids)
    return [] if card_ids.nil? || card_ids.empty?

    # display_name is a computed method, so we need to load objects
    Card.where(id: card_ids).map(&:display_name)
  end

  # Get face type string
  # @param facedown [Boolean] Whether cards are face down
  # @return [String] 'face down' or 'face up'
  def face_type_string(facedown)
    facedown ? 'face down' : 'face up'
  end

  # Get singular/plural card word
  # @param count [Integer] Number of cards
  # @return [String] 'card' or 'cards'
  def card_word(count)
    count == 1 ? 'card' : 'cards'
  end

  # Add cards to a hand (character instance or deck center)
  # @param holder [CharacterInstance, Deck] The card holder
  # @param card_ids [Array<Integer>] Card IDs to add
  # @param facedown [Boolean] Whether to add face down
  # @param to_center [Boolean] If true, add to deck center instead of hand
  def add_cards_to_holder(holder, card_ids, facedown:, to_center: false)
    if to_center
      # Adding to deck center
      if facedown
        holder.add_to_center_facedown(card_ids)
      else
        holder.add_to_center_faceup(card_ids)
      end
    else
      # Adding to character hand
      if facedown
        holder.add_cards_facedown(card_ids)
      else
        holder.add_cards_faceup(card_ids)
      end
    end
  end

  # Build draw message for the actor
  # @param count [Integer] Number of cards
  # @param facedown [Boolean] Whether face down
  # @param card_names [Array<String>] Card display names
  # @param destination [String] Where cards went (nil for hand, "center" for table)
  # @return [String] Message for the actor
  def draw_self_message(count:, facedown:, card_names:, destination: nil)
    dest_text = destination ? " to the #{destination}" : ''
    "You draw #{count} #{card_word(count)}#{dest_text} #{face_type_string(facedown)}: #{card_names.join(', ')}"
  end

  # Build draw message for observers
  # @param actor_name [String] Actor's full name
  # @param count [Integer] Number of cards
  # @param facedown [Boolean] Whether face down
  # @param card_names [Array<String>] Card display names
  # @param destination [String] Where cards went (nil for hand, "center" for table)
  # @return [String] Message for observers
  def draw_others_message(actor_name:, count:, facedown:, card_names:, destination: nil)
    dest_text = destination ? " to the #{destination}" : ''

    if facedown
      "#{actor_name} draws #{count} #{card_word(count)}#{dest_text} face down."
    else
      "#{actor_name} draws #{count} #{card_word(count)}#{dest_text} face up: #{card_names.join(', ')}"
    end
  end

  # Validate deck has enough cards
  # @param deck [Deck] The deck to check
  # @param count [Integer] Number of cards needed
  # @return [String, nil] Error message or nil if OK
  def validate_deck_count(deck, count)
    return nil if deck.remaining_count >= count

    "The deck only has #{deck.remaining_count} cards remaining."
  end

  # Check if player is in a card game
  # @return [Deck, nil] The current deck or nil with error message
  def require_card_game
    deck = character_instance.current_deck
    return nil unless deck

    deck
  end
end
