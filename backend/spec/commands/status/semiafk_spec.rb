# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Status::Semiafk, type: :command do
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

    context 'setting semi-AFK without duration' do
      it 'sets semi-AFK status indefinitely' do
        result = command.execute('semiafk')
        expect(result[:success]).to be true
        expect(result[:message]).to include('now semi-AFK')
        expect(character_instance.reload.semiafk?).to be true
        expect(character_instance.semiafk_until).to be_nil
      end

      it 'clears full AFK when setting semi-AFK' do
        character_instance.set_afk!(30)
        command.execute('semiafk')
        expect(character_instance.reload.semiafk?).to be true
        expect(character_instance.afk?).to be false
      end
    end

    context 'setting semi-AFK with duration' do
      it 'sets semi-AFK status for specified minutes' do
        result = command.execute('semiafk 30')
        expect(result[:success]).to be true
        expect(result[:message]).to include('30 minutes')
        expect(character_instance.reload.semiafk?).to be true
        expect(character_instance.semiafk_until).to be_within(5).of(Time.now + 30 * 60)
      end

      it 'returns duration in data' do
        result = command.execute('semiafk 15')
        expect(result[:data][:duration_minutes]).to eq(15)
      end
    end

    context 'clearing semi-AFK' do
      before do
        character_instance.set_semiafk!(30)
      end

      it 'clears semi-AFK when already semi-AFK' do
        result = command.execute('semiafk')
        expect(result[:success]).to be true
        expect(result[:message]).to include('no longer semi-AFK')
        expect(character_instance.reload.semiafk?).to be false
        expect(character_instance.semiafk_until).to be_nil
      end
    end

    context 'broadcast messages' do
      it 'broadcasts when setting semi-AFK indefinitely' do
        expect(BroadcastService).to receive(:to_room).with(
          room.id,
          "Alice Test gets distracted by their phone. [Semi-AFK Indefinite]",
          hash_including(exclude: [character_instance.id], type: :status)
        )
        command.execute('semiafk')
      end

      it 'broadcasts when setting semi-AFK with duration' do
        expect(BroadcastService).to receive(:to_room).with(
          room.id,
          "Alice Test gets distracted by their phone. [Semi-AFK 30 Minutes]",
          hash_including(exclude: [character_instance.id], type: :status)
        )
        command.execute('semiafk 30')
      end

      it 'broadcasts when clearing semi-AFK' do
        character_instance.set_semiafk!
        expect(BroadcastService).to receive(:to_room).with(
          room.id,
          "Alice Test refocuses as they put away their phone. [Semi-AFK removed]",
          hash_including(exclude: [character_instance.id], type: :status)
        )
        command.execute('semiafk')
      end
    end
  end
end
