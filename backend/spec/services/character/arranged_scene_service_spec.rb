# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ArrangedSceneService do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area) }
  let(:meeting_room) { create(:room, location: location, name: 'Meeting Room') }
  let(:rp_room) { create(:room, location: location, name: 'RP Room') }
  let(:reality) { create(:reality) }

  let(:npc_character) { create(:character, :npc, forename: 'Guide') }
  let(:pc_character) { create(:character, forename: 'Player') }
  let(:staff_character) { create(:character, forename: 'Staff') }

  let(:pc_instance) do
    create(:character_instance, character: pc_character, current_room: meeting_room, reality: reality, online: true)
  end

  before do
    allow(BroadcastService).to receive(:to_character)
    allow(BroadcastService).to receive(:to_room)
    allow(StaffAlertService).to receive(:broadcast_to_staff) if defined?(StaffAlertService)
  end

  describe '.create_scene' do
    it 'creates an arranged scene' do
      result = described_class.create_scene(
        npc_character: npc_character,
        pc_character: pc_character,
        meeting_room: meeting_room,
        rp_room: rp_room,
        created_by: staff_character
      )

      expect(result[:success]).to be true
      expect(result[:scene]).to be_a(ArrangedScene)
    end

    it 'sets scene to pending status' do
      result = described_class.create_scene(
        npc_character: npc_character,
        pc_character: pc_character,
        meeting_room: meeting_room,
        rp_room: rp_room,
        created_by: staff_character
      )

      expect(result[:scene].status).to eq('pending')
    end

    it 'accepts optional scene name' do
      result = described_class.create_scene(
        npc_character: npc_character,
        pc_character: pc_character,
        meeting_room: meeting_room,
        rp_room: rp_room,
        created_by: staff_character,
        scene_name: 'Important Meeting'
      )

      expect(result[:scene].scene_name).to eq('Important Meeting')
    end

    it 'accepts NPC instructions' do
      result = described_class.create_scene(
        npc_character: npc_character,
        pc_character: pc_character,
        meeting_room: meeting_room,
        rp_room: rp_room,
        created_by: staff_character,
        npc_instructions: 'Be mysterious and helpful'
      )

      expect(result[:scene].npc_instructions).to eq('Be mysterious and helpful')
    end

    it 'accepts invitation message' do
      result = described_class.create_scene(
        npc_character: npc_character,
        pc_character: pc_character,
        meeting_room: meeting_room,
        rp_room: rp_room,
        created_by: staff_character,
        invitation_message: 'Please meet me at the café'
      )

      expect(result[:scene].invitation_message).to eq('Please meet me at the café')
    end

    context 'when PC is online' do
      before do
        pc_instance # create the online instance
      end

      it 'sends invitation' do
        described_class.create_scene(
          npc_character: npc_character,
          pc_character: pc_character,
          meeting_room: meeting_room,
          rp_room: rp_room,
          created_by: staff_character
        )

        expect(BroadcastService).to have_received(:to_character).at_least(:once)
      end
    end
  end

  describe '.cancel_scene' do
    let(:scene) do
      ArrangedScene.create(
        npc_character_id: npc_character.id,
        pc_character_id: pc_character.id,
        meeting_room_id: meeting_room.id,
        rp_room_id: rp_room.id,
        created_by_id: staff_character.id,
        status: 'pending'
      )
    end

    it 'cancels a pending scene' do
      result = described_class.cancel_scene(scene)
      expect(result[:success]).to be true
      expect(scene.reload.status).to eq('cancelled')
    end

    context 'when scene is not pending' do
      before do
        scene.update(status: 'active')
      end

      it 'returns error' do
        result = described_class.cancel_scene(scene)
        expect(result[:success]).to be false
        expect(result[:message]).to match(/not pending/i)
      end
    end
  end

  describe '.trigger_scene' do
    let(:scene) do
      ArrangedScene.create(
        npc_character_id: npc_character.id,
        pc_character_id: pc_character.id,
        meeting_room_id: meeting_room.id,
        rp_room_id: rp_room.id,
        created_by_id: staff_character.id,
        status: 'pending'
      )
    end

    context 'when scene is not available' do
      before do
        scene.update(status: 'cancelled')
      end

      it 'returns error' do
        result = described_class.trigger_scene(scene, pc_instance)
        expect(result[:success]).to be false
        expect(result[:message]).to match(/not available/i)
      end
    end
  end

  describe '.end_scene' do
    let(:scene) do
      ArrangedScene.create(
        npc_character_id: npc_character.id,
        pc_character_id: pc_character.id,
        meeting_room_id: meeting_room.id,
        rp_room_id: rp_room.id,
        created_by_id: staff_character.id,
        status: 'active',
        started_at: Time.now
      )
    end

    context 'when scene is not active' do
      before do
        scene.update(status: 'pending')
      end

      it 'returns error' do
        result = described_class.end_scene(scene, pc_instance)
        expect(result[:success]).to be false
        expect(result[:message]).to match(/not active/i)
      end
    end
  end

  describe '.send_invitation' do
    let(:scene) do
      ArrangedScene.create(
        npc_character_id: npc_character.id,
        pc_character_id: pc_character.id,
        meeting_room_id: meeting_room.id,
        rp_room_id: rp_room.id,
        created_by_id: staff_character.id,
        status: 'pending'
      )
    end

    context 'when PC is not online' do
      it 'does not send message' do
        described_class.send_invitation(scene)
        expect(BroadcastService).not_to have_received(:to_character)
      end
    end

    context 'when PC is online' do
      before do
        pc_instance # create the online instance
      end

      it 'sends invitation message' do
        described_class.send_invitation(scene)
        expect(BroadcastService).to have_received(:to_character).at_least(:once)
      end
    end
  end
end
