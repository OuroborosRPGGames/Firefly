# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Generators::MissionBuilderService do
  describe 'constants' do
    it 'defines BUILDER_MODEL' do
      expect(described_class::BUILDER_MODEL).to include(:provider, :model)
    end
  end

  describe 'BuildContext' do
    let(:mission_plan) { { 'title' => 'Test Mission' } }
    let(:generation_job) { double('GenerationJob', log_progress!: nil) }
    let(:context) do
      described_class::BuildContext.new(
        mission_plan: mission_plan,
        setting: :fantasy,
        difficulty: :normal,
        location_mode: :mission_specific,
        options: { generate_images: true, base_location: double('Location', id: 1) },
        generation_job: generation_job
      )
    end

    describe '#initialize' do
      it 'stores mission_plan' do
        expect(context.mission_plan).to eq(mission_plan)
      end

      it 'stores setting' do
        expect(context.setting).to eq(:fantasy)
      end

      it 'stores difficulty' do
        expect(context.difficulty).to eq(:normal)
      end

      it 'initializes empty rooms' do
        expect(context.rooms).to eq({})
      end

      it 'initializes empty archetypes' do
        expect(context.archetypes).to eq({})
      end

      it 'initializes empty round_map' do
        expect(context.round_map).to eq({})
      end

      it 'initializes empty errors' do
        expect(context.errors).to eq([])
      end
    end

    describe '#log' do
      it 'delegates to generation_job' do
        expect(generation_job).to receive(:log_progress!).with('Test message')
        context.log('Test message')
      end

      it 'handles nil generation_job' do
        ctx = described_class::BuildContext.new(
          mission_plan: mission_plan,
          setting: :fantasy,
          difficulty: :normal,
          location_mode: :existing,
          options: {},
          generation_job: nil
        )
        expect { ctx.log('Test') }.not_to raise_error
      end
    end

    describe '#add_error' do
      it 'adds error to errors array' do
        context.add_error('Something went wrong')
        expect(context.errors).to include('Something went wrong')
      end
    end

    describe '#base_location' do
      it 'returns base_location from options' do
        expect(context.base_location).not_to be_nil
      end
    end

    describe '#generate_images?' do
      it 'returns true when generate_images option is true' do
        expect(context.generate_images?).to be true
      end

      it 'returns false when generate_images option is false' do
        ctx = described_class::BuildContext.new(
          mission_plan: mission_plan,
          setting: :fantasy,
          difficulty: :normal,
          location_mode: :existing,
          options: { generate_images: false },
          generation_job: nil
        )
        expect(ctx.generate_images?).to be false
      end
    end
  end

  describe '.build' do
    let(:mission_plan) do
      {
        'title' => 'The Lost Artifact',
        'summary' => 'A quest to find a mysterious artifact',
        'atype' => 'mission',
        'locations' => [],
        'adversaries' => [],
        'rounds' => [
          {
            'round_number' => 1,
            'branch' => 0,
            'rtype' => 'standard',
            'emit' => 'You enter the dungeon...'
          }
        ]
      }
    end
    let(:generation_job) { double('GenerationJob', id: 1, log_progress!: nil) }
    let(:mock_activity) { double('Activity', id: 1) }

    before do
      allow(Activity).to receive(:create).and_return(mock_activity)
      allow(ActivityRound).to receive(:create).and_return(double('ActivityRound', id: 1, update: true))
    end

    it 'returns success result with activity' do
      result = described_class.build(
        mission_plan: mission_plan,
        location_mode: :existing,
        setting: :fantasy,
        difficulty: :normal,
        generation_job: generation_job
      )

      expect(result[:success]).to be true
      expect(result[:activity]).to eq(mock_activity)
    end

    it 'logs progress' do
      expect(generation_job).to receive(:log_progress!).at_least(:once)

      described_class.build(
        mission_plan: mission_plan,
        location_mode: :existing,
        setting: :fantasy,
        generation_job: generation_job
      )
    end

    context 'when activity creation fails' do
      before do
        allow(Activity).to receive(:create).and_return(nil)
      end

      it 'returns failure result' do
        result = described_class.build(
          mission_plan: mission_plan,
          location_mode: :existing,
          setting: :fantasy
        )

        expect(result[:success]).to be false
        expect(result[:errors]).to include('Failed to create activity')
      end
    end

    context 'with mission_specific location mode' do
      let(:plan_with_locations) do
        mission_plan.merge(
          'locations' => [
            {
              'key' => 'entrance',
              'name' => 'Dungeon Entrance',
              'description' => 'A dark cave entrance',
              'room_type' => 'outdoor'
            }
          ]
        )
      end
      let(:mock_room) { double('Room', id: 1) }

      before do
        allow(SeedTermService).to receive(:for_generation).and_return(['ancient', 'mysterious'])
        allow(GamePrompts).to receive(:get).and_return('Generate room...')
        allow(LLM::Client).to receive(:generate).and_return({ success: true, text: 'A dark cave...' })
        allow(Room).to receive(:create).and_return(mock_room)
      end

      it 'creates rooms from locations' do
        expect(Room).to receive(:create).with(hash_including(name: 'Dungeon Entrance'))

        described_class.build(
          mission_plan: plan_with_locations,
          location_mode: :mission_specific,
          setting: :fantasy
        )
      end
    end

    context 'with adversaries' do
      let(:plan_with_adversaries) do
        mission_plan.merge(
          'adversaries' => [
            { 'key' => 'goblin', 'name' => 'Goblin Warrior' }
          ]
        )
      end

      before do
        allow(Generators::AdversaryGeneratorService).to receive(:generate).and_return({
          archetypes: { 'goblin' => double('NpcArchetype', id: 1) },
          errors: []
        })
      end

      it 'calls AdversaryGeneratorService' do
        expect(Generators::AdversaryGeneratorService).to receive(:generate).with(
          hash_including(
            adversaries: plan_with_adversaries['adversaries'],
            setting: :fantasy
          )
        )

        described_class.build(
          mission_plan: plan_with_adversaries,
          location_mode: :existing,
          setting: :fantasy
        )
      end
    end

    context 'with multiple round types' do
      let(:combat_round) do
        {
          'round_number' => 1,
          'branch' => 0,
          'rtype' => 'combat',
          'emit' => 'Combat begins!',
          'combat_encounter_key' => 'goblin'
        }
      end
      let(:branch_round) do
        {
          'round_number' => 2,
          'branch' => 0,
          'rtype' => 'branch',
          'emit' => 'Choose your path',
          'branch_choices' => [
            { 'text' => 'Go left', 'leads_to_branch' => 1 },
            { 'text' => 'Go right', 'leads_to_branch' => 2 }
          ]
        }
      end
      let(:persuade_round) do
        {
          'round_number' => 3,
          'branch' => 0,
          'rtype' => 'persuade',
          'emit' => 'Persuade the guard',
          'persuade_npc_name' => 'Guard Captain',
          'persuade_goal' => 'Get past the gate'
        }
      end

      it 'creates combat rounds' do
        plan = mission_plan.merge('rounds' => [combat_round])
        archetype = double('NpcArchetype', id: 1)

        mock_round = double('ActivityRound', id: 1)
        allow(mock_round).to receive(:update)
        allow(ActivityRound).to receive(:create).and_return(mock_round)

        result = described_class.build(
          mission_plan: plan,
          location_mode: :existing,
          setting: :fantasy
        )

        expect(result[:rounds_created]).to eq(1)
      end

      it 'creates branch rounds' do
        plan = mission_plan.merge('rounds' => [branch_round])

        mock_round = double('ActivityRound', id: 1)
        allow(mock_round).to receive(:update)
        allow(ActivityRound).to receive(:create).and_return(mock_round)

        result = described_class.build(
          mission_plan: plan,
          location_mode: :existing,
          setting: :fantasy
        )

        expect(result[:rounds_created]).to eq(1)
      end

      it 'creates persuade rounds' do
        plan = mission_plan.merge('rounds' => [persuade_round])

        mock_round = double('ActivityRound', id: 1)
        allow(mock_round).to receive(:update)
        allow(ActivityRound).to receive(:create).and_return(mock_round)

        result = described_class.build(
          mission_plan: plan,
          location_mode: :existing,
          setting: :fantasy
        )

        expect(result[:rounds_created]).to eq(1)
      end

      it 'passes persuade_npc_personality to round' do
        round_with_personality = persuade_round.merge(
          'persuade_npc_personality' => 'Voss wants a promotion and fears incompetence. Flattery works; threats backfire.'
        )
        plan = mission_plan.merge('rounds' => [round_with_personality])

        mock_round = double('ActivityRound', id: 1)
        allow(mock_round).to receive(:update)
        allow(ActivityRound).to receive(:create).and_return(mock_round)

        described_class.build(
          mission_plan: plan,
          location_mode: :existing,
          setting: :fantasy
        )

        expect(mock_round).to have_received(:update).with(hash_including(
          persuade_npc_personality: 'Voss wants a promotion and fears incompetence. Flattery works; threats backfire.'
        ))
      end
    end

    context 'with image generation enabled' do
      let(:plan_with_rooms) do
        mission_plan.merge(
          'locations' => [
            { 'key' => 'room1', 'name' => 'Test Room', 'room_type' => 'indoor' }
          ]
        )
      end
      let(:mock_room) { double('Room', id: 1) }

      before do
        allow(SeedTermService).to receive(:for_generation).and_return([])
        allow(GamePrompts).to receive(:get).and_return('Generate...')
        allow(LLM::Client).to receive(:generate).and_return({ success: true, text: 'Room desc' })
        allow(Room).to receive(:create).and_return(mock_room)
        allow(GenerationJob).to receive(:create)
      end

      it 'queues image generation jobs' do
        expect(GenerationJob).to receive(:create).at_least(:once)

        described_class.build(
          mission_plan: plan_with_rooms,
          location_mode: :mission_specific,
          setting: :fantasy,
          options: { generate_images: true },
          generation_job: generation_job
        )
      end
    end

    context 'when exception occurs' do
      before do
        allow(Activity).to receive(:create).and_raise(StandardError.new('Database error'))
      end

      it 'returns failure with error message' do
        result = described_class.build(
          mission_plan: mission_plan,
          location_mode: :existing,
          setting: :fantasy
        )

        expect(result[:success]).to be false
        expect(result[:errors]).to include('Failed to create activity')
      end
    end
  end

  describe 'branch linking' do
    let(:mock_activity) { double('Activity', id: 1) }
    let(:branch_plan) do
      {
        'title' => 'Branching Mission',
        'summary' => 'A mission with choices',
        'rounds' => [
          { 'round_number' => 1, 'branch' => 0, 'rtype' => 'branch',
            'branch_choices' => [
              { 'text' => 'Path A', 'leads_to_branch' => 1 },
              { 'text' => 'Path B', 'leads_to_branch' => 2 }
            ] },
          { 'round_number' => 1, 'branch' => 1, 'rtype' => 'standard', 'emit' => 'Path A content' },
          { 'round_number' => 1, 'branch' => 2, 'rtype' => 'standard', 'emit' => 'Path B content' }
        ]
      }
    end
    let(:mock_rounds) do
      {
        '0-1' => double('ActivityRound', id: 1, update: true),
        '1-1' => double('ActivityRound', id: 2, update: true),
        '2-1' => double('ActivityRound', id: 3, update: true)
      }
    end

    before do
      allow(Activity).to receive(:create).and_return(mock_activity)
      # Return different rounds for each creation
      round_index = 0
      allow(ActivityRound).to receive(:create) do
        rounds = mock_rounds.values
        result = rounds[round_index % rounds.size]
        round_index += 1
        result
      end
    end

    it 'links branches to target rounds' do
      # The branch round should be updated with branch_to
      expect(mock_rounds['0-1']).to receive(:update).at_least(:once)

      described_class.build(
        mission_plan: branch_plan,
        location_mode: :existing,
        setting: :fantasy
      )
    end
  end

  describe 'round type configurations' do
    let(:mock_activity) { double('Activity', id: 1) }
    let(:mock_round) { double('ActivityRound', id: 1) }

    before do
      allow(Activity).to receive(:create).and_return(mock_activity)
      allow(ActivityRound).to receive(:create).and_return(mock_round)
      allow(mock_round).to receive(:update)
    end

    context 'reflex round' do
      let(:reflex_plan) do
        {
          'title' => 'Test',
          'rounds' => [{ 'round_number' => 1, 'rtype' => 'reflex', 'timeout_seconds' => 90 }]
        }
      end

      it 'configures timeout' do
        expect(mock_round).to receive(:update).with(hash_including(timeout_seconds: 90))

        described_class.build(
          mission_plan: reflex_plan,
          location_mode: :existing,
          setting: :fantasy
        )
      end
    end

    context 'free_roll round' do
      let(:free_roll_plan) do
        {
          'title' => 'Test',
          'rounds' => [{ 'round_number' => 1, 'rtype' => 'free_roll', 'free_roll_context' => 'Investigate the room' }]
        }
      end

      it 'configures free_roll_context' do
        expect(mock_round).to receive(:update).with(hash_including(free_roll_context: 'Investigate the room'))

        described_class.build(
          mission_plan: free_roll_plan,
          location_mode: :existing,
          setting: :fantasy
        )
      end
    end

    context 'standard round with actions' do
      let(:standard_plan) do
        {
          'title' => 'Test',
          'rounds' => [{
            'round_number' => 1,
            'rtype' => 'standard',
            'actions' => [
              { 'choice_text' => 'Look around', 'output_string' => 'You see a room' }
            ]
          }]
        }
      end

      before do
        allow(ActivityAction).to receive(:create).and_return(double('ActivityAction', id: 10))
      end

      it 'creates activity actions' do
        expect(ActivityAction).to receive(:create).with(
          hash_including(choice_string: 'Look around')
        )

        described_class.build(
          mission_plan: standard_plan,
          location_mode: :existing,
          setting: :fantasy
        )
      end
    end

    context 'standard round with stat_ids on actions' do
      let(:stat_plan) do
        {
          'title' => 'Test Stats',
          'rounds' => [{
            'round_number' => 1,
            'rtype' => 'standard',
            'actions' => [
              { 'choice_text' => 'Climb wall', 'output_string' => 'You scale the wall', 'stat_ids' => [5, 12] }
            ]
          }]
        }
      end

      before do
        allow(ActivityAction).to receive(:create).and_return(double('ActivityAction', id: 10))
      end

      it 'passes skill_list with stat IDs to ActivityAction.create' do
        expect(ActivityAction).to receive(:create).with(
          hash_including(
            choice_string: 'Climb wall',
            skill_list: Sequel.pg_array([5, 12])
          )
        )

        described_class.build(
          mission_plan: stat_plan,
          location_mode: :existing,
          setting: :fantasy
        )
      end
    end

    context 'reflex round with reflex_stat_id' do
      let(:reflex_stat_plan) do
        {
          'title' => 'Test',
          'rounds' => [{ 'round_number' => 1, 'rtype' => 'reflex', 'timeout_seconds' => 60, 'reflex_stat_id' => 7 }]
        }
      end

      it 'configures reflex_stat_id' do
        expect(mock_round).to receive(:update).with(hash_including(timeout_seconds: 60, reflex_stat_id: 7))

        described_class.build(
          mission_plan: reflex_stat_plan,
          location_mode: :existing,
          setting: :fantasy
        )
      end
    end

    context 'persuade round with persuade_stat_ids' do
      let(:persuade_stat_plan) do
        {
          'title' => 'Test',
          'rounds' => [{
            'round_number' => 1,
            'rtype' => 'persuade',
            'emit' => 'Talk to the guard',
            'persuade_npc_name' => 'Guard',
            'persuade_goal' => 'Pass through',
            'persuade_stat_ids' => [3, 8]
          }]
        }
      end

      it 'configures stat_set_a from persuade_stat_ids' do
        expect(mock_round).to receive(:update).with(hash_including(
          persuade_npc_name: 'Guard',
          stat_set_a: Sequel.pg_array([3, 8])
        ))

        described_class.build(
          mission_plan: persuade_stat_plan,
          location_mode: :existing,
          setting: :fantasy
        )
      end
    end

    context 'group_check round with stat_set_a' do
      let(:group_check_plan) do
        {
          'title' => 'Test',
          'rounds' => [{
            'round_number' => 1,
            'rtype' => 'group_check',
            'emit' => 'Everyone must endure!',
            'stat_set_a' => [2, 4]
          }]
        }
      end

      it 'configures stat_set_a' do
        expect(mock_round).to receive(:update).with(hash_including(
          stat_set_a: Sequel.pg_array([2, 4])
        ))

        described_class.build(
          mission_plan: group_check_plan,
          location_mode: :existing,
          setting: :fantasy
        )
      end
    end
  end

  describe 'activity creation with universe and stat_block' do
    let(:mock_activity) { double('Activity', id: 1) }
    let(:mock_round) { double('ActivityRound', id: 1) }
    let(:generation_job) { double('GenerationJob', id: 1, log_progress!: nil) }

    before do
      allow(ActivityRound).to receive(:create).and_return(mock_round)
      allow(mock_round).to receive(:update)
    end

    it 'passes universe_id and stat_block_id to Activity.create' do
      expect(Activity).to receive(:create).with(hash_including(
        universe_id: 42,
        stat_block_id: 7
      )).and_return(mock_activity)

      described_class.build(
        mission_plan: { 'title' => 'Test', 'summary' => 'Test', 'rounds' => [{ 'round_number' => 1, 'rtype' => 'standard', 'emit' => 'Go' }] },
        location_mode: :existing,
        setting: :fantasy,
        options: { universe_id: 42, stat_block_id: 7, activity_type: 'adventure' },
        generation_job: generation_job
      )
    end

    it 'uses activity_type from options over plan atype' do
      expect(Activity).to receive(:create).with(hash_including(
        activity_type: 'adventure'
      )).and_return(mock_activity)

      described_class.build(
        mission_plan: { 'title' => 'Test', 'summary' => 'Test', 'atype' => 'mission', 'rounds' => [{ 'round_number' => 1, 'rtype' => 'standard', 'emit' => 'Go' }] },
        location_mode: :existing,
        setting: :fantasy,
        options: { activity_type: 'adventure' },
        generation_job: generation_job
      )
    end
  end
end
