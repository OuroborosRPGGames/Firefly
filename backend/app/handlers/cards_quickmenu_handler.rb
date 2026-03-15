# frozen_string_literal: true

# Manages card game quickmenu flows.
# Provides a unified interface for all card game actions through a single menu.
#
# Usage:
#   CardsQuickmenuHandler.show_menu(char_instance)
#   CardsQuickmenuHandler.handle_response(char_instance, context, response_key)
#
class CardsQuickmenuHandler
  include StringHelper
  include CardActionHelper
  include PersonalizedBroadcastConcern

  # Stage configuration with prompts
  STAGES = {
    'start_game' => { prompt: 'Choose a deck type:' },
    'main_menu' => { prompt: 'Card Actions:' },
    'draw_count' => { prompt: 'How many cards to draw?' },
    'draw_face' => { prompt: 'Face up or face down?' },
    'play_card' => { prompt: 'Which card to play?' },
    'play_face' => { prompt: 'Play face up or face down?' },
    'discard_card' => { prompt: 'Which card to discard?' },
    'discard_face' => { prompt: 'Discard face up or face down?' },
    'turnover_count' => { prompt: 'How many cards to turn over?' },
    'deal_count' => { prompt: 'How many cards to deal?' },
    'deal_player' => { prompt: 'Deal to which player?' },
    'deal_face' => { prompt: 'Deal face up or face down?' },
    'center_draw_count' => { prompt: 'How many cards to draw to center?' },
    'center_draw_face' => { prompt: 'Face up or face down?' },
    'center_turnover_count' => { prompt: 'How many center cards to flip?' },
    'return_count' => { prompt: 'How many cards to return from discard?' }
  }.freeze

  # Deck type configurations
  DECK_TYPES = {
    'standard' => { label: 'Standard Deck (52)', description: 'Standard playing cards without jokers' },
    'jokers' => { label: 'Deck with Jokers (54)', description: 'Standard playing cards with 2 jokers' },
    'tarot' => { label: 'Tarot Deck (78)', description: 'Full tarot deck with major and minor arcana' }
  }.freeze

  attr_reader :char_instance

  class << self
    # Show the current menu for a character
    def show_menu(char_instance)
      new(char_instance).show_current_menu
    end

    # Handle a response to a menu
    def handle_response(char_instance, context, response_key)
      new(char_instance, context).handle_response(response_key)
    end
  end

  def initialize(char_instance, context = {})
    @char_instance = char_instance
    @context = context || {}
  end

  # Show the quickmenu for the current state
  def show_current_menu
    stage = determine_stage
    build_menu_for_stage(stage)
  end

  # Handle a menu response
  def handle_response(response_key)
    stage = @context[:stage] || @context['stage'] || determine_stage

    # Handle close/cancel
    if response_key == 'close' || response_key == 'cancel'
      return { success: true, message: 'Card menu closed.', type: :message }
    end

    # Handle back navigation
    if response_key == 'back'
      return build_menu_for_stage('main_menu')
    end

    # Process the choice based on current stage
    process_stage_choice(stage, response_key)
  end

  private

  # Determine which stage to show based on current state
  def determine_stage
    deck = char_instance.current_deck
    deck ? 'main_menu' : 'start_game'
  end

  # Build menu for a specific stage
  def build_menu_for_stage(stage, extra_context = {})
    stage_config = STAGES[stage]
    return nil unless stage_config

    options = build_options_for_stage(stage)

    {
      type: :quickmenu,
      prompt: stage_config[:prompt],
      options: options,
      context: { command: 'cards', stage: stage }.merge(extra_context)
    }
  end

  # Process a choice for the given stage
  def process_stage_choice(stage, response)
    case stage
    when 'start_game'
      handle_start_game(response)
    when 'main_menu'
      handle_main_menu(response)
    when 'draw_count'
      handle_draw_count(response)
    when 'draw_face'
      handle_draw_face(response)
    when 'play_card'
      handle_play_card(response)
    when 'play_face'
      handle_play_face(response)
    when 'discard_card'
      handle_discard_card(response)
    when 'discard_face'
      handle_discard_face(response)
    when 'turnover_count'
      handle_turnover_count(response)
    when 'deal_count'
      handle_deal_count(response)
    when 'deal_player'
      handle_deal_player(response)
    when 'deal_face'
      handle_deal_face(response)
    when 'center_draw_count'
      handle_center_draw_count(response)
    when 'center_draw_face'
      handle_center_draw_face(response)
    when 'center_turnover_count'
      handle_center_turnover_count(response)
    when 'return_count'
      handle_return_count(response)
    else
      { success: false, error: "Unknown stage: #{stage}", type: :error }
    end
  end

  # Build options for a stage
  def build_options_for_stage(stage)
    case stage
    when 'start_game'
      build_start_game_options
    when 'main_menu'
      build_main_menu_options
    when 'draw_count', 'center_draw_count', 'deal_count'
      build_count_options(max_count: deck_remaining_count)
    when 'draw_face', 'play_face', 'discard_face', 'deal_face', 'center_draw_face'
      build_face_options
    when 'play_card', 'discard_card'
      build_card_selection_options
    when 'turnover_count'
      build_count_options(max_count: facedown_count_in_hand)
    when 'center_turnover_count'
      build_count_options(max_count: center_facedown_count)
    when 'return_count'
      build_count_options(max_count: discard_pile_count)
    when 'deal_player'
      build_player_selection_options
    else
      []
    end
  end

  # === Start Game ===

  def build_start_game_options
    DECK_TYPES.map do |key, config|
      { key: key, label: config[:label], description: config[:description] }
    end + [{ key: 'close', label: 'Close Menu', description: 'Close without starting a game' }]
  end

  def handle_start_game(deck_type)
    unless DECK_TYPES.key?(deck_type)
      return { success: false, error: 'Invalid deck type.', type: :error }
    end

    # Check if player already has a deck
    if char_instance.current_deck
      return { success: false, error: "You already have a deck. Use reshuffle from the menu to reset it.", type: :error }
    end

    # Find or create the deck pattern
    pattern = find_or_create_deck_pattern(deck_type.to_sym)
    unless pattern
      return { success: false, error: 'Could not find deck pattern.', type: :error }
    end

    # Create a deck instance for this player
    deck = Deck.create(
      deck_pattern_id: pattern.id,
      dealer_id: char_instance.id
    )

    # Initialize the deck with all cards from the pattern (shuffled)
    deck.reset!

    # Join the player to the deck
    char_instance.join_card_game!(deck)

    deck_name = case deck_type.to_sym
                when :jokers then 'standard deck with jokers (54 cards)'
                when :tarot then 'tarot deck (78 cards)'
                else 'standard deck (52 cards)'
                end

    # Broadcast to room
    broadcast_to_room_except(
      [char_instance],
      "#{char_instance.full_name} produces a #{deck_name}."
    )

    # Show main menu after starting
    result = build_menu_for_stage('main_menu')
    result[:message] = "You produce a #{deck_name}."
    result
  end

  # === Main Menu ===

  def build_main_menu_options
    options = []
    deck = char_instance.current_deck

    if deck
      # Player options
      options << { key: 'draw', label: 'Draw Cards', description: 'Draw cards from deck to your hand' } if deck.remaining_count.positive?

      if char_instance.has_cards?
        options << { key: 'play', label: 'Play a Card', description: 'Play a card from your hand' }
        options << { key: 'discard', label: 'Discard', description: 'Discard a card to the pile' }
        options << { key: 'showhand', label: 'Show Hand', description: 'Show your cards to everyone' }
        options << { key: 'turnover', label: 'Turn Over', description: 'Flip face-down cards to face-up' } if has_facedown_in_hand?
      end

      options << { key: 'viewdiscard', label: 'View Discard Pile', description: "#{deck.discard_count} cards" } if deck.discard_count.positive?
      options << { key: 'viewcenter', label: 'View Center', description: "#{deck.center_count} cards" } if deck.center_count.positive?

      # Dealer-only options
      if is_dealer?
        options << { key: 'deal', label: 'Deal Cards', description: 'Deal cards to another player' } if deck.remaining_count.positive?
        options << { key: 'centerdraw', label: 'Draw to Center', description: 'Draw cards to the table' } if deck.remaining_count.positive?
        options << { key: 'centerturnover', label: 'Flip Center Cards', description: 'Turn over cards in the center' } if center_facedown_count.positive?
        options << { key: 'return', label: 'Return Discards', description: 'Return cards from discard to deck' } if deck.discard_count.positive?
        options << { key: 'reshuffle', label: 'Reshuffle', description: 'Collect all cards and shuffle deck' }
      end

      options << { key: 'leave', label: 'Leave Game', description: 'Leave the card game' }
    end

    options << { key: 'close', label: 'Close Menu', description: 'Close the card menu' }
    options
  end

  def handle_main_menu(action)
    if dealer_only_action?(action) && !is_dealer?
      return dealer_required_error
    end

    case action
    when 'draw'
      build_menu_for_stage('draw_count')
    when 'play'
      build_menu_for_stage('play_card')
    when 'discard'
      build_menu_for_stage('discard_card')
    when 'showhand'
      execute_show_hand
    when 'turnover'
      build_menu_for_stage('turnover_count')
    when 'viewdiscard'
      execute_view_discard
    when 'viewcenter'
      execute_view_center
    when 'deal'
      build_menu_for_stage('deal_count')
    when 'centerdraw'
      build_menu_for_stage('center_draw_count')
    when 'centerturnover'
      build_menu_for_stage('center_turnover_count')
    when 'return'
      build_menu_for_stage('return_count')
    when 'reshuffle'
      execute_reshuffle
    when 'leave'
      execute_leave_game
    else
      { success: false, error: 'Invalid action.', type: :error }
    end
  end

  # === Draw Flow ===

  def handle_draw_count(count_str)
    count = count_str.to_i
    count = deck_remaining_count if count_str == 'all'

    if count < 1 || count > deck_remaining_count
      return { success: false, error: 'Invalid count.', type: :error }
    end

    build_menu_for_stage('draw_face', draw_count: count)
  end

  def handle_draw_face(face)
    count = @context[:draw_count] || @context['draw_count'] || 1
    facedown = (face == 'facedown')

    deck = char_instance.current_deck
    return { success: false, error: "You're not in a card game.", type: :error } unless deck

    # Draw cards from deck
    drawn_card_ids = deck.draw(count)

    # Add to player's hand
    add_cards_to_holder(char_instance, drawn_card_ids, facedown: facedown)

    # Get card names for message
    card_names = card_display_names(drawn_card_ids)

    # Build messages
    player_msg = draw_self_message(count: count, facedown: facedown, card_names: card_names)
    others_msg = draw_others_message(
      actor_name: char_instance.full_name,
      count: count,
      facedown: facedown,
      card_names: card_names
    )

    broadcast_to_room_except([char_instance], others_msg)

    result = build_menu_for_stage('main_menu')
    result[:message] = player_msg
    result[:data] = {
      action: 'draw',
      count: count,
      facedown: facedown,
      card_ids: drawn_card_ids,
      card_names: card_names,
      deck_remaining: deck.remaining_count
    }
    result
  end

  # === Play Card Flow ===

  def handle_play_card(card_key)
    card_id = card_key.to_i
    card = Card[card_id]

    unless card && char_instance.all_card_ids.include?(card_id)
      return { success: false, error: "You don't have that card.", type: :error }
    end

    build_menu_for_stage('play_face', selected_card_id: card_id)
  end

  def handle_play_face(face)
    card_id = @context[:selected_card_id] || @context['selected_card_id']
    card = Card[card_id]

    unless card && char_instance.all_card_ids.include?(card_id)
      return { success: false, error: "You don't have that card.", type: :error }
    end

    facedown = (face == 'facedown')

    # Remove from hand
    char_instance.remove_card(card_id)

    # Build messages
    if facedown
      broadcast_to_room_except([char_instance], "#{char_instance.full_name} plays a card face down.")
    else
      broadcast_to_room_except([char_instance], "#{char_instance.full_name} plays #{card.display_name} face up.")
    end

    face_type = facedown ? 'face down' : 'face up'
    result = build_menu_for_stage('main_menu')
    result[:message] = "You play #{card.display_name} #{face_type}."
    result[:data] = {
      action: 'play_card',
      card_id: card_id,
      card_name: card.display_name,
      facedown: facedown,
      cards_remaining: char_instance.card_count
    }
    result
  end

  # === Discard Flow ===

  def handle_discard_card(card_key)
    card_id = card_key.to_i
    card = Card[card_id]

    unless card && char_instance.all_card_ids.include?(card_id)
      return { success: false, error: "You don't have that card.", type: :error }
    end

    build_menu_for_stage('discard_face', selected_card_id: card_id)
  end

  def handle_discard_face(face)
    card_id = @context[:selected_card_id] || @context['selected_card_id']
    card = Card[card_id]
    deck = char_instance.current_deck

    unless card && char_instance.all_card_ids.include?(card_id)
      return { success: false, error: "You don't have that card.", type: :error }
    end

    unless deck
      return { success: false, error: "You're not in a card game.", type: :error }
    end

    facedown = (face == 'facedown')

    # Remove from hand and add to discard
    char_instance.remove_card(card_id)
    deck.add_to_discard([card_id])

    # Build messages
    face_type = face_type_string(facedown)
    if facedown
      broadcast_to_room_except([char_instance], "#{char_instance.full_name} discards a card #{face_type}.")
    else
      broadcast_to_room_except([char_instance], "#{char_instance.full_name} discards #{card.display_name} #{face_type}.")
    end

    result = build_menu_for_stage('main_menu')
    result[:message] = "You discard #{card.display_name} #{face_type}."
    result[:data] = {
      action: 'discard',
      card_id: card_id,
      card_name: card.display_name,
      facedown: facedown,
      cards_remaining: char_instance.card_count,
      discard_count: deck.discard_count
    }
    result
  end

  # === Turn Over Flow ===

  def handle_turnover_count(count_str)
    count = count_str.to_i
    count = facedown_count_in_hand if count_str == 'all'

    if count < 1 || count > facedown_count_in_hand
      return { success: false, error: 'Invalid count.', type: :error }
    end

    # Execute the flip
    flipped_ids = char_instance.flip_cards(count)
    return { success: false, error: 'No cards were flipped.', type: :error } if flipped_ids.empty?

    card_names = card_display_names(flipped_ids)
    card_word_str = card_word(flipped_ids.length)

    player_msg = "You turn over #{flipped_ids.length} #{card_word_str}: #{card_names.join(', ')}"
    others_msg = "#{char_instance.full_name} turns over #{flipped_ids.length} #{card_word_str}: #{card_names.join(', ')}"

    broadcast_to_room_except([char_instance], others_msg)

    result = build_menu_for_stage('main_menu')
    result[:message] = player_msg
    result[:data] = {
      action: 'turnover',
      count: flipped_ids.length,
      card_ids: flipped_ids,
      card_names: card_names
    }
    result
  end

  # === Deal Flow ===

  def handle_deal_count(count_str)
    return dealer_required_error unless is_dealer?

    count = count_str.to_i
    count = deck_remaining_count if count_str == 'all'

    if count < 1 || count > deck_remaining_count
      return { success: false, error: 'Invalid count.', type: :error }
    end

    build_menu_for_stage('deal_player', deal_count: count)
  end

  def handle_deal_player(player_key)
    return dealer_required_error unless is_dealer?

    deck = char_instance.current_deck
    return { success: false, error: "You're not in a card game.", type: :error } unless deck

    player_id = player_key.to_i
    target = CharacterInstance[player_id]

    unless target && target.current_room_id == char_instance.current_room_id
      return { success: false, error: 'That player is not here.', type: :error }
    end

    if target.in_card_game? && target.current_deck_id != deck.id
      return { success: false, error: 'That player is already in a different card game.', type: :error }
    end

    build_menu_for_stage('deal_face', deal_count: @context[:deal_count] || @context['deal_count'], target_id: player_id)
  end

  def handle_deal_face(face)
    count = (@context[:deal_count] || @context['deal_count'] || 1).to_i
    target_id = @context[:target_id] || @context['target_id']
    target = CharacterInstance[target_id]
    deck = char_instance.current_deck

    unless target
      return { success: false, error: 'Target player not found.', type: :error }
    end

    unless target.current_room_id == char_instance.current_room_id
      return { success: false, error: 'That player is not here.', type: :error }
    end

    unless deck && is_dealer?
      return { success: false, error: "You're not the dealer.", type: :error }
    end

    if target.in_card_game? && target.current_deck_id != deck.id
      return { success: false, error: 'That player is already in a different card game.', type: :error }
    end

    if count < 1 || count > deck.remaining_count
      return { success: false, error: 'Invalid count.', type: :error }
    end

    facedown = (face == 'facedown')

    # Draw cards from deck
    drawn_card_ids = deck.draw(count)

    # Add to target's hand
    if facedown
      target.add_cards_facedown(drawn_card_ids)
    else
      target.add_cards_faceup(drawn_card_ids)
    end

    # Join game if not already
    target.join_card_game!(deck) unless target.in_card_game?

    card_names = card_display_names(drawn_card_ids)
    face_type = face_type_string(facedown)
    card_word_str = card_word(count)

    # Message to dealer
    dealer_msg = "You deal #{count} #{card_word_str} #{face_type} to #{target.full_name}: #{card_names.join(', ')}"

    # Message to target
    target_msg = "#{char_instance.full_name} deals you #{count} #{card_word_str} #{face_type}: #{card_names.join(', ')}"

    # Message to others
    others_msg = if facedown
                   "#{char_instance.full_name} deals #{count} #{card_word_str} face down to #{target.full_name}."
                 else
                   "#{char_instance.full_name} deals #{count} #{card_word_str} face up to #{target.full_name}: #{card_names.join(', ')}"
                 end

    send_to_character(target, target_msg) unless target.id == char_instance.id
    broadcast_to_room_except([char_instance, target], others_msg)

    result = build_menu_for_stage('main_menu')
    result[:message] = dealer_msg
    result[:data] = {
      action: 'deal',
      count: count,
      facedown: facedown,
      target_id: target.id,
      target_name: target.full_name,
      card_ids: drawn_card_ids,
      deck_remaining: deck.remaining_count
    }
    result
  end

  # === Center Draw Flow ===

  def handle_center_draw_count(count_str)
    return dealer_required_error unless is_dealer?

    count = count_str.to_i
    count = deck_remaining_count if count_str == 'all'

    if count < 1 || count > deck_remaining_count
      return { success: false, error: 'Invalid count.', type: :error }
    end

    build_menu_for_stage('center_draw_face', draw_count: count)
  end

  def handle_center_draw_face(face)
    return dealer_required_error unless is_dealer?

    count = (@context[:draw_count] || @context['draw_count'] || 1).to_i
    deck = char_instance.current_deck
    facedown = (face == 'facedown')

    unless deck
      return { success: false, error: "You're not in a card game.", type: :error }
    end

    if count < 1 || count > deck.remaining_count
      return { success: false, error: 'Invalid count.', type: :error }
    end

    # Draw cards from deck to center
    drawn_card_ids = deck.draw(count)
    add_cards_to_holder(deck, drawn_card_ids, facedown: facedown, to_center: true)

    card_names = card_display_names(drawn_card_ids)

    player_msg = draw_self_message(count: count, facedown: facedown, card_names: card_names, destination: 'center')
    others_msg = draw_others_message(
      actor_name: char_instance.full_name,
      count: count,
      facedown: facedown,
      card_names: card_names,
      destination: 'center'
    )

    broadcast_to_room_except([char_instance], others_msg)

    result = build_menu_for_stage('main_menu')
    result[:message] = player_msg
    result[:data] = {
      action: 'centerdraw',
      count: count,
      facedown: facedown,
      card_ids: drawn_card_ids,
      card_names: card_names,
      deck_remaining: deck.remaining_count,
      center_count: deck.center_count
    }
    result
  end

  # === Center Turn Over Flow ===

  def handle_center_turnover_count(count_str)
    return dealer_required_error unless is_dealer?

    count = count_str.to_i
    count = center_facedown_count if count_str == 'all'
    deck = char_instance.current_deck

    if count < 1 || count > center_facedown_count
      return { success: false, error: 'Invalid count.', type: :error }
    end

    unless deck
      return { success: false, error: "You're not in a card game.", type: :error }
    end

    # Flip the center cards
    flipped_ids = deck.flip_center_cards(count)
    return { success: false, error: 'No cards were flipped.', type: :error } if flipped_ids.empty?

    card_names = card_display_names(flipped_ids)
    card_word_str = card_word(flipped_ids.length)

    msg = "#{char_instance.full_name} turns over #{flipped_ids.length} #{card_word_str} in the center: #{card_names.join(', ')}"
    broadcast_to_room(msg)

    result = build_menu_for_stage('main_menu')
    result[:message] = msg
    result[:data] = {
      action: 'centerturnover',
      count: flipped_ids.length,
      card_ids: flipped_ids,
      card_names: card_names,
      center_faceup_count: Array(deck.center_faceup).length,
      center_facedown_count: Array(deck.center_facedown).length
    }
    result
  end

  # === Return Discards Flow ===

  def handle_return_count(count_str)
    return dealer_required_error unless is_dealer?

    count = count_str.to_i
    count = discard_pile_count if count_str == 'all'
    deck = char_instance.current_deck

    if count < 1 || count > discard_pile_count
      return { success: false, error: 'Invalid count.', type: :error }
    end

    unless deck
      return { success: false, error: "You're not in a card game.", type: :error }
    end

    # Return cards from discard to deck
    returned_ids = deck.return_from_discard(count)
    return { success: false, error: 'No cards were returned.', type: :error } if returned_ids.empty?

    card_names = card_display_names(returned_ids)
    card_word_str = card_word(returned_ids.length)

    player_msg = "You return #{returned_ids.length} #{card_word_str} from the discard pile to the deck."
    others_msg = "#{char_instance.full_name} returns #{returned_ids.length} #{card_word_str} from the discard pile to the deck."

    broadcast_to_room_except([char_instance], others_msg)

    result = build_menu_for_stage('main_menu')
    result[:message] = player_msg
    result[:data] = {
      action: 'return',
      count: returned_ids.length,
      card_ids: returned_ids,
      deck_remaining: deck.remaining_count,
      discard_count: deck.discard_count
    }
    result
  end

  # === Immediate Actions ===

  def execute_show_hand
    deck = char_instance.current_deck
    return { success: false, error: "You're not in a card game.", type: :error } unless deck
    return { success: false, error: "You don't have any cards to show.", type: :error } unless char_instance.has_cards?

    faceup_cards = char_instance.faceup_cards
    facedown_cards = char_instance.facedown_cards

    faceup_names = faceup_cards.map(&:display_name)
    facedown_names = facedown_cards.map(&:display_name)

    all_names = faceup_names + facedown_names
    total_count = all_names.length
    card_word_str = card_word(total_count)

    details = []
    details << "Face up: #{faceup_names.join(', ')}" unless faceup_names.empty?
    details << "Face down: #{facedown_names.join(', ')}" unless facedown_names.empty?

    player_msg = "You show your hand (#{total_count} #{card_word_str}):\n#{details.join("\n")}"
    others_msg = "#{char_instance.full_name} shows their hand (#{total_count} #{card_word_str}):\n#{all_names.join(', ')}"

    broadcast_to_room_except([char_instance], others_msg)

    result = build_menu_for_stage('main_menu')
    result[:message] = player_msg
    result[:data] = {
      action: 'showhand',
      total_count: total_count,
      faceup_count: faceup_cards.length,
      facedown_count: facedown_cards.length,
      faceup_cards: faceup_cards.map { |c| { id: c.id, name: c.display_name } },
      facedown_cards: facedown_cards.map { |c| { id: c.id, name: c.display_name } }
    }
    result
  end

  def execute_view_discard
    deck = char_instance.current_deck
    return { success: false, error: "You're not in a card game.", type: :error } unless deck

    discard_ids = Array(deck.discard_pile)

    if discard_ids.empty?
      result = build_menu_for_stage('main_menu')
      result[:message] = 'The discard pile is empty.'
      return result
    end

    cards = deck.discard_cards
    card_names = cards.map(&:display_name)
    card_word_str = card_word(cards.length)

    msg = "Discard pile (#{cards.length} #{card_word_str}):\n#{card_names.join(', ')}"

    result = build_menu_for_stage('main_menu')
    result[:message] = msg
    result[:data] = {
      action: 'viewdiscard',
      count: cards.length,
      cards: cards.map { |c| { id: c.id, name: c.display_name } }
    }
    result
  end

  def execute_view_center
    deck = char_instance.current_deck
    return { success: false, error: "You're not in a card game.", type: :error } unless deck

    faceup_cards = deck.center_faceup_cards
    facedown_count = Array(deck.center_facedown).length
    total = faceup_cards.length + facedown_count

    if total.zero?
      result = build_menu_for_stage('main_menu')
      result[:message] = 'There are no cards in the center.'
      return result
    end

    parts = []
    parts << "Face up: #{faceup_cards.map(&:display_name).join(', ')}" if faceup_cards.any?
    parts << "Face down: #{facedown_count} cards" if facedown_count.positive?

    msg = "Center (#{total} cards):\n#{parts.join("\n")}"

    result = build_menu_for_stage('main_menu')
    result[:message] = msg
    result[:data] = {
      action: 'viewcenter',
      faceup_count: faceup_cards.length,
      facedown_count: facedown_count,
      faceup_cards: faceup_cards.map { |c| { id: c.id, name: c.display_name } }
    }
    result
  end

  def execute_reshuffle
    deck = char_instance.current_deck
    return { success: false, error: "You're not in a card game.", type: :error } unless deck
    return dealer_required_error unless is_dealer?

    # Collect all cards from all players
    players = deck.players.all
    player_count = players.count

    # Clear all player hands and reset deck
    deck.collect_all_cards!

    player_names = players.map(&:full_name).join(', ')
    card_count = deck.remaining_count

    broadcast_msg = "#{char_instance.full_name} collects all cards and shuffles the deck."
    broadcast_to_room_except([char_instance], broadcast_msg)

    result = build_menu_for_stage('main_menu')
    result[:message] = "You collect all cards and shuffle the deck. #{card_count} cards ready. Players: #{player_names}"
    result[:data] = {
      action: 'reshuffle',
      deck_id: deck.id,
      card_count: card_count,
      player_count: player_count
    }
    result
  end

  def execute_leave_game
    deck = char_instance.current_deck
    return { success: false, error: "You're not in a card game.", type: :error } unless deck

    # Clear hand and leave game
    char_instance.clear_cards!
    char_instance.leave_card_game!

    broadcast_to_room_except([char_instance], "#{char_instance.full_name} leaves the card game.")

    { success: true, message: 'You leave the card game.', type: :message }
  end

  # === Option Builders ===

  def build_count_options(max_count:)
    options = []

    [1, 2, 3, 5].each do |n|
      next if n > max_count

      options << { key: n.to_s, label: "#{n} #{card_word(n)}", description: "Draw #{n}" }
    end

    options << { key: 'all', label: "All (#{max_count})", description: "All #{max_count} available" } if max_count > 1

    options << { key: 'back', label: '<- Back', description: 'Return to main menu' }
    options
  end

  def build_face_options
    [
      { key: 'facedown', label: 'Face Down', description: 'Others cannot see the cards' },
      { key: 'faceup', label: 'Face Up', description: 'Cards are visible to everyone' },
      { key: 'back', label: '<- Back', description: 'Return to main menu' }
    ]
  end

  def build_card_selection_options
    cards = char_instance.all_cards
    options = cards.map do |card|
      face_status = Array(char_instance.cards_facedown).include?(card.id) ? '(face down)' : '(face up)'
      { key: card.id.to_s, label: card.display_name, description: face_status }
    end

    options << { key: 'back', label: '<- Back', description: 'Return to main menu' }
    options
  end

  def build_player_selection_options
    room = char_instance.current_room
    return [{ key: 'back', label: '<- Back', description: 'Return to main menu' }] unless room

    players = room.instances_dataset.exclude(id: char_instance.id).all
    options = players.map do |player|
      in_game = player.in_card_game? ? '(in game)' : ''
      { key: player.id.to_s, label: player.full_name, description: in_game }
    end

    options << { key: 'back', label: '<- Back', description: 'Return to main menu' }
    options
  end

  # === Helper Methods ===

  def deck_remaining_count
    char_instance.current_deck&.remaining_count || 0
  end

  def facedown_count_in_hand
    Array(char_instance.cards_facedown).length
  end

  def has_facedown_in_hand?
    facedown_count_in_hand.positive?
  end

  def center_facedown_count
    deck = char_instance.current_deck
    return 0 unless deck

    Array(deck.center_facedown).length
  end

  def discard_pile_count
    deck = char_instance.current_deck
    return 0 unless deck

    deck.discard_count
  end

  def is_dealer?
    deck = char_instance.current_deck
    return false unless deck

    deck.dealer_id == char_instance.id
  end

  def dealer_only_action?(action)
    %w[deal centerdraw centerturnover return reshuffle].include?(action)
  end

  def dealer_required_error
    { success: false, error: "You're not the dealer.", type: :error }
  end

  def find_or_create_deck_pattern(deck_type)
    case deck_type
    when :jokers
      DeckPattern.first(name: 'Standard Playing Cards (with Jokers)') ||
        DeckPattern.create_standard_deck_with_jokers(creator: char_instance.character)
    when :tarot
      DeckPattern.first(name: 'Tarot Deck') ||
        DeckPattern.create_tarot_deck(creator: char_instance.character)
    else
      DeckPattern.first(name: 'Standard Playing Cards') ||
        DeckPattern.create_standard_deck(creator: char_instance.character)
    end
  end

  # Broadcast helpers (delegate to OutputHelper/char_instance methods)

  def broadcast_to_room(message)
    room = char_instance.current_room
    return unless room

    broadcast_personalized_to_room(
      room.id,
      message,
      extra_characters: [char_instance]
    )
  end

  def broadcast_to_room_except(excluded_instances, message)
    room = char_instance.current_room
    return unless room

    excluded_ids = excluded_instances.map(&:id)
    broadcast_personalized_to_room(
      room.id,
      message,
      exclude: excluded_ids,
      extra_characters: excluded_instances
    )
  end

  def send_to_character(target, message)
    room = char_instance.current_room
    room_chars = room ? CharacterInstance.where(current_room_id: room.id, online: true).eager(:character).all : []
    personalized = personalize_for(message, viewer: target, room_characters: room_chars)
    BroadcastService.to_character(target, personalized)
  end

end
