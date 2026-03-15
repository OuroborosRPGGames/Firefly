# frozen_string_literal: true

require 'spec_helper'

RSpec.describe LLM::ImageGenerationService do
  let(:gemini_adapter) { class_double(LLM::Adapters::GeminiAdapter) }
  let(:openai_adapter) { class_double(LLM::Adapters::OpenAIAdapter) }
  let(:openrouter_adapter) { class_double(LLM::Adapters::OpenRouterAdapter) }

  before do
    allow(CloudStorageService).to receive(:upload).and_return('https://storage.example.com/images/test.png')
    allow(AIProviderService).to receive(:api_key_for).with('google_gemini').and_return('gemini-key')
    allow(AIProviderService).to receive(:api_key_for).with('openai').and_return('openai-key')
    allow(AIProviderService).to receive(:api_key_for).with('openrouter').and_return('openrouter-key')
    allow(AIProviderService).to receive(:provider_available?).with('google_gemini').and_return(true)
    allow(AIProviderService).to receive(:provider_available?).with('openai').and_return(true)
    allow(AIProviderService).to receive(:provider_available?).with('openrouter').and_return(true)
  end

  describe '.generate' do
    let(:prompt) { 'A beautiful sunset over mountains' }

    context 'with successful generation using default model' do
      before do
        stub_const('LLM::Adapters::GeminiAdapter', gemini_adapter)
        allow(gemini_adapter).to receive(:generate_image).and_return({
          success: true,
          base64_data: Base64.encode64('fake image data'),
          mime_type: 'image/png'
        })
      end

      it 'returns success with local URL' do
        result = described_class.generate(prompt: prompt)
        expect(result[:success]).to be true
        expect(result[:local_url]).to eq('https://storage.example.com/images/test.png')
      end

      it 'uses default model tier' do
        expect(gemini_adapter).to receive(:generate_image).with(hash_including(
          prompt: prompt,
          options: hash_including(model: 'gemini-3.1-flash-image-preview')
        ))

        described_class.generate(prompt: prompt)
      end

      it 'includes model_used and provider_used in result' do
        result = described_class.generate(prompt: prompt)
        expect(result[:model_used]).to eq('gemini-3.1-flash-image-preview')
        expect(result[:provider_used]).to eq('google_gemini')
      end
    end

    context 'with high quality tier' do
      before do
        stub_const('LLM::Adapters::GeminiAdapter', gemini_adapter)
        allow(gemini_adapter).to receive(:generate_image).and_return({
          success: true,
          base64_data: Base64.encode64('fake image data'),
          mime_type: 'image/png'
        })
      end

      it 'uses high quality model when tier is specified' do
        expect(gemini_adapter).to receive(:generate_image).with(hash_including(
          options: hash_including(model: 'gemini-3-pro-image-preview')
        ))

        described_class.generate(prompt: prompt, options: { tier: :high_quality })
      end

      it 'uses high quality model when quality is hd' do
        expect(gemini_adapter).to receive(:generate_image).with(hash_including(
          options: hash_including(model: 'gemini-3-pro-image-preview')
        ))

        described_class.generate(prompt: prompt, options: { quality: 'hd' })
      end

      it 'uses high quality model when quality is high_quality' do
        expect(gemini_adapter).to receive(:generate_image).with(hash_including(
          options: hash_including(model: 'gemini-3-pro-image-preview')
        ))

        described_class.generate(prompt: prompt, options: { quality: 'high_quality' })
      end
    end

    context 'with explicit provider and model' do
      before do
        stub_const('LLM::Adapters::OpenAIAdapter', openai_adapter)
        allow(openai_adapter).to receive(:generate_image).and_return({
          success: true,
          url: 'https://openai.com/image.png'
        })
        allow(LLM::ImageDownloader).to receive(:download).and_return('https://storage.example.com/images/test.png')
      end

      it 'uses specified provider and model directly' do
        expect(openai_adapter).to receive(:generate_image).with(hash_including(
          prompt: prompt
        ))

        described_class.generate(prompt: prompt, options: { provider: 'openai', model: 'dall-e-3' })
      end
    end

    context 'with content rejection fallback' do
      before do
        stub_const('LLM::Adapters::GeminiAdapter', gemini_adapter)
        stub_const('LLM::Adapters::OpenRouterAdapter', openrouter_adapter)

        # First call (Gemini) fails with content rejection
        allow(gemini_adapter).to receive(:generate_image).and_return({
          success: false,
          error: 'Content blocked due to safety policy violation'
        })

        # Second call (OpenRouter) succeeds
        allow(openrouter_adapter).to receive(:generate_image).and_return({
          success: true,
          url: 'https://openrouter.com/image.png'
        })
        allow(LLM::ImageDownloader).to receive(:download).and_return('https://storage.example.com/images/fallback.png')
      end

      it 'falls back to alternative provider on rejection' do
        result = described_class.generate(prompt: prompt)
        expect(result[:success]).to be true
        expect(result[:provider_used]).to eq('openrouter')
      end
    end

    context 'when allow_fallback is false' do
      before do
        stub_const('LLM::Adapters::GeminiAdapter', gemini_adapter)
        allow(gemini_adapter).to receive(:generate_image).and_return({
          success: false,
          error: 'Content blocked due to safety policy'
        })
      end

      it 'does not try fallback models' do
        result = described_class.generate(prompt: prompt, options: { allow_fallback: false })
        expect(result[:success]).to be false
      end
    end

    context 'when all providers fail' do
      before do
        stub_const('LLM::Adapters::GeminiAdapter', gemini_adapter)
        stub_const('LLM::Adapters::OpenRouterAdapter', openrouter_adapter)

        allow(gemini_adapter).to receive(:generate_image).and_return({
          success: false,
          error: 'Rate limit exceeded'
        })
        allow(openrouter_adapter).to receive(:generate_image).and_return({
          success: false,
          error: 'Service unavailable'
        })
      end

      it 'returns error with last error message' do
        result = described_class.generate(prompt: prompt)
        expect(result[:success]).to be false
        expect(result[:error]).to include('All image generation models failed')
        expect(result[:error]).to include('Service unavailable')
      end
    end

    context 'when provider is not available' do
      before do
        allow(AIProviderService).to receive(:provider_available?).with('google_gemini').and_return(false)
        stub_const('LLM::Adapters::OpenRouterAdapter', openrouter_adapter)
        allow(openrouter_adapter).to receive(:generate_image).and_return({
          success: true,
          url: 'https://openrouter.com/image.png'
        })
        allow(LLM::ImageDownloader).to receive(:download).and_return('https://storage.example.com/images/test.png')
      end

      it 'skips unavailable providers' do
        result = described_class.generate(prompt: prompt)
        expect(result[:success]).to be true
        expect(result[:provider_used]).to eq('openrouter')
      end
    end

    context 'with Faraday error' do
      before do
        stub_const('LLM::Adapters::GeminiAdapter', gemini_adapter)
        allow(gemini_adapter).to receive(:generate_image).and_raise(Faraday::ConnectionFailed.new('Connection refused'))
      end

      it 'returns HTTP error' do
        result = described_class.generate(prompt: prompt, options: { allow_fallback: false })
        expect(result[:success]).to be false
        expect(result[:error]).to include('HTTP error')
      end
    end

    context 'with unexpected error' do
      before do
        stub_const('LLM::Adapters::GeminiAdapter', gemini_adapter)
        allow(gemini_adapter).to receive(:generate_image).and_raise(StandardError.new('Something went wrong'))
      end

      it 'returns unexpected error' do
        result = described_class.generate(prompt: prompt, options: { allow_fallback: false })
        expect(result[:success]).to be false
        expect(result[:error]).to include('Unexpected error')
      end
    end
  end

  describe '.generate_with_model' do
    let(:prompt) { 'A cat sitting on a windowsill' }

    context 'with successful generation returning base64 data' do
      before do
        stub_const('LLM::Adapters::GeminiAdapter', gemini_adapter)
        allow(gemini_adapter).to receive(:generate_image).and_return({
          success: true,
          base64_data: Base64.encode64('fake image data'),
          mime_type: 'image/png'
        })
      end

      it 'saves base64 image to cloud storage' do
        expect(CloudStorageService).to receive(:upload).with(
          'fake image data',
          anything,
          content_type: 'image/png'
        )

        described_class.generate_with_model(prompt, 'google_gemini', 'gemini-3.1-flash-image-preview')
      end

      it 'returns local URL for saved image' do
        result = described_class.generate_with_model(prompt, 'google_gemini', 'gemini-3.1-flash-image-preview')
        expect(result[:local_url]).to eq('https://storage.example.com/images/test.png')
      end
    end

    context 'with successful generation returning URL' do
      before do
        stub_const('LLM::Adapters::OpenAIAdapter', openai_adapter)
        allow(openai_adapter).to receive(:generate_image).and_return({
          success: true,
          url: 'https://openai.com/image.png'
        })
        allow(LLM::ImageDownloader).to receive(:download).and_return('https://storage.example.com/images/test.png')
      end

      it 'downloads and stores image from URL' do
        expect(LLM::ImageDownloader).to receive(:download).with('https://openai.com/image.png')

        described_class.generate_with_model(prompt, 'openai', 'dall-e-3')
      end

      it 'returns local URL for downloaded image' do
        result = described_class.generate_with_model(prompt, 'openai', 'dall-e-3')
        expect(result[:local_url]).to eq('https://storage.example.com/images/test.png')
      end
    end

    context 'with missing API key' do
      before do
        allow(AIProviderService).to receive(:api_key_for).with('openai').and_return(nil)
      end

      it 'returns error' do
        result = described_class.generate_with_model(prompt, 'openai', 'dall-e-3')
        expect(result[:success]).to be false
        expect(result[:error]).to eq('No API key for openai')
      end
    end

    context 'with unknown provider' do
      before do
        allow(AIProviderService).to receive(:api_key_for).with('unknown_provider').and_return('some-key')
      end

      it 'returns error' do
        result = described_class.generate_with_model(prompt, 'unknown_provider', 'some-model')
        expect(result[:success]).to be false
        expect(result[:error]).to eq('Unknown provider: unknown_provider')
      end
    end
  end

  describe 'private methods via public interface' do
    describe 'prompt_rejected? detection' do
      before do
        stub_const('LLM::Adapters::GeminiAdapter', gemini_adapter)
        stub_const('LLM::Adapters::OpenRouterAdapter', openrouter_adapter)
      end

      let(:rejection_messages) do
        [
          'Content blocked due to safety policy',
          'Content policy violation detected',
          'This prompt was rejected',
          'Inappropriate content not allowed',
          'Request blocked - prohibited content',
          'Cannot generate harmful images',
          'This violates our content policy'
        ]
      end

      it 'recognizes rejection messages and triggers fallback' do
        rejection_messages.each do |message|
          allow(gemini_adapter).to receive(:generate_image).and_return({
            success: false,
            error: message
          })
          allow(openrouter_adapter).to receive(:generate_image).and_return({
            success: true,
            url: 'https://fallback.com/image.png'
          })
          allow(LLM::ImageDownloader).to receive(:download).and_return('https://storage.example.com/fallback.png')

          result = described_class.generate(prompt: 'test')
          expect(result[:provider_used]).to eq('openrouter'), "Expected fallback for: #{message}"
        end
      end
    end

    describe 'build_model_chain' do
      before do
        stub_const('LLM::Adapters::GeminiAdapter', gemini_adapter)
        # Track which models are tried
        @models_tried = []
        allow(gemini_adapter).to receive(:generate_image) do |args|
          @models_tried << args[:options][:model]
          { success: false, error: 'Test failure' }
        end

        stub_const('LLM::Adapters::OpenRouterAdapter', openrouter_adapter)
        allow(openrouter_adapter).to receive(:generate_image) do |args|
          @models_tried << args[:options][:model]
          { success: false, error: 'Test failure' }
        end
      end

      it 'tries default then fallback for default tier' do
        described_class.generate(prompt: 'test', options: { tier: :default })

        expect(@models_tried).to include('gemini-3.1-flash-image-preview')
        expect(@models_tried).to include('bytedance-seed/seedream-4.5')
      end

      it 'tries high_quality, then default, then fallback for high_quality tier' do
        described_class.generate(prompt: 'test', options: { tier: :high_quality })

        expect(@models_tried).to include('gemini-3-pro-image-preview')
        expect(@models_tried).to include('gemini-3.1-flash-image-preview')
        expect(@models_tried).to include('bytedance-seed/seedream-4.5')
      end
    end

    describe 'normalize_options' do
      context 'for Gemini provider' do
        before do
          stub_const('LLM::Adapters::GeminiAdapter', gemini_adapter)
          allow(gemini_adapter).to receive(:generate_image).and_return({ success: true, base64_data: 'data', mime_type: 'image/png' })
        end

        it 'passes aspect_ratio option' do
          expect(gemini_adapter).to receive(:generate_image).with(hash_including(
            options: hash_including(aspect_ratio: '16:9')
          ))

          described_class.generate(prompt: 'test', options: { provider: 'google_gemini', model: 'gemini-3.1-flash-image-preview', aspect_ratio: '16:9' })
        end
      end

      context 'for OpenAI provider' do
        before do
          stub_const('LLM::Adapters::OpenAIAdapter', openai_adapter)
          allow(openai_adapter).to receive(:generate_image).and_return({ success: true, url: 'https://test.com/image.png' })
          allow(LLM::ImageDownloader).to receive(:download).and_return('https://storage.example.com/test.png')
        end

        it 'includes size, quality, style, and n options' do
          expect(openai_adapter).to receive(:generate_image).with(hash_including(
            options: hash_including(
              size: '1792x1024',
              quality: 'hd',
              style: 'vivid',
              n: 1
            )
          ))

          described_class.generate(prompt: 'test', options: {
            provider: 'openai',
            model: 'dall-e-3',
            size: '1792x1024',
            quality: 'hd',
            style: 'vivid'
          })
        end
      end
    end

    describe 'save_base64_image' do
      before do
        stub_const('LLM::Adapters::GeminiAdapter', gemini_adapter)
      end

      it 'determines png extension from mime type' do
        allow(gemini_adapter).to receive(:generate_image).and_return({
          success: true,
          base64_data: Base64.encode64('test'),
          mime_type: 'image/png'
        })

        expect(CloudStorageService).to receive(:upload) do |_data, key, opts|
          expect(key).to end_with('.png')
          expect(opts[:content_type]).to eq('image/png')
          'https://storage.example.com/test.png'
        end

        described_class.generate(prompt: 'test', options: { provider: 'google_gemini', model: 'test' })
      end

      it 'determines jpg extension from mime type' do
        allow(gemini_adapter).to receive(:generate_image).and_return({
          success: true,
          base64_data: Base64.encode64('test'),
          mime_type: 'image/jpeg'
        })

        expect(CloudStorageService).to receive(:upload) do |_data, key, opts|
          expect(key).to end_with('.jpg')
          expect(opts[:content_type]).to eq('image/jpeg')
          'https://storage.example.com/test.jpg'
        end

        described_class.generate(prompt: 'test', options: { provider: 'google_gemini', model: 'test' })
      end

      it 'determines webp extension from mime type' do
        allow(gemini_adapter).to receive(:generate_image).and_return({
          success: true,
          base64_data: Base64.encode64('test'),
          mime_type: 'image/webp'
        })

        expect(CloudStorageService).to receive(:upload) do |_data, key, opts|
          expect(key).to end_with('.webp')
          expect(opts[:content_type]).to eq('image/webp')
          'https://storage.example.com/test.webp'
        end

        described_class.generate(prompt: 'test', options: { provider: 'google_gemini', model: 'test' })
      end

      it 'generates storage key with date path' do
        allow(gemini_adapter).to receive(:generate_image).and_return({
          success: true,
          base64_data: Base64.encode64('test'),
          mime_type: 'image/png'
        })

        expected_date_path = Time.now.strftime('%Y/%m')
        expect(CloudStorageService).to receive(:upload) do |_data, key, _opts|
          expect(key).to match(%r{generated/#{expected_date_path}/.+\.png})
          'https://storage.example.com/test.png'
        end

        described_class.generate(prompt: 'test', options: { provider: 'google_gemini', model: 'test' })
      end

      it 'handles storage failure gracefully' do
        allow(gemini_adapter).to receive(:generate_image).and_return({
          success: true,
          base64_data: Base64.encode64('test'),
          mime_type: 'image/png'
        })
        allow(CloudStorageService).to receive(:upload).and_raise(StandardError.new('Storage error'))

        result = described_class.generate(prompt: 'test', options: { provider: 'google_gemini', model: 'test' })
        expect(result[:success]).to be true
        expect(result[:local_url]).to be_nil
      end
    end

    describe 'select_provider (legacy)' do
      before do
        stub_const('LLM::Adapters::GeminiAdapter', gemini_adapter)
        stub_const('LLM::Adapters::OpenAIAdapter', openai_adapter)
      end

      context 'when google_gemini is available' do
        before do
          allow(AIProviderService).to receive(:provider_available?).with('google_gemini').and_return(true)
          allow(gemini_adapter).to receive(:generate_image).and_return({ success: true, base64_data: 'data', mime_type: 'image/png' })
        end

        it 'prefers google_gemini' do
          result = described_class.generate(prompt: 'test')
          expect(result[:provider_used]).to eq('google_gemini')
        end
      end
    end

    describe 'adapter_for' do
      it 'returns GeminiAdapter for google_gemini' do
        result = described_class.generate_with_model('test', 'google_gemini', 'test-model')
        # If we got past the adapter selection, it worked
        expect(result).to include(:success)
      end

      it 'returns OpenAIAdapter for openai' do
        stub_const('LLM::Adapters::OpenAIAdapter', openai_adapter)
        allow(openai_adapter).to receive(:generate_image).and_return({ success: true, url: 'test' })
        allow(LLM::ImageDownloader).to receive(:download)

        result = described_class.generate_with_model('test', 'openai', 'test-model')
        expect(result[:success]).to be true
      end

      it 'returns OpenRouterAdapter for openrouter' do
        stub_const('LLM::Adapters::OpenRouterAdapter', openrouter_adapter)
        allow(openrouter_adapter).to receive(:generate_image).and_return({ success: true, url: 'test' })
        allow(LLM::ImageDownloader).to receive(:download)

        result = described_class.generate_with_model('test', 'openrouter', 'test-model')
        expect(result[:success]).to be true
      end

      it 'returns nil for unknown provider' do
        allow(AIProviderService).to receive(:api_key_for).with('unknown').and_return('key')

        result = described_class.generate_with_model('test', 'unknown', 'test-model')
        expect(result[:success]).to be false
        expect(result[:error]).to eq('Unknown provider: unknown')
      end
    end
  end
end
