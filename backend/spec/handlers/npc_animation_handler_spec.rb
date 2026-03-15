# frozen_string_literal: true

require 'spec_helper'

RSpec.describe NpcAnimationHandler do
  let(:room) { create(:room) }
  let(:archetype) { create(:npc_archetype, name: 'Test Archetype', behavior_pattern: 'friendly') }
  let(:npc_character) { create(:character, :npc, forename: 'TestNpc', npc_archetype: archetype) }
  let(:npc_instance) do
    create(:character_instance, character: npc_character, current_room: room, online: true)
  end
  let(:entry) do
    create(:npc_animation_queue,
           character_instance: npc_instance,
           room: room,
           trigger_content: 'Hello there!',
           trigger_type: 'high_turn',
           status: 'pending')
  end

  before do
    # Stub external services that would be called during animation
    allow(BroadcastService).to receive(:to_room)
    allow(BroadcastService).to receive(:to_character)
    allow(TriggerService).to receive(:check_npc_triggers_async)
    allow(NpcLeadershipService).to receive(:check_and_handle_leave)

    # Stub LLM client
    allow(LLM::Client).to receive(:generate).and_return({
      success: true,
      text: 'TestNpc waves hello.'
    })

    # Stub memory services
    allow(NpcMemoryService).to receive(:store_memory)
    allow(NpcMemoryService).to receive(:retrieve_relevant).and_return([])
    allow(NpcMemoryService).to receive(:format_for_context).and_return(nil)

    # Stub world memory service
    allow(WorldMemoryService).to receive(:retrieve_for_npc).and_return([])
    allow(WorldMemoryService).to receive(:format_for_npc_context).and_return(nil)

    # Stub clue service
    allow(ClueService).to receive(:relevant_clues_for).and_return([])

    # Stub reputation service
    allow(ReputationService).to receive(:reputation_for).and_return(nil)

    # Stub helpfile lore
    allow(Helpfile).to receive(:lore_context_for).and_return(nil)

    # Stub NpcRelationship
    allow(NpcRelationship).to receive(:find_or_create_for).and_return(
      double('NpcRelationship',
             knowledge_tier: 1,
             knowledge_label: 'stranger',
             to_context_string: 'Stranger',
             record_interaction: true)
    )
    allow(NpcRelationship).to receive(:for_npc).and_return(NpcRelationship.where(id: -1))
    allow(NpcRelationshipUpdateJob).to receive(:perform_async).and_return('jid-relationship')

    # Stub CharacterInstance methods that may not exist in test environment
    allow_any_instance_of(CharacterInstance).to receive(:puppet_mode?).and_return(false)
    allow_any_instance_of(CharacterInstance).to receive(:seed_mode?).and_return(false)
  end

  describe 'module extensions' do
    it 'extends ResultHandler' do
      expect(described_class.singleton_class.included_modules).to include(ResultHandler)
    end
  end

  describe 'class methods' do
    it 'defines call' do
      expect(described_class).to respond_to(:call)
    end

    describe '.call' do
      it 'accepts an entry parameter' do
        method_params = described_class.method(:call).parameters
        expect(method_params).to include([:req, :entry])
      end
    end
  end

  describe 'private class methods' do
    it 'defines valid_npc_state?' do
      expect(described_class.private_methods).to include(:valid_npc_state?)
    end

    it 'defines build_context' do
      expect(described_class.private_methods).to include(:build_context)
    end

    it 'defines build_message_history' do
      expect(described_class.private_methods).to include(:build_message_history)
    end

    it 'defines generate_and_broadcast_emote' do
      expect(described_class.private_methods).to include(:generate_and_broadcast_emote)
    end

    it 'defines clean_emote_text' do
      expect(described_class.private_methods).to include(:clean_emote_text)
    end

    it 'defines broadcast_emote' do
      expect(described_class.private_methods).to include(:broadcast_emote)
    end

    it 'defines update_animation_tracking' do
      expect(described_class.private_methods).to include(:update_animation_tracking)
    end

    it 'defines fetch_lore_context' do
      expect(described_class.private_methods).to include(:fetch_lore_context)
    end

    it 'defines fetch_memory_context' do
      expect(described_class.private_methods).to include(:fetch_memory_context)
    end

    it 'defines fetch_relationship_context' do
      expect(described_class.private_methods).to include(:fetch_relationship_context)
    end

    it 'defines post_animation_update' do
      expect(described_class.private_methods).to include(:post_animation_update)
    end

    it 'defines build_system_prompt' do
      expect(described_class.private_methods).to include(:build_system_prompt)
    end
  end

  describe '.call' do
    context 'with nil entry' do
      it 'returns error' do
        result = described_class.call(nil)

        expect(result[:success]).to be false
        expect(result[:error]).to eq 'No queue entry provided'
      end
    end

    context 'when entry has been deleted' do
      before do
        allow(entry).to receive(:start_processing!).and_return(false)
      end

      it 'returns error' do
        result = described_class.call(entry)

        expect(result[:success]).to be false
        expect(result[:error]).to eq 'Queue entry no longer exists'
      end
    end

    context 'when NPC is no longer online' do
      before do
        allow(entry).to receive(:start_processing!).and_return(true)
        allow(entry).to receive(:fail!)
        npc_instance.update(online: false)
      end

      it 'fails the entry' do
        result = described_class.call(entry)

        expect(entry).to have_received(:fail!).with('NPC no longer in room')
        expect(result[:success]).to be false
      end
    end

    context 'when NPC has moved to another room' do
      let(:other_room) { create(:room) }

      before do
        allow(entry).to receive(:start_processing!).and_return(true)
        allow(entry).to receive(:fail!)
        npc_instance.update(current_room_id: other_room.id)
      end

      it 'fails the entry' do
        result = described_class.call(entry)

        expect(entry).to have_received(:fail!).with('NPC no longer in room')
        expect(result[:success]).to be false
      end
    end

    context 'when NPC is valid and generation succeeds' do
      before do
        allow(entry).to receive(:start_processing!).and_return(true)
        allow(entry).to receive(:complete!)
      end

      it 'generates and broadcasts emote' do
        result = described_class.call(entry)

        expect(result[:success]).to be true
        expect(BroadcastService).to have_received(:to_room).with(
          room.id,
          hash_including(:content),
          hash_including(type: :emote)
        )
      end

      it 'completes the entry' do
        described_class.call(entry)

        expect(entry).to have_received(:complete!).with(kind_of(String))
      end

      it 'updates animation tracking on instance' do
        described_class.call(entry)

        npc_instance.reload
        expect(npc_instance.animation_first_emote_done).to be true
        expect(npc_instance.animation_emote_count).to be >= 1
      end

      it 'stores memory of interaction' do
        described_class.call(entry)

        expect(NpcMemoryService).to have_received(:store_memory).with(
          hash_including(
            npc: npc_character,
            memory_type: 'interaction'
          )
        )
      end

      it 'checks NPC triggers asynchronously' do
        described_class.call(entry)

        expect(TriggerService).to have_received(:check_npc_triggers_async).with(
          hash_including(
            npc_instance: npc_instance,
            emote_content: kind_of(String)
          )
        )
      end

      it 'passes scene context to trigger checks for scene-scoped triggers' do
        scene = create(
          :arranged_scene,
          :active,
          npc_character: npc_character,
          meeting_room: room,
          rp_room: room
        )

        described_class.call(entry)

        expect(TriggerService).to have_received(:check_npc_triggers_async).with(
          hash_including(arranged_scene_id: scene.id)
        )
      end

      it 'does not scope to unrelated active scene when trigger source is another character' do
        other_pc = create(:character)
        other_instance = create(:character_instance, character: other_pc, current_room: room, online: true)
        entry.update(trigger_source_id: other_instance.id)

        create(
          :arranged_scene,
          :active,
          npc_character: npc_character,
          meeting_room: room,
          rp_room: room
        )

        described_class.call(entry)

        expect(TriggerService).to have_received(:check_npc_triggers_async).with(
          hash_including(arranged_scene_id: nil)
        )
      end
    end

    context 'when LLM generation fails' do
      before do
        allow(entry).to receive(:start_processing!).and_return(true)
        allow(entry).to receive(:fail!)
        allow(LLM::Client).to receive(:generate).and_return({
          success: false,
          error: 'Rate limit exceeded'
        })
        # Mock fallback models
        allow(archetype).to receive(:fallback_models).and_return([])
        allow(npc_character).to receive(:npc_archetype).and_return(archetype)
      end

      it 'fails the entry with error' do
        result = described_class.call(entry)

        expect(entry).to have_received(:fail!)
        expect(result[:success]).to be false
      end
    end

    context 'when an exception occurs' do
      before do
        allow(entry).to receive(:start_processing!).and_raise(StandardError.new('Database error'))
        allow(entry).to receive(:fail!)
      end

      it 'handles the exception gracefully' do
        result = described_class.call(entry)

        expect(result[:success]).to be false
        expect(result[:error]).to include('Handler error')
      end

      it 'fails the entry' do
        described_class.call(entry)

        expect(entry).to have_received(:fail!)
      end
    end

    context 'with puppet mode NPC' do
      let(:staff_user) { create(:user, is_admin: true) }
      let(:staff_character) { create(:character, user: staff_user) }
      let(:staff_instance) { create(:character_instance, character: staff_character, online: true) }

      before do
        allow(entry).to receive(:start_processing!).and_return(true)
        allow(entry).to receive(:complete!)
        allow(npc_instance).to receive(:puppet_mode?).and_return(true)
        allow(npc_instance).to receive(:puppeteer).and_return(staff_instance)
        allow(npc_instance).to receive(:set_puppet_suggestion!)
      end

      it 'sends suggestion to puppeteer instead of broadcasting' do
        described_class.call(entry)

        expect(BroadcastService).to have_received(:to_character).with(
          staff_instance,
          hash_including(:content, :html),
          hash_including(type: :puppet_suggestion)
        )
      end

      it 'stores the suggestion on the NPC' do
        described_class.call(entry)

        expect(npc_instance).to have_received(:set_puppet_suggestion!).with(kind_of(String))
      end

      it 'does not mutate memories or triggers before commit' do
        described_class.call(entry)

        expect(NpcMemoryService).not_to have_received(:store_memory)
        expect(TriggerService).not_to have_received(:check_npc_triggers_async)
      end
    end

    context 'when NPC is following someone' do
      let(:leader_instance) { create(:character_instance, current_room: room, online: true) }

      before do
        allow(entry).to receive(:start_processing!).and_return(true)
        allow(entry).to receive(:complete!)
        npc_instance.update(following_id: leader_instance.id)
      end

      it 'checks if NPC should leave their leader' do
        described_class.call(entry)

        expect(NpcLeadershipService).to have_received(:check_and_handle_leave).with(
          npc_instance: npc_instance
        )
      end
    end
  end

  describe 'message history building' do
    let(:pc_character) { create(:character) }
    let(:pc_instance) { create(:character_instance, character: pc_character, current_room: room, online: true) }

    before do
      allow(entry).to receive(:start_processing!).and_return(true)
      allow(entry).to receive(:complete!)
    end

    context 'with recent RP logs' do
      before do
        # Create some RP logs in the room (use plain Ruby time arithmetic)
        # rp_log model uses 'content' column (or 'text' alias), not 'plain_text'
        create(:rp_log, room: room, character_instance: pc_instance, content: 'waves hello', created_at: Time.now - 300)
        create(:rp_log, room: room, character_instance: npc_instance, content: 'smiles warmly', created_at: Time.now - 180)
        create(:rp_log, room: room, character_instance: pc_instance, content: 'asks a question', created_at: Time.now - 60)
      end

      it 'generates emote successfully' do
        result = described_class.call(entry)

        expect(result[:success]).to be true
      end

      it 'passes messages to LLM' do
        described_class.call(entry)

        expect(LLM::Client).to have_received(:generate).with(
          hash_including(
            options: hash_including(:messages)
          )
        )
      end
    end

    context 'with no RP logs' do
      it 'uses trigger content as message' do
        result = described_class.call(entry)

        expect(result[:success]).to be true
      end
    end

    context 'with witness-specific log history' do
      let(:other_character) { create(:character, forename: 'Other') }
      let(:other_instance) { create(:character_instance, character: other_character, current_room: room, online: true) }

      it 'only includes logs witnessed by the NPC instance' do
        create(:rp_log, room: room, character_instance: other_instance, content: 'other-only log', created_at: Time.now - 120)
        create(:rp_log, room: room, character_instance: npc_instance, content: 'npc-witnessed log', created_at: Time.now - 60)

        messages = described_class.send(:build_message_history, npc_instance, entry)
        combined = messages.map { |m| m[:content] }.join("\n")

        expect(combined).to include('npc-witnessed log')
        expect(combined).not_to include('other-only log')
      end

      it 'orders history by narrative time (logged_at) rather than created_at' do
        create(:rp_log,
               room: room,
               character_instance: npc_instance,
               content: 'earlier in narrative',
               logged_at: Time.now - 180,
               created_at: Time.now - 20)
        create(:rp_log,
               room: room,
               character_instance: npc_instance,
               content: 'later in narrative',
               logged_at: Time.now - 60,
               created_at: Time.now - 120)

        messages = described_class.send(:build_message_history, npc_instance, entry)
        combined = messages.map { |m| m[:content] }.join("\n")

        expect(combined.index('earlier in narrative')).to be < combined.index('later in narrative')
      end

      it 'uses sender identity rather than forename matching for role attribution' do
        same_name_pc = create(:character, forename: npc_character.forename, surname: 'Visitor')
        different_pc = create(:character, forename: 'Jordan', surname: 'Parker')

        create(:rp_log,
               room: room,
               character_instance: npc_instance,
               sender_character_id: different_pc.id,
               content: 'says hello',
               logged_at: Time.now - 120)
        create(:rp_log,
               room: room,
               character_instance: npc_instance,
               sender_character_id: same_name_pc.id,
               content: 'asks about prices',
               logged_at: Time.now - 60)

        messages = described_class.send(:build_message_history, npc_instance, entry)
        roles = messages.map { |m| m[:role] }

        expect(roles).to all(eq('user'))
      end
    end
  end

  describe 'context building' do
    before do
      allow(entry).to receive(:start_processing!).and_return(true)
      allow(entry).to receive(:complete!)
    end

    context 'with PCs in the room' do
      let(:pc_character) { create(:character, short_desc: 'A tall human') }
      let!(:pc_instance) { create(:character_instance, character: pc_character, current_room: room, online: true) }

      it 'includes PC descriptions in context' do
        described_class.call(entry)

        # The context is built and passed to LLM
        expect(LLM::Client).to have_received(:generate).with(
          hash_including(
            options: hash_including(:system_prompt)
          )
        )
      end
    end

    context 'with relevant lore' do
      before do
        allow(Helpfile).to receive(:lore_context_for).and_return('This city was founded by elves.')
      end

      it 'includes lore in context' do
        described_class.call(entry)

        expect(Helpfile).to have_received(:lore_context_for).with('Hello there!', limit: 2)
      end
    end

    context 'with relevant memories' do
      before do
        allow(NpcMemoryService).to receive(:retrieve_relevant).and_return([
          { content: 'Met someone last week', created_at: Time.now - 604800 } # 1 week = 604800 seconds
        ])
        allow(NpcMemoryService).to receive(:format_for_context).and_return('Past memory: Met someone last week')
      end

      it 'fetches memories for context' do
        described_class.call(entry)

        expect(NpcMemoryService).to have_received(:retrieve_relevant).with(
          hash_including(
            npc: npc_character,
            query: 'Hello there!',
            limit: 3
          )
        )
      end
    end
  end

  describe 'text cleaning' do
    before do
      allow(entry).to receive(:start_processing!).and_return(true)
      allow(entry).to receive(:complete!)
    end

    context 'when LLM returns text without name prefix' do
      before do
        allow(LLM::Client).to receive(:generate).and_return({
          success: true,
          text: 'waves hello warmly.'
        })
      end

      it 'prepends the character name' do
        result = described_class.call(entry)

        # Case insensitive check - the handler may normalize case
        expect(result[:data][:emote].downcase).to start_with('testnpc')
      end
    end

    context 'when LLM returns text with Action prefix' do
      before do
        allow(LLM::Client).to receive(:generate).and_return({
          success: true,
          text: "TestNpc's Action: waves hello warmly."
        })
      end

      it 'removes the Action prefix' do
        result = described_class.call(entry)

        expect(result[:data][:emote]).not_to include('Action:')
        # Case insensitive check
        expect(result[:data][:emote].downcase).to start_with('testnpc')
      end
    end
  end

  describe 'time gap formatting' do
    def format_time_gap(from, to)
      described_class.send(:format_time_gap, from, to)
    end

    it 'formats minutes correctly' do
      now = Time.now
      gap = format_time_gap(now, now + 600) # 10 minutes

      expect(gap).to eq '(10 minutes later)'
    end

    it 'formats hour correctly' do
      now = Time.now
      gap = format_time_gap(now, now + 3900) # 65 minutes

      expect(gap).to eq '(An hour later)'
    end

    it 'formats hours correctly' do
      now = Time.now
      gap = format_time_gap(now, now + 10800) # 180 minutes

      expect(gap).to eq '(3 hours later)'
    end

    it 'formats days correctly' do
      now = Time.now
      gap = format_time_gap(now, now + 172800) # 2 days

      expect(gap).to eq '(2 days later)'
    end

    it 'returns nil for small gaps' do
      now = Time.now
      gap = format_time_gap(now, now + 60) # 1 minute

      expect(gap).to be_nil
    end

    it 'returns nil for nil inputs' do
      expect(format_time_gap(nil, Time.now)).to be_nil
      expect(format_time_gap(Time.now, nil)).to be_nil
    end
  end

  describe 'valid_npc_state?' do
    it 'returns true for valid NPC' do
      result = described_class.send(:valid_npc_state?, npc_instance, entry)

      expect(result).to be true
    end

    it 'returns false when NPC is nil' do
      result = described_class.send(:valid_npc_state?, nil, entry)

      # Method returns falsey (nil or false) for invalid states
      expect(result).to be_falsey
    end

    it 'returns false when NPC is offline' do
      npc_instance.update(online: false)
      result = described_class.send(:valid_npc_state?, npc_instance, entry)

      expect(result).to be false
    end

    it 'returns false when NPC moved to different room' do
      other_room = create(:room)
      npc_instance.update(current_room_id: other_room.id)
      result = described_class.send(:valid_npc_state?, npc_instance, entry)

      expect(result).to be false
    end
  end

  describe 'fallback models' do
    before do
      allow(entry).to receive(:start_processing!).and_return(true)
      allow(entry).to receive(:complete!)
      # Primary model fails, then succeeds on second call
      call_count = 0
      allow(LLM::Client).to receive(:generate) do
        call_count += 1
        if call_count == 1
          { success: false, error: 'Primary failed' }
        else
          { success: true, text: 'TestNpc waves from fallback.' }
        end
      end
    end

    it 'tries fallback models when primary fails' do
      # Stub archetype to have fallback models
      allow(archetype).to receive(:fallback_models).and_return(['gpt-5-mini'])

      result = described_class.call(entry)

      # Should have made 2 calls - primary and fallback
      expect(LLM::Client).to have_received(:generate).at_least(:twice)
    end
  end

  describe 'relationship updates' do
    let(:pc_character) { create(:character) }
    let(:pc_instance) { create(:character_instance, character: pc_character, current_room: room, online: true) }

    before do
      allow(entry).to receive(:start_processing!).and_return(true)
      allow(entry).to receive(:complete!)
      entry.update(trigger_source_id: pc_instance.id)
      allow(NpcRelationshipUpdateJob).to receive(:perform_async).and_return('jid-relationship')
    end

    it 'enqueues relationship update after successful animation' do
      described_class.call(entry)

      expect(NpcRelationshipUpdateJob).to have_received(:perform_async).with(
        npc_character.id,
        pc_character.id,
        entry.trigger_content,
        kind_of(String)
      )
    end
  end

  describe 'seed instruction handling' do
    before do
      allow(entry).to receive(:start_processing!).and_return(true)
      allow(entry).to receive(:complete!)
      allow(npc_instance).to receive(:seed_mode?).and_return(true)
      allow(npc_instance).to receive(:puppet_instruction).and_return('Mention the weather')
      allow(npc_instance).to receive(:clear_seed_instruction!)
    end

    it 'clears seed instruction after use' do
      described_class.call(entry)

      expect(npc_instance).to have_received(:clear_seed_instruction!)
    end
  end

  describe 'world memory context' do
    before do
      allow(entry).to receive(:start_processing!).and_return(true)
      allow(entry).to receive(:complete!)
    end

    context 'when NPC has relevant world memories' do
      before do
        allow(WorldMemoryService).to receive(:retrieve_for_npc).and_return([
          { content: 'A dragon attacked the town last week', witnessed: true }
        ])
        allow(WorldMemoryService).to receive(:format_for_npc_context).and_return('World event: Dragon attack')
      end

      it 'fetches world memories' do
        described_class.call(entry)

        expect(WorldMemoryService).to have_received(:retrieve_for_npc).with(
          hash_including(
            npc: npc_character,
            query: 'Hello there!',
            room: room,
            limit: 3
          )
        )
      end
    end
  end

  describe 'clue context' do
    let(:pc_character) { create(:character) }
    let(:pc_instance) { create(:character_instance, character: pc_character, current_room: room, online: true) }

    before do
      allow(entry).to receive(:start_processing!).and_return(true)
      allow(entry).to receive(:complete!)
      entry.update(trigger_source_id: pc_instance.id)
    end

    context 'when NPC knows relevant clues' do
      before do
        allow(ClueService).to receive(:relevant_clues_for).and_return([
          { clue: 'The butler did it', shared: false }
        ])
        allow(ClueService).to receive(:format_for_context).and_return('Clue: The butler did it')
      end

      it 'fetches clues when talking to a PC' do
        described_class.call(entry)

        expect(ClueService).to have_received(:relevant_clues_for).with(
          hash_including(
            npc: npc_character,
            query: 'Hello there!',
            pc: pc_character,
            limit: 2
          )
        )
      end
    end

    context 'when trigger source is an NPC' do
      let(:other_npc) { create(:character, :npc) }
      let(:other_npc_instance) { create(:character_instance, character: other_npc, current_room: room, online: true) }

      before do
        entry.update(trigger_source_id: other_npc_instance.id)
      end

      it 'does not fetch clues' do
        described_class.call(entry)

        expect(ClueService).not_to have_received(:relevant_clues_for)
      end
    end
  end

  describe 'message grouping with alternation' do
    it 'combines consecutive user messages' do
      initial = [
        { role: 'user', content: 'Hello' },
        { role: 'user', content: 'How are you?' }
      ]

      result = described_class.send(:group_messages_with_alternation, initial)

      expect(result.length).to eq 1
      expect(result[0][:content]).to include('Hello')
      expect(result[0][:content]).to include('How are you?')
    end

    it 'merges time gaps into user content' do
      initial = [
        { role: 'user', content: 'Hello' },
        { role: 'time_gap', content: '(5 minutes later)' },
        { role: 'user', content: 'Still here?' }
      ]

      result = described_class.send(:group_messages_with_alternation, initial)

      # Should be combined with time gap in between
      expect(result.length).to eq 1
      expect(result[0][:content]).to include('Hello')
      expect(result[0][:content]).to include('5 minutes later')
    end

    it 'maintains user/assistant alternation' do
      initial = [
        { role: 'user', content: 'Hello' },
        { role: 'assistant', content: 'Hi there!' },
        { role: 'user', content: 'How are you?' }
      ]

      result = described_class.send(:group_messages_with_alternation, initial)

      expect(result.length).to eq 3
      expect(result.map { |m| m[:role] }).to eq %w[user assistant user]
    end
  end

  describe 'ensuring first message is user' do
    it 'converts first assistant message to user' do
      messages = [
        { role: 'assistant', content: 'Hello' },
        { role: 'user', content: 'Hi' }
      ]

      described_class.send(:ensure_first_message_is_user, messages)

      expect(messages[0][:role]).to eq 'user'
    end

    it 'does nothing if first message is already user' do
      messages = [
        { role: 'user', content: 'Hello' },
        { role: 'assistant', content: 'Hi' }
      ]

      described_class.send(:ensure_first_message_is_user, messages)

      expect(messages[0][:role]).to eq 'user'
      expect(messages.length).to eq 2
    end
  end

  describe 'ensuring last message is user' do
    it 'appends placeholder if last message is assistant' do
      messages = [
        { role: 'user', content: 'Hello' },
        { role: 'assistant', content: 'Hi there!' }
      ]

      described_class.send(:ensure_last_message_is_user, messages)

      expect(messages.last[:role]).to eq 'user'
    end

    it 'does nothing if last message is already user' do
      messages = [
        { role: 'user', content: 'Hello' },
        { role: 'assistant', content: 'Hi' },
        { role: 'user', content: 'Goodbye' }
      ]

      described_class.send(:ensure_last_message_is_user, messages)

      expect(messages.last[:content]).to eq 'Goodbye'
    end
  end

  describe 'combine_consecutive_roles' do
    it 'combines consecutive same-role messages' do
      messages = [
        { role: 'user', content: 'A' },
        { role: 'user', content: 'B' },
        { role: 'assistant', content: 'C' }
      ]

      result = described_class.send(:combine_consecutive_roles, messages)

      expect(result.length).to eq 2
      expect(result[0][:content]).to include('A')
      expect(result[0][:content]).to include('B')
    end

    it 'handles empty array' do
      result = described_class.send(:combine_consecutive_roles, [])

      expect(result).to eq []
    end

    it 'handles single message' do
      messages = [{ role: 'user', content: 'A' }]

      result = described_class.send(:combine_consecutive_roles, messages)

      expect(result).to eq messages
    end
  end

  describe 'build_pc_descriptions' do
    let(:pc_char1) { create(:character, short_desc: 'A tall elf') }
    let(:pc_char2) { create(:character, short_desc: 'A dwarf warrior') }

    before do
      create(:character_instance, character: pc_char1, current_room: room, online: true)
      create(:character_instance, character: pc_char2, current_room: room, online: true)
    end

    it 'returns formatted descriptions of PCs in the room' do
      result = described_class.send(:build_pc_descriptions, npc_instance)

      expect(result).to include(pc_char1.full_name)
      expect(result).to include('tall elf')
      expect(result).to include(pc_char2.full_name)
    end

    it 'excludes the NPC itself' do
      result = described_class.send(:build_pc_descriptions, npc_instance)

      expect(result).not_to include(npc_character.full_name)
    end

    context 'when no PCs are in room' do
      before do
        CharacterInstance.where(current_room_id: room.id).exclude(id: npc_instance.id).destroy
      end

      it 'returns nil' do
        result = described_class.send(:build_pc_descriptions, npc_instance)

        expect(result).to be_nil
      end
    end
  end

  describe 'clean_emote_text' do
    it 'removes Action prefix' do
      text = "TestNpc's Action: waves hello."
      result = described_class.send(:clean_emote_text, text, 'TestNpc')

      expect(result).not_to include('Action:')
      expect(result).to start_with('TestNpc')
    end

    it 'prepends name if missing' do
      text = 'waves hello warmly.'
      result = described_class.send(:clean_emote_text, text, 'TestNpc')

      expect(result).to start_with('TestNpc')
    end

    it 'leaves text alone if name is present' do
      text = 'TestNpc waves hello warmly.'
      result = described_class.send(:clean_emote_text, text, 'TestNpc')

      expect(result).to eq text
    end

    it 'handles case insensitive name check' do
      text = 'testnpc waves hello warmly.'
      result = described_class.send(:clean_emote_text, text, 'TestNpc')

      expect(result).to eq text
    end
  end

  describe 'reputation context' do
    let(:pc_character) { create(:character, short_desc: 'A tall human') }
    let!(:pc_instance) { create(:character_instance, character: pc_character, current_room: room, online: true) }
    let(:relationship) { double('NpcRelationship', knowledge_tier: 2, knowledge_label: 'acquaintance', to_context_string: 'Acquaintance') }

    before do
      allow(NpcRelationship).to receive(:find_or_create_for).and_return(relationship)
      allow(ReputationService).to receive(:reputation_for).and_return('Known troublemaker')
    end

    it 'fetches reputation based on knowledge tier' do
      described_class.send(:fetch_reputation_context, npc_instance)

      expect(ReputationService).to have_received(:reputation_for).with(pc_character, knowledge_tier: 2)
    end

    it 'returns nil when no PCs are in room' do
      CharacterInstance.where(current_room_id: room.id).exclude(id: npc_instance.id).destroy
      result = described_class.send(:fetch_reputation_context, npc_instance)
      expect(result).to be_nil
    end

    it 'returns nil when reputation service returns empty' do
      allow(ReputationService).to receive(:reputation_for).and_return('')
      result = described_class.send(:fetch_reputation_context, npc_instance)
      expect(result).to be_nil
    end

    it 'handles exception gracefully' do
      allow(ReputationService).to receive(:reputation_for).and_raise(StandardError.new('DB error'))
      result = described_class.send(:fetch_reputation_context, npc_instance)
      expect(result).to be_nil
    end
  end

  describe 'fetch_world_memory_context' do
    let(:world_memories) { [double('WorldMemory', content: 'Something happened')] }

    before do
      allow(WorldMemoryService).to receive(:retrieve_for_npc).and_return(world_memories)
      allow(WorldMemoryService).to receive(:format_for_npc_context).and_return('Formatted memory')
    end

    it 'retrieves world memories for NPC' do
      result = described_class.send(:fetch_world_memory_context, npc_character, 'test query', room)

      expect(WorldMemoryService).to have_received(:retrieve_for_npc).with(
        npc: npc_character,
        query: 'test query',
        room: room,
        limit: 3
      )
      expect(result).to eq 'Formatted memory'
    end

    it 'returns nil for nil NPC' do
      result = described_class.send(:fetch_world_memory_context, nil, 'test query', room)
      expect(result).to be_nil
    end

    it 'returns nil when no memories found' do
      allow(WorldMemoryService).to receive(:retrieve_for_npc).and_return([])
      result = described_class.send(:fetch_world_memory_context, npc_character, 'test query', room)
      expect(result).to be_nil
    end

    it 'handles exception gracefully' do
      allow(WorldMemoryService).to receive(:retrieve_for_npc).and_raise(StandardError.new('DB error'))
      result = described_class.send(:fetch_world_memory_context, npc_character, 'test query', room)
      expect(result).to be_nil
    end
  end

  describe 'fetch_clue_context' do
    let(:pc_character) { create(:character) }
    let(:pc_instance) { create(:character_instance, character: pc_character, current_room: room, online: true) }

    before do
      entry.update(trigger_source_id: pc_instance.id)
    end

    it 'retrieves relevant clues when trigger source is a PC' do
      clue_info = [double('Clue', content: 'Important info')]
      allow(ClueService).to receive(:relevant_clues_for).and_return(clue_info)
      allow(ClueService).to receive(:format_for_context).and_return('Formatted clues')

      result = described_class.send(:fetch_clue_context, npc_character, entry)

      expect(ClueService).to have_received(:relevant_clues_for).with(
        npc: npc_character,
        query: entry.trigger_content,
        pc: pc_character,
        limit: 2,
        arranged_scene_id: nil
      )
      expect(result).to eq 'Formatted clues'
    end

    it 'passes arranged scene id for scene-scoped clues' do
      scene = create(
        :arranged_scene,
        :active,
        npc_character: npc_character,
        pc_character: pc_character,
        meeting_room: room,
        rp_room: room
      )
      allow(ClueService).to receive(:relevant_clues_for).and_return([])

      described_class.send(:fetch_clue_context, npc_character, entry)

      expect(ClueService).to have_received(:relevant_clues_for).with(
        hash_including(arranged_scene_id: scene.id)
      )
    end

    it 'does not scope clue lookup to unrelated active scene' do
      other_pc = create(:character)
      other_instance = create(:character_instance, character: other_pc, current_room: room, online: true)
      entry.update(trigger_source_id: other_instance.id)

      create(
        :arranged_scene,
        :active,
        npc_character: npc_character,
        pc_character: pc_character,
        meeting_room: room,
        rp_room: room
      )

      allow(ClueService).to receive(:relevant_clues_for).and_return([])

      described_class.send(:fetch_clue_context, npc_character, entry)

      expect(ClueService).to have_received(:relevant_clues_for).with(
        hash_including(arranged_scene_id: nil)
      )
    end

    it 'returns nil for nil NPC' do
      result = described_class.send(:fetch_clue_context, nil, entry)
      expect(result).to be_nil
    end

    it 'returns nil when trigger source is not set' do
      entry.update(trigger_source_id: nil)
      result = described_class.send(:fetch_clue_context, npc_character, entry)
      expect(result).to be_nil
    end

    it 'returns nil when trigger source is NPC' do
      other_npc = create(:character, :npc)
      other_npc_instance = create(:character_instance, character: other_npc, current_room: room)
      entry.update(trigger_source_id: other_npc_instance.id)

      result = described_class.send(:fetch_clue_context, npc_character, entry)
      expect(result).to be_nil
    end

    it 'returns nil when no clues found' do
      allow(ClueService).to receive(:relevant_clues_for).and_return([])
      result = described_class.send(:fetch_clue_context, npc_character, entry)
      expect(result).to be_nil
    end

    it 'handles exception gracefully' do
      allow(ClueService).to receive(:relevant_clues_for).and_raise(StandardError.new('DB error'))
      result = described_class.send(:fetch_clue_context, npc_character, entry)
      expect(result).to be_nil
    end
  end

  describe 'fetch_lore_context' do
    it 'calls Helpfile.lore_context_for with query' do
      allow(Helpfile).to receive(:lore_context_for).and_return('Some lore')
      result = described_class.send(:fetch_lore_context, 'magic sword')

      expect(Helpfile).to have_received(:lore_context_for).with('magic sword', limit: 2)
      expect(result).to eq 'Some lore'
    end

    it 'returns nil for nil query' do
      result = described_class.send(:fetch_lore_context, nil)
      expect(result).to be_nil
    end

    it 'returns nil for empty query' do
      result = described_class.send(:fetch_lore_context, '   ')
      expect(result).to be_nil
    end

    it 'handles exception gracefully' do
      allow(Helpfile).to receive(:lore_context_for).and_raise(StandardError.new('DB error'))
      result = described_class.send(:fetch_lore_context, 'query')
      expect(result).to be_nil
    end
  end

  describe 'fetch_memory_context' do
    let(:memories) { [double('Memory', content: 'I remember this')] }

    before do
      allow(NpcMemoryService).to receive(:retrieve_relevant).and_return(memories)
      allow(NpcMemoryService).to receive(:format_for_context).and_return('Formatted memories')
    end

    it 'retrieves relevant memories' do
      result = described_class.send(:fetch_memory_context, npc_character, 'test query')

      expect(NpcMemoryService).to have_received(:retrieve_relevant).with(
        npc: npc_character,
        query: 'test query',
        limit: 3,
        include_abstractions: true
      )
      expect(result).to eq 'Formatted memories'
    end

    it 'returns nil for nil NPC' do
      result = described_class.send(:fetch_memory_context, nil, 'test query')
      expect(result).to be_nil
    end

    it 'returns nil for nil query' do
      result = described_class.send(:fetch_memory_context, npc_character, nil)
      expect(result).to be_nil
    end

    it 'returns nil when no memories found' do
      allow(NpcMemoryService).to receive(:retrieve_relevant).and_return([])
      result = described_class.send(:fetch_memory_context, npc_character, 'test query')
      expect(result).to be_nil
    end

    it 'handles exception gracefully' do
      allow(NpcMemoryService).to receive(:retrieve_relevant).and_raise(StandardError.new('DB error'))
      result = described_class.send(:fetch_memory_context, npc_character, 'test query')
      expect(result).to be_nil
    end
  end

  describe 'update_relationship_from_interaction' do
    let(:pc_character) { create(:character) }
    let(:pc_instance) { create(:character_instance, character: pc_character, current_room: room, online: true) }

    before do
      entry.update(trigger_source_id: pc_instance.id)
      allow(NpcRelationshipUpdateJob).to receive(:perform_async).and_return('jid-relationship')
    end

    it 'enqueues a relationship update job' do
      described_class.send(:update_relationship_from_interaction, npc_character, entry, 'waves hello')

      expect(NpcRelationshipUpdateJob).to have_received(:perform_async).with(
        npc_character.id,
        pc_character.id,
        entry.trigger_content,
        'waves hello'
      )
    end

    it 'does nothing when trigger source not set' do
      entry.update(trigger_source_id: nil)
      expect(NpcRelationshipUpdateJob).not_to receive(:perform_async)

      described_class.send(:update_relationship_from_interaction, npc_character, entry, 'waves')
    end

    it 'does nothing when trigger source is NPC' do
      other_npc = create(:character, :npc)
      other_npc_instance = create(:character_instance, character: other_npc, current_room: room)
      entry.update(trigger_source_id: other_npc_instance.id)

      expect(NpcRelationshipUpdateJob).not_to receive(:perform_async)

      described_class.send(:update_relationship_from_interaction, npc_character, entry, 'waves')
    end

    it 'handles exception gracefully' do
      allow(NpcRelationshipUpdateJob).to receive(:perform_async).and_raise(StandardError.new('queue down'))

      expect {
        described_class.send(:update_relationship_from_interaction, npc_character, entry, 'waves')
      }.not_to raise_error
    end
  end

  describe 'store_interaction_memory' do
    let(:pc_character) { create(:character) }
    let(:pc_instance) { create(:character_instance, character: pc_character, current_room: room, online: true) }

    before do
      entry.update(trigger_source_id: pc_instance.id)
    end

    it 'stores memory with correct parameters' do
      described_class.send(:store_interaction_memory, npc_character, entry, 'waves hello')

      expect(NpcMemoryService).to have_received(:store_memory).with(
        npc: npc_character,
        content: kind_of(String),
        about_character: pc_character,
        importance: 4,
        memory_type: 'interaction'
      )
    end

    it 'truncates long content' do
      long_trigger = 'a' * 400
      entry.update(trigger_content: long_trigger)
      long_response = 'b' * 400

      described_class.send(:store_interaction_memory, npc_character, entry, long_response)

      # Verify NpcMemoryService was called with truncated content (ending with ...)
      expect(NpcMemoryService).to have_received(:store_memory).with(
        hash_including(content: end_with('...'))
      )
    end

    it 'handles missing trigger source' do
      entry.update(trigger_source_id: nil)

      described_class.send(:store_interaction_memory, npc_character, entry, 'waves')

      expect(NpcMemoryService).to have_received(:store_memory).with(
        hash_including(about_character: nil)
      )
    end

    it 'handles exception gracefully' do
      allow(NpcMemoryService).to receive(:store_memory).and_raise(StandardError.new('DB error'))

      expect {
        described_class.send(:store_interaction_memory, npc_character, entry, 'waves')
      }.not_to raise_error
    end
  end

  describe 'post_animation_update' do
    let(:pc_character) { create(:character) }
    let(:pc_instance) { create(:character_instance, character: pc_character, current_room: room, online: true) }

    before do
      entry.update(trigger_source_id: pc_instance.id)
      allow(NpcRelationshipUpdateJob).to receive(:perform_async).and_return('jid-relationship')
    end

    it 'stores memory and updates relationship' do
      described_class.send(:post_animation_update, npc_instance, entry, 'waves hello')

      expect(NpcMemoryService).to have_received(:store_memory)
      expect(NpcRelationshipUpdateJob).to have_received(:perform_async).with(
        npc_character.id,
        pc_character.id,
        entry.trigger_content,
        'waves hello'
      )
    end

    it 'does nothing for nil NPC character' do
      allow(npc_instance).to receive(:character).and_return(nil)

      expect(NpcMemoryService).not_to receive(:store_memory)

      described_class.send(:post_animation_update, npc_instance, entry, 'waves')
    end

    it 'handles exception gracefully' do
      allow(NpcMemoryService).to receive(:store_memory).and_raise(StandardError.new('DB error'))

      expect {
        described_class.send(:post_animation_update, npc_instance, entry, 'waves')
      }.not_to raise_error
    end
  end

  describe 'valid_npc_state?' do
    it 'returns true when NPC is online and in correct room' do
      result = described_class.send(:valid_npc_state?, npc_instance, entry)
      expect(result).to be true
    end

    it 'returns falsey for nil instance' do
      result = described_class.send(:valid_npc_state?, nil, entry)
      expect(result).to be_falsey
    end

    it 'returns false when NPC is offline' do
      npc_instance.update(online: false)
      result = described_class.send(:valid_npc_state?, npc_instance, entry)
      expect(result).to be false
    end

    it 'returns false when NPC is in different room' do
      other_room = create(:room)
      npc_instance.update(current_room_id: other_room.id)
      result = described_class.send(:valid_npc_state?, npc_instance, entry)
      expect(result).to be false
    end
  end

  describe 'build_context' do
    let(:pc_character) { create(:character, short_desc: 'A tall warrior') }
    let!(:pc_instance) { create(:character_instance, character: pc_character, current_room: room, online: true) }

    before do
      allow(Helpfile).to receive(:lore_context_for).and_return(nil)
      allow(NpcMemoryService).to receive(:retrieve_relevant).and_return([])
      allow(WorldMemoryService).to receive(:retrieve_for_npc).and_return([])
      allow(ClueService).to receive(:relevant_clues_for).and_return([])
      allow(ReputationService).to receive(:reputation_for).and_return(nil)
      allow(NpcRelationship).to receive(:find_or_create_for).and_return(
        double('NpcRelationship',
               knowledge_tier: 1,
               knowledge_label: 'stranger',
               to_context_string: 'Stranger')
      )
      allow(NpcRelationship).to receive(:for_npc).and_return(NpcRelationship.where(id: -1))
    end

    it 'includes current conditions' do
      result = described_class.send(:build_context, npc_instance, entry)

      expect(result).to include('CURRENT CONDITIONS')
      expect(result).to include(room.name)
    end

    it 'includes people present' do
      result = described_class.send(:build_context, npc_instance, entry)

      expect(result).to include('PEOPLE PRESENT')
      expect(result).to include(pc_character.full_name)
    end

    it 'includes NPC current state when set' do
      npc_instance.update(roomtitle: 'leaning against the wall')
      result = described_class.send(:build_context, npc_instance, entry)

      expect(result).to include('YOUR CURRENT STATE')
      expect(result).to include('leaning against the wall')
    end

    it 'excludes NPC current state when empty' do
      npc_instance.update(roomtitle: nil)
      result = described_class.send(:build_context, npc_instance, entry)

      expect(result).not_to include('YOUR CURRENT STATE')
    end

    it 'includes lore when available' do
      allow(Helpfile).to receive(:lore_context_for).and_return('Ancient lore about dragons')
      result = described_class.send(:build_context, npc_instance, entry)

      expect(result).to include('RELEVANT BACKGROUND INFORMATION')
      expect(result).to include('dragons')
    end

    it 'includes memories when available' do
      allow(NpcMemoryService).to receive(:retrieve_relevant).and_return([double('Memory')])
      allow(NpcMemoryService).to receive(:format_for_context).and_return('I remember meeting them')
      result = described_class.send(:build_context, npc_instance, entry)

      expect(result).to include('RELEVANT MEMORIES')
      expect(result).to include('meeting them')
    end

    it 'includes world memories when available' do
      allow(WorldMemoryService).to receive(:retrieve_for_npc).and_return([double('WorldMemory')])
      allow(WorldMemoryService).to receive(:format_for_npc_context).and_return('The battle happened')
      result = described_class.send(:build_context, npc_instance, entry)

      expect(result).to include('WORLD EVENTS')
      expect(result).to include('battle')
    end
  end

  describe 'seed_instruction_prompt' do
    it 'returns empty string when not in seed mode' do
      allow(npc_instance).to receive(:seed_mode?).and_return(false)
      result = described_class.send(:seed_instruction_prompt, npc_instance)

      expect(result).to eq ''
    end

    it 'returns instruction when in seed mode' do
      allow(npc_instance).to receive(:seed_mode?).and_return(true)
      allow(npc_instance).to receive(:puppet_instruction).and_return('Ask about the weather')
      result = described_class.send(:seed_instruction_prompt, npc_instance)

      expect(result).to include('SPECIAL INSTRUCTION')
      expect(result).to include('weather')
    end
  end

  describe 'try_fallback_models' do
    let(:system_prompt) { 'You are an NPC' }
    let(:messages) { [{ role: 'user', content: 'Hello' }] }

    before do
      allow(archetype).to receive(:fallback_models).and_return(['gemini-pro', 'openrouter/llama'])
    end

    it 'tries fallback models when primary fails' do
      allow(LLM::Client).to receive(:generate)
        .and_return({ success: false, error: 'Rate limit' })
        .and_return({ success: true, text: 'Fallback response' })

      result = described_class.send(:try_fallback_models, archetype, system_prompt, messages, 'TestNpc')

      expect(result[:success]).to be true
    end

    it 'returns failure when all fallbacks fail' do
      allow(archetype).to receive(:fallback_models).and_return(['model1'])
      allow(LLM::Client).to receive(:generate).and_return({ success: false, error: 'All failed' })

      result = described_class.send(:try_fallback_models, archetype, system_prompt, messages, 'TestNpc')

      expect(result[:success]).to be false
      expect(result[:error]).to include('All fallback models failed')
    end
  end
end
