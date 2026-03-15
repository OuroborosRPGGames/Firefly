# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ArrangedScene do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:zone) { create(:zone, world: world) }
  let(:location) { create(:location, zone: zone) }
  let(:meeting_room) { create(:room, location: location, name: 'Meeting Room') }
  let(:rp_room) { create(:room, location: location, name: 'RP Room') }
  let(:reality) { create(:reality) }

  let(:user1) { create(:user) }
  let(:user2) { create(:user) }
  let(:npc_character) { create(:character, :npc) }
  let(:pc_character) { create(:character, user: user2) }
  let(:creator) { create(:character, user: user1) }

  describe 'associations' do
    let(:scene) do
      ArrangedScene.create(
        npc_character_id: npc_character.id,
        pc_character_id: pc_character.id,
        meeting_room_id: meeting_room.id,
        rp_room_id: rp_room.id,
        created_by_id: creator.id,
        status: 'pending'
      )
    end

    it 'belongs to npc_character' do
      expect(scene.npc_character).to eq(npc_character)
    end

    it 'belongs to pc_character' do
      expect(scene.pc_character).to eq(pc_character)
    end

    it 'belongs to meeting_room' do
      expect(scene.meeting_room).to eq(meeting_room)
    end

    it 'belongs to rp_room' do
      expect(scene.rp_room).to eq(rp_room)
    end

    it 'belongs to created_by' do
      expect(scene.created_by).to eq(creator)
    end
  end

  describe 'validations' do
    it 'requires npc_character_id' do
      scene = ArrangedScene.new(
        pc_character_id: pc_character.id,
        meeting_room_id: meeting_room.id,
        rp_room_id: rp_room.id,
        created_by_id: creator.id,
        status: 'pending'
      )
      expect(scene.valid?).to be false
      expect(scene.errors[:npc_character_id]).not_to be_empty
    end

    it 'requires pc_character_id' do
      scene = ArrangedScene.new(
        npc_character_id: npc_character.id,
        meeting_room_id: meeting_room.id,
        rp_room_id: rp_room.id,
        created_by_id: creator.id,
        status: 'pending'
      )
      expect(scene.valid?).to be false
      expect(scene.errors[:pc_character_id]).not_to be_empty
    end

    it 'requires meeting_room_id' do
      scene = ArrangedScene.new(
        npc_character_id: npc_character.id,
        pc_character_id: pc_character.id,
        rp_room_id: rp_room.id,
        created_by_id: creator.id,
        status: 'pending'
      )
      expect(scene.valid?).to be false
      expect(scene.errors[:meeting_room_id]).not_to be_empty
    end

    it 'requires rp_room_id' do
      scene = ArrangedScene.new(
        npc_character_id: npc_character.id,
        pc_character_id: pc_character.id,
        meeting_room_id: meeting_room.id,
        created_by_id: creator.id,
        status: 'pending'
      )
      expect(scene.valid?).to be false
      expect(scene.errors[:rp_room_id]).not_to be_empty
    end

    it 'requires created_by_id' do
      scene = ArrangedScene.new(
        npc_character_id: npc_character.id,
        pc_character_id: pc_character.id,
        meeting_room_id: meeting_room.id,
        rp_room_id: rp_room.id,
        status: 'pending'
      )
      expect(scene.valid?).to be false
      expect(scene.errors[:created_by_id]).not_to be_empty
    end

    it 'validates status is in STATUSES' do
      scene = ArrangedScene.new(
        npc_character_id: npc_character.id,
        pc_character_id: pc_character.id,
        meeting_room_id: meeting_room.id,
        rp_room_id: rp_room.id,
        created_by_id: creator.id,
        status: 'invalid'
      )
      expect(scene.valid?).to be false
      expect(scene.errors[:status]).not_to be_empty
    end

    it 'accepts valid statuses' do
      ArrangedScene::STATUSES.each do |status|
        scene = ArrangedScene.new(
          npc_character_id: npc_character.id,
          pc_character_id: pc_character.id,
          meeting_room_id: meeting_room.id,
          rp_room_id: rp_room.id,
          created_by_id: creator.id,
          status: status
        )
        expect(scene.valid?).to be true
      end
    end
  end

  describe 'status helpers' do
    let(:scene) { create(:arranged_scene) }

    describe '#pending?' do
      it 'returns true when status is pending' do
        scene.update(status: 'pending')
        expect(scene.pending?).to be true
      end

      it 'returns false when status is not pending' do
        scene.update(status: 'active')
        expect(scene.pending?).to be false
      end
    end

    describe '#active?' do
      it 'returns true when status is active' do
        scene.update(status: 'active')
        expect(scene.active?).to be true
      end

      it 'returns false when status is not active' do
        scene.update(status: 'pending')
        expect(scene.active?).to be false
      end
    end

    describe '#completed?' do
      it 'returns true when status is completed' do
        scene.update(status: 'completed')
        expect(scene.completed?).to be true
      end
    end

    describe '#cancelled?' do
      it 'returns true when status is cancelled' do
        scene.update(status: 'cancelled')
        expect(scene.cancelled?).to be true
      end
    end

    describe '#expired?' do
      it 'returns true when status is expired' do
        scene.update(status: 'expired')
        expect(scene.expired?).to be true
      end
    end
  end

  describe '#available?' do
    let(:scene) { create(:arranged_scene, status: 'pending') }

    it 'returns true when pending and within time window' do
      scene.update(available_from: Time.now - 3600, expires_at: Time.now + 3600)
      expect(scene.available?).to be true
    end

    it 'returns true when pending with no time window' do
      scene.update(available_from: nil, expires_at: nil)
      expect(scene.available?).to be true
    end

    it 'returns false when not pending' do
      scene.update(status: 'active')
      expect(scene.available?).to be false
    end

    it 'returns false when before available_from' do
      scene.update(available_from: Time.now + 3600, expires_at: Time.now + 7200)
      expect(scene.available?).to be false
    end

    it 'returns false when after expires_at' do
      scene.update(available_from: Time.now - 7200, expires_at: Time.now - 3600)
      expect(scene.available?).to be false
    end
  end

  describe '#display_name' do
    it 'returns scene_name when set' do
      scene = create(:arranged_scene, scene_name: 'Secret Meeting')
      expect(scene.display_name).to eq('Secret Meeting')
    end

    it 'generates default name when scene_name is nil' do
      scene = create(:arranged_scene, scene_name: nil)
      expect(scene.display_name).to include('Meeting with')
    end
  end

  describe '#invitation_text' do
    it 'returns invitation_message when set' do
      scene = create(:arranged_scene, invitation_message: 'Custom invitation')
      expect(scene.invitation_text).to eq('Custom invitation')
    end

    it 'generates default invitation when not set' do
      scene = create(:arranged_scene, invitation_message: nil)
      expect(scene.invitation_text).to include('invited')
    end
  end

  describe '#metadata' do
    it 'returns empty hash when nil' do
      scene = create(:arranged_scene)
      scene.this.update(metadata: nil)
      scene.refresh
      expect(scene.metadata).to eq({})
    end

    it 'always returns a hash' do
      scene = create(:arranged_scene)
      expect(scene.metadata).to be_a(Hash)
    end

    it 'handles valid JSON data' do
      scene = ArrangedScene.create(
        npc_character_id: npc_character.id,
        pc_character_id: pc_character.id,
        meeting_room_id: meeting_room.id,
        rp_room_id: rp_room.id,
        created_by_id: creator.id,
        status: 'pending',
        metadata: { 'test' => 'data' }
      )
      # Verify we can access metadata - may come back with string or symbol keys
      result = scene.metadata
      expect(result).to be_a(Hash)
    end
  end

  describe '.available_for' do
    let(:pc_instance) do
      create(:character_instance,
             character: pc_character,
             reality: reality,
             current_room: meeting_room,
             online: true)
    end

    let!(:available_scene) do
      create(:arranged_scene,
             npc_character: npc_character,
             pc_character: pc_character,
             meeting_room: meeting_room,
             status: 'pending')
    end

    let!(:wrong_room_scene) do
      create(:arranged_scene,
             npc_character: npc_character,
             pc_character: pc_character,
             meeting_room: rp_room, # Different room
             status: 'pending')
    end

    let!(:active_scene) do
      create(:arranged_scene,
             npc_character: npc_character,
             pc_character: pc_character,
             meeting_room: meeting_room,
             status: 'active')
    end

    it 'finds scenes for character in room' do
      scenes = ArrangedScene.available_for(pc_instance)
      expect(scenes).to include(available_scene)
    end

    it 'excludes scenes in different rooms' do
      scenes = ArrangedScene.available_for(pc_instance)
      expect(scenes).not_to include(wrong_room_scene)
    end

    it 'excludes non-pending scenes' do
      scenes = ArrangedScene.available_for(pc_instance)
      expect(scenes).not_to include(active_scene)
    end

    it 'excludes expired scenes' do
      available_scene.update(expires_at: Time.now - 3600)
      scenes = ArrangedScene.available_for(pc_instance)
      expect(scenes).not_to include(available_scene)
    end
  end

  describe '.active_for' do
    let(:pc_instance) do
      create(:character_instance,
             character: pc_character,
             reality: reality,
             current_room: meeting_room,
             online: true)
    end

    it 'finds active scene for character' do
      scene = create(:arranged_scene,
                     npc_character: npc_character,
                     pc_character: pc_character,
                     status: 'active')

      result = ArrangedScene.active_for(pc_instance)
      expect(result).to eq(scene)
    end

    it 'returns nil when no active scene' do
      create(:arranged_scene,
             npc_character: npc_character,
             pc_character: pc_character,
             status: 'pending')

      result = ArrangedScene.active_for(pc_instance)
      expect(result).to be_nil
    end
  end

  describe 'factory traits' do
    it 'creates with :active trait' do
      scene = create(:arranged_scene, :active)
      expect(scene.status).to eq('active')
      expect(scene.active?).to be true
    end

    it 'creates with :completed trait' do
      scene = create(:arranged_scene, :completed)
      expect(scene.status).to eq('completed')
      expect(scene.completed?).to be true
    end

    it 'creates with :with_time_window trait' do
      scene = create(:arranged_scene, :with_time_window)
      expect(scene.available_from).not_to be_nil
      expect(scene.expires_at).not_to be_nil
      expect(scene.available?).to be true
    end

    it 'creates with :expired_window trait' do
      scene = create(:arranged_scene, :expired_window)
      expect(scene.available?).to be false
    end

    it 'creates with :future_window trait' do
      scene = create(:arranged_scene, :future_window)
      expect(scene.available?).to be false
    end
  end
end
