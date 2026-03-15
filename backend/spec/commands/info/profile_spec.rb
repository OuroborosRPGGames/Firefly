# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Info::Profile, type: :command do
  let(:location) { create(:location) }
  let(:room) { create(:room, location: location, name: 'Test Room', short_description: 'A room') }
  let(:reality) { create(:reality) }
  let(:user) { create(:user) }
  let(:character) do
    create(:character,
      forename: 'Alice',
      surname: 'Test',
      user: user,
      race: 'elf',
      character_class: 'mage',
      gender: 'female',
      age: 120,
      height_cm: 165
    )
  end
  let(:character_instance) do
    create(:character_instance,
      character: character,
      reality: reality,
      current_room: room,
      online: true,
      status: 'alive',
      stance: 'standing',
      level: 10,
      experience: 5000
    )
  end

  let(:user2) { create(:user) }
  let(:bob_character) do
    create(:character,
      forename: 'Bob',
      surname: 'Smith',
      user: user2,
      race: 'human',
      character_class: 'warrior',
      short_desc: 'a tall man in armor'
    )
  end
  let!(:bob_instance) do
    create(:character_instance,
      character: bob_character,
      reality: reality,
      current_room: room,
      online: true,
      status: 'alive',
      stance: 'standing',
      level: 5
    )
  end

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'own profile' do
      it 'displays own profile' do
        result = command.execute('profile')
        expect(result[:success]).to be true
        expect(result[:message]).to include('Your Profile')
        expect(result[:message]).to include('Alice Test')
      end

      it 'shows race, class, gender, age' do
        result = command.execute('profile')
        expect(result[:success]).to be true
        expect(result[:message]).to include('elf')
        expect(result[:message]).to include('mage')
        expect(result[:message]).to include('female')
        expect(result[:message]).to include('120')
      end

      it 'shows height display' do
        result = command.execute('profile')
        expect(result[:success]).to be true
        expect(result[:message]).to include('Height')
        expect(result[:message]).to include('165cm')
      end

      it 'shows level' do
        result = command.execute('profile')
        expect(result[:success]).to be true
        expect(result[:message]).to include('Level: 10')
      end

      it 'shows online status' do
        result = command.execute('profile')
        expect(result[:success]).to be true
        expect(result[:message]).to include('Online')
      end

      it 'shows current location' do
        result = command.execute('profile')
        expect(result[:success]).to be true
        expect(result[:message]).to include('Test Room')
      end
    end

    context "another's profile" do
      it 'displays target profile' do
        result = command.execute('profile Bob')
        expect(result[:success]).to be true
        expect(result[:message]).to include("Bob Smith's Profile")
      end

      it 'shows short description if present' do
        result = command.execute('profile Bob')
        expect(result[:success]).to be true
        expect(result[:message]).to include('tall man in armor')
      end

      it 'shows target level' do
        result = command.execute('profile Bob')
        expect(result[:success]).to be true
        expect(result[:message]).to include('Level: 5')
      end
    end

    context 'target not found' do
      it 'returns error' do
        result = command.execute('profile Nobody')
        expect(result[:success]).to be false
        expect(result[:message]).to include("Nobody")
        expect(result[:message]).to include("found")
      end
    end

    context 'partial name matching' do
      it 'finds by prefix' do
        result = command.execute('profile Bo')
        expect(result[:success]).to be true
        expect(result[:message]).to include("Bob Smith's Profile")
      end
    end
  end
end
