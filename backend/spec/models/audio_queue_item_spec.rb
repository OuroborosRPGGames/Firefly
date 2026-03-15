# frozen_string_literal: true

require 'spec_helper'

RSpec.describe AudioQueueItem do
  let(:character_instance) { create(:character_instance) }

  # Helper to create a valid queue item
  def create_queue_item(attrs = {})
    item = AudioQueueItem.new
    item.character_instance = attrs[:character_instance] || character_instance
    item.audio_url = attrs[:audio_url] || 'https://example.com/audio.mp3'
    item.content_type = attrs[:content_type] || 'narrator'
    item.sequence_number = attrs[:sequence_number] || AudioQueueItem.next_sequence_for(character_instance.id)
    item.original_text = attrs[:original_text] if attrs[:original_text]
    item.voice_type = attrs[:voice_type] if attrs[:voice_type]
    item.duration_seconds = attrs[:duration_seconds] if attrs[:duration_seconds]
    item.played = attrs[:played] || false
    item.expires_at = attrs[:expires_at] if attrs[:expires_at]
    item.save
    item
  end

  describe 'associations' do
    it 'belongs to character_instance' do
      item = create_queue_item(character_instance: character_instance)
      expect(item.character_instance.id).to eq(character_instance.id)
    end
  end

  describe 'validations' do
    it 'requires character_instance_id' do
      item = AudioQueueItem.new(
        audio_url: 'https://example.com/audio.mp3',
        content_type: 'narrator',
        sequence_number: 1
      )
      expect(item.valid?).to be false
      expect(item.errors[:character_instance_id]).not_to be_empty
    end

    it 'requires audio_url' do
      item = AudioQueueItem.new(
        character_instance_id: character_instance.id,
        content_type: 'narrator',
        sequence_number: 1
      )
      expect(item.valid?).to be false
      expect(item.errors[:audio_url]).not_to be_empty
    end

    it 'requires content_type' do
      item = AudioQueueItem.new(
        character_instance_id: character_instance.id,
        audio_url: 'https://example.com/audio.mp3',
        sequence_number: 1
      )
      expect(item.valid?).to be false
      expect(item.errors[:content_type]).not_to be_empty
    end

    it 'requires sequence_number' do
      item = AudioQueueItem.new(
        character_instance_id: character_instance.id,
        audio_url: 'https://example.com/audio.mp3',
        content_type: 'narrator'
      )
      expect(item.valid?).to be false
      expect(item.errors[:sequence_number]).not_to be_empty
    end

    AudioQueueItem::CONTENT_TYPES.each do |content_type|
      it "accepts #{content_type} as content_type" do
        item = AudioQueueItem.new(
          character_instance_id: character_instance.id,
          audio_url: 'https://example.com/audio.mp3',
          content_type: content_type,
          sequence_number: 1
        )
        expect(item.valid?).to be true
      end
    end

    it 'rejects invalid content_type' do
      item = AudioQueueItem.new(
        character_instance_id: character_instance.id,
        audio_url: 'https://example.com/audio.mp3',
        content_type: 'invalid',
        sequence_number: 1
      )
      expect(item.valid?).to be false
    end
  end

  describe '#before_create' do
    it 'sets queued_at if not provided' do
      item = create_queue_item
      expect(item.queued_at).not_to be_nil
    end

    it 'sets expires_at if not provided' do
      item = create_queue_item
      expect(item.expires_at).not_to be_nil
    end
  end

  describe '#mark_played!' do
    it 'sets played to true' do
      item = create_queue_item(played: false)
      item.mark_played!
      item.refresh

      expect(item.played).to be true
    end

    it 'sets played_at' do
      item = create_queue_item(played: false)
      item.mark_played!
      item.refresh

      expect(item.played_at).not_to be_nil
    end
  end

  describe '#expired?' do
    it 'returns true when expires_at is in the past' do
      item = create_queue_item(expires_at: Time.now - 60)
      expect(item.expired?).to be true
    end

    it 'returns false when expires_at is in the future' do
      item = create_queue_item(expires_at: Time.now + 3600)
      expect(item.expired?).to be false
    end

    # Note: expires_at has NOT NULL constraint, so we can't test nil case
  end

  describe '.next_sequence_for' do
    it 'returns 1 for first item' do
      expect(AudioQueueItem.next_sequence_for(character_instance.id)).to eq(1)
    end

    it 'returns next sequence number' do
      create_queue_item(sequence_number: 5)

      expect(AudioQueueItem.next_sequence_for(character_instance.id)).to eq(6)
    end
  end

  describe '.cleanup_expired!' do
    it 'deletes expired items' do
      expired = create_queue_item(expires_at: Time.now - 120)
      valid = create_queue_item(expires_at: Time.now + 3600, sequence_number: 2)

      AudioQueueItem.cleanup_expired!

      expect(AudioQueueItem[expired.id]).to be_nil
      expect(AudioQueueItem[valid.id]).not_to be_nil
    end
  end

  describe '.pending_for' do
    it 'returns unplayed items in sequence order' do
      item1 = create_queue_item(sequence_number: 1, played: false)
      item2 = create_queue_item(sequence_number: 2, played: false)
      create_queue_item(sequence_number: 3, played: true)

      results = AudioQueueItem.pending_for(character_instance.id)

      expect(results.map(&:id)).to eq([item1.id, item2.id])
    end

    it 'respects from_position' do
      create_queue_item(sequence_number: 1, played: false)
      item2 = create_queue_item(sequence_number: 2, played: false)
      item3 = create_queue_item(sequence_number: 3, played: false)

      results = AudioQueueItem.pending_for(character_instance.id, from_position: 1)

      expect(results.map(&:id)).to eq([item2.id, item3.id])
    end

    it 'respects limit' do
      create_queue_item(sequence_number: 1, played: false)
      create_queue_item(sequence_number: 2, played: false)
      create_queue_item(sequence_number: 3, played: false)

      results = AudioQueueItem.pending_for(character_instance.id, limit: 2)

      expect(results.length).to eq(2)
    end
  end

  describe '#to_api_hash' do
    it 'returns hash with all API fields' do
      item = create_queue_item(
        sequence_number: 5,
        original_text: 'Hello world',
        voice_type: 'default',
        duration_seconds: 3.5,
        played: false
      )

      api_hash = item.to_api_hash

      expect(api_hash[:id]).to eq(item.id)
      expect(api_hash[:sequence]).to eq(5)
      expect(api_hash[:audio_url]).to eq('https://example.com/audio.mp3')
      expect(api_hash[:content_type]).to eq('narrator')
      expect(api_hash[:text]).to eq('Hello world')
      expect(api_hash[:voice]).to eq('default')
      expect(api_hash[:duration]).to eq(3.5)
      expect(api_hash[:played]).to be false
    end
  end
end
