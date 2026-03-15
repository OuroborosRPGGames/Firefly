# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Communication::EndScene, type: :command do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:zone) { create(:zone, world: world) }
  let(:location) { create(:location, zone: zone) }
  let(:meeting_room) { create(:room, location: location, name: 'Meeting Room') }
  let(:rp_room) { create(:room, location: location, name: 'RP Room') }
  let(:reality) { create(:reality) }

  let(:user) { create(:user) }
  let(:pc_character) { create(:character, user: user, forename: 'Player') }
  let(:npc_character) { create(:character, :npc, forename: 'Guide') }
  let(:creator) { create(:character) }

  let(:character_instance) do
    create(:character_instance,
           character: pc_character,
           reality: reality,
           current_room: rp_room,
           online: true)
  end

  subject(:command) { described_class.new(character_instance) }

  before do
    allow(BroadcastService).to receive(:to_character)
    allow(BroadcastService).to receive(:to_room)
  end

  # Use shared example for command metadata
  it_behaves_like "command metadata", 'endscene', :roleplaying, ['end scene', 'leave scene', 'leavescene', 'exitscene']

  describe 'command registration' do
    it 'is registered in the command registry' do
      expect(Commands::Base::Registry.commands['endscene']).to eq(described_class)
    end
  end

  describe 'when not in an active scene' do
    it 'returns error message' do
      result = command.execute('endscene')

      expect(result[:success]).to be false
      expect(result[:message]).to include('not currently in an arranged scene')
    end

    it 'explains how to use the command' do
      result = command.execute('endscene')

      # Message may have HTML entities
      expect(result[:message]).to include('scene').or include('meet')
    end
  end

  describe 'when in an active scene' do
    let!(:active_scene) do
      create(:arranged_scene,
             npc_character: npc_character,
             pc_character: pc_character,
             meeting_room: meeting_room,
             rp_room: rp_room,
             created_by: creator,
             scene_name: 'Important Meeting',
             status: 'active')
    end

    before do
      allow(ArrangedSceneService).to receive(:end_scene).and_return({
        success: true,
        meeting_room: meeting_room
      })
    end

    it 'ends the scene via service' do
      command.execute('endscene')

      expect(ArrangedSceneService).to have_received(:end_scene)
        .with(active_scene, character_instance)
    end

    it 'returns success message' do
      result = command.execute('endscene')

      expect(result[:success]).to be true
      expect(result[:message]).to include('meeting has concluded')
    end

    it 'mentions return room' do
      result = command.execute('endscene')

      expect(result[:message]).to include(meeting_room.name)
    end

    it 'includes structured data' do
      result = command.execute('endscene')

      expect(result[:type]).to eq(:action)
      expect(result[:data]).not_to be_nil
      expect(result[:data][:action]).to eq('scene_ended')
      expect(result[:data][:scene_id]).to eq(active_scene.id)
      expect(result[:data][:return_room]).to eq(meeting_room.name)
    end
  end

  describe 'when scene end fails' do
    let!(:active_scene) do
      create(:arranged_scene,
             npc_character: npc_character,
             pc_character: pc_character,
             meeting_room: meeting_room,
             rp_room: rp_room,
             created_by: creator,
             status: 'active')
    end

    before do
      allow(ArrangedSceneService).to receive(:end_scene).and_return({
        success: false,
        message: 'Scene is locked by staff'
      })
    end

    it 'returns error from service' do
      result = command.execute('endscene')

      expect(result[:success]).to be false
      expect(result[:message]).to include('Scene is locked by staff')
    end
  end

  describe 'scene filtering' do
    context 'when scene status is pending' do
      let!(:pending_scene) do
        create(:arranged_scene,
               npc_character: npc_character,
               pc_character: pc_character,
               meeting_room: meeting_room,
               rp_room: rp_room,
               created_by: creator,
               status: 'pending')
      end

      it 'does not find the scene' do
        result = command.execute('endscene')

        expect(result[:success]).to be false
        expect(result[:message]).to include('not currently in an arranged scene')
      end
    end

    context 'when scene status is completed' do
      let!(:completed_scene) do
        create(:arranged_scene,
               npc_character: npc_character,
               pc_character: pc_character,
               meeting_room: meeting_room,
               rp_room: rp_room,
               created_by: creator,
               status: 'completed')
      end

      it 'does not find the scene' do
        result = command.execute('endscene')

        expect(result[:success]).to be false
        expect(result[:message]).to include('not currently in an arranged scene')
      end
    end

    context 'when scene belongs to different character' do
      let(:other_character) { create(:character) }
      let!(:other_scene) do
        create(:arranged_scene,
               npc_character: npc_character,
               pc_character: other_character,
               meeting_room: meeting_room,
               rp_room: rp_room,
               created_by: creator,
               status: 'active')
      end

      it 'does not find the scene' do
        result = command.execute('endscene')

        expect(result[:success]).to be false
        expect(result[:message]).to include('not currently in an arranged scene')
      end
    end
  end

  describe 'room description generation' do
    let!(:active_scene) do
      create(:arranged_scene,
             npc_character: npc_character,
             pc_character: pc_character,
             meeting_room: meeting_room,
             rp_room: rp_room,
             created_by: creator,
             status: 'active')
    end

    let!(:other_instance) do
      create(:character_instance,
             character: create(:character),
             reality: reality,
             current_room: meeting_room,
             online: true)
    end

    before do
      allow(ArrangedSceneService).to receive(:end_scene).and_return({
        success: true,
        meeting_room: meeting_room
      })
    end

    it 'includes meeting room name' do
      result = command.execute('endscene')

      expect(result[:message]).to include(meeting_room.name)
    end

    it 'includes meeting room description if present' do
      meeting_room.update(short_description: 'A grand lobby')

      result = command.execute('endscene')

      expect(result[:message]).to include('grand lobby')
    end
  end

  describe 'alias commands' do
    let!(:active_scene) do
      create(:arranged_scene,
             npc_character: npc_character,
             pc_character: pc_character,
             meeting_room: meeting_room,
             rp_room: rp_room,
             created_by: creator,
             status: 'active')
    end

    before do
      allow(ArrangedSceneService).to receive(:end_scene).and_return({
        success: true,
        meeting_room: meeting_room
      })
    end

    it 'works with "end scene"' do
      result = command.execute('end scene')

      expect(result[:success]).to be true
    end

    it 'works with "leave scene"' do
      result = command.execute('leave scene')

      expect(result[:success]).to be true
    end

    it 'works with "leavescene"' do
      result = command.execute('leavescene')

      expect(result[:success]).to be true
    end

    it 'works with "exitscene"' do
      result = command.execute('exitscene')

      expect(result[:success]).to be true
    end
  end
end
