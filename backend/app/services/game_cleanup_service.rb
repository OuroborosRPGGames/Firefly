# frozen_string_literal: true

# Unified periodic cleanup orchestrator for game systems.
#
# Delegates to per-system cleanup services:
# - FightCleanupService - Stale/abandoned fights
# - ActivityCleanupService - Stuck/abandoned activities
# - AutoGm::AutoGmCleanupService - Stuck/abandoned Auto-GM sessions
#
# @example
#   GameCleanupService.sweep!
#   # => { fights: { cleaned: 1, ... }, activities: { cleaned: 0, ... }, auto_gm: { cleaned: 0, ... } }
#
class GameCleanupService
  class << self
    def sweep!
      results = {}
      results[:fights] = safe_cleanup('Fights') { FightCleanupService.cleanup_all! }
      results[:activities] = safe_cleanup('Activities') { ActivityCleanupService.cleanup_all! }
      results[:auto_gm] = safe_cleanup('AutoGM') { AutoGm::AutoGmCleanupService.cleanup_all! }
      log_summary(results)
      results
    end

    private

    def safe_cleanup(name)
      yield
    rescue StandardError => e
      warn "[GameCleanup] #{name} failed: #{e.message}"
      { error: e.message }
    end

    def log_summary(results)
      parts = []

      if (fights = results[:fights]) && fights.is_a?(Hash) && !fights[:error]
        parts << "fights=#{fights[:cleaned] || 0}" if (fights[:cleaned] || 0) > 0
      end

      if (activities = results[:activities]) && activities.is_a?(Hash) && !activities[:error]
        parts << "activities=#{activities[:cleaned] || 0}" if (activities[:cleaned] || 0) > 0
      end

      if (auto_gm = results[:auto_gm]) && auto_gm.is_a?(Hash) && !auto_gm[:error]
        parts << "auto_gm=#{auto_gm[:cleaned] || 0}" if (auto_gm[:cleaned] || 0) > 0
      end

      # Only log when something was actually cleaned up
      warn "[GameCleanup] Sweep complete: #{parts.join(', ')}" if parts.any?
    end
  end
end
