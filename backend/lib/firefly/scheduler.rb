# frozen_string_literal: true

module Firefly
  # Main scheduler for game ticks and cron jobs
  #
  # Manages two types of scheduling:
  # - Fast game ticks (every 5 seconds) for combat, regen, cooldowns
  # - Slow cron jobs (minute-level) for cleanup, reports, maintenance
  #
  # The scheduler runs in a background thread and can be stopped gracefully.
  #
  class Scheduler
    TICK_INTERVAL = 5 # seconds
    CRON_CHECK_INTERVAL = 60 # seconds

    WATCHDOG_INTERVAL = 30 # seconds - how often the watchdog checks
    WATCHDOG_STALE_THRESHOLD = 60 # seconds - ticks stale for this long triggers restart

    attr_reader :tick_count, :running, :last_tick_at

    def initialize
      @tick_count = 0
      @running = false
      @thread = nil
      @watchdog_thread = nil
      @tick_handlers = []
      @cron_handlers = []
      @last_cron_check = Time.now
      @last_tick_at = nil
    end

    # Start the scheduler
    def start
      return if @running

      @running = true
      @thread = Thread.new { run_loop }
      @watchdog_thread = Thread.new { watchdog_loop }
      log("Scheduler started (tick interval: #{TICK_INTERVAL}s)")
    end

    # Stop the scheduler gracefully
    def stop
      return unless @running

      @running = false
      @thread&.join(5) # Wait up to 5 seconds
      @thread&.kill if @thread&.alive?
      @watchdog_thread&.kill if @watchdog_thread&.alive?
      log('Scheduler stopped')
    end

    # Register a tick handler (called every game tick)
    # @param interval [Integer] run every N ticks (default: 1 = every tick)
    # @yield [TickEvent] block to execute
    def on_tick(interval = 1, &block)
      @tick_handlers << { interval: interval, handler: block }
    end

    # Register a cron handler
    # @param spec [Hash] cron specification
    # @yield [CronEvent] block to execute
    def on_cron(spec, &block)
      @cron_handlers << { spec: spec, handler: block, last_run: nil }
    end

    # Get scheduler status
    # @return [Hash]
    def status
      {
        running: @running,
        tick_count: @tick_count,
        tick_handlers: @tick_handlers.size,
        cron_handlers: @cron_handlers.size,
        uptime_seconds: @start_time ? (Time.now - @start_time).to_i : 0,
        last_tick_at: @last_tick_at&.iso8601,
        seconds_since_tick: @last_tick_at ? (Time.now - @last_tick_at).round(1) : nil,
        thread_alive: @thread&.alive? || false
      }
    end

    # Fire a single tick (useful for testing)
    def fire_tick!
      process_tick
    end

    # Process pending cron jobs (useful for testing)
    def process_cron!
      process_cron_jobs
    end

    class << self
      def instance
        @instance ||= new
      end

      def start
        instance.start
      end

      def stop
        instance.stop
      end

      def on_tick(interval = 1, &block)
        instance.on_tick(interval, &block)
      end

      def on_cron(spec, &block)
        instance.on_cron(spec, &block)
      end

      def status
        instance.status
      end

      # Reset the singleton (for testing)
      def reset!
        instance.stop if instance.running
        @instance = nil
      end
    end

    private

    def run_loop
      @start_time = Time.now

      while @running
        process_tick
        check_cron_jobs
        sleep(TICK_INTERVAL)
      end
    rescue Exception => e # rubocop:disable Lint/RescueException
      # Catch ALL exceptions including SystemStackError, NoMemoryError, etc.
      # A dead scheduler thread silently stops all game processing (movement,
      # combat timeouts, NPC animations) with no visible error to players.
      raise if e.is_a?(Interrupt) || e.is_a?(SignalException)

      log("CRITICAL scheduler error (#{e.class}): #{e.message}")
      log(e.backtrace&.first(5)&.join("\n") || '(no backtrace)')
      retry if @running
    end

    def process_tick
      @tick_count += 1
      @last_tick_at = Time.now
      event = TickEvent.new(@tick_count, Time.now)

      # Run registered tick handlers
      @tick_handlers.each do |handler_info|
        next unless (@tick_count % handler_info[:interval]).zero?

        begin
          handler_info[:handler].call(event)
        rescue Exception => e # rubocop:disable Lint/RescueException
          raise if e.is_a?(Interrupt) || e.is_a?(SignalException)

          log("Tick handler error (#{e.class}): #{e.message}")
        end
      end

      # Run database tick tasks
      begin
        ScheduledTask.tick_tasks(@tick_count).each(&:execute!)
      rescue StandardError => e
        log("Tick task error: #{e.message}")
      end
    end

    def check_cron_jobs
      now = Time.now
      return if now - @last_cron_check < CRON_CHECK_INTERVAL

      @last_cron_check = now
      process_cron_jobs
    end

    def process_cron_jobs
      now = Time.now
      event = CronEvent.new(now)

      # Run registered cron handlers
      @cron_handlers.each do |handler_info|
        next unless Cron.matches?(handler_info[:spec], now)
        next if handler_info[:last_run] && now - handler_info[:last_run] < 60

        begin
          handler_info[:handler].call(event)
          handler_info[:last_run] = now
        rescue StandardError => e
          log("Cron handler error: #{e.message}")
        end
      end

      # Run database cron tasks
      begin
        ScheduledTask.due_tasks.each(&:execute!)
      rescue StandardError => e
        log("Cron task error: #{e.message}")
      end
    end

    # Watchdog: detects when the main tick thread is stuck or dead and restarts it.
    # Runs in a separate thread so it's not affected by tick thread blocking.
    def watchdog_loop
      sleep(WATCHDOG_STALE_THRESHOLD) # Initial grace period

      while @running
        sleep(WATCHDOG_INTERVAL)
        next unless @running
        next unless @last_tick_at

        stale_seconds = Time.now - @last_tick_at
        next if stale_seconds < WATCHDOG_STALE_THRESHOLD

        log("WATCHDOG: Tick thread stale for #{stale_seconds.round(1)}s — restarting")
        @thread&.kill if @thread&.alive?
        @thread = Thread.new { run_loop }
      end
    rescue StandardError => e
      log("WATCHDOG error: #{e.message}")
      retry if @running
    end

    def log(message)
      puts "[Scheduler] #{message}"
    end
  end

  # Event object passed to tick handlers
  class TickEvent
    attr_reader :tick_number, :timestamp

    def initialize(tick_number, timestamp)
      @tick_number = tick_number
      @timestamp = timestamp
    end
  end

  # Event object passed to cron handlers
  class CronEvent
    attr_reader :timestamp

    def initialize(timestamp)
      @timestamp = timestamp
    end

    def hour
      @timestamp.hour
    end

    def minute
      @timestamp.min
    end

    def day
      @timestamp.day
    end

    def weekday
      @timestamp.wday
    end
  end
end
