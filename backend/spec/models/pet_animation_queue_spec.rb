# frozen_string_literal: true

require 'spec_helper'

RSpec.describe PetAnimationQueue do
  let(:item) { create(:item) }
  let(:room) { create(:room) }
  let(:character_instance) { create(:character_instance) }

  # Factory for creating valid queue entries
  def create_queue_entry(attrs = {})
    entry = PetAnimationQueue.new
    entry.item = attrs[:item] || item
    entry.room = attrs[:room] || room
    entry.trigger_type = attrs[:trigger_type] || 'idle_animation'
    entry.status = attrs[:status] || 'pending'
    entry.owner_instance = attrs[:owner_instance] if attrs[:owner_instance]
    entry.save
    entry
  end

  # Build a queue entry without saving
  def build_queue_entry(attrs = {})
    entry = PetAnimationQueue.new
    entry.item = attrs[:item] || item
    entry.room = attrs[:room] || room
    entry.trigger_type = attrs[:trigger_type] || 'idle_animation'
    entry.status = attrs[:status] || 'pending'
    entry.owner_instance = attrs[:owner_instance] if attrs[:owner_instance]
    entry
  end

  describe 'associations' do
    it 'belongs to item' do
      queue_entry = create_queue_entry
      expect(queue_entry.item.id).to eq(item.id)
    end

    it 'belongs to room' do
      queue_entry = create_queue_entry
      expect(queue_entry.room.id).to eq(room.id)
    end

    it 'belongs to owner_instance' do
      queue_entry = create_queue_entry(owner_instance: character_instance)
      expect(queue_entry.owner_instance.id).to eq(character_instance.id)
    end
  end

  describe 'validations' do
    it 'requires item_id' do
      entry = PetAnimationQueue.new
      entry.room = room
      entry.trigger_type = 'idle_animation'
      entry.status = 'pending'
      expect(entry.valid?).to be false
      expect(entry.errors[:item_id]).not_to be_empty
    end

    it 'requires room_id' do
      entry = PetAnimationQueue.new
      entry.item = item
      entry.trigger_type = 'idle_animation'
      entry.status = 'pending'
      expect(entry.valid?).to be false
      expect(entry.errors[:room_id]).not_to be_empty
    end

    it 'requires trigger_type' do
      entry = PetAnimationQueue.new
      entry.item = item
      entry.room = room
      entry.status = 'pending'
      expect(entry.valid?).to be false
      expect(entry.errors[:trigger_type]).not_to be_empty
    end

    it 'requires status' do
      entry = PetAnimationQueue.new
      entry.item = item
      entry.room = room
      entry.trigger_type = 'idle_animation'
      expect(entry.valid?).to be false
      expect(entry.errors[:status]).not_to be_empty
    end

    it 'validates trigger_type is in TRIGGER_TYPES' do
      entry = build_queue_entry(trigger_type: 'invalid')
      expect(entry.valid?).to be false
      expect(entry.errors[:trigger_type]).not_to be_empty
    end

    it 'validates status is in STATUSES' do
      entry = build_queue_entry(status: 'invalid')
      expect(entry.valid?).to be false
      expect(entry.errors[:status]).not_to be_empty
    end

    %w[broadcast_reaction idle_animation].each do |type|
      it "accepts #{type} as trigger_type" do
        entry = build_queue_entry(trigger_type: type)
        expect(entry.valid?).to be true
      end
    end

    %w[pending processing complete failed].each do |status|
      it "accepts #{status} as status" do
        entry = build_queue_entry(status: status)
        expect(entry.valid?).to be true
      end
    end
  end

  describe '#before_create' do
    it 'sets scheduled_at if not provided' do
      freeze_time = Time.now
      allow(Time).to receive(:now).and_return(freeze_time)

      queue_entry = create_queue_entry

      expect(queue_entry.scheduled_at).to be_within(1).of(freeze_time)
    end

    it 'preserves scheduled_at if provided' do
      custom_time = Time.now + 300
      entry = build_queue_entry
      entry.scheduled_at = custom_time
      entry.save

      expect(entry.scheduled_at).to be_within(1).of(custom_time)
    end
  end

  describe 'status helpers' do
    let(:queue_entry) { create_queue_entry }

    describe '#pending?' do
      it 'returns true when status is pending' do
        expect(queue_entry.pending?).to be true
      end

      it 'returns false otherwise' do
        queue_entry.update(status: 'processing')
        expect(queue_entry.pending?).to be false
      end
    end

    describe '#processing?' do
      it 'returns true when status is processing' do
        queue_entry.update(status: 'processing')
        expect(queue_entry.processing?).to be true
      end

      it 'returns false otherwise' do
        expect(queue_entry.processing?).to be false
      end
    end

    describe '#complete?' do
      it 'returns true when status is complete' do
        queue_entry.update(status: 'complete')
        expect(queue_entry.complete?).to be true
      end

      it 'returns false otherwise' do
        expect(queue_entry.complete?).to be false
      end
    end

    describe '#failed?' do
      it 'returns true when status is failed' do
        queue_entry.update(status: 'failed')
        expect(queue_entry.failed?).to be true
      end

      it 'returns false otherwise' do
        expect(queue_entry.failed?).to be false
      end
    end
  end

  describe 'state transitions' do
    let(:queue_entry) { create_queue_entry }

    describe '#start_processing!' do
      it 'sets status to processing' do
        queue_entry.start_processing!
        queue_entry.refresh

        expect(queue_entry.status).to eq('processing')
      end
    end

    describe '#complete!' do
      it 'sets status to complete' do
        queue_entry.complete!('The pet meows happily.')
        queue_entry.refresh

        expect(queue_entry.status).to eq('complete')
      end

      it 'stores llm_response' do
        queue_entry.complete!('The pet meows happily.')
        queue_entry.refresh

        expect(queue_entry.llm_response).to eq('The pet meows happily.')
      end

      it 'sets processed_at' do
        queue_entry.complete!('Response')
        queue_entry.refresh

        expect(queue_entry.processed_at).not_to be_nil
      end
    end

    describe '#fail!' do
      it 'sets status to failed' do
        queue_entry.fail!('API timeout')
        queue_entry.refresh

        expect(queue_entry.status).to eq('failed')
      end

      it 'stores error_message' do
        queue_entry.fail!('API timeout')
        queue_entry.refresh

        expect(queue_entry.error_message).to eq('API timeout')
      end

      it 'sets processed_at' do
        queue_entry.fail!('Error')
        queue_entry.refresh

        expect(queue_entry.processed_at).not_to be_nil
      end
    end
  end

  describe '.pending_ready' do
    let!(:ready_entry) do
      entry = create_queue_entry
      entry.update(scheduled_at: Time.now - 60)
      entry
    end

    let!(:future_entry) do
      entry = create_queue_entry
      entry.update(scheduled_at: Time.now + 60)
      entry
    end

    let!(:processing_entry) do
      entry = create_queue_entry
      entry.update(status: 'processing', scheduled_at: Time.now - 60)
      entry
    end

    it 'returns pending entries with scheduled_at <= now' do
      results = PetAnimationQueue.pending_ready

      expect(results).to include(ready_entry)
      expect(results).not_to include(future_entry)
      expect(results).not_to include(processing_entry)
    end

    it 'limits results' do
      # Create more ready entries
      3.times do
        entry = create_queue_entry
        entry.update(scheduled_at: Time.now - 60)
      end

      results = PetAnimationQueue.pending_ready(limit: 2)
      expect(results.length).to eq(2)
    end

    it 'orders by scheduled_at' do
      earlier = create_queue_entry
      earlier.update(scheduled_at: Time.now - 120)

      results = PetAnimationQueue.pending_ready
      expect(results.first.id).to eq(earlier.id)
    end
  end

  describe '.recent_count_for_room' do
    it 'counts complete entries within window' do
      3.times do
        entry = create_queue_entry
        entry.update(status: 'complete', processed_at: Time.now - 30)
      end

      count = PetAnimationQueue.recent_count_for_room(room.id, window_seconds: 60)
      expect(count).to eq(3)
    end

    it 'does not count entries outside window' do
      entry = create_queue_entry
      entry.update(status: 'complete', processed_at: Time.now - 120)

      count = PetAnimationQueue.recent_count_for_room(room.id, window_seconds: 60)
      expect(count).to eq(0)
    end

    it 'does not count entries for other rooms' do
      other_room = create(:room)
      entry = create_queue_entry(room: other_room)
      entry.update(status: 'complete', processed_at: Time.now - 30)

      count = PetAnimationQueue.recent_count_for_room(room.id, window_seconds: 60)
      expect(count).to eq(0)
    end
  end

  describe '.recent_count_for_pet' do
    it 'counts complete entries within window' do
      3.times do
        entry = create_queue_entry
        entry.update(status: 'complete', processed_at: Time.now - 60)
      end

      count = PetAnimationQueue.recent_count_for_pet(item.id, window_seconds: 120)
      expect(count).to eq(3)
    end

    it 'does not count entries for other pets' do
      other_item = create(:item)
      entry = create_queue_entry(item: other_item)
      entry.update(status: 'complete', processed_at: Time.now - 60)

      count = PetAnimationQueue.recent_count_for_pet(item.id, window_seconds: 120)
      expect(count).to eq(0)
    end
  end

  describe '.cleanup_old_entries' do
    it 'deletes old completed entries' do
      old_entry = create_queue_entry
      old_entry.update(status: 'complete', processed_at: Time.now - 7200)

      deleted_count = PetAnimationQueue.cleanup_old_entries(older_than: 3600)

      expect(deleted_count).to eq(1)
      expect(PetAnimationQueue[old_entry.id]).to be_nil
    end

    it 'deletes old failed entries' do
      old_entry = create_queue_entry
      old_entry.update(status: 'failed', processed_at: Time.now - 7200)

      PetAnimationQueue.cleanup_old_entries(older_than: 3600)

      expect(PetAnimationQueue[old_entry.id]).to be_nil
    end

    it 'does not delete recent entries' do
      recent_entry = create_queue_entry
      recent_entry.update(status: 'complete', processed_at: Time.now - 1800)

      PetAnimationQueue.cleanup_old_entries(older_than: 3600)

      expect(PetAnimationQueue[recent_entry.id]).not_to be_nil
    end

    it 'does not delete pending entries' do
      pending_entry = create_queue_entry

      PetAnimationQueue.cleanup_old_entries(older_than: 0)

      expect(PetAnimationQueue[pending_entry.id]).not_to be_nil
    end
  end

  describe '.queue_animation' do
    it 'creates a pending entry' do
      entry = PetAnimationQueue.queue_animation(
        pet: item,
        room_id: room.id,
        trigger_type: 'idle_animation'
      )

      expect(entry.item.id).to eq(item.id)
      expect(entry.room.id).to eq(room.id)
      expect(entry.trigger_type).to eq('idle_animation')
      expect(entry.status).to eq('pending')
    end

    it 'stores trigger_content' do
      entry = PetAnimationQueue.queue_animation(
        pet: item,
        room_id: room.id,
        trigger_type: 'broadcast_reaction',
        trigger_content: 'Someone says, "Hello there!"'
      )

      expect(entry.trigger_content).to eq('Someone says, "Hello there!"')
    end

    it 'stores owner_instance' do
      entry = PetAnimationQueue.queue_animation(
        pet: item,
        room_id: room.id,
        trigger_type: 'idle_animation',
        owner_instance: character_instance
      )

      expect(entry.owner_instance.id).to eq(character_instance.id)
    end

    it 'sets scheduled_at to now' do
      freeze_time = Time.now
      allow(Time).to receive(:now).and_return(freeze_time)

      entry = PetAnimationQueue.queue_animation(
        pet: item,
        room_id: room.id,
        trigger_type: 'idle_animation'
      )

      expect(entry.scheduled_at).to be_within(1).of(freeze_time)
    end
  end
end
