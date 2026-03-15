# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'LLM Batch Processing Integration', type: :integration do
  before do
    LLM::ProviderThrottle.reset!('anthropic')
    # Stub spawn_processor so no real API calls or Sidekiq jobs are enqueued
    allow(LLM::RequestProcessor).to receive(:enqueue_async)
  end

  after do
    LLM::ProviderThrottle.reset!('anthropic')
  end

  describe 'LLM::Client.batch_submit' do
    it 'creates a batch record with correct total_count' do
      requests = 3.times.map do |i|
        { prompt: "batch_integ_#{i}", provider: 'anthropic', model: 'test-model' }
      end

      batch = LLM::Client.batch_submit(requests)

      expect(batch).to be_a(LlmBatch)
      expect(batch.total_count).to eq(3)
      expect(batch.status).to eq('pending')
    end

    it 'creates LLMRequest records linked to the batch' do
      requests = 3.times.map do |i|
        { prompt: "batch_integ_linked_#{i}", provider: 'anthropic', model: 'test-model' }
      end

      batch = LLM::Client.batch_submit(requests)

      linked_requests = LLMRequest.where(llm_batch_id: batch.id).all
      expect(linked_requests.size).to eq(3)
      expect(linked_requests.map(&:status).uniq).to eq(['pending'])
    end

    it 'initializes Redis completed counter to 0' do
      requests = [{ prompt: 'batch_integ_redis', provider: 'anthropic', model: 'test-model' }]

      batch = LLM::Client.batch_submit(requests)

      count = REDIS_POOL.with { |redis| redis.get("llm:batch:#{batch.id}:completed").to_i }
      expect(count).to eq(0)
    end

    it 'passes callback_handler and callback_context to batch' do
      requests = [{ prompt: 'batch_integ_callback', provider: 'anthropic', model: 'test-model' }]

      batch = LLM::Client.batch_submit(
        requests,
        callback_handler: 'TestHandler',
        callback_context: { foo: 'bar' }
      )

      expect(batch.callback_handler).to eq('TestHandler')
    end

    it 'spawns a processor for each request' do
      requests = 2.times.map do |i|
        { prompt: "batch_integ_spawn_#{i}", provider: 'anthropic', model: 'test-model' }
      end

      LLM::Client.batch_submit(requests)

      expect(LLM::RequestProcessor).to have_received(:enqueue_async).exactly(2).times
    end
  end

  describe 'batch completion flow' do
    it 'completes batch after all requests record completion' do
      batch = LlmBatch.create(total_count: 2, status: 'pending')
      REDIS_POOL.with { |redis| redis.set("llm:batch:#{batch.id}:completed", 0) }

      batch.record_completion!
      expect(batch.refresh.status).to eq('pending')

      batch.record_completion!
      expect(batch.refresh.status).to eq('completed')
    end
  end
end
