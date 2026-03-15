# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Timeline::TimelineCmd do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area) }
  let(:room) { create(:room, location: location) }
  let(:reality) { create(:reality) }

  let(:user) { create(:user) }
  let(:character) { create(:character, user: user, forename: 'Time', surname: 'Traveler') }
  let(:character_instance) do
    create(:character_instance,
           character: character,
           reality: reality,
           current_room: room,
           online: true,
           status: 'alive')
  end

  subject(:command) { described_class.new(character_instance) }

  def execute_command(args = nil)
    input = args.nil? ? 'timeline' : "timeline #{args}"
    command.execute(input)
  end

  describe 'command registration' do
    it 'is registered in the command registry' do
      expect(Commands::Base::Registry.commands['timeline']).to eq(described_class)
    end

    it 'has alias timelines' do
      cmd_class, _ = Commands::Base::Registry.find_command('timelines')
      expect(cmd_class).to eq(described_class)
    end

    it 'has alias tl' do
      cmd_class, _ = Commands::Base::Registry.find_command('tl')
      expect(cmd_class).to eq(described_class)
    end

    it 'has alias snapshot' do
      cmd_class, _ = Commands::Base::Registry.find_command('snapshot')
      expect(cmd_class).to eq(described_class)
    end

    it 'has alias snap' do
      cmd_class, _ = Commands::Base::Registry.find_command('snap')
      expect(cmd_class).to eq(described_class)
    end

    it 'has correct category' do
      expect(described_class.category).to eq(:info)
    end
  end

  describe 'no arguments - main menu' do
    before do
      allow(character_instance).to receive(:in_past_timeline?).and_return(false)
      allow(OutputHelper).to receive(:store_agent_interaction)
    end

    it 'returns a quickmenu' do
      result = execute_command

      expect(result[:success]).to be true
      expect(result[:type]).to eq(:quickmenu)
    end

    it 'has correct prompt' do
      result = execute_command

      expect(result[:prompt]).to eq('Timeline Management')
    end

    it 'includes standard options' do
      result = execute_command

      options = result[:options]
      keys = options.map { |o| o[:key] }

      expect(keys).to include('view')
      expect(keys).to include('enter')
      expect(keys).to include('create')
      expect(keys).to include('delete')
      expect(keys).to include('q')
    end

    it 'does not include leave option when not in past timeline' do
      result = execute_command

      options = result[:options]
      keys = options.map { |o| o[:key] }

      expect(keys).not_to include('leave')
      expect(keys).not_to include('info')
    end

    context 'when in a past timeline' do
      before do
        allow(character_instance).to receive(:in_past_timeline?).and_return(true)
      end

      it 'includes leave and info options' do
        result = execute_command

        options = result[:options]
        keys = options.map { |o| o[:key] }

        expect(keys).to include('leave')
        expect(keys).to include('info')
      end
    end

    it 'stores interaction for agent access' do
      expect(OutputHelper).to receive(:store_agent_interaction).with(
        character_instance,
        anything,
        hash_including(type: 'quickmenu', prompt: 'Timeline Management')
      )

      execute_command
    end

    it 'includes interaction_id' do
      result = execute_command

      expect(result[:interaction_id]).not_to be_nil
    end

    it 'includes context with command and stage' do
      result = execute_command

      expect(result[:context][:command]).to eq('timeline')
      expect(result[:context][:stage]).to eq('main_menu')
    end
  end

  describe 'with snapshot name argument - quick enter' do
    let(:snapshot) do
      double('CharacterSnapshot',
             id: 1,
             name: 'Battle Eve',
             can_enter?: true,
             character: character)
    end
    let(:timeline_instance) { double('CharacterInstance', id: 99) }

    before do
      allow(character_instance).to receive(:in_past_timeline?).and_return(false)
      allow(CharacterSnapshot).to receive(:first).and_return(snapshot)
      allow(TimelineService).to receive(:accessible_snapshots_for).and_return([])
      allow(TimelineService).to receive(:enter_snapshot_timeline).and_return(timeline_instance)
    end

    it 'enters the snapshot timeline' do
      expect(TimelineService).to receive(:enter_snapshot_timeline).with(character, snapshot)

      execute_command('"Battle Eve"')
    end

    it 'returns success with restrictions info' do
      result = execute_command('"Battle Eve"')

      expect(result[:success]).to be true
      expect(result[:message]).to include("entered the timeline 'Battle Eve'")
      expect(result[:message]).to include('Timeline Restrictions')
      expect(result[:message]).to include('Deaths are disabled')
    end

    it 'returns instance data' do
      result = execute_command('"Battle Eve"')

      expect(result[:data][:instance_id]).to eq(99)
      expect(result[:data][:snapshot_name]).to eq('Battle Eve')
    end

    context 'with unquoted name' do
      it 'handles unquoted snapshot names' do
        allow(CharacterSnapshot).to receive(:first).with(character_id: character.id, name: 'Battle Eve').and_return(snapshot)

        result = execute_command('Battle Eve')

        expect(result[:success]).to be true
      end
    end

    context 'when snapshot not found' do
      before do
        allow(CharacterSnapshot).to receive(:first).and_return(nil)
        allow(TimelineService).to receive(:accessible_snapshots_for).and_return([])
      end

      it 'returns error' do
        result = execute_command('"Unknown Snapshot"')

        expect(result[:success]).to be false
        expect(result[:message]).to include('Unknown Snapshot')
        expect(result[:message]).to include('not found')
      end
    end

    context 'when character not present in snapshot' do
      before do
        allow(snapshot).to receive(:can_enter?).and_return(false)
      end

      it 'returns error' do
        result = execute_command('"Battle Eve"')

        expect(result[:success]).to be false
        expect(result[:message]).to include("present when this snapshot was created")
      end
    end

    context 'when already in a past timeline' do
      before do
        allow(character_instance).to receive(:in_past_timeline?).and_return(true)
      end

      it 'returns error' do
        result = execute_command('"Battle Eve"')

        expect(result[:success]).to be false
        expect(result[:message]).to include("already in a past timeline")
      end
    end

    context 'with year-like input' do
      it 'directs user to use the menu' do
        result = execute_command('1892')

        expect(result[:success]).to be false
        expect(result[:message]).to include('historical timeline')
        expect(result[:message]).to include('menu')
      end
    end

    context 'when service raises NotAllowedError' do
      before do
        allow(TimelineService).to receive(:enter_snapshot_timeline)
          .and_raise(TimelineService::NotAllowedError.new('Already at max timeline instances'))
      end

      it 'returns error with message' do
        result = execute_command('"Battle Eve"')

        expect(result[:success]).to be false
        expect(result[:message]).to include('Already at max timeline instances')
      end
    end
  end

  describe 'helper methods' do
    describe '#show_enter_menu' do
      before do
        allow(character_instance).to receive(:in_past_timeline?).and_return(false)
        allow(TimelineService).to receive(:snapshots_for).with(character).and_return([])
        allow(TimelineService).to receive(:accessible_snapshots_for).with(character).and_return([])
        allow(OutputHelper).to receive(:store_agent_interaction)
      end

      it 'allows entering historical timeline even with no snapshots' do
        result = command.send(:show_enter_menu)

        expect(result[:success]).to be true
        expect(result[:type]).to eq(:quickmenu)
        expect(result[:options].map { |option| option[:key] }).to contain_exactly('h', 'q')
      end
    end

    describe '#list_timelines' do
      let(:snapshot) do
        double('CharacterSnapshot',
               id: 1,
               name: 'Battle Eve',
               description: 'The night before the big battle',
               snapshot_taken_at: Time.now - 3600,
               character: character,
               character_id: character.id)
      end

      before do
        allow(TimelineService).to receive(:snapshots_for).with(character).and_return([])
        allow(TimelineService).to receive(:accessible_snapshots_for).with(character).and_return([])
        allow(TimelineService).to receive(:active_timelines_for).with(character).and_return([])
      end

      context 'with no timelines' do
        it 'shows empty state message' do
          result = command.send(:list_timelines)

          expect(result[:success]).to be true
          expect(result[:message]).to include('no snapshots or active timelines')
        end
      end

      context 'with own snapshots' do
        before do
          allow(TimelineService).to receive(:snapshots_for).with(character).and_return([snapshot])
          allow(TimelineService).to receive(:accessible_snapshots_for).with(character).and_return([snapshot])
        end

        it 'lists own snapshots' do
          result = command.send(:list_timelines)

          expect(result[:success]).to be true
          expect(result[:message]).to include('Your Snapshots')
          expect(result[:message]).to include('Battle Eve')
        end

        it 'includes snapshot description' do
          result = command.send(:list_timelines)

          expect(result[:message]).to include('night before the big battle')
        end
      end

      context 'with accessible snapshots from others' do
        let(:other_snapshot) do
          double('CharacterSnapshot',
                 id: 2,
                 name: 'Victory Celebration',
                 description: nil,
                 snapshot_taken_at: Time.now - 7200,
                 character: double('Character', full_name: 'Other Person'),
                 character_id: 999)
        end

        before do
          allow(TimelineService).to receive(:accessible_snapshots_for).with(character).and_return([other_snapshot])
        end

        it 'lists accessible snapshots' do
          result = command.send(:list_timelines)

          expect(result[:success]).to be true
          expect(result[:message]).to include('Snapshots You Can Join')
          expect(result[:message]).to include('Victory Celebration')
          expect(result[:message]).to include('by Other Person')
        end
      end

      context 'with active timeline instances' do
        let(:timeline) { double('Timeline', display_name: 'Past Adventures') }
        let(:active_instance) do
          double('CharacterInstance',
                 id: 99,
                 online: true,
                 source_snapshot_id: 1,
                 timeline: timeline)
        end

        before do
          allow(TimelineService).to receive(:active_timelines_for).with(character).and_return([active_instance])
        end

        it 'lists active instances' do
          result = command.send(:list_timelines)

          expect(result[:success]).to be true
          expect(result[:message]).to include('Active Timeline Instances')
          expect(result[:message]).to include('Past Adventures')
          expect(result[:message]).to include('[ONLINE]')
        end
      end
    end

    describe '#leave_timeline' do
      context 'when not in a past timeline' do
        before do
          allow(character_instance).to receive(:in_past_timeline?).and_return(false)
        end

        it 'returns error' do
          result = command.send(:leave_timeline)

          expect(result[:success]).to be false
          expect(result[:message]).to include("not in a past timeline")
        end
      end

      context 'when in a past timeline' do
        before do
          allow(character_instance).to receive(:in_past_timeline?).and_return(true)
          allow(character_instance).to receive(:timeline_display_name).and_return('Battle Eve')
          allow(TimelineService).to receive(:leave_timeline).with(character_instance)
        end

        it 'leaves the timeline' do
          expect(TimelineService).to receive(:leave_timeline).with(character_instance)

          command.send(:leave_timeline)
        end

        it 'returns success message' do
          result = command.send(:leave_timeline)

          expect(result[:success]).to be true
          expect(result[:message]).to include("left the timeline 'Battle Eve'")
          expect(result[:message]).to include('returned to the present')
        end
      end
    end

    describe '#show_timeline_info' do
      context 'when not in a past timeline' do
        before do
          allow(character_instance).to receive(:in_past_timeline?).and_return(false)
        end

        it 'returns error' do
          result = command.send(:show_timeline_info)

          expect(result[:success]).to be false
          expect(result[:message]).to include("not in a past timeline")
        end
      end

      context 'when in a historical timeline' do
        let(:zone) { double('Zone', name: 'Downtown') }
        let(:timeline) do
          double('Timeline',
                 display_name: '1892 Downtown',
                 timeline_type: 'historical',
                 historical?: true,
                 snapshot?: false,
                 year: 1892,
                 zone: zone,
                 era: nil,
                 no_death?: true,
                 no_prisoner?: true,
                 no_xp?: true,
                 rooms_read_only?: true)
        end

        before do
          allow(character_instance).to receive(:in_past_timeline?).and_return(true)
          allow(character_instance).to receive(:timeline).and_return(timeline)
        end

        it 'shows timeline info' do
          result = command.send(:show_timeline_info)

          expect(result[:success]).to be true
          expect(result[:message]).to include('Current Timeline')
          expect(result[:message]).to include('1892 Downtown')
          expect(result[:message]).to include('Type: Historical')
          expect(result[:message]).to include('Year: 1892')
          expect(result[:message]).to include('Zone: Downtown')
        end

        it 'shows restrictions' do
          result = command.send(:show_timeline_info)

          expect(result[:message]).to include('Restrictions')
          expect(result[:message]).to include('No Death: Yes')
          expect(result[:message]).to include('No Prisoner: Yes')
          expect(result[:message]).to include('No XP: Yes')
          expect(result[:message]).to include('Rooms Read-Only: Yes')
        end
      end

      context 'when in a snapshot timeline' do
        let(:snapshot_creator) { double('Character', full_name: 'Creator Name') }
        let(:snapshot) do
          double('CharacterSnapshot',
                 character: snapshot_creator,
                 snapshot_taken_at: Time.new(2024, 1, 15, 14, 30))
        end
        let(:timeline) do
          double('Timeline',
                 display_name: 'Battle Eve',
                 timeline_type: 'snapshot',
                 historical?: false,
                 snapshot?: true,
                 snapshot: snapshot,
                 no_death?: true,
                 no_prisoner?: false,
                 no_xp?: true,
                 rooms_read_only?: true)
        end

        before do
          allow(character_instance).to receive(:in_past_timeline?).and_return(true)
          allow(character_instance).to receive(:timeline).and_return(timeline)
        end

        it 'shows snapshot info' do
          result = command.send(:show_timeline_info)

          expect(result[:success]).to be true
          expect(result[:message]).to include('Battle Eve')
          expect(result[:message]).to include('Type: Snapshot')
          expect(result[:message]).to include('Snapshot by: Creator Name')
          expect(result[:message]).to include('Taken at:')
        end
      end
    end
  end
end
