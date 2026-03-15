# frozen_string_literal: true

require 'spec_helper'

# Skip if triggers table doesn't exist
return unless DB.table_exists?(:triggers)

RSpec.describe TriggerService do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area) }
  let(:room) { create(:room, location: location) }
  let(:reality) { create(:reality) }

  let(:user) { create(:user) }
  let(:character) { create(:character, user: user, forename: 'Alice') }
  let(:character_instance) do
    create(:character_instance,
           character: character,
           reality: reality,
           current_room: room,
           online: true,
           status: 'alive')
  end

  let(:npc_character) { create(:character, :npc, forename: 'Guide') }
  let(:npc_instance) do
    create(:character_instance,
           character: npc_character,
           reality: reality,
           current_room: room,
           online: true,
           status: 'alive')
  end

  before do
    allow(StaffAlertService).to receive(:send_trigger_alert) if defined?(StaffAlertService)
    allow(TriggerCodeExecutor).to receive(:execute).and_return('executed') if defined?(TriggerCodeExecutor)
  end

  describe 'module structure' do
    it 'is a module' do
      expect(TriggerService).to be_a(Module)
    end

    it 'responds to check_mission_triggers' do
      expect(TriggerService).to respond_to(:check_mission_triggers)
    end

    it 'responds to check_npc_triggers' do
      expect(TriggerService).to respond_to(:check_npc_triggers)
    end

    it 'responds to check_npc_triggers_async' do
      expect(TriggerService).to respond_to(:check_npc_triggers_async)
    end

    it 'responds to check_world_memory_triggers' do
      expect(TriggerService).to respond_to(:check_world_memory_triggers)
    end

    it 'responds to check_clue_share_triggers' do
      expect(TriggerService).to respond_to(:check_clue_share_triggers)
    end
  end

  describe '.check_npc_triggers' do
    context 'with empty emote content' do
      it 'returns early without checking' do
        expect {
          described_class.check_npc_triggers(
            npc_instance: npc_instance,
            emote_content: ''
          )
        }.not_to change { TriggerActivation.count }
      end

      it 'returns early with nil content' do
        expect {
          described_class.check_npc_triggers(
            npc_instance: npc_instance,
            emote_content: nil
          )
        }.not_to change { TriggerActivation.count }
      end

      it 'returns early with whitespace content' do
        expect {
          described_class.check_npc_triggers(
            npc_instance: npc_instance,
            emote_content: '   '
          )
        }.not_to change { TriggerActivation.count }
      end
    end

    context 'with non-NPC character' do
      it 'returns early without checking triggers' do
        expect {
          described_class.check_npc_triggers(
            npc_instance: character_instance,
            emote_content: 'The character attacks!'
          )
        }.not_to change { TriggerActivation.count }
      end
    end

    context 'with valid NPC and emote' do
      let!(:trigger) do
        Trigger.create(
          trigger_type: 'npc',
          name: 'Test Trigger',
          is_active: true,
          condition_type: 'contains',
          condition_value: 'attack',
          action_type: 'code_block',
          npc_character_id: npc_character.id
        )
      end

      it 'finds applicable triggers for NPC' do
        allow(trigger).to receive(:applies_to_npc?).and_return(true)

        expect {
          described_class.check_npc_triggers(
            npc_instance: npc_instance,
            emote_content: 'The guard prepares to attack!'
          )
        }.to change { TriggerActivation.count }.by(1)
      end
    end

    context 'with scene-specific triggers' do
      let!(:global_trigger) do
        Trigger.create(
          trigger_type: 'npc',
          name: 'Global Trigger',
          is_active: true,
          condition_type: 'contains',
          condition_value: 'test',
          action_type: 'code_block',
          arranged_scene_id: nil,
          npc_character_id: npc_character.id
        )
      end

      let!(:scene_trigger) do
        Trigger.create(
          trigger_type: 'npc',
          name: 'Scene Trigger',
          is_active: true,
          condition_type: 'contains',
          condition_value: 'test',
          action_type: 'code_block',
          arranged_scene_id: 999,
          npc_character_id: npc_character.id
        )
      end

      it 'includes global triggers when not in a scene' do
        described_class.check_npc_triggers(
          npc_instance: npc_instance,
          emote_content: 'test message'
        )

        # Global trigger should be activated
        expect(TriggerActivation.where(trigger_id: global_trigger.id).count).to eq(1)
      end

      it 'includes both global and scene triggers when in a scene' do
        described_class.check_npc_triggers(
          npc_instance: npc_instance,
          emote_content: 'test message',
          arranged_scene_id: 999
        )

        expect(TriggerActivation.where(trigger_id: global_trigger.id).count).to eq(1)
        expect(TriggerActivation.where(trigger_id: scene_trigger.id).count).to eq(1)
      end
    end
  end

  describe '.check_npc_triggers_async' do
    it 'returns a Thread object' do
      thread = described_class.check_npc_triggers_async(
        npc_instance: npc_instance,
        emote_content: 'test async'
      )

      expect(thread).to be_a(Thread)
      thread.join # Wait for completion
    end

    it 'calls check_npc_triggers in the thread' do
      allow(described_class).to receive(:check_npc_triggers)

      thread = described_class.check_npc_triggers_async(
        npc_instance: npc_instance,
        emote_content: 'test async'
      )
      thread.join

      expect(described_class).to have_received(:check_npc_triggers)
    end
  end

  describe '.check_mission_triggers' do
    let(:activity) { create(:activity) }
    let(:activity_instance) { create(:activity_instance, activity: activity, initiator: character) }

    context 'with matching mission trigger' do
      let!(:trigger) do
        Trigger.create(
          trigger_type: 'mission',
          name: 'Mission Success Trigger',
          is_active: true,
          condition_type: 'contains',
          action_type: 'code_block',
          activity_id: activity.id,
          mission_event_type: 'succeed'
        )
      end

      it 'activates trigger for matching event' do
        expect {
          described_class.check_mission_triggers(
            activity_instance: activity_instance,
            event_type: 'succeed'
          )
        }.to change { TriggerActivation.count }.by(1)
      end

      it 'does not activate trigger for non-matching event' do
        expect {
          described_class.check_mission_triggers(
            activity_instance: activity_instance,
            event_type: 'fail'
          )
        }.not_to change { TriggerActivation.count }
      end
    end

    context 'with round-specific trigger' do
      let!(:trigger) do
        Trigger.create(
          trigger_type: 'mission',
          name: 'Round Complete Trigger',
          is_active: true,
          condition_type: 'contains',
          action_type: 'code_block',
          activity_id: activity.id,
          mission_event_type: 'round_complete',
          specific_round: 3
        )
      end

      it 'activates for matching round' do
        expect {
          described_class.check_mission_triggers(
            activity_instance: activity_instance,
            event_type: 'round_complete',
            round: 3
          )
        }.to change { TriggerActivation.count }.by(1)
      end
    end

    context 'with branch-specific trigger' do
      let!(:trigger) do
        Trigger.create(
          trigger_type: 'mission',
          name: 'Branch Trigger',
          is_active: true,
          condition_type: 'contains',
          action_type: 'code_block',
          activity_id: activity.id,
          mission_event_type: 'branch',
          specific_branch: 2
        )
      end

      it 'activates for matching branch' do
        expect {
          described_class.check_mission_triggers(
            activity_instance: activity_instance,
            event_type: 'branch',
            branch: 2
          )
        }.to change { TriggerActivation.count }.by(1)
      end
    end
  end

  describe '.check_world_memory_triggers' do
    let(:world_memory) do
      WorldMemory.create(
        summary: 'A dragon attacked the village!',
        publicity_level: 'public',
        importance: 7,
        started_at: Time.now - 3600,
        ended_at: Time.now
      )
    end

    before do
      # Associate memory with room via join table
      WorldMemoryLocation.create(world_memory_id: world_memory.id, room_id: room.id, is_primary: true)
      allow(world_memory).to receive(:characters).and_return([character])
    end

    context 'with matching world memory trigger' do
      let!(:trigger) do
        Trigger.create(
          trigger_type: 'world_memory',
          name: 'Dragon Attack Trigger',
          is_active: true,
          condition_type: 'contains',
          condition_value: 'dragon',
          action_type: 'code_block'
        )
      end

      it 'activates trigger for matching content' do
        expect {
          described_class.check_world_memory_triggers(world_memory: world_memory)
        }.to change { TriggerActivation.count }.by(1)
      end
    end

    context 'with publicity filter' do
      let!(:trigger) do
        Trigger.create(
          trigger_type: 'world_memory',
          name: 'Private Memory Trigger',
          is_active: true,
          condition_type: 'contains',
          condition_value: 'dragon',
          action_type: 'code_block',
          memory_publicity_filter: 'private'
        )
      end

      it 'does not activate for non-matching publicity' do
        expect {
          described_class.check_world_memory_triggers(world_memory: world_memory)
        }.not_to change { TriggerActivation.count }
      end
    end

    context 'with importance filter' do
      let!(:trigger) do
        Trigger.create(
          trigger_type: 'world_memory',
          name: 'High Importance Trigger',
          is_active: true,
          condition_type: 'contains',
          condition_value: 'dragon',
          action_type: 'code_block',
          min_importance: 9
        )
      end

      it 'does not activate for low importance memories' do
        expect {
          described_class.check_world_memory_triggers(world_memory: world_memory)
        }.not_to change { TriggerActivation.count }
      end
    end
  end

  describe '.check_clue_share_triggers' do
    let(:clue) { create(:clue, name: 'Secret Map', content: 'X marks the spot') }
    let(:recipient) { create(:character, forename: 'Bob') }

    context 'with matching clue share trigger' do
      let!(:trigger) do
        Trigger.create(
          trigger_type: 'clue_share',
          name: 'Clue Share Trigger',
          is_active: true,
          condition_type: 'contains',
          condition_value: 'Secret Map',
          action_type: 'code_block'
        )
      end

      it 'activates trigger for matching clue' do
        expect {
          described_class.check_clue_share_triggers(
            clue: clue,
            npc: npc_character,
            recipient: recipient,
            room: room
          )
        }.to change { TriggerActivation.count }.by(1)
      end
    end

    context 'with NPC filter' do
      let!(:trigger) do
        Trigger.create(
          trigger_type: 'clue_share',
          name: 'Specific NPC Trigger',
          is_active: true,
          condition_type: 'contains',
          condition_value: 'Secret',
          action_type: 'code_block',
          npc_character_id: npc_character.id
        )
      end

      it 'activates for matching NPC' do
        expect {
          described_class.check_clue_share_triggers(
            clue: clue,
            npc: npc_character,
            recipient: recipient,
            room: room
          )
        }.to change { TriggerActivation.count }.by(1)
      end

      it 'does not activate for different NPC' do
        other_npc = create(:character, :npc, forename: 'Other')

        expect {
          described_class.check_clue_share_triggers(
            clue: clue,
            npc: other_npc,
            recipient: recipient,
            room: room
          )
        }.not_to change { TriggerActivation.count }
      end
    end
  end

  describe 'trigger matching' do
    let!(:trigger) { Trigger.create(trigger_type: 'npc', name: 'Test', is_active: true, condition_type: 'contains', action_type: 'code_block', npc_character_id: npc_character.id) }

    context 'with exact condition' do
      before { trigger.update(condition_type: 'exact', condition_value: 'hello world') }

      it 'matches exact content' do
        expect {
          described_class.check_npc_triggers(
            npc_instance: npc_instance,
            emote_content: 'hello world'
          )
        }.to change { TriggerActivation.count }.by(1)
      end

      it 'matches case-insensitively' do
        expect {
          described_class.check_npc_triggers(
            npc_instance: npc_instance,
            emote_content: 'HELLO WORLD'
          )
        }.to change { TriggerActivation.count }.by(1)
      end

      it 'does not match partial content' do
        expect {
          described_class.check_npc_triggers(
            npc_instance: npc_instance,
            emote_content: 'hello world!'
          )
        }.not_to change { TriggerActivation.count }
      end
    end

    context 'with contains condition' do
      before { trigger.update(condition_type: 'contains', condition_value: 'attack') }

      it 'matches content containing the value' do
        expect {
          described_class.check_npc_triggers(
            npc_instance: npc_instance,
            emote_content: 'The guard prepares to attack!'
          )
        }.to change { TriggerActivation.count }.by(1)
      end

      it 'does not match content without the value' do
        expect {
          described_class.check_npc_triggers(
            npc_instance: npc_instance,
            emote_content: 'The guard stands watch'
          )
        }.not_to change { TriggerActivation.count }
      end
    end

    context 'with regex condition' do
      before { trigger.update(condition_type: 'regex', condition_value: 'attack.*sword') }

      it 'matches content matching the regex' do
        expect {
          described_class.check_npc_triggers(
            npc_instance: npc_instance,
            emote_content: 'The guard attacks with a sword!'
          )
        }.to change { TriggerActivation.count }.by(1)
      end

      it 'does not match non-matching content' do
        expect {
          described_class.check_npc_triggers(
            npc_instance: npc_instance,
            emote_content: 'The guard attacks with a spear!'
          )
        }.not_to change { TriggerActivation.count }
      end
    end

    context 'with invalid regex' do
      before { trigger.update(condition_type: 'regex', condition_value: '[invalid(regex') }

      it 'handles invalid regex gracefully' do
        expect {
          described_class.check_npc_triggers(
            npc_instance: npc_instance,
            emote_content: 'test content'
          )
        }.not_to raise_error
      end
    end

    context 'with empty condition value' do
      before { trigger.update(condition_value: nil) }

      it 'always matches when no condition value is set' do
        expect {
          described_class.check_npc_triggers(
            npc_instance: npc_instance,
            emote_content: 'any content'
          )
        }.to change { TriggerActivation.count }.by(1)
      end
    end

    context 'with llm_match condition' do
      before do
        trigger.update(condition_type: 'llm_match', condition_value: 'is this hostile?')
        allow(TriggerLLMMatcherService).to receive(:check_match).and_return({
          matched: true,
          confidence: 0.9,
          reasoning: 'Content appears hostile'
        })
      end

      it 'uses TriggerLLMMatcherService for matching' do
        described_class.check_npc_triggers(
          npc_instance: npc_instance,
          emote_content: 'The guard attacks!'
        )

        expect(TriggerLLMMatcherService).to have_received(:check_match)
      end
    end
  end

  describe 'trigger activation' do
    let!(:trigger) do
      Trigger.create(
        trigger_type: 'npc',
        name: 'Test Trigger',
        is_active: true,
        condition_type: 'contains',
        condition_value: 'test',
        action_type: 'code_block',
        npc_character_id: npc_character.id
      )
    end

    it 'creates TriggerActivation record' do
      described_class.check_npc_triggers(
        npc_instance: npc_instance,
        emote_content: 'test message'
      )

      activation = TriggerActivation.last
      expect(activation.trigger_id).to eq(trigger.id)
      expect(activation.source_type).to eq('npc')
      expect(activation.source_character_id).to eq(npc_character.id)
      expect(activation.triggering_content).to eq('test message')
    end

    context 'with code block' do
      before do
        # action_type 'code_block' makes should_execute_code? return true
        trigger.update(code_block: 'puts "Hello"', action_type: 'code_block')
      end

      it 'executes code block via TriggerCodeExecutor' do
        described_class.check_npc_triggers(
          npc_instance: npc_instance,
          emote_content: 'test message'
        )

        expect(TriggerCodeExecutor).to have_received(:execute)
      end
    end

    context 'with staff alerts' do
      before do
        # action_type 'both' makes should_alert_staff? return true (and should_execute_code?)
        trigger.update(action_type: 'both', send_discord: true)
      end

      it 'sends staff alerts' do
        described_class.check_npc_triggers(
          npc_instance: npc_instance,
          emote_content: 'test message'
        )

        expect(StaffAlertService).to have_received(:send_trigger_alert)
      end
    end
  end

  describe 'error handling' do
    it 'handles errors gracefully in check_npc_triggers' do
      allow(Trigger).to receive(:where).and_raise(StandardError.new('Database error'))

      expect {
        described_class.check_npc_triggers(
          npc_instance: npc_instance,
          emote_content: 'test'
        )
      }.not_to raise_error
    end

    it 'handles errors gracefully in check_mission_triggers' do
      allow(Trigger).to receive(:where).and_raise(StandardError.new('Database error'))

      activity_instance = double('ActivityInstance',
        activity_id: 1,
        id: 1,
        activity: double(name: 'Test'),
        initiator: character
      )

      expect {
        described_class.check_mission_triggers(
          activity_instance: activity_instance,
          event_type: 'succeed'
        )
      }.not_to raise_error
    end

    it 'handles errors gracefully in check_world_memory_triggers' do
      allow(Trigger).to receive(:where).and_raise(StandardError.new('Database error'))

      world_memory = double('WorldMemory', summary: 'test', raw_log: nil)

      expect {
        described_class.check_world_memory_triggers(world_memory: world_memory)
      }.not_to raise_error
    end

    it 'handles errors gracefully in check_clue_share_triggers' do
      allow(Trigger).to receive(:where).and_raise(StandardError.new('Database error'))

      clue = double('Clue', id: 1, name: 'Test', content: 'content')

      expect {
        described_class.check_clue_share_triggers(
          clue: clue,
          npc: npc_character,
          recipient: character,
          room: room
        )
      }.not_to raise_error
    end
  end
end
