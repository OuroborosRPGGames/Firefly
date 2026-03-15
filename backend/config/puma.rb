#!/usr/bin/env puma
# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

environment ENV.fetch('RACK_ENV', 'development')

# 2 workers by default to catch concurrency issues early
# Set WEB_CONCURRENCY=0 for single-mode if needed
workers ENV.fetch('WEB_CONCURRENCY', 2).to_i

# 5 threads optimal for I/O-bound MRI Ruby
threads_count = ENV.fetch('PUMA_THREADS', 5).to_i
threads threads_count, threads_count

# Memory optimization via copy-on-write
preload_app!

# Network - use bind only (port + bind causes double-binding in cluster mode)
bind "tcp://0.0.0.0:#{ENV.fetch('PORT', 3000)}"

# Process management
pidfile 'tmp/pids/puma.pid'
state_path 'tmp/pids/puma.state'

# Logging
stdout_redirect 'log/puma_access.log', 'log/puma_error.log', true

# CRITICAL: Proper lifecycle hooks for connection management
before_fork do
  # Disconnect BEFORE forking - children will reconnect
  require_relative 'database'
  FireflyDatabase.disconnect if defined?(FireflyDatabase)
end

on_worker_boot do
  # Each worker MUST reconnect with its own pool
  require_relative 'database'
  DB = FireflyDatabase.connect
  puts "[Worker #{Process.pid}] Connected to database (pool: #{DB.pool.max_size})"

  # Silently clear stale restart keys left over from previous runs
  begin
    REDIS_POOL.with { |redis| redis.del('firefly:restart:pending') } if defined?(REDIS_POOL)
  rescue StandardError
    nil
  end
end

on_worker_shutdown do
  require_relative 'database'
  FireflyDatabase.disconnect if defined?(FireflyDatabase)
end

on_restart do
  puts 'Puma is restarting...'
end

# Enable phased restart by touching tmp/restart.txt
# Run: touch tmp/restart.txt
# This triggers a rolling restart of workers without downtime
plugin :tmp_restart

# Embedded Sidekiq — auto-starts worker threads inside Puma.
# Disable with DISABLE_SIDEKIQ=1 (e.g. for tests).
plugin :sidekiq
