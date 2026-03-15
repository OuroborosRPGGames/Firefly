# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Activity::Observe do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area) }
  let(:room) { create(:room, location: location, name: 'Activity Room') }
  let(:reality) { create(:reality) }

  let(:user) { create(:user) }
  let(:character) { create(:character, user: user, forename: 'Observer', surname: 'One') }
  let(:character_instance) do
    create(:character_instance,
           character: character,
           reality: reality,
           current_room: room,
           online: true,
           status: 'alive')
  end

  # Second character (activity participant)
  let(:user2) { create(:user, email: 'player2@test.com') }
  let(:character2) { create(:character, user: user2, forename: 'Player', surname: 'Two') }
  let(:character_instance2) do
    create(:character_instance,
           character: character2,
           reality: reality,
           current_room: room,
           online: true,
           status: 'alive')
  end

  # Activity setup
  let(:activity) { create(:activity) }
  let(:activity_instance) { create(:activity_instance, activity: activity, room: room) }
  let(:activity_participant) do
    # Factory expects Character, not CharacterInstance
    # (factory sets char_id from character.id)
    character_instance2 # Ensure character_instance2 is created first
    create(:activity_participant,
           instance: activity_instance,
           character: character2)
  end

  subject(:command) { described_class.new(character_instance) }

  def execute_command(args = nil)
    input = args.nil? ? 'observe' : "observe #{args}"
    command.execute(input)
  end

  describe 'command metadata' do
    it 'has correct command name' do
      expect(described_class.command_name).to eq('aobserve')
    end

    it 'has aliases' do
      alias_names = described_class.aliases.map { |a| a.is_a?(Hash) ? a[:name] : a }
      expect(alias_names).to include('obs')
    end

    it 'has events category' do
      expect(described_class.category).to eq(:events)
    end

    it 'requires character' do
      req_types = described_class.requirements.map { |r| r[:type] || r[:condition] }
      expect(req_types).to include(:character)
    end
  end

  describe 'subcommand: status' do
    context 'when not observing any activity' do
      it 'returns error message' do
        result = execute_command('status')

        expect(result[:success]).to be false
        expect(result[:error]).to include('not observing any activity')
      end
    end

    context 'when observing an activity' do
      let!(:observer) do
        create(:activity_remote_observer,
               activity_instance: activity_instance,
               character_instance: character_instance,
               role: 'support',
               active: true)
      end

      it 'shows activity name and role' do
        result = execute_command('status')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Support')
      end
    end
  end

  describe 'subcommand: leave / quit' do
    context 'when observing an activity' do
      let!(:observer) do
        create(:activity_remote_observer,
               activity_instance: activity_instance,
               character_instance: character_instance,
               role: 'support',
               active: true)
      end

      it 'sets observer to inactive' do
        result = execute_command('leave')

        expect(result[:success]).to be true
        expect(observer.reload.active).to be false
      end

      it 'confirms the player stopped observing' do
        result = execute_command('leave')

        expect(result[:message]).to include('stopped observing')
      end

      it 'works with quit alias' do
        result = execute_command('quit')

        expect(result[:success]).to be true
        expect(observer.reload.active).to be false
      end
    end

    context 'when not observing' do
      it 'returns error' do
        result = execute_command('leave')

        expect(result[:success]).to be false
        expect(result[:message]).to include('not observing')
      end
    end
  end

  describe 'subcommand: actions / list' do
    context 'when not observing' do
      it 'returns error' do
        result = execute_command('actions')

        expect(result[:success]).to be false
        expect(result[:message]).to include('not observing')
      end
    end

    context 'when observing as supporter' do
      let!(:observer) do
        create(:activity_remote_observer,
               activity_instance: activity_instance,
               character_instance: character_instance,
               role: 'support',
               active: true)
      end

      it 'lists available support actions' do
        result = execute_command('actions')

        expect(result[:success]).to be true
        # Standard support actions include stat_swap and reroll_ones only
        expect(result[:message]).to include('stat_swap')
        expect(result[:message]).to include('reroll_ones')
        expect(result[:message]).not_to include('block_damage')
      end
    end

    context 'when observing as opposer' do
      let!(:observer) do
        create(:activity_remote_observer,
               activity_instance: activity_instance,
               character_instance: character_instance,
               role: 'oppose',
               active: true)
      end

      it 'lists available oppose actions' do
        result = execute_command('actions')

        expect(result[:success]).to be true
        # Standard oppose actions include block_explosions, damage_on_ones, block_willpower
        expect(result[:message]).to include('block_explosions').or include('damage_on_ones').or include('block_willpower')
      end
    end

    it 'works with list alias' do
      observer = create(:activity_remote_observer,
                        activity_instance: activity_instance,
                        character_instance: character_instance,
                        role: 'support',
                        active: true)

      result = execute_command('list')

      expect(result[:success]).to be true
    end
  end

  describe 'subcommand: action' do
    context 'when not observing' do
      it 'returns error' do
        result = execute_command('action stat_swap Player Two')

        expect(result[:success]).to be false
        expect(result[:message]).to include('not observing')
      end
    end

    context 'when observing' do
      let!(:observer) do
        create(:activity_remote_observer,
               activity_instance: activity_instance,
               character_instance: character_instance,
               role: 'support',
               active: true)
      end

      before do
        # Ensure the participant exists
        activity_participant
      end

      it 'submits the action' do
        result = execute_command('action stat_swap Player')

        expect(result[:success]).to be true
        expect(observer.reload.action_type).to eq('stat_swap')
      end

      it 'returns error for invalid action type' do
        result = execute_command('action invalid_action Player')

        expect(result[:success]).to be false
        expect(result[:message]).to include('Invalid action')
      end
    end
  end

  describe 'subcommand: support request' do
    context 'when target is not in an activity' do
      it 'returns error about no activity' do
        # character_instance2 is in the same room but not in an activity
        character_instance2

        result = execute_command('support Player')

        expect(result[:success]).to be false
        expect(result[:message]).to include('not currently participating')
      end
    end

    context 'when target not found' do
      it 'returns error about not finding player' do
        result = execute_command('support NonexistentPlayer')

        expect(result[:success]).to be false
        expect(result[:message]).to include('Could not find')
      end
    end

    context 'when target has left the activity' do
      it 'treats them as not currently participating' do
        create(:activity_participant, :inactive, instance: activity_instance, character: character2)
        character_instance2

        result = execute_command('support Player')

        expect(result[:success]).to be false
        expect(result[:message]).to include('not currently participating')
      end
    end
  end

  describe 'subcommand: oppose request' do
    context 'when target is not in an activity' do
      it 'returns error about no activity' do
        character_instance2

        result = execute_command('oppose Player')

        expect(result[:success]).to be false
        expect(result[:message]).to include('not currently participating')
      end
    end
  end

  describe 'subcommand: accept request' do
    let!(:my_participation) do
      create(:activity_participant,
             instance: activity_instance,
             character: character)
    end

    it 'returns a friendly error when requester is already observing something else' do
      create(:activity_remote_observer,
             activity_instance: activity_instance,
             character_instance: character_instance2,
             role: 'support',
             active: true)

      support_key = "observe_request:#{character_instance2.id}:#{character_instance.id}:support"
      request_data = {
        requester_id: character_instance2.id,
        requester_name: character_instance2.character.full_name,
        target_id: character_instance.id,
        activity_instance_id: activity_instance.id,
        role: 'support',
        requested_at: Time.now.iso8601
      }

      allow(command).to receive(:redis_fetch) do |key|
        key == support_key ? request_data : nil
      end
      allow(command).to receive(:redis_delete)

      result = execute_command('accept Player')

      expect(result[:success]).to be false
      expect(result[:message]).to include('already observing another activity')
    end

    it 'requires an active participation for the acceptor' do
      my_participation.update(continue: false)

      support_key = "observe_request:#{character_instance2.id}:#{character_instance.id}:support"
      request_data = {
        requester_id: character_instance2.id,
        requester_name: character_instance2.character.full_name,
        target_id: character_instance.id,
        activity_instance_id: activity_instance.id,
        role: 'support',
        requested_at: Time.now.iso8601
      }

      allow(command).to receive(:redis_fetch) do |key|
        key == support_key ? request_data : nil
      end
      allow(command).to receive(:redis_delete)

      result = execute_command('accept Player')

      expect(result[:success]).to be false
      expect(result[:message]).to include('not currently participating')
    end
  end

  describe 'show_usage' do
    it 'shows usage when no subcommand given' do
      result = execute_command(nil)

      expect(result[:success]).to be true
      expect(result[:message]).to include('status')
      expect(result[:message]).to include('leave')
      expect(result[:message]).to include('actions')
    end
  end
end
