# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Communication::Pemit, type: :command do
  let(:room) { create(:room) }
  let(:reality) { create(:reality) }
  let(:user) { create(:user) }
  let(:character) { create(:character, forename: 'Alice', user: user) }
  let(:character_instance) { create(:character_instance, character: character, current_room: room, reality: reality, online: true) }
  let(:target_character) { create(:character, forename: 'Bob') }
  let(:target_instance) { create(:character_instance, character: target_character, current_room: room, reality: reality, online: true) }

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'without staff permissions' do
      before { target_instance }

      it 'returns permission error' do
        result = command.execute('pemit Bob A chill runs down your spine.')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/don't have permission/i)
      end
    end

    context 'with staff permissions' do
      before do
        user.update(is_admin: true)
        target_instance
      end

      it 'sends emit to target' do
        result = command.execute('pemit Bob A chill runs down your spine.')

        expect(result[:success]).to be true
        expect(result[:type]).to eq(:pemit)
        expect(result[:data][:targets]).to eq(target_character.full_name)
      end

      it 'sends to multiple targets using = separator' do
        second_target = create(:character, forename: 'Charlie')
        create(:character_instance, character: second_target, current_room: room, reality: reality, online: true)

        result = command.execute('pemit Bob, Charlie = You both feel something.')

        expect(result[:success]).to be true
        expect(result[:data][:target_count]).to eq(2)
      end

      it 'backward compat: works with = separator' do
        result = command.execute('pemit Bob = A chill runs down your spine.')

        expect(result[:success]).to be true
        expect(result[:type]).to eq(:pemit)
        expect(result[:data][:targets]).to eq(target_character.full_name)
      end
    end

    context 'with admin permissions' do
      before do
        user.update(is_admin: true)
        target_instance
      end

      it 'allows pemit' do
        result = command.execute('pemit Bob Test message')

        expect(result[:success]).to be true
      end
    end

    context 'with invalid input' do
      before do
        user.update(is_admin: true)
        target_instance
      end

      it 'returns error for empty input' do
        result = command.execute('pemit')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/usage/i)
      end

      it 'returns error for unknown target' do
        result = command.execute('pemit Nobody Hello')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/none of those characters/i)
      end

      it 'returns error for empty message with = separator' do
        result = command.execute('pemit Bob = ')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/what did you want to emit/i)
      end
    end

    context 'with aliases' do
      before do
        user.update(is_admin: true)
        target_instance
      end

      it 'works with emit to alias' do
        result = command.execute('emit to Bob Hello!')

        expect(result[:success]).to be true
      end

      it 'works with semit alias' do
        result = command.execute('semit Bob Hello!')

        expect(result[:success]).to be true
      end
    end
  end
end
