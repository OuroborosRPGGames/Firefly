# frozen_string_literal: true

require 'spec_helper'

RSpec.describe LlmBatch do
  let(:batch) { described_class.create(total_count: 3, status: 'pending') }

  before do
    REDIS_POOL.with { |redis| redis.set("llm:batch:#{batch.id}:completed", 0) }
  end

  after do
    # Clean up Redis keys
    REDIS_POOL.with do |redis|
      redis.del("llm:batch:#{batch.id}:completed")
      redis.del("llm:batch:#{batch.id}:total")
    end
  end

  describe 'validations' do
    it 'requires a valid status' do
      invalid = described_class.new(total_count: 1, status: 'invalid')
      expect(invalid.valid?).to be false
    end

    it 'allows pending, completed, and failed statuses' do
      %w[pending completed failed].each do |status|
        record = described_class.new(total_count: 1, status: status)
        expect(record.valid?).to be true
      end
    end
  end

  describe '#record_completion!' do
    it 'increments completed count in Redis' do
      batch.record_completion!

      count = REDIS_POOL.with { |redis| redis.get("llm:batch:#{batch.id}:completed").to_i }
      expect(count).to eq(1)
    end

    it 'returns false when batch is not yet complete' do
      expect(batch.record_completion!).to be false
    end

    it 'completes batch when all requests done' do
      small_batch = described_class.create(total_count: 2, status: 'pending')
      REDIS_POOL.with { |redis| redis.set("llm:batch:#{small_batch.id}:completed", 0) }

      expect(small_batch.record_completion!).to be false
      expect(small_batch.refresh.status).to eq('pending')

      expect(small_batch.record_completion!).to be true
      expect(small_batch.refresh.status).to eq('completed')
      expect(small_batch.completed_at).not_to be_nil
    end
  end

  describe '#complete!' do
    it 'marks batch as completed with timestamp' do
      batch.complete!

      batch.refresh
      expect(batch.status).to eq('completed')
      expect(batch.completed_at).not_to be_nil
    end

    it 'cleans up Redis keys' do
      REDIS_POOL.with { |redis| redis.set("llm:batch:#{batch.id}:completed", 3) }

      batch.complete!

      count = REDIS_POOL.with { |redis| redis.get("llm:batch:#{batch.id}:completed") }
      expect(count).to be_nil
    end
  end

  describe '#results' do
    it 'returns associated LLMRequests' do
      request = LLMRequest.create(
        request_id: SecureRandom.uuid,
        request_type: 'text',
        status: 'completed',
        prompt: 'batch_test_results',
        provider: 'anthropic',
        model: 'test',
        llm_batch_id: batch.id
      )

      expect(batch.results.map(&:id)).to include(request.id)
    end

    it 'returns empty array when no requests' do
      expect(batch.results).to eq([])
    end
  end

  describe '#successful_results' do
    it 'returns only completed requests' do
      completed = LLMRequest.create(
        request_id: SecureRandom.uuid,
        request_type: 'text',
        status: 'completed',
        prompt: 'batch_test_success',
        provider: 'anthropic',
        model: 'test',
        llm_batch_id: batch.id
      )
      LLMRequest.create(
        request_id: SecureRandom.uuid,
        request_type: 'text',
        status: 'failed',
        prompt: 'batch_test_fail',
        provider: 'anthropic',
        model: 'test',
        llm_batch_id: batch.id
      )

      results = batch.successful_results
      expect(results.map(&:id)).to include(completed.id)
      expect(results.size).to eq(1)
    end
  end

  describe '#failed_results' do
    it 'returns only failed requests' do
      LLMRequest.create(
        request_id: SecureRandom.uuid,
        request_type: 'text',
        status: 'completed',
        prompt: 'batch_test_ok',
        provider: 'anthropic',
        model: 'test',
        llm_batch_id: batch.id
      )
      failed = LLMRequest.create(
        request_id: SecureRandom.uuid,
        request_type: 'text',
        status: 'failed',
        prompt: 'batch_test_failed',
        provider: 'anthropic',
        model: 'test',
        llm_batch_id: batch.id
      )

      results = batch.failed_results
      expect(results.map(&:id)).to include(failed.id)
      expect(results.size).to eq(1)
    end
  end

  describe '#wait!' do
    it 'returns true if already completed' do
      completed_batch = described_class.create(total_count: 0, status: 'completed')
      expect(completed_batch.wait!(timeout: 1)).to be true
    end

    it 'returns true if Redis shows all completed' do
      REDIS_POOL.with { |redis| redis.set("llm:batch:#{batch.id}:completed", 3) }
      batch.complete!
      expect(batch.wait!(timeout: 1)).to be true
    end
  end
end
