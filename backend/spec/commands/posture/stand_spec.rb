# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Posture::Stand, type: :command do
  let(:user) { create(:user) }
  let(:character) { create(:character, forename: 'Test', surname: 'Char', user: user) }
  let(:room) { create(:room, name: 'Test Room', short_description: 'A room') }
  let(:character_instance) { create(:character_instance, character: character, current_room: room, stance: 'sitting') }

  let!(:couch) do
    Place.create(
      room: room,
      name: 'comfortable couch',
      is_furniture: true,
      default_sit_action: 'on',
      capacity: 4
    )
  end

  let!(:bar) do
    Place.create(
      room: room,
      name: 'wooden bar',
      is_furniture: true,
      default_sit_action: 'at',
      capacity: 6
    )
  end

  let!(:stage) do
    Place.create(
      room: room,
      name: 'small stage',
      is_furniture: true,
      default_sit_action: 'on',
      capacity: 3
    )
  end

  let!(:window) do
    Place.create(
      room: room,
      name: 'large window',
      is_furniture: true,
      default_sit_action: 'by',
      capacity: 2
    )
  end

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'standing up from sitting' do
      it 'changes stance to standing' do
        result = command.execute('stand')
        expect(result[:success]).to be true
        expect(result[:message]).to include('You stand up')
        expect(character_instance.reload.stance).to eq('standing')
      end

      it 'clears current place when standing' do
        character_instance.update(current_place_id: couch.id)
        result = command.execute('stand')
        expect(result[:success]).to be true
        expect(character_instance.reload.current_place_id).to be_nil
      end

      it 'mentions furniture name when standing from furniture' do
        character_instance.update(current_place_id: couch.id)
        result = command.execute('stand')
        expect(result[:success]).to be true
        expect(result[:message]).to include('couch')
      end
    end

    context 'standing up from lying' do
      before do
        character_instance.update(stance: 'lying')
      end

      it 'changes stance to standing' do
        result = command.execute('stand up')
        expect(result[:success]).to be true
        expect(character_instance.reload.stance).to eq('standing')
      end
    end

    context 'alias commands' do
      it 'handles "get up"' do
        result = command.execute('get up')
        expect(result[:success]).to be true
        expect(character_instance.reload.stance).to eq('standing')
      end

      it 'handles "stand up"' do
        result = command.execute('stand up')
        expect(result[:success]).to be true
        expect(character_instance.reload.stance).to eq('standing')
      end
    end

    context 'error cases' do
      it 'errors when already standing with no place' do
        character_instance.update(stance: 'standing', current_place_id: nil)
        result = command.execute('stand')
        expect(result[:success]).to be false
        expect(result[:error]).to include('already standing')
      end
    end

    context 'standing at furniture' do
      it 'stands at a place with "stand at"' do
        result = command.execute('stand at wooden bar')
        expect(result[:success]).to be true
        expect(result[:message]).to include('stand at wooden bar')
        expect(character_instance.reload.stance).to eq('standing')
        expect(character_instance.reload.current_place_id).to eq(bar.id)
      end

      it 'stands by a place with "stand by"' do
        result = command.execute('stand by window')
        expect(result[:success]).to be true
        expect(result[:message]).to include('stand by large window')
        expect(character_instance.reload.current_place_id).to eq(window.id)
      end

      it 'stands beside a place with "stand beside"' do
        result = command.execute('stand beside bar')
        expect(result[:success]).to be true
        expect(character_instance.reload.stance).to eq('standing')
        expect(character_instance.reload.current_place_id).to eq(bar.id)
      end

      it 'uses text preposition when given' do
        result = command.execute('stand near window')
        expect(result[:success]).to be true
        expect(result[:message]).to include('stand near large window')
      end

      it 'uses default preposition at when none specified' do
        result = command.execute('stand bar')
        expect(result[:success]).to be true
        expect(result[:message]).to include('stand at wooden bar')
      end
    end

    context 'dance aliases' do
      it 'handles "dance on stage"' do
        result = command.execute('dance on stage')
        expect(result[:success]).to be true
        expect(result[:message]).to include('stand on small stage')
        expect(character_instance.reload.stance).to eq('standing')
        expect(character_instance.reload.current_place_id).to eq(stage.id)
      end

      it 'handles "dance at bar"' do
        result = command.execute('dance at bar')
        expect(result[:success]).to be true
        expect(result[:message]).to include('stand at wooden bar')
        expect(character_instance.reload.current_place_id).to eq(bar.id)
      end

      it 'handles "dance" with explicit preposition' do
        result = command.execute('dance on stage')
        expect(result[:success]).to be true
        expect(character_instance.reload.current_place_id).to eq(stage.id)
      end
    end

    context 'pace aliases' do
      it 'handles "pace at window"' do
        result = command.execute('pace at window')
        expect(result[:success]).to be true
        expect(result[:message]).to include('stand at large window')
        expect(character_instance.reload.current_place_id).to eq(window.id)
      end

      it 'handles "pace on stage"' do
        result = command.execute('pace on stage')
        expect(result[:success]).to be true
        expect(character_instance.reload.current_place_id).to eq(stage.id)
      end

      it 'handles "pace" with explicit preposition in text' do
        result = command.execute('pace by window')
        expect(result[:success]).to be true
        expect(result[:message]).to include('stand by large window')
      end
    end

    context 'already standing but moving to furniture' do
      before do
        character_instance.update(stance: 'standing', current_place_id: nil)
      end

      it 'moves to furniture when already standing' do
        result = command.execute('stand at bar')
        expect(result[:success]).to be true
        expect(character_instance.reload.current_place_id).to eq(bar.id)
      end

      it 'errors when already standing at the same place' do
        character_instance.update(current_place_id: bar.id)
        result = command.execute('stand at bar')
        expect(result[:success]).to be false
        expect(result[:error]).to include('already standing at wooden bar')
      end

      it 'allows moving from one place to another' do
        character_instance.update(current_place_id: bar.id)
        result = command.execute('stand at window')
        expect(result[:success]).to be true
        expect(character_instance.reload.current_place_id).to eq(window.id)
      end
    end

    context 'from sitting at furniture to standing at different furniture' do
      before do
        character_instance.update(stance: 'sitting', current_place_id: couch.id)
      end

      it 'changes from sitting on couch to standing at bar' do
        result = command.execute('stand at bar')
        expect(result[:success]).to be true
        expect(character_instance.reload.stance).to eq('standing')
        expect(character_instance.reload.current_place_id).to eq(bar.id)
        expect(result[:data][:previous_stance]).to eq('sitting')
        expect(result[:data][:previous_place]).to eq('comfortable couch')
      end
    end

    context 'furniture not found' do
      it 'returns error when furniture does not exist' do
        result = command.execute('stand at nonexistent table')
        expect(result[:success]).to be false
        expect(result[:error]).to include("don't see 'nonexistent table'")
      end
    end

    context 'capacity errors' do
      let!(:full_place) do
        Place.create(
          room: room,
          name: 'tiny pedestal',
          is_furniture: true,
          default_sit_action: 'on',
          capacity: 0
        )
      end

      it 'returns error when place is full' do
        result = command.execute('stand at pedestal')
        expect(result[:success]).to be false
        expect(result[:error]).to include('no room')
      end
    end
  end
end
