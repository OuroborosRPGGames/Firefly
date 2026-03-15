# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Communication::Scene, type: :command do
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
           current_room: meeting_room,
           online: true)
  end

  subject(:command) { described_class.new(character_instance) }

  before do
    allow(BroadcastService).to receive(:to_character)
    allow(BroadcastService).to receive(:to_room)
  end

  # Use shared example for command metadata
  it_behaves_like "command metadata", 'scene', :roleplaying, ['meet', 'startscene', 'begin scene']

  describe 'command registration' do
    it 'is registered in the command registry' do
      expect(Commands::Base::Registry.commands['scene']).to eq(described_class)
    end
  end

  describe 'when no scenes available' do
    it 'returns error message' do
      result = command.execute('scene')

      expect(result[:success]).to be false
      expect(result[:message]).to include('no arranged scenes')
    end

    it 'suggests going to meeting location' do
      result = command.execute('scene')

      expect(result[:message]).to include('meeting location')
    end
  end

  describe 'when scene available' do
    let!(:available_scene) do
      create(:arranged_scene,
             npc_character: npc_character,
             pc_character: pc_character,
             meeting_room: meeting_room,
             rp_room: rp_room,
             created_by: creator,
             status: 'pending')
    end

    before do
      allow(ArrangedSceneService).to receive(:trigger_scene).and_return({
        success: true,
        rp_room: rp_room
      })
    end

    it 'triggers the scene via service' do
      command.execute('scene')

      expect(ArrangedSceneService).to have_received(:trigger_scene)
        .with(available_scene, character_instance)
    end

    it 'returns success with meeting info' do
      result = command.execute('scene')

      expect(result[:success]).to be true
      expect(result[:message]).to include('arranged meeting')
      expect(result[:message]).to include(npc_character.full_name)
    end

    it 'includes structured data' do
      result = command.execute('scene')

      expect(result[:type]).to eq(:action)
      expect(result[:data]).not_to be_nil
      expect(result[:data][:action]).to eq('scene_started')
      expect(result[:data][:scene_id]).to eq(available_scene.id)
    end
  end

  describe 'when scene trigger fails' do
    let!(:available_scene) do
      create(:arranged_scene,
             npc_character: npc_character,
             pc_character: pc_character,
             meeting_room: meeting_room,
             rp_room: rp_room,
             created_by: creator,
             status: 'pending')
    end

    before do
      allow(ArrangedSceneService).to receive(:trigger_scene).and_return({
        success: false,
        message: 'NPC is not available'
      })
    end

    it 'returns error from service' do
      result = command.execute('scene')

      expect(result[:success]).to be false
      expect(result[:message]).to include('NPC is not available')
    end
  end

  describe 'when multiple scenes available' do
    let!(:scene1) do
      create(:arranged_scene,
             npc_character: npc_character,
             pc_character: pc_character,
             meeting_room: meeting_room,
             rp_room: rp_room,
             created_by: creator,
             scene_name: 'First Meeting',
             status: 'pending')
    end

    let(:npc_character2) { create(:character, :npc, forename: 'Sage') }
    let!(:scene2) do
      create(:arranged_scene,
             npc_character: npc_character2,
             pc_character: pc_character,
             meeting_room: meeting_room,
             rp_room: rp_room,
             created_by: creator,
             scene_name: 'Second Meeting',
             status: 'pending')
    end

    it 'returns a quickmenu for selection' do
      result = command.execute('scene')

      expect(result[:success]).to be true
      expect(result[:type]).to eq(:quickmenu)
    end

    it 'includes both scenes in options' do
      result = command.execute('scene')

      options = result[:data][:options]
      expect(options.length).to eq(2)
      expect(options.map { |o| o[:label] }).to include('First Meeting', 'Second Meeting')
    end

    it 'includes NPC names in descriptions' do
      result = command.execute('scene')

      options = result[:data][:options]
      descriptions = options.map { |o| o[:description] }
      expect(descriptions.any? { |d| d.include?('Guide') }).to be true
      expect(descriptions.any? { |d| d.include?('Sage') }).to be true
    end
  end

  describe 'scene filtering' do
    let!(:pending_scene) do
      create(:arranged_scene,
             npc_character: npc_character,
             pc_character: pc_character,
             meeting_room: meeting_room,
             rp_room: rp_room,
             created_by: creator,
             status: 'pending')
    end

    context 'when scene is in wrong room' do
      let(:other_room) { create(:room, location: location) }

      before do
        pending_scene.update(meeting_room_id: other_room.id)
      end

      it 'does not find the scene' do
        result = command.execute('scene')

        expect(result[:success]).to be false
        expect(result[:message]).to include('no arranged scenes')
      end
    end

    context 'when scene is for different character' do
      let(:other_character) { create(:character) }

      before do
        pending_scene.update(pc_character_id: other_character.id)
      end

      it 'does not find the scene' do
        result = command.execute('scene')

        expect(result[:success]).to be false
        expect(result[:message]).to include('no arranged scenes')
      end
    end

    context 'when scene is not pending' do
      before do
        pending_scene.update(status: 'active')
      end

      it 'does not find the scene' do
        result = command.execute('scene')

        expect(result[:success]).to be false
        expect(result[:message]).to include('no arranged scenes')
      end
    end

    context 'when scene has expired' do
      before do
        pending_scene.update(expires_at: Time.now - 3600)
      end

      it 'does not find the scene' do
        result = command.execute('scene')

        expect(result[:success]).to be false
        expect(result[:message]).to include('no arranged scenes')
      end
    end

    context 'when scene is not yet available' do
      before do
        pending_scene.update(available_from: Time.now + 3600)
      end

      it 'does not find the scene' do
        result = command.execute('scene')

        expect(result[:success]).to be false
        expect(result[:message]).to include('no arranged scenes')
      end
    end
  end

  describe 'room description generation' do
    let!(:available_scene) do
      create(:arranged_scene,
             npc_character: npc_character,
             pc_character: pc_character,
             meeting_room: meeting_room,
             rp_room: rp_room,
             created_by: creator,
             status: 'pending')
    end

    let!(:npc_instance) do
      create(:character_instance,
             character: npc_character,
             reality: reality,
             current_room: rp_room,
             online: true)
    end

    before do
      allow(ArrangedSceneService).to receive(:trigger_scene).and_return({
        success: true,
        rp_room: rp_room
      })
    end

    it 'includes room name in response' do
      result = command.execute('scene')

      expect(result[:message]).to include(rp_room.name)
    end

    it 'includes room description if present' do
      rp_room.update(short_description: 'A quiet meeting space')

      result = command.execute('scene')

      expect(result[:message]).to include('quiet meeting space')
    end
  end
end
