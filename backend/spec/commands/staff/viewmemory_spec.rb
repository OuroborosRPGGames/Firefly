# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Staff::ViewMemory, type: :command do
  let(:room) { create(:room) }
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

  subject(:command) { described_class.new(character_instance) }

  describe 'command registration' do
    it 'is registered in the command registry' do
      expect(Commands::Base::Registry.commands['viewmemory']).to eq(described_class)
    end

    it 'has alias memview' do
      cmd_class, = Commands::Base::Registry.find_command('memview')
      expect(cmd_class).to eq(described_class)
    end

    it 'has alias showmemory' do
      cmd_class, = Commands::Base::Registry.find_command('showmemory')
      expect(cmd_class).to eq(described_class)
    end
  end

  describe 'command metadata' do
    it 'has correct command name' do
      expect(described_class.command_name).to eq('viewmemory')
    end

    it 'has category staff' do
      expect(described_class.category).to eq(:staff)
    end

    it 'has help text' do
      expect(described_class.help_text).to include('View')
    end

    it 'has usage' do
      expect(described_class.usage).to include('viewmemory')
    end

    it 'has examples' do
      expect(described_class.examples).to include('viewmemory 142')
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
        result = non_staff_command.execute('viewmemory 1')

        expect(result[:success]).to be false
        expect(result[:error]).to include('staff members')
      end
    end

    context 'with empty arguments' do
      it 'shows usage message' do
        result = command.execute('viewmemory')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Usage')
      end
    end

    context 'with invalid ID' do
      it 'returns error for zero' do
        result = command.execute('viewmemory 0')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Usage')
      end

      it 'returns error for negative number' do
        result = command.execute('viewmemory -5')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Usage')
      end

      it 'returns error for non-numeric input' do
        result = command.execute('viewmemory abc')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Usage')
      end
    end

    context 'when WorldMemory is not defined' do
      before do
        hide_const('WorldMemory')
      end

      it 'returns error about unavailable class' do
        result = command.execute('viewmemory 1')

        expect(result[:success]).to be false
        expect(result[:error]).to include('WorldMemory not available')
      end
    end

    context 'with valid ID' do
      let(:memory_room) { create(:room, name: 'Test Room') }
      let(:other_character) { create(:character, forename: 'Bob') }

      let(:world_memory_character) do
        double('WorldMemoryCharacter',
               character: other_character,
               role: 'participant',
               message_count: 5)
      end

      let(:world_memory_location) do
        double('WorldMemoryLocation',
               room: memory_room,
               is_primary: true)
      end

      let(:world_memory) do
        double('WorldMemory',
               id: 42,
               summary: 'A conversation about magic',
               importance: 7,
               publicity_level: 'public',
               started_at: Time.now - 3600,
               ended_at: Time.now - 1800,
               message_count: 10,
               world_memory_characters: [world_memory_character],
               world_memory_locations: [world_memory_location],
               raw_log: "Alice: Hello\nBob: Hi there",
               raw_log_expired?: false)
      end

      before do
        stub_const('WorldMemory', double('WorldMemoryClass'))
        allow(WorldMemory).to receive(:[]).with(42).and_return(world_memory)
      end

      it 'shows memory details' do
        result = command.execute('viewmemory 42')

        expect(result[:success]).to be true
        expect(result[:message]).to include('<h3>World Memory #42</h3>')
        expect(result[:message]).to include('A conversation about magic')
        expect(result[:message]).to include('Importance: 7/10')
        expect(result[:message]).to include('public')
        expect(result[:message]).to include('Message Count: 10')
      end

      it 'shows linked characters' do
        result = command.execute('viewmemory 42')

        expect(result[:message]).to include('Characters Involved:')
        expect(result[:message]).to include('Bob')
        expect(result[:message]).to include('participant')
        expect(result[:message]).to include('5 messages')
      end

      it 'shows linked locations' do
        result = command.execute('viewmemory 42')

        expect(result[:message]).to include('Locations:')
        expect(result[:message]).to include('Test Room')
        expect(result[:message]).to include('(primary)')
      end

      it 'shows raw log' do
        result = command.execute('viewmemory 42')

        expect(result[:message]).to include('<h4>Raw Log</h4>')
        expect(result[:message]).to include("Alice: Hello")
        expect(result[:message]).to include("Bob: Hi there")
      end

      it 'includes action data' do
        result = command.execute('viewmemory 42')

        expect(result[:data][:action]).to eq('viewmemory')
        expect(result[:data][:memory_id]).to eq(42)
      end

      context 'with expired raw log' do
        before do
          allow(world_memory).to receive(:raw_log).and_return(nil)
          allow(world_memory).to receive(:raw_log_expired?).and_return(true)
        end

        it 'shows expired message' do
          result = command.execute('viewmemory 42')

          expect(result[:message]).to include('expired and been purged')
        end
      end

      context 'with empty raw log' do
        before do
          allow(world_memory).to receive(:raw_log).and_return('')
          allow(world_memory).to receive(:raw_log_expired?).and_return(false)
        end

        it 'shows no log available message' do
          result = command.execute('viewmemory 42')

          expect(result[:message]).to include('No raw log available')
        end
      end

      context 'with no linked characters' do
        before do
          allow(world_memory).to receive(:world_memory_characters).and_return([])
        end

        it 'shows none linked message' do
          result = command.execute('viewmemory 42')

          expect(result[:message]).to include('None linked.')
        end
      end

      context 'with no linked locations' do
        before do
          allow(world_memory).to receive(:world_memory_locations).and_return([])
        end

        it 'shows none linked message' do
          result = command.execute('viewmemory 42')

          expect(result[:message]).to include('None linked.')
        end
      end

      context 'with nil importance' do
        before do
          allow(world_memory).to receive(:importance).and_return(nil)
        end

        it 'shows default importance' do
          result = command.execute('viewmemory 42')

          expect(result[:message]).to include('Importance: 5/10')
        end
      end
    end

    context 'when memory not found' do
      before do
        stub_const('WorldMemory', double('WorldMemoryClass'))
        allow(WorldMemory).to receive(:[]).with(999).and_return(nil)
      end

      it 'returns error' do
        result = command.execute('viewmemory 999')

        expect(result[:success]).to be false
        expect(result[:error]).to include('World memory #999 not found')
      end
    end
  end
end
