# frozen_string_literal: true

# WorldJourneyPassenger tracks a character's participation in a world journey.
# Multiple passengers can share a journey and interact with each other.
class WorldJourneyPassenger < Sequel::Model
  plugin :timestamps
  plugin :validation_helpers

  many_to_one :world_journey
  many_to_one :character_instance

  def validate
    super
    validates_presence %i[world_journey_id character_instance_id]
  end

  # Board the journey
  def self.board!(journey, character_instance, is_driver: false)
    existing = first(world_journey_id: journey.id, character_instance_id: character_instance.id)
    return existing if existing

    passenger = create(
      world_journey_id: journey.id,
      character_instance_id: character_instance.id,
      is_driver: is_driver,
      boarded_at: Time.now
    )

    # Update character instance to reference journey
    character_instance.update(current_world_journey_id: journey.id)

    passenger
  end

  # Disembark from the journey
  def disembark!
    character_instance.update(current_world_journey_id: nil)
    destroy
  end

  # Get the character's name for display
  def character_name
    character_instance&.full_name || 'Unknown'
  end
end
