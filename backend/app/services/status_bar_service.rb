# frozen_string_literal: true

# Calculates status bar content for a character
# Provides data for both left (channel/time) and right (activity) status bars
#
# Left status bar: Channel + Time + Private Mode
# Right status bar: Activity + Presence (AFK/GTG)
class StatusBarService
  attr_reader :character_instance

  def initialize(character_instance)
    @character_instance = character_instance
  end

  # Full status bar data for API responses
  # @return [Hash] with :left, :right, :weather, and :combat status bar data
  def build_status_data
    return nil unless character_instance

    {
      left: build_left_status,
      right: build_right_status,
      weather: build_weather_data,
      combat: build_combat_status
    }
  end

  private

  # LEFT STATUS BAR: Channel + Time + Private Mode
  def build_left_status
    {
      channel: current_channel_info,
      dm_targets: recent_dm_targets,
      time: time_display,
      time_gradient: time_gradient,
      moon_phase: moon_phase_emoji,
      private_mode: character_instance.private_mode?
    }
  end

  # RIGHT STATUS BAR: Activity + Presence
  def build_right_status
    {
      action_text: current_action_text,
      action_type: action_type,
      expires_in: action_expires_in,
      presence: presence_info
    }
  end

  # Channel info for left status — mode-aware
  def current_channel_info
    mode = character_instance.messaging_mode || 'channel'

    case mode
    when 'ooc'
      names = character_instance.ooc_target_names
      display = StringHelper.present?(names) ? "OOC: #{names}" : 'OOC'
      { name: display, display: display, mode: 'ooc' }
    when 'msg'
      names = character_instance.msg_target_names
      display = StringHelper.present?(names) ? "MSG: #{names}" : 'MSG'
      { name: display, display: display, mode: 'msg' }
    else
      build_channel_mode_info
    end
  end

  # Standard channel mode info (extracted from previous current_channel_info)
  def build_channel_mode_info
    channel_name = character_instance.last_channel_name

    # Fallback to current_channel_id if last_channel_name is not set
    if StringHelper.blank?(channel_name)
      if character_instance.current_channel_id
        channel = Channel[character_instance.current_channel_id]
        channel_name = channel&.name
      end
    end

    # If still no channel name, use the default OOC channel
    if StringHelper.blank?(channel_name)
      ooc_channel = begin
        ChannelBroadcastService.default_ooc_channel
      rescue StandardError => e
        warn "[StatusBarService] Failed to get default OOC channel: #{e.message}"
        nil
      end
      channel_name = ooc_channel&.name || 'OOC'
    end

    {
      name: channel_name,
      display: format_channel_display(channel_name),
      mode: 'channel'
    }
  end

  def format_channel_display(channel_name)
    case channel_name
    when 'room' then 'Room'
    when 'ooc' then 'OOC'
    when 'whisper' then 'Whisper'
    when 'private_message', 'pm' then 'PM'
    else channel_name.to_s.split(/[\s_]+/).map(&:capitalize).join(' ')
    end
  end

  # Recent DM targets
  def recent_dm_targets
    target_ids = character_instance.last_dm_target_ids
    return [] if target_ids.nil? || target_ids.empty?

    # Get character names for the target IDs
    # Note: Convert pg_array to Ruby array for Sequel's where clause
    # Note: full_name is a computed method, so we select forename/surname
    ids = target_ids.to_a
    Character.where(id: ids).select_map([:id, :forename, :surname]).map do |id, forename, surname|
      name = surname ? "#{forename} #{surname}" : forename
      { id: id, name: name }
    end
  rescue StandardError => e
    warn "[StatusBarService] Error fetching DM targets: #{e.message}"
    []
  end

  # Time display respects timeline
  def time_display
    timeline = character_instance.timeline
    location = character_instance.current_room&.location

    if timeline&.historical?
      # Show historical year instead of current date
      {
        year: timeline.year,
        era: timeline.era,
        display: timeline.display_name,
        is_historical: true
      }
    else
      # Normal time display
      game_time = GameTimeService.current_time(location)
      {
        hour: game_time.hour,
        formatted: game_time.strftime('%I:%M%p %a %e %b'),
        time_of_day: GameTimeService.time_of_day(location),
        season: GameTimeService.season(location),
        is_historical: false
      }
    end
  rescue StandardError => e
    warn "[StatusBarService] Error getting time display: #{e.message}"
    { hour: Time.now.hour, formatted: Time.now.strftime('%I:%M%p %a %e %b'), is_historical: false }
  end

  # Time gradient colors for client rendering
  def time_gradient
    location = character_instance.current_room&.location
    TimeGradientService.gradient_for_time(location)
  rescue StandardError => e
    warn "[StatusBarService] Error getting time gradient: #{e.message}"
    { period: :day, start_color: '#57C8CF', end_color: '#F4FB92' }
  end

  # Moon phase emoji
  def moon_phase_emoji
    MoonPhaseService.emoji
  rescue StandardError => e
    warn "[StatusBarService] Error getting moon phase: #{e.message}"
    nil
  end

  # Current action text for right status
  # Uses RoomDisplayService format for consistency with room look display
  def current_action_text
    room = character_instance.current_room
    return character_instance.display_action unless room

    # Use RoomDisplayService to get the same status format shown when looking at room
    service = RoomDisplayService.for(room, character_instance)
    service.send(:build_status_line, character_instance)
  rescue StandardError => e
    warn "[StatusBarService] Error getting action text: #{e.message}"
    nil
  end

  # Action type: :temporary or :static
  def action_type
    if character_instance.current_action && action_not_expired?
      :temporary
    else
      :static
    end
  end

  def action_not_expired?
    until_time = character_instance.current_action_until
    until_time.nil? || until_time > Time.now
  end

  # Seconds remaining for temporary action
  def action_expires_in
    return nil unless action_type == :temporary

    until_time = character_instance.current_action_until
    return nil unless until_time

    remaining = (until_time - Time.now).to_i
    remaining.positive? ? remaining : nil
  end

  # Presence info: AFK, GTG, Semi-AFK with countdown
  def presence_info
    if character_instance.afk?
      afk_info
    elsif character_instance.gtg_until && character_instance.gtg_until > Time.now
      gtg_info
    elsif character_instance.semiafk?
      semiafk_info
    else
      { status: 'present', display: nil }
    end
  end

  def afk_info
    afk_until = character_instance.respond_to?(:afk_until) ? character_instance.afk_until : nil

    if afk_until && afk_until > Time.now
      minutes = ((afk_until - Time.now) / 60).to_i
      { status: 'afk', display: "AFK #{minutes}m", minutes_remaining: minutes }
    else
      { status: 'afk', display: 'AFK' }
    end
  end

  def gtg_info
    gtg_until = character_instance.gtg_until
    minutes = ((gtg_until - Time.now) / 60).to_i
    { status: 'gtg', display: "GTG #{minutes}m", minutes_remaining: minutes }
  end

  def semiafk_info
    semiafk_until = character_instance.respond_to?(:semiafk_until) ? character_instance.semiafk_until : nil

    if semiafk_until && semiafk_until > Time.now
      minutes = ((semiafk_until - Time.now) / 60).to_i
      { status: 'semiafk', display: "Semi-AFK #{minutes}m", minutes_remaining: minutes }
    else
      { status: 'semiafk', display: 'Semi-AFK' }
    end
  end

  # WEATHER DATA: Current weather conditions + outdoor status
  def build_weather_data
    room = character_instance.current_room
    return nil unless room

    location = room.location
    zone = location&.zone

    # Get weather for this location/zone
    weather = if location
                Weather.for_location(location)
              elsif zone
                Weather.first(zone_id: zone.id)
              end

    return nil unless weather

    {
      condition: weather.condition,
      intensity: weather.intensity,
      temperature_c: weather.temperature_c,
      temperature_f: weather.temperature_f.round,
      humidity: weather.humidity,
      wind_speed_kph: weather.wind_speed_kph,
      is_outdoor: room.room_environment_type == :outdoor,
      emoji: weather_emoji(weather.condition)
    }
  rescue StandardError => e
    warn "[StatusBarService] Error building weather data: #{e.message}"
    nil
  end

  # Get emoji for weather condition
  def weather_emoji(condition)
    case condition
    when 'clear' then '☀'
    when 'cloudy' then '☁'
    when 'overcast' then '☁'
    when 'rain' then '☂'
    when 'storm', 'thunderstorm' then '⛈'
    when 'snow' then '❄'
    when 'blizzard' then '❄'
    when 'fog' then '▒'
    when 'wind' then '≋'
    when 'hail' then '⛆'
    when 'hurricane', 'tornado' then '⚡'
    when 'heat_wave' then '♨'
    when 'cold_snap' then '❆'
    else '☀'
    end
  end

  # COMBAT STATUS: HP data for blood effect visualization
  # Shows during combat, or out of combat when injured
  def build_combat_status
    # Get active fight participant (only from non-complete fights)
    active_fight_ids = Fight.exclude(status: 'complete').select(:id)
    participant = FightParticipant.where(
      character_instance_id: character_instance.id,
      fight_id: active_fight_ids
    ).order(:created_at).last

    if participant
      return {
        current_hp: participant.current_hp,
        max_hp: participant.max_hp,
        injury_level: participant.wound_penalty,
        spar_mode: participant.fight&.spar_mode? || false,
        touch_count: participant.touch_count || 0,
        willpower_dice: participant.willpower_dice&.to_f
      }
    end

    # Show HP out of combat if injured (character_instance.health is the one true HP)
    health = character_instance.health
    max_health = character_instance.max_health
    if health && max_health && health < max_health
      return {
        current_hp: health,
        max_hp: max_health,
        injury_level: max_health - health,
        spar_mode: false,
        touch_count: 0
      }
    end

    nil
  rescue StandardError => e
    warn "[StatusBarService] Error building combat status: #{e.message}"
    nil
  end
end
