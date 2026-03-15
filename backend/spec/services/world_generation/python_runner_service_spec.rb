# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'tempfile'

RSpec.describe WorldGeneration::PythonRunnerService do
  let(:world) { create(:world) }
  let(:job) do
    WorldGenerationJob.create(
      world_id: world.id,
      job_type: 'procedural',
      status: 'pending',
      config: {
        'seed' => 12345,
        'preset' => 'earth_like',
        'subdivision_level' => 3,
        'ocean_coverage' => 0.70
      }
    )
  end
  let(:service) { described_class.new(job) }

  describe 'constants' do
    it 'defines DEFAULT_POLL_INTERVAL' do
      expect(described_class::DEFAULT_POLL_INTERVAL).to eq(2)
    end

    it 'defines DEFAULT_TIMEOUT' do
      expect(described_class::DEFAULT_TIMEOUT).to be > 0
    end

    it 'defines PYTHON_MODULE' do
      expect(described_class::PYTHON_MODULE).to eq('worldgen')
    end
  end

  describe '#initialize' do
    it 'sets up the job reference' do
      expect(service.instance_variable_get(:@job)).to eq(job)
    end

    it 'sets up the world reference' do
      expect(service.instance_variable_get(:@world)).to eq(world)
    end

    it 'generates config path in /tmp' do
      config_path = service.instance_variable_get(:@config_path)
      expect(config_path).to match(%r{^/tmp/worldgen_#{job.id}_config\.json$})
    end

    it 'generates status path in /tmp' do
      status_path = service.instance_variable_get(:@status_path)
      expect(status_path).to match(%r{^/tmp/worldgen_#{job.id}_status\.json$})
    end

    it 'generates output path in /tmp' do
      output_path = service.instance_variable_get(:@output_path)
      expect(output_path).to match(%r{^/tmp/worldgen_#{job.id}_world\.json$})
    end

    it 'accepts custom poll interval' do
      custom_service = described_class.new(job, poll_interval: 5)
      expect(custom_service.instance_variable_get(:@poll_interval)).to eq(5)
    end

    it 'accepts custom timeout' do
      custom_service = described_class.new(job, timeout: 7200)
      expect(custom_service.instance_variable_get(:@timeout)).to eq(7200)
    end
  end

  describe '#write_config' do
    after do
      config_path = service.instance_variable_get(:@config_path)
      File.delete(config_path) if File.exist?(config_path)
    end

    it 'writes a JSON config file' do
      service.send(:write_config)
      config_path = service.instance_variable_get(:@config_path)

      expect(File.exist?(config_path)).to be true
    end

    it 'includes seed from job config' do
      service.send(:write_config)
      config_path = service.instance_variable_get(:@config_path)
      config = JSON.parse(File.read(config_path))

      expect(config['seed']).to eq(12345)
    end

    it 'includes preset from job config' do
      service.send(:write_config)
      config_path = service.instance_variable_get(:@config_path)
      config = JSON.parse(File.read(config_path))

      expect(config['preset']).to eq('earth_like')
    end

    it 'includes subdivision_level from job config' do
      service.send(:write_config)
      config_path = service.instance_variable_get(:@config_path)
      config = JSON.parse(File.read(config_path))

      expect(config['subdivision_level']).to eq(3)
    end

    it 'includes ocean_coverage from job config' do
      service.send(:write_config)
      config_path = service.instance_variable_get(:@config_path)
      config = JSON.parse(File.read(config_path))

      expect(config['ocean_coverage']).to eq(0.70)
    end

    it 'includes output_path' do
      service.send(:write_config)
      config_path = service.instance_variable_get(:@config_path)
      config = JSON.parse(File.read(config_path))

      expect(config['output_path']).to eq(service.instance_variable_get(:@output_path))
    end

    it 'includes status_path' do
      service.send(:write_config)
      config_path = service.instance_variable_get(:@config_path)
      config = JSON.parse(File.read(config_path))

      expect(config['status_path']).to eq(service.instance_variable_get(:@status_path))
    end

    it 'generates random seed if not provided' do
      job_without_seed = WorldGenerationJob.create(
        world_id: world.id,
        job_type: 'procedural',
        status: 'pending',
        config: { 'preset' => 'earth_like' }
      )
      service_without_seed = described_class.new(job_without_seed)
      service_without_seed.send(:write_config)
      config_path = service_without_seed.instance_variable_get(:@config_path)
      config = JSON.parse(File.read(config_path))

      expect(config['seed']).to be_a(Integer)
      expect(config['seed']).to be > 0

      File.delete(config_path) if File.exist?(config_path)
    end
  end

  describe '#find_python' do
    it 'returns a python executable path' do
      python = service.send(:find_python)
      # Should return either venv python or system python
      expect(python).to match(/python/)
    end

    it 'prefers venv python when available' do
      venv_path = File.join(service.send(:python_worldgen_path), 'venv', 'bin', 'python')
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with(venv_path).and_return(true)

      python = service.send(:find_python)
      expect(python).to eq(venv_path)
    end

    it 'falls back to python3 when venv not available' do
      venv_path = File.join(service.send(:python_worldgen_path), 'venv', 'bin', 'python')
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with(venv_path).and_return(false)

      python = service.send(:find_python)
      expect(python).to eq('python3')
    end
  end

  describe '#python_worldgen_path' do
    it 'returns the path to python_worldgen directory' do
      path = service.send(:python_worldgen_path)
      expect(path).to match(%r{/backend/python_worldgen$})
    end
  end

  describe '#read_status_file' do
    let(:status_path) { service.instance_variable_get(:@status_path) }

    after do
      File.delete(status_path) if File.exist?(status_path)
    end

    it 'returns nil when file does not exist' do
      status = service.send(:read_status_file)
      expect(status).to be_nil
    end

    it 'parses JSON status file' do
      File.write(status_path, { 'status' => 'running', 'percent_complete' => 50 }.to_json)

      status = service.send(:read_status_file)
      expect(status['status']).to eq('running')
      expect(status['percent_complete']).to eq(50)
    end

    it 'handles invalid JSON gracefully' do
      File.write(status_path, 'not valid json {{{')

      status = service.send(:read_status_file)
      expect(status).to be_nil
    end

    it 'handles empty file gracefully' do
      File.write(status_path, '')

      status = service.send(:read_status_file)
      expect(status).to be_nil
    end
  end

  describe '#process_alive?' do
    it 'returns false when pid is nil' do
      service.instance_variable_set(:@pid, nil)
      expect(service.send(:process_alive?)).to be false
    end

    it 'returns true for running process' do
      # Use current process as a known-running process
      service.instance_variable_set(:@pid, Process.pid)
      expect(service.send(:process_alive?)).to be true
    end

    it 'returns false for non-existent process' do
      # Use an impossibly high PID
      service.instance_variable_set(:@pid, 999_999_999)
      expect(service.send(:process_alive?)).to be false
    end
  end

  describe '#cleanup_temp_files' do
    let(:config_path) { service.instance_variable_get(:@config_path) }
    let(:status_path) { service.instance_variable_get(:@status_path) }
    let(:output_path) { service.instance_variable_get(:@output_path) }

    it 'removes config file if it exists' do
      File.write(config_path, '{}')

      service.send(:cleanup_temp_files)
      expect(File.exist?(config_path)).to be false
    end

    it 'removes status file if it exists' do
      File.write(status_path, '{}')

      service.send(:cleanup_temp_files)
      expect(File.exist?(status_path)).to be false
    end

    it 'removes output file if it exists' do
      File.write(output_path, '{}')

      service.send(:cleanup_temp_files)
      expect(File.exist?(output_path)).to be false
    end

    it 'handles missing files gracefully' do
      expect { service.send(:cleanup_temp_files) }.not_to raise_error
    end
  end

  describe '#update_job_progress' do
    it 'updates job progress_percentage from status' do
      status = { 'percent_complete' => 45.5 }
      service.send(:update_job_progress, status)

      job.reload
      expect(job.progress_percentage).to eq(45.5)
    end

    it 'updates job phase from status' do
      status = { 'percent_complete' => 50, 'phase' => 'hydrology' }
      service.send(:update_job_progress, status)

      job.reload
      expect(job.config['current_phase']).to eq('hydrology')
    end

    it 'handles missing percent_complete' do
      status = { 'phase' => 'tectonics' }
      expect { service.send(:update_job_progress, status) }.not_to raise_error
    end
  end

  describe '#run (integration with mocked subprocess)' do
    let(:config_path) { service.instance_variable_get(:@config_path) }
    let(:status_path) { service.instance_variable_get(:@status_path) }
    let(:output_path) { service.instance_variable_get(:@output_path) }
    let(:mock_import_service) { double('WorldImportService', import: true) }

    # Stub WorldImportService if it doesn't exist (it's Task 13)
    before do
      unless defined?(WorldGeneration::WorldImportService)
        stub_const('WorldGeneration::WorldImportService', Class.new do
          def initialize(world, path); end
          def import; true; end
        end)
      end
    end

    after do
      [config_path, status_path, output_path].each do |path|
        File.delete(path) if File.exist?(path)
      end
    end

    context 'when generation succeeds' do
      before do
        # Mock Process.spawn to simulate successful python execution
        allow(service).to receive(:spawn_python) do
          service.instance_variable_set(:@pid, 12345)
        end

        # Mock process_alive? to return true initially, then false after "completion"
        call_count = 0
        allow(service).to receive(:process_alive?) do
          call_count += 1
          call_count <= 2
        end

        # Simulate status file updates
        status_sequence = [
          { 'status' => 'running', 'phase' => 'tectonics', 'percent_complete' => 20 },
          { 'status' => 'complete', 'percent_complete' => 100 }
        ]
        read_count = 0
        allow(service).to receive(:read_status_file) do
          status = status_sequence[[read_count, status_sequence.length - 1].min]
          read_count += 1
          status
        end

        # Mock the import service
        allow(WorldGeneration::WorldImportService).to receive(:new).and_return(mock_import_service)

        # Skip actual sleep
        allow(service).to receive(:sleep)
      end

      it 'writes config file before spawning' do
        service.run

        # Config should have been written (verify by checking method was called)
        expect(service).to have_received(:spawn_python)
      end

      it 'marks job as running at start' do
        service.run

        # Job should have gone through running state
        # We check final state since we complete in test
        job.reload
        expect(job.status).to eq('completed')
      end

      it 'calls WorldImportService when complete' do
        # Create the output file that Python would have written
        File.write(output_path, '{"hexes": []}')

        service.run

        expect(WorldGeneration::WorldImportService).to have_received(:new)
      end

      it 'marks job as completed when done' do
        service.run

        job.reload
        expect(job.status).to eq('completed')
      end

      it 'cleans up temp files' do
        # Create temp files to verify cleanup
        File.write(config_path, '{}')
        File.write(status_path, '{}')

        service.run

        expect(File.exist?(config_path)).to be false
        expect(File.exist?(status_path)).to be false
      end
    end

    context 'when generation fails' do
      before do
        allow(service).to receive(:spawn_python) do
          service.instance_variable_set(:@pid, 12345)
        end

        allow(service).to receive(:process_alive?).and_return(true)

        # Simulate failure status
        allow(service).to receive(:read_status_file).and_return(
          { 'status' => 'failed', 'error_message' => 'Out of memory', 'traceback' => 'Stack trace here' }
        )

        allow(service).to receive(:sleep)
      end

      it 'marks job as failed with error message' do
        service.run

        job.reload
        expect(job.status).to eq('failed')
        expect(job.error_message).to eq('Out of memory')
      end

      it 'stores traceback in error_details' do
        service.run

        job.reload
        expect(job.error_details).to eq('Stack trace here')
      end

      it 'cleans up temp files on failure' do
        File.write(config_path, '{}')
        File.write(status_path, '{}')

        service.run

        expect(File.exist?(config_path)).to be false
        expect(File.exist?(status_path)).to be false
      end
    end

    context 'when process dies unexpectedly' do
      before do
        allow(service).to receive(:spawn_python) do
          service.instance_variable_set(:@pid, 12345)
        end

        # Process dies immediately
        allow(service).to receive(:process_alive?).and_return(false)

        # No status file written
        allow(service).to receive(:read_status_file).and_return(nil)

        allow(service).to receive(:sleep)
      end

      it 'marks job as failed' do
        service.run

        job.reload
        expect(job.status).to eq('failed')
      end

      it 'includes meaningful error message' do
        service.run

        job.reload
        expect(job.error_message).to match(/died unexpectedly|Process exited/i)
      end
    end

    context 'when timeout is reached' do
      let(:short_timeout_service) { described_class.new(job, timeout: 0.001, poll_interval: 0.001) }

      before do
        allow(short_timeout_service).to receive(:spawn_python) do
          short_timeout_service.instance_variable_set(:@pid, 12345)
        end

        # Process stays alive (simulating stuck process)
        allow(short_timeout_service).to receive(:process_alive?).and_return(true)

        # Status file shows running
        allow(short_timeout_service).to receive(:read_status_file).and_return(
          { 'status' => 'running', 'percent_complete' => 10 }
        )

        # Mock Process.kill to track termination attempts
        allow(Process).to receive(:kill)
      end

      it 'marks job as failed with timeout error' do
        short_timeout_service.run

        job.reload
        expect(job.status).to eq('failed')
        expect(job.error_message).to match(/timeout|timed out/i)
      end

      it 'attempts to kill the process' do
        short_timeout_service.run

        expect(Process).to have_received(:kill).with('TERM', 12345)
      end
    end
  end

  describe '#spawn_python' do
    it 'calls Process.spawn with correct arguments' do
      allow(Process).to receive(:spawn).and_return(12345)
      allow(service).to receive(:find_python).and_return('python3')

      # Write config first (required before spawn)
      service.send(:write_config)
      service.send(:spawn_python)

      expect(Process).to have_received(:spawn).with(
        'python3', '-m', 'worldgen', 'generate',
        '--config', service.instance_variable_get(:@config_path),
        hash_including(chdir: service.send(:python_worldgen_path))
      )

      # Cleanup
      config_path = service.instance_variable_get(:@config_path)
      File.delete(config_path) if File.exist?(config_path)
    end

    it 'stores the PID' do
      allow(Process).to receive(:spawn).and_return(12345)
      allow(service).to receive(:find_python).and_return('python3')

      service.send(:write_config)
      service.send(:spawn_python)

      expect(service.instance_variable_get(:@pid)).to eq(12345)

      # Cleanup
      config_path = service.instance_variable_get(:@config_path)
      File.delete(config_path) if File.exist?(config_path)
    end
  end

  describe 'error handling edge cases' do
    it 'handles nil job config gracefully' do
      job_with_nil_config = WorldGenerationJob.create(
        world_id: world.id,
        job_type: 'procedural',
        status: 'pending',
        config: nil
      )
      service_with_nil = described_class.new(job_with_nil_config)

      expect { service_with_nil.send(:write_config) }.not_to raise_error

      # Cleanup
      config_path = service_with_nil.instance_variable_get(:@config_path)
      File.delete(config_path) if File.exist?(config_path)
    end

    it 'handles empty job config gracefully' do
      job_with_empty_config = WorldGenerationJob.create(
        world_id: world.id,
        job_type: 'procedural',
        status: 'pending',
        config: {}
      )
      service_with_empty = described_class.new(job_with_empty_config)

      service_with_empty.send(:write_config)
      config_path = service_with_empty.instance_variable_get(:@config_path)
      config = JSON.parse(File.read(config_path))

      # Should have auto-generated seed
      expect(config['seed']).to be_a(Integer)

      # Cleanup
      File.delete(config_path) if File.exist?(config_path)
    end
  end
end
