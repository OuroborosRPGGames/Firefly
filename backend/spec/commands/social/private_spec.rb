# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Social::Private, type: :command do
  let(:room) { create(:room) }
  let(:reality) { create(:reality) }
  let(:character) { create(:character, forename: 'Alice') }
  let(:character_instance) { create(:character_instance, character: character, current_room: room, reality: reality, private_mode: false, online: true) }
  let(:target_character) { create(:character, forename: 'Bob') }
  let(:target_instance) { create(:character_instance, character: target_character, current_room: room, reality: reality, online: true) }

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'when toggling private mode (no args)' do
      context 'when entering private mode' do
        it 'toggles private mode on' do
          expect(character_instance.private_mode?).to be false

          result = command.execute('private')

          expect(result[:success]).to be true
          expect(character_instance.reload.private_mode?).to be true
        end

        it 'returns confirmation message for entering private mode' do
          result = command.execute('private')

          expect(result[:message]).to include('private mode')
          expect(result[:message]).to include('visible')
        end

        it 'includes private_mode: true in data' do
          result = command.execute('private')

          expect(result[:data][:private_mode]).to be true
        end
      end

      context 'when leaving private mode' do
        before do
          character_instance.update(private_mode: true)
        end

        it 'toggles private mode off' do
          expect(character_instance.private_mode?).to be true

          result = command.execute('private')

          expect(result[:success]).to be true
          expect(character_instance.reload.private_mode?).to be false
        end

        it 'returns confirmation message for leaving private mode' do
          result = command.execute('private')

          expect(result[:message]).to include('left private mode')
          expect(result[:message]).to include('hidden')
        end

        it 'includes private_mode: false in data' do
          result = command.execute('private')

          expect(result[:data][:private_mode]).to be false
        end
      end
    end

    context 'when performing private emote' do
      before { target_instance }

      it 'sends private emote to target' do
        result = command.execute('private Bob winks knowingly')

        expect(result[:success]).to be true
        expect(result[:data][:type]).to eq('private_emote')
        expect(result[:target]).to eq(target_character.full_name)
      end

      it 'includes character name in emote' do
        result = command.execute('private Bob waves secretively')

        expect(result[:formatted_message]).to include(character.full_name)
        expect(result[:formatted_message]).to include('waves secretively')
      end

      it 'formats sender message with "[Private to Target]" superscript tag at end' do
        result = command.execute('private Bob nods subtly')

        expect(result[:formatted_message]).to match(/Private to.*Bob/i)
        expect(result[:formatted_message]).to include('<sup class="emote-tag">')
      end

      it 'works with "to" prefix syntax' do
        result = command.execute('private to Bob smiles slyly')

        expect(result[:success]).to be true
        expect(result[:target]).to eq(target_character.full_name)
      end

      it 'returns error when target not in room' do
        result = command.execute('private Nobody waves')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/don't see anyone/i)
      end

      it 'returns error when no emote text provided' do
        result = command.execute('private Bob')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/what do you want to do/i)
      end

      it 'returns error when targeting self' do
        result = command.execute('private Alice waves')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/yourself/i)
      end

      it 'persists message with private_emote type' do
        result = command.execute('private Bob makes a secret gesture')

        expect(result[:success]).to be true
        message = Message.last
        expect(message.message_type).to eq('private_emote')
        expect(message.target_character_instance_id).to eq(target_instance.id)
      end

      it 'creates exactly one rp log per participant with private_emote type' do
        sender_before = RpLog.where(character_instance_id: character_instance.id).count
        target_before = RpLog.where(character_instance_id: target_instance.id).count

        result = command.execute('private Bob taps a coded rhythm')
        expect(result[:success]).to be true

        sender_logs = RpLog.where(character_instance_id: character_instance.id)
                           .order(Sequel.desc(:id))
                           .limit(1)
                           .all
        target_logs = RpLog.where(character_instance_id: target_instance.id)
                           .order(Sequel.desc(:id))
                           .limit(1)
                           .all

        expect(RpLog.where(character_instance_id: character_instance.id).count).to eq(sender_before + 1)
        expect(RpLog.where(character_instance_id: target_instance.id).count).to eq(target_before + 1)
        expect(sender_logs.first.log_type).to eq('private_emote')
        expect(target_logs.first.log_type).to eq('private_emote')
      end
    end
  end

  describe '#can_execute?' do
    subject(:command) { described_class.new(character_instance) }

    it 'returns true when character is in a room' do
      expect(command.can_execute?).to be true
    end
  end

  describe 'command metadata' do
    it 'has correct command name' do
      expect(described_class.command_name).to eq('private')
    end

    it 'has correct aliases' do
      expect(described_class.alias_names).to include('priv')
    end

    it 'has correct category' do
      expect(described_class.category).to eq(:social)
    end

    it 'has help text' do
      expect(described_class.help_text).to be_a(String)
      expect(described_class.help_text.length).to be > 0
    end
  end
end
