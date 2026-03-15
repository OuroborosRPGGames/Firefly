# frozen_string_literal: true

require 'spec_helper'
require_relative '../../app/helpers/message_persistence_helper'
require_relative '../../app/helpers/output_helper'

# Test class that includes the helper and provides required context
class TestMessageContext
  include MessagePersistenceHelper
  include OutputHelper

  attr_accessor :character_instance

  def initialize(character_instance:)
    @character_instance = character_instance
  end

  def character
    @character_instance&.character
  end

  def location
    @character_instance&.current_room
  end

  def error_result(message)
    { success: false, message: message }
  end

  def online_room_characters(exclude: [])
    room_id = @character_instance&.current_room_id
    return [] unless room_id

    exclude_ids = exclude.map(&:id)
    CharacterInstance.where(current_room_id: room_id, online: true)
                     .exclude(id: exclude_ids)
                     .all
  end

  def send_to_character(_instance, _message)
    # No-op for testing
  end

  def substitute_names_for_viewer(message, _viewer)
    message
  end
end

RSpec.describe MessagePersistenceHelper do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area) }
  let(:room) { create(:room, location: location) }
  let(:reality) { create(:reality) }
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }
  let(:character_instance) do
    create(:character_instance, character: character, reality: reality, current_room: room, online: true)
  end

  let(:context) { TestMessageContext.new(character_instance: character_instance) }

  before do
    # Stub AbuseMonitoringService to allow messages by default
    allow(AbuseMonitoringService).to receive(:check_message).and_return({ allowed: true })
  end

  describe '#persist_room_message' do
    it 'creates a message in the database' do
      expect do
        context.persist_room_message('Hello, world!', message_type: 'say')
      end.to change(Message, :count).by(1)
    end

    it 'sets correct attributes on the message' do
      message = context.persist_room_message('Test message', message_type: 'emote')

      expect(message.character_instance_id).to eq character_instance.id
      expect(message.reality_id).to eq reality.id
      expect(message.room_id).to eq room.id
      expect(message.content).to eq 'Test message'
      expect(message.message_type).to eq 'emote'
    end

    it 'handles database errors gracefully' do
      # Force an error by using invalid data
      allow(Message).to receive(:create).and_raise(StandardError.new('DB error'))

      result = context.persist_room_message('Test', message_type: 'say')
      expect(result).to be_nil
    end
  end

  describe '#persist_targeted_message' do
    let(:target_character) { create(:character, user: create(:user)) }
    let(:target_instance) do
      create(:character_instance, character: target_character, reality: reality, current_room: room, online: true)
    end

    it 'creates a targeted message' do
      expect do
        context.persist_targeted_message('Psst!', target_instance, message_type: 'whisper')
      end.to change(Message, :count).by(1)
    end

    it 'sets target_character_instance_id' do
      message = context.persist_targeted_message('Secret', target_instance, message_type: 'whisper')

      expect(message.target_character_instance_id).to eq target_instance.id
      expect(message.message_type).to eq 'whisper'
    end

    it 'handles nil target' do
      message = context.persist_targeted_message('Broadcast', nil, message_type: 'broadcast')

      expect(message.target_character_instance_id).to be_nil
    end
  end

  describe '#has_recent_duplicate?' do
    before do
      # Create a recent message
      Message.create(
        character_instance_id: character_instance.id,
        reality_id: reality.id,
        room_id: room.id,
        content: "Test character says, 'Hello there!'",
        message_type: 'say'
      )
    end

    it 'returns true for exact duplicate' do
      result = context.has_recent_duplicate?('Hello there!', message_type: 'say')
      expect(result).to be true
    end

    it 'returns true for similar text' do
      result = context.has_recent_duplicate?('Hello there', message_type: 'say')
      expect(result).to be true
    end

    it 'returns false for different text' do
      result = context.has_recent_duplicate?('Goodbye!', message_type: 'say')
      expect(result).to be false
    end

    it 'returns false for different message type' do
      result = context.has_recent_duplicate?('Hello there!', message_type: 'emote')
      expect(result).to be false
    end

    it 'returns false for very short texts' do
      # Create a short message
      Message.create(
        character_instance_id: character_instance.id,
        reality_id: reality.id,
        room_id: room.id,
        content: "Test character says, 'Hi'",
        message_type: 'say'
      )

      # Very short texts require exact match
      result = context.has_recent_duplicate?('Hi', message_type: 'say')
      expect(result).to be true

      result = context.has_recent_duplicate?('Ho', message_type: 'say')
      expect(result).to be false
    end
  end

  describe '#check_for_abuse' do
    it 'calls AbuseMonitoringService with correct parameters' do
      expect(AbuseMonitoringService).to receive(:check_message).with(
        content: 'Test content',
        message_type: 'say',
        character_instance: character_instance,
        context: hash_including(:room_name, :character_name)
      )

      context.check_for_abuse('Test content', message_type: 'say')
    end

    it 'returns allowed: true when no abuse detected' do
      result = context.check_for_abuse('Normal message', message_type: 'say')
      expect(result[:allowed]).to be true
    end

    it 'returns allowed: false when abuse detected' do
      allow(AbuseMonitoringService).to receive(:check_message).and_return({
                                                                            allowed: false,
                                                                            reason: 'Inappropriate content'
                                                                          })

      result = context.check_for_abuse('Bad message', message_type: 'say')
      expect(result[:allowed]).to be false
      expect(result[:reason]).to eq 'Inappropriate content'
    end
  end

  describe '#validate_message_content' do
    context 'when user is not muted' do
      before do
        allow(user).to receive(:muted?).and_return(false)
        allow(user).to receive(:check_mute_expired!)
      end

      it 'returns nil for valid content' do
        result = context.validate_message_content('Valid message', message_type: 'say')
        expect(result).to be_nil
      end

      it 'returns error for duplicate content' do
        # Create a recent message
        Message.create(
          character_instance_id: character_instance.id,
          reality_id: reality.id,
          room_id: room.id,
          content: "Test character says, 'Duplicate!'",
          message_type: 'say'
        )

        result = context.validate_message_content('Duplicate!', message_type: 'say')
        expect(result).not_to be_nil
        expect(result[:success]).to be false
      end

      it 'returns error for abusive content' do
        allow(AbuseMonitoringService).to receive(:check_message).and_return({
                                                                              allowed: false,
                                                                              reason: 'Abuse detected'
                                                                            })

        result = context.validate_message_content('Bad content', message_type: 'say')
        expect(result).not_to be_nil
        expect(result[:success]).to be false
      end
    end

    context 'when user is muted' do
      before do
        allow(user).to receive(:muted?).and_return(true)
        allow(user).to receive(:check_mute_expired!)
        allow(user).to receive(:mute_info).and_return({ remaining_display: '5 minutes' })
      end

      it 'returns mute error' do
        result = context.validate_message_content('Any message', message_type: 'say')
        expect(result).not_to be_nil
        expect(result[:success]).to be false
        expect(result[:message]).to include('muted')
      end
    end
  end

  describe '#check_not_gagged' do
    context 'when character is not gagged' do
      before do
        allow(character_instance).to receive(:gagged?).and_return(false)
      end

      it 'returns nil' do
        result = context.check_not_gagged
        expect(result).to be_nil
      end
    end

    context 'when character is gagged' do
      before do
        allow(character_instance).to receive(:gagged?).and_return(true)
      end

      it 'returns error with default message' do
        result = context.check_not_gagged
        expect(result[:success]).to be false
        expect(result[:message]).to include('muffled sounds')
        expect(result[:message]).to include('speak')
      end

      it 'returns error with custom action description' do
        result = context.check_not_gagged('express yourself')
        expect(result[:message]).to include('express yourself')
      end
    end
  end
end
