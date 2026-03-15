# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Communication::Msg, type: :command do
  let(:room) { create(:room) }
  let(:other_room) { create(:room) }
  let(:reality) { create(:reality) }
  let(:character) { create(:character, forename: 'Alice') }
  let(:character_instance) { create(:character_instance, character: character, current_room: room, reality: reality, online: true) }
  let(:target_character) { create(:character, forename: 'Bob') }
  let(:target_instance) { create(:character_instance, character: target_character, current_room: other_room, reality: reality, online: true) }

  # Set era to modern (instant messaging)
  before do
    GameSetting.set('time_period', 'modern', type: 'string')
    # Modern era requires a phone for DMs
    create(:item, name: 'mobile phone', is_phone: true, character_instance: character_instance)
  end

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'with valid target and message' do
      before { target_instance }

      it 'sends message to online recipient' do
        result = command.execute('msg Bob Hey, where are you?')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Bob')
        expect(result[:message]).to include('Hey, where are you?')
      end

      it 'creates DirectMessage record' do
        expect {
          command.execute('msg Bob Hello!')
        }.to change { DirectMessage.count }.by(1)

        dm = DirectMessage.last
        expect(dm.sender_id).to eq(character.id)
        expect(dm.recipient_id).to eq(target_character.id)
        expect(dm.content).to eq('Hello!')
      end

      it 'marks message as delivered when recipient is online' do
        command.execute('msg Bob Online test')

        dm = DirectMessage.last
        expect(dm.delivered?).to be true
      end

      it 'returns message type in result' do
        result = command.execute('msg Bob Testing type')

        expect(result[:type]).to eq(:message)
      end
    end

    context 'when recipient is offline' do
      before do
        target_instance.update(online: false)
      end

      it 'stores message for later delivery' do
        result = command.execute('msg Bob See you later!')

        expect(result[:success]).to be true
        expect(result[:message]).to include('offline')

        dm = DirectMessage.last
        expect(dm.delivered?).to be false
      end
    end

    context 'with no target specified' do
      it 'returns error' do
        result = command.execute('msg')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/who do you want to message/i)
      end
    end

    context 'with no message (set target only)' do
      before { target_instance }

      it 'sets MSG mode and confirms' do
        result = command.execute('msg Bob')

        expect(result[:success]).to be true
        expect(result[:message]).to match(/msg mode set/i)
        expect(result[:message]).to include('Bob')
      end

      it 'persists messaging_mode as msg' do
        command.execute('msg Bob')
        character_instance.reload

        expect(character_instance.messaging_mode).to eq('msg')
        expect(character_instance.msg_target_names).to eq('Bob')
        expect(character_instance.last_channel_name).to eq('msg')
      end

      it 'sets msg_target_character_ids' do
        command.execute('msg Bob')
        character_instance.reload

        expect(character_instance.msg_target_character_ids.to_a).to include(target_character.id)
      end
    end

    context 'with unknown target' do
      it 'returns error' do
        result = command.execute('msg Nobody Hello!')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/could not find anyone/i)
      end
    end

    context 'with self as target' do
      it 'returns error' do
        result = command.execute('msg Alice Hello me!')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/yourself/i)
      end
    end

    context 'with aliases' do
      before { target_instance }

      it 'works with dm alias' do
        result = command.execute('dm Bob Hello via dm!')

        expect(result[:success]).to be true
      end

      it 'works with text alias' do
        result = command.execute('text Bob Hello via text!')

        expect(result[:success]).to be true
      end
    end
  end

  # Note: MessengerService (era-based delayed messaging) was removed
  # All eras now use direct DM delivery

  describe 'command metadata' do
    it 'has correct command name' do
      expect(described_class.command_name).to eq('msg')
    end

    it 'has correct aliases' do
      expect(described_class.alias_names).to include('dm')
      expect(described_class.alias_names).to include('text')
    end

    it 'has correct category' do
      expect(described_class.category).to eq(:communication)
    end

    it 'has help text' do
      expect(described_class.help_text).to be_a(String)
      expect(described_class.help_text.length).to be > 0
    end
  end
end
