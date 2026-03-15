# frozen_string_literal: true

require 'spec_helper'

RSpec.describe NpcAnimationService do
  let(:archetype) { create(:npc_archetype, :animated) }
  let(:npc_character) do
    create(:character, :npc, npc_archetype: archetype, forename: 'Merchant', surname: 'Smith', short_desc: 'weathered trader')
  end
  let(:room) { create(:room, name: 'Market Square', long_description: 'A busy marketplace.') }
  let(:npc_instance) do
    create(:character_instance, character: npc_character, current_room: room, online: true)
  end
  let(:player_character) { create(:character, forename: 'Player') }
  let(:player_instance) do
    create(:character_instance, character: player_character, current_room: room, online: true)
  end

  before do
    allow(NpcAnimationProcessJob).to receive(:perform_async).and_return('jid-npc-animation')
  end

  # Helper to stub LLM responses
  def stub_llm_response(text: 'Test response', success: true)
    allow(LLM::Client).to receive(:generate).and_return({ success: success, text: text })
  end

  describe '.strip_ooc_content' do
    it 'removes (( )) OOC brackets' do
      content = 'Hello there ((this is OOC)) how are you?'
      result = described_class.strip_ooc_content(content)
      expect(result).to eq 'Hello there  how are you?'
    end

    it 'removes [[ ]] OOC brackets' do
      content = 'Hello there [[this is also OOC]] how are you?'
      result = described_class.strip_ooc_content(content)
      expect(result).to eq 'Hello there  how are you?'
    end

    it 'removes multiple OOC sections' do
      content = 'Hello ((OOC1)) there [[OOC2]] friend ((OOC3))'
      result = described_class.strip_ooc_content(content)
      expect(result).to eq 'Hello  there  friend'
    end

    it 'handles nil input' do
      expect(described_class.strip_ooc_content(nil)).to be_nil
    end

    it 'returns empty string for pure OOC message' do
      content = '((This is all OOC))'
      result = described_class.strip_ooc_content(content)
      expect(result).to eq ''
    end
  end

  describe '.mentioned_in_content?' do
    it 'returns true when forename is mentioned' do
      allow(npc_character).to receive(:forename).and_return('Bob')
      result = described_class.mentioned_in_content?(
        npc_instance: npc_instance,
        content: 'Hello Bob, how are you?'
      )
      expect(result).to be true
    end

    it 'returns true when surname is mentioned' do
      allow(npc_character).to receive(:forename).and_return('Bob')
      allow(npc_character).to receive(:surname).and_return('Smith')
      result = described_class.mentioned_in_content?(
        npc_instance: npc_instance,
        content: 'Hello Smith, how are you?'
      )
      expect(result).to be true
    end

    it 'is case-insensitive' do
      allow(npc_character).to receive(:forename).and_return('Bob')
      result = described_class.mentioned_in_content?(
        npc_instance: npc_instance,
        content: 'Hello BOB, how are you?'
      )
      expect(result).to be true
    end

    it 'returns false when not mentioned' do
      allow(npc_character).to receive(:forename).and_return('Bob')
      allow(npc_character).to receive(:surname).and_return('Smith')
      result = described_class.mentioned_in_content?(
        npc_instance: npc_instance,
        content: 'Hello everyone, how are you?'
      )
      expect(result).to be false
    end

    it 'returns false for nil content' do
      result = described_class.mentioned_in_content?(
        npc_instance: npc_instance,
        content: nil
      )
      expect(result).to be false
    end

    it 'returns false for nil instance' do
      result = described_class.mentioned_in_content?(
        npc_instance: nil,
        content: 'Hello Bob'
      )
      expect(result).to be false
    end
  end

  describe '.process_room_broadcast' do
    before do
      # Ensure NPC and player are created and in the room
      npc_instance
      player_instance

      # Stub LLM calls to avoid actual API requests
      allow(LLM::Client).to receive(:generate).and_return(
        { success: true, text: "#{npc_character.forename} nods politely." }
      )
    end

    context 'with high animation level' do
      before do
        archetype.update(animation_level: 'high')
        # Refresh NPC instance to pick up archetype changes
        npc_instance.character.reload
      end

      it 'queues a response for any IC content' do
        expect do
          described_class.process_room_broadcast(
            room_id: room.id,
            content: 'Hello everyone!',
            sender_instance: player_instance,
            type: :say
          )
        end.to change(NpcAnimationQueue, :count).by(1)
      end

      it 'sets trigger_type to high_turn' do
        described_class.process_room_broadcast(
          room_id: room.id,
          content: 'Hello everyone!',
          sender_instance: player_instance,
          type: :say
        )
        expect(NpcAnimationQueue.last.trigger_type).to eq 'high_turn'
      end
    end

    context 'with low animation level' do
      before do
        archetype.update(animation_level: 'low')
        npc_instance.character.reload
      end

      it 'queues a response when NPC is mentioned' do
        expect do
          described_class.process_room_broadcast(
            room_id: room.id,
            content: "Hello #{npc_character.forename}!",
            sender_instance: player_instance,
            type: :say
          )
        end.to change(NpcAnimationQueue, :count).by(1)
      end

      it 'sets trigger_type to low_mention' do
        described_class.process_room_broadcast(
          room_id: room.id,
          content: "Hello #{npc_character.forename}!",
          sender_instance: player_instance,
          type: :say
        )
        expect(NpcAnimationQueue.last.trigger_type).to eq 'low_mention'
      end

      it 'does not queue when NPC is not mentioned' do
        expect do
          described_class.process_room_broadcast(
            room_id: room.id,
            content: 'Hello everyone!',
            sender_instance: player_instance,
            type: :say
          )
        end.not_to change(NpcAnimationQueue, :count)
      end
    end

    context 'with animation off' do
      before do
        archetype.update(animation_level: 'off')
        npc_instance.character.reload
      end

      it 'does not queue any response' do
        expect do
          described_class.process_room_broadcast(
            room_id: room.id,
            content: "Hello #{npc_character.forename}!",
            sender_instance: player_instance,
            type: :say
          )
        end.not_to change(NpcAnimationQueue, :count)
      end
    end

    it 'ignores OOC content' do
      archetype.update(animation_level: 'high')
      npc_instance.character.reload
      expect do
        described_class.process_room_broadcast(
          room_id: room.id,
          content: '((This is all OOC))',
          sender_instance: player_instance,
          type: :say
        )
      end.not_to change(NpcAnimationQueue, :count)
    end

    it 'does not queue for nil room_id' do
      expect do
        described_class.process_room_broadcast(
          room_id: nil,
          content: 'Hello!',
          sender_instance: player_instance,
          type: :say
        )
      end.not_to change(NpcAnimationQueue, :count)
    end

    it 'does not queue for nil sender_instance' do
      expect do
        described_class.process_room_broadcast(
          room_id: room.id,
          content: 'Hello!',
          sender_instance: nil,
          type: :say
        )
      end.not_to change(NpcAnimationQueue, :count)
    end
  end

  describe '.process_queue!' do
    before do
      # Create a pending queue entry
      allow(NpcAnimationHandler).to receive(:call).and_return({ success: true })
    end

    it 'processes pending entries' do
      entry = create(:npc_animation_queue, character_instance: npc_instance, room: room)

      expect(NpcAnimationHandler).to receive(:call).with(entry)
      described_class.process_queue!
    end

    it 'returns results hash with processed count' do
      create(:npc_animation_queue, character_instance: npc_instance, room: room)

      results = described_class.process_queue!
      expect(results[:processed]).to eq 1
      expect(results[:failed]).to eq 0
    end

    it 'increments failed count on failure' do
      create(:npc_animation_queue, character_instance: npc_instance, room: room)
      allow(NpcAnimationHandler).to receive(:call).and_return({ success: false })

      results = described_class.process_queue!
      expect(results[:processed]).to eq 0
      expect(results[:failed]).to eq 1
    end

    it 'cleans up old entries even when no pending entries exist' do
      allow(NpcAnimationQueue).to receive(:cleanup_old_entries)

      described_class.process_queue!

      expect(NpcAnimationQueue).to have_received(:cleanup_old_entries)
    end
  end

  describe 'CONSTANTS' do
    it 'defines MEDIUM_DECAY_FACTOR as 0.5' do
      expect(NpcAnimationService::MEDIUM_DECAY_FACTOR).to eq 0.5
    end

    it 'defines RECENT_WINDOW as 300' do
      expect(NpcAnimationService::RECENT_WINDOW).to eq 300
    end

    it 'defines MAX_RESPONSES_PER_MINUTE as 3' do
      expect(NpcAnimationService::MAX_RESPONSES_PER_MINUTE).to eq 3
    end

    it 'defines OOC_PATTERNS' do
      expect(NpcAnimationService::OOC_PATTERNS).to be_an Array
      expect(NpcAnimationService::OOC_PATTERNS.size).to eq 2
    end
  end

  describe '.generate_spawn_outfit' do
    before do
      npc_instance
      stub_llm_response(text: 'A worn leather apron over simple merchant clothes.')
    end

    context 'when archetype should generate outfit' do
      before do
        allow(archetype).to receive(:should_generate_outfit?).and_return(true)
      end

      it 'returns generated outfit text' do
        result = described_class.generate_spawn_outfit(npc_instance)
        expect(result).to eq 'A worn leather apron over simple merchant clothes.'
      end

      it 'strips whitespace from result' do
        allow(LLM::Client).to receive(:generate).and_return({
          success: true,
          text: "  Fancy outfit  \n"
        })
        result = described_class.generate_spawn_outfit(npc_instance)
        expect(result).to eq 'Fancy outfit'
      end
    end

    context 'when archetype should not generate outfit' do
      before do
        allow(archetype).to receive(:should_generate_outfit?).and_return(false)
      end

      it 'returns nil' do
        result = described_class.generate_spawn_outfit(npc_instance)
        expect(result).to be_nil
      end
    end

    context 'when LLM generation fails' do
      before do
        allow(archetype).to receive(:should_generate_outfit?).and_return(true)
        stub_llm_response(success: false)
      end

      it 'returns nil' do
        result = described_class.generate_spawn_outfit(npc_instance)
        expect(result).to be_nil
      end
    end

    context 'when instance has no archetype' do
      let(:plain_npc) { create(:character, :npc, npc_archetype: nil) }
      let(:plain_instance) { create(:character_instance, character: plain_npc, current_room: room) }

      it 'returns nil' do
        result = described_class.generate_spawn_outfit(plain_instance)
        expect(result).to be_nil
      end
    end
  end

  describe '.generate_spawn_status' do
    before do
      npc_instance
      stub_llm_response(text: 'browsing the market stalls')
    end

    context 'when archetype should generate status' do
      before do
        allow(archetype).to receive(:should_generate_status?).and_return(true)
      end

      it 'returns generated status text' do
        result = described_class.generate_spawn_status(npc_instance)
        expect(result).to eq 'browsing the market stalls'
      end

      it 'truncates to 100 characters' do
        long_text = 'A' * 150
        allow(LLM::Client).to receive(:generate).and_return({ success: true, text: long_text })

        result = described_class.generate_spawn_status(npc_instance)
        expect(result.length).to eq 100
      end
    end

    context 'when archetype should not generate status' do
      before do
        allow(archetype).to receive(:should_generate_status?).and_return(false)
      end

      it 'returns nil' do
        result = described_class.generate_spawn_status(npc_instance)
        expect(result).to be_nil
      end
    end

    context 'when LLM fails' do
      before do
        allow(archetype).to receive(:should_generate_status?).and_return(true)
        stub_llm_response(success: false)
      end

      it 'returns nil' do
        result = described_class.generate_spawn_status(npc_instance)
        expect(result).to be_nil
      end
    end
  end

  describe '.process_room_broadcast with medium level' do
    before do
      archetype.update(animation_level: 'medium')
      npc_instance.character.reload
      player_instance

      allow(LLM::Client).to receive(:generate).and_return({
        success: true,
        text: '{"probability": 0.8}'
      })
      allow(NpcAnimationHandler).to receive(:call).and_return({ success: true })
    end

    context 'when NPC is mentioned' do
      it 'queues a response with trigger_type medium_mention' do
        expect do
          described_class.process_room_broadcast(
            room_id: room.id,
            content: 'Hello Merchant!',
            sender_instance: player_instance,
            type: :say
          )
        end.to change(NpcAnimationQueue, :count).by(1)

        expect(NpcAnimationQueue.last.trigger_type).to eq 'medium_mention'
      end
    end

    context 'when NPC is not mentioned but RNG passes' do
      before do
        allow_any_instance_of(Object).to receive(:rand).and_return(0.1) # Below 0.8 probability
      end

      it 'queues a response with trigger_type medium_rng' do
        expect do
          described_class.process_room_broadcast(
            room_id: room.id,
            content: 'Hello everyone!',
            sender_instance: player_instance,
            type: :say
          )
        end.to change(NpcAnimationQueue, :count).by(1)

        expect(NpcAnimationQueue.last.trigger_type).to eq 'medium_rng'
      end
    end

    context 'when RNG fails' do
      before do
        allow_any_instance_of(Object).to receive(:rand).and_return(0.99) # Above 0.8 probability
      end

      it 'does not queue a response' do
        expect do
          described_class.process_room_broadcast(
            room_id: room.id,
            content: 'Hello everyone!',
            sender_instance: player_instance,
            type: :say
          )
        end.not_to change(NpcAnimationQueue, :count)
      end
    end

    context 'when NPC is on cooldown' do
      before do
        npc_instance.update(last_animation_at: Time.now - 10) # Recent animation
      end

      it 'does not queue unless mentioned' do
        expect do
          described_class.process_room_broadcast(
            room_id: room.id,
            content: 'Hello everyone!',
            sender_instance: player_instance,
            type: :say
          )
        end.not_to change(NpcAnimationQueue, :count)
      end

      it 'queues when mentioned even on cooldown' do
        expect do
          described_class.process_room_broadcast(
            room_id: room.id,
            content: 'Hello Merchant!',
            sender_instance: player_instance,
            type: :say
          )
        end.to change(NpcAnimationQueue, :count).by(1)
      end
    end

    context 'when probability is zero' do
      before do
        allow(LLM::Client).to receive(:generate).and_return({
          success: true,
          text: '{"probability": 0}'
        })
      end

      it 'does not queue a response' do
        expect do
          described_class.process_room_broadcast(
            room_id: room.id,
            content: 'Hello everyone!',
            sender_instance: player_instance,
            type: :say
          )
        end.not_to change(NpcAnimationQueue, :count)
      end
    end
  end

  describe 'anti-spam guards' do
    before do
      archetype.update(animation_level: 'high')
      npc_instance.character.reload
      player_instance
      allow(NpcAnimationHandler).to receive(:call).and_return({ success: true })
    end

    context 'when sender is an NPC' do
      let(:other_npc_char) { create(:character, :npc, forename: 'OtherNPC') }
      let(:other_npc_instance) { create(:character_instance, character: other_npc_char, current_room: room, online: true) }

      it 'does not queue response to prevent NPC ping-pong' do
        expect do
          described_class.process_room_broadcast(
            room_id: room.id,
            content: 'Hello from NPC!',
            sender_instance: other_npc_instance,
            type: :say
          )
        end.not_to change(NpcAnimationQueue, :count)
      end
    end

    context 'when NPC has exceeded hourly limit' do
      before do
        # Create many completed queue entries in the last hour
        (NpcAnimationService::MAX_NPC_RESPONSES_PER_HOUR + 1).times do
          create(:npc_animation_queue,
            character_instance: npc_instance,
            room: room,
            status: 'complete',
            processed_at: Time.now - 1800)
        end
      end

      it 'does not queue a response' do
        expect do
          described_class.process_room_broadcast(
            room_id: room.id,
            content: 'Hello!',
            sender_instance: player_instance,
            type: :say
          )
        end.not_to change(NpcAnimationQueue, :count)
      end
    end

    context 'when room rate limit is exceeded' do
      before do
        # Fill up the room's pending queue
        NpcAnimationService::MAX_RESPONSES_PER_MINUTE.times do
          create(:npc_animation_queue, character_instance: npc_instance, room: room, status: 'pending')
        end
      end

      it 'does not queue more responses' do
        expect do
          described_class.process_room_broadcast(
            room_id: room.id,
            content: 'Hello!',
            sender_instance: player_instance,
            type: :say
          )
        end.not_to change(NpcAnimationQueue, :count)
      end
    end
  end

  describe 'private methods' do
    describe '#find_animated_npcs_in_room' do
      before do
        npc_instance
        player_instance
      end

      it 'finds animated NPCs' do
        result = described_class.send(:find_animated_npcs_in_room, room.id)
        expect(result).to include(npc_instance)
      end

      it 'excludes specified id' do
        result = described_class.send(:find_animated_npcs_in_room, room.id, exclude_id: npc_instance.id)
        expect(result).not_to include(npc_instance)
      end

      it 'excludes player characters' do
        result = described_class.send(:find_animated_npcs_in_room, room.id)
        expect(result).not_to include(player_instance)
      end

      it 'excludes NPCs with animation off' do
        archetype.update(animation_level: 'off')
        npc_instance.character.reload
        result = described_class.send(:find_animated_npcs_in_room, room.id)
        expect(result).not_to include(npc_instance)
      end
    end

    describe '#count_recent_room_animators' do
      before { npc_instance }

      it 'returns 0 when no recent animations' do
        count = described_class.send(:count_recent_room_animators, room.id)
        expect(count).to eq 0
      end

      it 'counts NPCs with recent animations' do
        npc_instance.update(last_animation_at: Time.now - 60)
        count = described_class.send(:count_recent_room_animators, room.id)
        expect(count).to eq 1
      end

      it 'excludes old animations' do
        npc_instance.update(last_animation_at: Time.now - 600)
        count = described_class.send(:count_recent_room_animators, room.id)
        expect(count).to eq 0
      end
    end

    describe '#on_cooldown?' do
      it 'returns false when no last_animation_at' do
        expect(described_class.send(:on_cooldown?, npc_instance)).to be false
      end

      it 'returns true when recently animated' do
        npc_instance.update(last_animation_at: Time.now - 10)
        expect(described_class.send(:on_cooldown?, npc_instance)).to be true
      end

      it 'returns false when cooldown has passed' do
        npc_instance.update(last_animation_at: Time.now - 600)
        expect(described_class.send(:on_cooldown?, npc_instance)).to be false
      end
    end

    describe '#can_respond_in_room?' do
      it 'returns true when under limits' do
        expect(described_class.send(:can_respond_in_room?, room.id)).to be true
      end

      it 'returns false when pending count is at limit' do
        NpcAnimationService::MAX_RESPONSES_PER_MINUTE.times do
          create(:npc_animation_queue, character_instance: npc_instance, room: room, status: 'pending')
        end
        expect(described_class.send(:can_respond_in_room?, room.id)).to be false
      end
    end

    describe '#judge_response_probability' do
      it 'uses the npc_name prompt interpolation key' do
        allow(GamePrompts).to receive(:get).and_return('prompt')
        allow(LLM::Client).to receive(:generate).and_return({
          success: true,
          text: '{"probability": 0.5}'
        })

        described_class.send(:judge_response_probability, npc_instance: npc_instance, content: 'Hello')

        expect(GamePrompts).to have_received(:get).with(
          'npc_animation.response_probability',
          hash_including(
            npc_name: npc_character.full_name,
            personality: archetype.effective_personality_prompt,
            content: 'Hello'
          )
        )
      end

      it 'parses probability from LLM JSON response' do
        allow(LLM::Client).to receive(:generate).and_return({
          success: true,
          text: '{"probability": 0.75}'
        })

        result = described_class.send(:judge_response_probability, npc_instance: npc_instance, content: 'Hello')
        expect(result).to eq 0.75
      end

      it 'handles markdown-wrapped JSON' do
        allow(LLM::Client).to receive(:generate).and_return({
          success: true,
          text: "```json\n{\"probability\": 0.5}\n```"
        })

        result = described_class.send(:judge_response_probability, npc_instance: npc_instance, content: 'Hello')
        expect(result).to eq 0.5
      end

      it 'clamps probability to valid range' do
        allow(LLM::Client).to receive(:generate).and_return({
          success: true,
          text: '{"probability": 1.5}'
        })

        result = described_class.send(:judge_response_probability, npc_instance: npc_instance, content: 'Hello')
        expect(result).to eq 1.0
      end

      it 'returns 0 on negative probability' do
        allow(LLM::Client).to receive(:generate).and_return({
          success: true,
          text: '{"probability": -0.5}'
        })

        result = described_class.send(:judge_response_probability, npc_instance: npc_instance, content: 'Hello')
        expect(result).to eq 0.0
      end

      it 'returns 0 on failed LLM call' do
        allow(LLM::Client).to receive(:generate).and_return({ success: false })

        result = described_class.send(:judge_response_probability, npc_instance: npc_instance, content: 'Hello')
        expect(result).to eq 0.0
      end

      it 'returns 0 on invalid JSON' do
        allow(LLM::Client).to receive(:generate).and_return({
          success: true,
          text: 'not valid json'
        })

        result = described_class.send(:judge_response_probability, npc_instance: npc_instance, content: 'Hello')
        expect(result).to eq 0.0
      end
    end

    describe '#build_context' do
      before do
        npc_instance.update(roomtitle: 'examining wares')
        allow(RpLog).to receive(:where).and_return(double(
          order: double(limit: double(all: []))
        ))
      end

      it 'includes room name' do
        result = described_class.send(:build_context, npc_instance: npc_instance, trigger_content: 'Hello')
        expect(result).to include('Market Square')
      end

      it 'includes room description' do
        result = described_class.send(:build_context, npc_instance: npc_instance, trigger_content: 'Hello')
        expect(result).to include('A busy marketplace')
      end

      it 'includes trigger content' do
        result = described_class.send(:build_context, npc_instance: npc_instance, trigger_content: 'Hello merchant!')
        expect(result).to include('TRIGGER:')
        expect(result).to include('Hello merchant!')
      end

      it 'includes NPC state when set' do
        result = described_class.send(:build_context, npc_instance: npc_instance, trigger_content: 'Hello')
        expect(result).to include('YOUR STATE: examining wares')
      end
    end

    describe '#recent_room_content' do
      it 'returns empty string when no logs' do
        result = described_class.send(:recent_room_content, room_id: room.id, limit: 5)
        expect(result).to eq ''
      end

      it 'returns nil and logs warning on error' do
        allow(RpLog).to receive(:where).and_raise(StandardError.new('DB error'))

        expect { described_class.send(:recent_room_content, room_id: room.id) }
          .to output(/Failed to get recent room content/).to_stderr

        result = described_class.send(:recent_room_content, room_id: room.id)
        expect(result).to be_nil
      end
    end

    describe '#recent_room_activity' do
      it 'returns empty array for room with no activity' do
        result = described_class.send(:recent_room_activity, room_id: room.id)
        expect(result).to eq []
      end

      it 'deduplicates per-witness duplicate log rows into a single activity stream item' do
        timestamp = Time.now - 30
        create(:rp_log,
               room: room,
               character_instance: npc_instance,
               sender_character: npc_character,
               content: 'duplicate action',
               logged_at: timestamp,
               created_at: timestamp)
        create(:rp_log,
               room: room,
               character_instance: player_instance,
               sender_character: npc_character,
               content: 'duplicate action',
               logged_at: timestamp,
               created_at: timestamp)

        result = described_class.send(:recent_room_activity, room_id: room.id, limit: 10)

        matching = result.select { |entry| entry[:content] == 'duplicate action' }
        expect(matching.length).to eq 1
      end

      it 'handles database errors gracefully' do
        allow(RpLog).to receive(:where).and_raise(StandardError.new('DB error'))

        expect { described_class.send(:recent_room_activity, room_id: room.id) }
          .to output(/Failed to get room context/).to_stderr

        result = described_class.send(:recent_room_activity, room_id: room.id)
        expect(result).to eq []
      end
    end

    describe '#count_consecutive_npc_messages' do
      it 'returns 0 when no recent activity' do
        result = described_class.send(:count_consecutive_npc_messages, room.id)
        expect(result).to eq 0
      end
    end

    describe '#broadcast_npc_emote' do
      before do
        allow(BroadcastService).to receive(:to_room)
      end

      it 'broadcasts to room with type emote' do
        expect(BroadcastService).to receive(:to_room).with(
          room.id,
          hash_including(content: start_with('Merchant')),
          hash_including(type: :emote, sender_instance: npc_instance)
        )

        described_class.send(:broadcast_npc_emote, npc_instance, 'waves hello')
      end

      it 'cleans up Claude action prefix' do
        expect(BroadcastService).to receive(:to_room).with(
          room.id,
          hash_including(content: 'Merchant waves hello'),
          anything
        )

        described_class.send(:broadcast_npc_emote, npc_instance, "Merchant's Action: waves hello")
      end

      it 'prepends character name if missing' do
        expect(BroadcastService).to receive(:to_room).with(
          room.id,
          hash_including(content: 'Merchant nods quietly'),
          anything
        )

        described_class.send(:broadcast_npc_emote, npc_instance, 'nods quietly')
      end

      it 'does not double-prepend name' do
        expect(BroadcastService).to receive(:to_room).with(
          room.id,
          hash_including(content: 'Merchant smiles warmly'),
          anything
        )

        described_class.send(:broadcast_npc_emote, npc_instance, 'Merchant smiles warmly')
      end
    end

    describe '#update_animation_tracking' do
      it 'updates last_animation_at' do
        described_class.send(:update_animation_tracking, npc_instance)
        npc_instance.reload
        expect(npc_instance.last_animation_at).to be_within(2).of(Time.now)
      end

      it 'increments animation_emote_count' do
        original_count = npc_instance.animation_emote_count || 0
        described_class.send(:update_animation_tracking, npc_instance)
        npc_instance.reload
        expect(npc_instance.animation_emote_count).to eq(original_count + 1)
      end

      it 'sets animation_first_emote_done to true' do
        described_class.send(:update_animation_tracking, npc_instance)
        npc_instance.reload
        expect(npc_instance.animation_first_emote_done).to be true
      end
    end

    describe '#build_status_prompt' do
      it 'uses location_name interpolation key expected by the prompt' do
        allow(GamePrompts).to receive(:get).and_return('status prompt')

        described_class.send(:build_status_prompt, npc_instance)

        expect(GamePrompts).to have_received(:get).with(
          'npc_animation.status',
          hash_including(
            full_name: npc_character.full_name,
            personality: archetype.effective_personality_prompt,
            location_name: room.name
          )
        )
      end
    end
  end

  describe '.generate_emote' do
    before do
      stub_llm_response(text: 'Merchant nods thoughtfully.')
    end

    it 'generates emote using archetype settings' do
      result = described_class.send(:generate_emote, npc_instance: npc_instance, context: 'Someone said hello')
      expect(result[:success]).to be true
      expect(result[:text]).to eq 'Merchant nods thoughtfully.'
    end

    it 'uses first emote model when first emote not done' do
      npc_instance.update(animation_first_emote_done: false)

      expect(LLM::Client).to receive(:generate) do |args|
        expect(args[:model]).to eq(archetype.effective_first_emote_model)
        { success: true, text: 'response' }
      end

      described_class.send(:generate_emote, npc_instance: npc_instance, context: 'context')
    end

    it 'uses primary model after first emote' do
      npc_instance.update(animation_first_emote_done: true)

      expect(LLM::Client).to receive(:generate) do |args|
        expect(args[:model]).to eq(archetype.effective_primary_model)
        { success: true, text: 'response' }
      end

      described_class.send(:generate_emote, npc_instance: npc_instance, context: 'context')
    end
  end

  describe '.generate_with_fallback' do
    let(:fallback_models) { ['gemini-3-flash-preview', 'gpt-5-mini'] }

    before do
      allow(archetype).to receive(:effective_primary_model).and_return('claude-haiku-4-5-20251001')
      allow(archetype).to receive(:effective_first_emote_model).and_return('claude-sonnet-4-20250514')
      allow(archetype).to receive(:fallback_models).and_return(fallback_models)
    end

    it 'returns success on first try' do
      allow(LLM::Client).to receive(:generate).and_return({ success: true, text: 'response' })

      result = described_class.send(
        :generate_with_fallback,
        archetype: archetype,
        prompt: 'test',
        is_first_emote: false
      )

      expect(result[:success]).to be true
    end

    it 'tries fallback models on failure' do
      call_count = 0
      allow(LLM::Client).to receive(:generate) do
        call_count += 1
        if call_count == 1
          { success: false, error: 'Primary failed' }
        else
          { success: true, text: 'fallback response' }
        end
      end

      result = described_class.send(
        :generate_with_fallback,
        archetype: archetype,
        prompt: 'test',
        is_first_emote: false
      )

      expect(result[:success]).to be true
      expect(call_count).to eq 2
    end

    it 'returns failure if all models fail' do
      allow(LLM::Client).to receive(:generate).and_return({ success: false, error: 'All failed' })

      result = described_class.send(
        :generate_with_fallback,
        archetype: archetype,
        prompt: 'test',
        is_first_emote: false
      )

      expect(result[:success]).to be false
    end

    it 'adds partial_assistant for Claude models' do
      allow(NpcArchetype).to receive(:claude_model?).with('claude-haiku-4-5-20251001').and_return(true)
      allow(NpcArchetype).to receive(:provider_for_model).and_return('anthropic')

      expect(LLM::Client).to receive(:generate) do |args|
        expect(args[:options][:partial_assistant]).to eq("Bob's Action: ")
        { success: true, text: 'response' }
      end

      described_class.send(
        :generate_with_fallback,
        archetype: archetype,
        prompt: 'test',
        is_first_emote: false,
        npc_name: 'Bob'
      )
    end
  end

  describe '.process_async' do
    it 'enqueues background processing job' do
      entry = create(:npc_animation_queue, character_instance: npc_instance, room: room)
      allow(NpcAnimationProcessJob).to receive(:perform_async).and_return('jid-123')

      jid = described_class.send(:process_async, entry)

      expect(NpcAnimationProcessJob).to have_received(:perform_async).with(entry.id)
      expect(jid).to eq('jid-123')
    end

    it 'marks entry failed when enqueue raises' do
      entry = create(:npc_animation_queue, character_instance: npc_instance, room: room, status: 'pending')
      allow(NpcAnimationProcessJob).to receive(:perform_async).and_raise(StandardError.new('queue down'))

      result = described_class.send(:process_async, entry)

      expect(result).to be_nil
      entry.reload
      expect(entry.status).to eq 'failed'
      expect(entry.error_message).to include('Async enqueue error: queue down')
    end

    it 'handles errors gracefully by calling fail! on entry' do
      entry = create(:npc_animation_queue, character_instance: npc_instance, room: room, status: 'pending')
      allow(NpcAnimationHandler).to receive(:call).and_raise(StandardError.new('Test error'))

      # Test via process_queue_entry directly since thread database isolation makes it hard to test async
      result = described_class.send(:process_queue_entry, entry)

      expect(result).to be false
      entry.reload
      expect(entry.status).to eq 'failed'
      expect(entry.error_message).to include('Test error')
    end
  end

  describe '.mentioned_in_content? with short_desc keywords' do
    it 'matches significant words from short_desc' do
      result = described_class.mentioned_in_content?(
        npc_instance: npc_instance,
        content: 'That trader over there'
      )
      expect(result).to be true
    end

    it 'ignores short words in short_desc' do
      npc_character.update(short_desc: 'a worn old man')

      result = described_class.mentioned_in_content?(
        npc_instance: npc_instance,
        content: 'I see a man here' # 'man' and 'old' are too short
      )
      expect(result).to be false
    end
  end

  describe 'queue cleanup in process_queue!' do
    it 'calls cleanup_old_entries when there are pending entries' do
      # Create a pending entry so the queue has something to process
      create(:npc_animation_queue, character_instance: npc_instance, room: room, status: 'pending')

      allow(NpcAnimationHandler).to receive(:call).and_return({ success: true })
      expect(NpcAnimationQueue).to receive(:cleanup_old_entries)

      described_class.process_queue!
    end

    it 'runs cleanup when no pending entries exist' do
      expect(NpcAnimationQueue).to receive(:cleanup_old_entries)

      result = described_class.process_queue!
      expect(result[:processed]).to eq 0
    end
  end
end
