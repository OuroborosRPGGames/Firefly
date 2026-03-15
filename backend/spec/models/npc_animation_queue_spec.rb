# frozen_string_literal: true

require 'spec_helper'

RSpec.describe NpcAnimationQueue do
  let(:archetype) { create(:npc_archetype, :animated) }
  let(:npc_character) { create(:character, :npc, npc_archetype: archetype) }
  let(:room) { create(:room) }
  let(:npc_instance) do
    create(:character_instance, character: npc_character, current_room: room, online: true)
  end

  # Helper to create queue entries directly
  def create_queue(attrs = {})
    NpcAnimationQueue.create({
      character_instance_id: npc_instance.id,
      room_id: room.id,
      trigger_type: 'high_turn',
      status: 'pending',
      scheduled_at: Time.now
    }.merge(attrs))
  end

  describe 'validations' do
    it 'requires character_instance_id' do
      queue = NpcAnimationQueue.new(
        room_id: room.id,
        trigger_type: 'high_turn',
        status: 'pending'
      )
      expect(queue.valid?).to be false
      expect(queue.errors[:character_instance_id]).not_to be_empty
    end

    it 'requires room_id' do
      queue = NpcAnimationQueue.new(
        character_instance_id: npc_instance.id,
        trigger_type: 'high_turn',
        status: 'pending'
      )
      expect(queue.valid?).to be false
      expect(queue.errors[:room_id]).not_to be_empty
    end

    it 'requires trigger_type' do
      queue = NpcAnimationQueue.new(
        character_instance_id: npc_instance.id,
        room_id: room.id,
        status: 'pending'
      )
      expect(queue.valid?).to be false
      expect(queue.errors[:trigger_type]).not_to be_empty
    end

    it 'requires valid trigger_type' do
      queue = NpcAnimationQueue.new(
        character_instance_id: npc_instance.id,
        room_id: room.id,
        trigger_type: 'invalid',
        status: 'pending'
      )
      expect(queue.valid?).to be false
    end

    it 'requires valid status' do
      queue = NpcAnimationQueue.new(
        character_instance_id: npc_instance.id,
        room_id: room.id,
        trigger_type: 'high_turn',
        status: 'invalid'
      )
      expect(queue.valid?).to be false
    end

    it 'accepts valid trigger types' do
      NpcAnimationQueue::TRIGGER_TYPES.each do |type|
        queue = NpcAnimationQueue.new(
          character_instance_id: npc_instance.id,
          room_id: room.id,
          trigger_type: type,
          status: 'pending'
        )
        expect(queue.valid?).to be true
      end
    end

    it 'accepts valid statuses' do
      NpcAnimationQueue::STATUSES.each do |status|
        queue = NpcAnimationQueue.new(
          character_instance_id: npc_instance.id,
          room_id: room.id,
          trigger_type: 'high_turn',
          status: status
        )
        expect(queue.valid?).to be true
      end
    end
  end

  describe 'status helpers' do
    let(:queue) { create_queue }

    it '#pending? returns true for pending status' do
      queue.update(status: 'pending')
      expect(queue.pending?).to be true
      expect(queue.processing?).to be false
    end

    it '#processing? returns true for processing status' do
      queue.update(status: 'processing')
      expect(queue.processing?).to be true
      expect(queue.pending?).to be false
    end

    it '#complete? returns true for complete status' do
      queue.update(status: 'complete')
      expect(queue.complete?).to be true
    end

    it '#failed? returns true for failed status' do
      queue.update(status: 'failed')
      expect(queue.failed?).to be true
    end
  end

  describe 'status transitions' do
    let(:queue) { create_queue }

    it '#start_processing! changes status to processing' do
      queue.start_processing!
      expect(queue.status).to eq 'processing'
    end

    it '#start_processing! returns false when already claimed' do
      expect(queue.start_processing!).to be true
      expect(queue.start_processing!).to be false
    end

    it '#complete! changes status to complete and sets response' do
      queue.complete!('NPC nods politely.')
      expect(queue.status).to eq 'complete'
      expect(queue.llm_response).to eq 'NPC nods politely.'
      expect(queue.processed_at).not_to be_nil
    end

    it '#fail! changes status to failed and sets error' do
      queue.fail!('API error occurred')
      expect(queue.status).to eq 'failed'
      expect(queue.error_message).to eq 'API error occurred'
      expect(queue.processed_at).not_to be_nil
    end
  end

  describe '.pending_ready' do
    before do
      # Create pending entries
      @ready = create_queue(scheduled_at: Time.now - 10)
      @not_ready = create_queue(scheduled_at: Time.now + 60)
      @processing = create_queue(status: 'processing')
    end

    it 'returns only pending entries that are ready' do
      result = described_class.pending_ready
      expect(result).to include(@ready)
      expect(result).not_to include(@not_ready)
      expect(result).not_to include(@processing)
    end

    it 'respects limit parameter' do
      create_queue(scheduled_at: Time.now - 5)

      result = described_class.pending_ready(limit: 1)
      expect(result.size).to eq 1
    end

    it 'orders by priority then scheduled_at' do
      high_priority = create_queue(scheduled_at: Time.now - 5, priority: 1)

      result = described_class.pending_ready
      expect(result.first).to eq high_priority
    end
  end

  describe '.pending_count_for_room' do
    it 'counts pending entries for a specific room' do
      create_queue(status: 'pending')
      create_queue(status: 'pending')
      create_queue(status: 'complete')

      expect(described_class.pending_count_for_room(room.id)).to eq 2
    end
  end

  describe '.recent_complete_count_for_room' do
    it 'counts recently completed entries for a specific room' do
      create_queue(status: 'complete', processed_at: Time.now - 30)
      create_queue(status: 'complete', processed_at: Time.now - 120)

      expect(described_class.recent_complete_count_for_room(room.id)).to eq 1
    end
  end

  describe '.cleanup_old_entries' do
    it 'deletes old completed entries' do
      old_entry = create_queue(status: 'complete', processed_at: Time.now - 7200)
      recent_entry = create_queue(status: 'complete', processed_at: Time.now - 60)

      described_class.cleanup_old_entries

      expect(described_class[old_entry.id]).to be_nil
      expect(described_class[recent_entry.id]).not_to be_nil
    end
  end

  describe '.cancel_for_instance' do
    it 'marks pending entries as failed' do
      pending_entry = create_queue(status: 'pending')
      processing_entry = create_queue(status: 'processing')

      described_class.cancel_for_instance(npc_instance.id)

      pending_entry.refresh
      processing_entry.refresh

      expect(pending_entry.status).to eq 'failed'
      expect(pending_entry.error_message).to include 'Cancelled'
      expect(processing_entry.status).to eq 'processing'
    end
  end

  describe '.queue_response' do
    it 'creates a new pending queue entry' do
      entry = described_class.queue_response(
        npc_instance: npc_instance,
        trigger_type: 'high_turn',
        content: 'Hello merchant!',
        source_id: 123
      )

      expect(entry.id).not_to be_nil
      expect(entry.status).to eq 'pending'
      expect(entry.trigger_type).to eq 'high_turn'
      expect(entry.trigger_content).to eq 'Hello merchant!'
      expect(entry.trigger_source_id).to eq 123
    end

    it 'sets scheduled_at with delay' do
      before_time = Time.now
      entry = described_class.queue_response(
        npc_instance: npc_instance,
        trigger_type: 'high_turn',
        content: 'Hello!',
        delay_seconds: 5
      )

      expect(entry.scheduled_at).to be > before_time + 4
      expect(entry.scheduled_at).to be < before_time + 6
    end

    it 'sets priority' do
      entry = described_class.queue_response(
        npc_instance: npc_instance,
        trigger_type: 'high_turn',
        content: 'Hello!',
        priority: 3
      )

      expect(entry.priority).to eq 3
    end
  end

  describe 'constants' do
    it 'defines TRIGGER_TYPES' do
      expect(described_class::TRIGGER_TYPES).to include(
        'high_turn', 'medium_mention', 'medium_rng', 'low_mention'
      )
    end

    it 'defines STATUSES' do
      expect(described_class::STATUSES).to include(
        'pending', 'processing', 'complete', 'failed'
      )
    end
  end
end
