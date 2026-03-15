# frozen_string_literal: true

# JukeboxPlaybackService - Background processor for jukebox playlist playback
#
# Handles automatic track advancement and video broadcasting for room jukeboxes.
# Uses precise thread-based scheduling when track duration is known.
# Falls back to tick-based polling for tracks without known duration.
#
# Similar to Ravencroft's jukebox_update() in tick_update.rb.
#
# Usage:
#   # Immediate track playback with precise scheduling
#   JukeboxPlaybackService.play_track_now(jukebox, track)
#
#   # Fallback polling (called by scheduler)
#   JukeboxPlaybackService.process_due_jukeboxes!
#
module JukeboxPlaybackService
  class << self
    # Default track duration from centralized YouTube service
    def default_track_duration
      YouTubeMetadataService::DEFAULT_DURATION
    end
    # Play a track immediately and schedule the next track with precise timing
    #
    # @param jukebox [Jukebox]
    # @param track [JukeboxTrack] optional, uses current_track if not provided
    # @return [Boolean] true if track was broadcast
    def play_track_now(jukebox, track = nil)
      return false unless jukebox

      room = jukebox.room
      return false unless room

      track ||= jukebox.current_track
      return false unless track

      # Broadcast the track
      broadcast_track(jukebox, track, room)

      # Get track duration
      duration = track.duration_seconds

      # Schedule next track
      if duration && duration > 0
        # Precise scheduling - spawn thread that sleeps until track ends
        schedule_next_track_precise(jukebox, duration)
      else
        # Fallback - set next_play for tick-based polling
        schedule_next_track_fallback(jukebox)
      end

      true
    end

    # Process all jukeboxes that are ready for their next track (fallback polling)
    #
    # This runs periodically as a safety net for:
    # - Tracks without known duration
    # - Cases where precise scheduling threads failed
    #
    # @return [Hash] Results with :played, :advanced, :stopped, :errors
    def process_due_jukeboxes!
      results = { played: 0, advanced: 0, stopped: 0, errors: [] }

      due_jukeboxes.each do |jukebox|
        process_jukebox(jukebox, results)
      rescue StandardError => e
        results[:errors] << { jukebox_id: jukebox.id, error: e.message }
      end

      results
    end

    # Process a single jukebox (called by fallback polling)
    #
    # @param jukebox [Jukebox]
    # @param results [Hash] Accumulator for results
    def process_jukebox(jukebox, results)
      room = jukebox.room
      return unless room

      # Check if anyone is in the room
      unless room_has_players?(room.id)
        jukebox.stop!
        results[:stopped] += 1
        return
      end

      track = jukebox.current_track

      # If no track at current position, try to advance or stop
      unless track
        if jukebox.loop_play
          # Loop back to beginning
          first_track = jukebox.tracks_dataset.order(:position).first
          if first_track
            jukebox.update(currently_playing: first_track.position)
            track = first_track
          else
            jukebox.stop!
            results[:stopped] += 1
            return
          end
        else
          jukebox.stop!
          results[:stopped] += 1
          return
        end
      end

      # Broadcast the track and schedule next
      if play_track_now(jukebox, track)
        results[:played] += 1
        advance_to_next_track(jukebox)
        results[:advanced] += 1
      end
    end

    # Find all jukeboxes that are playing and ready for next track (fallback)
    #
    # @return [Array<Jukebox>]
    def due_jukeboxes
      Jukebox
        .exclude(currently_playing: nil)
        .where { next_play <= Time.now }
        .all
    end

    # Check if a room has online players (not just NPCs)
    #
    # @param room_id [Integer]
    # @return [Boolean]
    def room_has_players?(room_id)
      CharacterInstance
        .where(current_room_id: room_id, online: true)
        .join(:characters, id: :character_id)
        .where(is_npc: false)
        .count > 0
    end

    # Broadcast a track to all characters in the room
    #
    # @param jukebox [Jukebox]
    # @param track [JukeboxTrack]
    # @param room [Room]
    def broadcast_track(jukebox, track, room)
      video_data = build_video_data(jukebox, track)

      # Build the visual message (iframe embed)
      embed_html = build_embed_html(jukebox, track)

      # Build structured message for webclient
      message = {
        content: "#{jukebox.name} plays: #{track.display_title}",
        html: embed_html
      }

      # Broadcast to room with media type
      BroadcastService.to_room(
        room.id,
        message,
        type: :media,
        jukebox_id: jukebox.id,
        track_id: track.id,
        video_data: video_data
      )
    end

    # Build video data for webclient rendering
    #
    # @param jukebox [Jukebox]
    # @param track [JukeboxTrack]
    # @return [Hash]
    def build_video_data(jukebox, track)
      {
        jukebox_id: jukebox.id,
        jukebox_name: jukebox.name,
        track_id: track.id,
        track_title: track.display_title,
        url: track.url,
        embed_url: track.embed_url,
        video_id: track.youtube_video_id,
        is_youtube: track.youtube?,
        duration: track.duration_seconds,
        position: track.position,
        autoplay: true,
        shuffle: jukebox.shuffle_play,
        loop: jukebox.loop_play
      }
    end

    # Build HTML embed for the track
    #
    # @param jukebox [Jukebox]
    # @param track [JukeboxTrack]
    # @return [String]
    def build_embed_html(jukebox, track)
      return build_generic_embed(track) unless track.youtube?

      embed_url = track.embed_url
      return build_generic_embed(track) unless embed_url

      # Add autoplay parameter if not present
      embed_url += embed_url.include?('?') ? '&autoplay=1' : '?autoplay=1'

      <<~HTML
        <fieldset class="jukebox-track">
          <legend>#{escape_html(track.display_title)}</legend>
          <iframe
            width="98%"
            height="360"
            src="#{escape_html(embed_url)}"
            title="#{escape_html(track.display_title)}"
            frameborder="0"
            allow="autoplay; fullscreen; encrypted-media"
            allowfullscreen>
          </iframe>
        </fieldset>
      HTML
    end

    # Build generic embed for non-YouTube URLs
    #
    # @param track [JukeboxTrack]
    # @return [String]
    def build_generic_embed(track)
      <<~HTML
        <fieldset class="jukebox-track">
          <legend>#{escape_html(track.display_title)}</legend>
          <a href="#{escape_html(track.url)}" target="_blank">#{escape_html(track.url)}</a>
        </fieldset>
      HTML
    end

    # Advance jukebox to the next track position (without triggering playback)
    #
    # @param jukebox [Jukebox]
    def advance_to_next_track(jukebox)
      current_pos = jukebox.currently_playing

      if jukebox.shuffle_play
        # Pick a random different track
        next_track = jukebox.tracks_dataset
                            .exclude(position: current_pos)
                            .order(Sequel.lit('RANDOM()'))
                            .first

        if next_track
          jukebox.update(currently_playing: next_track.position)
        elsif jukebox.loop_play
          # Only one track and looping - keep same position
          # No update needed
        else
          # Single track, no loop - will stop after this
          # Keep current position, will stop on next check
        end
      else
        # Sequential - advance to next position
        next_track = jukebox.tracks_dataset
                            .where { position > current_pos }
                            .order(:position)
                            .first

        if next_track
          jukebox.update(currently_playing: next_track.position)
        elsif jukebox.loop_play
          # Loop back to beginning
          first_track = jukebox.tracks_dataset.order(:position).first
          jukebox.update(currently_playing: first_track.position) if first_track
        else
          # End of playlist, no loop - mark as ending
          # The next cycle will stop it when there's no track
          max_pos = jukebox.tracks_dataset.max(:position) || 0
          jukebox.update(currently_playing: max_pos + 1)
        end
      end
    end

    private

    # Schedule next track with precise timing using a background thread
    #
    # @param jukebox [Jukebox]
    # @param duration_seconds [Integer]
    def schedule_next_track_precise(jukebox, duration_seconds)
      jukebox_id = jukebox.id

      # Set next_play far in future (prevents fallback from picking this up)
      # We'll update it when the thread finishes
      jukebox.update(next_play: Time.now + duration_seconds + 3600)

      Thread.new do
        # Sleep until track ends (add small buffer for network latency)
        sleep(duration_seconds + 1)

        # Re-fetch jukebox (might have been stopped or changed)
        current_jukebox = Jukebox[jukebox_id]
        next unless current_jukebox
        next unless current_jukebox.playing?

        # Advance to next track
        advance_to_next_track(current_jukebox)

        # Play the next track (this will recursively schedule)
        play_track_now(current_jukebox)
      rescue StandardError => e
        warn "[JukeboxPlayback] Precise scheduling error for jukebox ##{jukebox_id}: #{e.message}"

        # On error, set next_play so fallback can recover
        current_jukebox = Jukebox[jukebox_id]
        current_jukebox&.update(next_play: Time.now) if current_jukebox&.playing?
      end
    end

    # Schedule next track using fallback timing (for tracks without duration)
    #
    # @param jukebox [Jukebox]
    def schedule_next_track_fallback(jukebox)
      # Use default duration - tick-based polling will pick this up
      jukebox.update(next_play: Time.now + default_track_duration)

      # Also pre-advance to next track position
      advance_to_next_track(jukebox)
    end

    # Escape HTML entities
    #
    # @param str [String]
    # @return [String]
    def escape_html(str)
      return '' if str.nil?

      str.to_s
         .gsub('&', '&amp;')
         .gsub('<', '&lt;')
         .gsub('>', '&gt;')
         .gsub('"', '&quot;')
         .gsub("'", '&#39;')
    end
  end
end
