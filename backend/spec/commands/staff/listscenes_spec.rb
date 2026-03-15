# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Staff::ListScenes, type: :command do
  let(:room) { create(:room) }
  let(:meeting_room) { create(:room, name: 'Reception Hall') }
  let(:rp_room) { create(:room, name: 'Private Office') }
  let(:reality) { create(:reality) }
  let(:staff_user) { create(:user, :admin) }
  let(:staff_character) { create(:character, user: staff_user, is_staff_character: true, forename: 'Staff') }
  let(:character_instance) do
    create(:character_instance,
           character: staff_character,
           current_room: room,
           reality: reality,
           online: true)
  end
  let(:npc_character) { create(:character, :npc, forename: 'Merchant') }
  let(:pc_character) { create(:character, forename: 'Alice') }

  subject(:command) { described_class.new(character_instance) }

  describe 'command registration' do
    it 'is registered in the command registry' do
      expect(Commands::Base::Registry.commands['listscenes']).to eq(described_class)
    end

    it 'has alias scenes' do
      cmd_class, = Commands::Base::Registry.find_command('scenes')
      expect(cmd_class).to eq(described_class)
    end
  end

  describe 'command metadata' do
    it 'has correct command name' do
      expect(described_class.command_name).to eq('listscenes')
    end

    it 'has category staff' do
      expect(described_class.category).to eq(:staff)
    end

    it 'has help text' do
      expect(described_class.help_text).to include('List')
    end

    it 'has usage' do
      expect(described_class.usage).to include('listscenes')
    end

    it 'has examples' do
      expect(described_class.examples).to include('listscenes')
    end
  end

  describe '#execute' do
    context 'when user is not staff' do
      let(:non_staff_character) { create(:character, is_staff_character: false, forename: 'Regular') }
      let(:non_staff_instance) do
        create(:character_instance,
               character: non_staff_character,
               current_room: room,
               reality: reality,
               online: true)
      end
      let(:non_staff_command) { described_class.new(non_staff_instance) }

      it 'returns error' do
        result = non_staff_command.execute('listscenes')

        expect(result[:success]).to be false
        expect(result[:error]).to include('staff members')
      end
    end

    context 'with no arguments (defaults to pending)' do
      let(:pending_scene) do
        double('ArrangedScene',
               id: 1,
               display_name: 'Meeting with Merchant',
               status: 'pending',
               npc_character: npc_character,
               pc_character: pc_character,
               meeting_room: meeting_room,
               rp_room: rp_room,
               pending?: true,
               active?: false,
               completed?: false,
               available?: true,
               available_from: nil,
               expires_at: nil,
               started_at: nil,
               ended_at: nil,
               world_memory: nil)
      end

      before do
        query = double('ArrangedSceneQuery')
        allow(ArrangedScene).to receive(:where).with(status: 'pending').and_return(query)
        allow(query).to receive(:order).and_return(query)
        allow(query).to receive(:all).and_return([pending_scene])
      end

      it 'shows pending scenes' do
        result = command.execute('listscenes')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Arranged Scenes (pending)')
        expect(result[:message]).to include('Meeting with Merchant')
        expect(result[:message]).to include('Merchant')
        expect(result[:message]).to include('Alice')
      end

      it 'shows room information' do
        result = command.execute('listscenes')

        expect(result[:message]).to include('Reception Hall')
        expect(result[:message]).to include('Private Office')
      end

      it 'shows ready to trigger for available scenes' do
        result = command.execute('listscenes')

        expect(result[:message]).to include('Ready to trigger')
      end

      it 'includes data in response' do
        result = command.execute('listscenes')

        expect(result[:data][:action]).to eq('list')
        expect(result[:data][:filter]).to eq('pending')
        expect(result[:data][:count]).to eq(1)
        expect(result[:data][:scenes]).to be_an(Array)
      end
    end

    context 'with "all" filter' do
      before do
        query = double('ArrangedSceneQuery')
        allow(ArrangedScene).to receive(:order).and_return(query)
        allow(query).to receive(:limit).with(50).and_return(query)
        allow(query).to receive(:all).and_return([])
      end

      it 'queries all scenes' do
        result = command.execute('listscenes all')

        expect(result[:success]).to be true
        expect(result[:message]).to include('No all scenes found')
      end
    end

    context 'with "active" filter' do
      let(:active_scene) do
        double('ArrangedScene',
               id: 2,
               display_name: 'Active Meeting',
               status: 'active',
               npc_character: npc_character,
               pc_character: pc_character,
               meeting_room: meeting_room,
               rp_room: rp_room,
               pending?: false,
               active?: true,
               completed?: false,
               started_at: Time.now - 600,
               ended_at: nil,
               world_memory: nil)
      end

      before do
        query = double('ArrangedSceneQuery')
        allow(ArrangedScene).to receive(:where).with(status: 'active').and_return(query)
        allow(query).to receive(:order).and_return(query)
        allow(query).to receive(:all).and_return([active_scene])
      end

      it 'shows active scenes with started time' do
        result = command.execute('listscenes active')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Active Meeting')
        expect(result[:message]).to include('Started:')
        expect(result[:data][:filter]).to eq('active')
      end
    end

    context 'with "completed" filter' do
      let(:world_memory) do
        double('WorldMemory',
               summary: 'A great conversation about the marketplace')
      end

      let(:completed_scene) do
        double('ArrangedScene',
               id: 3,
               display_name: 'Completed Meeting',
               status: 'completed',
               npc_character: npc_character,
               pc_character: pc_character,
               meeting_room: meeting_room,
               rp_room: rp_room,
               pending?: false,
               active?: false,
               completed?: true,
               started_at: Time.now - 3600,
               ended_at: Time.now - 1800,
               world_memory: world_memory)
      end

      before do
        query = double('ArrangedSceneQuery')
        allow(ArrangedScene).to receive(:where).with(status: 'completed').and_return(query)
        allow(query).to receive(:order).and_return(query)
        allow(query).to receive(:limit).with(20).and_return(query)
        allow(query).to receive(:all).and_return([completed_scene])
      end

      it 'shows completed scenes with summary' do
        result = command.execute('listscenes completed')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Completed Meeting')
        expect(result[:message]).to include('Summary:')
        expect(result[:message]).to include('conversation')
        expect(result[:data][:filter]).to eq('completed')
      end

      it 'truncates long summaries' do
        long_summary = 'A' * 150
        allow(world_memory).to receive(:summary).and_return(long_summary)

        result = command.execute('listscenes completed')

        expect(result[:message]).to include('...')
      end
    end

    context 'with "cancelled" filter' do
      before do
        query = double('ArrangedSceneQuery')
        allow(ArrangedScene).to receive(:where).with(status: 'cancelled').and_return(query)
        allow(query).to receive(:order).and_return(query)
        allow(query).to receive(:limit).with(20).and_return(query)
        allow(query).to receive(:all).and_return([])
      end

      it 'queries cancelled scenes' do
        result = command.execute('listscenes cancelled')

        expect(result[:success]).to be true
        expect(result[:data][:filter]).to eq('cancelled')
      end
    end

    context 'with pending scene timing states' do
      let(:future_scene) do
        double('ArrangedScene',
               id: 4,
               display_name: 'Future Meeting',
               status: 'pending',
               npc_character: npc_character,
               pc_character: pc_character,
               meeting_room: meeting_room,
               rp_room: rp_room,
               pending?: true,
               active?: false,
               completed?: false,
               available?: false,
               available_from: Time.now + 3600,
               expires_at: nil,
               started_at: nil,
               ended_at: nil,
               world_memory: nil)
      end

      before do
        query = double('ArrangedSceneQuery')
        allow(ArrangedScene).to receive(:where).with(status: 'pending').and_return(query)
        allow(query).to receive(:order).and_return(query)
        allow(query).to receive(:all).and_return([future_scene])
      end

      it 'shows available from time for future scenes' do
        result = command.execute('listscenes')

        expect(result[:message]).to include('Available from:')
      end
    end

    context 'with expired pending scene' do
      let(:expired_scene) do
        double('ArrangedScene',
               id: 5,
               display_name: 'Expired Meeting',
               status: 'pending',
               npc_character: npc_character,
               pc_character: pc_character,
               meeting_room: meeting_room,
               rp_room: rp_room,
               pending?: true,
               active?: false,
               completed?: false,
               available?: false,
               available_from: nil,
               expires_at: Time.now - 3600,
               started_at: nil,
               ended_at: nil,
               world_memory: nil)
      end

      before do
        query = double('ArrangedSceneQuery')
        allow(ArrangedScene).to receive(:where).with(status: 'pending').and_return(query)
        allow(query).to receive(:order).and_return(query)
        allow(query).to receive(:all).and_return([expired_scene])
      end

      it 'shows EXPIRED indicator' do
        result = command.execute('listscenes')

        expect(result[:message]).to include('EXPIRED')
      end
    end

    context 'with empty results' do
      before do
        query = double('ArrangedSceneQuery')
        allow(ArrangedScene).to receive(:where).and_return(query)
        allow(query).to receive(:order).and_return(query)
        allow(query).to receive(:all).and_return([])
      end

      it 'shows no scenes found message' do
        result = command.execute('listscenes')

        expect(result[:success]).to be true
        expect(result[:message]).to include('No pending scenes found')
        expect(result[:data][:count]).to eq(0)
      end
    end

    context 'shows helper commands' do
      before do
        query = double('ArrangedSceneQuery')
        allow(ArrangedScene).to receive(:where).and_return(query)
        allow(query).to receive(:order).and_return(query)
        allow(query).to receive(:all).and_return([
                                                   double('ArrangedScene',
                                                          id: 1,
                                                          display_name: 'Test',
                                                          status: 'pending',
                                                          npc_character: npc_character,
                                                          pc_character: pc_character,
                                                          meeting_room: meeting_room,
                                                          rp_room: rp_room,
                                                          pending?: true,
                                                          active?: false,
                                                          completed?: false,
                                                          available?: true,
                                                          available_from: nil,
                                                          expires_at: nil,
                                                          started_at: nil,
                                                          ended_at: nil,
                                                          world_memory: nil)
                                                 ])
      end

      it 'includes command hints' do
        result = command.execute('listscenes')

        expect(result[:message]).to include('Commands:')
        expect(result[:message]).to include('sceneinstructions')
        expect(result[:message]).to include('cancelscene')
      end
    end
  end
end
