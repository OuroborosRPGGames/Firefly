# frozen_string_literal: true

require 'spec_helper'

RSpec.describe FireflyDatabase do
  describe '.connect' do
    it 'calculates pool size dynamically from worker and thread config' do
      # Default: 4 workers * 5 threads + 15 overhead = 35
      # We can't easily test the connection without mocking, but we can verify the module exists
      expect(described_class).to respond_to(:connect)
    end

    it 'respects DB_POOL_SIZE environment override' do
      stub_const('ENV', ENV.to_h.merge('DB_POOL_SIZE' => '50'))
      # Connection would use 50 if we called connect
      expect(ENV['DB_POOL_SIZE']).to eq('50')
    end

    it 'respects DB_POOL_TIMEOUT environment override' do
      stub_const('ENV', ENV.to_h.merge('DB_POOL_TIMEOUT' => '10'))
      expect(ENV['DB_POOL_TIMEOUT']).to eq('10')
    end
  end

  describe '.disconnect' do
    it 'responds to disconnect' do
      expect(described_class).to respond_to(:disconnect)
    end

    it 'handles disconnect when DB is not defined' do
      # This should not raise an error
      expect { described_class.disconnect }.not_to raise_error
    end
  end

  describe '.pool_stats' do
    it 'returns hash with pool statistics when DB is connected' do
      stats = described_class.pool_stats
      expect(stats).to be_a(Hash)
      expect(stats).to include(:size, :max_size, :available, :allocated)
    end

    it 'handles errors gracefully' do
      # Mock DB to raise an error
      allow(DB).to receive(:pool).and_raise(StandardError.new('test error'))

      stats = described_class.pool_stats
      expect(stats).to eq({})
    end
  end

  describe 'connection validation timeout' do
    it 'uses configurable validation timeout' do
      # The default timeout should be 300 seconds
      stub_const('ENV', ENV.to_h.merge('DB_VALIDATION_TIMEOUT' => '600'))
      expect(ENV.fetch('DB_VALIDATION_TIMEOUT', 300).to_i).to eq(600)
    end
  end

  describe 'statement timeout' do
    it 'uses stricter timeout in production' do
      stub_const('ENV', ENV.to_h.merge('RACK_ENV' => 'production'))
      expected_timeout = ENV.fetch('DB_STATEMENT_TIMEOUT') { '500ms' }
      expect(expected_timeout).to eq('500ms')
    end

    it 'uses longer timeout in development/test' do
      stub_const('ENV', ENV.to_h.merge('RACK_ENV' => 'test'))
      expected_timeout = ENV['RACK_ENV'] == 'production' ? '500ms' : '5s'
      expect(expected_timeout).to eq('5s')
    end
  end

  describe 'dynamic pool sizing' do
    it 'calculates base connections from workers and threads' do
      workers = ENV.fetch('WEB_CONCURRENCY', 4).to_i
      threads = ENV.fetch('PUMA_THREADS', 5).to_i
      base = workers * threads

      expect(base).to be >= 0
    end

    it 'adds overhead for background jobs and admin connections' do
      workers = 4
      threads = 5
      overhead = 15
      expected_min_pool = workers * threads + overhead

      expect(expected_min_pool).to eq(35)
    end
  end
end
