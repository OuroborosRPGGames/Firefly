# frozen_string_literal: true

# Wraps a RoomFeature to present it from the "other side" of the wall.
# Flips direction and orientation so the feature appears correct from
# the connected room's perspective. Delegates everything else to the
# underlying RoomFeature record.
#
# This is NOT a Sequel model — it's a lightweight decorator.
class InboundFeatureWrapper < SimpleDelegator
  def initialize(feature, inferred_direction: nil)
    super(feature)
    @inferred_direction = inferred_direction
  end

  def direction
    @inferred_direction || CanvasHelper.opposite_direction(super.to_s)
  end

  def orientation
    @inferred_direction || CanvasHelper.opposite_direction(super.to_s)
  end

  # From the viewing room's perspective, the "connected room" is the
  # feature's owning room (where you'd go through the door to).
  def connected_room_id
    __getobj__.room_id
  end

  def connected_room
    __getobj__.room
  end

  def inbound?
    true
  end

  # The underlying real feature record (for edits/deletes)
  def source_feature
    __getobj__
  end
end
