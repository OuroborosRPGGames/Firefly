# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Communication::Reply, type: :command do
  let(:room) { create(:room) }
  let(:other_room) { create(:room) }
  let(:reality) { create(:reality) }
  let(:user1) { create(:user) }
  let(:user2) { create(:user) }
  let(:character) { create(:character, forename: 'Alice', user: user1) }
  let(:character_instance) { create(:character_instance, character: character, current_room: room, reality: reality, online: true) }
  let(:target_character) { create(:character, forename: 'Bob', user: user2) }
  let(:target_instance) { create(:character_instance, character: target_character, current_room: other_room, reality: reality, online: true) }

  before do
    GameSetting.set('time_period', 'modern', type: 'string')
    create(:item, name: 'mobile phone', is_phone: true, character_instance: character_instance)
  end

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'with no recent messages' do
      it 'returns error' do
        result = command.execute('reply')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/no one has messaged you/i)
      end
    end

    context 'after receiving an OOC message' do
      before do
        target_instance
        character_instance.this.update(
          last_ooc_sender_character_id: target_character.id,
          last_ooc_sender_at: Time.now
        )
        character_instance.refresh
      end

      it 'sets OOC mode with sender as target' do
        result = command.execute('reply')

        expect(result[:success]).to be true
        expect(result[:message]).to match(/ooc mode set/i)
        expect(result[:message]).to include('Bob')

        character_instance.reload
        expect(character_instance.messaging_mode).to eq('ooc')
        expect(character_instance.ooc_target_names).to eq('Bob')
        expect(character_instance.current_ooc_target_ids.to_a).to include(user2.id)
      end

      it 'sends OOC message when text provided' do
        result = command.execute('reply Got your message!')

        expect(result[:success]).to be true
        expect(result[:message]).to include('OOC to Bob')
        expect(result[:message]).to include('Got your message!')

        character_instance.reload
        expect(character_instance.messaging_mode).to eq('ooc')
      end
    end

    context 'after receiving a MSG' do
      before do
        target_instance
        character_instance.this.update(
          last_msg_sender_character_id: target_character.id,
          last_msg_sender_at: Time.now
        )
        character_instance.refresh
      end

      it 'sets MSG mode with sender as target' do
        result = command.execute('reply')

        expect(result[:success]).to be true
        expect(result[:message]).to match(/msg mode set/i)
        expect(result[:message]).to include('Bob')

        character_instance.reload
        expect(character_instance.messaging_mode).to eq('msg')
        expect(character_instance.msg_target_names).to eq('Bob')
        expect(character_instance.msg_target_character_ids.to_a).to include(target_character.id)
      end

      it 'sends MSG when text provided' do
        expect {
          result = command.execute('reply On my way!')
          expect(result[:success]).to be true
        }.to change { DirectMessage.count }.by(1)

        character_instance.reload
        expect(character_instance.messaging_mode).to eq('msg')
      end
    end

    context 'with both OOC and MSG senders' do
      before { target_instance }

      it 'targets MSG sender when MSG is more recent' do
        character_instance.this.update(
          last_ooc_sender_character_id: target_character.id,
          last_ooc_sender_at: Time.now - 60,
          last_msg_sender_character_id: target_character.id,
          last_msg_sender_at: Time.now
        )
        character_instance.refresh

        result = command.execute('reply')

        expect(result[:success]).to be true
        character_instance.reload
        expect(character_instance.messaging_mode).to eq('msg')
      end

      it 'targets OOC sender when OOC is more recent' do
        character_instance.this.update(
          last_ooc_sender_character_id: target_character.id,
          last_ooc_sender_at: Time.now,
          last_msg_sender_character_id: target_character.id,
          last_msg_sender_at: Time.now - 60
        )
        character_instance.refresh

        result = command.execute('reply')

        expect(result[:success]).to be true
        character_instance.reload
        expect(character_instance.messaging_mode).to eq('ooc')
      end
    end

    context 'with respond alias' do
      before do
        target_instance
        character_instance.this.update(
          last_ooc_sender_character_id: target_character.id,
          last_ooc_sender_at: Time.now
        )
        character_instance.refresh
      end

      it 'works with respond alias' do
        result = command.execute('respond')

        expect(result[:success]).to be true
        expect(result[:message]).to match(/ooc mode set/i)
      end
    end
  end

  describe 'command metadata' do
    it 'has correct command name' do
      expect(described_class.command_name).to eq('reply')
    end

    it 'has correct aliases' do
      expect(described_class.alias_names).to include('respond')
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
