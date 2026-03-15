# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::System::Helpsearch, type: :command do
  let(:user) { create(:user) }
  let(:character) { create(:character, forename: 'TestChar', user: user) }
  let(:character_instance) { create(:character_instance, character: character) }

  subject(:command) { described_class.new(character_instance) }

  describe 'command metadata' do
    it 'has correct name' do
      expect(described_class.command_name).to eq('helpsearch')
    end

    it 'has correct aliases' do
      expect(described_class.alias_names).to include('searchhelp', 'findhelp')
    end

    it 'has correct category' do
      expect(described_class.category).to eq(:system)
    end
  end

  describe '#execute' do
    context 'without a query' do
      it 'returns an error' do
        result = command.execute('helpsearch')
        expect(result[:success]).to be false
        expect(result[:message]).to include('Search what?')
      end

      it 'returns an error with nil input' do
        result = command.execute(nil)
        expect(result[:success]).to be false
        expect(result[:message]).to include('Search what?')
      end
    end

    context 'with a query but no results' do
      before do
        allow(Firefly::HelpManager).to receive(:search).and_return([])
      end

      it 'returns a helpful message' do
        result = command.execute('helpsearch xyznonexistent')
        expect(result[:success]).to be false
        expect(result[:message]).to include("No help topics found")
        expect(result[:message]).to include('xyznonexistent')
      end
    end

    context 'with a query that has results' do
      let(:mock_results) do
        [
          { command: 'look', topic: 'look', summary: 'Look at surroundings', category: 'navigation' },
          { command: 'look at', topic: 'look at', summary: 'Look at a specific target', category: 'navigation' }
        ]
      end

      before do
        allow(Firefly::HelpManager).to receive(:search).and_return(mock_results)
      end

      it 'returns formatted results' do
        result = command.execute('helpsearch look')
        expect(result[:success]).to be true
        expect(result[:message]).to include("Help Search Results")
        expect(result[:message]).to include('look')
        expect(result[:message]).to include('Found 2 result(s)')
      end

      it 'includes structured data' do
        result = command.execute('helpsearch look')
        expect(result[:data][:action]).to eq('search')
        expect(result[:data][:query]).to eq('look')
        expect(result[:data][:count]).to eq(2)
        expect(result[:data][:results]).to eq(mock_results)
      end
    end

    context 'with a category filter' do
      let(:mock_results) do
        [{ command: 'attack', topic: 'attack', summary: 'Attack a target', category: 'combat' }]
      end

      before do
        allow(Firefly::HelpManager).to receive(:search).and_return(mock_results)
      end

      it 'passes category to search' do
        expect(Firefly::HelpManager).to receive(:search)
          .with('sword', hash_including(category: 'combat'))
          .and_return(mock_results)

        command.execute('helpsearch sword combat')
      end

      it 'shows category in output' do
        result = command.execute('helpsearch sword combat')
        expect(result[:success]).to be true
        expect(result[:data][:category]).to eq('combat')
      end
    end

    context 'with multi-word query' do
      before do
        allow(Firefly::HelpManager).to receive(:search).and_return([])
      end

      it 'joins words into query' do
        expect(Firefly::HelpManager).to receive(:search)
          .with('move north', anything)
          .and_return([])

        command.execute('helpsearch move north')
      end
    end
  end
end
