# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Message do
  describe 'validations' do
    it 'validates presence of content' do
      character = create(:character)
      message = Message.new(character_id: character.id, content: nil)
      expect(message).not_to be_valid
    end
    
    it 'validates presence of character_id' do
      message = Message.new(content: "Test", character_id: nil)
      expect(message).not_to be_valid
    end
    
    it 'is valid with valid attributes' do
      character = create(:character)
      reality = create(:reality)
      message = Message.new(
        character_id: character.id,
        content: "Test message",
        reality_id: reality.id,
        message_type: 'say'
      )
      expect(message).to be_valid
    end
  end
  
  describe 'associations' do
    it 'belongs to a character' do
      character = create(:character)
      message = create(:message, character: character)
      
      expect(message.character).to eq(character)
      expect(message.character_id).to eq(character.id)
    end
  end
  
  describe 'creation' do
    it 'creates a message with valid attributes' do
      character = create(:character)
      
      expect {
        create(:message, character: character, content: 'Test message')
      }.to change(Message, :count).by(1)
    end
    
    it 'sets timestamp on creation' do
      message = create(:message)
      expect(message.created_at).not_to be_nil
    end
  end
end