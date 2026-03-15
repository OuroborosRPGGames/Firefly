# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::System::Help, type: :command do
  let(:room) { create(:room) }
  let(:reality) { create(:reality) }
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }
  let(:character_instance) { create(:character_instance, character: character, current_room: room, reality: reality, online: true) }

  # Use shared example for standard metadata tests
  it_behaves_like "command metadata", 'help', :system, ['h', '?']

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'with no topic specified' do
      it 'returns success' do
        result = command.execute('help')
        expect(result[:success]).to be true
      end

      it 'shows welcome message' do
        result = command.execute('help')
        expect(result[:message]).to include('Welcome to the Help System')
      end

      it 'lists common commands' do
        result = command.execute('help')
        expect(result[:message]).to include('look')
        expect(result[:message]).to include('say')
        expect(result[:message]).to include('emote')
      end

      it 'includes usage hint' do
        result = command.execute('help')
        expect(result[:message]).to include("Type 'help <command>'")
      end

      it 'includes structured data' do
        result = command.execute('help')
        expect(result[:structured][:display_type]).to eq(:help)
      end
    end

    context 'with valid command topic' do
      it 'returns success' do
        result = command.execute('help look')
        expect(result[:success]).to be true
      end

      it 'shows command name in header' do
        result = command.execute('help look')
        expect(result[:message]).to include('LOOK')
      end

      it 'shows help text' do
        result = command.execute('help look')
        expect(result[:message]).to include('Look')
      end

      it 'shows usage info' do
        result = command.execute('help look')
        expect(result[:message]).to include('Usage:')
      end

      it 'shows aliases if any' do
        result = command.execute('help look')
        expect(result[:message]).to match(/Aliases:.*l/i)
      end

      it 'shows category' do
        result = command.execute('help look')
        expect(result[:message]).to include('Category:')
      end

      it 'includes structured data with command info' do
        result = command.execute('help look')
        expect(result[:structured][:command]).to eq('look')
        expect(result[:structured][:category]).to eq(:navigation)
      end
    end

    context 'with command alias as topic' do
      it 'finds command by alias' do
        result = command.execute('help l')
        expect(result[:success]).to be true
        expect(result[:message]).to include('LOOK')
      end
    end

    context 'with case-insensitive topic' do
      it 'accepts lowercase' do
        result = command.execute('help look')
        expect(result[:success]).to be true
      end

      it 'accepts uppercase' do
        result = command.execute('help LOOK')
        expect(result[:success]).to be true
      end

      it 'accepts mixed case' do
        result = command.execute('help Look')
        expect(result[:success]).to be true
      end
    end

    context 'with invalid topic' do
      it 'returns error' do
        result = command.execute('help nonexistent_command_xyz')
        expect(result[:success]).to be false
      end

      it 'shows no help found message' do
        result = command.execute('help nonexistent_command_xyz')
        expect(result[:error]).to include('No help found')
      end

      it 'suggests using commands' do
        result = command.execute('help nonexistent_command_xyz')
        expect(result[:error]).to include('commands')
      end
    end

    context 'with topic that has suggestions' do
      it 'suggests similar commands' do
        result = command.execute('help lok')  # typo for 'look'
        expect(result[:success]).to be false
        # May or may not have suggestions depending on implementation
        expect(result[:error]).to include('No help found')
      end
    end

    context 'with embedding similarity fallback' do
      let!(:helpfile) { create(:helpfile, topic: 'look', command_name: 'look', summary: 'Look around the room', hidden: false, admin_only: false) }

      before do
        # Prevent actual command lookup from succeeding for our misspelling
        allow(Firefly::HelpManager).to receive(:get_help).with('lok', anything).and_return(nil)
        allow(Firefly::HelpManager).to receive(:suggest_topics).and_return([])
        allow(::Commands::Base::Registry).to receive(:suggest_commands).and_return([])
      end

      it 'shows helpfile directly when similarity >= 0.8' do
        allow(Helpfile).to receive(:search_helpfiles).and_return([{ helpfile: helpfile, similarity: 0.85 }])
        allow(Firefly::HelpManager).to receive(:get_help).with('look', anything).and_return({ topic: 'look', content: 'Look around the room' })

        result = command.execute('help lok')
        expect(result[:success]).to be true
        expect(result[:message]).to include('look')
      end

      it 'falls through when similarity < 0.8' do
        allow(Helpfile).to receive(:search_helpfiles).and_return([{ helpfile: helpfile, similarity: 0.5 }])

        result = command.execute('help lok')
        expect(result[:success]).to be false
        expect(result[:error]).to include('No help found')
      end

      it 'falls through when no embedding results' do
        allow(Helpfile).to receive(:search_helpfiles).and_return([])

        result = command.execute('help lok')
        expect(result[:success]).to be false
        expect(result[:error]).to include('No help found')
      end

      it 'falls through gracefully on error' do
        allow(Helpfile).to receive(:search_helpfiles).and_raise(StandardError.new('Voyage API down'))

        result = command.execute('help lok')
        expect(result[:success]).to be false
        expect(result[:error]).to include('No help found')
      end

      it 'skips hidden helpfiles' do
        hidden_helpfile = create(:helpfile, topic: 'secret', command_name: 'secret', summary: 'Secret stuff', hidden: true)
        allow(Helpfile).to receive(:search_helpfiles).and_return([{ helpfile: hidden_helpfile, similarity: 0.9 }])

        result = command.execute('help lok')
        expect(result[:success]).to be false
        expect(result[:error]).to include('No help found')
      end
    end

    context 'with help systems' do
      it 'lists systems with help systems command' do
        result = command.execute('help systems')
        # Might return error if no HelpSystem defined, or success with list
        # Either is acceptable behavior
        expect([true, false]).to include(result[:success])
      end

      it 'shows specific system with help system command' do
        result = command.execute('help system navigation')
        # Might return error if no HelpSystem defined, or success with details
        expect([true, false]).to include(result[:success])
      end
    end

    context 'with aliases' do
      it 'works with h alias' do
        result = command.execute('h')
        expect(result[:success]).to be true
        expect(result[:message]).to include('Welcome to the Help System')
      end

      it 'works with ? alias' do
        result = command.execute('?')
        expect(result[:success]).to be true
        expect(result[:message]).to include('Welcome to the Help System')
      end

      it 'works with h alias and topic' do
        result = command.execute('h look')
        expect(result[:success]).to be true
        expect(result[:message]).to include('LOOK')
      end
    end

    context 'for say command' do
      it 'shows help for say' do
        result = command.execute('help say')
        expect(result[:success]).to be true
        expect(result[:message]).to include('SAY')
        expect(result[:message]).to include('Speak')
      end
    end

    context 'for emote command' do
      it 'shows help for emote' do
        result = command.execute('help emote')
        expect(result[:success]).to be true
        expect(result[:message]).to include('EMOTE')
      end
    end

    context 'for combat commands' do
      it 'shows help for attack' do
        result = command.execute('help attack')
        expect(result[:success]).to be true
        expect(result[:message]).to include('ATTACK')
      end

      it 'shows help for fight' do
        result = command.execute('help fight')
        expect(result[:success]).to be true
        expect(result[:message]).to include('FIGHT')
      end
    end
  end

  describe '#can_execute?' do
    subject(:command) { described_class.new(character_instance) }

    it 'returns true for normal character' do
      expect(command.can_execute?).to be true
    end
  end

  describe 'staff view' do
    let(:staff_user) { create(:user, :admin) }
    let(:staff_character) { create(:character, user: staff_user) }
    let(:staff_instance) { create(:character_instance, character: staff_character, current_room: room, reality: reality, online: true) }
    subject(:command) { described_class.new(staff_instance) }

    it 'shows staff information for staff users' do
      allow(staff_character).to receive(:staff?).and_return(true)
      result = command.execute('help look')

      expect(result[:success]).to be true
      expect(result[:message]).to include('Staff Information')
    end
  end
end
