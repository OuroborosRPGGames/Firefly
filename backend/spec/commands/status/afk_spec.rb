# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Status::Afk, type: :command do
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

    context 'setting AFK' do
      it 'sets AFK status without timer' do
        result = command.execute('afk')
        expect(result[:success]).to be true
        expect(result[:message]).to include('now AFK')
        expect(character_instance.reload.afk?).to be true
        expect(character_instance.afk_until).to be_nil
      end

      it 'sets AFK status with timer' do
        result = command.execute('afk 30')
        expect(result[:success]).to be true
        expect(result[:message]).to include('30 minutes')
        expect(character_instance.reload.afk?).to be true
        expect(character_instance.afk_until).to be_within(5).of(Time.now + 30 * 60)
      end

      it 'clears semiafk when setting afk' do
        character_instance.update(semiafk: true)
        command.execute('afk')
        expect(character_instance.reload.semiafk?).to be false
        expect(character_instance.afk?).to be true
      end
    end

    context 'clearing AFK' do
      before do
        character_instance.set_afk!(30)
      end

      it 'clears AFK status when already AFK' do
        result = command.execute('afk')
        expect(result[:success]).to be true
        expect(result[:message]).to include('no longer AFK')
        expect(character_instance.reload.afk?).to be false
        expect(character_instance.afk_until).to be_nil
      end
    end

    describe 'clear_afk! clears afk state' do
      it 'clears afk and semiafk together' do
        # afk and semiafk are mutually exclusive - setting one clears the other
        # clear_afk! resets both to ensure a clean state
        character_instance.this.update(afk: true, afk_until: nil)
        character_instance.refresh

        character_instance.clear_afk!
        character_instance.refresh

        expect(character_instance.afk?).to be false
        expect(character_instance.semiafk?).to be false
      end
    end

    context 'caps minutes' do
      it 'caps minutes at 1000' do
        result = command.execute('afk 9999')
        expect(result[:success]).to be true
        expect(character_instance.reload.afk_until).to be_within(5).of(Time.now + 1000 * 60)
      end

      it 'ignores non-positive minutes' do
        result = command.execute('afk -5')
        expect(result[:success]).to be true
        expect(character_instance.reload.afk_until).to be_nil
      end
    end
  end
end
