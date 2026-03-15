# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Communication::Ooc, type: :command do
  let(:room) { create(:room) }
  let(:other_room) { create(:room) }
  let(:reality) { create(:reality) }
  let(:user1) { create(:user) }
  let(:user2) { create(:user) }
  let(:user3) { create(:user) }
  let(:character) { create(:character, forename: 'Alice', user: user1) }
  let(:character_instance) { create(:character_instance, character: character, current_room: room, reality: reality, online: true) }
  let(:target_character) { create(:character, forename: 'Bob', user: user2) }
  let(:target_instance) { create(:character_instance, character: target_character, current_room: other_room, reality: reality, online: true) }
  let(:third_character) { create(:character, forename: 'Charlie', user: user3) }
  let(:third_instance) { create(:character_instance, character: third_character, current_room: other_room, reality: reality, online: true) }

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'with valid target and message' do
      before { target_instance }

      it 'sends OOC message to online recipient' do
        result = command.execute('ooc Bob Hello there!')

        expect(result[:success]).to be true
        expect(result[:message]).to include('OOC to Bob')
        expect(result[:message]).to include('Hello there!')
      end

      it 'creates OocMessage record' do
        expect {
          command.execute('ooc Bob Hello!')
        }.to change { OocMessage.count }.by(1)

        msg = OocMessage.last
        expect(msg.sender_user_id).to eq(user1.id)
        expect(msg.recipient_user_id).to eq(user2.id)
        expect(msg.content).to eq('Hello!')
      end

      it 'marks message as delivered when recipient is online' do
        command.execute('ooc Bob Online test')

        msg = OocMessage.last
        expect(msg.delivered?).to be true
      end

      it 'returns message type in result' do
        result = command.execute('ooc Bob Testing type')

        expect(result[:type]).to eq(:message)
      end

      it 'includes recipient data in result' do
        result = command.execute('ooc Bob Testing data')

        expect(result[:data][:recipient_names]).to include('Bob')
        expect(result[:data][:sent_count]).to eq(1)
      end

      it 'persists messaging_mode when sending with message' do
        command.execute('ooc Bob Hello there!')
        character_instance.reload

        expect(character_instance.messaging_mode).to eq('ooc')
        expect(character_instance.ooc_target_names).to eq('Bob')
      end
    end

    context 'with multiple recipients' do
      before do
        target_instance
        third_instance
      end

      it 'sends OOC message to multiple recipients' do
        result = command.execute('ooc Bob,Charlie Hello everyone!')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Bob')
        expect(result[:message]).to include('Charlie')
        expect(result[:data][:sent_count]).to eq(2)
      end

      it 'creates multiple OocMessage records' do
        expect {
          command.execute('ooc Bob,Charlie Hi all!')
        }.to change { OocMessage.count }.by(2)
      end
    end

    context 'when recipient is offline' do
      before do
        target_instance.update(online: false)
      end

      it 'stores message for later delivery' do
        result = command.execute('ooc Bob See you later!')

        expect(result[:success]).to be true

        msg = OocMessage.last
        expect(msg.delivered?).to be false
      end
    end

    context 'with no arguments' do
      it 'shows recent OOC contacts or usage info' do
        result = command.execute('ooc')

        # When no recent contacts, shows usage
        expect(result[:success]).to be false
        expect(result[:error]).to match(/usage|ooc contacts/i)
      end
    end

    context 'with no message (set target only)' do
      before { target_instance }

      it 'sets OOC mode and confirms' do
        result = command.execute('ooc Bob')

        expect(result[:success]).to be true
        expect(result[:message]).to match(/ooc mode set/i)
        expect(result[:message]).to include('Bob')
      end

      it 'persists messaging_mode as ooc' do
        command.execute('ooc Bob')
        character_instance.reload

        expect(character_instance.messaging_mode).to eq('ooc')
        expect(character_instance.ooc_target_names).to eq('Bob')
        expect(character_instance.last_channel_name).to eq('ooc')
      end

      it 'sets current_ooc_target_ids' do
        command.execute('ooc Bob')
        character_instance.reload

        expect(character_instance.current_ooc_target_ids.to_a).to include(user2.id)
      end
    end

    context 'with unknown target' do
      it 'returns error' do
        result = command.execute('ooc Nobody Hello!')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/could not find/i)
      end
    end

    context 'with self as target' do
      it 'returns error' do
        result = command.execute('ooc Alice Hello me!')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/yourself/i)
      end
    end

    context 'when recipient has OOC messaging blocked' do
      before do
        target_instance
        # Set Bob's generic permission to block OOC from everyone
        UserPermission.generic_for(user2).update(ooc_messaging: 'no')
        # Create specific permission for user1 with 'no'
        UserPermission.specific_for(user2, user1).update(ooc_messaging: 'no')
      end

      it 'returns blocked error' do
        result = command.execute('ooc Bob Hello!')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/blocked/i)
      end
    end

    context 'when recipient requires OOC request' do
      before do
        target_instance
        # Set Bob's permission to require OOC request
        UserPermission.generic_for(user2).update(ooc_messaging: 'ask')
      end

      it 'returns request required error' do
        result = command.execute('ooc Bob Hello!')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/oocrequest/i)
      end

      context 'when OOC request has been accepted' do
        before do
          OocRequest.create(
            sender_user_id: user1.id,
            target_user_id: user2.id,
            sender_character_id: character.id,
            message: 'Can we chat?',
            status: 'accepted'
          )
        end

        it 'allows message' do
          result = command.execute('ooc Bob Hello!')

          expect(result[:success]).to be true
        end
      end
    end

    context 'with aliases' do
      before { target_instance }

      it 'works with oocp alias' do
        result = command.execute('oocp Bob Hello via oocp!')

        expect(result[:success]).to be true
      end

      it 'works with oocmsg alias' do
        result = command.execute('oocmsg Bob Hello via oocmsg!')

        expect(result[:success]).to be true
      end
    end
  end

  describe 'command metadata' do
    it 'has correct command name' do
      expect(described_class.command_name).to eq('ooc')
    end

    it 'has correct aliases' do
      expect(described_class.alias_names).to include('oocp')
      expect(described_class.alias_names).to include('oocmsg')
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
