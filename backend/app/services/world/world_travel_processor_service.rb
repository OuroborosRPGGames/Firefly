# frozen_string_literal: true

# WorldTravelProcessorService processes active journeys on scheduler ticks.
# Advances journeys hex by hex and handles arrivals.
class WorldTravelProcessorService
  class << self
    # Process all due journeys
    # @return [Hash] with :advanced, :arrived, :errors counts
    def process_due_journeys!
      results = { advanced: 0, arrived: 0, errors: [] }

      # Find all traveling journeys that are ready to advance
      WorldJourney.where(status: 'traveling')
                  .where { next_hex_at <= Time.now }
                  .each do |journey|
        process_journey(journey, results)
      end

      log_results(results) if results[:advanced] > 0 || results[:arrived] > 0

      results
    end

    private

    # Process a single journey
    def process_journey(journey, results)
      if journey.path_remaining.nil? || journey.path_remaining.empty?
        # Segment exhausted; continue to next segment if available, otherwise arrive.
        unless transition_to_next_segment(journey, results)
          complete_journey(journey, results)
        end
      else
        # Advance to next hex
        advance_journey(journey, results)
      end
    rescue StandardError => e
      results[:errors] << { journey_id: journey.id, error: e.message }
    end

    # Advance journey to the next hex
    def advance_journey(journey, results)
      old_globe_hex_id = journey.current_globe_hex_id

      if journey.advance_to_next_hex!
        results[:advanced] += 1

        # Notify passengers of terrain change
        notify_terrain_update(journey, old_globe_hex_id)

        # Check if we've arrived at destination
        if journey.path_remaining.nil? || journey.path_remaining.empty?
          unless transition_to_next_segment(journey, results)
            complete_journey(journey, results)
          end
        end
      end
    end

    # Move to the next planned segment when available
    # @return [Boolean] true if segment transition occurred
    def transition_to_next_segment(journey, results)
      segments = journey.segments || []
      current_index = journey.current_segment_index.to_i
      next_segment = segments[current_index + 1]
      return false unless next_segment

      next_path = segment_path(next_segment)
      return false if next_path.length < 2

      next_mode = segment_value(next_segment, :mode) || journey.travel_mode
      next_vehicle = segment_value(next_segment, :vehicle) || journey.vehicle_type
      remaining_path = next_path[1..] || []
      next_index = current_index + 1

      journey.update(
        current_segment_index: next_index,
        travel_mode: next_mode,
        vehicle_type: next_vehicle,
        path_remaining: remaining_path,
        next_hex_at: remaining_path.empty? ? nil : journey.calculate_next_hex_time,
        estimated_arrival_at: estimate_segment_arrival(journey, segments, next_index, remaining_path)
      )

      results[:advanced] += 1
      notify_segment_transfer(journey, next_mode, next_vehicle)
      true
    rescue StandardError => e
      warn "[WorldTravelProcessorService] Failed segment transition for journey #{journey.id}: #{e.message}"
      false
    end

    # Complete a journey that has arrived
    def complete_journey(journey, results)
      journey.complete_arrival!
      results[:arrived] += 1

      notify_arrival(journey)
    end

    # Notify passengers of terrain change during travel
    def notify_terrain_update(journey, _old_globe_hex_id)
      passengers = journey.passengers
      return if passengers.empty?

      hex = journey.current_hex
      terrain_desc = journey.terrain_description

      message = format_terrain_message(journey, terrain_desc)

      passengers.each do |char_instance|
        BroadcastService.send_system_message(
          char_instance,
          message,
          type: :travel_update
        )
      end
    rescue StandardError => e
      # Log but don't fail the journey processing
      warn "[WorldTravelProcessorService] Failed to notify terrain update: #{e.message}"
    end

    # Notify passengers of arrival
    def notify_arrival(journey)
      destination = journey.destination_location
      destination_name = destination&.display_name || 'your destination'

      journey.passengers.each do |char_instance|
        room = char_instance.current_room
        room_name = room&.name || 'the arrival point'

        BroadcastService.send_system_message(
          char_instance,
          "You have arrived at #{destination_name}. You find yourself in #{room_name}.",
          type: :travel_arrival
        )
      end
    rescue StandardError => e
      # Log but don't fail the journey processing
      warn "[WorldTravelProcessorService] Failed to notify arrival: #{e.message}"
    end

    # Notify passengers when they switch to a new segment/vehicle.
    def notify_segment_transfer(journey, next_mode, next_vehicle)
      passengers = journey.passengers
      return if passengers.empty?

      vehicle_name = next_vehicle.to_s.tr('_', ' ')
      message = "You transfer and continue by #{vehicle_name} (#{next_mode})."

      passengers.each do |char_instance|
        BroadcastService.send_system_message(
          char_instance,
          message,
          type: :travel_update
        )
      end
    rescue StandardError => e
      warn "[WorldTravelProcessorService] Failed to notify transfer: #{e.message}"
    end

    # Parse a segment path from symbol- or string-keyed JSON.
    def segment_path(segment)
      raw = segment_value(segment, :path)
      return [] unless raw.is_a?(Array)

      raw.map { |hex_id| hex_id.to_i }
    end

    # Fetch segment hash values regardless of key style.
    def segment_value(segment, key)
      segment[key] || segment[key.to_s]
    end

    # Estimate remaining arrival time across this and all future segments.
    def estimate_segment_arrival(journey, segments, current_index, current_path_remaining)
      return Time.now if current_path_remaining.empty?

      remaining_hexes = current_path_remaining.length

      ((current_index + 1)...segments.length).each do |idx|
        future_path = segment_path(segments[idx])
        remaining_hexes += [future_path.length - 1, 0].max
      end

      Time.now + (remaining_hexes * journey.time_per_hex_seconds)
    end

    # Format a terrain update message based on vehicle type
    def format_terrain_message(journey, terrain_desc)
      vehicle = journey.vehicle_type

      case journey.travel_mode
      when 'water'
        "The #{vehicle.tr('_', ' ')} continues across the #{terrain_desc}."
      when 'air'
        "Looking down from the #{vehicle.tr('_', ' ')}, you see #{terrain_desc} below."
      when 'rail'
        "The #{vehicle.tr('_', ' ')} passes through #{terrain_desc}."
      else
        "Your #{vehicle.tr('_', ' ')} travels through #{terrain_desc}."
      end
    end

    # Log processing results
    def log_results(results)
      message = "WorldTravel: Advanced #{results[:advanced]} journeys, " \
                "#{results[:arrived]} arrivals"
      message += ", #{results[:errors].length} errors" if results[:errors].any?

      warn "[WorldTravelProcessorService] #{message}"
    end
  end
end
