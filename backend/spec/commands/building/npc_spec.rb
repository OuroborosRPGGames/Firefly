# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Building::Npc, type: :command do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area, name: 'Test Location') }
  let(:room) { create(:room, location: location, name: 'Guard Post') }

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
    allow(character_instance).to receive(:creator_mode?).and_return(true)
    allow(user).to receive(:has_permission?).with('can_manage_npcs').and_return(false)
    allow(user).to receive(:admin?).and_return(false)
    allow(character).to receive(:staff?).and_return(false)
    allow(character).to receive(:admin?).and_return(false)

    # Stub NpcSchedule weekday patterns
    stub_const('NpcSchedule::WEEKDAY_PATTERNS', %w[all weekdays weekends])
  end

  # Use shared example for command metadata
  it_behaves_like "command metadata", 'npc', :building, ['npclocation', 'npcloc']

  describe 'command registration' do
    it 'is registered in the command registry' do
      expect(Commands::Base::Registry.commands['npc']).to eq(described_class)
    end
  end

  describe '#execute' do
    context 'when user lacks building permission' do
      before do
        allow(character_instance).to receive(:creator_mode?).and_return(false)
      end

      it 'returns an error' do
        result = subject.execute('npc add')

        expect(result[:success]).to be false
        expect(result[:message]).to include('building permissions')
      end
    end

    context 'with no arguments (help)' do
      it 'shows help message' do
        result = subject.execute('npc')

        expect(result[:success]).to be true
        expect(result[:message]).to include('NPC Management Commands')
        expect(result[:message]).to include('npc location add')
        expect(result[:message]).to include('npc location save')
        expect(result[:message]).to include('npc location list')
        expect(result[:message]).to include('Shortcuts')
      end
    end

    context 'with help subcommand' do
      it 'shows help message' do
        result = subject.execute('npc help')

        expect(result[:success]).to be true
        expect(result[:message]).to include('NPC Management Commands')
      end
    end

    context 'with unknown subcommand' do
      it 'returns an error' do
        result = subject.execute('npc unknown')

        expect(result[:success]).to be false
        expect(result[:message]).to include('Unknown subcommand')
      end
    end
  end

  # ========================================
  # Location Add Tests
  # ========================================

  describe 'npc add' do
    context 'when user has no archetypes' do
      before do
        allow(NpcArchetype).to receive(:where).and_return(double(order: double(all: [])))
      end

      it 'returns an error message' do
        result = subject.execute('npc add')

        expect(result[:success]).to be false
        expect(result[:message]).to include('no NPC archetypes')
      end
    end

    context 'when user has archetypes' do
      let(:archetype1) { double('NpcArchetype', id: 1, name: 'Guard', behavior_pattern: 'patrol', characters_dataset: double(count: 5)) }
      let(:archetype2) { double('NpcArchetype', id: 2, name: 'Merchant', behavior_pattern: 'stationary', characters_dataset: double(count: 2)) }

      before do
        allow(NpcArchetype).to receive(:where).and_return(double(order: double(all: [archetype1, archetype2])))
      end

      it 'creates a quickmenu with available archetypes' do
        expect(subject).to receive(:create_quickmenu).and_return({ success: true, message: 'Test' })

        subject.execute('npc add')
      end
    end

    context 'when specifying an NPC name directly' do
      let(:archetype) { double('NpcArchetype', id: 1, name: 'Guard') }

      before do
        allow(NpcArchetype).to receive(:where).and_return(double(order: double(all: [archetype])))
      end

      it 'shows schedule form when NPC found' do
        expect(subject).to receive(:show_schedule_form).with(archetype, room).and_return({ success: true, message: 'Test' })

        subject.execute('npc add Guard')
      end

      it 'returns error when NPC not found' do
        allow(NpcArchetype).to receive(:where).and_return(double(order: double(all: [])))

        result = subject.execute('npc add NonExistent')

        expect(result[:success]).to be false
        expect(result[:message]).to include('not found')
      end
    end

    context 'via npc location add' do
      let(:archetype) { double('NpcArchetype', id: 1, name: 'Guard', behavior_pattern: 'patrol', characters_dataset: double(count: 3)) }

      before do
        allow(NpcArchetype).to receive(:where).and_return(double(order: double(all: [archetype])))
      end

      it 'works via location subcommand' do
        expect(subject).to receive(:create_quickmenu).and_return({ success: true, message: 'Test' })

        subject.execute('npc location add')
      end
    end

    context 'when user is admin' do
      before do
        allow(user).to receive(:has_permission?).with('can_manage_npcs').and_return(true)
      end

      it 'shows all archetypes' do
        expect(NpcArchetype).to receive(:order).with(:name).and_return(double(all: []))

        subject.execute('npc add')
      end
    end

    context 'when user has can_manage_npcs permission' do
      before do
        allow(user).to receive(:has_permission?).with('can_manage_npcs').and_return(true)
      end

      it 'shows all archetypes' do
        expect(NpcArchetype).to receive(:order).with(:name).and_return(double(all: []))

        subject.execute('npc add')
      end
    end
  end

  # ========================================
  # Location Save Tests
  # ========================================

  describe 'npc save' do
    context 'with no name provided' do
      it 'returns an error' do
        result = subject.execute('npc save')

        expect(result[:success]).to be false
        expect(result[:message]).to include('Please provide a name')
      end
    end

    context 'when name already exists' do
      before do
        allow(NpcSpawnLocation).to receive(:first).and_return(double('existing location'))
      end

      it 'returns an error' do
        result = subject.execute('npc save Guard Post')

        expect(result[:success]).to be false
        expect(result[:message]).to include('already have a location')
      end
    end

    context 'when name is unique' do
      let(:new_location) { double('NpcSpawnLocation', id: 123) }

      before do
        allow(NpcSpawnLocation).to receive(:first).and_return(nil)
        allow(NpcSpawnLocation).to receive(:create).and_return(new_location)
      end

      it 'creates the location' do
        result = subject.execute('npc save Guard Post')

        expect(result[:success]).to be true
        expect(result[:message]).to include("Saved 'Guard Post'")
        expect(NpcSpawnLocation).to have_received(:create).with(
          hash_including(user_id: user.id, room_id: room.id, name: 'Guard Post')
        )
      end

      it 'includes structured data' do
        result = subject.execute('npc save Guard Post')

        expect(result[:data][:action]).to eq('location_saved')
        expect(result[:data][:location_id]).to eq(123)
        expect(result[:data][:room_id]).to eq(room.id)
      end
    end

    context 'when validation fails' do
      before do
        allow(NpcSpawnLocation).to receive(:first).and_return(nil)
        allow(NpcSpawnLocation).to receive(:create).and_raise(
          Sequel::ValidationFailed.new(double(full_messages: ['Name is too long']))
        )
      end

      it 'returns an error' do
        result = subject.execute('npc save ' + 'x' * 500)

        expect(result[:success]).to be false
        expect(result[:message]).to include('Failed to save location')
      end
    end

    context 'via npc location save' do
      let(:new_location) { double('NpcSpawnLocation', id: 456) }

      before do
        allow(NpcSpawnLocation).to receive(:first).and_return(nil)
        allow(NpcSpawnLocation).to receive(:create).and_return(new_location)
      end

      it 'works via location subcommand' do
        result = subject.execute('npc location save Main Gate')

        expect(result[:success]).to be true
        expect(result[:message]).to include("Saved 'Main Gate'")
      end
    end
  end

  # ========================================
  # Location List Tests
  # ========================================

  describe 'npc list' do
    context 'with no saved locations' do
      before do
        allow(NpcSpawnLocation).to receive(:for_user).and_return(double(eager: double(all: [])))
      end

      it 'shows empty library message' do
        result = subject.execute('npc list')

        expect(result[:success]).to be true
        expect(result[:message]).to include('library is empty')
      end
    end

    context 'with saved locations' do
      let(:room1) { double('Room', name: 'Main Gate', location: double(name: 'Town')) }
      let(:room2) { double('Room', name: 'Market Stall', location: nil) }

      let(:loc1) do
        double('NpcSpawnLocation',
               id: 1,
               name: 'Gate Guard Spot',
               room: room1,
               room_id: 10,
               notes: 'Good visibility')
      end
      let(:loc2) do
        double('NpcSpawnLocation',
               id: 2,
               name: 'Merchant Position',
               room: room2,
               room_id: 20,
               notes: nil)
      end

      before do
        allow(NpcSpawnLocation).to receive(:for_user).and_return(double(eager: double(all: [loc1, loc2])))
      end

      it 'lists all locations' do
        result = subject.execute('npc list')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Gate Guard Spot')
        expect(result[:message]).to include('Main Gate')
        expect(result[:message]).to include('(Town)')
        expect(result[:message]).to include('Good visibility')
        expect(result[:message]).to include('Merchant Position')
        expect(result[:message]).to include('Market Stall')
        expect(result[:message]).to include('Total: 2')
      end

      it 'includes structured data' do
        result = subject.execute('npc list')

        expect(result[:data][:action]).to eq('list_locations')
        expect(result[:data][:count]).to eq(2)
        expect(result[:data][:locations]).to be_an(Array)
        expect(result[:data][:locations].length).to eq(2)
      end
    end

    context 'via npc location list' do
      before do
        allow(NpcSpawnLocation).to receive(:for_user).and_return(double(eager: double(all: [])))
      end

      it 'works via location subcommand' do
        result = subject.execute('location list')

        expect(result[:success]).to be true
      end
    end

    context 'via npc ls shortcut' do
      before do
        allow(NpcSpawnLocation).to receive(:for_user).and_return(double(eager: double(all: [])))
      end

      it 'works via ls alias' do
        result = subject.execute('ls')

        expect(result[:success]).to be true
      end
    end
  end

  # ========================================
  # Location Delete Tests
  # ========================================

  describe 'npc del' do
    context 'with no name provided' do
      it 'returns an error' do
        result = subject.execute('npc del')

        expect(result[:success]).to be false
        expect(result[:message]).to include('specify which location')
      end
    end

    context 'when location not found' do
      before do
        allow(NpcSpawnLocation).to receive(:find_by_name).and_return(nil)
      end

      it 'returns an error' do
        result = subject.execute('npc del NonExistent')

        expect(result[:success]).to be false
        expect(result[:message]).to include('No location named')
      end
    end

    context 'when location exists' do
      let(:loc) do
        double('NpcSpawnLocation',
               name: 'Guard Post',
               room: double(name: 'Main Gate'))
      end

      before do
        allow(NpcSpawnLocation).to receive(:find_by_name).and_return(loc)
        allow(loc).to receive(:destroy)
      end

      it 'deletes the location' do
        result = subject.execute('npc del Guard Post')

        expect(result[:success]).to be true
        expect(result[:message]).to include("Removed 'Guard Post'")
        expect(result[:message]).to include('Main Gate')
        expect(loc).to have_received(:destroy)
      end

      it 'includes structured data' do
        result = subject.execute('npc del Guard Post')

        expect(result[:data][:action]).to eq('location_deleted')
        expect(result[:data][:name]).to eq('Guard Post')
      end
    end

    context 'when room is nil' do
      let(:loc) do
        double('NpcSpawnLocation', name: 'Orphaned', room: nil)
      end

      before do
        allow(NpcSpawnLocation).to receive(:find_by_name).and_return(loc)
        allow(loc).to receive(:destroy)
      end

      it 'handles nil room gracefully' do
        result = subject.execute('npc del Orphaned')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Unknown')
      end
    end

    context 'via npc location del' do
      let(:loc) do
        double('NpcSpawnLocation', name: 'Test', room: double(name: 'Room'))
      end

      before do
        allow(NpcSpawnLocation).to receive(:find_by_name).and_return(loc)
        allow(loc).to receive(:destroy)
      end

      it 'works via location subcommand' do
        result = subject.execute('npc location del Test')

        expect(result[:success]).to be true
      end
    end

    context 'via npc delete alias' do
      let(:loc) do
        double('NpcSpawnLocation', name: 'Test', room: double(name: 'Room'))
      end

      before do
        allow(NpcSpawnLocation).to receive(:find_by_name).and_return(loc)
        allow(loc).to receive(:destroy)
      end

      it 'works via delete alias' do
        result = subject.execute('npc delete Test')

        expect(result[:success]).to be true
      end
    end

    context 'via npc remove alias' do
      let(:loc) do
        double('NpcSpawnLocation', name: 'Test', room: double(name: 'Room'))
      end

      before do
        allow(NpcSpawnLocation).to receive(:find_by_name).and_return(loc)
        allow(loc).to receive(:destroy)
      end

      it 'works via remove alias' do
        result = subject.execute('npc remove Test')

        expect(result[:success]).to be true
      end
    end
  end

  # ========================================
  # Form Response Tests
  # ========================================

  describe '#handle_form_response' do
    let(:archetype) do
      double('NpcArchetype',
             id: 1,
             name: 'Town Guard',
             characters: double(first: nil),
             create_unique_npc: double(id: 100))
    end
    let(:schedule) { double('NpcSchedule', id: 200) }

    let(:form_data) do
      {
        'activity' => 'patrolling the area',
        'start_hour' => '8',
        'end_hour' => '18',
        'weekdays' => 'weekdays',
        'probability' => '80',
        'save_to_library' => 'false',
        'library_name' => ''
      }
    end

    let(:context) do
      {
        'archetype_id' => archetype.id,
        'room_id' => room.id
      }
    end

    before do
      allow(NpcArchetype).to receive(:[]).with(archetype.id).and_return(archetype)
      allow(Room).to receive(:[]).with(room.id).and_return(room)
      allow(NpcSchedule).to receive(:create).and_return(schedule)
    end

    it 'creates an NPC schedule' do
      result = subject.send(:handle_form_response,form_data, context)

      expect(result[:success]).to be true
      expect(result[:message]).to include('Schedule created')
      expect(result[:message]).to include('Town Guard')
      expect(NpcSchedule).to have_received(:create).with(
        hash_including(
          room_id: room.id,
          activity: 'patrolling the area',
          start_hour: 8,
          end_hour: 18,
          weekdays: 'weekdays',
          probability: 80
        )
      )
    end

    it 'includes structured data' do
      result = subject.send(:handle_form_response,form_data, context)

      expect(result[:data][:action]).to eq('npc_schedule_created')
      expect(result[:data][:schedule_id]).to eq(200)
      expect(result[:data][:archetype_id]).to eq(1)
    end

    context 'when archetype has existing NPC' do
      let(:existing_npc) { double('Character', id: 50) }

      before do
        allow(archetype).to receive(:characters).and_return(double(first: existing_npc))
      end

      it 'uses existing NPC' do
        result = subject.send(:handle_form_response,form_data, context)

        expect(result[:success]).to be true
        expect(NpcSchedule).to have_received(:create).with(
          hash_including(character_id: 50)
        )
      end
    end

    context 'when save_to_library is true' do
      let(:library_form_data) do
        form_data.merge(
          'save_to_library' => 'true',
          'library_name' => 'Guard Station'
        )
      end

      before do
        allow(NpcSpawnLocation).to receive(:create).and_return(double)
      end

      it 'saves location to library' do
        subject.send(:handle_form_response,library_form_data, context)

        expect(NpcSpawnLocation).to have_received(:create).with(
          hash_including(name: 'Guard Station', room_id: room.id)
        )
      end
    end

    context 'when save_to_library is true but name empty' do
      let(:empty_name_form) do
        form_data.merge(
          'save_to_library' => 'true',
          'library_name' => ''
        )
      end

      it 'does not save to library' do
        expect(NpcSpawnLocation).not_to receive(:create)

        subject.send(:handle_form_response,empty_name_form, context)
      end
    end

    context 'when archetype is invalid' do
      before do
        allow(NpcArchetype).to receive(:[]).with(archetype.id).and_return(nil)
      end

      it 'returns an error' do
        result = subject.send(:handle_form_response,form_data, context)

        expect(result[:success]).to be false
        expect(result[:message]).to include('Invalid archetype')
      end
    end

    context 'when room is invalid' do
      before do
        allow(Room).to receive(:[]).with(room.id).and_return(nil)
      end

      it 'returns an error' do
        result = subject.send(:handle_form_response,form_data, context)

        expect(result[:success]).to be false
        expect(result[:message]).to include('Invalid')
      end
    end

    context 'with default values' do
      let(:minimal_form_data) do
        {
          'activity' => nil,
          'start_hour' => nil,
          'end_hour' => nil,
          'weekdays' => nil,
          'probability' => nil
        }
      end

      it 'uses default values' do
        subject.send(:handle_form_response,minimal_form_data, context)

        expect(NpcSchedule).to have_received(:create).with(
          hash_including(
            start_hour: 0,
            end_hour: 24,
            weekdays: 'all',
            probability: 100
          )
        )
      end
    end
  end

  # ========================================
  # Location Subcommand Routing Tests
  # ========================================

  describe 'location subcommand routing' do
    context 'with unknown action' do
      it 'returns an error' do
        result = subject.execute('npc location invalid')

        expect(result[:success]).to be false
        expect(result[:message]).to include('Unknown location subcommand')
      end
    end

    context 'with create alias' do
      before do
        allow(NpcArchetype).to receive(:where).and_return(double(order: double(all: [])))
      end

      it 'routes to add' do
        result = subject.execute('npc location create')

        expect(result[:success]).to be false
        expect(result[:message]).to include('no NPC archetypes')
      end
    end
  end

  # ========================================
  # Edge Cases
  # ========================================

  describe 'edge cases' do
    context 'with extra whitespace' do
      before do
        allow(NpcSpawnLocation).to receive(:for_user).and_return(double(eager: double(all: [])))
      end

      it 'handles extra whitespace' do
        result = subject.execute('  list  ')

        expect(result[:success]).to be true
      end
    end

    context 'with mixed case' do
      before do
        allow(NpcSpawnLocation).to receive(:for_user).and_return(double(eager: double(all: [])))
      end

      it 'handles uppercase' do
        result = subject.execute('LIST')

        expect(result[:success]).to be true
      end
    end

    context 'with name containing spaces' do
      let(:new_location) { double('NpcSpawnLocation', id: 789) }

      before do
        allow(NpcSpawnLocation).to receive(:first).and_return(nil)
        allow(NpcSpawnLocation).to receive(:create).and_return(new_location)
      end

      it 'handles names with spaces' do
        result = subject.execute('npc save Main Guard Post')

        expect(result[:success]).to be true
        expect(NpcSpawnLocation).to have_received(:create).with(
          hash_including(name: 'Main Guard Post')
        )
      end
    end
  end

  # ========================================
  # Show Schedule Form Tests
  # ========================================

  describe '#show_schedule_form' do
    let(:archetype) { double('NpcArchetype', id: 1, name: 'Guard') }

    it 'creates a form with correct fields' do
      expect(subject).to receive(:create_form) do |instance, title, fields, options|
        expect(title).to include('Guard')
        expect(title).to include(room.name)
        expect(fields.map { |f| f[:name] }).to include(
          'activity', 'start_hour', 'end_hour', 'weekdays',
          'probability', 'save_to_library', 'library_name'
        )
        expect(options[:context][:archetype_id]).to eq(1)
        expect(options[:context][:room_id]).to eq(room.id)
      end

      subject.send(:show_schedule_form, archetype, room)
    end
  end
end
