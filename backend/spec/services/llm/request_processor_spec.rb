# frozen_string_literal: true

require 'spec_helper'

RSpec.describe LLM::RequestProcessor do
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }

  describe '.enqueue_async' do
    let(:request) { create(:llm_request, prompt: 'Test prompt', request_type: 'text', status: 'pending') }

    it 'enqueues a Sidekiq job' do
      allow(LlmRequestJob).to receive(:perform_async)

      described_class.enqueue_async(request)

      expect(LlmRequestJob).to have_received(:perform_async).with(request.id)
    end
  end

  describe '.process' do
    context 'with text request' do
      let(:request) { create(:llm_request, prompt: 'Test prompt', request_type: 'text', status: 'pending', provider: 'openai', llm_model: 'gpt-5.4') }

      before do
        allow(request).to receive(:start_processing!)
        allow(request).to receive(:complete!)
        allow(request).to receive(:text?).and_return(true)
        allow(request).to receive(:image?).and_return(false)
        allow(request).to receive(:embedding?).and_return(false)
        allow(request).to receive(:callback_handler).and_return(nil)
        allow(request).to receive(:llm_conversation).and_return(nil)
      end

      it 'marks request as processing' do
        adapter = double('adapter')
        allow(LLM::TextGenerationService).to receive(:adapter_for).and_return(adapter)
        allow(AIProviderService).to receive(:api_key_for).and_return('test-key')
        allow(request).to receive(:parsed_options).and_return({})
        allow(adapter).to receive(:generate).and_return({ success: true, text: 'Response' })

        described_class.process(request)
        expect(request).to have_received(:start_processing!)
      end

      it 'calls adapter with correct parameters' do
        adapter = double('adapter')
        allow(LLM::TextGenerationService).to receive(:adapter_for).and_return(adapter)
        allow(AIProviderService).to receive(:api_key_for).and_return('test-key')
        allow(request).to receive(:parsed_options).and_return({})

        expect(adapter).to receive(:generate).with(
          messages: [{ role: 'user', content: 'Test prompt' }],
          model: 'gpt-5.4',
          api_key: 'test-key',
          options: {},
          json_mode: false
        ).and_return({ success: true, text: 'Response' })

        described_class.process(request)
      end

      it 'completes request on success' do
        adapter = double('adapter')
        allow(LLM::TextGenerationService).to receive(:adapter_for).and_return(adapter)
        allow(AIProviderService).to receive(:api_key_for).and_return('test-key')
        allow(request).to receive(:parsed_options).and_return({})
        allow(adapter).to receive(:generate).and_return({ success: true, text: 'Response' })

        described_class.process(request)
        expect(request).to have_received(:complete!)
      end
    end

    context 'with image request' do
      let(:request) { create(:llm_request, prompt: 'Generate an image', request_type: 'image', status: 'pending', provider: 'openai', llm_model: 'dall-e-3') }

      before do
        allow(request).to receive(:start_processing!)
        allow(request).to receive(:complete!)
        allow(request).to receive(:text?).and_return(false)
        allow(request).to receive(:image?).and_return(true)
        allow(request).to receive(:embedding?).and_return(false)
        allow(request).to receive(:callback_handler).and_return(nil)
      end

      it 'processes image request' do
        adapter = double('adapter')
        allow(LLM::TextGenerationService).to receive(:adapter_for).and_return(adapter)
        allow(AIProviderService).to receive(:api_key_for).and_return('test-key')
        allow(request).to receive(:parsed_options).and_return({})
        allow(adapter).to receive(:generate_image).and_return({ success: true, url: 'https://example.com/image.png' })
        allow(LLM::ImageDownloader).to receive(:download).and_return('https://storage.example.com/image.png')

        described_class.process(request)
        expect(request).to have_received(:complete!)
      end

      it 'downloads image when URL returned' do
        adapter = double('adapter')
        allow(LLM::TextGenerationService).to receive(:adapter_for).and_return(adapter)
        allow(AIProviderService).to receive(:api_key_for).and_return('test-key')
        allow(request).to receive(:parsed_options).and_return({})
        allow(adapter).to receive(:generate_image).and_return({ success: true, url: 'https://example.com/image.png' })

        expect(LLM::ImageDownloader).to receive(:download).with('https://example.com/image.png', request)

        described_class.process(request)
      end
    end

    context 'with embedding request' do
      let(:request) { create(:llm_request, prompt: 'Text to embed', request_type: 'embedding', status: 'pending', provider: 'openai', llm_model: 'text-embedding-3-small') }

      before do
        allow(request).to receive(:start_processing!)
        allow(request).to receive(:complete!)
        allow(request).to receive(:text?).and_return(false)
        allow(request).to receive(:image?).and_return(false)
        allow(request).to receive(:embedding?).and_return(true)
        allow(request).to receive(:callback_handler).and_return(nil)
      end

      it 'processes embedding request' do
        allow(request).to receive(:parsed_options).and_return({})
        allow(LLM::EmbeddingService).to receive(:generate).and_return({
          success: true,
          embedding: [0.1, 0.2, 0.3],
          dimensions: 3,
          model: 'text-embedding-3-small'
        })

        described_class.process(request)
        expect(request).to have_received(:complete!)
      end
    end

    context 'with unknown request type' do
      let(:request) do
        instance_double(
          LLMRequest,
          request_type: 'unknown',
          start_processing!: nil,
          text?: false,
          image?: false,
          embedding?: false,
          should_retry?: false,
          fail!: nil,
          callback_handler: nil
        )
      end

      it 'fails the request' do
        described_class.process(request)
        expect(request).to have_received(:fail!).with('Unknown request type: unknown')
      end
    end

    context 'with missing provider' do
      let(:request) { create(:llm_request, prompt: 'Test', request_type: 'text', status: 'pending', provider: 'unknown') }

      before do
        allow(request).to receive(:start_processing!)
        allow(request).to receive(:text?).and_return(true)
        allow(request).to receive(:should_retry?).and_return(false)
        allow(request).to receive(:fail!)
        allow(request).to receive(:callback_handler).and_return(nil)
        allow(LLM::TextGenerationService).to receive(:adapter_for).and_return(nil)
      end

      it 'fails with unknown provider error' do
        described_class.process(request)
        expect(request).to have_received(:fail!).with('Unknown provider: unknown')
      end
    end

    context 'with missing API key' do
      let(:request) { create(:llm_request, prompt: 'Test', request_type: 'text', status: 'pending', provider: 'openai') }

      before do
        allow(request).to receive(:start_processing!)
        allow(request).to receive(:text?).and_return(true)
        allow(request).to receive(:should_retry?).and_return(false)
        allow(request).to receive(:fail!)
        allow(request).to receive(:callback_handler).and_return(nil)
        allow(LLM::TextGenerationService).to receive(:adapter_for).and_return(double('adapter'))
        allow(AIProviderService).to receive(:api_key_for).and_return(nil)
      end

      it 'fails with no API key error' do
        described_class.process(request)
        expect(request).to have_received(:fail!).with('No API key for openai')
      end
    end
  end

  describe 'retry handling' do
    let(:request) { create(:llm_request, prompt: 'Test', request_type: 'text', status: 'pending', provider: 'openai') }

    before do
      allow(request).to receive(:start_processing!)
      allow(request).to receive(:text?).and_return(true)
      allow(request).to receive(:callback_handler).and_return(nil)
      allow(LLM::TextGenerationService).to receive(:adapter_for).and_return(nil)
    end

    it 'retries when should_retry? returns true by scheduling Sidekiq job' do
      allow(request).to receive(:should_retry?).and_return(true)
      allow(request).to receive(:retry_count).and_return(1)
      allow(request).to receive(:fail!)
      allow(LlmRequestJob).to receive(:perform_in)

      described_class.process(request)

      expect(LlmRequestJob).to have_received(:perform_in).with(1, request.id)
    end

    it 'fails after retries exhausted' do
      allow(request).to receive(:should_retry?).and_return(false)
      allow(request).to receive(:fail!)

      described_class.process(request)

      expect(request).to have_received(:fail!)
    end
  end

  describe 'callback handling' do
    let(:request) { create(:llm_request, prompt: 'Test', request_type: 'text', status: 'pending', provider: 'openai', callback_handler: 'TestCallbackHandler') }

    before do
      allow(request).to receive(:start_processing!)
      allow(request).to receive(:complete!)
      allow(request).to receive(:text?).and_return(true)
      allow(request).to receive(:image?).and_return(false)
      allow(request).to receive(:embedding?).and_return(false)
      allow(request).to receive(:llm_conversation).and_return(nil)
      allow(request).to receive(:parsed_options).and_return({})

      adapter = double('adapter')
      allow(LLM::TextGenerationService).to receive(:adapter_for).and_return(adapter)
      allow(AIProviderService).to receive(:api_key_for).and_return('test-key')
      allow(adapter).to receive(:generate).and_return({ success: true, text: 'Response' })
    end

    it 'invokes callback handler on success' do
      test_handler = double('TestCallbackHandler')
      stub_const('TestCallbackHandler', test_handler)
      expect(test_handler).to receive(:call).with(request, hash_including(success: true))

      described_class.process(request)
    end

    it 'handles missing callback handler gracefully' do
      allow(request).to receive(:callback_handler).and_return('NonexistentHandler')
      expect(described_class).to receive(:warn).with(/Callback handler not found/)

      # Should not raise
      expect { described_class.process(request) }.not_to raise_error
    end

    it 'handles callback handler errors gracefully' do
      test_handler = double('TestCallbackHandler')
      stub_const('TestCallbackHandler', test_handler)
      allow(test_handler).to receive(:call).and_raise(StandardError.new('Callback error'))
      expect(described_class).to receive(:warn).with(/Callback handler error: Callback error/)

      # Should not raise
      expect { described_class.process(request) }.not_to raise_error
    end
  end

  describe 'conversation handling' do
    let(:conversation) { create(:llm_conversation, system_prompt: 'You are helpful.') }
    let(:request) { create(:llm_request, prompt: 'Hello', request_type: 'text', status: 'pending', provider: 'openai', llm_model: 'gpt-5.4', llm_conversation: conversation) }

    before do
      allow(request).to receive(:start_processing!)
      allow(request).to receive(:complete!)
      allow(request).to receive(:text?).and_return(true)
      allow(request).to receive(:image?).and_return(false)
      allow(request).to receive(:embedding?).and_return(false)
      allow(request).to receive(:callback_handler).and_return(nil)
      allow(request).to receive(:parsed_options).and_return({})
    end

    it 'includes system prompt in messages' do
      adapter = double('adapter')
      allow(LLM::TextGenerationService).to receive(:adapter_for).and_return(adapter)
      allow(AIProviderService).to receive(:api_key_for).and_return('test-key')

      expect(adapter).to receive(:generate) do |args|
        messages = args[:messages]
        expect(messages.first[:role]).to eq('system')
        expect(messages.first[:content]).to eq('You are helpful.')
        { success: true, text: 'Hi!' }
      end

      described_class.process(request)
    end

    it 'adds assistant response to conversation' do
      adapter = double('adapter')
      allow(LLM::TextGenerationService).to receive(:adapter_for).and_return(adapter)
      allow(AIProviderService).to receive(:api_key_for).and_return('test-key')
      allow(adapter).to receive(:generate).and_return({ success: true, text: 'Hi!' })

      expect(conversation).to receive(:add_message).with(role: 'assistant', content: 'Hi!')

      described_class.process(request)
    end
  end
end
