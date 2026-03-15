# frozen_string_literal: true

module WorldGeneration
  # Spawns and monitors a Python subprocess for world generation.
  #
  # This service acts as the bridge between Ruby and the Python worldgen package.
  # It writes a config JSON file, spawns Python, polls the status file for progress,
  # and imports the results when complete.
  #
  # @example Basic usage
  #   job = WorldGenerationJob.find(123)
  #   service = PythonRunnerService.new(job)
  #   service.run
  #
  # @example With custom options
  #   service = PythonRunnerService.new(job, poll_interval: 5, timeout: 7200)
  #   service.run
  #
  class PythonRunnerService
    # Default interval between status file polls (seconds)
    DEFAULT_POLL_INTERVAL = 2

    # Default maximum generation time before timeout (1 hour)
    DEFAULT_TIMEOUT = 3600

    # Python module name for worldgen package
    PYTHON_MODULE = 'worldgen'

    # @param job [WorldGenerationJob] The job to run
    # @param poll_interval [Integer] Seconds between status polls (default: 2)
    # @param timeout [Integer] Max seconds before timeout (default: 3600)
    def initialize(job, poll_interval: DEFAULT_POLL_INTERVAL, timeout: DEFAULT_TIMEOUT)
      @job = job
      @world = job.world
      @poll_interval = poll_interval
      @timeout = timeout
      @pid = nil

      # Temp file paths
      @config_path = "/tmp/worldgen_#{job.id}_config.json"
      @status_path = "/tmp/worldgen_#{job.id}_status.json"
      @output_path = "/tmp/worldgen_#{job.id}_world.json"
    end

    # Run the Python world generation process
    #
    # This method:
    # 1. Writes the config file for Python
    # 2. Spawns the Python subprocess
    # 3. Monitors progress via status file polling
    # 4. Imports results when complete
    # 5. Cleans up temp files
    #
    # @return [void]
    def run
      @job.start!

      begin
        write_config
        spawn_python
        monitor_process
      rescue StandardError => e
        warn "[PythonRunnerService] Generation failed: #{e.message}"
        @job.fail!(e.message, e.backtrace&.first(10)&.join("\n"))
      ensure
        cleanup_temp_files
      end
    end

    private

    # Write the configuration JSON file for Python to read
    #
    # The config includes all generation parameters needed by the
    # Python worldgen pipeline.
    #
    # @return [void]
    def write_config
      config = @job.config || {}

      python_config = {
        'seed' => config['seed'] || Random.new_seed,
        'preset' => config['preset'] || 'earth_like',
        'subdivision_level' => config['subdivision_level'] || 5,
        'ocean_coverage' => config['ocean_coverage'] || 0.70,
        'planet_radius_km' => config['planet_radius_km'] || 6371,
        'output_path' => @output_path,
        'status_path' => @status_path
      }

      # Store the seed back to job config for reproducibility
      existing_config = @job.config || {}
      @job.update(config: existing_config.merge('seed' => python_config['seed']))

      File.write(@config_path, JSON.pretty_generate(python_config))
    end

    # Spawn the Python worldgen subprocess
    #
    # Runs: python -m worldgen generate --config /tmp/worldgen_ID_config.json
    #
    # @return [void]
    def spawn_python
      python = find_python

      @pid = Process.spawn(
        python, '-m', PYTHON_MODULE, 'generate',
        '--config', @config_path,
        chdir: python_worldgen_path,
        out: '/dev/null',
        err: '/dev/null'
      )
    end

    # Monitor the Python process until completion, failure, or timeout
    #
    # Polls the status file at regular intervals to track progress.
    # Updates the job's progress_percentage as generation proceeds.
    #
    # @return [void]
    def monitor_process
      start_time = Time.now

      loop do
        # Check timeout
        if Time.now - start_time > @timeout
          kill_process
          @job.fail!('Generation timed out')
          return
        end

        # Check if process is still running
        unless process_alive?
          handle_process_exit
          return
        end

        # Read and process status
        status = read_status_file
        if status
          case status['status']
          when 'complete'
            handle_completion
            return
          when 'failed'
            handle_failure(status)
            return
          else
            update_job_progress(status)
          end
        end

        sleep @poll_interval
      end
    end

    # Handle successful generation completion
    #
    # Updates job phase to 'importing', runs import, then completes.
    #
    # @return [void]
    def handle_completion
      existing_config = @job.config || {}
      @job.update(
        progress_percentage: 95,
        config: existing_config.merge('current_phase' => 'importing')
      )

      # Import the generated world data
      if File.exist?(@output_path)
        WorldImportService.new(@world, @output_path).import
      else
        warn "[PythonRunnerService] Output file not found: #{@output_path}"
      end

      @job.complete!
    end

    # Handle generation failure
    #
    # @param status [Hash] The failure status from Python
    # @return [void]
    def handle_failure(status)
      error_msg = status['error_message'] || 'Unknown error'
      traceback = status['traceback']

      @job.fail!(error_msg, traceback)
    end

    # Handle unexpected process exit
    #
    # Called when the Python process dies without writing complete/failed status.
    #
    # @return [void]
    def handle_process_exit
      # Try to get any error info from status file
      status = read_status_file

      if status && status['status'] == 'complete'
        handle_completion
      elsif status && status['status'] == 'failed'
        handle_failure(status)
      else
        @job.fail!('Python process exited unexpectedly')
      end
    end

    # Kill the Python subprocess
    #
    # Sends TERM signal first, then KILL if process doesn't exit.
    #
    # @return [void]
    def kill_process
      return unless @pid

      begin
        Process.kill('TERM', @pid)
        # Give it a moment to terminate gracefully
        sleep 1
        if process_alive?
          Process.kill('KILL', @pid)
        end
      rescue Errno::ESRCH, Errno::EPERM
        # Process already dead or we don't have permission
      end
    end

    # Update job progress from status file data
    #
    # @param status [Hash] The status data from Python
    # @return [void]
    def update_job_progress(status)
      updates = {}

      if status['percent_complete']
        updates[:progress_percentage] = status['percent_complete']
      end

      if status['phase']
        updates[:config] = (@job.config || {}).merge('current_phase' => status['phase'])
      end

      @job.update(updates) unless updates.empty?
    end

    # Read and parse the status file
    #
    # @return [Hash, nil] The parsed status data, or nil if file doesn't exist or is invalid
    def read_status_file
      return nil unless File.exist?(@status_path)

      content = File.read(@status_path)
      return nil if content.nil? || content.empty?

      JSON.parse(content)
    rescue JSON::ParserError => e
      warn "[PythonRunnerService] Failed to parse status file: #{e.message}"
      nil
    end

    # Check if the Python process is still running
    #
    # @return [Boolean] true if process is alive
    def process_alive?
      return false unless @pid

      Process.kill(0, @pid)
      true
    rescue Errno::ESRCH, Errno::EPERM
      false
    end

    # Find the Python executable to use
    #
    # Prefers a venv in the python_worldgen directory, falls back to system python3.
    #
    # @return [String] Path to python executable
    def find_python
      venv_python = File.join(python_worldgen_path, 'venv', 'bin', 'python')
      return venv_python if File.exist?(venv_python)

      'python3'
    end

    # Get the path to the python_worldgen directory
    #
    # @return [String] Absolute path to python_worldgen
    def python_worldgen_path
      File.expand_path('../../../python_worldgen', __dir__)
    end

    # Clean up temporary files created during generation
    #
    # Removes config, status, and output files.
    #
    # @return [void]
    def cleanup_temp_files
      [@config_path, @status_path, @output_path].each do |path|
        File.delete(path) if File.exist?(path)
      rescue Errno::ENOENT
        # File already deleted, ignore
      end
    end
  end
end
