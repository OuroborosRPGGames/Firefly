# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Status::Gtg, type: :command do
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

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'setting GTG' do
      it 'sets GTG status with explicit timer' do
        result = command.execute('gtg 30')
        expect(result[:success]).to be true
        expect(result[:message]).to include('30 minutes')
        expect(character_instance.reload.gtg?).to be true
        expect(character_instance.gtg_until).to be_within(5).of(Time.now + 30 * 60)
      end

      it 'defaults to 15 minutes with invalid number' do
        result = command.execute('gtg abc')
        expect(result[:success]).to be true
        expect(result[:message]).to include('15 minutes')
        expect(character_instance.reload.gtg_until).to be_within(5).of(Time.now + 15 * 60)
      end
    end

    context 'clearing GTG' do
      before do
        character_instance.set_gtg!(30)
      end

      it 'clears GTG with empty command' do
        result = command.execute('gtg')
        expect(result[:success]).to be true
        expect(result[:message]).to include('cleared')
        expect(character_instance.reload.gtg?).to be false
      end
    end

    context 'no GTG to clear' do
      it 'returns error when no GTG status' do
        result = command.execute('gtg')
        expect(result[:success]).to be false
        expect(result[:message]).to match(/don.*t have GTG status/)
      end
    end
  end
end
