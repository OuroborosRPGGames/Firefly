# frozen_string_literal: true

require 'sidekiq'

class ServerRestartJob
  include Sidekiq::Job

  sidekiq_options queue: 'default', retry: 0

  WARNING_INTERVALS = [300, 120, 60, 30, 10].freeze

  def perform(type, delay)
    restart_at = Time.now + delay
    warned = Set.new

    loop do
      unless restart_pending?
        warn '[ServerRestartJob] Restart cancelled, exiting'
        return
      end

      remaining = (restart_at - Time.now).ceil

      WARNING_INTERVALS.each do |interval|
        if remaining <= interval && !warned.include?(interval)
          warned.add(interval)
          broadcast_warning(remaining)
        end
      end

      if remaining <= 0
        BroadcastService.to_all(
          '[Server] Restarting now. You will be briefly disconnected.',
          type: :system
        )
        sleep 1
        ServerRestartService.execute(type)
        return
      end

      sleep 1
    end
  rescue StandardError => e
    warn "[ServerRestartJob] Error: #{e.message}"
  end

  private

  def restart_pending?
    REDIS_POOL.with { |redis| redis.exists?('firefly:restart:pending') }
  end

  def broadcast_warning(remaining_seconds)
    time_str = format_remaining(remaining_seconds)
    BroadcastService.to_all(
      "[Server] Restarting in #{time_str}. You will be briefly disconnected.",
      type: :system
    )
  end

  def format_remaining(seconds)
    if seconds >= 120
      "#{seconds / 60} minutes"
    elsif seconds >= 60
      '1 minute'
    elsif seconds == 1
      '1 second'
    else
      "#{seconds} seconds"
    end
  end
end
