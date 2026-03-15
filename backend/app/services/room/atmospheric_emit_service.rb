# frozen_string_literal: true

# AtmosphericEmitService - Generates ambient atmospheric descriptions for rooms
#
# Uses Gemini Flash to create 1-2 sentence ambient emits based on:
# - Time of day and season
# - Weather conditions
# - Room type and description
# - Room publicity level
# - Recent world memories
#
# Constraints:
# - Only emits in public/semi-public rooms
# - Only emits when PCs are present
# - 60-minute cooldown per room
# - Skips accessibility mode users
# - Not logged to RP logs
#
class AtmosphericEmitService
  extend CharacterLookupHelper
  extend StringHelper

  # Cooldown between atmospheric emits per room (in seconds)
  COOLDOWN_SECONDS = 3600

  # Room types to exclude (system areas that shouldn't get atmospheric messages)
  EXCLUDED_ROOM_TYPES = RoomTypeConfig.tagged(:excluded_from_atmosphere).freeze

  # Only emit in public or semi-public rooms
  ALLOWED_PUBLICITY = %w[public semi_public].freeze

  class << self
    # Generate an atmospheric emit for a room
    # @param room [Room] The room to generate an emit for
    # @return [String, nil] The atmospheric description or nil if skipped
    def generate_for_room(room)
      return nil unless enabled?
      return nil unless room
      return nil if excluded_room?(room)
      return nil unless public_or_semi_public?(room)
      return nil if on_cooldown?(room)

      location = room.location

      # Gather context
      context = {
        room_name: room.name,
        room_type: room.room_type,
        room_description: room.short_description,
        publicity: room.publicity || 'public',
        time_of_day: GameTimeService.time_of_day(location),
        season: GameTimeService.season(location),
        weather: weather_context(location),
        recent_memories: recent_memory_context(room),
        characters_present: room_population(room)
      }

      prompt = build_prompt(context)

      result = LLM::Client.generate(
        prompt: prompt,
        provider: 'google_gemini',
        model: 'gemini-3-flash-preview',
        options: { max_tokens: 500, temperature: 0.9 }
      )

      return nil unless result[:success]

      format_emit(result[:text])
    end

    # Broadcast an atmospheric emit to eligible characters in a room
    # Skips accessibility mode users and doesn't log to RP logs
    # @param room [Room] The room to broadcast to
    # @param emit_text [String] The atmospheric description
    def broadcast_to_room(room, emit_text)
      return if blank?(emit_text)

      # Get all online character instances in this room
      instances = find_characters_in_room(room.id)

      # Filter out accessibility mode users
      instances = instances.reject { |ci| ci.accessibility_mode? }

      return if instances.empty?

      # Build message with subtle styling
      message = {
        content: emit_text,
        html: "<div class='atmospheric-emit'>#{CGI.escapeHTML(emit_text)}</div>"
      }

      # Send to each eligible character (bypassing normal to_room to avoid logging)
      instances.each do |instance|
        BroadcastService.to_character_raw(
          instance,
          message,
          type: :atmosphere,
          skip_tts: true
        )
      end

      # Set cooldown for this room
      set_cooldown!(room)
    end

    # Check if atmospheric emits are enabled
    # @return [Boolean]
    def enabled?
      GameSetting.boolean('atmospheric_emits_enabled')
    end

    # Get the emit chance per room per interval
    # @return [Float] 0.0 to 1.0
    def emit_chance
      GameSetting.get('atmospheric_emit_chance')&.to_f || 0.25
    end

    # Get minimum PC count required for emits
    # @return [Integer]
    def min_players
      GameSetting.get('atmospheric_emit_min_players')&.to_i || 1
    end

    # Called by the scheduler to emit atmosphere to all occupied rooms.
    def process_pending_emits!
      return unless enabled?

      emitted = 0
      errors = []

      pc_room_ids = CharacterInstance
        .where(online: true)
        .join(:characters, id: :character_id)
        .where(is_npc: false)
        .select_map(:current_room_id)
        .uniq
        .compact

      pc_room_ids.each do |room_id|
        room = Room[room_id]
        next unless room

        pc_count = CharacterInstance
          .where(current_room_id: room_id, online: true)
          .join(:characters, id: :character_id)
          .where(is_npc: false)
          .count

        next if pc_count < min_players
        next unless rand < emit_chance

        begin
          emit = generate_for_room(room)
          if emit
            broadcast_to_room(room, emit)
            emitted += 1
          end
        rescue StandardError => e
          errors << { room_id: room_id, error: e.message }
        end
      end

      warn "[Atmosphere] Emitted to #{emitted} room(s)" if emitted > 0
      errors.each { |err| warn "[Atmosphere] Error for room ##{err[:room_id]}: #{err[:error]}" }
    rescue StandardError => e
      warn "[Atmosphere] Error processing atmospheric emits: #{e.message}"
    end

    private

    # Build the LLM prompt with room context
    # @param context [Hash] Room context data
    # @return [String]
    def build_prompt(context)
      memories_line = if context[:recent_memories] && !context[:recent_memories].empty?
                        "- Recent events: #{context[:recent_memories]}"
                      else
                        ''
                      end

      GamePrompts.get(
        'atmospheric.room_emit',
        room_name: context[:room_name],
        room_type: context[:room_type],
        room_description: context[:room_description],
        time_of_day: context[:time_of_day],
        season: context[:season],
        weather: context[:weather],
        publicity: context[:publicity],
        characters_present: context[:characters_present],
        memories_line: memories_line
      )
    end

    # Get weather context string for a location
    # @param location [Location, nil]
    # @return [String]
    def weather_context(location)
      weather = location&.weather
      return 'clear conditions' unless weather

      temp = weather.respond_to?(:temperature_f) ? weather.temperature_f : nil
      intensity = weather.respond_to?(:intensity) ? weather.intensity : 'moderate'
      condition = weather.respond_to?(:condition) ? weather.condition : 'clear'

      temp ? "#{intensity} #{condition}, #{temp}F" : "#{intensity} #{condition}"
    end

    # Get recent memory context for a room
    # @param room [Room]
    # @return [String, nil]
    def recent_memory_context(room)
      memories = WorldMemory.for_room(room, limit: 3).all
      return nil if memories.empty?

      summaries = memories.map(&:summary).compact
      return nil if summaries.empty?

      summaries.join('; ').slice(0, 200)
    end

    # Get human-readable room population description
    # @param room [Room]
    # @return [String]
    def room_population(room)
      count = find_characters_in_room(room.id, eager: []).count
      case count
      when 0 then 'empty'
      when 1 then 'one person'
      when 2..3 then 'a few people'
      else 'several people'
      end
    end

    # Format the LLM output into a clean emit
    # @param text [String]
    # @return [String]
    def format_emit(text)
      return nil if text.nil?

      text = text.strip
      text = text.gsub(/^["']|["']$/, '') # Remove surrounding quotes
      text = text.gsub(/\n+/, ' ')        # Remove newlines
      text.slice(0, 150)                  # Safety limit
    end

    # Check if room type is excluded from emits
    # @param room [Room]
    # @return [Boolean]
    def excluded_room?(room)
      room_type = room.room_type&.to_s&.downcase
      EXCLUDED_ROOM_TYPES.include?(room_type)
    end

    # Check if room is public or semi-public
    # @param room [Room]
    # @return [Boolean]
    def public_or_semi_public?(room)
      publicity = room.publicity&.to_s&.downcase || 'public'
      ALLOWED_PUBLICITY.include?(publicity)
    end

    # Check if room is on cooldown
    # @param room [Room]
    # @return [Boolean]
    def on_cooldown?(room)
      REDIS_POOL.with do |redis|
        key = "atmospheric_emit_cooldown:#{room.id}"
        redis.exists?(key)
      end
    rescue StandardError => e
      warn "[AtmosphericEmitService] Failed to check cooldown: #{e.message}"
      false
    end

    # Set cooldown for a room
    # @param room [Room]
    def set_cooldown!(room)
      REDIS_POOL.with do |redis|
        key = "atmospheric_emit_cooldown:#{room.id}"
        redis.setex(key, GameConfig::NpcAnimation::ATMOSPHERIC_COOLDOWN_SECONDS, '1')
      end
    rescue StandardError => e
      warn "[AtmosphericEmitService] Failed to set cooldown: #{e.message}"
    end
  end
end
