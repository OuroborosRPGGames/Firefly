# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MovementService do
  let(:location) { create(:location) }
  # Room A at (0,0)-(100,100), Room B at (0,100)-(100,200) - adjacent on north edge
  let(:room_a) { create(:room, name: 'Room A', short_description: 'Start', location: location, indoors: false, min_x: 0, max_x: 100, min_y: 0, max_y: 100) }
  let(:room_b) { create(:room, name: 'Room B', short_description: 'North room', location: location, indoors: false, min_x: 0, max_x: 100, min_y: 100, max_y: 200) }
  let(:reality) { create(:reality) }
  let(:user) { create(:user) }
  let(:character) { create(:character, forename: 'Test', surname: 'Character', user: user) }
  let(:character_instance) { create(:character_instance, character: character, reality: reality, current_room: room_a) }

  # Spatial exit from room_a to room_b via north
  let(:north_exit) { MovementService::SpatialExit.new(to_room: room_b, direction: 'north', from_room: room_a) }

  # Ensure room_b exists for spatial adjacency
  before { room_b }

  describe '.start_movement' do
    context 'with direction target' do
      it 'starts movement and creates timed action' do
        result = described_class.start_movement(character_instance, target: 'north')

        expect(result.success).to be true
        expect(result.message).to include('walking')
        expect(character_instance.reload.movement_state).to eq('moving')
      end

      it 'creates a timed action for the movement' do
        expect do
          described_class.start_movement(character_instance, target: 'north')
        end.to change { TimedAction.count }.by(1)

        action = TimedAction.last
        expect(action.action_name).to eq('movement')
        expect(action.completion_handler).to eq('MovementHandler')
      end

      it 'uses custom movement verb' do
        result = described_class.start_movement(character_instance, target: 'north', adverb: 'run')

        expect(result.success).to be true
        expect(result.message).to include('running')
      end
    end

    context 'when already moving' do
      before do
        character_instance.update(movement_state: 'moving')
      end

      it 'returns error' do
        result = described_class.start_movement(character_instance, target: 'north')

        expect(result.success).to be false
        expect(result.message).to include('Already moving')
      end
    end

    context 'with blocked exit (wall with closed door)' do
      before do
        # Make rooms indoor and add wall with closed door
        room_a.update(indoors: true)
        room_b.update(indoors: true)
        create(:room_feature, room: room_a, feature_type: 'wall', direction: 'north')
        create(:room_feature, room: room_a, feature_type: 'door', direction: 'north', is_open: false)
      end

      it 'returns error' do
        result = described_class.start_movement(character_instance, target: 'north')

        expect(result.success).to be false
        # When exit is blocked, direction is recognized but no passable exit exists
        expect(result.message).to match(/can't go that way|can't find|no exit|blocked/i)
      end
    end

    context 'with invalid direction' do
      before do
        allow(TargetResolverService).to receive(:resolve_movement_target).and_return(
          double(type: :error, error: 'No exit in that direction')
        )
      end

      it 'returns error' do
        result = described_class.start_movement(character_instance, target: 'nowhere')

        expect(result.success).to be false
      end
    end

    context 'with a Room object target' do
      it 'bypasses resolver and pathfinds directly' do
        fake_result = double(success: true, message: 'Pathing to room object')
        allow(described_class).to receive(:start_pathfind_movement).and_return(fake_result)

        expect(TargetResolverService).not_to receive(:resolve_movement_target)
        expect(described_class).to receive(:start_pathfind_movement).with(
          character_instance,
          room_b,
          'walk',
          skip_autodrive: false
        )

        result = described_class.start_movement(character_instance, target: room_b)
        expect(result).to eq(fake_result)
      end
    end
  end

  describe '.stop_movement' do
    context 'when moving' do
      before do
        described_class.start_movement(character_instance, target: 'north')
      end

      it 'stops the movement' do
        result = described_class.stop_movement(character_instance)

        expect(result.success).to be true
        expect(character_instance.reload.movement_state).to eq('idle')
      end

      it 'cancels the timed action' do
        described_class.stop_movement(character_instance)

        action = TimedAction.where(character_instance_id: character_instance.id).first
        expect(action.reload.status).to eq('cancelled')
      end
    end

    context 'when not moving' do
      it 'returns error' do
        result = described_class.stop_movement(character_instance)

        expect(result.success).to be false
        expect(result.message).to include('Not moving')
      end
    end
  end

  describe '.complete_room_transition' do
    it 'moves the character to the new room' do
      result = described_class.complete_room_transition(character_instance, north_exit)

      expect(result.success).to be true
      expect(character_instance.reload.current_room_id).to eq(room_b.id)
    end

    it 'resets movement state for single-room movement' do
      character_instance.update(movement_state: 'moving', movement_adverb: 'walk')

      described_class.complete_room_transition(character_instance, north_exit)

      expect(character_instance.reload.movement_state).to eq('idle')
    end

    describe 'game score cleanup on room exit' do
      it 'clears game scores when leaving a room' do
        # Setup character with movement state
        character_instance.update(movement_state: 'moving', movement_adverb: 'walk')

        # Expect GameScore.clear_for_room to be called with the OLD room id (room_a)
        expect(GameScore).to receive(:clear_for_room).with(room_a.id, character_instance.id)

        # Complete the transition from room_a to room_b
        described_class.complete_room_transition(character_instance, north_exit)
      end
    end
  end

  describe '.moving?' do
    it 'returns true when movement_state is moving' do
      character_instance.update(movement_state: 'moving')

      expect(described_class.moving?(character_instance)).to be true
    end

    it 'returns false when movement_state is idle' do
      character_instance.update(movement_state: 'idle')

      expect(described_class.moving?(character_instance)).to be false
    end
  end

  describe 'following' do
    let(:user2) { create(:user) }
    let(:leader_character) { Character.create(forename: 'Leader', user: user2, is_npc: false) }
    let(:leader_instance) do
      CharacterInstance.create(
        character: leader_character,
        reality: reality,
        current_room: room_a,
        online: true,
        status: 'alive',
        level: 1,
        experience: 0,
        health: 100,
        max_health: 100,
        mana: 50,
        max_mana: 50
      )
    end

    describe '.start_following' do
      context 'without permission' do
        it 'returns error' do
          result = described_class.start_following(character_instance, leader_instance)

          expect(result.success).to be false
          expect(result.message).to include('permission')
        end
      end

      context 'with permission' do
        before do
          Relationship.create(
            character: character,
            target_character: leader_character,
            status: 'accepted',
            can_follow: true
          )
        end

        it 'starts following' do
          result = described_class.start_following(character_instance, leader_instance)

          expect(result.success).to be true
          expect(character_instance.reload.following_id).to eq(leader_instance.id)
          expect(character_instance.movement_state).to eq('following')
        end
      end

      context 'when trying to follow self' do
        it 'returns error' do
          result = described_class.start_following(character_instance, character_instance)

          expect(result.success).to be false
          expect(result.message).to include('yourself')
        end
      end
    end

    describe '.stop_following' do
      before do
        Relationship.create(
          character: character,
          target_character: leader_character,
          status: 'accepted',
          can_follow: true
        )
        described_class.start_following(character_instance, leader_instance)
      end

      it 'stops following' do
        result = described_class.stop_following(character_instance)

        expect(result.success).to be true
        expect(character_instance.reload.following_id).to be_nil
        expect(character_instance.movement_state).to eq('idle')
      end
    end

    describe '.grant_follow_permission' do
      it 'creates relationship with follow permission' do
        result = described_class.grant_follow_permission(leader_instance, character_instance)

        expect(result.success).to be true

        rel = Relationship.between(character, leader_character)
        expect(rel).not_to be_nil
        expect(rel.can_follow).to be true
        expect(rel.status).to eq('accepted')
      end
    end

    describe '.revoke_follow_permission' do
      before do
        Relationship.create(
          character: character,
          target_character: leader_character,
          status: 'accepted',
          can_follow: true
        )
        described_class.start_following(character_instance, leader_instance)
      end

      it 'revokes permission and stops following' do
        result = described_class.revoke_follow_permission(leader_instance, character_instance)

        expect(result.success).to be true

        rel = Relationship.between(character, leader_character)
        expect(rel.can_follow).to be false
        expect(character_instance.reload.following_id).to be_nil
      end
    end
  end

  describe 'movement restrictions' do
    context 'when character is unconscious' do
      before do
        allow(character_instance).to receive(:can_move_independently?).and_return(false)
        allow(character_instance).to receive(:unconscious?).and_return(true)
      end

      it 'prevents movement' do
        result = described_class.start_movement(character_instance, target: 'north')

        expect(result.success).to be false
        expect(result.message).to include('unconscious')
      end
    end

    context 'when character has feet bound' do
      before do
        allow(character_instance).to receive(:can_move_independently?).and_return(false)
        allow(character_instance).to receive(:unconscious?).and_return(false)
        allow(character_instance).to receive(:feet_bound?).and_return(true)
      end

      it 'prevents movement' do
        result = described_class.start_movement(character_instance, target: 'north')

        expect(result.success).to be false
        expect(result.message).to include('feet are bound')
      end
    end

    context 'when character is being held' do
      let(:captor_character) { double('CaptorCharacter') }
      let(:captor) { double('Captor', character: captor_character) }

      before do
        allow(captor_character).to receive(:display_name_for).and_return('Guard')
        allow(character_instance).to receive(:can_move_independently?).and_return(false)
        allow(character_instance).to receive(:unconscious?).and_return(false)
        allow(character_instance).to receive(:feet_bound?).and_return(false)
        allow(character_instance).to receive(:being_moved?).and_return(true)
        allow(character_instance).to receive(:captor).and_return(captor)
      end

      it 'prevents movement' do
        result = described_class.start_movement(character_instance, target: 'north')

        expect(result.success).to be false
        expect(result.message).to include('being held')
        expect(result.message).to include('Guard')
      end
    end
  end

  describe 'room access checks' do
    # Staff room at west of room_a: (-100,0)-(0,100)
    let(:staff_only_room) do
      Room.create(
        name: 'Staff Room',
        short_description: 'Staff only',
        location: location,
        room_type: 'standard',
        staff_only: true,
        indoors: false,
        min_x: -100, max_x: 0, min_y: 0, max_y: 100
      )
    end

    # Just ensure staff_only_room is created - spatial adjacency handles the exit
    before { staff_only_room }

    context 'with staff-only room' do
      it 'denies access to non-staff' do
        result = described_class.start_movement(character_instance, target: 'west')

        expect(result.success).to be false
        expect(result.message).to include('restricted to staff')
      end

      it 'allows access to staff' do
        # User needs permission to create staff characters
        user.update(is_admin: true)
        character.update(is_staff_character: true)

        result = described_class.start_movement(character_instance, target: 'west')

        expect(result.success).to be true
      end
    end

    context 'with active fight in room' do
      # Fight room at east of room_a: (100,0)-(200,100)
      let(:fight_room) do
        Room.create(name: 'Fight Room', short_description: 'Fight here', location: location, room_type: 'standard', indoors: false, min_x: 100, max_x: 200, min_y: 0, max_y: 100)
      end

      before do
        fight_room # Ensure created for spatial adjacency
        Fight.create(room_id: fight_room.id, status: 'input')
        allow(FightEntryDelayService).to receive(:can_enter?).and_return(false)
        allow(FightEntryDelayService).to receive(:rounds_until_entry).and_return(3)
      end

      it 'denies entry during active fight' do
        result = described_class.start_movement(character_instance, target: 'east')

        expect(result.success).to be false
        expect(result.message).to include('fight is in progress')
        expect(result.message).to include('3 more combat round')
      end
    end

    context 'with recently ended fight' do
      # Fight room at east of room_a: (100,0)-(200,100)
      let(:fight_room) do
        Room.create(name: 'Fight Room', short_description: 'Fight here', location: location, room_type: 'standard', indoors: false, min_x: 100, max_x: 200, min_y: 0, max_y: 100)
      end

      let!(:recent_fight) do
        fight_room # Ensure room is created first
        Fight.create(
          room_id: fight_room.id,
          status: 'complete',
          combat_ended_at: Time.now - 300 # 5 minutes ago (within 10 min cooldown)
        )
      end

      it 'denies entry during cooldown' do
        result = described_class.start_movement(character_instance, target: 'east')

        expect(result.success).to be false
        expect(result.message).to include('Combat recently ended')
      end

      it 'allows entry for fight participants' do
        FightParticipant.create(fight: recent_fight, character_instance: character_instance)

        result = described_class.start_movement(character_instance, target: 'east')

        expect(result.success).to be true
      end
    end

    context 'with locked room' do
      let(:owner_user) { create(:user) }
      let(:room_owner) do
        Character.create(forename: 'Owner', user: owner_user, is_npc: false)
      end

      # Locked room at south of room_a: (0,-100)-(100,0)
      let(:locked_room) do
        # A room is locked when it has an owner but no public unlocks
        Room.create(
          name: 'Locked Room',
          short_description: 'Locked',
          location: location,
          room_type: 'standard',
          owner_id: room_owner.id,
          indoors: false,
          min_x: 0, max_x: 100, min_y: -100, max_y: 0
        )
      end

      before { locked_room } # Ensure created for spatial adjacency

      it 'denies entry to locked room' do
        result = described_class.start_movement(character_instance, target: 'south')

        expect(result.success).to be false
        expect(result.message).to include('door is locked')
      end
    end
  end

  describe 'pathfinding movement' do
    # Room C at (0,200)-(100,300), north of room_b
    let(:room_c) { Room.create(name: 'Room C', short_description: 'Far room', location: location, room_type: 'standard', indoors: false, min_x: 0, max_x: 100, min_y: 200, max_y: 300) }
    let(:bc_exit) { MovementService::SpatialExit.new(to_room: room_c, direction: 'north', from_room: room_b) }

    context 'when path exists' do
      before do
        room_c # Ensure created
        allow(TargetResolverService).to receive(:resolve_movement_target).and_return(
          double(type: :room, room: room_c, target: room_c)
        )
        allow(PathfindingService).to receive(:find_path).and_return([north_exit, bc_exit])
      end

      it 'starts multi-room movement' do
        result = described_class.start_movement(character_instance, target: room_c.name)

        expect(result.success).to be true
        expect(result.message).to include('walking toward', room_c.name)
        expect(character_instance.reload.final_destination_id).to eq(room_c.id)
      end
    end

    context 'when no path exists' do
      before do
        allow(TargetResolverService).to receive(:resolve_movement_target).and_return(
          double(type: :room, room: room_c, target: room_c)
        )
        allow(PathfindingService).to receive(:find_path).and_return([])
      end

      it 'falls back to smart navigation' do
        smart_nav = instance_double(SmartNavigationService)
        allow(SmartNavigationService).to receive(:new).and_return(smart_nav)
        allow(smart_nav).to receive(:navigate_to).and_return({ success: true, message: 'Taking a taxi', travel_type: 'taxi' })

        result = described_class.start_movement(character_instance, target: room_c.name)

        expect(result.success).to be true
        expect(result.data[:smart_navigation]).to be true
      end

      it 'returns error when smart navigation fails' do
        smart_nav = instance_double(SmartNavigationService)
        allow(SmartNavigationService).to receive(:new).and_return(smart_nav)
        allow(smart_nav).to receive(:navigate_to).and_return({ success: false, error: 'No route available' })

        result = described_class.start_movement(character_instance, target: room_c.name)

        expect(result.success).to be false
        expect(result.message).to include('No route available')
      end
    end
  end

  describe 'character-targeted movement' do
    let(:user2) { create(:user) }
    let(:target_character) { Character.create(forename: 'Target', user: user2, is_npc: false) }
    let(:target_instance) do
      CharacterInstance.create(
        character: target_character,
        reality: reality,
        current_room: room_b,
        online: true,
        status: 'alive',
        level: 1,
        experience: 0,
        health: 100,
        max_health: 100,
        mana: 50,
        max_mana: 50
      )
    end

    # Viewer knows the target character so display_name_for returns forename
    before do
      CharacterKnowledge.create(
        knower_character: character,
        known_character: target_character,
        is_known: true,
        known_name: 'Target'
      )
    end

    context 'when target is in different room' do
      before do
        allow(PathfindingService).to receive(:find_path).and_return([north_exit])
        allow(TargetResolverService).to receive(:resolve_movement_target).and_return(
          double(type: :character, target: target_instance)
        )
      end

      it 'starts movement toward character' do
        result = described_class.start_movement(character_instance, target: 'Target')

        expect(result.success).to be true
        expect(result.message).to include('toward Target')
        expect(character_instance.reload.person_target_id).to eq(target_instance.id)
      end
    end

    context 'when target is in same room' do
      before do
        target_instance.update(current_room: room_a)
        allow(TargetResolverService).to receive(:resolve_movement_target).and_return(
          double(type: :character, target: target_instance)
        )
      end

      it 'returns error' do
        result = described_class.start_movement(character_instance, target: 'Target')

        expect(result.success).to be false
        expect(result.message).to include('right here')
      end
    end

    context 'when no path to target' do
      before do
        allow(PathfindingService).to receive(:find_path).and_return([])
        allow(TargetResolverService).to receive(:resolve_movement_target).and_return(
          double(type: :character, target: target_instance)
        )
      end

      it 'returns error' do
        result = described_class.start_movement(character_instance, target: 'Target')

        expect(result.success).to be false
        expect(result.message).to include("find a way to get to")
      end
    end
  end

  describe 'furniture approach' do
    let(:furniture) { Place.create(name: 'Comfortable Chair', room: room_a, x: 20.0, y: 20.0, capacity: 4) }

    before do
      allow(TargetResolverService).to receive(:resolve_movement_target).and_return(
        double(type: :furniture, target: furniture)
      )
    end

    context 'when close to furniture' do
      before do
        character_instance.update(x: 18.0, y: 18.0)
      end

      it 'moves instantly' do
        result = described_class.start_movement(character_instance, target: 'chair')

        expect(result.success).to be true
        expect(result.data[:instant]).to be true
      end
    end

    context 'when far from furniture' do
      before do
        character_instance.update(x: 0.0, y: 0.0)
      end

      it 'creates timed approach action' do
        expect do
          described_class.start_movement(character_instance, target: 'chair')
        end.to change { TimedAction.count }.by(1)

        action = TimedAction.last
        expect(action.action_name).to eq('approach')
        expect(action.completion_handler).to eq('ApproachHandler')
      end
    end
  end

  describe 'movement adverb normalization' do
    it 'accepts valid movement verbs' do
      result = described_class.start_movement(character_instance, target: 'north', adverb: 'run')

      expect(result.success).to be true
      expect(result.message).to include('running')
    end

    it 'normalizes to default for invalid verbs' do
      result = described_class.start_movement(character_instance, target: 'north', adverb: 'teleport')

      expect(result.success).to be true
      expect(result.message).to include('walking')
    end

    it 'handles nil adverb' do
      result = described_class.start_movement(character_instance, target: 'north', adverb: nil)

      expect(result.success).to be true
    end
  end

  describe 'prisoner movement' do
    let(:prisoner_user) { create(:user) }
    let(:prisoner_char) { Character.create(forename: 'Prisoner', user: prisoner_user, is_npc: false) }
    let(:prisoner_instance) do
      CharacterInstance.create(
        character: prisoner_char,
        reality: reality,
        current_room: room_a,
        online: true,
        status: 'alive',
        level: 1,
        experience: 0,
        health: 100,
        max_health: 100,
        mana: 50,
        max_mana: 50,
        being_dragged_by_id: character_instance.id
      )
    end

    before do
      prisoner_instance
      allow(PrisonerService).to receive(:movement_speed_modifier).and_return(1.5)
      allow(PrisonerService).to receive(:move_prisoners!).and_return([prisoner_instance])
      allow(prisoner_instance).to receive(:being_dragged?).and_return(true)
      allow(BroadcastService).to receive(:to_room)
      allow(BroadcastService).to receive(:to_character)
      allow(ContentConsentService).to receive(:on_room_entry)
    end

    describe 'movement speed modifier' do
      it 'applies speed modifier when dragging prisoner' do
        result = described_class.start_movement(character_instance, target: 'north')

        expect(result.success).to be true
        expect(PrisonerService).to have_received(:movement_speed_modifier).with(character_instance)
      end
    end

    describe 'during room transition' do
      it 'moves prisoners with captor' do
        character_instance.update(movement_state: 'moving', movement_adverb: 'walk')

        described_class.complete_room_transition(character_instance, north_exit)

        expect(PrisonerService).to have_received(:move_prisoners!).with(character_instance, room_b)
      end

      it 'broadcasts drag message for dragged prisoners' do
        # Add a viewer in the destination room to receive personalized broadcast
        viewer_user = create(:user)
        viewer_char = Character.create(forename: 'Viewer', user: viewer_user, is_npc: false)
        viewer_instance = CharacterInstance.create(
          character: viewer_char, reality: reality, current_room: room_b,
          online: true, status: 'alive', level: 1, experience: 0,
          health: 100, max_health: 100, mana: 50, max_mana: 50
        )

        character_instance.update(movement_state: 'moving', movement_adverb: 'walk')

        described_class.complete_room_transition(character_instance, north_exit)

        expect(BroadcastService).to have_received(:to_character).with(
          viewer_instance,
          include('drags'),
          any_args
        )
      end
    end
  end

  describe 'follower movement' do
    let(:follower_user) { create(:user) }
    let(:follower_char) { Character.create(forename: 'Follower', user: follower_user, is_npc: false) }
    let(:follower_instance) do
      CharacterInstance.create(
        character: follower_char,
        reality: reality,
        current_room: room_a,
        online: true,
        status: 'alive',
        level: 1,
        experience: 0,
        health: 100,
        max_health: 100,
        mana: 50,
        max_mana: 50,
        following_id: character_instance.id
      )
    end

    before do
      follower_instance
    end

    it 'creates timed action for followers during room transition' do
      character_instance.update(movement_state: 'moving', movement_adverb: 'walk')

      expect do
        described_class.complete_room_transition(character_instance, north_exit)
      end.to change { TimedAction.where(character_instance_id: follower_instance.id).count }.by(1)
    end

    it 'does not create action for followers already moving' do
      character_instance.update(movement_state: 'moving', movement_adverb: 'walk')
      follower_instance.update(movement_state: 'moving')

      expect do
        described_class.complete_room_transition(character_instance, north_exit)
      end.not_to(change { TimedAction.where(character_instance_id: follower_instance.id).count })
    end
  end

  describe 'multi-room destination continuation' do
    # Room C at (0,200)-(100,300), north of room_b
    let(:room_c) { Room.create(name: 'Room C', short_description: 'Final', location: location, room_type: 'standard', indoors: false, min_x: 0, max_x: 100, min_y: 200, max_y: 300) }
    let(:bc_exit) { MovementService::SpatialExit.new(to_room: room_c, direction: 'north', from_room: room_b) }

    before do
      room_c # Ensure created
      character_instance.update(
        movement_state: 'moving',
        movement_adverb: 'walk',
        final_destination_id: room_c.id
      )
      allow(PathfindingService).to receive(:find_path).and_return([bc_exit])
    end

    it 'continues moving when not at final destination' do
      described_class.complete_room_transition(character_instance, north_exit)

      expect(character_instance.reload.movement_state).to eq('moving')
      expect(character_instance.current_room_id).to eq(room_b.id)

      # Should have created a new timed action for continued movement
      action = TimedAction.where(
        character_instance_id: character_instance.id,
        action_name: 'movement'
      ).order(:id).last

      expect(action).not_to be_nil
    end

    it 'stops when reaching final destination' do
      character_instance.update(final_destination_id: room_b.id)

      described_class.complete_room_transition(character_instance, north_exit)

      expect(character_instance.reload.movement_state).to eq('idle')
      expect(character_instance.final_destination_id).to be_nil
    end
  end

  describe 'person target continuation' do
    let(:target_user) { create(:user) }
    let(:target_char) { Character.create(forename: 'Target', user: target_user, is_npc: false) }
    let(:target_instance) do
      CharacterInstance.create(
        character: target_char,
        reality: reality,
        current_room: room_b,
        online: true,
        status: 'alive',
        level: 1,
        experience: 0,
        health: 100,
        max_health: 100,
        mana: 50,
        max_mana: 50
      )
    end

    before do
      target_instance
      character_instance.update(
        movement_state: 'moving',
        movement_adverb: 'walk',
        person_target_id: target_instance.id
      )
    end

    it 'stops when reaching person in same room' do
      described_class.complete_room_transition(character_instance, north_exit)

      expect(character_instance.reload.movement_state).to eq('idle')
      expect(character_instance.person_target_id).to be_nil
    end

    it 'stops when target goes offline' do
      target_instance.update(online: false)

      # Move to room_b, but target is offline
      described_class.complete_room_transition(character_instance, north_exit)

      expect(character_instance.reload.movement_state).to eq('idle')
      expect(character_instance.person_target_id).to be_nil
    end
  end

  describe 'context clearing on movement' do
    let(:other_user) { create(:user) }
    let(:other_character) { Character.create(forename: 'Other', user: other_user, is_npc: false) }
    let(:other_instance) do
      CharacterInstance.create(
        character: other_character,
        reality: reality,
        current_room: room_a,
        online: true,
        status: 'alive',
        level: 1,
        experience: 0,
        health: 100,
        max_health: 100,
        mana: 50,
        max_mana: 50
      )
    end

    let(:enemy_user) { create(:user) }
    let(:enemy_character) { Character.create(forename: 'Enemy', user: enemy_user, is_npc: false) }
    let(:enemy_instance) do
      CharacterInstance.create(
        character: enemy_character,
        reality: reality,
        current_room: room_a,
        online: true,
        status: 'alive',
        level: 1,
        experience: 0,
        health: 100,
        max_health: 100,
        mana: 50,
        max_mana: 50
      )
    end

    before do
      character_instance.update(movement_state: 'moving', movement_adverb: 'walk')
    end

    it 'clears interaction context when changing rooms' do
      character_instance.set_last_speaker(other_instance)
      character_instance.set_last_spoken_to(other_instance)
      character_instance.set_last_interactor(other_instance)

      # Move character
      described_class.complete_room_transition(character_instance, north_exit)

      character_instance.reload
      expect(character_instance.last_speaker_id).to be_nil
      expect(character_instance.last_spoken_to_id).to be_nil
      expect(character_instance.last_interactor_id).to be_nil
    end

    it 'preserves combat context during movement' do
      character_instance.set_last_combat_target(enemy_instance)

      # Move character
      described_class.complete_room_transition(character_instance, north_exit)

      character_instance.reload
      expect(character_instance.last_combat_target_id).to eq(enemy_instance.id)
    end
  end

  describe 'ambiguous movement targets' do
    before do
      allow(TargetResolverService).to receive(:resolve_movement_target).and_return(
        double(type: :ambiguous, target: [room_b, staff_only_room])
      )
    end

    let(:staff_only_room) do
      Room.create(name: 'Staff Area', short_description: 'Staff only', location: location, room_type: 'standard')
    end

    it 'returns ambiguous result' do
      result = described_class.start_movement(character_instance, target: 'room')

      expect(result.success).to be false
      expect(result.message).to include('Multiple matches')
    end
  end

  describe 'unknown target type' do
    before do
      allow(TargetResolverService).to receive(:resolve_movement_target).and_return(
        double(type: :unknown, target: nil)
      )
    end

    it 'returns error' do
      result = described_class.start_movement(character_instance, target: 'mystery')

      expect(result.success).to be false
      expect(result.message).to include("Don't know how to move")
    end
  end

  # ============================================
  # Additional Edge Case Tests
  # ============================================

  describe '.start_following (edge cases)' do
    let(:user2) { create(:user) }
    let(:leader_character) { Character.create(forename: 'Leader', user: user2, is_npc: false) }
    let(:leader_instance) do
      CharacterInstance.create(
        character: leader_character,
        reality: reality,
        current_room: room_a,
        online: true,
        status: 'alive',
        level: 1,
        experience: 0,
        health: 100,
        max_health: 100,
        mana: 50,
        max_mana: 50
      )
    end

    context 'when already following someone' do
      before do
        Relationship.create(
          character: character,
          target_character: leader_character,
          status: 'accepted',
          can_follow: true
        )
        described_class.start_following(character_instance, leader_instance)
      end

      it 'returns error' do
        result = described_class.start_following(character_instance, leader_instance)

        expect(result.success).to be false
        expect(result.message).to include('Already following')
      end
    end
  end

  describe '.stop_following (edge cases)' do
    context 'when not following anyone' do
      it 'returns error' do
        character_instance.update(following_id: nil)

        result = described_class.stop_following(character_instance)

        expect(result.success).to be false
        expect(result.message).to include('Not following')
      end
    end
  end

  describe 'movement restrictions (edge cases)' do
    context 'when character is being held by unknown captor' do
      before do
        allow(character_instance).to receive(:can_move_independently?).and_return(false)
        allow(character_instance).to receive(:unconscious?).and_return(false)
        allow(character_instance).to receive(:feet_bound?).and_return(false)
        allow(character_instance).to receive(:being_moved?).and_return(true)
        allow(character_instance).to receive(:captor).and_return(nil)
      end

      it 'uses "someone" as captor name' do
        result = described_class.start_movement(character_instance, target: 'north')

        expect(result.success).to be false
        expect(result.message).to include('being held')
        expect(result.message).to include('someone')
      end
    end
  end

  describe 'exit blocked message' do
    context 'with blocked exit (wall without opening)' do
      before do
        # Make rooms indoor and add wall without opening
        room_a.update(indoors: true)
        room_b.update(indoors: true)
        create(:room_feature, room: room_a, feature_type: 'wall', direction: 'north')
      end

      it 'returns generic blocked message' do
        result = described_class.start_movement(character_instance, target: 'north')

        expect(result.success).to be false
        # When exit is blocked by wall, direction is recognized but no passable exit exists
        expect(result.message).to match(/can't go that way|can't find|no exit|blocked/i)
      end
    end
  end

  describe 'destination room not navigable' do
    # Inaccessible room at south of room_a: (0,-100)-(100,0)
    let(:inaccessible_room) do
      Room.create(
        name: 'Beyond Bounds',
        short_description: 'Inaccessible',
        location: location,
        room_type: 'standard',
        indoors: false,
        min_x: 0, max_x: 100, min_y: -100, max_y: 0
      )
    end

    before do
      inaccessible_room # Ensure created
      allow(inaccessible_room).to receive(:navigable?).and_return(false)
      allow_any_instance_of(Room).to receive(:navigable?) do |room|
        room.id != inaccessible_room.id
      end
    end

    it 'returns error about zone boundaries' do
      result = described_class.start_movement(character_instance, target: 'south')

      expect(result.success).to be false
      expect(result.message).to include('beyond the zone boundaries')
    end
  end

  describe 'approach_furniture (edge cases)' do
    context 'with furniture without x/y coordinates' do
      let(:furniture_no_coords) { double('Furniture', name: 'Mystery Object', id: 999) }

      before do
        allow(furniture_no_coords).to receive(:respond_to?).with(:x).and_return(false)
        allow(furniture_no_coords).to receive(:respond_to?).with(:y).and_return(false)
        allow(furniture_no_coords).to receive(:respond_to?).with(:z).and_return(false)
        allow(TargetResolverService).to receive(:resolve_movement_target).and_return(
          double(type: :furniture, target: furniture_no_coords)
        )
        character_instance.update(x: 50.0, y: 50.0)
      end

      it 'uses room center as default position' do
        result = described_class.start_movement(character_instance, target: 'mystery')

        # Should succeed since furniture at center, char at center = instant move
        expect(result.success).to be true
      end
    end

    context 'with furniture having nil coordinates' do
      let(:furniture_nil_coords) { double('Furniture', name: 'Nil Object', id: 998, x: nil, y: nil, z: nil) }

      before do
        allow(furniture_nil_coords).to receive(:respond_to?).with(:x).and_return(true)
        allow(furniture_nil_coords).to receive(:respond_to?).with(:y).and_return(true)
        allow(furniture_nil_coords).to receive(:respond_to?).with(:z).and_return(true)
        allow(TargetResolverService).to receive(:resolve_movement_target).and_return(
          double(type: :furniture, target: furniture_nil_coords)
        )
        character_instance.update(x: 50.0, y: 50.0)
      end

      it 'uses default values for nil coordinates' do
        result = described_class.start_movement(character_instance, target: 'nil')

        expect(result.success).to be true
      end
    end
  end

  describe 'continue_to_destination (edge cases)' do
    # Room C at (0,200)-(100,300), north of room_b
    let(:room_c) { Room.create(name: 'Room C', short_description: 'Final', location: location, room_type: 'standard', indoors: false, min_x: 0, max_x: 100, min_y: 200, max_y: 300) }

    context 'when path becomes empty mid-journey' do
      before do
        room_c # Ensure created
        character_instance.update(
          current_room: room_b,
          movement_state: 'moving',
          movement_adverb: 'walk',
          final_destination_id: room_c.id
        )
        allow(PathfindingService).to receive(:find_path).and_return([])
      end

      it 'stops movement when no path available' do
        described_class.send(:continue_to_destination, character_instance)

        character_instance.reload
        expect(character_instance.movement_state).to eq('idle')
        expect(character_instance.final_destination_id).to be_nil
      end
    end
  end

  describe 'continue_following_person (edge cases)' do
    let(:target_user) { create(:user) }
    let(:target_char) { Character.create(forename: 'Target', user: target_user, is_npc: false) }
    let(:target_instance) do
      CharacterInstance.create(
        character: target_char,
        reality: reality,
        current_room: room_b,
        online: true,
        status: 'alive',
        level: 1,
        experience: 0,
        health: 100,
        max_health: 100,
        mana: 50,
        max_mana: 50
      )
    end

    context 'when target goes offline during chase' do
      before do
        target_instance.update(online: false)
        character_instance.update(
          movement_state: 'moving',
          movement_adverb: 'walk',
          person_target_id: target_instance.id
        )
      end

      it 'stops following' do
        described_class.send(:continue_following_person, character_instance)

        character_instance.reload
        expect(character_instance.movement_state).to eq('idle')
        expect(character_instance.person_target_id).to be_nil
      end
    end

    context 'when in same room as target' do
      before do
        target_instance.update(current_room: room_a)
        character_instance.update(
          movement_state: 'moving',
          movement_adverb: 'walk',
          person_target_id: target_instance.id
        )
      end

      it 'stops following (arrived)' do
        described_class.send(:continue_following_person, character_instance)

        character_instance.reload
        expect(character_instance.movement_state).to eq('idle')
        expect(character_instance.person_target_id).to be_nil
      end
    end

    context 'when no path to target' do
      before do
        target_instance
        character_instance.update(
          movement_state: 'moving',
          movement_adverb: 'walk',
          person_target_id: target_instance.id
        )
        allow(PathfindingService).to receive(:find_path).and_return([])
      end

      it 'stops following' do
        described_class.send(:continue_following_person, character_instance)

        character_instance.reload
        expect(character_instance.movement_state).to eq('idle')
        expect(character_instance.person_target_id).to be_nil
      end
    end
  end

  describe 'move_prisoners (edge cases)' do
    let(:prisoner_user) { create(:user) }
    let(:prisoner_char) { Character.create(forename: 'Prisoner', user: prisoner_user, is_npc: false) }
    let(:carried_prisoner) do
      CharacterInstance.create(
        character: prisoner_char,
        reality: reality,
        current_room: room_a,
        online: true,
        status: 'alive',
        level: 1,
        experience: 0,
        health: 100,
        max_health: 100,
        mana: 50,
        max_mana: 50,
        being_carried_by_id: character_instance.id
      )
    end

    before do
      carried_prisoner
      allow(PrisonerService).to receive(:move_prisoners!).and_return([carried_prisoner])
      allow(carried_prisoner).to receive(:being_dragged?).and_return(false)
      allow(BroadcastService).to receive(:to_room)
      allow(BroadcastService).to receive(:to_character)
      allow(ContentConsentService).to receive(:on_room_entry)
      character_instance.update(movement_state: 'moving', movement_adverb: 'walk')
    end

    it 'broadcasts carry message for carried prisoners' do
      # Add a viewer in the destination room to receive personalized broadcast
      viewer_user = create(:user)
      viewer_char = Character.create(forename: 'Viewer', user: viewer_user, is_npc: false)
      viewer_instance = CharacterInstance.create(
        character: viewer_char, reality: reality, current_room: room_b,
        online: true, status: 'alive', level: 1, experience: 0,
        health: 100, max_health: 100, mana: 50, max_mana: 50
      )

      described_class.complete_room_transition(character_instance, north_exit)

      expect(BroadcastService).to have_received(:to_character).with(
        viewer_instance,
        include('carries'),
        any_args
      )
    end

    it 'sends carried message to prisoner' do
      described_class.complete_room_transition(character_instance, north_exit)

      expect(BroadcastService).to have_received(:to_character).with(
        carried_prisoner,
        include('carried along'),
        anything
      )
    end
  end

  describe 'update_room_players_set' do
    context 'when REDIS_POOL is not defined' do
      before do
        allow(described_class).to receive(:defined?).with(:REDIS_POOL).and_return(false)
      end

      it 'silently returns without error' do
        expect do
          described_class.send(:update_room_players_set, character_instance, room_a.id, room_b.id)
        end.not_to raise_error
      end
    end

    context 'when Redis operation fails' do
      before do
        # Define a mock REDIS_POOL that raises an error
        stub_const('REDIS_POOL', double('RedisPool'))
        allow(REDIS_POOL).to receive(:with).and_raise(StandardError, 'Redis connection failed')
      end

      it 'logs warning and continues' do
        expect do
          described_class.send(:update_room_players_set, character_instance, room_a.id, room_b.id)
        end.not_to raise_error
      end
    end
  end

  describe 'pathfinding with first exit blocked' do
    # Room C at (0,200)-(100,300), north of room_b
    let(:room_c) { Room.create(name: 'Room C', short_description: 'Far', location: location, room_type: 'standard', indoors: false, min_x: 0, max_x: 100, min_y: 200, max_y: 300) }
    let(:bc_exit) { MovementService::SpatialExit.new(to_room: room_c, direction: 'north', from_room: room_b) }

    before do
      room_c # Ensure created
      # Block the north exit by making rooms indoor with wall and closed door
      room_a.update(indoors: true)
      room_b.update(indoors: true)
      create(:room_feature, room: room_a, feature_type: 'wall', direction: 'north')
      create(:room_feature, room: room_a, feature_type: 'door', direction: 'north', is_open: false)

      allow(TargetResolverService).to receive(:resolve_movement_target).and_return(
        double(type: :room, room: room_c, target: room_c)
      )
      allow(PathfindingService).to receive(:find_path).and_return([north_exit, bc_exit])
    end

    it 'returns error when first exit is blocked' do
      result = described_class.start_movement(character_instance, target: room_c.name)

      expect(result.success).to be false
      expect(result.message).to match(/blocked|can't go|no exit/i)
    end
  end

  describe 'TargetResolverService error handling' do
    before do
      allow(TargetResolverService).to receive(:resolve_movement_target).and_return(
        double(type: :error, error: 'Could not find target')
      )
    end

    it 'returns error from resolver' do
      result = described_class.start_movement(character_instance, target: 'nonexistent')

      expect(result.success).to be false
      expect(result.message).to include('Could not find target')
    end
  end

  describe '.revoke_follow_permission (edge cases)' do
    let(:user2) { create(:user) }
    let(:leader_character) { Character.create(forename: 'Leader', user: user2, is_npc: false) }
    let(:leader_instance) do
      CharacterInstance.create(
        character: leader_character,
        reality: reality,
        current_room: room_a,
        online: true,
        status: 'alive',
        level: 1,
        experience: 0,
        health: 100,
        max_health: 100,
        mana: 50,
        max_mana: 50
      )
    end

    context 'when no existing relationship' do
      it 'still succeeds without error' do
        result = described_class.revoke_follow_permission(leader_instance, character_instance)

        expect(result.success).to be true
      end
    end
  end
end
