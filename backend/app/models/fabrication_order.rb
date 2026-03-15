# frozen_string_literal: true

class FabricationOrder < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  many_to_one :character
  many_to_one :pattern
  many_to_one :fabrication_room, class: :Room
  many_to_one :delivery_room, class: :Room

  def validate
    super
    validates_presence [:character_id, :pattern_id, :status, :delivery_method]
    validates_includes GameConfig::Fabrication::STATUSES, :status
    validates_includes GameConfig::Fabrication::DELIVERY_METHODS, :delivery_method
  end

  # === Status Methods ===

  # Check if the order has completed fabrication
  # @return [Boolean]
  def complete?
    return false unless completes_at

    Time.now >= completes_at
  end

  # Check if this order is still being crafted
  # @return [Boolean]
  def crafting?
    status == 'crafting'
  end

  # Check if this order is ready for pickup
  # @return [Boolean]
  def ready?
    status == 'ready'
  end

  # Check if this order has been delivered
  # @return [Boolean]
  def delivered?
    status == 'delivered'
  end

  # Check if this order was cancelled
  # @return [Boolean]
  def cancelled?
    status == 'cancelled'
  end

  # Check if delivery method is pickup
  # @return [Boolean]
  def pickup?
    delivery_method == 'pickup'
  end

  # Check if delivery method is delivery to home
  # @return [Boolean]
  def delivery?
    delivery_method == 'delivery'
  end

  # === Time Methods ===

  # Calculate seconds remaining until completion
  # @return [Integer] seconds remaining (0 if complete)
  def time_remaining
    return 0 unless completes_at
    return 0 if complete?

    (completes_at - Time.now).to_i
  end

  # Get human-readable time remaining display
  # @return [String] formatted time (e.g., "4 hours", "30 minutes", "45 seconds")
  def time_remaining_display
    seconds = time_remaining
    return 'ready' if seconds <= 0

    if seconds >= 3600
      hours = (seconds / 3600.0).round(1)
      hours == hours.to_i ? "#{hours.to_i} hour#{'s' if hours.to_i != 1}" : "#{hours} hours"
    elsif seconds >= 60
      minutes = (seconds / 60.0).round
      "#{minutes} minute#{'s' if minutes != 1}"
    else
      "#{seconds} second#{'s' if seconds != 1}"
    end
  end

  # === Status Transitions ===

  # Mark the order as ready for pickup (after fabrication completes)
  def mark_ready!
    update(status: 'ready')
  end

  # Mark the order as delivered
  # @param item [Item, nil] the created item (optional, for tracking)
  def mark_delivered!(item = nil)
    update(
      status: 'delivered',
      delivered_at: Time.now
    )
  end

  # Cancel the order
  def cancel!
    update(status: 'cancelled')
  end

  # === Item Creation ===

  # Create the item from this order
  # @param character_instance [CharacterInstance] the character instance to give the item to
  # @param room [Room, nil] the room to place the item in (for delivery)
  # @return [Item] the created item
  def create_item(character_instance: nil, room: nil)
    options = parsed_item_options
    pattern.instantiate(
      character_instance: character_instance,
      room: room,
      name: options['name'],
      description: options['description']
    )
  end

  # Get parsed item options from JSONB
  # @return [Hash]
  def parsed_item_options
    return {} unless item_options

    if item_options.is_a?(Hash)
      item_options
    else
      JSON.parse(item_options.to_s)
    end
  rescue JSON::ParserError
    {}
  end

  # === Class Methods (Scopes) ===

  dataset_module do
    # Orders that have completed fabrication but not yet processed
    def ready_to_complete
      where(status: 'crafting')
        .where { completes_at <= Time.now }
    end

    # Active orders for a specific character
    def pending_for_character(character)
      where(character_id: character.id)
        .where(status: %w[crafting ready])
        .order(:completes_at)
    end

    # Orders awaiting pickup at a specific room
    def awaiting_pickup_at(room)
      where(fabrication_room_id: room.id)
        .where(status: 'ready')
        .where(delivery_method: 'pickup')
    end

    # Orders that are crafting
    def crafting
      where(status: 'crafting')
    end

    # Orders that are ready
    def ready
      where(status: 'ready')
    end
  end
end
