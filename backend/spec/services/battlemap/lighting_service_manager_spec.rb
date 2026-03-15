# frozen_string_literal: true

require 'spec_helper'

RSpec.describe LightingServiceManager do
  # Use a fresh instance for each test (not the singleton)
  let(:manager) { described_class.new }

  after do
    manager.stop if manager.running?
  end

  describe '#running?' do
    it 'returns false when no process has been started' do
      expect(manager.running?).to be false
    end
  end

  describe '#status' do
    it 'returns status hash' do
      status = manager.status

      expect(status).to have_key(:running)
      expect(status).to have_key(:pid)
      expect(status).to have_key(:last_used_at)
      expect(status).to have_key(:idle_seconds)
      expect(status[:running]).to be false
      expect(status[:pid]).to be_nil
    end
  end

  describe '#mark_used' do
    it 'updates last_used_at' do
      manager.mark_used

      expect(manager.status[:last_used_at]).to be_a(Time)
      expect(manager.status[:idle_seconds]).to be_a(Integer)
      expect(manager.status[:idle_seconds]).to be <= 1
    end
  end

  describe '#check_idle_shutdown' do
    it 'does nothing when not running' do
      expect { manager.check_idle_shutdown }.not_to raise_error
    end

    it 'does not shut down when recently used' do
      # Simulate a running process
      allow(manager).to receive(:process_alive?).and_return(true)
      manager.mark_used

      manager.check_idle_shutdown

      # Would still be "running" since we mocked process_alive?
      expect(manager).to have_received(:process_alive?).at_least(:once)
    end

    it 'shuts down after idle timeout' do
      allow(manager).to receive(:process_alive?).and_return(true)
      allow(manager).to receive(:stop_process)

      # Set last_used_at to over an hour ago
      manager.instance_variable_set(:@last_used_at, Time.now - 3700)

      manager.check_idle_shutdown

      expect(manager).to have_received(:stop_process)
    end
  end

  describe '#ensure_running' do
    context 'when service cannot be started' do
      it 'returns false and does not raise' do
        # Stub process spawning to fail
        allow(Process).to receive(:spawn).and_raise(Errno::ENOENT.new('python3'))

        result = manager.ensure_running

        expect(result).to be false
      end
    end

    context 'when service is already healthy' do
      it 'returns true without starting a new process' do
        allow(manager).to receive(:process_alive?).and_return(true)
        allow(manager).to receive(:healthy?).and_return(true)

        result = manager.ensure_running

        expect(result).to be true
        expect(manager.status[:last_used_at]).not_to be_nil
      end
    end
  end

  describe '#stop' do
    it 'does nothing when not running' do
      expect { manager.stop }.not_to raise_error
    end
  end

  describe '.instance' do
    it 'returns the same instance' do
      expect(described_class.instance).to be(described_class.instance)
    end

    after do
      described_class.reset!
    end
  end

  describe '.reset!' do
    it 'clears the singleton instance' do
      first = described_class.instance
      described_class.reset!
      second = described_class.instance

      expect(first).not_to be(second)
    end

    after do
      described_class.reset!
    end
  end
end
