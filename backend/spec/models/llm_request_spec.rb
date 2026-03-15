# frozen_string_literal: true

require 'spec_helper'

RSpec.describe LLMRequest do
  describe 'validations' do
    it 'requires request_id' do
      request = described_class.new(
        request_type: 'text',
        status: 'pending',
        prompt: 'Test prompt'
      )
      expect(request.valid?).to be false
      expect(request.errors[:request_id]).to include('is not present')
    end

    it 'requires request_type' do
      request = described_class.new(
        request_id: SecureRandom.uuid,
        status: 'pending',
        prompt: 'Test prompt'
      )
      expect(request.valid?).to be false
    end

    it 'allows empty prompt when messages are in options' do
      request = described_class.new(
        request_id: SecureRandom.uuid,
        request_type: 'text',
        status: 'pending',
        prompt: '',
        options: Sequel.pg_json_wrap({ messages: [{ role: 'user', content: 'test' }] })
      )
      expect(request.valid?).to be true
    end

    it 'validates status is in STATUSES list' do
      request = described_class.new(
        request_id: SecureRandom.uuid,
        request_type: 'text',
        status: 'invalid',
        prompt: 'Test'
      )
      expect(request.valid?).to be false
    end

    it 'validates request_type is in REQUEST_TYPES list' do
      request = described_class.new(
        request_id: SecureRandom.uuid,
        request_type: 'invalid',
        status: 'pending',
        prompt: 'Test'
      )
      expect(request.valid?).to be false
    end
  end

  describe '.create_text_request' do
    it 'creates a text request with generated request_id' do
      request = described_class.create_text_request(prompt: 'Hello')

      expect(request.id).not_to be_nil
      expect(request.request_id).not_to be_nil
      expect(request.request_type).to eq('text')
      expect(request.status).to eq('pending')
      expect(request.prompt).to eq('Hello')
    end

    it 'sets callback handler when provided' do
      request = described_class.create_text_request(
        prompt: 'Hello',
        callback: 'TestHandler'
      )
      expect(request.callback_handler).to eq('TestHandler')
    end

    it 'stores context as JSONB' do
      request = described_class.create_text_request(
        prompt: 'Hello',
        context: { room_id: 123 }
      )
      expect(request.parsed_context['room_id']).to eq(123)
    end
  end

  describe '.create_image_request' do
    it 'creates an image request with DALL-E defaults' do
      request = described_class.create_image_request(prompt: 'A cat')

      expect(request.id).not_to be_nil
      expect(request.request_type).to eq('image')
      expect(request.provider).to eq('openai')
      expect(request.llm_model).to eq('dall-e-3')
    end
  end

  describe '#start_processing!' do
    let(:request) { described_class.create_text_request(prompt: 'Hello') }

    it 'updates status to processing' do
      request.start_processing!
      expect(request.status).to eq('processing')
    end

    it 'sets started_at' do
      request.start_processing!
      expect(request.started_at).to be_within(1).of(Time.now)
    end
  end

  describe '#claim_for_processing!' do
    let(:request) { described_class.create_text_request(prompt: 'Hello') }

    it 'atomically claims a pending request' do
      expect(request.claim_for_processing!).to be true
      expect(request.refresh.status).to eq('processing')
      expect(request.started_at).not_to be_nil
    end

    it 'does not claim a request that is already processing and not stale' do
      request.update(status: 'processing', started_at: Time.now)
      expect(request.claim_for_processing!(stale_after: 300)).to be false
    end

    it 'reclaims a stale processing request' do
      request.update(status: 'processing', started_at: Time.now - 600)
      expect(request.claim_for_processing!(stale_after: 300)).to be true
      expect(request.refresh.status).to eq('processing')
    end
  end

  describe '#complete!' do
    let(:request) do
      req = described_class.create_text_request(prompt: 'Hello')
      req.start_processing!
      req
    end

    it 'updates status to completed' do
      request.complete!(text: 'Response')
      expect(request.status).to eq('completed')
    end

    it 'stores response_text' do
      request.complete!(text: 'Response')
      expect(request.response_text).to eq('Response')
    end

    it 'stores response_url for images' do
      request.complete!(url: '/uploads/image.png')
      expect(request.response_url).to eq('/uploads/image.png')
    end

    it 'calculates duration_ms' do
      request # force let evaluation so started_at is set before sleep
      sleep 0.05
      request.complete!(text: 'Response')
      expect(request.duration_ms).to be > 0
    end
  end

  describe '#fail!' do
    let(:request) { described_class.create_text_request(prompt: 'Hello') }

    it 'updates status to failed' do
      request.fail!('Some error')
      expect(request.status).to eq('failed')
    end

    it 'stores error_message' do
      request.fail!('Some error')
      expect(request.error_message).to eq('Some error')
    end

    it 'truncates long error messages' do
      request.fail!('x' * 2000)
      expect(request.error_message.length).to eq(1000)
    end
  end

  describe '#should_retry?' do
    let(:request) { described_class.create_text_request(prompt: 'Hello') }

    it 'returns true and increments retry_count when under limit' do
      expect(request.should_retry?).to be true
      expect(request.retry_count).to eq(1)
    end

    it 'resets status to pending' do
      request.update(status: 'failed')
      request.should_retry?
      expect(request.status).to eq('pending')
    end

    it 'returns false when at max_retries' do
      request.update(retry_count: 3)
      expect(request.should_retry?).to be false
    end
  end

  describe 'status helpers' do
    let(:request) { described_class.create_text_request(prompt: 'Hello') }

    it '#pending? returns true for pending status' do
      expect(request.pending?).to be true
    end

    it '#processing? returns true for processing status' do
      request.update(status: 'processing')
      expect(request.processing?).to be true
    end

    it '#completed? returns true for completed status' do
      request.update(status: 'completed')
      expect(request.completed?).to be true
    end

    it '#failed? returns true for failed status' do
      request.update(status: 'failed')
      expect(request.failed?).to be true
    end
  end

  describe 'type helpers' do
    it '#text? returns true for text requests' do
      request = described_class.create_text_request(prompt: 'Hello')
      expect(request.text?).to be true
      expect(request.image?).to be false
    end

    it '#image? returns true for image requests' do
      request = described_class.create_image_request(prompt: 'A cat')
      expect(request.image?).to be true
      expect(request.text?).to be false
    end
  end
end
