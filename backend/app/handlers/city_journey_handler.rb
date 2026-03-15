# frozen_string_literal: true

# CityJourneyHandler processes city journey movement ticks.
#
# Called by the TimedAction system to advance vehicle travel
# through street routes. Each tick moves the vehicle to the
# next room in the journey's route.
#
# Usage:
#   TimedAction.start_delayed(
#     character_instance,
#     'city_journey',
#     delay_ms,
#     'CityJourneyHandler',
#     { journey_id: journey.id }
#   )
#
class CityJourneyHandler
  extend TimedActionHandler

  class << self
    # Process a city journey movement tick.
    #
    # @param timed_action [TimedAction] the timed action with journey data
    def call(timed_action)
      data = timed_action.parsed_action_data
      journey_id = data[:journey_id]

      unless journey_id
        store_error(timed_action, 'Missing journey_id in action data')
        return
      end

      VehicleTravelService.advance_journey(journey_id)
      store_success(timed_action, { journey_id: journey_id })
    rescue StandardError => e
      warn "[CityJourneyHandler] Error advancing journey #{journey_id}: #{e.message}"
      store_error(timed_action, e.message)
    end
  end
end
