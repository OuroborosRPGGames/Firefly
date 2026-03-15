# frozen_string_literal: true

module AutoGm
  # Cleans up stuck and abandoned Auto-GM sessions.
  #
  # Runs periodically via GameCleanupService.sweep! to end sessions where:
  # - All participants are offline
  # - All participants have left the room
  # - The GM loop has died (no heartbeat + no actions for 30 min)
  # - The session has been running for 8+ hours
  #
  # @example
  #   AutoGm::AutoGmCleanupService.cleanup_all!
  #   # => { cleaned: 1, reasons: { orphaned: 1 }, errors: [] }
  #
  class AutoGmCleanupService
    class << self
      def cleanup_all!
        results = { cleaned: 0, reasons: Hash.new(0), errors: [] }

        return results unless defined?(AutoGmSession)

        AutoGmSession.active.each do |session|
          reason = determine_reason(session)
          next unless reason

          cleanup_session!(session, reason, results)
        rescue StandardError => e
          results[:errors] << { session_id: session.id, error: e.message }
        end

        results
      end

      private

      def determine_reason(session)
        instances = Array(session.participant_instances)

        if instances.any?
          # Check if all participants are offline
          return :all_offline if instances.all? { |ci| !ci.online }

          # Check if all online participants have left the room
          online_instances = instances.select(&:online)
          if online_instances.any? && online_instances.all? { |ci| ci.current_room_id != session.current_room_id }
            last_activity = session.last_action_at || session.started_at || session.created_at
            if age_seconds(last_activity) > GameConfig::Cleanup::AUTO_GM_ALL_LEFT_ROOM_SECONDS
              return :left_room
            end
          end
        end

        # Check for orphaned GM loop (running/climax with no heartbeat and no recent actions)
        if session.gm_can_act?
          heartbeat_age = age_seconds(session.loop_heartbeat_at)
          action_age = age_seconds(session.last_action_at || session.started_at || session.created_at)

          if heartbeat_age > GameConfig::Cleanup::AUTO_GM_ORPHAN_SECONDS &&
             action_age > GameConfig::Cleanup::AUTO_GM_ORPHAN_SECONDS
            return :orphaned
          end
        end

        # Check if running too long overall
        start_time = session.started_at || session.created_at
        if age_seconds(start_time) > GameConfig::Cleanup::AUTO_GM_MAX_DURATION_SECONDS
          return :too_long
        end

        nil
      end

      def cleanup_session!(session, reason, results)
        reason_text = case reason
                      when :all_offline
                        'All participants went offline'
                      when :left_room
                        'All participants left the area'
                      when :orphaned
                        'GM loop stopped responding'
                      when :too_long
                        'Maximum session duration reached'
                      else
                        'Session cleanup'
                      end

        AutoGmResolutionService.abandon(session, reason: reason_text)

        results[:cleaned] += 1
        results[:reasons][reason] += 1
      end

      def age_seconds(timestamp)
        return Float::INFINITY unless timestamp

        Time.now - timestamp
      end
    end
  end
end
