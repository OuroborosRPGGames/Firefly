# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Communication::Attempt, type: :command do
  let(:user) { create(:user) }
  let(:character) { create(:character, forename: 'Alice', surname: 'Test', user: user) }
  let(:room) { create(:room, name: 'Test Room', short_description: 'A room') }
  let(:reality) { create(:reality) }
  let(:character_instance) { create(:character_instance, character: character, current_room: room, reality: reality, stance: 'standing') }

  let(:user2) { create(:user) }
  let(:bob_character) { create(:character, forename: 'Bob', surname: 'Smith', user: user2) }
  let!(:bob_instance) { create(:character_instance, character: bob_character, current_room: room, reality: reality, stance: 'standing') }

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'submitting an attempt' do
      it 'submits an attempt to the target' do
        result = command.execute('attempt Bob hugs warmly')
        expect(result[:success]).to be true
        expect(result[:message]).to include('Bob Smith')
        expect(result[:message]).to include('hugs warmly')
      end

      it 'sets attempt fields on the requester' do
        command.execute('attempt Bob hugs warmly')
        character_instance.reload
        expect(character_instance.attempt_text).to eq('hugs warmly')
        expect(character_instance.attempt_target_id).to eq(bob_instance.id)
      end

      it 'sets pending attempt fields on the target' do
        command.execute('attempt Bob hugs warmly')
        bob_instance.reload
        expect(bob_instance.pending_attempter_id).to eq(character_instance.id)
        expect(bob_instance.pending_attempt_text).to eq('hugs warmly')
        expect(bob_instance.pending_attempt_at).not_to be_nil
      end
    end

    context 'error cases' do
      it 'returns error without arguments' do
        result = command.execute('attempt')
        expect(result[:success]).to be false
        expect(result[:message]).to include('Usage')
      end

      it 'returns error without action text' do
        result = command.execute('attempt Bob')
        expect(result[:success]).to be false
        expect(result[:message]).to include('What do you want to attempt')
      end

      it 'returns error for unknown target' do
        result = command.execute('attempt Nobody hugs')
        expect(result[:success]).to be false
        expect(result[:message]).to include("Nobody")
      end

      it 'returns error when attempting on self' do
        result = command.execute('attempt Alice hugs self')
        expect(result[:success]).to be false
        expect(result[:message]).to include("yourself")
      end

      it 'returns error when target has pending attempt' do
        bob_instance.update(pending_attempter_id: 999, pending_attempt_text: 'something')
        result = command.execute('attempt Bob hugs')
        expect(result[:success]).to be false
        expect(result[:message]).to include('already has a pending')
      end

      it 'returns error when requester has pending attempt' do
        character_instance.update(attempt_target_id: 999)
        result = command.execute('attempt Bob hugs')
        expect(result[:success]).to be false
        expect(result[:message]).to include('already have a pending')
      end
    end

    context 'fuzzy matching' do
      it 'finds target by prefix' do
        result = command.execute('attempt Bo hugs')
        expect(result[:success]).to be true
        expect(result[:data][:target_id]).to eq(bob_instance.id)
      end
    end
  end
end
