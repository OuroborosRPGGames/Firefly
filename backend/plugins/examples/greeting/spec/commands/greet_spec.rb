# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Greeting::Greet, type: :command do
  let(:room) { create(:room) }
  let(:reality) { create(:reality) }
  let(:character) { create(:character) }
  let(:character_instance) do
    create(:character_instance, character: character, current_room: room, reality: reality, status: 'alive')
  end

  let(:other_character) { create(:character, forename: 'Alice', surname: 'Smith') }
  let(:other_instance) do
    create(:character_instance, character: other_character, current_room: room, reality: reality, status: 'alive', online: true)
  end

  describe 'command metadata' do
    it 'has correct command name' do
      expect(described_class.command_name).to eq('greet')
    end

    it 'has aliases' do
      expect(described_class.alias_names).to include('wave', 'hello', 'hi')
    end

    it 'has correct category' do
      expect(described_class.category).to eq(:social)
    end

    it 'has help text' do
      expect(described_class.help_text).to include('Greet')
    end

    it 'has usage information' do
      expect(described_class.usage).to eq('greet <character>')
    end

    it 'has examples' do
      expect(described_class.examples).to include('greet John')
    end
  end

  describe 'requirements' do
    it 'requires alive state' do
      requirements = described_class.requirements
      alive_req = requirements.find { |r| r[:args]&.include?(:alive) }
      expect(alive_req).not_to be_nil
    end
  end

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'when greeting everyone' do
      it 'greets everyone successfully' do
        result = command.execute('greet everyone')
        expect(result[:success]).to be true
        expect(result[:message]).to include('everyone')
      end

      it 'works with "all" keyword' do
        result = command.execute('greet all')
        expect(result[:success]).to be true
      end

      it 'works with no target specified' do
        result = command.execute('greet')
        expect(result[:success]).to be true
      end
    end

    context 'when greeting a specific character' do
      before { other_instance } # Ensure other character is in room

      it 'greets the target successfully' do
        result = command.execute('greet Alice')
        expect(result[:success]).to be true
        expect(result[:data][:target]).to eq(other_character.full_name)
      end

      it 'returns error for non-existent target' do
        result = command.execute('greet Nonexistent')
        expect(result[:success]).to be false
        expect(result[:error]).to include("don't see")
      end
    end

    context 'when dead' do
      before do
        allow(character_instance).to receive(:status).and_return('dead')
      end

      it 'returns error' do
        result = command.execute('greet')
        expect(result[:success]).to be false
        expect(result[:error]).to include('dead')
      end
    end
  end

  describe 'aliases' do
    subject(:command) { described_class.new(character_instance) }

    it 'responds to wave' do
      result = command.execute('wave')
      expect(result[:success]).to be true
    end

    it 'responds to hello' do
      result = command.execute('hello')
      expect(result[:success]).to be true
    end

    it 'responds to hi' do
      result = command.execute('hi')
      expect(result[:success]).to be true
    end
  end

  describe 'plugin integration' do
    it 'increments greeting count' do
      initial_count = Plugins::Greeting::Plugin.greeting_count
      command = described_class.new(character_instance)
      command.execute('greet')
      expect(Plugins::Greeting::Plugin.greeting_count).to eq(initial_count + 1)
    end

    it 'uses random greetings from plugin' do
      expect(Plugins::Greeting::Plugin.random_greeting).to be_a(String)
    end
  end
end
