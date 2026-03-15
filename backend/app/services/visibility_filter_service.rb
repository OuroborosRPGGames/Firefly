# frozen_string_literal: true

# VisibilityFilterService - Central service for visibility-based broadcast filtering
#
# Handles filtering of room broadcasts based on visibility context (reality, timeline, etc.)
# Used by BroadcastService for polling fallback and WebsocketHandler for real-time delivery.
#
# Usage:
#   # Check if a message should be delivered to a viewer
#   if VisibilityFilterService.should_deliver?(payload, viewer_instance)
#     deliver_message(payload)
#   end
#
#   # Get eligible recipients for a room broadcast
#   recipients = VisibilityFilterService.eligible_recipients_in_room(
#     room_id, sender_instance, exclude: [some_id]
#   )
#
class VisibilityFilterService
  class << self
    # Check if a message should be delivered to a specific viewer
    #
    # @param payload [Hash] The message payload (must include :visibility_context if sender-specific)
    # @param viewer_instance [CharacterInstance] The viewer to check
    # @return [Boolean] True if the message should be delivered
    def should_deliver?(payload, viewer_instance)
      return true if viewer_instance.nil?

      # Extract sender's visibility context from payload
      sender_context = extract_visibility_context(payload)

      # No sender context = system message, always deliver
      return true if sender_context.nil?

      # Build viewer's visibility context
      viewer_context = VisibilityContext.from_character_instance(viewer_instance)

      # Check if viewer can see sender
      viewer_context.can_see?(
        sender_context,
        viewer_staff_vision: viewer_instance.staff_vision_enabled?
      )
    end

    # Get eligible recipients for a room broadcast (for polling fallback)
    #
    # @param room_id [Integer] The room ID
    # @param sender_instance [CharacterInstance, nil] The sender (nil for system messages)
    # @param exclude [Array<Integer>] Character instance IDs to exclude
    # @return [Array<CharacterInstance>] Eligible recipients
    def eligible_recipients_in_room(room_id, sender_instance, exclude: [])
      # Get all online characters in the room
      # Use qualified column reference to avoid Sequel association filtering
      recipients = CharacterInstance
        .where(Sequel[:character_instances][:current_room_id] => room_id, online: true)
        .exclude(Sequel[:character_instances][:id] => Array(exclude))
        .all

      # If no sender context (system message), all are eligible
      return recipients if sender_instance.nil?

      # Build sender's visibility context
      sender_context = VisibilityContext.from_character_instance(sender_instance)

      # Filter to only those who can see the sender
      recipients.select do |recipient|
        viewer_context = VisibilityContext.from_character_instance(recipient)
        viewer_context.can_see?(
          sender_context,
          viewer_staff_vision: recipient.staff_vision_enabled?
        )
      end
    end

    # Get eligible recipients for a zone broadcast
    #
    # @param zone_id [Integer] The zone ID
    # @param sender_instance [CharacterInstance, nil] The sender (nil for system messages)
    # @return [Array<Integer>] Eligible recipient instance IDs
    def eligible_recipients_in_zone(zone_id, sender_instance)
      # Get all online characters in rooms belonging to this zone
      # Join path: character_instances -> rooms -> locations -> zones
      recipients = CharacterInstance
        .where(online: true)
        .join(:rooms, id: :current_room_id)
        .join(:locations, id: Sequel[:rooms][:location_id])
        .where(Sequel[:locations][:zone_id] => zone_id)
        .select_all(:character_instances)
        .all

      # If no sender context (system message), all are eligible
      return recipients.map(&:id) if sender_instance.nil?

      # Build sender's visibility context
      sender_context = VisibilityContext.from_character_instance(sender_instance)

      # Filter to only those who can see the sender
      recipients.select do |recipient|
        viewer_context = VisibilityContext.from_character_instance(recipient)
        viewer_context.can_see?(
          sender_context,
          viewer_staff_vision: recipient.staff_vision_enabled?
        )
      end.map(&:id)
    end

    # Get eligible recipients for a global broadcast
    #
    # @param sender_instance [CharacterInstance, nil] The sender (nil for system messages)
    # @return [Array<Integer>] Eligible recipient instance IDs
    def eligible_recipients_global(sender_instance)
      # Get all online characters
      recipients = CharacterInstance.where(online: true).all

      # If no sender context (system message), all are eligible
      return recipients.map(&:id) if sender_instance.nil?

      # Build sender's visibility context
      sender_context = VisibilityContext.from_character_instance(sender_instance)

      # Filter to only those who can see the sender
      recipients.select do |recipient|
        viewer_context = VisibilityContext.from_character_instance(recipient)
        viewer_context.can_see?(
          sender_context,
          viewer_staff_vision: recipient.staff_vision_enabled?
        )
      end.map(&:id)
    end

    # Filter a list of character instances to only those visible to a viewer
    #
    # @param instances [Array<CharacterInstance>] Character instances to filter
    # @param viewer_instance [CharacterInstance] The viewer
    # @return [Array<CharacterInstance>] Visible instances
    def visible_to(instances, viewer_instance)
      return instances if viewer_instance.nil?

      viewer_context = VisibilityContext.from_character_instance(viewer_instance)

      instances.select do |ci|
        sender_context = VisibilityContext.from_character_instance(ci)
        viewer_context.can_see?(
          sender_context,
          viewer_staff_vision: viewer_instance.staff_vision_enabled?
        )
      end
    end

    private

    # Extract visibility context from a payload hash
    #
    # @param payload [Hash] The message payload
    # @return [VisibilityContext, nil]
    def extract_visibility_context(payload)
      ctx = payload[:visibility_context] || payload['visibility_context']
      return nil if ctx.nil?

      VisibilityContext.new(
        reality_id: ctx[:reality_id] || ctx['reality_id'],
        timeline_id: ctx[:timeline_id] || ctx['timeline_id'],
        private_mode: ctx[:private_mode] || ctx['private_mode'] || false,
        invisible: ctx[:invisible] || ctx['invisible'] || false,
        flashback_instanced: ctx[:flashback_instanced] || ctx['flashback_instanced'] || false,
        flashback_co_travelers: ctx[:flashback_co_travelers] || ctx['flashback_co_travelers'] || [],
        character_instance_id: ctx[:character_instance_id] || ctx['character_instance_id'],
        in_event_id: ctx[:in_event_id] || ctx['in_event_id']
      )
    end
  end
end
