# frozen_string_literal: true

require 'spec_helper'
require 'sidekiq/testing'

RSpec.describe LlmRequestJob do
  before do
    Sidekiq::Testing.fake!
    LLM::ProviderThrottle.reset!('anthropic')
  end

  after do
    Sidekiq::Worker.clear_all
    LLM::ProviderThrottle.reset!('anthropic')
  end

  describe '#perform' do
    let(:request) do
      create(:llm_request,
        prompt: 'Test prompt',
        request_type: 'text',
        status: 'pending',
        provider: 'anthropic',
        llm_model: 'test-model')
    end

    it 'processes the request via RequestProcessor' do
      allow(LLM::ProviderThrottle).to receive(:try_acquire_slot).and_return(true)
      allow(LLM::ProviderThrottle).to receive(:release_slot)
      allow(LLM::ProviderThrottle).to receive(:record_success)
      allow(LLM::RequestProcessor).to receive(:process)

      described_class.new.perform(request.id)

      expect(LLM::RequestProcessor).to have_received(:process).with(request, claimed: true)
    end

    it 'acquires and releases provider throttle slot' do
      allow(LLM::ProviderThrottle).to receive(:try_acquire_slot).and_return(true)
      allow(LLM::ProviderThrottle).to receive(:release_slot)
      allow(LLM::ProviderThrottle).to receive(:record_success)
      allow(LLM::RequestProcessor).to receive(:process)

      described_class.new.perform(request.id)

      expect(LLM::ProviderThrottle).to have_received(:try_acquire_slot).with('anthropic')
      expect(LLM::ProviderThrottle).to have_received(:release_slot).with('anthropic')
    end

    it 'skips completed requests' do
      request.update(status: 'completed')
      allow(LLM::RequestProcessor).to receive(:process)

      described_class.new.perform(request.id)

      expect(LLM::RequestProcessor).not_to have_received(:process)
    end

    it 'skips missing requests' do
      allow(LLM::RequestProcessor).to receive(:process)

      described_class.new.perform(999999)

      expect(LLM::RequestProcessor).not_to have_received(:process)
    end

    it 'retries when slot acquisition times out' do
      allow(LLM::ProviderThrottle).to receive(:try_acquire_slot).and_return(false)

      described_class.new.perform(request.id)

      # Should have scheduled a retry
      expect(described_class.jobs.size).to eq(1)
    end

    it 'fails request after slot retries are exhausted' do
      request.update(retry_count: request.max_retries)
      allow(LLM::ProviderThrottle).to receive(:try_acquire_slot).and_return(false)

      described_class.new.perform(request.id)

      expect(request.refresh.status).to eq('failed')
      expect(request.error_message).to include('Provider busy')
    end

    it 're-raises unexpected processing errors so Sidekiq retries can run' do
      allow(LLM::ProviderThrottle).to receive(:try_acquire_slot).and_return(true)
      allow(LLM::ProviderThrottle).to receive(:release_slot)
      allow(LLM::RequestProcessor).to receive(:process).and_raise(StandardError, 'boom')

      expect { described_class.new.perform(request.id) }.to raise_error(StandardError, 'boom')
      expect(request.refresh.status).to eq('pending')
    end

    it 'skips duplicate jobs when request was already claimed' do
      allow(LLM::ProviderThrottle).to receive(:try_acquire_slot).and_return(true)
      allow(LLM::ProviderThrottle).to receive(:release_slot)
      allow_any_instance_of(LLMRequest).to receive(:claim_for_processing!).and_return(false)
      allow(LLM::RequestProcessor).to receive(:process)

      described_class.new.perform(request.id)

      expect(LLM::RequestProcessor).not_to have_received(:process)
    end

    it 'records rate limit on 429 error' do
      allow(LLM::ProviderThrottle).to receive(:try_acquire_slot).and_return(true)
      allow(LLM::ProviderThrottle).to receive(:release_slot)
      allow(LLM::ProviderThrottle).to receive(:record_rate_limit)
      allow(LLM::RequestProcessor).to receive(:process) do
        request.update(status: 'failed', error_message: '429 Rate limited: too many requests')
      end

      described_class.new.perform(request.id)

      expect(LLM::ProviderThrottle).to have_received(:record_rate_limit).with('anthropic')
    end

    context 'with batch' do
      it 'records batch completion' do
        batch = LlmBatch.create(total_count: 1, status: 'pending')
        REDIS_POOL.with { |redis| redis.set("llm:batch:#{batch.id}:completed", 0) }
        request.update(llm_batch_id: batch.id)

        allow(LLM::ProviderThrottle).to receive(:try_acquire_slot).and_return(true)
        allow(LLM::ProviderThrottle).to receive(:release_slot)
        allow(LLM::ProviderThrottle).to receive(:record_success)
        allow(LLM::RequestProcessor).to receive(:process) do
          request.update(status: 'completed')
        end

        described_class.new.perform(request.id)

        expect(batch.refresh.status).to eq('completed')
      end
    end
  end

  describe 'enqueuing' do
    it 'enqueues to the llm queue' do
      described_class.perform_async(123)
      expect(described_class.jobs.first['queue']).to eq('llm')
    end
  end
end
