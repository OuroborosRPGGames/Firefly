# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Customization::ChangeName, type: :command do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area) }
  let(:room) { create(:room, location: location) }
  let(:reality) { create(:reality) }
  let(:character) { create(:character, forename: 'Alice', surname: 'Smith') }
  let(:character_instance) { create(:character_instance, character: character, current_room: room, reality: reality, online: true) }

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'with no input' do
      it 'shows usage' do
        result = command.execute('change name')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Usage')
        expect(result[:error]).to include('nickname')
        expect(result[:error]).to include('forename')
        expect(result[:error]).to include('surname')
      end
    end

    context 'change nickname' do
      it 'changes nickname' do
        result = command.execute('change name nickname Ally')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Nickname updated')
        expect(character.reload.nickname).to eq('Ally')
      end

      it 'auto-capitalizes nickname' do
        result = command.execute('change name nickname ally')

        expect(result[:success]).to be true
        expect(character.reload.nickname).to eq('Ally')
      end

      it 'rejects duplicate nicknames' do
        create(:character, forename: 'Other', nickname: 'Taken')
        result = command.execute('change name nickname Taken')

        expect(result[:success]).to be false
        expect(result[:error]).to include('already taken')
      end

      it 'rejects nicknames over 50 characters' do
        long_nickname = 'A' * 55
        result = command.execute("change name nickname #{long_nickname}")

        expect(result[:success]).to be false
        expect(result[:error]).to include('too long')
      end
    end

    context 'change forename' do
      it 'changes forename when no cooldown' do
        result = command.execute('change name forename Alexandra')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Forename changed')
        expect(character.reload.forename).to eq('Alexandra')
      end

      it 'sets last_name_change timestamp' do
        command.execute('change name forename Alexandra')

        expect(character.reload.last_name_change).not_to be_nil
        expect(character.last_name_change).to be_within(5).of(Time.now)
      end

      it 'respects 21-day cooldown' do
        character.update(last_name_change: Time.now - (5 * 24 * 60 * 60))  # 5 days ago
        result = command.execute('change name forename Alexandra')

        expect(result[:success]).to be false
        expect(result[:error]).to include('cannot change')
        expect(result[:error]).to match(/\d+ more day/)
      end

      it 'allows change after cooldown expires' do
        character.update(last_name_change: Time.now - (22 * 24 * 60 * 60))  # 22 days ago
        result = command.execute('change name forename Alexandra')

        expect(result[:success]).to be true
      end

      it 'rejects duplicate forename+surname combination' do
        create(:character, forename: 'Alexandra', surname: 'Smith')
        result = command.execute('change name forename Alexandra')

        expect(result[:success]).to be false
        expect(result[:error]).to include('already taken')
      end
    end

    context 'change surname' do
      it 'changes surname when no cooldown' do
        result = command.execute('change name surname Johnson')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Surname changed')
        expect(character.reload.surname).to eq('Johnson')
      end

      it 'respects 21-day cooldown' do
        character.update(last_name_change: Time.now - (10 * 24 * 60 * 60))  # 10 days ago
        result = command.execute('change name surname Johnson')

        expect(result[:success]).to be false
        expect(result[:error]).to include('cannot change')
      end

      it 'rejects duplicate forename+surname combination' do
        create(:character, forename: 'Alice', surname: 'Johnson')
        result = command.execute('change name surname Johnson')

        expect(result[:success]).to be false
        expect(result[:error]).to include('already taken')
      end
    end

    context 'with invalid name type' do
      it 'returns error' do
        result = command.execute('change name invalid Bob')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Invalid name type')
      end
    end
  end
end
