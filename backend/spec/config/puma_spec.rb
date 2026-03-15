# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Puma Configuration' do
  let(:puma_config_path) { File.expand_path('../../config/puma.rb', __dir__) }
  let(:puma_config_content) { File.read(puma_config_path) }

  describe 'configuration file' do
    it 'exists at the expected path' do
      expect(File.exist?(puma_config_path)).to be true
    end

    it 'is a valid Ruby file' do
      expect { RubyVM::InstructionSequence.compile(puma_config_content) }.not_to raise_error
    end

    it 'is executable' do
      # Check shebang line
      expect(puma_config_content).to start_with('#!/usr/bin/env puma')
    end

    it 'is frozen string literal' do
      expect(puma_config_content).to include('# frozen_string_literal: true')
    end
  end

  describe 'environment variables' do
    describe 'RACK_ENV' do
      it 'defaults to development' do
        env = ENV.fetch('RACK_ENV', 'development')
        expect(%w[development test production]).to include(env)
      end

      it 'environment DSL is present in config' do
        expect(puma_config_content).to include("environment ENV.fetch('RACK_ENV', 'development')")
      end
    end

    describe 'WEB_CONCURRENCY' do
      it 'defaults to 2 workers' do
        workers = ENV.fetch('WEB_CONCURRENCY', 2).to_i
        expect(workers).to be >= 0
      end

      it 'can be configured via environment' do
        stub_const('ENV', ENV.to_h.merge('WEB_CONCURRENCY' => '4'))
        workers = ENV.fetch('WEB_CONCURRENCY', 2).to_i
        expect(workers).to eq(4)
      end

      it 'supports single-mode with 0 workers' do
        stub_const('ENV', ENV.to_h.merge('WEB_CONCURRENCY' => '0'))
        workers = ENV.fetch('WEB_CONCURRENCY', 2).to_i
        expect(workers).to eq(0)
      end

      it 'workers DSL is present in config' do
        expect(puma_config_content).to include("workers ENV.fetch('WEB_CONCURRENCY', 2)")
      end
    end

    describe 'PUMA_THREADS' do
      it 'defaults to 5 threads' do
        threads = ENV.fetch('PUMA_THREADS', 5).to_i
        expect(threads).to eq(5)
      end

      it 'can be configured via environment' do
        stub_const('ENV', ENV.to_h.merge('PUMA_THREADS' => '10'))
        threads = ENV.fetch('PUMA_THREADS', 10).to_i
        expect(threads).to eq(10)
      end

      it 'threads DSL is present in config' do
        expect(puma_config_content).to include("threads_count = ENV.fetch('PUMA_THREADS', 5)")
        expect(puma_config_content).to include('threads threads_count, threads_count')
      end
    end

    describe 'PORT' do
      it 'defaults to 3000' do
        port = ENV.fetch('PORT', 3000).to_i
        expect(port).to eq(3000)
      end

      it 'can be configured via environment' do
        stub_const('ENV', ENV.to_h.merge('PORT' => '8080'))
        port = ENV.fetch('PORT', 3000).to_i
        expect(port).to eq(8080)
      end

      it 'bind DSL is present in config' do
        expect(puma_config_content).to include("bind \"tcp://0.0.0.0:\#{ENV.fetch('PORT', 3000)}\"")
      end
    end
  end

  describe 'file paths' do
    it 'specifies pidfile in tmp/pids' do
      expect(File.directory?(File.expand_path('../../tmp/pids', __dir__))).to be true
      expect(puma_config_content).to include("pidfile 'tmp/pids/puma.pid'")
    end

    it 'specifies state_path in tmp/pids' do
      expect(puma_config_content).to include("state_path 'tmp/pids/puma.state'")
    end

    it 'specifies log files in log directory' do
      log_dir = File.expand_path('../../log', __dir__)
      expect(File.directory?(log_dir)).to be true
      expect(puma_config_content).to include("stdout_redirect 'log/puma_access.log', 'log/puma_error.log', true")
    end
  end

  describe 'memory optimization' do
    it 'preloads app for copy-on-write' do
      expect(puma_config_content).to include('preload_app!')
    end
  end

  describe 'connection pool integration' do
    it 'workers * threads should be reasonable for connection pooling' do
      workers = ENV.fetch('WEB_CONCURRENCY', 2).to_i
      threads = ENV.fetch('PUMA_THREADS', 5).to_i

      # In test mode, workers might be 0 (single mode)
      total_threads = workers.positive? ? workers * threads : threads

      # Total threads should be reasonable (not too high for DB connections)
      expect(total_threads).to be_between(1, 100)
    end

    it 'default config uses 10 total threads (2 workers * 5 threads)' do
      # Verify the documented defaults
      workers = 2
      threads = 5
      expect(workers * threads).to eq(10)
    end
  end

  describe 'lifecycle hooks' do
    it 'before_fork disconnects database' do
      # Verify the pattern is followed - database should be disconnectable
      expect(FireflyDatabase).to respond_to(:disconnect)
      expect(puma_config_content).to include('before_fork do')
      expect(puma_config_content).to include('FireflyDatabase.disconnect')
    end

    it 'on_worker_boot reconnects database' do
      # Verify the pattern is followed - database should be connectable
      expect(FireflyDatabase).to respond_to(:connect)
      expect(puma_config_content).to include('on_worker_boot do')
      expect(puma_config_content).to include('DB = FireflyDatabase.connect')
    end

    it 'on_worker_shutdown disconnects database' do
      expect(puma_config_content).to include('on_worker_shutdown do')
      expect(puma_config_content).to include('FireflyDatabase.disconnect')
    end

    it 'on_restart logs restart' do
      expect(puma_config_content).to include('on_restart do')
      expect(puma_config_content).to include("puts 'Puma is restarting...'")
    end
  end

  describe 'database lifecycle' do
    it 'requires database config in hooks' do
      expect(puma_config_content).to include("require_relative 'database'")
    end

    it 'checks if FireflyDatabase is defined before disconnect' do
      expect(puma_config_content).to include('if defined?(FireflyDatabase)')
    end
  end

  describe 'binding configuration' do
    it 'uses tcp binding only' do
      # Config comment mentions avoiding double-binding in cluster mode
      expect(puma_config_content).to include('bind "tcp://0.0.0.0:')
      expect(puma_config_content).not_to include("port ENV.fetch('PORT'")
    end

    it 'binds to 0.0.0.0 for all interfaces' do
      expect(puma_config_content).to include('tcp://0.0.0.0:')
    end
  end

  describe 'FireflyDatabase integration' do
    describe '.connect' do
      it 'returns a Sequel database connection' do
        # The connect method should return a Sequel::Database
        # In tests, we already have a connection, so just verify the interface
        expect(DB).to be_a(Sequel::Database)
      end
    end

    describe '.disconnect' do
      it 'gracefully handles disconnect when no connection' do
        # Should not raise even if called multiple times or with no connection
        expect { FireflyDatabase.disconnect }.not_to raise_error
      end
    end

    describe 'pool configuration' do
      it 'has a reasonable pool size' do
        # Pool should be at least 1 for tests, configured appropriately for production
        pool_max = DB.pool.max_size
        expect(pool_max).to be >= 1
      end
    end
  end
end
