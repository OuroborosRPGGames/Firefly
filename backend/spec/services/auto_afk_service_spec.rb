# frozen_string_literal: true

require 'spec_helper'

RSpec.describe AutoAfkService do
  # Helper for time calculations (minutes to seconds)
  def minutes(n)
    n * 60
  end

  let(:reality) { create(:reality) }
  let(:room) { create(:room) }
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }
  let(:character_instance) do
    create(:character_instance,
           character: character,
           reality: reality,
           current_room: room,
           online: true,
           afk: false,
           last_activity: Time.now,
           last_websocket_ping: Time.now)
  end

  describe '.process_idle_characters!' do
    context 'with active character' do
      it 'does not mark recently active character as AFK' do
        character_instance.update(last_activity: Time.now)

        results = described_class.process_idle_characters!

        expect(character_instance.reload.afk?).to be false
        expect(results[:afk]).to eq(0)
      end
    end

    context 'with character alone in room for 60+ minutes' do
      it 'marks character as AFK' do
        character_instance.update(last_activity: Time.now - minutes(61))

        results = described_class.process_idle_characters!

        expect(character_instance.reload.afk?).to be true
        expect(results[:afk]).to eq(1)
      end
    end

    context 'with character alone for less than 60 minutes' do
      it 'does not mark character as AFK' do
        character_instance.update(last_activity: Time.now - minutes(30))

        results = described_class.process_idle_characters!

        expect(character_instance.reload.afk?).to be false
        expect(results[:afk]).to eq(0)
      end
    end

    context 'with character in room with others for 17+ minutes' do
      let(:other_character) { create(:character) }
      let!(:other_instance) do
        create(:character_instance,
               character: other_character,
               reality: reality,
               current_room: room,
               online: true,
               last_activity: Time.now,
               last_websocket_ping: Time.now)
      end

      it 'marks character as AFK after 17 minutes' do
        # Ensure our character_instance is created and updated
        character_instance.update(
          last_activity: Time.now - minutes(18),
          last_websocket_ping: Time.now
        )

        results = described_class.process_idle_characters!

        expect(character_instance.reload.afk?).to be true
        expect(results[:afk]).to eq(1)
      end

      it 'does not mark character as AFK before 17 minutes' do
        character_instance.update(last_activity: Time.now - minutes(10))

        results = described_class.process_idle_characters!

        expect(character_instance.reload.afk?).to be false
        expect(results[:afk]).to eq(0)
      end
    end

    context 'with agent (API token user)' do
      before do
        user.generate_api_token!
      end

      it 'logs out agent after 120 minutes of inactivity' do
        character_instance.update(last_activity: Time.now - minutes(121))

        results = described_class.process_idle_characters!

        expect(character_instance.reload.online).to be false
        expect(results[:disconnected]).to eq(1)
      end

      it 'does not log out agent before 120 minutes' do
        character_instance.update(last_activity: Time.now - minutes(60))

        results = described_class.process_idle_characters!

        expect(character_instance.reload.online).to be true
        expect(results[:disconnected]).to eq(0)
      end
    end

    context 'with hard disconnect timeout (180 minutes)' do
      it 'force logs out player after 180 minutes' do
        character_instance.update(last_activity: Time.now - minutes(181))

        results = described_class.process_idle_characters!

        expect(character_instance.reload.online).to be false
        expect(results[:disconnected]).to eq(1)
      end
    end

    context 'with stale WebSocket connection' do
      it 'disconnects character with no ping for 5+ minutes' do
        character_instance.update(
          last_activity: Time.now,
          last_websocket_ping: Time.now - minutes(6)
        )

        results = described_class.process_idle_characters!

        expect(character_instance.reload.online).to be false
        expect(results[:disconnected]).to eq(1)
      end

      it 'does not disconnect character with recent ping' do
        character_instance.update(
          last_activity: Time.now - minutes(10),
          last_websocket_ping: Time.now - minutes(2)
        )

        results = described_class.process_idle_characters!

        # Should mark AFK but not disconnect
        expect(character_instance.reload.online).to be true
      end
    end

    context 'with exempt character' do
      it 'skips staff characters' do
        # Use database update to bypass validation that requires user permission
        DB[:characters].where(id: character.id).update(is_staff_character: true)
        character_instance.update(last_activity: Time.now - minutes(200))

        results = described_class.process_idle_characters!

        expect(character_instance.reload.online).to be true
        expect(results[:skipped]).to eq(1)
      end

      it 'skips explicitly exempt characters' do
        character_instance.update(
          auto_afk_exempt: true,
          last_activity: Time.now - minutes(200)
        )

        results = described_class.process_idle_characters!

        expect(character_instance.reload.online).to be true
        expect(results[:skipped]).to eq(1)
      end
    end

    context 'with already AFK character' do
      it 'does not re-process AFK status' do
        character_instance.update(
          afk: true,
          last_activity: Time.now - minutes(30)
        )

        # Should skip since already AFK
        results = described_class.process_idle_characters!

        expect(results[:afk]).to eq(0)
      end

      it 'still disconnects AFK character after hard timeout' do
        character_instance.update(
          afk: true,
          last_activity: Time.now - minutes(181)
        )

        results = described_class.process_idle_characters!

        expect(character_instance.reload.online).to be false
        expect(results[:disconnected]).to eq(1)
      end
    end

    context 'with semi-AFK character' do
      it 'does not upgrade semi-AFK to AFK' do
        character_instance.update(
          semiafk: true,
          last_activity: Time.now - minutes(61)
        )

        results = described_class.process_idle_characters!

        character_instance.reload
        expect(character_instance.afk?).to be false
        expect(character_instance.semiafk?).to be true
        expect(results[:afk]).to eq(0)
      end

      it 'still disconnects semi-AFK character after hard timeout' do
        character_instance.update(
          semiafk: true,
          last_activity: Time.now - minutes(181)
        )

        results = described_class.process_idle_characters!

        expect(character_instance.reload.online).to be false
        expect(results[:disconnected]).to eq(1)
      end
    end

    context 'with GTG character' do
      it 'does not mark GTG character as AFK' do
        character_instance.update(
          gtg_until: Time.now + minutes(15),
          last_activity: Time.now - minutes(61)
        )

        results = described_class.process_idle_characters!

        character_instance.reload
        expect(character_instance.afk?).to be false
        expect(character_instance.gtg?).to be true
        expect(results[:afk]).to eq(0)
      end

      it 'still disconnects GTG character after hard timeout' do
        character_instance.update(
          gtg_until: Time.now + minutes(15),
          last_activity: Time.now - minutes(181)
        )

        results = described_class.process_idle_characters!

        expect(character_instance.reload.online).to be false
        expect(results[:disconnected]).to eq(1)
      end
    end
  end
end
