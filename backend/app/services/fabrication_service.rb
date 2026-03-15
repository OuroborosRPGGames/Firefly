# frozen_string_literal: true

require_relative '../lib/time_format_helper'

# FabricationService handles era-based crafting with room requirements.
#
# In sci-fi eras, fabrication is instant (replicator technology).
# In earlier eras, fabrication takes time and requires appropriate facilities.
#
# @example Check if character can fabricate here
#   FabricationService.can_fabricate_here?(character_instance, pattern)
#
# @example Start a fabrication order
#   FabricationService.start_fabrication(ci, pattern, delivery_method: 'pickup')
#
# @example Check if fabrication would be instant
#   FabricationService.instant?(pattern)
#
class FabricationService
  extend TimeFormatHelper

  class << self
    # Check if a character can fabricate a pattern in their current location
    # @param character_instance [CharacterInstance] the character's instance
    # @param pattern [Pattern] the pattern to fabricate
    # @return [Boolean]
    def can_fabricate_here?(character_instance, pattern)
      return true if character_instance.character.admin?

      room = character_instance.current_room
      return false unless room

      # Tutorial rooms always allow fabrication
      return true if room.respond_to?(:tutorial_room) && room.tutorial_room

      # Check if room is a universal fabrication facility
      return true if universal_facility?(room)

      # Check if room type matches the pattern's requirements
      facility_allows_pattern?(room, pattern)
    end

    # Calculate fabrication time for a pattern based on current era
    # @param pattern [Pattern] the pattern to fabricate
    # @return [Integer] fabrication time in seconds
    def calculate_time(pattern)
      era = EraService.current_era
      era_config = GameConfig::Fabrication::ERA_TIMES[era] || GameConfig::Fabrication::ERA_TIMES[:modern]

      base_time = era_config[:base_seconds]
      complexity_mult = era_config[:complexity_mult]

      # Apply pattern type complexity
      type_key = GameConfig::Fabrication.pattern_type_key(pattern)
      pattern_mult = GameConfig::Fabrication::COMPLEXITY_MULTIPLIERS[type_key] || 1.0

      (base_time * complexity_mult * pattern_mult).to_i
    end

    # Check if fabrication would be instant (below threshold)
    # @param pattern [Pattern] the pattern to fabricate
    # @return [Boolean]
    def instant?(pattern)
      calculate_time(pattern) < GameConfig::Fabrication::INSTANT_THRESHOLD_SECONDS
    end

    # Start a fabrication order
    # @param character_instance [CharacterInstance] the character's instance
    # @param pattern [Pattern] the pattern to fabricate
    # @param delivery_method [String] 'pickup' or 'delivery'
    # @param delivery_room [Room, nil] the room to deliver to (required if delivery_method is 'delivery')
    # @param item_options [Hash] custom options for the created item
    # @return [FabricationOrder] the created order
    def start_fabrication(character_instance, pattern, delivery_method:, delivery_room: nil, item_options: {})
      fabrication_time = calculate_time(pattern)
      now = Time.now

      FabricationOrder.create(
        character_id: character_instance.character.id,
        pattern_id: pattern.id,
        fabrication_room_id: character_instance.current_room_id,
        delivery_room_id: delivery_room&.id,
        status: 'crafting',
        delivery_method: delivery_method,
        started_at: now,
        completes_at: now + fabrication_time,
        item_options: Sequel.pg_jsonb_wrap(item_options)
      )
    end

    # Process all completed orders and deliver/notify as appropriate
    # Called by the scheduled task processor
    # @return [Array<FabricationOrder>] orders that were processed
    def process_completed_orders
      processed = []

      FabricationOrder.ready_to_complete.all.each do |order|
        complete_order(order)
        processed << order
      rescue StandardError => e
        warn "[FabricationService] Failed to complete order #{order.id}: #{e.message}"
      end

      processed
    end

    # Complete a single order (create item and notify)
    # @param order [FabricationOrder] the order to complete
    # @return [Item, nil] the created item
    def complete_order(order)
      character = order.character
      return unless character

      # Find character instance (may be offline)
      character_instance = character.character_instances_dataset.first

      if order.delivery?
        # Delivery to home - create item in delivery room
        delivery_room = order.delivery_room
        return unless delivery_room

        item = order.create_item(room: delivery_room)
        order.mark_delivered!(item)

        # Notify character if online
        notify_delivery(character_instance, order, item) if character_instance&.online
      else
        # Pickup - mark as ready
        order.mark_ready!

        # Notify character if online
        notify_ready_for_pickup(character_instance, order) if character_instance&.online
      end
    end

    # Get pending orders for a character
    # @param character [Character] the character
    # @return [Array<FabricationOrder>]
    def pending_orders(character)
      FabricationOrder.pending_for_character(character).all
    end

    # Pick up a ready order
    # @param character_instance [CharacterInstance] the character picking up
    # @param order [FabricationOrder] the order to pick up
    # @return [Hash] { success: Boolean, item: Item, message: String }
    def pickup_order(character_instance, order)
      unless order.ready?
        return { success: false, item: nil, message: 'This order is not ready for pickup.' }
      end

      unless order.character_id == character_instance.character.id
        return { success: false, item: nil, message: 'This order belongs to someone else.' }
      end

      # Create the item in the character's inventory
      item = order.create_item(character_instance: character_instance)
      order.mark_delivered!(item)

      { success: true, item: item, message: "You collect your #{item.name}." }
    end

    # Get display name for facility type based on era
    # @param room [Room] the fabrication room
    # @return [String]
    def facility_name(room)
      case room.room_type
      when 'replicator', 'materializer', 'fabrication_bay'
        EraService.scifi? || EraService.near_future? ? 'replicator' : 'workshop'
      when 'forge', 'blacksmith', 'armory'
        'forge'
      when 'tailor', 'fashion_studio'
        'tailor'
      when 'jeweler', 'crafting_studio'
        'jeweler'
      when 'tattoo_parlor', 'clinic'
        'parlor'
      when 'pet_shop', 'breeder', 'cloning_lab'
        EraService.scifi? || EraService.near_future? ? 'cloning lab' : 'breeder'
      else
        'workshop'
      end
    end

    # Get era-appropriate completion message
    # @param pattern [Pattern] the pattern being fabricated
    # @return [String]
    def crafting_started_message(pattern, time_seconds)
      time_display = format_duration(time_seconds)
      era = EraService.current_era

      case era
      when :medieval, :gaslight
        "The craftsman begins work on your #{pattern.description}. Return here in #{time_display} to collect it."
      when :modern
        "Your order has been placed. It will be ready in #{time_display}."
      when :near_future
        "Fabrication initiated. Estimated completion: #{time_display}."
      when :scifi
        "Synthesizing... ready in #{time_display}."
      else
        "Your #{pattern.description} will be ready in #{time_display}."
      end
    end

    # Get era-appropriate delivery message
    # @param pattern [Pattern] the pattern
    # @param delivery_room [Room] the delivery location
    # @param time_seconds [Integer] fabrication time
    # @return [String]
    def delivery_started_message(pattern, delivery_room, time_seconds)
      time_display = format_duration(time_seconds)
      era = EraService.current_era

      case era
      when :medieval, :gaslight
        "The craftsman begins work on your #{pattern.description}. It will be delivered to #{delivery_room.name} when complete."
      when :modern
        "Your order has been placed. It will be delivered to #{delivery_room.name} in #{time_display}."
      when :near_future, :scifi
        "Fabrication initiated with delivery to #{delivery_room.name}. ETA: #{time_display}."
      else
        "Your #{pattern.description} will be delivered to #{delivery_room.name} in #{time_display}."
      end
    end

    private

    # Check if room is a universal fabrication facility
    # @param room [Room] the room to check
    # @return [Boolean]
    def universal_facility?(room)
      return false unless room.room_type

      GameConfig::Fabrication::UNIVERSAL_FACILITIES.include?(room.room_type)
    end

    # Check if room type allows fabrication of a specific pattern type
    # @param room [Room] the room
    # @param pattern [Pattern, nil] the pattern (nil = check if any fabrication is allowed)
    # @return [Boolean]
    def facility_allows_pattern?(room, pattern)
      return false unless room.room_type

      # If no pattern specified, check if room is any fabrication facility
      if pattern.nil?
        all_facilities = GameConfig::Fabrication::FACILITY_REQUIREMENTS.values.flatten.uniq
        return all_facilities.include?(room.room_type)
      end

      type_key = GameConfig::Fabrication.pattern_type_key(pattern)
      allowed_types = GameConfig::Fabrication::FACILITY_REQUIREMENTS[type_key]
      return false unless allowed_types

      allowed_types.include?(room.room_type)
    end

    # Notify character their delivery has arrived
    # @param character_instance [CharacterInstance] the character
    # @param order [FabricationOrder] the completed order
    # @param item [Item] the delivered item
    def notify_delivery(character_instance, order, item)
      return unless character_instance

      delivery_room = order.delivery_room
      message = "Your #{item.name} has been delivered to #{delivery_room&.name || 'your home'}."

      character_instance.send_system_message(message: message, type: 'fabrication')
    rescue StandardError => e
      warn "[FabricationService] Failed to notify delivery: #{e.message}"
    end

    # Notify character their order is ready for pickup
    # @param character_instance [CharacterInstance] the character
    # @param order [FabricationOrder] the ready order
    def notify_ready_for_pickup(character_instance, order)
      return unless character_instance

      fabrication_room = order.fabrication_room
      pattern = order.pattern
      message = "Your #{pattern&.description || 'item'} is ready for pickup at #{fabrication_room&.name || 'the workshop'}."

      character_instance.send_system_message(message: message, type: 'fabrication')
    rescue StandardError => e
      warn "[FabricationService] Failed to notify pickup: #{e.message}"
    end
  end
end
