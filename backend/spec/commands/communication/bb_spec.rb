# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Communication::BB, type: :command do
  let(:room) { create(:room) }
  let(:reality) { create(:reality) }
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user, forename: 'Alice') }
  let(:character_instance) do
    create(:character_instance,
           character: character,
           current_room: room,
           reality: reality,
           online: true)
  end

  subject { described_class.new(character_instance) }

  before do
    allow(BroadcastService).to receive(:to_character)
    allow(BroadcastService).to receive(:to_room)
  end

  # Use shared example for command metadata
  it_behaves_like "command metadata", 'bb', :communication, ['bulletin', 'bulletins', 'board']

  describe 'command registration' do
    it 'is registered in the command registry' do
      expect(Commands::Base::Registry.commands['bb']).to eq(described_class)
    end
  end

  # ========================================
  # List/View Tests
  # ========================================

  describe 'bb list' do
    context 'with empty bulletin board' do
      it 'shows empty message' do
        result = subject.execute('bb')

        expect(result[:success]).to be true
        expect(result[:message]).to include('bulletin board is empty')
      end

      it 'returns zero count in data' do
        result = subject.execute('bb list')

        expect(result[:data][:count]).to eq(0)
      end
    end

    context 'with bulletins' do
      let(:other_user) { create(:user) }
      let(:other_character) { create(:character, user: other_user, forename: 'Bob') }

      let!(:bulletin) do
        Bulletin.create(
          character_id: other_character.id,
          body: 'Looking for adventuring party!',
          from_text: other_character.full_name,
          posted_at: Time.now
        )
      end

      it 'shows bulletins' do
        result = subject.execute('bb')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Bulletin Board')
        expect(result[:message]).to include('Looking for adventuring party!')
      end

      it 'returns count in data' do
        result = subject.execute('bb list')

        expect(result[:data][:count]).to eq(1)
      end

      it 'shows author name' do
        result = subject.execute('bb')

        expect(result[:message]).to include('Bob')
      end
    end
  end

  # ========================================
  # Post Tests
  # ========================================

  describe 'bb post' do
    context 'with no message' do
      it 'returns error' do
        result = subject.execute('bb post')

        expect(result[:success]).to be false
        expect(result[:error] || result[:message]).to include('What do you want to post')
      end
    end

    context 'with valid message' do
      it 'creates bulletin' do
        result = subject.execute('bb post Hello everyone!')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Bulletin posted')
        expect(Bulletin.by_character(character).count).to eq(1)
      end

      it 'broadcasts to room' do
        expect(BroadcastService).to receive(:to_room).with(
          room.id,
          anything,
          hash_including(exclude: [character_instance.id])
        )

        subject.execute('bb post Test message')
      end

      it 'replaces existing bulletin from same character' do
        # Create first bulletin
        subject.execute('bb post First message')
        expect(Bulletin.by_character(character).count).to eq(1)

        # Create second bulletin - should replace
        subject.execute('bb post Second message')
        expect(Bulletin.by_character(character).count).to eq(1)

        bulletin = Bulletin.by_character(character).first
        expect(bulletin.body).to eq('Second message')
      end
    end

    context 'with message too long' do
      it 'returns error' do
        long_message = 'a' * 2001
        result = subject.execute("bb post #{long_message}")

        expect(result[:success]).to be false
        expect(result[:error] || result[:message]).to include('too long')
      end
    end

    context 'with direct message (no subcommand)' do
      it 'posts the message directly' do
        result = subject.execute('bb Looking for group')

        expect(result[:success]).to be true
        expect(Bulletin.by_character(character).count).to eq(1)

        bulletin = Bulletin.by_character(character).first
        expect(bulletin.body).to include('Looking for group')
      end
    end
  end

  # ========================================
  # Read Tests
  # ========================================

  describe 'bb read' do
    context 'with no bulletins' do
      it 'returns error for invalid number' do
        result = subject.execute('bb read 1')

        expect(result[:success]).to be false
        expect(result[:error] || result[:message]).to include('Invalid bulletin number')
      end
    end

    context 'with bulletins' do
      let(:other_user) { create(:user) }
      let(:other_character) { create(:character, user: other_user, forename: 'Bob') }

      let!(:bulletin) do
        Bulletin.create(
          character_id: other_character.id,
          body: 'Test bulletin content',
          from_text: other_character.full_name,
          posted_at: Time.now
        )
      end

      it 'shows bulletin content' do
        result = subject.execute('bb read 1')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Test bulletin content')
      end

      it 'shows author info' do
        result = subject.execute('bb read 1')

        expect(result[:message]).to include('Bob')
      end

      it 'returns error for invalid number' do
        result = subject.execute('bb read 99')

        expect(result[:success]).to be false
        expect(result[:error] || result[:message]).to include('Invalid bulletin number')
      end

      it 'returns error for zero number' do
        result = subject.execute('bb read 0')

        expect(result[:success]).to be false
      end

      it 'returns error when no number provided' do
        result = subject.execute('bb read')

        expect(result[:success]).to be false
        expect(result[:error] || result[:message]).to include('Usage')
      end
    end
  end

  # ========================================
  # Delete Tests
  # ========================================

  describe 'bb delete' do
    context 'with no bulletins' do
      it 'returns error' do
        result = subject.execute('bb delete')

        expect(result[:success]).to be false
        expect(result[:error] || result[:message]).to include("don't have any bulletins")
      end
    end

    context 'with own bulletin' do
      before do
        Bulletin.create(
          character_id: character.id,
          body: 'My bulletin',
          from_text: character.full_name,
          posted_at: Time.now
        )
      end

      it 'deletes own bulletin' do
        expect(Bulletin.by_character(character).count).to eq(1)

        result = subject.execute('bb delete')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Deleted')
        expect(Bulletin.by_character(character).count).to eq(0)
      end

      it 'returns count in result' do
        result = subject.execute('bb delete')

        expect(result[:data][:count]).to eq(1)
      end
    end
  end

  # ========================================
  # Usage Tests
  # ========================================

  describe 'unknown subcommand' do
    it 'treats as direct post' do
      # Unknown subcommands that aren't reserved words are treated as posts
      result = subject.execute('bb hello world')

      expect(result[:success]).to be true
    end
  end

  # ========================================
  # Alias Tests
  # ========================================

  describe 'aliases' do
    it 'command has bulletin alias' do
      alias_names = described_class.aliases.map { |a| a[:name] }
      expect(alias_names).to include('bulletin')
    end

    it 'command has board alias' do
      alias_names = described_class.aliases.map { |a| a[:name] }
      expect(alias_names).to include('board')
    end
  end
end
