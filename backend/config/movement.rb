# frozen_string_literal: true

module MovementConfig
  # Base room transition time in milliseconds (fallback when no coordinates)
  BASE_ROOM_TIME_MS = 3000

  # Minimum transition time even when very close to exit
  MIN_TRANSITION_TIME_MS = 500

  # Speed multipliers for different movement verbs
  # Lower = faster
  SPEED_MULTIPLIERS = {
    'fly' => 0.05,
    'run' => 0.5,
    'jog' => 0.6,
    'walk' => 1.0,
    'strut' => 1.1,
    'meander' => 1.5,
    'stroll' => 1.3,
    'crawl' => 5.0,
    'limp' => 2.0,
    'sneak' => 2.0,
    'sprint' => 0.3
  }.freeze

  # Third-person verb conjugations for messages
  VERB_CONJUGATIONS = {
    'fly' => { present: 'flies', past: 'flew', continuous: 'flying' },
    'run' => { present: 'runs', past: 'ran', continuous: 'running' },
    'jog' => { present: 'jogs', past: 'jogged', continuous: 'jogging' },
    'walk' => { present: 'walks', past: 'walked', continuous: 'walking' },
    'strut' => { present: 'struts', past: 'strutted', continuous: 'strutting' },
    'meander' => { present: 'meanders', past: 'meandered', continuous: 'meandering' },
    'stroll' => { present: 'strolls', past: 'strolled', continuous: 'strolling' },
    'crawl' => { present: 'crawls', past: 'crawled', continuous: 'crawling' },
    'limp' => { present: 'limps', past: 'limped', continuous: 'limping' },
    'sneak' => { present: 'sneaks', past: 'snuck', continuous: 'sneaking' },
    'sprint' => { present: 'sprints', past: 'sprinted', continuous: 'sprinting' }
  }.freeze

  # Movement states
  STATES = %w[idle moving following leading].freeze

  class << self
    def time_for_movement(adverb, room_exit = nil, character_instance = nil)
      multiplier = SPEED_MULTIPLIERS[adverb] || 1.0

      base_time = if room_exit && character_instance
                    # Calculate time based on distance from character to exit
                    DistanceService.time_to_exit(character_instance, room_exit)
                  elsif room_exit&.respond_to?(:travel_time) && room_exit.travel_time
                    room_exit.travel_time
                  else
                    BASE_ROOM_TIME_MS
                  end

      [(base_time * multiplier).to_i, MIN_TRANSITION_TIME_MS].max
    end

    def conjugate(verb, form = :present)
      VERB_CONJUGATIONS.dig(verb, form) || verb
    end

    def valid_verb?(verb)
      SPEED_MULTIPLIERS.key?(verb)
    end

    def default_verb
      'walk'
    end
  end
end
