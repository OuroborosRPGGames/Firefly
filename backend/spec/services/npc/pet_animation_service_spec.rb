# frozen_string_literal: true

require 'spec_helper'

RSpec.describe PetAnimationService do
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }
  let(:room) { create(:room) }
  let(:character_instance) do
    create(:character_instance, character: character, current_room: room, online: true)
  end

  # Mock pet item
  let(:pet) do
    item = double('Item',
                  id: 1,
                  name: 'Fluffy',
                  is_pet_instance: true,
                  held: true,
                  pet?: true,
                  owner_instance: character_instance,
                  owner_name: character.full_name,
                  pet_description: 'A fluffy orange cat',
                  pet_sounds: 'meows, purrs, hisses',
                  recent_emote_context: 'Previous emote context')
    allow(item).to receive(:pet_on_cooldown?).and_return(false)
    allow(item).to receive(:add_emote_to_history)
    allow(item).to receive(:update_pet_animation_time!)
    item
  end

  # Mock queue entry with all required methods
  let(:queue_entry) do
    entry = double('PetAnimationQueue',
                   id: 1,
                   item: pet,
                   room_id: room.id,
                   trigger_content: 'Hello there')
    allow(entry).to receive(:start_processing!)
    allow(entry).to receive(:fail!)
    allow(entry).to receive(:complete!)
    entry
  end

  before do
    # Mock BroadcastService
    allow(BroadcastService).to receive(:to_room)

    # Mock LLM::Client
    allow(LLM::Client).to receive(:generate).and_return({
      success: true,
      text: 'Fluffy stretches lazily and yawns.'
    })

    # Mock GamePrompts
    allow(GamePrompts).to receive(:get).and_return('Mocked prompt for pet animation')
  end

  describe 'module structure' do
    it 'defines a module' do
      expect(described_class).to be_a(Module)
    end
  end

  describe 'constants' do
    it 'defines PET_COOLDOWN_SECONDS' do
      expect(described_class::PET_COOLDOWN_SECONDS).to be_a(Integer)
    end

    it 'defines MAX_ROOM_ANIMATIONS_PER_MINUTE' do
      expect(described_class::MAX_ROOM_ANIMATIONS_PER_MINUTE).to be_a(Integer)
    end

    it 'defines IDLE_MIN_SECONDS' do
      expect(described_class::IDLE_MIN_SECONDS).to be_a(Integer)
    end

    it 'defines IDLE_MAX_SECONDS' do
      expect(described_class::IDLE_MAX_SECONDS).to be_a(Integer)
    end

    it 'has reasonable cooldown value' do
      expect(described_class::PET_COOLDOWN_SECONDS).to be >= 60
    end

    it 'has reasonable room animation limit' do
      expect(described_class::MAX_ROOM_ANIMATIONS_PER_MINUTE).to be >= 1
      expect(described_class::MAX_ROOM_ANIMATIONS_PER_MINUTE).to be <= 10
    end
  end

  describe '.process_room_broadcast' do
    context 'when room_id is nil' do
      it 'returns early' do
        result = described_class.process_room_broadcast(
          room_id: nil,
          content: 'test',
          sender_instance: character_instance,
          type: :say
        )
        expect(result).to be_nil
      end
    end

    context 'when content is nil' do
      it 'returns early' do
        result = described_class.process_room_broadcast(
          room_id: room.id,
          content: nil,
          sender_instance: character_instance,
          type: :say
        )
        expect(result).to be_nil
      end
    end

    context 'when type is not IC content' do
      %i[system ooc whisper private].each do |type|
        it "returns early for #{type} messages" do
          allow(Item).to receive(:pets_held_in_room).and_return(double(all: [pet]))

          described_class.process_room_broadcast(
            room_id: room.id,
            content: 'Hello there',
            sender_instance: character_instance,
            type: type
          )

          # Should not process pets for non-IC content
          expect(pet).not_to have_received(:add_emote_to_history)
        end
      end
    end

    context 'when type is IC content' do
      %i[say emote pose action].each do |type|
        it "processes pets for #{type} messages" do
          allow(Item).to receive(:pets_held_in_room).and_return(double(all: [pet]))
          allow(PetAnimationQueue).to receive(:queue_animation).and_return(queue_entry)
          allow(PetAnimationQueue).to receive(:recent_count_for_room).and_return(0)

          # Stub thread creation to avoid async issues in test
          allow(Thread).to receive(:new).and_yield

          described_class.process_room_broadcast(
            room_id: room.id,
            content: 'Hello there',
            sender_instance: character_instance,
            type: type
          )

          expect(pet).to have_received(:add_emote_to_history).with('Hello there')
        end
      end
    end

    context 'when no pets in room' do
      before do
        allow(Item).to receive(:pets_held_in_room).and_return(double(all: []))
      end

      it 'returns early' do
        result = described_class.process_room_broadcast(
          room_id: room.id,
          content: 'Hello',
          sender_instance: character_instance,
          type: :say
        )

        expect(result).to be_nil
      end
    end

    context 'when pet is on cooldown' do
      before do
        allow(Item).to receive(:pets_held_in_room).and_return(double(all: [pet]))
        allow(pet).to receive(:pet_on_cooldown?).and_return(true)
      end

      it 'does not queue animation' do
        expect(PetAnimationQueue).not_to receive(:queue_animation)

        described_class.process_room_broadcast(
          room_id: room.id,
          content: 'Hello',
          sender_instance: character_instance,
          type: :say
        )
      end
    end

    context 'when room rate limit is exceeded' do
      before do
        allow(Item).to receive(:pets_held_in_room).and_return(double(all: [pet]))
        allow(PetAnimationQueue).to receive(:recent_count_for_room).and_return(100)
      end

      it 'does not queue animation' do
        expect(PetAnimationQueue).not_to receive(:queue_animation)

        described_class.process_room_broadcast(
          room_id: room.id,
          content: 'Hello',
          sender_instance: character_instance,
          type: :say
        )
      end
    end
  end

  describe '.process_idle_animations!' do
    # Build the chain mock: where -> exclude -> where -> join -> where -> select_all -> all
    def build_pet_query_mock(pets)
      mock_chain = double('QueryChain')
      allow(mock_chain).to receive(:exclude).and_return(mock_chain)
      allow(mock_chain).to receive(:where).and_return(mock_chain)
      allow(mock_chain).to receive(:join).and_return(mock_chain)
      allow(mock_chain).to receive(:select_all).and_return(mock_chain)
      allow(mock_chain).to receive(:all).and_return(pets)
      mock_chain
    end

    context 'when no active pets' do
      before do
        allow(Item).to receive(:where).and_return(build_pet_query_mock([]))
      end

      it 'returns zero counts' do
        result = described_class.process_idle_animations!

        expect(result[:queued]).to eq(0)
        expect(result[:skipped]).to eq(0)
      end
    end

    context 'when pets are active' do
      before do
        allow(Item).to receive(:where).and_return(build_pet_query_mock([pet]))
        allow(pet).to receive(:owner_instance).and_return(character_instance)
        allow(character_instance).to receive(:current_room_id).and_return(room.id)
        allow(PetAnimationQueue).to receive(:recent_count_for_room).and_return(0)
        allow(PetAnimationQueue).to receive(:queue_animation).and_return(queue_entry)
        allow(Thread).to receive(:new).and_yield
      end

      it 'queues animation for each pet' do
        result = described_class.process_idle_animations!

        expect(result[:queued]).to eq(1)
      end

      context 'when pet owner is offline' do
        before do
          allow(pet).to receive(:owner_instance).and_return(double(online: false))
        end

        it 'skips the pet' do
          result = described_class.process_idle_animations!

          expect(result[:skipped]).to eq(1)
          expect(result[:queued]).to eq(0)
        end
      end

      context 'when pet is on cooldown' do
        before do
          allow(pet).to receive(:pet_on_cooldown?).and_return(true)
        end

        it 'skips the pet' do
          result = described_class.process_idle_animations!

          expect(result[:skipped]).to eq(1)
        end
      end
    end
  end

  describe '.process_queue!' do
    context 'when queue is empty' do
      before do
        allow(PetAnimationQueue).to receive(:pending_ready).and_return([])
      end

      it 'returns zero counts' do
        result = described_class.process_queue!

        expect(result[:processed]).to eq(0)
        expect(result[:failed]).to eq(0)
      end
    end

    context 'when queue has entries' do
      let(:queue_entry) do
        entry = double('PetAnimationQueue',
                       id: 1,
                       item: pet,
                       room_id: room.id,
                       trigger_content: 'Someone said hello')
        allow(entry).to receive(:start_processing!)
        allow(entry).to receive(:complete!)
        allow(entry).to receive(:fail!)
        entry
      end

      before do
        allow(PetAnimationQueue).to receive(:pending_ready).and_return([queue_entry])
        allow(PetAnimationQueue).to receive(:cleanup_old_entries)
        allow(pet).to receive(:owner_instance).and_return(character_instance)
      end

      it 'processes each entry' do
        result = described_class.process_queue!

        expect(result[:processed]).to eq(1)
      end

      it 'calls cleanup after processing' do
        described_class.process_queue!

        expect(PetAnimationQueue).to have_received(:cleanup_old_entries)
      end

      context 'when pet is no longer active' do
        before do
          allow(pet).to receive(:pet?).and_return(false)
        end

        it 'fails the entry' do
          described_class.process_queue!

          expect(queue_entry).to have_received(:fail!).with(/no longer active/)
        end

        it 'counts as failed' do
          result = described_class.process_queue!

          expect(result[:failed]).to eq(1)
        end
      end

      context 'when owner is offline' do
        before do
          allow(pet).to receive(:owner_instance).and_return(double(online: false))
        end

        it 'fails the entry' do
          described_class.process_queue!

          expect(queue_entry).to have_received(:fail!).with(/no longer active/)
        end
      end

      context 'when LLM generation fails' do
        before do
          allow(LLM::Client).to receive(:generate).and_return({
            success: false,
            error: 'API timeout'
          })
        end

        it 'fails the entry' do
          described_class.process_queue!

          expect(queue_entry).to have_received(:fail!)
        end
      end

      context 'when LLM generation succeeds' do
        before do
          allow(LLM::Client).to receive(:generate).and_return({
            success: true,
            text: 'Fluffy purrs contentedly.'
          })
        end

        it 'completes the entry' do
          described_class.process_queue!

          expect(queue_entry).to have_received(:complete!)
        end

        it 'broadcasts to room' do
          described_class.process_queue!

          expect(BroadcastService).to have_received(:to_room).with(
            room.id,
            hash_including(:content),
            hash_including(type: :emote)
          )
        end

        it 'updates pet animation time' do
          described_class.process_queue!

          expect(pet).to have_received(:update_pet_animation_time!)
        end
      end
    end
  end

  describe 'private method behavior' do
    describe 'can_animate?' do
      # Tested through process_room_broadcast

      it 'respects per-pet cooldown' do
        allow(Item).to receive(:pets_held_in_room).and_return(double(all: [pet]))
        allow(pet).to receive(:pet_on_cooldown?).and_return(true)
        expect(PetAnimationQueue).not_to receive(:queue_animation)

        described_class.process_room_broadcast(
          room_id: room.id,
          content: 'Hello',
          sender_instance: character_instance,
          type: :say
        )
      end

      it 'respects room rate limit' do
        allow(Item).to receive(:pets_held_in_room).and_return(double(all: [pet]))
        allow(PetAnimationQueue).to receive(:recent_count_for_room).and_return(1000)
        expect(PetAnimationQueue).not_to receive(:queue_animation)

        described_class.process_room_broadcast(
          room_id: room.id,
          content: 'Hello',
          sender_instance: character_instance,
          type: :say
        )
      end
    end

    describe 'generate_pet_emote' do
      # Tested via process_queue!

      it 'uses LLM client with haiku model' do
        queue_entry = double('PetAnimationQueue',
                             id: 1,
                             item: pet,
                             room_id: room.id,
                             trigger_content: nil)
        allow(queue_entry).to receive(:start_processing!)
        allow(queue_entry).to receive(:complete!)
        allow(PetAnimationQueue).to receive(:pending_ready).and_return([queue_entry])
        allow(PetAnimationQueue).to receive(:cleanup_old_entries)

        described_class.process_queue!

        expect(LLM::Client).to have_received(:generate).with(
          hash_including(
            model: 'claude-haiku-4-5-20251001',
            provider: 'anthropic'
          )
        )
      end
    end

    describe 'clean_pet_emote' do
      # Test the cleaning logic via process_queue!

      context 'when LLM returns quoted speech' do
        before do
          allow(LLM::Client).to receive(:generate).and_return({
            success: true,
            text: 'Fluffy says "Meow!" and stretches.'
          })
        end

        it 'removes quoted speech' do
          queue_entry = double('PetAnimationQueue',
                               id: 1,
                               item: pet,
                               room_id: room.id,
                               trigger_content: nil)
          allow(queue_entry).to receive(:start_processing!)
          allow(queue_entry).to receive(:complete!)
          allow(PetAnimationQueue).to receive(:pending_ready).and_return([queue_entry])
          allow(PetAnimationQueue).to receive(:cleanup_old_entries)

          described_class.process_queue!

          expect(queue_entry).to have_received(:complete!) do |text|
            expect(text).not_to include('"Meow!"')
          end
        end
      end

      context 'when LLM returns parenthetical notes' do
        before do
          allow(LLM::Client).to receive(:generate).and_return({
            success: true,
            text: 'Fluffy stretches (indicating contentment).'
          })
        end

        it 'removes parenthetical notes' do
          queue_entry = double('PetAnimationQueue',
                               id: 1,
                               item: pet,
                               room_id: room.id,
                               trigger_content: nil)
          allow(queue_entry).to receive(:start_processing!)
          allow(queue_entry).to receive(:complete!)
          allow(PetAnimationQueue).to receive(:pending_ready).and_return([queue_entry])
          allow(PetAnimationQueue).to receive(:cleanup_old_entries)

          described_class.process_queue!

          expect(queue_entry).to have_received(:complete!) do |text|
            expect(text).not_to include('indicating contentment')
          end
        end
      end
    end

    describe 'build_pet_prompt' do
      # Tested via process_queue!

      it 'uses GamePrompts for pet animation' do
        queue_entry = double('PetAnimationQueue',
                             id: 1,
                             item: pet,
                             room_id: room.id,
                             trigger_content: 'Hello everyone!')
        allow(queue_entry).to receive(:start_processing!)
        allow(queue_entry).to receive(:complete!)
        allow(PetAnimationQueue).to receive(:pending_ready).and_return([queue_entry])
        allow(PetAnimationQueue).to receive(:cleanup_old_entries)

        described_class.process_queue!

        expect(GamePrompts).to have_received(:get).with(
          'pet_animation.emote',
          hash_including(
            pet_name: 'Fluffy',
            pet_desc: 'A fluffy orange cat',
            owner_name: character.full_name,
            pet_sounds: 'meows, purrs, hisses'
          )
        )
      end
    end

    describe 'broadcast_pet_emote' do
      # Tested via process_queue!

      it 'broadcasts emote to room' do
        queue_entry = double('PetAnimationQueue',
                             id: 1,
                             item: pet,
                             room_id: room.id,
                             trigger_content: nil)
        allow(queue_entry).to receive(:start_processing!)
        allow(queue_entry).to receive(:complete!)
        allow(PetAnimationQueue).to receive(:pending_ready).and_return([queue_entry])
        allow(PetAnimationQueue).to receive(:cleanup_old_entries)

        described_class.process_queue!

        expect(BroadcastService).to have_received(:to_room).with(
          room.id,
          hash_including(:content, :html),
          hash_including(type: :emote, sender_instance: character_instance)
        )
      end
    end
  end

  describe 'error handling' do
    context 'when async processing fails' do
      let(:queue_entry) do
        entry = double('PetAnimationQueue',
                       id: 1,
                       item: pet,
                       room_id: room.id,
                       trigger_content: nil)
        allow(entry).to receive(:start_processing!)
        allow(entry).to receive(:fail!)
        entry
      end

      before do
        allow(Item).to receive(:pets_held_in_room).and_return(double(all: [pet]))
        allow(PetAnimationQueue).to receive(:queue_animation).and_return(queue_entry)
        allow(PetAnimationQueue).to receive(:recent_count_for_room).and_return(0)

        # Make Thread.new actually raise an error
        allow(Thread).to receive(:new).and_yield
        allow(queue_entry).to receive(:start_processing!).and_raise(StandardError, 'Processing error')
      end

      it 'fails the entry with error message' do
        described_class.process_room_broadcast(
          room_id: room.id,
          content: 'Hello',
          sender_instance: character_instance,
          type: :say
        )

        expect(queue_entry).to have_received(:fail!).with(/Async error/)
      end
    end

    context 'when LLM client raises exception' do
      let(:queue_entry) do
        entry = double('PetAnimationQueue',
                       id: 1,
                       item: pet,
                       room_id: room.id,
                       trigger_content: nil)
        allow(entry).to receive(:start_processing!)
        allow(entry).to receive(:complete!)
        allow(entry).to receive(:fail!)
        entry
      end

      before do
        allow(LLM::Client).to receive(:generate).and_raise(StandardError, 'Network timeout')
        allow(PetAnimationQueue).to receive(:pending_ready).and_return([queue_entry])
        allow(PetAnimationQueue).to receive(:cleanup_old_entries)
      end

      it 'catches the error and fails entry' do
        expect {
          described_class.process_queue!
        }.not_to raise_error

        expect(queue_entry).to have_received(:fail!)
      end
    end
  end

  describe 'integration scenarios' do
    describe 'multiple pets in same room' do
      let(:pet2) do
        item = double('Item',
                      id: 2,
                      name: 'Spot',
                      is_pet_instance: true,
                      held: true,
                      pet?: true,
                      owner_instance: character_instance,
                      owner_name: character.full_name,
                      pet_description: 'A spotted dalmatian',
                      pet_sounds: 'barks, whines, pants',
                      recent_emote_context: '')
        allow(item).to receive(:pet_on_cooldown?).and_return(false)
        allow(item).to receive(:add_emote_to_history)
        allow(item).to receive(:update_pet_animation_time!)
        item
      end

      before do
        allow(Item).to receive(:pets_held_in_room).and_return(double(all: [pet, pet2]))
        allow(PetAnimationQueue).to receive(:queue_animation).and_return(queue_entry)
        allow(PetAnimationQueue).to receive(:recent_count_for_room).and_return(0)
        allow(Thread).to receive(:new).and_yield
      end

      it 'processes each pet' do
        described_class.process_room_broadcast(
          room_id: room.id,
          content: 'Hello pets!',
          sender_instance: character_instance,
          type: :say
        )

        expect(pet).to have_received(:add_emote_to_history)
        expect(pet2).to have_received(:add_emote_to_history)
      end
    end

    describe 'rate limiting enforcement' do
      it 'allows first pet when under limit' do
        allow(Item).to receive(:pets_held_in_room).and_return(double(all: [pet]))
        allow(PetAnimationQueue).to receive(:queue_animation).and_return(queue_entry)
        allow(PetAnimationQueue).to receive(:recent_count_for_room).and_return(
          described_class::MAX_ROOM_ANIMATIONS_PER_MINUTE - 1
        )
        allow(Thread).to receive(:new).and_yield

        described_class.process_room_broadcast(
          room_id: room.id,
          content: 'Hello',
          sender_instance: character_instance,
          type: :say
        )

        expect(PetAnimationQueue).to have_received(:queue_animation)
      end

      it 'blocks pet when at limit' do
        allow(Item).to receive(:pets_held_in_room).and_return(double(all: [pet]))
        allow(PetAnimationQueue).to receive(:recent_count_for_room).and_return(
          described_class::MAX_ROOM_ANIMATIONS_PER_MINUTE
        )
        expect(PetAnimationQueue).not_to receive(:queue_animation)

        described_class.process_room_broadcast(
          room_id: room.id,
          content: 'Hello',
          sender_instance: character_instance,
          type: :say
        )
      end
    end
  end
end
