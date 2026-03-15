# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Info::Finger, type: :command do
  let(:location) { create(:location) }
  let(:room) { create(:room, location: location, name: 'Test Room', short_description: 'A room') }
  let(:reality) { create(:reality) }
  let(:user) { create(:user) }
  let(:character) { create(:character, forename: 'Alice', surname: 'Test', user: user) }
  let(:character_instance) do
    create(:character_instance,
      character: character,
      reality: reality,
      current_room: room,
      online: true,
      status: 'alive',
      stance: 'standing'
    )
  end

  let(:user2) { create(:user) }
  let(:bob_character) do
    create(:character,
      forename: 'Bob',
      surname: 'Smith',
      user: user2,
      race: 'human',
      character_class: 'warrior'
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
      level: 5,
      last_activity: Time.now - 60
    )
  end

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'with valid target' do
      it 'displays character information' do
        result = command.execute('finger Bob')
        expect(result[:success]).to be true
        expect(result[:message]).to include('Bob Smith')
        expect(result[:message]).to include('Level: 5')
      end

      it 'shows online status and location' do
        result = command.execute('finger Bob')
        expect(result[:success]).to be true
        expect(result[:message]).to include('Online')
        expect(result[:message]).to include('Test Room')
      end

      it 'shows race and class if present' do
        result = command.execute('finger Bob')
        expect(result[:success]).to be true
        expect(result[:message]).to include('human')
        expect(result[:message]).to include('warrior')
      end

      it 'shows last activity time' do
        result = command.execute('finger Bob')
        expect(result[:success]).to be true
        expect(result[:message]).to include('Last Activity')
      end
    end

    context 'character knowledge' do
      it 'shows known status when character is known' do
        CharacterKnowledge.create(
          knower_character_id: character.id,
          known_character_id: bob_character.id,
          is_known: true,
          known_name: 'Bobby'
        )

        result = command.execute('finger Bob')
        expect(result[:success]).to be true
        expect(result[:message]).to include('Known to you: Yes')
        expect(result[:message]).to include('Bobby')
      end

      it 'shows unknown status when character is not known' do
        result = command.execute('finger Bob')
        expect(result[:success]).to be true
        expect(result[:message]).to include('Known to you: No')
      end
    end

    context 'offline character' do
      it 'shows offline status' do
        bob_instance.update(online: false)
        result = command.execute('finger Bob')
        expect(result[:success]).to be true
        expect(result[:message]).to include('Offline')
      end
    end

    context 'without target' do
      it 'returns error' do
        result = command.execute('finger')
        expect(result[:success]).to be false
        expect(result[:message]).to include('Finger whom')
      end
    end

    context 'target not found' do
      it 'returns error' do
        result = command.execute('finger Nobody')
        expect(result[:success]).to be false
        expect(result[:message]).to include("Nobody")
        expect(result[:message]).to include("found")
      end
    end

    context 'partial name matching' do
      it 'finds by prefix' do
        result = command.execute('finger Bo')
        expect(result[:success]).to be true
        expect(result[:message]).to include('Bob Smith')
      end
    end
  end
end
