# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::System::Commands, type: :command do
  let(:room) { create(:room) }
  let(:reality) { create(:reality) }
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }
  let(:character_instance) { create(:character_instance, character: character, current_room: room, reality: reality, online: true) }

  # Use shared example for standard metadata tests
  it_behaves_like "command metadata", 'commands', :system, ['cmds', 'cmdlist']

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'with no category specified' do
      it 'returns success' do
        result = command.execute('commands')
        expect(result[:success]).to be true
      end

      it 'shows category list header' do
        result = command.execute('commands')
        expect(result[:message]).to include('Available Command Categories')
      end

      it 'shows categories in HTML table format without counts' do
        result = command.execute('commands')
        # Should show categories in table format, not with command counts
        expect(result[:message]).to include('combat')
        expect(result[:message]).not_to match(/\(\d+ commands?\)/)
        # Table should use HTML
        expect(result[:message]).to include('<table>')
        expect(result[:message]).to include('<td>')
      end

      it 'includes usage hint' do
        result = command.execute('commands')
        expect(result[:message]).to include("Type 'commands &lt;category&gt;'")
      end

      it 'includes structured data with categories' do
        result = command.execute('commands')
        expect(result[:structured][:display_type]).to eq(:command_list)
        expect(result[:structured][:categories]).to be_a(Hash)
      end

      it 'does not list individual command names inline' do
        result = command.execute('commands')
        # The output should NOT list commands like "COMMUNICATION: emote, say, whisper..."
        # Instead it should show categories with descriptions
        expect(result[:message]).not_to match(/^  \w+: \w+, \w+/)
      end
    end

    context 'with valid category specified' do
      it 'returns success for navigation category' do
        result = command.execute('commands navigation')
        expect(result[:success]).to be true
      end

      it 'shows category header in uppercase' do
        result = command.execute('commands navigation')
        expect(result[:message]).to include('NAVIGATION')
      end

      it 'lists commands in the category' do
        result = command.execute('commands navigation')
        # Should include commands like 'look'
        expect(result[:message]).to include('look')
      end

      it 'shows command help text' do
        result = command.execute('commands navigation')
        # Commands should have descriptions in format "  ● command - description"
        expect(result[:message]).to match(/●.*-.*/)
      end

      it 'shows category description' do
        result = command.execute('commands navigation')
        # Should show the category description from CATEGORY_DESCRIPTIONS
        expect(result[:message]).to include('Movement, posture, and vehicles')
      end

      it 'includes usage hint for help' do
        result = command.execute('commands navigation')
        expect(result[:message]).to include("Type 'help <command>'")
      end
    end

    context 'with case-insensitive category' do
      it 'accepts lowercase category' do
        result = command.execute('commands navigation')
        expect(result[:success]).to be true
      end

      it 'accepts uppercase category' do
        result = command.execute('commands NAVIGATION')
        expect(result[:success]).to be true
      end

      it 'accepts mixed case category' do
        result = command.execute('commands Navigation')
        expect(result[:success]).to be true
      end
    end

    context 'with invalid category' do
      it 'returns error' do
        result = command.execute('commands invalid_category')
        expect(result[:success]).to be false
      end

      it 'shows unknown category message' do
        result = command.execute('commands invalid_category')
        expect(result[:error]).to include("Unknown category")
        expect(result[:error]).to include("invalid_category")
      end

      it 'lists available categories' do
        result = command.execute('commands invalid_category')
        expect(result[:error]).to include("Available categories")
      end
    end

    context 'with combat category' do
      it 'lists combat commands' do
        result = command.execute('commands combat')
        expect(result[:success]).to be true
        expect(result[:message]).to include('COMBAT')
      end
    end

    context 'with system category' do
      it 'lists system commands including commands itself' do
        result = command.execute('commands system')
        expect(result[:success]).to be true
        expect(result[:message]).to include('commands')
      end
    end

    context 'with aliases' do
      it 'works with cmds alias' do
        result = command.execute('cmds')
        expect(result[:success]).to be true
        expect(result[:message]).to include('Available Command Categories')
      end

      it 'works with cmdlist alias' do
        result = command.execute('cmdlist')
        expect(result[:success]).to be true
        expect(result[:message]).to include('Available Command Categories')
      end

      it 'works with cmds alias and category argument' do
        result = command.execute('cmds navigation')
        expect(result[:success]).to be true
        expect(result[:message]).to include('NAVIGATION')
      end
    end

    context 'with empty category argument' do
      it 'treats empty string as no category' do
        result = command.execute('commands ')
        expect(result[:success]).to be true
        expect(result[:message]).to include('Available Command Categories')
      end
    end
  end

  describe 'CATEGORY_DESCRIPTIONS' do
    it 'has descriptions for common categories' do
      expect(described_class::CATEGORY_DESCRIPTIONS[:combat]).not_to be_nil
      expect(described_class::CATEGORY_DESCRIPTIONS[:combat]).not_to be_empty
      expect(described_class::CATEGORY_DESCRIPTIONS[:communication]).not_to be_nil
      expect(described_class::CATEGORY_DESCRIPTIONS[:navigation]).not_to be_nil
      expect(described_class::CATEGORY_DESCRIPTIONS[:system]).not_to be_nil
    end

    it 'has concise descriptions' do
      described_class::CATEGORY_DESCRIPTIONS.each do |category, description|
        expect(description.length).to be < 50, "#{category} description too long"
      end
    end
  end
end
