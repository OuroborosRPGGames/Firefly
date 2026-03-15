# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RpLog do
  let(:room) { create(:room) }
  let(:character) { create(:character) }
  let(:character_instance) { create(:character_instance, character: character, current_room: room) }

  # Helper to create a log with logged_at set (required for sorting)
  def create_log(attrs = {})
    defaults = {
      character_instance_id: character_instance.id,
      room_id: room.id,
      timeline_id: character_instance.timeline_id,
      logged_at: Time.now
    }
    RpLog.create(defaults.merge(attrs))
  end

  describe 'constants' do
    it 'has expected log types' do
      expect(RpLog::LOG_TYPES).to include('say', 'emote', 'whisper', 'movement', 'combat', 'system')
    end

    it 'has dedup window set' do
      expect(RpLog::DEDUP_WINDOW).to eq(120)
    end
  end

  describe 'validations' do
    it 'requires content' do
      log = RpLog.new(character_instance_id: character_instance.id)
      expect(log.valid?).to be false
      expect(log.errors[:content]).not_to be_empty
    end

    it 'requires character_instance_id' do
      log = RpLog.new(content: 'Test message')
      expect(log.valid?).to be false
      expect(log.errors[:character_instance_id]).not_to be_empty
    end

    it 'accepts valid log entry' do
      log = RpLog.new(
        character_instance_id: character_instance.id,
        content: 'Test message',
        room_id: room.id
      )
      expect(log.valid?).to be true
    end

    it 'rejects blank content' do
      log = RpLog.new(character_instance_id: character_instance.id, content: '   ')
      expect(log.valid?).to be false
    end
  end

  describe '#text alias' do
    let(:log) { RpLog.new(content: 'Hello world') }

    it 'reads content via text' do
      expect(log.text).to eq('Hello world')
    end

    it 'writes content via text=' do
      log.text = 'Goodbye world'
      expect(log.content).to eq('Goodbye world')
    end
  end

  describe 'before_create' do
    it 'generates content_hash for deduplication' do
      log = create_log(content: 'Test message')
      expect(log.content_hash).not_to be_nil
      expect(log.content_hash.length).to eq(64)
    end

    it 'does not overwrite existing content_hash' do
      custom_hash = 'custom_hash_value'
      log = RpLog.new(
        character_instance_id: character_instance.id,
        content: 'Test message',
        room_id: room.id,
        timeline_id: character_instance.timeline_id,
        logged_at: Time.now,
        content_hash: custom_hash
      )
      log.save
      expect(log.content_hash).to eq(custom_hash)
    end
  end

  describe '.visible_to' do
    it 'returns logs for the specified character instance' do
      log1 = create_log(content: 'Log 1')
      other_instance = create(:character_instance, current_room: room)
      log2 = create_log(content: 'Log 2', character_instance_id: other_instance.id)

      results = RpLog.visible_to(character_instance).all
      expect(results.map(&:id)).to include(log1.id)
      expect(results.map(&:id)).not_to include(log2.id)
    end

    it 'returns empty dataset for nil character' do
      expect(RpLog.visible_to(nil).count).to eq(0)
    end

    it 'limits results' do
      3.times do |i|
        create_log(content: "Log #{i}")
      end

      results = RpLog.visible_to(character_instance, 2).all
      expect(results.count).to eq(2)
    end

    it 'orders by logged_at descending' do
      log1 = create_log(content: 'Old', logged_at: Time.now - 3600)
      log2 = create_log(content: 'New', logged_at: Time.now)

      results = RpLog.visible_to(character_instance).all
      expect(results.first.id).to eq(log2.id)
      expect(results.last.id).to eq(log1.id)
    end
  end

  describe '.visible_with_privacy' do
    before do
      @public_log = create_log(content: 'Public', is_private: false)
      @private_log = create_log(content: 'Private', is_private: true)
    end

    it 'excludes private logs by default' do
      results = RpLog.visible_with_privacy(character_instance).all
      expect(results.map(&:id)).to include(@public_log.id)
      expect(results.map(&:id)).not_to include(@private_log.id)
    end

    it 'includes private logs when requested' do
      results = RpLog.visible_with_privacy(character_instance, include_private: true).all
      expect(results.map(&:id)).to include(@public_log.id)
      expect(results.map(&:id)).to include(@private_log.id)
    end
  end

  describe '.recent_for_character' do
    it 'returns logs in chronological order (oldest first)' do
      log1 = create_log(content: 'Old', logged_at: Time.now - 3600)
      log2 = create_log(content: 'New', logged_at: Time.now)

      results = RpLog.recent_for_character(character_instance)
      expect(results.first.id).to eq(log1.id)
      expect(results.last.id).to eq(log2.id)
    end
  end

  describe '.since_logout' do
    it 'returns logs since last logout' do
      character_instance.update(last_logout_at: Time.now - 3600)

      old_log = create_log(content: 'Before logout', logged_at: Time.now - 7200)
      new_log = create_log(content: 'After logout', logged_at: Time.now - 1800)

      results = RpLog.since_logout(character_instance)
      expect(results.map(&:id)).not_to include(old_log.id)
      expect(results.map(&:id)).to include(new_log.id)
    end

    it 'returns recent logs if no last_logout_at' do
      character_instance.update(last_logout_at: nil)
      log = create_log(content: 'Test')

      results = RpLog.since_logout(character_instance)
      expect(results.map(&:id)).to include(log.id)
    end
  end

  describe '.duplicate?' do
    it 'returns true for duplicate content within window' do
      create_log(content: 'Duplicate test')
      expect(RpLog.duplicate?(character_instance.id, 'Duplicate test')).to be true
    end

    it 'returns false for different content' do
      create_log(content: 'Original')
      expect(RpLog.duplicate?(character_instance.id, 'Different')).to be false
    end

    it 'returns false for same content from different character' do
      create_log(content: 'Test')
      other_instance = create(:character_instance, current_room: room)
      expect(RpLog.duplicate?(other_instance.id, 'Test')).to be false
    end

    it 'returns false for same content from different senders' do
      sender_one = create(:character)
      sender_two = create(:character)
      create_log(content: 'Echo', sender_character_id: sender_one.id, log_type: 'say')

      expect(
        RpLog.duplicate?(
          character_instance.id,
          'Echo',
          sender_character_id: sender_two.id,
          log_type: 'say'
        )
      ).to be false
    end
  end

  describe '.content_hash_for' do
    it 'generates consistent hash for same input' do
      hash1 = RpLog.content_hash_for('Test content', 1)
      hash2 = RpLog.content_hash_for('Test content', 1)
      expect(hash1).to eq(hash2)
    end

    it 'generates different hash for different character' do
      hash1 = RpLog.content_hash_for('Test content', 1)
      hash2 = RpLog.content_hash_for('Test content', 2)
      expect(hash1).not_to eq(hash2)
    end

    it 'returns 64 character hash' do
      hash = RpLog.content_hash_for('Any content', 1)
      expect(hash.length).to eq(64)
    end

    it 'changes hash when sender context differs' do
      hash1 = RpLog.content_hash_for('Test content', 1, sender_character_id: 10, log_type: 'say')
      hash2 = RpLog.content_hash_for('Test content', 1, sender_character_id: 11, log_type: 'say')
      expect(hash1).not_to eq(hash2)
    end
  end

  describe '#display_timestamp' do
    it 'returns logged_at when available' do
      logged_time = Time.now - 3600
      log = RpLog.new(logged_at: logged_time, created_at: Time.now)
      expect(log.display_timestamp).to eq(logged_time)
    end

    it 'falls back to created_at when logged_at is nil' do
      created_time = Time.now - 1800
      log = RpLog.new(logged_at: nil, created_at: created_time)
      expect(log.display_timestamp).to eq(created_time)
    end
  end

  describe '#in_past_timeline?' do
    it 'returns true when timeline_id is set' do
      log = RpLog.new(timeline_id: 1)
      expect(log.in_past_timeline?).to be true
    end

    it 'returns false when timeline_id is nil' do
      log = RpLog.new(timeline_id: nil)
      expect(log.in_past_timeline?).to be false
    end
  end

  describe '#to_api_hash' do
    let(:log) do
      create_log(
        content: 'Test content',
        html_content: '<p>Test content</p>',
        sender_character_id: character.id,
        log_type: 'emote',
        is_private: false,
        scene_id: 42
      )
    end

    it 'includes all expected fields' do
      hash = log.to_api_hash
      expect(hash).to include(
        :id, :content, :html_content, :log_type, :is_private,
        :sender_name, :room_name, :timestamp, :scene_id
      )
    end

    it 'includes timeline awareness fields' do
      hash = log.to_api_hash
      expect(hash).to include(:timeline_id, :in_past_timeline)
    end

    it 'uses viewer for sender name resolution when provided' do
      viewer = create(:character_instance, current_room: room)
      hash = log.to_api_hash(viewer)
      expect(hash[:sender_name]).not_to be_nil
    end
  end

  describe '#formatted_for' do
    let(:sender) { create(:character, forename: 'John', surname: 'Doe') }
    let(:log) do
      RpLog.new(
        content: "John Doe waves hello.",
        sender_character_id: sender.id,
        logged_at: Time.now
      )
    end

    it 'returns formatted hash with text' do
      result = log.formatted_for(character_instance)
      expect(result[:text]).to include('waves hello')
    end

    it 'includes timestamp' do
      result = log.formatted_for(character_instance)
      expect(result[:timestamp]).not_to be_nil
    end
  end

  describe 'cache invalidation' do
    it 'invalidates chapter cache when new log is created' do
      expect(ChapterService).to receive(:invalidate_cache).with(character.id)

      create_log(content: 'Test log content for cache invalidation')
    end

    it 'handles nil character_instance gracefully' do
      expect(ChapterService).not_to receive(:invalidate_cache)

      # Attempt to create log without character_instance_id
      # Validation should fail, but after_create hook should not crash
      log = RpLog.new(
        character_instance_id: nil,
        room_id: room.id,
        timeline_id: character_instance.timeline_id,
        content: 'Test log content',
        logged_at: Time.now
      )

      expect(log.valid?).to be false
      expect(log.errors[:character_instance_id]).not_to be_empty
    end
  end
end
