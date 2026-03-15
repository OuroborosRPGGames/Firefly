# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Posture::Lie, type: :command do
  let(:user) { create(:user) }
  let(:character) { create(:character, forename: 'Test', surname: 'Char', user: user) }
  let(:room) { create(:room, name: 'Test Room', short_description: 'A room') }
  let(:character_instance) { create(:character_instance, character: character, current_room: room, stance: 'standing') }

  let!(:bed) do
    Place.create(
      room: room,
      name: 'comfortable bed',
      is_furniture: true,
      default_sit_action: 'on',
      capacity: 2
    )
  end

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'lie on ground' do
      it 'changes stance to lying' do
        result = command.execute('lie down')
        expect(result[:success]).to be true
        expect(result[:message]).to include('You lie down')
        expect(character_instance.reload.stance).to eq('lying')
      end

      it 'handles "lay down" alias' do
        result = command.execute('lay down')
        expect(result[:success]).to be true
        expect(character_instance.reload.stance).to eq('lying')
      end
    end

    context 'lie on furniture' do
      it 'lies on furniture' do
        result = command.execute('lie on bed')
        expect(result[:success]).to be true
        expect(result[:message]).to include('bed')
        expect(character_instance.reload.current_place_id).to eq(bed.id)
        expect(character_instance.reload.stance).to eq('lying')
      end
    end

    context 'error cases' do
      it 'errors when already lying' do
        character_instance.update(stance: 'lying')
        result = command.execute('lie down')
        expect(result[:success]).to be false
        expect(result[:error]).to include('already lying')
      end

      it 'errors when furniture not found' do
        result = command.execute('lie on throne')
        expect(result[:success]).to be false
        expect(result[:error]).to include("don't see")
      end

      it 'errors when furniture is full' do
        bed.update(capacity: 0)
        result = command.execute('lie on bed')
        expect(result[:success]).to be false
        expect(result[:error]).to include('no room')
      end
    end
  end
end
