# frozen_string_literal: true

require 'spec_helper'

RSpec.describe LLMMessage do
  let(:conversation) { LLMConversation.start(purpose: 'npc_chat') }

  describe 'validations' do
    it 'requires llm_conversation_id' do
      message = described_class.new(role: 'user', content: 'Hello')
      expect(message.valid?).to be false
      expect(message.errors[:llm_conversation_id]).to include('is not present')
    end

    it 'requires role' do
      message = described_class.new(llm_conversation_id: conversation.id, content: 'Hello')
      expect(message.valid?).to be false
      expect(message.errors[:role]).to include('is not present')
    end

    it 'requires content' do
      message = described_class.new(llm_conversation_id: conversation.id, role: 'user')
      expect(message.valid?).to be false
      expect(message.errors[:content]).to include('is not present')
    end

    it 'validates role is in ROLES list' do
      message = described_class.new(
        llm_conversation_id: conversation.id,
        role: 'invalid',
        content: 'Hello'
      )
      expect(message.valid?).to be false
    end

    it 'allows valid roles' do
      described_class::ROLES.each do |role|
        message = described_class.new(
          llm_conversation_id: conversation.id,
          role: role,
          content: 'Hello'
        )
        message.valid?
        expect(message.errors.on(:role)).to be_nil
      end
    end
  end

  describe 'role helpers' do
    it '#user? returns true for user role' do
      message = conversation.add_message(role: 'user', content: 'Hi')
      expect(message.user?).to be true
      expect(message.assistant?).to be false
      expect(message.system?).to be false
    end

    it '#assistant? returns true for assistant role' do
      message = conversation.add_message(role: 'assistant', content: 'Hello!')
      expect(message.assistant?).to be true
      expect(message.user?).to be false
      expect(message.system?).to be false
    end

    it '#system? returns true for system role' do
      message = conversation.add_message(role: 'system', content: 'Instructions')
      expect(message.system?).to be true
      expect(message.user?).to be false
      expect(message.assistant?).to be false
    end
  end

  describe '#to_api_format' do
    it 'returns hash with role and content' do
      message = conversation.add_message(role: 'user', content: 'Hello!')
      expect(message.to_api_format).to eq({ role: 'user', content: 'Hello!' })
    end
  end
end
