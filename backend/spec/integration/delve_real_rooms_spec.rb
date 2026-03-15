# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Delve Real Rooms Integration', type: :integration do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area) }
  let(:room) { create(:room, location: location, name: 'Town Square', room_type: 'standard') }
  let(:reality) { create(:reality) }

  let(:user) { create(:user) }
  let(:character) { create(:character, user: user, forename: 'Dungeon', surname: 'Crawler') }
  let(:character_instance) do
    create(:character_instance,
           character: character,
           reality: reality,
           current_room: room,
           online: true,
           status: 'alive')
  end

  # Ensure pool infrastructure exists
  let!(:pool_location) do
    Location.find_or_create(name: 'Room Pool') do |l|
      l.zone_id = area.id
      l.location_type = 'building'
    end
  end

  let!(:delve_location) do
    Location.find_or_create(name: 'Delve Pool') do |l|
      l.zone_id = area.id
      l.world_id = world.id
      l.location_type = 'building'
    end
  end

  let!(:delve_room_template) do
    RoomTemplate.find_or_create(template_type: 'delve_room') do |t|
      t.name = 'Delve Room'
      t.category = 'delve'
      t.room_type = 'dungeon'
      t.short_description = 'A dark dungeon chamber.'
      t.long_description = 'The walls are rough-hewn stone, slick with moisture.'
      t.width = 30
      t.length = 30
      t.height = 10
      t.active = true
      t.universe_id = universe.id
    end
  end

  subject(:command) { Commands::Delve::DelveCommand.new(character_instance) }

  before do
    # Stub the SVG map service since it relies on complex rendering
    allow(DelveMapPanelService).to receive(:render).and_return({ svg: nil, metadata: {} })
  end

  def execute_command(args = nil)
    input = args.nil? ? 'delve' : "delve #{args}"
    command.execute(input)
  end

  describe 'full delve lifecycle with real rooms' do
    it 'creates real Room records when entering a delve' do
      original_room_id = character_instance.current_room_id
      original_room_count = Room.count

      result = execute_command('enter Test Dungeon')

      expect(result[:success]).to be true
      expect(result[:message]).to include('You enter Test Dungeon')

      # Verify new rooms were created
      expect(Room.count).to be > original_room_count

      # Find the delve and its rooms
      delve = Delve.order(:id).last
      expect(delve).not_to be_nil
      expect(delve.name).to eq('Test Dungeon')

      delve_rooms = DelveRoom.where(delve_id: delve.id).all
      expect(delve_rooms).not_to be_empty

      # Every delve room should have a real Room record linked
      rooms_with_real = delve_rooms.select { |dr| !dr.room_id.nil? }
      expect(rooms_with_real.length).to eq(delve_rooms.length)
    end

    it 'sets character current_room_id to real entrance room' do
      original_room_id = character_instance.current_room_id

      result = execute_command('enter Test Dungeon')
      expect(result[:success]).to be true

      # Find the entrance
      delve = Delve.order(:id).last
      entrance = delve.entrance_room(1)
      expect(entrance).not_to be_nil
      expect(entrance.room_id).not_to be_nil

      # Character should now be in the real room
      character_instance.reload
      expect(character_instance.current_room_id).to eq(entrance.room_id)
      expect(character_instance.current_room_id).not_to eq(original_room_id)
    end

    it 'stores pre_delve_room_id on the participant' do
      original_room_id = character_instance.current_room_id

      result = execute_command('enter Test Dungeon')
      expect(result[:success]).to be true

      participant = DelveParticipant.where(character_instance_id: character_instance.id, status: 'active').first
      expect(participant).not_to be_nil
      expect(participant.pre_delve_room_id).to eq(original_room_id)
    end

    it 'creates RoomFeature records (walls and doors) on delve rooms' do
      result = execute_command('enter Test Dungeon')
      expect(result[:success]).to be true

      delve = Delve.order(:id).last
      delve_rooms = DelveRoom.where(delve_id: delve.id).all

      # At least some rooms should have features
      rooms_with_features = delve_rooms.count do |dr|
        next false unless dr.room_id

        RoomFeature.where(room_id: dr.room_id).count > 0
      end

      expect(rooms_with_features).to be > 0

      # Check that features include walls (every room should have 4 walls)
      sample_room = delve_rooms.find { |dr| dr.room_id && RoomFeature.where(room_id: dr.room_id).count > 0 }
      if sample_room
        walls = RoomFeature.where(room_id: sample_room.room_id, feature_type: 'wall').all
        expect(walls.length).to eq(4), "Expected 4 walls, got #{walls.length}"

        # Check that wall directions cover all cardinals
        wall_dirs = walls.map(&:direction).sort
        expect(wall_dirs).to eq(%w[east north south west])
      end
    end

    it 'creates temporary rooms with correct spatial bounds' do
      result = execute_command('enter Test Dungeon')
      expect(result[:success]).to be true

      delve = Delve.order(:id).last
      delve_rooms = DelveRoom.where(delve_id: delve.id).all

      delve_rooms.each do |dr|
        next unless dr.room_id

        real_room = Room[dr.room_id]
        expect(real_room).not_to be_nil
        expect(real_room.is_temporary).to be true

        # Check spatial bounds are within grid cell (30ft per cell, rooms may be centered)
        cell_min_x = dr.grid_x * 30.0
        cell_min_y = dr.grid_y * 30.0
        expect(real_room.min_x.to_f).to be >= cell_min_x
        expect(real_room.min_y.to_f).to be >= cell_min_y
        expect(real_room.max_x.to_f).to be <= (cell_min_x + 30.0)
        expect(real_room.max_y.to_f).to be <= (cell_min_y + 30.0)
        room_w = (real_room.max_x - real_room.min_x).to_f
        room_h = (real_room.max_y - real_room.min_y).to_f
        expect(room_w).to be > 0
        expect(room_h).to be > 0
      end
    end
  end

  describe 'flee returns character to original room' do
    it 'restores character to pre-delve room on flee' do
      original_room_id = character_instance.current_room_id

      # Enter
      enter_result = execute_command('enter Test Dungeon')
      expect(enter_result[:success]).to be true

      character_instance.reload
      expect(character_instance.current_room_id).not_to eq(original_room_id)

      # Flee
      flee_result = execute_command('flee')
      expect(flee_result[:success]).to be true
      expect(flee_result[:message]).to include('flee')

      # Character should be back in original room
      character_instance.reload
      expect(character_instance.current_room_id).to eq(original_room_id)
    end

    it 'releases delve rooms from pool on flee' do
      enter_result = execute_command('enter Test Dungeon')
      expect(enter_result[:success]).to be true

      delve = Delve.order(:id).last
      delve_rooms = DelveRoom.where(delve_id: delve.id).all
      real_room_ids = delve_rooms.map(&:room_id).compact

      # Verify rooms exist and are in_use before flee
      expect(real_room_ids).not_to be_empty
      in_use_rooms = Room.where(id: real_room_ids, pool_status: 'in_use').all
      expect(in_use_rooms.length).to be > 0

      # Flee
      flee_result = execute_command('flee')
      expect(flee_result[:success]).to be true

      # Rooms should be released back to pool (available)
      Room.where(id: real_room_ids).each do |r|
        r.reload
        expect(r.pool_status).to eq('available'),
          "Room #{r.id} should be available after flee, but was #{r.pool_status}"
      end
    end

    it 'clears RoomFeature records on flee' do
      enter_result = execute_command('enter Test Dungeon')
      expect(enter_result[:success]).to be true

      delve = Delve.order(:id).last
      delve_rooms = DelveRoom.where(delve_id: delve.id).all
      real_room_ids = delve_rooms.map(&:room_id).compact

      # Verify features exist before flee
      total_features_before = RoomFeature.where(room_id: real_room_ids).count
      expect(total_features_before).to be > 0

      # Flee
      flee_result = execute_command('flee')
      expect(flee_result[:success]).to be true

      # Features should be cleared
      total_features_after = RoomFeature.where(room_id: real_room_ids).count
      expect(total_features_after).to eq(0)
    end
  end

  describe 'movement updates character real room' do
    it 'updates character current_room_id when moving between delve rooms' do
      enter_result = execute_command('enter Test Dungeon')
      expect(enter_result[:success]).to be true

      delve = Delve.order(:id).last
      participant = DelveParticipant.where(
        character_instance_id: character_instance.id,
        status: 'active'
      ).first

      entrance = participant.current_room
      expect(entrance).not_to be_nil

      # Find a valid exit direction from the entrance
      exits = entrance.available_exits
      movable_dir = exits.find { |d| %w[north south east west].include?(d) }

      if movable_dir
        room_before_move = character_instance.reload.current_room_id

        move_result = execute_command(movable_dir)

        if move_result[:success]
          # Find the new delve room
          participant.reload
          new_delve_room = participant.current_room
          expect(new_delve_room).not_to be_nil
          expect(new_delve_room.id).not_to eq(entrance.id)

          # Character's real room should have changed
          character_instance.reload
          if new_delve_room.room_id
            expect(character_instance.current_room_id).to eq(new_delve_room.room_id)
            expect(character_instance.current_room_id).not_to eq(room_before_move)
          end
        end
      end
    end
  end

  describe 'cross-delve spatial isolation' do
    it 'rooms from different delves at the same grid position are not adjacent' do
      # Create two delves that will have rooms at overlapping grid coordinates
      result1 = execute_command('enter Dungeon Alpha')
      expect(result1[:success]).to be true
      delve1 = Delve.order(:id).last

      # Create a second character for the second delve
      user2 = create(:user)
      char2 = create(:character, user: user2, forename: 'Second', surname: 'Delver')
      ci2 = create(:character_instance,
                   character: char2,
                   reality: reality,
                   current_room: room,
                   online: true,
                   status: 'alive')
      cmd2 = Commands::Delve::DelveCommand.new(ci2)
      result2 = cmd2.execute('delve enter Dungeon Beta')
      expect(result2[:success]).to be true
      delve2 = Delve.order(:id).last

      expect(delve1.id).not_to eq(delve2.id)

      # Get rooms from each delve
      rooms1 = Room.where(temp_delve_id: delve1.id, is_temporary: true).all
      rooms2 = Room.where(temp_delve_id: delve2.id, is_temporary: true).all

      expect(rooms1).not_to be_empty
      expect(rooms2).not_to be_empty

      # Verify spatial groups are different
      groups1 = rooms1.map(&:spatial_group_id).uniq
      groups2 = rooms2.map(&:spatial_group_id).uniq
      expect(groups1).to eq(["delve:#{delve1.id}"])
      expect(groups2).to eq(["delve:#{delve2.id}"])

      # Verify adjacency from a delve1 room never returns delve2 rooms
      sample_room = rooms1.first
      adjacent = RoomAdjacencyService.compute_adjacent_rooms(sample_room)
      all_adjacent_ids = adjacent.values.flatten.map(&:id)

      rooms2_ids = rooms2.map(&:id)
      expect(all_adjacent_ids & rooms2_ids).to be_empty,
        'Rooms from different delves should never be adjacent'
    end
  end

  describe ':with_real_room factory trait' do
    it 'creates a delve_room with an associated real Room' do
      delve = create(:delve, grid_width: 15, grid_height: 15)
      delve_room = create(:delve_room, :with_real_room, delve: delve, grid_x: 2, grid_y: 3)

      expect(delve_room.room_id).not_to be_nil

      real_room = Room[delve_room.room_id]
      expect(real_room).not_to be_nil
      expect(real_room.is_temporary).to be true
      expect(real_room.pool_status).to eq('in_use')
      expect(real_room.room_type).to eq('dungeon')
      expect(real_room.name).to include('Dungeon')
      expect(real_room.name).to include('[2,3]')
    end

    it 'sets correct spatial bounds based on grid position' do
      delve = create(:delve, grid_width: 15, grid_height: 15)
      delve_room = create(:delve_room, :with_real_room, delve: delve, grid_x: 5, grid_y: 7)

      real_room = Room[delve_room.room_id]
      expect(real_room.min_x.to_f).to eq(150.0)  # 5 * 30.0
      expect(real_room.max_x.to_f).to eq(180.0)  # 5 * 30.0 + 30.0
      expect(real_room.min_y.to_f).to eq(210.0)  # 7 * 30.0
      expect(real_room.max_y.to_f).to eq(240.0)  # 7 * 30.0 + 30.0
    end
  end
end
