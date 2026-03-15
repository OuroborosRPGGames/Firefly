# frozen_string_literal: true

require 'spec_helper'

RSpec.describe LLM::Client do
  let(:prompt) { 'Tell me a story' }
  let(:success_result) do
    {
      success: true,
      text: 'Once upon a time...',
      data: {},
      error: nil
    }
  end

  describe '.generate' do
    before do
      allow(LLM::TextGenerationService).to receive(:generate).and_return(success_result)
    end

    it 'delegates to TextGenerationService' do
      expect(LLM::TextGenerationService).to receive(:generate).with(
        prompt: prompt,
        model: nil,
        provider: nil,
        options: {},
        json_mode: false,
        conversation: nil,
        tools: nil
      )
      described_class.generate(prompt: prompt)
    end

    it 'returns result from TextGenerationService' do
      result = described_class.generate(prompt: prompt)
      expect(result[:success]).to be true
      expect(result[:text]).to eq('Once upon a time...')
    end

    it 'passes all options through' do
      expect(LLM::TextGenerationService).to receive(:generate).with(
        prompt: prompt,
        model: 'gpt-5.4',
        provider: 'openai',
        options: { temperature: 0.5 },
        json_mode: true,
        conversation: nil,
        tools: nil
      )
      described_class.generate(
        prompt: prompt,
        model: 'gpt-5.4',
        provider: 'openai',
        options: { temperature: 0.5 },
        json_mode: true
      )
    end
  end

  describe '.generate_async' do
    let(:request) { instance_double(LLMRequest, id: 1) }

    before do
      allow(LLMRequest).to receive(:create_text_request).and_return(request)
      allow(LLM::RequestProcessor).to receive(:enqueue_async)
    end

    it 'creates text request' do
      expect(LLMRequest).to receive(:create_text_request).with(
        prompt: prompt,
        callback: 'TestHandler',
        context: { room_id: 123 },
        provider: nil,
        model: nil,
        options: {},
        conversation: nil,
        character_instance: nil
      )
      described_class.generate_async(prompt: prompt, callback: 'TestHandler', context: { room_id: 123 })
    end

    it 'spawns processor for request' do
      expect(LLM::RequestProcessor).to receive(:enqueue_async).with(request)
      described_class.generate_async(prompt: prompt)
    end

    it 'returns the request' do
      result = described_class.generate_async(prompt: prompt)
      expect(result).to eq(request)
    end

    it 'merges json_mode into options' do
      expect(LLMRequest).to receive(:create_text_request).with(
        hash_including(options: { json_mode: true })
      )
      described_class.generate_async(prompt: prompt, json_mode: true)
    end
  end

  describe '.start_conversation' do
    let(:conversation) { instance_double(LLMConversation, id: 1) }

    before do
      allow(LLMConversation).to receive(:start).and_return(conversation)
    end

    it 'creates new conversation' do
      expect(LLMConversation).to receive(:start).with(
        purpose: 'npc_chat',
        system_prompt: 'You are helpful',
        character_instance: nil,
        metadata: {}
      )
      described_class.start_conversation(purpose: 'npc_chat', system_prompt: 'You are helpful')
    end

    it 'returns the conversation' do
      result = described_class.start_conversation(purpose: 'test')
      expect(result).to eq(conversation)
    end
  end

  describe '.chat_async' do
    let(:conversation) { instance_double(LLMConversation, id: 123) }
    let(:request) { instance_double(LLMRequest, id: 1) }

    before do
      allow(conversation).to receive(:add_message)
      allow(conversation).to receive(:message_history).and_return([
        { role: 'system', content: 'You are helpful' },
        { role: 'user', content: 'Hello' }
      ])
      allow(LLMRequest).to receive(:create_text_request).and_return(request)
      allow(LLM::RequestProcessor).to receive(:enqueue_async)
    end

    it 'adds user message to conversation' do
      expect(conversation).to receive(:add_message).with(role: 'user', content: 'Hello')
      described_class.chat_async(conversation: conversation, message: 'Hello')
    end

    it 'gets message history' do
      expect(conversation).to receive(:message_history).with(include_system: true)
      described_class.chat_async(conversation: conversation, message: 'Hello')
    end

    it 'creates request with conversation_id in context' do
      expect(LLMRequest).to receive(:create_text_request) do |args|
        expect(args[:context][:conversation_id]).to eq(123)
        request
      end
      described_class.chat_async(conversation: conversation, message: 'Hello')
    end

    it 'returns request' do
      result = described_class.chat_async(conversation: conversation, message: 'Hello')
      expect(result).to eq(request)
    end
  end

  describe '.chat' do
    let(:conversation) { instance_double(LLMConversation) }

    before do
      allow(conversation).to receive(:add_message)
      allow(conversation).to receive(:message_history).and_return([
        { role: 'user', content: 'Hello' }
      ])
      allow(LLM::TextGenerationService).to receive(:generate).and_return(success_result)
    end

    it 'adds user message to conversation' do
      expect(conversation).to receive(:add_message).with(role: 'user', content: 'Hello')
      described_class.chat(conversation: conversation, message: 'Hello')
    end

    it 'adds assistant response to conversation on success' do
      expect(conversation).to receive(:add_message).with(role: 'assistant', content: 'Once upon a time...')
      described_class.chat(conversation: conversation, message: 'Hello')
    end

    it 'does not add assistant message on failure' do
      allow(LLM::TextGenerationService).to receive(:generate).and_return({ success: false, error: 'Failed' })
      expect(conversation).not_to receive(:add_message).with(hash_including(role: 'assistant'))
      described_class.chat(conversation: conversation, message: 'Hello')
    end

    it 'returns result' do
      result = described_class.chat(conversation: conversation, message: 'Hello')
      expect(result[:success]).to be true
    end
  end

  describe '.generate_image' do
    let(:image_result) do
      { success: true, url: 'https://example.com/image.png', data: {} }
    end

    before do
      allow(LLM::ImageGenerationService).to receive(:generate).and_return(image_result)
    end

    it 'delegates to ImageGenerationService' do
      expect(LLM::ImageGenerationService).to receive(:generate).with(
        prompt: 'A cat',
        options: { size: '512x512' }
      )
      described_class.generate_image(prompt: 'A cat', options: { size: '512x512' })
    end

    it 'returns result' do
      result = described_class.generate_image(prompt: 'A cat')
      expect(result[:success]).to be true
      expect(result[:url]).to eq('https://example.com/image.png')
    end
  end

  describe '.generate_image_async' do
    let(:request) { instance_double(LLMRequest, id: 1) }

    before do
      allow(LLMRequest).to receive(:create_image_request).and_return(request)
      allow(LLM::RequestProcessor).to receive(:enqueue_async)
    end

    it 'creates image request' do
      expect(LLMRequest).to receive(:create_image_request).with(
        prompt: 'A cat',
        callback: 'ImageHandler',
        context: {},
        options: {},
        character_instance: nil
      )
      described_class.generate_image_async(prompt: 'A cat', callback: 'ImageHandler')
    end

    it 'spawns processor' do
      expect(LLM::RequestProcessor).to receive(:enqueue_async).with(request)
      described_class.generate_image_async(prompt: 'A cat')
    end

    it 'returns request' do
      result = described_class.generate_image_async(prompt: 'A cat')
      expect(result).to eq(request)
    end
  end

  describe '.embed' do
    let(:embed_result) do
      { success: true, embedding: [0.1, 0.2, 0.3], dimensions: 1024 }
    end

    before do
      allow(LLM::EmbeddingService).to receive(:generate).and_return(embed_result)
    end

    it 'delegates to EmbeddingService' do
      expect(LLM::EmbeddingService).to receive(:generate).with(
        text: 'Hello',
        model: nil,
        input_type: 'document'
      )
      described_class.embed(text: 'Hello')
    end

    it 'passes input_type' do
      expect(LLM::EmbeddingService).to receive(:generate).with(
        hash_including(input_type: 'query')
      )
      described_class.embed(text: 'Hello', input_type: 'query')
    end

    it 'returns result' do
      result = described_class.embed(text: 'Hello')
      expect(result[:success]).to be true
      expect(result[:embedding]).to eq([0.1, 0.2, 0.3])
    end
  end

  describe '.embed_batch' do
    let(:batch_result) do
      { success: true, embeddings: [[0.1], [0.2]], dimensions: 1024 }
    end

    before do
      allow(LLM::EmbeddingService).to receive(:generate_batch).and_return(batch_result)
    end

    it 'delegates to EmbeddingService' do
      expect(LLM::EmbeddingService).to receive(:generate_batch).with(
        texts: ['Hello', 'World'],
        model: nil,
        input_type: 'document'
      )
      described_class.embed_batch(texts: ['Hello', 'World'])
    end

    it 'returns result' do
      result = described_class.embed_batch(texts: ['Hello', 'World'])
      expect(result[:success]).to be true
      expect(result[:embeddings].length).to eq(2)
    end
  end

  describe '.embed_async' do
    let(:request) { instance_double(LLMRequest, id: 1) }

    before do
      allow(LLMRequest).to receive(:create_embedding_request).and_return(request)
      allow(LLM::RequestProcessor).to receive(:enqueue_async)
      allow(LLM::EmbeddingService).to receive(:default_model).and_return('voyage-3-large')
    end

    it 'creates embedding request' do
      expect(LLMRequest).to receive(:create_embedding_request).with(
        text: 'Hello',
        callback: 'EmbedHandler',
        context: {},
        model: 'voyage-3-large',
        input_type: 'document',
        character_instance: nil
      )
      described_class.embed_async(text: 'Hello', callback: 'EmbedHandler')
    end

    it 'spawns processor' do
      expect(LLM::RequestProcessor).to receive(:enqueue_async).with(request)
      described_class.embed_async(text: 'Hello')
    end

    it 'returns request' do
      result = described_class.embed_async(text: 'Hello')
      expect(result).to eq(request)
    end
  end

  describe '.embeddings_available?' do
    it 'delegates to EmbeddingService' do
      allow(LLM::EmbeddingService).to receive(:available?).and_return(true)
      expect(described_class.embeddings_available?).to be true
    end
  end

  describe '.available?' do
    it 'delegates to AIProviderService' do
      allow(AIProviderService).to receive(:any_available?).and_return(true)
      expect(described_class.available?).to be true
    end
  end

  describe '.status' do
    let(:pending_query) { double(count: 5) }
    let(:failed_query) { double(where: double(count: 2)) }

    before do
      allow(AIProviderService).to receive(:any_available?).and_return(true)
      allow(AIProviderService).to receive(:status_summary).and_return({ anthropic: true })
      allow(LLMRequest).to receive(:where).with(status: %w[pending processing]).and_return(pending_query)
      allow(LLMRequest).to receive(:where).with(status: 'failed').and_return(failed_query)
    end

    it 'returns status hash' do
      result = described_class.status
      expect(result[:available]).to be true
      expect(result[:providers]).to eq({ anthropic: true })
      expect(result[:pending_requests]).to eq(5)
      expect(result[:recent_failures]).to eq(2)
    end
  end
end
