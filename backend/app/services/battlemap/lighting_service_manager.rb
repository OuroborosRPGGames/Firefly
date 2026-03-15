# frozen_string_literal: true

require 'faraday'

# Manages the lifecycle of the Python lighting microservice process.
#
# Starts the service on-demand when a fight needs lighting,
# and shuts it down after IDLE_TIMEOUT seconds of inactivity.
#
# Usage:
#   LightingServiceManager.ensure_running  # => true if ready, false if timed out
#   LightingServiceManager.mark_used       # reset idle timer
#   LightingServiceManager.check_idle_shutdown  # called by scheduler
#   LightingServiceManager.stop            # graceful shutdown
#
class LightingServiceManager
  STARTUP_TIMEOUT = 10      # seconds to wait for service to respond to /health
  IDLE_TIMEOUT = 3600       # 1 hour of no usage before auto-shutdown
  HEALTH_POLL_INTERVAL = 0.3 # seconds between /health polls during startup

  class << self
    def instance
      @instance ||= new
    end

    def ensure_running
      instance.ensure_running
    end

    def mark_used
      instance.mark_used
    end

    def stop
      instance.stop
    end

    def running?
      instance.running?
    end

    def check_idle_shutdown
      instance.check_idle_shutdown
    end

    def status
      instance.status
    end

    # Reset singleton (for testing)
    def reset!
      instance.stop if @instance&.running?
      @instance = nil
    end
  end

  def initialize
    @pid = nil
    @last_used_at = nil
    @mutex = Mutex.new
  end

  # Start the service if needed and wait for it to be healthy.
  # Returns true if the service is ready, false if it timed out.
  def ensure_running
    @mutex.synchronize do
      # Fast path: already running and healthy
      if process_alive? && healthy?
        @last_used_at = Time.now
        return true
      end

      # Start if not running
      start_process unless process_alive?

      # If process failed to start, bail out
      return false unless process_alive?

      # Wait for /health to respond
      ready = wait_for_healthy
      @last_used_at = Time.now if ready
      ready
    end
  rescue StandardError => e
    warn "[LightingServiceManager] ensure_running failed: #{e.message}"
    false
  end

  def mark_used
    @last_used_at = Time.now
  end

  # Called periodically by the scheduler to shut down idle service.
  def check_idle_shutdown
    return unless process_alive?
    return unless @last_used_at

    idle_seconds = Time.now - @last_used_at
    return unless idle_seconds >= IDLE_TIMEOUT

    warn "[LightingServiceManager] Shutting down after #{(idle_seconds / 60).round}m idle"
    stop
  end

  def stop
    @mutex.synchronize { stop_process }
  end

  def running?
    process_alive?
  end

  def status
    {
      running: process_alive?,
      pid: @pid,
      last_used_at: @last_used_at,
      idle_seconds: @last_used_at ? (Time.now - @last_used_at).round : nil
    }
  end

  private

  def start_process
    service_dir = File.expand_path('../../../lighting_service', __dir__)
    venv_python = File.join(service_dir, 'venv', 'bin', 'python3')
    python = File.exist?(venv_python) ? venv_python : 'python3'
    port = lighting_port

    log_path = File.join(service_dir, 'service.log')

    @pid = Process.spawn(
      python, '-m', 'uvicorn', 'main:app',
      '--host', '127.0.0.1',
      '--port', port.to_s,
      chdir: service_dir,
      out: log_path,
      err: log_path
    )
    Process.detach(@pid)

    warn "[LightingServiceManager] Started process #{@pid} on port #{port}"
  rescue StandardError => e
    warn "[LightingServiceManager] Failed to start: #{e.message}"
    @pid = nil
  end

  def stop_process
    return unless @pid

    pid = @pid
    @pid = nil

    Process.kill('TERM', pid)
    # Poll until process exits or deadline expires
    deadline = Time.now + 5
    loop do
      begin
        result = Process.waitpid(pid, Process::WNOHANG)
        break if result # Process has exited
      rescue Errno::ECHILD
        break # Already gone
      end
      break if Time.now > deadline
      sleep 0.1
    end
  rescue Errno::ESRCH
    # Process already gone
  rescue StandardError => e
    warn "[LightingServiceManager] Error stopping process: #{e.message}"
    begin
      Process.kill('KILL', pid)
    rescue StandardError => kill_error
      warn "[LightingServiceManager] Failed force-kill for process #{pid}: #{kill_error.message}"
      nil
    end
  end

  def process_alive?
    return false unless @pid

    Process.kill(0, @pid)
    true
  rescue Errno::ESRCH, Errno::EPERM
    @pid = nil
    false
  end

  def healthy?
    conn = Faraday.new(url: service_url) { |f| f.options.timeout = 2; f.options.open_timeout = 2 }
    response = conn.get('/health')
    response.success?
  rescue Faraday::ConnectionFailed, Faraday::TimeoutError
    false
  end

  def wait_for_healthy
    deadline = Time.now + STARTUP_TIMEOUT
    while Time.now < deadline
      return true if healthy?

      # Check that process hasn't died
      unless process_alive?
        warn "[LightingServiceManager] Process died during startup"
        return false
      end

      sleep(HEALTH_POLL_INTERVAL)
    end

    warn "[LightingServiceManager] Startup timed out after #{STARTUP_TIMEOUT}s"
    false
  end

  def service_url
    ENV.fetch('LIGHTING_SERVICE_URL', "http://localhost:#{lighting_port}")
  end

  def lighting_port
    ENV.fetch('LIGHTING_SERVICE_PORT', '18942')
  end
end
