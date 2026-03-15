# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Building::Build, type: :command do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area, city_built_at: nil) }
  let(:room) { create(:room, location: location, name: 'Town Square', room_type: 'plaza') }

  let(:user) { create(:user) }
  let(:character) { create(:character, user: user, forename: 'Builder') }
  let(:reality) { create(:reality) }
  let(:character_instance) do
    create(:character_instance,
           character: character,
           reality: reality,
           current_room: room,
           online: true)
  end

  subject { described_class.new(character_instance) }

  before do
    allow(BroadcastService).to receive(:to_character)
    allow(BroadcastService).to receive(:to_room)
    allow(character).to receive(:staff?).and_return(true)
    allow(character).to receive(:admin?).and_return(false)
    allow(character_instance).to receive(:creator_mode?).and_return(false)
  end

  # Use shared example for command metadata
  it_behaves_like "command metadata", 'build', :building

  describe 'command registration' do
    it 'is registered in the command registry' do
      expect(Commands::Base::Registry.commands['build']).to eq(described_class)
    end
  end

  describe 'BUILD_OPTIONS constant' do
    it 'has create options' do
      expect(described_class::BUILD_OPTIONS[:create]).to be_an(Array)
      expect(described_class::BUILD_OPTIONS[:create].length).to be >= 5
    end

    it 'has modify options' do
      expect(described_class::BUILD_OPTIONS[:modify]).to be_an(Array)
      expect(described_class::BUILD_OPTIONS[:modify].length).to be >= 5
    end

    it 'includes city, block, room, shop, apartment in create' do
      labels = described_class::BUILD_OPTIONS[:create].map { |o| o[:label] }
      expect(labels).to include('City', 'Block', 'Room', 'Shop', 'Apartment')
    end

    it 'includes edit, rename, resize, decorate, delete in modify' do
      labels = described_class::BUILD_OPTIONS[:modify].map { |o| o[:label] }
      expect(labels).to include('Edit', 'Rename', 'Resize', 'Decorate', 'Delete')
    end
  end

  describe '#execute' do
    context 'when character lacks permission' do
      before do
        allow(character).to receive(:staff?).and_return(false)
        allow(character).to receive(:admin?).and_return(false)
        allow(character_instance).to receive(:creator_mode?).and_return(false)
      end

      it 'returns an error' do
        result = subject.execute('build city')

        expect(result[:success]).to be false
        expect(result[:message]).to include('staff permissions')
      end
    end

    context 'when character is admin' do
      before do
        allow(character).to receive(:staff?).and_return(false)
        allow(character).to receive(:admin?).and_return(true)
      end

      it 'allows access' do
        result = subject.execute('build')
        # Should not return permission error
        expect(result[:error]).not_to include('staff permissions') if result[:error]
      end
    end

    context 'when in creator mode' do
      before do
        allow(character).to receive(:staff?).and_return(false)
        allow(character_instance).to receive(:creator_mode?).and_return(true)
      end

      it 'allows access' do
        result = subject.execute('build')
        # Should not return permission error
        expect(result[:error]).not_to include('staff permissions') if result[:error]
      end
    end

    context 'with no arguments' do
      it 'shows build menu' do
        result = subject.execute('build')
        # Should return a quickmenu interaction
        expect(result[:interaction_id]).not_to be_nil
      end
    end

    context 'with unknown subcommand' do
      it 'returns an error' do
        result = subject.execute('build unknown')

        expect(result[:success]).to be false
        expect(result[:error] || result[:message]).to include('Unknown build subcommand')
      end
    end
  end

  # ========================================
  # Subcommand Routing Tests
  # ========================================

  describe 'subcommand routing' do
    before do
      # Mock the registry to track which command gets called
      allow(Commands::Base::Registry).to receive(:execute_command).and_return({
        success: true,
        message: 'Command executed'
      })
    end

    describe 'create operations' do
      it 'routes city to build city' do
        subject.execute('build city')

        expect(Commands::Base::Registry).to have_received(:execute_command)
          .with(character_instance, 'build city')
      end

      it 'routes town alias to build city' do
        subject.execute('build town')

        expect(Commands::Base::Registry).to have_received(:execute_command)
          .with(character_instance, 'build city')
      end

      it 'routes block to build block' do
        subject.execute('build block')

        expect(Commands::Base::Registry).to have_received(:execute_command)
          .with(character_instance, 'build block')
      end

      it 'routes building alias to build block' do
        subject.execute('build building')

        expect(Commands::Base::Registry).to have_received(:execute_command)
          .with(character_instance, 'build block')
      end

      it 'routes room to build location' do
        subject.execute('build room')

        expect(Commands::Base::Registry).to have_received(:execute_command)
          .with(character_instance, 'build location')
      end

      it 'routes location alias to build location' do
        subject.execute('build location')

        expect(Commands::Base::Registry).to have_received(:execute_command)
          .with(character_instance, 'build location')
      end

      it 'routes shop to build shop' do
        subject.execute('build shop')

        expect(Commands::Base::Registry).to have_received(:execute_command)
          .with(character_instance, 'build shop')
      end

      it 'routes store alias to build shop' do
        subject.execute('build store')

        expect(Commands::Base::Registry).to have_received(:execute_command)
          .with(character_instance, 'build shop')
      end

      it 'routes apartment to build apartment' do
        subject.execute('build apartment')

        expect(Commands::Base::Registry).to have_received(:execute_command)
          .with(character_instance, 'build apartment')
      end

      it 'routes apt alias to build apartment' do
        subject.execute('build apt')

        expect(Commands::Base::Registry).to have_received(:execute_command)
          .with(character_instance, 'build apartment')
      end
    end

    describe 'modify operations' do
      it 'routes edit to edit room' do
        subject.execute('build edit')

        expect(Commands::Base::Registry).to have_received(:execute_command)
          .with(character_instance, 'edit room')
      end

      it 'routes settings alias to edit room' do
        subject.execute('build settings')

        expect(Commands::Base::Registry).to have_received(:execute_command)
          .with(character_instance, 'edit room')
      end

      it 'routes rename to rename' do
        subject.execute('build rename')

        expect(Commands::Base::Registry).to have_received(:execute_command)
          .with(character_instance, 'rename')
      end

      it 'routes name alias to rename' do
        subject.execute('build name')

        expect(Commands::Base::Registry).to have_received(:execute_command)
          .with(character_instance, 'rename')
      end

      it 'routes resize to resize room' do
        subject.execute('build resize')

        expect(Commands::Base::Registry).to have_received(:execute_command)
          .with(character_instance, 'resize room')
      end

      it 'routes size alias to resize room' do
        subject.execute('build size')

        expect(Commands::Base::Registry).to have_received(:execute_command)
          .with(character_instance, 'resize room')
      end

      it 'routes decorate to decorate' do
        subject.execute('build decorate')

        expect(Commands::Base::Registry).to have_received(:execute_command)
          .with(character_instance, 'decorate')
      end

      it 'routes decoration alias to decorate' do
        subject.execute('build decoration')

        expect(Commands::Base::Registry).to have_received(:execute_command)
          .with(character_instance, 'decorate')
      end

      it 'routes dec alias to decorate' do
        subject.execute('build dec')

        expect(Commands::Base::Registry).to have_received(:execute_command)
          .with(character_instance, 'decorate')
      end

      it 'routes redecorate to redecorate' do
        subject.execute('build redecorate')

        expect(Commands::Base::Registry).to have_received(:execute_command)
          .with(character_instance, 'redecorate')
      end

      it 'routes redec alias to redecorate' do
        subject.execute('build redec')

        expect(Commands::Base::Registry).to have_received(:execute_command)
          .with(character_instance, 'redecorate')
      end

      it 'routes delete to delete room' do
        subject.execute('build delete')

        expect(Commands::Base::Registry).to have_received(:execute_command)
          .with(character_instance, 'delete room')
      end

      it 'routes remove alias to delete room' do
        subject.execute('build remove')

        expect(Commands::Base::Registry).to have_received(:execute_command)
          .with(character_instance, 'delete room')
      end

      it 'routes destroy alias to delete room' do
        subject.execute('build destroy')

        expect(Commands::Base::Registry).to have_received(:execute_command)
          .with(character_instance, 'delete room')
      end
    end

    describe 'background/seasonal operations' do
      it 'routes background to set background' do
        subject.execute('build background')

        expect(Commands::Base::Registry).to have_received(:execute_command)
          .with(character_instance, 'set background')
      end

      it 'routes bg alias to set background' do
        subject.execute('build bg')

        expect(Commands::Base::Registry).to have_received(:execute_command)
          .with(character_instance, 'set background')
      end

      it 'routes seasonal to set seasonal' do
        subject.execute('build seasonal')

        expect(Commands::Base::Registry).to have_received(:execute_command)
          .with(character_instance, 'set seasonal')
      end
    end

    describe 'with arguments' do
      it 'passes arguments to routed command' do
        subject.execute('build room My New Room')

        expect(Commands::Base::Registry).to have_received(:execute_command)
          .with(character_instance, 'build location My New Room')
      end

      it 'passes multiple arguments' do
        subject.execute('build resize 10 20 8')

        expect(Commands::Base::Registry).to have_received(:execute_command)
          .with(character_instance, 'resize room 10 20 8')
      end

      it 'passes rename argument' do
        subject.execute('build rename Grand Hall')

        expect(Commands::Base::Registry).to have_received(:execute_command)
          .with(character_instance, 'rename Grand Hall')
      end
    end
  end

  # ========================================
  # Build Menu Tests
  # ========================================

  describe '#show_build_menu' do
    context 'at a location without city built' do
      before do
        allow(location).to receive(:city_built_at).and_return(nil)
      end

      it 'includes City option' do
        expect(subject).to receive(:create_quickmenu) do |_, _, options, **kwargs|
          labels = options.map { |o| o[:label] }
          expect(labels).to include('City')
        end

        subject.send(:show_build_menu)
      end
    end

    context 'at a location with city already built' do
      before do
        allow(location).to receive(:city_built_at).and_return(Time.now)
      end

      it 'does not include City option' do
        expect(subject).to receive(:create_quickmenu) do |_, _, options, **kwargs|
          labels = options.map { |o| o[:label] }
          expect(labels).not_to include('City')
        end

        subject.send(:show_build_menu)
      end
    end

    context 'at an intersection' do
      before do
        allow(room).to receive(:room_type).and_return('intersection')
      end

      it 'includes Block option' do
        expect(subject).to receive(:create_quickmenu) do |_, _, options, **kwargs|
          labels = options.map { |o| o[:label] }
          expect(labels).to include('Block')
        end

        subject.send(:show_build_menu)
      end
    end

    context 'at a non-intersection' do
      before do
        allow(room).to receive(:room_type).and_return('indoor')
      end

      it 'does not include Block option' do
        expect(subject).to receive(:create_quickmenu) do |_, _, options, **kwargs|
          labels = options.map { |o| o[:label] }
          expect(labels).not_to include('Block')
        end

        subject.send(:show_build_menu)
      end
    end

    context 'when character owns the room' do
      let(:outer_room) { double('Room', owned_by?: true) }

      before do
        allow(room).to receive(:outer_room).and_return(outer_room)
      end

      it 'includes modify options' do
        expect(subject).to receive(:create_quickmenu) do |_, _, options, **kwargs|
          labels = options.map { |o| o[:label] }
          expect(labels).to include('Edit', 'Rename', 'Resize', 'Decorate', 'Delete')
        end

        subject.send(:show_build_menu)
      end
    end

    context 'when character does not own the room' do
      let(:outer_room) { double('Room', owned_by?: false) }

      before do
        allow(room).to receive(:outer_room).and_return(outer_room)
      end

      it 'does not include modify options' do
        expect(subject).to receive(:create_quickmenu) do |_, _, options, **kwargs|
          labels = options.map { |o| o[:label] }
          expect(labels).not_to include('Edit')
          expect(labels).not_to include('Delete')
        end

        subject.send(:show_build_menu)
      end
    end

    context 'when outer_room is nil' do
      before do
        allow(room).to receive(:outer_room).and_return(nil)
      end

      it 'does not include modify options' do
        expect(subject).to receive(:create_quickmenu) do |_, _, options, **kwargs|
          labels = options.map { |o| o[:label] }
          expect(labels).not_to include('Edit')
        end

        subject.send(:show_build_menu)
      end
    end

    it 'always includes Cancel option' do
      expect(subject).to receive(:create_quickmenu) do |_, _, options, **kwargs|
        labels = options.map { |o| o[:label] }
        expect(labels).to include('Cancel')
      end

      subject.send(:show_build_menu)
    end

    it 'always includes Room, Shop, Apartment options' do
      expect(subject).to receive(:create_quickmenu) do |_, _, options, **kwargs|
        labels = options.map { |o| o[:label] }
        expect(labels).to include('Room', 'Shop', 'Apartment')
      end

      subject.send(:show_build_menu)
    end

    it 'passes correct context' do
      expect(subject).to receive(:create_quickmenu) do |_, _, _, **kwargs|
        context = kwargs[:context]
        expect(context[:command]).to eq('build')
        expect(context[:stage]).to eq('select_type')
        expect(context[:room_id]).to eq(room.id)
        expect(context[:location_id]).to eq(location.id)
      end

      subject.send(:show_build_menu)
    end
  end

  # ========================================
  # Execute Build Command Tests
  # ========================================

  describe '#execute_build_command' do
    context 'when routed command succeeds' do
      before do
        allow(Commands::Base::Registry).to receive(:execute_command).and_return({
          success: true,
          message: 'Room created',
          type: :message,
          data: { room_id: 123 }
        })
      end

      it 'returns success result' do
        result = subject.send(:execute_build_command, 'build location', 'Test Room')

        expect(result[:success]).to be true
        expect(result[:message]).to eq('Room created')
      end

      it 'passes through type' do
        result = subject.send(:execute_build_command, 'build location', 'Test Room')

        expect(result[:type]).to eq(:message)
      end

      it 'passes through data' do
        result = subject.send(:execute_build_command, 'build location', 'Test Room')

        expect(result[:data]).to eq({ room_id: 123 })
      end
    end

    context 'when routed command fails' do
      before do
        allow(Commands::Base::Registry).to receive(:execute_command).and_return({
          success: false,
          message: 'Permission denied'
        })
      end

      it 'returns failure result' do
        result = subject.send(:execute_build_command, 'build location', '')

        expect(result[:success]).to be false
        expect(result[:error]).to eq('Permission denied')
        expect(result[:type]).to eq(:error)
      end
    end

    context 'when routed command returns error key' do
      before do
        allow(Commands::Base::Registry).to receive(:execute_command).and_return({
          success: false,
          error: 'Invalid parameters'
        })
      end

      it 'uses error key for error message' do
        result = subject.send(:execute_build_command, 'build city', '')

        expect(result[:error]).to eq('Invalid parameters')
      end
    end

    context 'with interaction_id' do
      before do
        allow(Commands::Base::Registry).to receive(:execute_command).and_return({
          success: true,
          message: 'Form shown',
          interaction_id: 'form-123'
        })
      end

      it 'passes through interaction_id' do
        result = subject.send(:execute_build_command, 'edit room', '')

        expect(result[:interaction_id]).to eq('form-123')
      end
    end

    it 'handles empty args' do
      allow(Commands::Base::Registry).to receive(:execute_command).and_return({ success: true, message: 'OK' })

      subject.send(:execute_build_command, 'build city', '')

      expect(Commands::Base::Registry).to have_received(:execute_command)
        .with(character_instance, 'build city')
    end

    it 'handles non-empty args' do
      allow(Commands::Base::Registry).to receive(:execute_command).and_return({ success: true, message: 'OK' })

      subject.send(:execute_build_command, 'rename', 'New Name')

      expect(Commands::Base::Registry).to have_received(:execute_command)
        .with(character_instance, 'rename New Name')
    end
  end

  # ========================================
  # Edge Cases
  # ========================================

  describe 'edge cases' do
    before do
      allow(Commands::Base::Registry).to receive(:execute_command).and_return({
        success: true,
        message: 'OK'
      })
    end

    context 'with extra whitespace' do
      it 'handles leading/trailing whitespace' do
        subject.execute('build   city  ')

        expect(Commands::Base::Registry).to have_received(:execute_command)
          .with(character_instance, 'build city')
      end
    end

    context 'with mixed case' do
      it 'handles uppercase' do
        subject.execute('build CITY')

        expect(Commands::Base::Registry).to have_received(:execute_command)
          .with(character_instance, 'build city')
      end

      it 'handles mixed case' do
        subject.execute('build City')

        expect(Commands::Base::Registry).to have_received(:execute_command)
          .with(character_instance, 'build city')
      end
    end

    context 'when room is nil' do
      before do
        allow(character_instance).to receive(:current_room).and_return(nil)
      end

      it 'handles nil room gracefully' do
        expect(subject).to receive(:create_quickmenu) do |_, _, options, **kwargs|
          context = kwargs[:context]
          expect(context[:room_id]).to be_nil
          expect(context[:location_id]).to be_nil
        end

        subject.send(:show_build_menu)
      end
    end

    context 'when location is nil' do
      before do
        allow(room).to receive(:location).and_return(nil)
      end

      it 'handles nil location gracefully' do
        expect(subject).to receive(:create_quickmenu) do |_, _, options, **kwargs|
          context = kwargs[:context]
          expect(context[:location_id]).to be_nil
        end

        subject.send(:show_build_menu)
      end
    end
  end
end
