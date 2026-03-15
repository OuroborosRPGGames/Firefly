# frozen_string_literal: true

require_relative '../spec_helper'

# Stub ServerRestartJob if it doesn't exist yet (implemented in Task 2)
ServerRestartJob = Class.new unless defined?(ServerRestartJob)

RSpec.describe ServerRestartService do
  before do
    REDIS_POOL.with { |r| r.del('firefly:restart:pending') }
  end

  describe '.schedule' do
    it 'stores restart state in Redis with TTL' do
      ServerRestartService.schedule(type: 'phased', delay: 60)

      REDIS_POOL.with do |redis|
        raw = redis.get('firefly:restart:pending')
        expect(raw).not_to be_nil
        data = JSON.parse(raw)
        expect(data['type']).to eq('phased')
        expect(data['restart_at']).to be_a(String)
        ttl = redis.ttl('firefly:restart:pending')
        expect(ttl).to be_between(60, 120)
      end
    end

    it 'enqueues ServerRestartJob for non-zero delay' do
      expect(ServerRestartJob).to receive(:perform_async).with('phased', 60)
      ServerRestartService.schedule(type: 'phased', delay: 60)
    end

    it 'does not enqueue job for zero delay' do
      allow(ServerRestartService).to receive(:execute)
      allow(BroadcastService).to receive(:to_all)
      expect(ServerRestartJob).not_to receive(:perform_async)
      ServerRestartService.schedule(type: 'phased', delay: 0)
    end

    it 'returns error if restart already pending' do
      ServerRestartService.schedule(type: 'phased', delay: 60)
      result = ServerRestartService.schedule(type: 'full', delay: 30)
      expect(result[:error]).to match(/already pending/i)
    end
  end

  describe '.cancel' do
    it 'deletes the Redis key' do
      ServerRestartService.schedule(type: 'phased', delay: 60)
      ServerRestartService.cancel
      REDIS_POOL.with do |redis|
        expect(redis.get('firefly:restart:pending')).to be_nil
      end
    end

    it 'returns error if no restart pending' do
      result = ServerRestartService.cancel
      expect(result[:error]).to match(/no restart pending/i)
    end
  end

  describe '.status' do
    it 'returns pending false when no restart scheduled' do
      result = ServerRestartService.status
      expect(result[:pending]).to be false
    end

    it 'returns pending true with details when restart scheduled' do
      ServerRestartService.schedule(type: 'full', delay: 120)
      result = ServerRestartService.status
      expect(result[:pending]).to be true
      expect(result[:type]).to eq('full')
      expect(result[:remaining_seconds]).to be_between(100, 120)
    end
  end

  describe '.execute' do
    it 'spawns a detached process for phased restart' do
      expect(ServerRestartService).to receive(:spawn).and_return(123)
      expect(Process).to receive(:detach).with(123)
      ServerRestartService.execute('phased')
    end

    it 'spawns a detached process for full restart' do
      expect(ServerRestartService).to receive(:spawn).and_return(456)
      expect(Process).to receive(:detach).with(456)
      ServerRestartService.execute('full')
    end
  end
end
