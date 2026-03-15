# frozen_string_literal: true

require 'spec_helper'

RSpec.describe LLMConversation do
  let(:reality) { create(:reality) }
  let(:room) { create(:room) }
  let(:character) { create(:character) }
  let(:character_instance) { create(:character_instance, character: character, reality: reality, current_room: room) }

  describe 'validations' do
    it 'requires conversation_id' do
      conv = described_class.new(purpose: 'npc_chat')
      expect(conv.valid?).to be false
      expect(conv.errors[:conversation_id]).to include('is not present')
    end

    it 'validates purpose is in PURPOSES list' do
      conv = described_class.new(
        conversation_id: SecureRandom.uuid,
        purpose: 'invalid_purpose'
      )
      expect(conv.valid?).to be false
    end

    it 'allows valid purposes' do
      described_class::PURPOSES.each do |purpose|
        conv = described_class.new(
          conversation_id: SecureRandom.uuid,
          purpose: purpose
        )
        conv.valid?
        expect(conv.errors.on(:purpose)).to be_nil
      end
    end
  end

  describe '.start' do
    it 'creates a new conversation with generated conversation_id' do
      conv = described_class.start(purpose: 'npc_chat')

      expect(conv.id).not_to be_nil
      expect(conv.conversation_id).not_to be_nil
      expect(conv.purpose).to eq('npc_chat')
    end

    it 'sets system_prompt when provided' do
      conv = described_class.start(
        purpose: 'npc_chat',
        system_prompt: 'You are an innkeeper.'
      )

      expect(conv.system_prompt).to eq('You are an innkeeper.')
    end

    it 'associates with character_instance when provided' do
      conv = described_class.start(
        purpose: 'npc_chat',
        character_instance: character_instance
      )

      expect(conv.character_instance_id).to eq(character_instance.id)
    end

    it 'sets last_message_at to current time' do
      conv = described_class.start(purpose: 'npc_chat')
      expect(conv.last_message_at).to be_within(1).of(Time.now)
    end
  end

  describe '#add_message' do
    let(:conversation) { described_class.start(purpose: 'npc_chat') }

    it 'creates an associated LLMMessage' do
      message = conversation.add_message(role: 'user', content: 'Hello!')

      expect(message.id).not_to be_nil
      expect(message.llm_conversation_id).to eq(conversation.id)
      expect(message.role).to eq('user')
      expect(message.content).to eq('Hello!')
    end

    it 'updates last_message_at' do
      original_time = conversation.last_message_at
      sleep 0.01
      conversation.add_message(role: 'user', content: 'Hello!')

      conversation.refresh
      expect(conversation.last_message_at).to be > original_time
    end

    it 'sets token_count when provided' do
      message = conversation.add_message(role: 'user', content: 'Hello!', token_count: 5)
      expect(message.token_count).to eq(5)
    end
  end

  describe '#message_history' do
    let(:conversation) do
      conv = described_class.start(purpose: 'npc_chat', system_prompt: 'You are helpful.')
      conv.add_message(role: 'user', content: 'Hi')
      conv.add_message(role: 'assistant', content: 'Hello!')
      conv
    end

    it 'returns messages without system prompt by default' do
      history = conversation.message_history
      expect(history.length).to eq(2)
      expect(history[0][:role]).to eq('user')
      expect(history[1][:role]).to eq('assistant')
    end

    it 'includes system prompt when requested' do
      history = conversation.message_history(include_system: true)
      expect(history.length).to eq(3)
      expect(history[0][:role]).to eq('system')
      expect(history[0][:content]).to eq('You are helpful.')
    end
  end

  describe '#recent_messages' do
    let(:conversation) do
      conv = described_class.start(purpose: 'npc_chat')
      5.times { |i| conv.add_message(role: 'user', content: "Message #{i}") }
      conv
    end

    it 'returns messages in chronological order' do
      messages = conversation.recent_messages(3)
      expect(messages.length).to eq(3)
      expect(messages[0].content).to eq('Message 2')
      expect(messages[2].content).to eq('Message 4')
    end
  end
end
