# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Posture::Sit, type: :command do
  let(:user) { create(:user) }
  let(:character) { create(:character, forename: 'Test', surname: 'Char', user: user) }
  let(:room) { create(:room, name: 'Test Room', short_description: 'A room') }
  let(:character_instance) { create(:character_instance, character: character, current_room: room, stance: 'standing') }

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
      name: 'bar',
      is_furniture: true,
      default_sit_action: 'at',
      capacity: 6
    )
  end

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'sit on ground' do
      it 'changes stance to sitting' do
        result = command.execute('sit')
        expect(result[:success]).to be true
        expect(result[:message]).to include('You sit down')
        expect(character_instance.reload.stance).to eq('sitting')
      end

      it 'handles "sit down"' do
        result = command.execute('sit down')
        expect(result[:success]).to be true
        expect(character_instance.reload.stance).to eq('sitting')
      end

      it 'clears current place when sitting on ground' do
        character_instance.update(current_place_id: couch.id)
        result = command.execute('sit down')
        expect(result[:success]).to be true
        expect(character_instance.reload.current_place_id).to be_nil
      end
    end

    context 'sit on furniture' do
      it 'sits on furniture with explicit preposition' do
        result = command.execute('sit on couch')
        expect(result[:success]).to be true
        expect(result[:message]).to include('on')
        expect(result[:message]).to include('couch')
        expect(character_instance.reload.current_place_id).to eq(couch.id)
        expect(character_instance.reload.stance).to eq('sitting')
      end

      it 'uses furniture default_sit_action' do
        result = command.execute('sit bar')
        expect(result[:success]).to be true
        expect(result[:message]).to include('at bar')
      end

      it 'handles partial furniture names' do
        result = command.execute('sit couc')
        expect(result[:success]).to be true
        expect(character_instance.reload.current_place_id).to eq(couch.id)
      end

      it 'handles "sit at" preposition' do
        result = command.execute('sit at bar')
        expect(result[:success]).to be true
        expect(result[:message]).to include('at bar')
      end

      it 'handles "sit in" preposition' do
        booth = Place.create(room: room, name: 'booth', is_furniture: true, default_sit_action: 'in', capacity: 4)
        result = command.execute('sit in booth')
        expect(result[:success]).to be true
        expect(result[:message]).to include('in booth')
      end
    end

    context 'error cases' do
      it 'errors when already sitting' do
        character_instance.update(stance: 'sitting')
        result = command.execute('sit')
        expect(result[:success]).to be false
        expect(result[:error]).to include('already sitting')
      end

      it 'errors when furniture not found' do
        result = command.execute('sit on throne')
        expect(result[:success]).to be false
        expect(result[:error]).to include("don't see")
      end

      it 'errors when furniture is full' do
        couch.update(capacity: 0)
        result = command.execute('sit on couch')
        expect(result[:success]).to be false
        expect(result[:error]).to include('no room')
      end
    end
  end
end
