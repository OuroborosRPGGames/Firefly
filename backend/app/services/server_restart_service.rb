# frozen_string_literal: true

require 'time'

module ServerRestartService
  REDIS_KEY = 'firefly:restart:pending'
  VALID_TYPES = %w[phased full].freeze

  class << self
    def schedule(type:, delay:)
      type = type.to_s
      delay = delay.to_i

      unless VALID_TYPES.include?(type)
        return { error: "Invalid restart type: #{type}. Must be phased or full." }
      end

      # Check if already pending
      REDIS_POOL.with do |redis|
        if redis.get(REDIS_KEY)
          return { error: 'A restart is already pending. Cancel it first.' }
        end
      end

      restart_at = Time.now + delay
      state = { type: type, restart_at: restart_at.iso8601 }
      ttl = delay + 60 # Safety margin for stale keys

      REDIS_POOL.with do |redis|
        redis.setex(REDIS_KEY, [ttl, 61].max, state.to_json)
      end

      if delay.zero?
        BroadcastService.to_all(
          '[Server] Restarting now. You will be briefly disconnected.',
          type: :system
        )
        execute(type)
      else
        ServerRestartJob.perform_async(type, delay)
      end

      { success: true, restart_at: restart_at.iso8601 }
    rescue StandardError => e
      warn "[ServerRestartService] Schedule failed: #{e.message}"
      { error: "Failed to schedule restart: #{e.message}" }
    end

    def cancel
      REDIS_POOL.with do |redis|
        if redis.del(REDIS_KEY).zero?
          return { error: 'No restart pending.' }
        end
      end

      BroadcastService.to_all(
        '[Server] Scheduled restart has been cancelled.',
        type: :system
      )

      { success: true }
    rescue StandardError => e
      warn "[ServerRestartService] Cancel failed: #{e.message}"
      { error: "Failed to cancel restart: #{e.message}" }
    end

    def status
      REDIS_POOL.with do |redis|
        raw = redis.get(REDIS_KEY)
        return { pending: false } unless raw

        data = JSON.parse(raw)
        restart_at = Time.parse(data['restart_at'])
        remaining = [(restart_at - Time.now).ceil, 0].max

        {
          pending: true,
          type: data['type'],
          remaining_seconds: remaining,
          restart_at: data['restart_at']
        }
      end
    rescue StandardError => e
      warn "[ServerRestartService] Status check failed: #{e.message}"
      { pending: false }
    end

    def execute(type)
      app_root = File.expand_path('../../', __dir__)

      script = case type
      when 'full'
        pid_file = File.join(app_root, 'tmp', 'pids', 'puma.pid')
        "sleep 2 && kill -USR2 $(cat #{pid_file} 2>/dev/null || echo 0) 2>/dev/null || touch #{File.join(app_root, 'tmp', 'restart.txt')}"
      else # phased
        "sleep 2 && touch #{File.join(app_root, 'tmp', 'restart.txt')}"
      end

      pid = spawn(script, [:out, :err] => '/dev/null', pgroup: true)
      Process.detach(pid)

      warn "[ServerRestartService] Restart triggered (#{type}), detached PID: #{pid}"
    rescue StandardError => e
      warn "[ServerRestartService] Execute failed: #{e.message}"
    end
  end
end
