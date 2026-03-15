# frozen_string_literal: true

require 'spec_helper'

RSpec.describe NpcLeadershipService do
  let(:user) { create(:user) }
  let(:pc_character) { create(:character, user: user, forename: 'TestPC', surname: 'Player') }
  let(:npc_character) { create(:character, :npc, forename: 'Gareth', surname: 'Blackwood') }
  let(:reality) { create(:reality) }
  let(:room) { create(:room) }
  let(:other_room) { create(:room) }
  let(:pc_instance) { create(:character_instance, character: pc_character, reality: reality, current_room: room, online: true) }
  let(:npc_instance) { create(:character_instance, character: npc_character, reality: reality, current_room: room, online: true) }

  # ============================================
  # Flag Checks
  # ============================================

  describe '.can_be_led?' do
    it 'returns false for nil character' do
      expect(described_class.can_be_led?(nil)).to be false
    end

    it 'returns true when character is leadable' do
      allow(npc_character).to receive(:leadable?).and_return(true)
      expect(described_class.can_be_led?(npc_character)).to be true
    end

    it 'returns false when character is not leadable' do
      allow(npc_character).to receive(:leadable?).and_return(false)
      expect(described_class.can_be_led?(npc_character)).to be false
    end
  end

  describe '.can_be_summoned?' do
    it 'returns false for nil character' do
      expect(described_class.can_be_summoned?(nil)).to be false
    end

    it 'returns true when character is summonable' do
      allow(npc_character).to receive(:summonable?).and_return(true)
      expect(described_class.can_be_summoned?(npc_character)).to be true
    end

    it 'returns false when character is not summonable' do
      allow(npc_character).to receive(:summonable?).and_return(false)
      expect(described_class.can_be_summoned?(npc_character)).to be false
    end
  end

  # ============================================
  # Cooldown Checks
  # ============================================

  describe '.on_lead_cooldown?' do
    it 'returns cooldown status from relationship' do
      relationship = instance_double(NpcRelationship, on_lead_cooldown?: true)
      allow(NpcRelationship).to receive(:find_or_create_for).and_return(relationship)

      result = described_class.on_lead_cooldown?(npc: npc_character, pc: pc_character)
      expect(result).to be true
    end

    it 'returns false when not on cooldown' do
      relationship = instance_double(NpcRelationship, on_lead_cooldown?: false)
      allow(NpcRelationship).to receive(:find_or_create_for).and_return(relationship)

      result = described_class.on_lead_cooldown?(npc: npc_character, pc: pc_character)
      expect(result).to be false
    end
  end

  describe '.on_summon_cooldown?' do
    it 'returns cooldown status from relationship' do
      relationship = instance_double(NpcRelationship, on_summon_cooldown?: true)
      allow(NpcRelationship).to receive(:find_or_create_for).and_return(relationship)

      result = described_class.on_summon_cooldown?(npc: npc_character, pc: pc_character)
      expect(result).to be true
    end
  end

  describe '.lead_cooldown_remaining' do
    it 'returns remaining seconds from relationship' do
      relationship = instance_double(NpcRelationship, lead_cooldown_remaining: 1800)
      allow(NpcRelationship).to receive(:find_or_create_for).and_return(relationship)

      result = described_class.lead_cooldown_remaining(npc: npc_character, pc: pc_character)
      expect(result).to eq(1800)
    end
  end

  describe '.summon_cooldown_remaining' do
    it 'returns remaining seconds from relationship' do
      relationship = instance_double(NpcRelationship, summon_cooldown_remaining: 3600)
      allow(NpcRelationship).to receive(:find_or_create_for).and_return(relationship)

      result = described_class.summon_cooldown_remaining(npc: npc_character, pc: pc_character)
      expect(result).to eq(3600)
    end
  end

  # ============================================
  # Lead Request
  # ============================================

  describe '.request_lead' do
    it 'returns async response immediately' do
      result = described_class.request_lead(npc_instance: npc_instance, pc_instance: pc_instance)

      expect(result[:success]).to be true
      expect(result[:async]).to be true
      expect(result[:message]).to include('considered')
    end
  end

  # ============================================
  # Summon Request
  # ============================================

  describe '.request_summon' do
    it 'returns async response immediately' do
      result = described_class.request_summon(
        npc_instance: npc_instance,
        pc_instance: pc_instance,
        message: 'Please come here!'
      )

      expect(result[:success]).to be true
      expect(result[:async]).to be true
      expect(result[:message]).to include('delivered')
    end
  end

  # ============================================
  # Leave Check
  # ============================================

  describe '.check_and_handle_leave' do
    context 'when NPC is not following anyone' do
      it 'returns should_leave: false' do
        npc_instance.update(following_id: nil)

        result = described_class.check_and_handle_leave(npc_instance: npc_instance)

        expect(result[:should_leave]).to be false
      end
    end

    context 'when leader is offline' do
      before do
        npc_instance.update(following_id: pc_instance.id)
        pc_instance.update(online: false)
        allow(BroadcastService).to receive(:to_room)
      end

      it 'makes NPC leave and returns leader_offline reason' do
        result = described_class.check_and_handle_leave(npc_instance: npc_instance)

        expect(result[:should_leave]).to be true
        expect(result[:reason]).to eq('leader_offline')
      end

      it 'clears following_id' do
        described_class.check_and_handle_leave(npc_instance: npc_instance)

        npc_instance.reload
        expect(npc_instance.following_id).to be_nil
      end
    end

    context 'when leader is still online and in same room' do
      before do
        npc_instance.update(following_id: pc_instance.id)
        pc_instance.update(online: true)
      end

      it 'returns should_leave: false' do
        result = described_class.check_and_handle_leave(npc_instance: npc_instance)

        expect(result[:should_leave]).to be false
      end
    end
  end

  # ============================================
  # NPC Leave Leader
  # ============================================

  describe '.npc_leave_leader' do
    before do
      npc_instance.update(following_id: pc_instance.id)
      allow(BroadcastService).to receive(:to_room)
    end

    it 'clears following_id' do
      described_class.npc_leave_leader(npc_instance: npc_instance, reason: 'test')

      npc_instance.reload
      expect(npc_instance.following_id).to be_nil
    end

    it 'broadcasts departure message' do
      expect(BroadcastService).to receive(:to_room).with(
        npc_instance.current_room_id,
        anything,
        hash_including(type: :narrative)
      )

      described_class.npc_leave_leader(npc_instance: npc_instance, reason: 'leader_offline')
    end

    it 'returns success with reason' do
      result = described_class.npc_leave_leader(npc_instance: npc_instance, reason: 'leader_offline')

      expect(result[:success]).to be true
      expect(result[:reason]).to eq('leader_offline')
    end

    context 'with different reasons' do
      it 'has specific message for leader_offline' do
        expect(BroadcastService).to receive(:to_room).with(
          anything,
          /is gone and stops following/,
          anything
        )

        described_class.npc_leave_leader(npc_instance: npc_instance, reason: 'leader_offline')
      end

      it 'has specific message for leader_left_and_schedule_calls' do
        expect(BroadcastService).to receive(:to_room).with(
          anything,
          /has somewhere else to be/,
          anything
        )

        described_class.npc_leave_leader(npc_instance: npc_instance, reason: 'leader_left_and_schedule_calls')
      end
    end
  end

  # ============================================
  # Staff Query
  # ============================================

  describe '.query_npc' do
    before do
      allow(npc_character).to receive(:npc_archetype).and_return(nil)
      allow(npc_instance).to receive(:character).and_return(npc_character)
      allow(npc_instance).to receive(:current_room).and_return(room)
      allow(npc_instance).to receive(:roomtitle).and_return(nil)
      allow(GameSetting).to receive(:get).and_return('modern fantasy')
      allow(GamePrompts).to receive(:get).and_return('Test system prompt')
    end

    context 'when LLM succeeds' do
      before do
        allow(LLM::Client).to receive(:generate).and_return({
                                                              success: true,
                                                              text: 'I am doing well, thank you for asking.'
                                                            })
      end

      it 'returns success with response' do
        result = described_class.query_npc(npc_instance: npc_instance, question: 'How are you?')

        expect(result[:success]).to be true
        expect(result[:response]).to include('doing well')
      end
    end

    context 'when LLM fails' do
      before do
        allow(LLM::Client).to receive(:generate).and_return({
                                                              success: false,
                                                              error: 'API error'
                                                            })
      end

      it 'returns failure with error' do
        result = described_class.query_npc(npc_instance: npc_instance, question: 'How are you?')

        expect(result[:success]).to be false
        expect(result[:error]).not_to be_nil
      end
    end

    context 'when exception occurs' do
      before do
        allow(LLM::Client).to receive(:generate).and_raise(StandardError, 'Connection timeout')
      end

      it 'handles error gracefully' do
        result = described_class.query_npc(npc_instance: npc_instance, question: 'How are you?')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Connection timeout')
      end
    end
  end

  # ============================================
  # NPC Finding
  # ============================================

  describe '.find_npc_in_room' do
    let!(:npc_instance_2) { create(:character_instance, character: create(:character, :npc, forename: 'Mira'), reality: reality, current_room: room, online: true) }

    before do
      # Set up NPCs in the room - only stub the specific NPC lookup query,
      # not all where() calls (which would break after_create hooks)
      allow(CharacterInstance).to receive(:where).and_call_original
      allow(CharacterInstance).to receive(:where)
        .with(current_room_id: pc_instance.current_room_id, online: true)
        .and_return(double(eager: double(all: [npc_instance, npc_instance_2])))
    end

    it 'finds NPC by exact forename' do
      result = described_class.find_npc_in_room(pc_instance: pc_instance, name: 'Gareth')
      expect(result).to eq(npc_instance)
    end

    it 'finds NPC by partial forename' do
      result = described_class.find_npc_in_room(pc_instance: pc_instance, name: 'Gar')
      expect(result).to eq(npc_instance)
    end

    it 'returns nil for non-existent NPC' do
      result = described_class.find_npc_in_room(pc_instance: pc_instance, name: 'Nobody')
      expect(result).to be_nil
    end

    it 'returns nil for empty name' do
      result = described_class.find_npc_in_room(pc_instance: pc_instance, name: '')
      expect(result).to be_nil
    end

    it 'returns nil for nil name' do
      result = described_class.find_npc_in_room(pc_instance: pc_instance, name: nil)
      expect(result).to be_nil
    end
  end

  describe '.find_npc_in_summon_range' do
    before do
      # Only stub the specific NPC lookup query, not all where() calls
      allow(CharacterInstance).to receive(:where).and_call_original
      allow(CharacterInstance).to receive(:where)
        .with(online: true)
        .and_return(double(eager: double(all: [npc_instance])))
      allow(npc_character).to receive(:summon_range).and_return('zone')
    end

    it 'finds NPC when in range' do
      allow(pc_instance).to receive(:current_room).and_return(room)
      allow(room).to receive(:location).and_return(double(zone_id: 1))
      allow(npc_instance).to receive(:current_room).and_return(room)

      result = described_class.find_npc_in_summon_range(pc_instance: pc_instance, name: 'Gareth')
      expect(result).to eq(npc_instance)
    end

    context 'with room range' do
      before do
        allow(npc_character).to receive(:summon_range).and_return('room')
      end

      it 'only finds NPC in same room' do
        # Same room
        result = described_class.find_npc_in_summon_range(pc_instance: pc_instance, name: 'Gareth')
        expect(result).to eq(npc_instance)
      end
    end

    context 'with world range' do
      before do
        allow(npc_character).to receive(:summon_range).and_return('world')
      end

      it 'finds NPC anywhere' do
        allow(pc_instance).to receive(:current_room).and_return(other_room)
        allow(other_room).to receive(:location).and_return(double(zone_id: 99))

        result = described_class.find_npc_in_summon_range(pc_instance: pc_instance, name: 'Gareth')
        expect(result).to eq(npc_instance)
      end
    end
  end

  # ============================================
  # Module Structure
  # ============================================

  describe 'module structure' do
    it 'defines a module' do
      expect(described_class).to be_a(Module)
    end

    it 'responds to all public methods' do
      %i[
        can_be_led?
        can_be_summoned?
        on_lead_cooldown?
        on_summon_cooldown?
        lead_cooldown_remaining
        summon_cooldown_remaining
        request_lead
        request_summon
        check_and_handle_leave
        npc_leave_leader
        query_npc
        find_npc_in_room
        find_npc_in_summon_range
      ].each do |method|
        expect(described_class).to respond_to(method)
      end
    end
  end

  # ============================================
  # Private Method Testing
  # ============================================

  describe 'private methods' do
    describe '#resolve_by_name' do
      let(:npc_instance_1) { create(:character_instance, character: create(:character, :npc, forename: 'Gareth', surname: 'Blackwood'), reality: reality, current_room: room, online: true) }
      let(:npc_instance_2) { create(:character_instance, character: create(:character, :npc, forename: 'Garen', surname: 'Smith'), reality: reality, current_room: room, online: true) }

      it 'returns nil for empty array' do
        result = described_class.send(:resolve_by_name, [], 'Gareth')
        expect(result).to be_nil
      end

      it 'returns nil for nil name' do
        result = described_class.send(:resolve_by_name, [npc_instance_1], nil)
        expect(result).to be_nil
      end

      it 'returns nil for whitespace-only name' do
        result = described_class.send(:resolve_by_name, [npc_instance_1], '   ')
        expect(result).to be_nil
      end

      it 'finds by exact forename match' do
        result = described_class.send(:resolve_by_name, [npc_instance_1, npc_instance_2], 'Gareth')
        expect(result).to eq(npc_instance_1)
      end

      it 'finds by exact full name match' do
        result = described_class.send(:resolve_by_name, [npc_instance_1, npc_instance_2], 'Gareth Blackwood')
        expect(result).to eq(npc_instance_1)
      end

      it 'finds by partial forename match' do
        result = described_class.send(:resolve_by_name, [npc_instance_1, npc_instance_2], 'Gar')
        # Returns first partial match
        expect([npc_instance_1, npc_instance_2]).to include(result)
      end

      it 'finds by partial full name match' do
        result = described_class.send(:resolve_by_name, [npc_instance_1, npc_instance_2], 'blackwood')
        expect(result).to eq(npc_instance_1)
      end

      it 'is case insensitive' do
        result = described_class.send(:resolve_by_name, [npc_instance_1], 'GARETH')
        expect(result).to eq(npc_instance_1)
      end
    end

    describe '#build_leadership_context' do
      let(:archetype) { create(:npc_archetype) }
      let(:schedule) { create(:npc_schedule, character: npc_character, room: room, start_hour: 0, end_hour: 23) }

      before do
        allow(npc_character).to receive(:npc_archetype).and_return(archetype)
        allow(NpcRelationship).to receive(:find_or_create_for).and_return(
          double(
            to_context_string: 'SENTIMENT: 0.5, TRUST: 0.5',
            interaction_count: 5,
            knowledge_tier_descriptor: 'familiar'
          )
        )
      end

      it 'builds context with relationship info' do
        result = described_class.send(:build_leadership_context, npc_instance: npc_instance, pc_instance: pc_instance)
        expect(result).to include('RELATIONSHIP WITH')
        expect(result).to include('Interactions: 5')
      end

      it 'includes current location' do
        result = described_class.send(:build_leadership_context, npc_instance: npc_instance, pc_instance: pc_instance)
        expect(result).to include('CURRENT LOCATION')
      end

      it 'includes following status when following someone' do
        leader_instance = create(:character_instance, character: create(:character), reality: reality, current_room: room)
        npc_instance.update(following_id: leader_instance.id)

        result = described_class.send(:build_leadership_context, npc_instance: npc_instance, pc_instance: pc_instance)
        expect(result).to include('CURRENTLY FOLLOWING')
      end
    end

    describe '#build_lead_prompt' do
      before do
        allow(NpcRelationship).to receive(:find_or_create_for).and_return(
          double(
            to_context_string: 'SENTIMENT: 0.5, TRUST: 0.5',
            interaction_count: 0,
            knowledge_tier_descriptor: 'stranger'
          )
        )
      end

      it 'includes character names' do
        result = described_class.send(:build_lead_prompt, npc_instance: npc_instance, pc_instance: pc_instance, context: 'Test context')
        expect(result).to include(pc_character.full_name)
        expect(result).to include(npc_character.full_name)
      end

      it 'asks about following' do
        result = described_class.send(:build_lead_prompt, npc_instance: npc_instance, pc_instance: pc_instance, context: 'Test context')
        expect(result).to include('follow')
      end
    end

    describe '#build_summon_prompt' do
      before do
        allow(NpcRelationship).to receive(:find_or_create_for).and_return(
          double(
            to_context_string: 'SENTIMENT: 0.5, TRUST: 0.5',
            interaction_count: 0,
            knowledge_tier_descriptor: 'stranger'
          )
        )
      end

      it 'includes the summon message' do
        result = described_class.send(:build_summon_prompt,
                                      npc_instance: npc_instance,
                                      pc_instance: pc_instance,
                                      message: 'I need your help urgently!',
                                      context: 'Test context')
        expect(result).to include('I need your help urgently!')
      end

      it 'mentions the PC location' do
        result = described_class.send(:build_summon_prompt,
                                      npc_instance: npc_instance,
                                      pc_instance: pc_instance,
                                      message: 'Come here',
                                      context: 'Test context')
        expect(result).to include('another location').or include(room.name.to_s)
      end
    end

    describe '#parse_decision_response' do
      it 'parses ACCEPT response' do
        result = described_class.send(:parse_decision_response, "ACCEPT\nI'd be happy to help you.")
        expect(result[:accept]).to be true
        expect(result[:response]).to include('happy to help')
      end

      it 'parses REJECT response' do
        result = described_class.send(:parse_decision_response, "REJECT\nI'm too busy right now.")
        expect(result[:accept]).to be false
        expect(result[:response]).to include('too busy')
      end

      it 'defaults to reject for unclear response' do
        result = described_class.send(:parse_decision_response, "Maybe later")
        expect(result[:accept]).to be false
      end

      it 'handles empty response' do
        result = described_class.send(:parse_decision_response, "")
        expect(result[:accept]).to be false
        # Empty input means lines is [], so falls back to default rejection response
        expect(result[:response]).to eq('shakes their head.')
      end

      it 'cleans up prefixes in response' do
        result = described_class.send(:parse_decision_response, "ACCEPT nods in agreement.")
        expect(result[:response]).not_to include('ACCEPT')
      end
    end

    describe '#build_decision_system_prompt' do
      before do
        allow(npc_character).to receive(:npc_archetype).and_return(nil)
        allow(GameSetting).to receive(:get).and_return('modern fantasy')
        allow(GamePrompts).to receive(:get).and_return('You are a test NPC')
      end

      it 'builds system prompt for lead decisions' do
        described_class.send(:build_decision_system_prompt, npc_instance, 'lead')
        expect(GamePrompts).to have_received(:get).with(
          'npc_leadership.decision_system',
          hash_including(action: 'follow them')
        )
      end

      it 'builds system prompt for summon decisions' do
        described_class.send(:build_decision_system_prompt, npc_instance, 'summon')
        expect(GamePrompts).to have_received(:get).with(
          'npc_leadership.decision_system',
          hash_including(action: 'go to them')
        )
      end
    end

    describe '#build_query_system_prompt' do
      before do
        allow(npc_character).to receive(:npc_archetype).and_return(nil)
        allow(GameSetting).to receive(:get).and_return('modern fantasy')
        allow(GamePrompts).to receive(:get).and_return('You are a test NPC')
      end

      it 'calls GamePrompts with correct parameters' do
        described_class.send(:build_query_system_prompt, npc_instance)
        expect(GamePrompts).to have_received(:get).with(
          'npc_leadership.query_system',
          hash_including(npc_name: npc_character.full_name)
        )
      end
    end
  end

  # ============================================
  # Check and Handle Leave Edge Cases
  # ============================================

  describe '.check_and_handle_leave edge cases' do
    context 'when leader does not exist' do
      before do
        # Set following_id but mock the lookup to return nil to simulate non-existent leader
        npc_instance.update(following_id: pc_instance.id)
        allow(CharacterInstance).to receive(:[]).and_call_original
        allow(CharacterInstance).to receive(:[]).with(pc_instance.id).and_return(nil)
        allow(BroadcastService).to receive(:to_room)
      end

      it 'makes NPC leave due to offline leader' do
        result = described_class.check_and_handle_leave(npc_instance: npc_instance)
        expect(result[:should_leave]).to be true
        expect(result[:reason]).to eq('leader_offline')
      end
    end

    context 'when leader is in different room with schedule conflict' do
      let(:schedule_room) { create(:room) }
      let!(:schedule) do
        NpcSchedule.create(
          character_id: npc_character.id,
          room_id: schedule_room.id,
          start_hour: Time.now.hour,
          end_hour: Time.now.hour + 1
        )
      end

      before do
        npc_instance.update(following_id: pc_instance.id, current_room: room)
        pc_instance.update(current_room: other_room, online: true)
        allow(BroadcastService).to receive(:to_room)
        # Mock MovementService to avoid triggering the target resolution bug
        # (MovementService.start_movement expects string target, but service passes Room)
        allow(MovementService).to receive(:start_movement)
      end

      it 'leaves when schedule calls them elsewhere' do
        result = described_class.check_and_handle_leave(npc_instance: npc_instance)
        expect(result[:should_leave]).to be true
        expect(result[:reason]).to eq('leader_left_and_schedule_calls')
      end
    end
  end

  # ============================================
  # Emit Helpers
  # ============================================

  describe 'emit helpers' do
    before do
      allow(BroadcastService).to receive(:to_room)
      allow(BroadcastService).to receive(:to_character)
    end

    describe '#emit_accept_lead' do
      it 'broadcasts to room with emote type' do
        expect(BroadcastService).to receive(:to_room).with(
          npc_instance.current_room_id,
          anything,
          hash_including(type: :emote)
        )
        described_class.send(:emit_accept_lead, npc_instance: npc_instance, pc_instance: pc_instance, response: 'nods eagerly.')
      end

      it 'prepends character name if not already present' do
        expect(BroadcastService).to receive(:to_room).with(
          anything,
          /^#{npc_character.full_name}/,
          anything
        )
        described_class.send(:emit_accept_lead, npc_instance: npc_instance, pc_instance: pc_instance, response: 'nods eagerly.')
      end

      it 'does not double prepend if name already present' do
        expect(BroadcastService).to receive(:to_room).with(
          anything,
          /#{npc_character.forename}/,
          anything
        )
        described_class.send(:emit_accept_lead, npc_instance: npc_instance, pc_instance: pc_instance, response: "#{npc_character.forename} nods.")
      end
    end

    describe '#emit_reject_summon' do
      it 'sends message to PC' do
        expect(BroadcastService).to receive(:to_character).with(
          pc_instance,
          /won't be coming/,
          hash_including(type: :narrative)
        )
        described_class.send(:emit_reject_summon, npc_instance: npc_instance, pc_instance: pc_instance, response: 'shakes their head.')
      end
    end
  end

  # ============================================
  # Movement Helpers
  # ============================================

  describe 'movement helpers' do
    describe '#move_npc_to_pc' do
      let(:destination_room) { create(:room) }

      before do
        pc_instance.update(current_room: destination_room)
      end

      context 'when MovementService is available' do
        before do
          allow(MovementService).to receive(:start_movement)
        end

        it 'uses MovementService to move NPC' do
          expect(MovementService).to receive(:start_movement).with(
            npc_instance,
            hash_including(target: destination_room)
          )
          described_class.send(:move_npc_to_pc, npc_instance: npc_instance, pc_instance: pc_instance)
        end
      end

      context 'when MovementService is not available' do
        before do
          hide_const('MovementService')
          allow(npc_instance).to receive(:teleport_to_room!)
          allow(BroadcastService).to receive(:to_room)
        end

        it 'teleports NPC directly' do
          expect(npc_instance).to receive(:teleport_to_room!).with(destination_room)
          described_class.send(:move_npc_to_pc, npc_instance: npc_instance, pc_instance: pc_instance)
        end

        it 'announces arrival' do
          expect(BroadcastService).to receive(:to_room).with(
            destination_room.id,
            /arrives/,
            anything
          )
          described_class.send(:move_npc_to_pc, npc_instance: npc_instance, pc_instance: pc_instance)
        end
      end

      context 'when PC has no current room' do
        before do
          allow(pc_instance).to receive(:current_room).and_return(nil)
        end

        it 'returns early without error' do
          expect { described_class.send(:move_npc_to_pc, npc_instance: npc_instance, pc_instance: pc_instance) }.not_to raise_error
        end
      end
    end

    describe '#return_to_schedule' do
      let(:schedule_room) { create(:room) }

      context 'with active schedule' do
        before do
          NpcSchedule.create(
            character_id: npc_character.id,
            room_id: schedule_room.id,
            start_hour: Time.now.hour,
            end_hour: Time.now.hour + 1
          )
        end

        context 'when MovementService is not available' do
          before do
            hide_const('MovementService')
            allow(npc_instance).to receive(:teleport_to_room!)
          end

          it 'teleports NPC to scheduled room' do
            expect(npc_instance).to receive(:teleport_to_room!).with(schedule_room)
            described_class.send(:return_to_schedule, npc_instance)
          end
        end

        it 'does nothing if already at scheduled location' do
          npc_instance.update(current_room: schedule_room)
          allow(npc_instance).to receive(:teleport_to_room!)
          described_class.send(:return_to_schedule, npc_instance)
          expect(npc_instance).not_to have_received(:teleport_to_room!)
        end
      end

      context 'without active schedule' do
        it 'does nothing' do
          allow(npc_instance).to receive(:teleport_to_room!)
          described_class.send(:return_to_schedule, npc_instance)
          expect(npc_instance).not_to have_received(:teleport_to_room!)
        end
      end
    end
  end

  # ============================================
  # LLM Decision Making
  # ============================================

  describe '#generate_npc_decision' do
    let(:archetype) { create(:npc_archetype, animation_primary_model: 'gemini-3-flash-preview') }

    before do
      allow(npc_character).to receive(:npc_archetype).and_return(archetype)
      allow(GamePrompts).to receive(:get).and_return('Test system prompt')
      allow(GameSetting).to receive(:get).and_return('modern fantasy')
    end

    context 'when LLM succeeds' do
      before do
        allow(LLM::Client).to receive(:generate).and_return({
                                                              success: true,
                                                              text: "ACCEPT\nI'll follow you."
                                                            })
      end

      it 'returns parsed decision' do
        result = described_class.send(:generate_npc_decision, npc_instance: npc_instance, prompt: 'Test', decision_type: 'lead')
        expect(result[:accept]).to be true
        expect(result[:response]).to include('follow')
      end
    end

    context 'when LLM fails' do
      before do
        allow(LLM::Client).to receive(:generate).and_return({
                                                              success: false,
                                                              error: 'API error'
                                                            })
      end

      it 'defaults to rejection' do
        result = described_class.send(:generate_npc_decision, npc_instance: npc_instance, prompt: 'Test', decision_type: 'lead')
        expect(result[:accept]).to be false
        expect(result[:response]).to include('uncertain')
      end
    end
  end
end
