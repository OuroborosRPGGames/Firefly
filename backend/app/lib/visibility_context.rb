# frozen_string_literal: true

# VisibilityContext - Value object encapsulating visibility dimensions for broadcast filtering
#
# Characters in the same room may be in different "realities" (alternate dimensions, dreams, etc.)
# or different "timelines" (past snapshots, historical periods). This class encapsulates
# the visibility context of a character and provides methods to determine if two characters
# can see each other's broadcasts.
#
# Usage:
#   sender_ctx = VisibilityContext.from_character_instance(sender)
#   viewer_ctx = VisibilityContext.from_character_instance(viewer)
#
#   if viewer_ctx.can_see?(sender_ctx)
#     # Deliver the message
#   end
#
# Visibility Rules:
#   - Characters must be in the same reality (reality_id must match)
#   - Characters must be in the same timeline (both nil, or both same timeline_id)
#   - Invisible characters are only visible to staff with vision enabled
#   - Private mode blocks staff vision (content consent)
#   - Staff with vision enabled bypass reality/timeline checks (except private mode)
#
class VisibilityContext
  attr_reader :reality_id, :timeline_id, :private_mode, :invisible,
              :flashback_instanced, :flashback_co_travelers, :character_instance_id,
              :in_event_id

  def initialize(reality_id:, timeline_id: nil, private_mode: false, invisible: false,
                 flashback_instanced: false, flashback_co_travelers: [], character_instance_id: nil,
                 in_event_id: nil)
    @reality_id = reality_id
    @timeline_id = timeline_id
    @private_mode = private_mode
    @invisible = invisible
    @flashback_instanced = flashback_instanced
    @flashback_co_travelers = flashback_co_travelers || []
    @character_instance_id = character_instance_id
    @in_event_id = in_event_id
  end

  # Create a VisibilityContext from a CharacterInstance
  #
  # @param character_instance [CharacterInstance] The character instance
  # @return [VisibilityContext]
  def self.from_character_instance(character_instance)
    # Safely access flashback fields (may not exist if schema not yet migrated)
    flashback_instanced = character_instance.respond_to?(:flashback_instanced?) ?
                          character_instance.flashback_instanced? : false
    flashback_co_travelers = character_instance.respond_to?(:flashback_co_travelers) ?
                             (character_instance.flashback_co_travelers || []) : []

    new(
      reality_id: character_instance.reality_id,
      timeline_id: character_instance.timeline_id,
      private_mode: character_instance.private_mode?,
      invisible: character_instance.invisible?,
      flashback_instanced: flashback_instanced,
      flashback_co_travelers: flashback_co_travelers,
      character_instance_id: character_instance.id,
      in_event_id: character_instance.in_event_id
    )
  end

  # Convert to a hash for JSON serialization in broadcast payloads
  #
  # @return [Hash]
  def to_h
    {
      reality_id: reality_id,
      timeline_id: timeline_id,
      private_mode: private_mode,
      invisible: invisible,
      flashback_instanced: flashback_instanced,
      flashback_co_travelers: flashback_co_travelers,
      character_instance_id: character_instance_id,
      in_event_id: in_event_id
    }
  end

  # Check if this viewer can see broadcasts from a sender
  #
  # @param sender_context [VisibilityContext] The sender's visibility context
  # @param viewer_staff_vision [Boolean] Whether the viewer has staff vision enabled
  # @return [Boolean]
  def can_see?(sender_context, viewer_staff_vision: false)
    # Private mode always blocks staff vision (content consent)
    return false if sender_context.private_mode && viewer_staff_vision

    # Event space partitioning: event participants only see others in the same event.
    # nil means "not in an event", so this also blocks event <-> non-event visibility.
    return false unless in_event_id == sender_context.in_event_id

    # Staff vision bypasses reality/timeline/invisibility checks
    if viewer_staff_vision
      return true
    end

    # Invisible senders are only visible to staff (handled above)
    return false if sender_context.invisible

    # Must be in the same reality
    return false unless reality_id == sender_context.reality_id

    # Must be in the same timeline
    return false unless timeline_matches?(sender_context.timeline_id)

    # Flashback instancing filter
    # If sender is flashback-instanced, only their co-travelers can see them
    if sender_context.flashback_instanced
      return false unless flashback_can_see_instanced?(sender_context)
    end

    # If viewer is flashback-instanced, they can only see their co-travelers
    if @flashback_instanced
      return false unless flashback_instanced_can_see?(sender_context)
    end

    true
  end

  # Check if two contexts are in the same visibility space (ignoring staff vision)
  #
  # @param other [VisibilityContext] The other context
  # @return [Boolean]
  def same_context?(other)
    reality_id == other.reality_id &&
      timeline_matches?(other.timeline_id) &&
      in_event_id == other.in_event_id
  end

  private

  # Check if timelines match
  # - Both nil = same timeline (primary/main timeline)
  # - Both non-nil and equal = same timeline
  # - One nil and other non-nil = different timelines
  #
  # @param sender_timeline_id [Integer, nil] The sender's timeline ID
  # @return [Boolean]
  def timeline_matches?(sender_timeline_id)
    # Both nil = same timeline (primary)
    return true if timeline_id.nil? && sender_timeline_id.nil?

    # If one is nil and other isn't, they're in different timelines
    return false if timeline_id.nil? || sender_timeline_id.nil?

    # Both have timeline IDs - must match
    timeline_id == sender_timeline_id
  end

  # Check if this (non-instanced) viewer can see an instanced sender
  # Only co-travelers can see flashback-instanced characters
  #
  # @param sender_context [VisibilityContext]
  # @return [Boolean]
  def flashback_can_see_instanced?(sender_context)
    # Viewer must be in sender's co-travelers list
    sender_context.flashback_co_travelers&.include?(@character_instance_id)
  end

  # Check if this (instanced) viewer can see a sender
  # Instanced viewers can only see their co-travelers
  #
  # @param sender_context [VisibilityContext]
  # @return [Boolean]
  def flashback_instanced_can_see?(sender_context)
    # Can see other instanced characters if they're co-travelers
    @flashback_co_travelers&.include?(sender_context.character_instance_id)
  end
end
