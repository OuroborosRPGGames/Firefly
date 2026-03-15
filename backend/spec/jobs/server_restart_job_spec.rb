# frozen_string_literal: true

require_relative '../spec_helper'
require 'sidekiq/testing'

RSpec.describe ServerRestartJob do
  before do
    Sidekiq::Testing.fake!
    REDIS_POOL.with { |r| r.del('firefly:restart:pending') }
    allow(ServerRestartService).to receive(:execute)
  end

  describe '#perform' do
    it 'broadcasts countdown warnings at correct intervals' do
      state = { type: 'phased', restart_at: (Time.now + 60).iso8601 }
      REDIS_POOL.with { |r| r.setex('firefly:restart:pending', 120, state.to_json) }

      broadcasts = []
      allow(BroadcastService).to receive(:to_all) { |msg, **| broadcasts << msg }
      allow_any_instance_of(ServerRestartJob).to receive(:sleep)

      state_now = { type: 'phased', restart_at: (Time.now + 1).iso8601 }
      REDIS_POOL.with { |r| r.setex('firefly:restart:pending', 120, state_now.to_json) }

      ServerRestartJob.new.perform('phased', 1)

      expect(broadcasts.last).to match(/restarting now/i)
    end

    it 'exits silently when cancelled (Redis key deleted)' do
      expect(BroadcastService).not_to receive(:to_all)
      expect(ServerRestartService).not_to receive(:execute)

      ServerRestartJob.new.perform('phased', 10)
    end

    it 'triggers restart execution at the end' do
      state = { type: 'full', restart_at: (Time.now + 1).iso8601 }
      REDIS_POOL.with { |r| r.setex('firefly:restart:pending', 120, state.to_json) }
      allow(BroadcastService).to receive(:to_all)
      allow_any_instance_of(ServerRestartJob).to receive(:sleep)

      expect(ServerRestartService).to receive(:execute).with('full')

      ServerRestartJob.new.perform('full', 1)
    end
  end
end
