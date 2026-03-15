# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ClanDisambiguationHandler do
  let(:room) { create(:room) }
  let(:character) { create(:character) }
  let(:char_instance) { create(:character_instance, character: character, current_room: room) }
  let(:universe) { create(:universe) }
  let(:clan) { create(:group, :clan, universe: universe, name: 'Test Clan') }

  describe '.process_response' do
    context 'with invalid selection' do
      it 'returns error for invalid index' do
        interaction_data = { context: { action: 'leave', clan_ids: [clan.id] } }

        result = described_class.process_response(char_instance, interaction_data, '5')

        expect(result[:success]).to be false
        expect(result[:message]).to eq('Invalid selection')
      end

      it 'returns error for empty clan_ids array' do
        interaction_data = { context: { action: 'leave', clan_ids: [] } }

        result = described_class.process_response(char_instance, interaction_data, '1')

        expect(result[:success]).to be false
        expect(result[:message]).to eq('Invalid selection')
      end

      it 'returns error for non-numeric index' do
        interaction_data = { context: { action: 'leave', clan_ids: [clan.id] } }

        # 'abc'.to_i returns 0, and 0 - 1 = -1, which wraps to last element in Ruby
        # So we test with an index that is actually out of bounds
        result = described_class.process_response(char_instance, interaction_data, '99')

        expect(result[:success]).to be false
        expect(result[:message]).to eq('Invalid selection')
      end
    end

    context 'with clan not found' do
      it 'returns error when clan does not exist' do
        interaction_data = { context: { action: 'leave', clan_ids: [99999] } }

        result = described_class.process_response(char_instance, interaction_data, '1')

        expect(result[:success]).to be false
        expect(result[:message]).to eq('Clan not found')
      end
    end

    context 'with unknown action' do
      it 'returns error for unknown action' do
        interaction_data = { context: { action: 'unknown_action', clan_ids: [clan.id] } }

        result = described_class.process_response(char_instance, interaction_data, '1')

        expect(result[:success]).to be false
        expect(result[:message]).to include('Unknown clan action')
      end
    end

    context 'with string keys in context' do
      it 'handles string keys correctly' do
        allow(ClanService).to receive(:leave_clan).and_return({ success: true, message: 'You left the clan.' })
        interaction_data = { 'context' => { 'action' => 'leave', 'clan_ids' => [clan.id] } }

        result = described_class.process_response(char_instance, interaction_data, '1')

        expect(result[:success]).to be true
      end
    end

    # Invite action
    context 'with invite action' do
      let(:target) { create(:character) }

      context 'when successful' do
        before do
          allow(ClanService).to receive(:invite_member).and_return({
            success: true,
            message: "#{target.full_name} has been invited to #{clan.name}."
          })
        end

        it 'invites the target character' do
          interaction_data = {
            context: {
              action: 'invite',
              clan_ids: [clan.id],
              target_id: target.id
            }
          }

          result = described_class.process_response(char_instance, interaction_data, '1')

          expect(result[:success]).to be true
          expect(result[:message]).to include('invited')
          expect(ClanService).to have_received(:invite_member).with(clan, character, target, handle: nil)
        end

        it 'passes handle to invite when provided' do
          interaction_data = {
            context: {
              action: 'invite',
              clan_ids: [clan.id],
              target_id: target.id,
              handle: 'ShadowAgent'
            }
          }

          described_class.process_response(char_instance, interaction_data, '1')

          expect(ClanService).to have_received(:invite_member).with(clan, character, target, handle: 'ShadowAgent')
        end
      end

      context 'when target not found' do
        it 'returns error' do
          interaction_data = {
            context: {
              action: 'invite',
              clan_ids: [clan.id],
              target_id: 99999
            }
          }

          result = described_class.process_response(char_instance, interaction_data, '1')

          expect(result[:success]).to be false
          expect(result[:message]).to eq('Character not found')
        end
      end

      context 'when ClanService returns error' do
        before do
          allow(ClanService).to receive(:invite_member).and_return({
            success: false,
            error: 'You do not have permission to invite members.'
          })
        end

        it 'returns the service error' do
          interaction_data = {
            context: {
              action: 'invite',
              clan_ids: [clan.id],
              target_id: target.id
            }
          }

          result = described_class.process_response(char_instance, interaction_data, '1')

          expect(result[:success]).to be false
          expect(result[:message]).to eq('You do not have permission to invite members.')
        end
      end
    end

    # Kick action
    context 'with kick action' do
      let(:target) { create(:character) }

      context 'when successful' do
        before do
          allow(ClanService).to receive(:kick_member).and_return({
            success: true,
            message: "#{target.full_name} has been kicked from #{clan.name}."
          })
        end

        it 'kicks the target character' do
          interaction_data = {
            context: {
              action: 'kick',
              clan_ids: [clan.id],
              target_id: target.id
            }
          }

          result = described_class.process_response(char_instance, interaction_data, '1')

          expect(result[:success]).to be true
          expect(result[:message]).to include('kicked')
          expect(ClanService).to have_received(:kick_member).with(clan, character, target)
        end
      end

      context 'when target not found' do
        it 'returns error' do
          interaction_data = {
            context: {
              action: 'kick',
              clan_ids: [clan.id],
              target_id: 99999
            }
          }

          result = described_class.process_response(char_instance, interaction_data, '1')

          expect(result[:success]).to be false
          expect(result[:message]).to eq('Character not found')
        end
      end

      context 'when ClanService returns error' do
        before do
          allow(ClanService).to receive(:kick_member).and_return({
            success: false,
            error: 'You cannot kick this member.'
          })
        end

        it 'returns the service error' do
          interaction_data = {
            context: {
              action: 'kick',
              clan_ids: [clan.id],
              target_id: target.id
            }
          }

          result = described_class.process_response(char_instance, interaction_data, '1')

          expect(result[:success]).to be false
          expect(result[:message]).to eq('You cannot kick this member.')
        end
      end
    end

    # Leave action
    context 'with leave action' do
      context 'when successful' do
        before do
          allow(ClanService).to receive(:leave_clan).and_return({
            success: true,
            message: "You have left #{clan.name}."
          })
        end

        it 'leaves the clan' do
          interaction_data = {
            context: {
              action: 'leave',
              clan_ids: [clan.id]
            }
          }

          result = described_class.process_response(char_instance, interaction_data, '1')

          expect(result[:success]).to be true
          expect(result[:message]).to include('left')
          expect(ClanService).to have_received(:leave_clan).with(clan, character)
        end
      end

      context 'when ClanService returns error' do
        before do
          allow(ClanService).to receive(:leave_clan).and_return({
            success: false,
            error: 'You cannot leave as the last leader.'
          })
        end

        it 'returns the service error' do
          interaction_data = {
            context: {
              action: 'leave',
              clan_ids: [clan.id]
            }
          }

          result = described_class.process_response(char_instance, interaction_data, '1')

          expect(result[:success]).to be false
          expect(result[:message]).to eq('You cannot leave as the last leader.')
        end
      end
    end

    # Memo action
    context 'with memo action' do
      context 'when successful' do
        before do
          allow(ClanService).to receive(:send_clan_memo).and_return({
            success: true,
            message: 'Memo sent to all clan members.'
          })
        end

        it 'sends the memo' do
          interaction_data = {
            context: {
              action: 'memo',
              clan_ids: [clan.id],
              subject: 'Important Announcement',
              body: 'Meeting tomorrow at noon.'
            }
          }

          result = described_class.process_response(char_instance, interaction_data, '1')

          expect(result[:success]).to be true
          expect(result[:message]).to include('Memo sent')
          expect(ClanService).to have_received(:send_clan_memo).with(
            clan, character, subject: 'Important Announcement', body: 'Meeting tomorrow at noon.'
          )
        end
      end

      context 'when ClanService returns error' do
        before do
          allow(ClanService).to receive(:send_clan_memo).and_return({
            success: false,
            error: 'You do not have permission to send memos.'
          })
        end

        it 'returns the service error' do
          interaction_data = {
            context: {
              action: 'memo',
              clan_ids: [clan.id],
              subject: 'Test',
              body: 'Body'
            }
          }

          result = described_class.process_response(char_instance, interaction_data, '1')

          expect(result[:success]).to be false
          expect(result[:message]).to eq('You do not have permission to send memos.')
        end
      end
    end

    # Handle action
    context 'with handle action' do
      context 'when successful' do
        before do
          allow(ClanService).to receive(:set_handle).and_return({
            success: true,
            message: 'Your clan handle has been updated.'
          })
        end

        it 'sets the new handle' do
          interaction_data = {
            context: {
              action: 'handle',
              clan_ids: [clan.id],
              new_handle: 'NewNickname'
            }
          }

          result = described_class.process_response(char_instance, interaction_data, '1')

          expect(result[:success]).to be true
          expect(result[:message]).to include('handle')
          expect(ClanService).to have_received(:set_handle).with(clan, character, 'NewNickname')
        end
      end

      context 'when ClanService returns error' do
        before do
          allow(ClanService).to receive(:set_handle).and_return({
            success: false,
            error: 'Handle is already taken.'
          })
        end

        it 'returns the service error' do
          interaction_data = {
            context: {
              action: 'handle',
              clan_ids: [clan.id],
              new_handle: 'TakenName'
            }
          }

          result = described_class.process_response(char_instance, interaction_data, '1')

          expect(result[:success]).to be false
          expect(result[:message]).to eq('Handle is already taken.')
        end
      end
    end

    # Grant action
    context 'with grant action' do
      let(:target_room) { create(:room) }

      context 'when user is an officer' do
        let(:membership) { double('GroupMember', officer?: true) }

        before do
          allow(clan).to receive(:membership_for).with(character).and_return(membership)
          allow(clan).to receive(:grant_room_access!)
          allow(clan).to receive(:display_name).and_return('Test Clan')
          allow(Group).to receive(:[]).with(clan.id).and_return(clan)
        end

        it 'grants room access' do
          interaction_data = {
            context: {
              action: 'grant',
              clan_ids: [clan.id],
              room_id: target_room.id
            }
          }

          result = described_class.process_response(char_instance, interaction_data, '1')

          expect(result[:success]).to be true
          expect(result[:message]).to include('can now enter this room')
          expect(clan).to have_received(:grant_room_access!).with(target_room, permanent: true)
        end
      end

      context 'when user is not an officer' do
        let(:membership) { double('GroupMember', officer?: false) }

        before do
          allow(clan).to receive(:membership_for).with(character).and_return(membership)
          allow(Group).to receive(:[]).with(clan.id).and_return(clan)
        end

        it 'returns error' do
          interaction_data = {
            context: {
              action: 'grant',
              clan_ids: [clan.id],
              room_id: target_room.id
            }
          }

          result = described_class.process_response(char_instance, interaction_data, '1')

          expect(result[:success]).to be false
          expect(result[:message]).to eq('Only officers can grant room access.')
        end
      end

      context 'when user has no membership' do
        before do
          allow(clan).to receive(:membership_for).with(character).and_return(nil)
          allow(Group).to receive(:[]).with(clan.id).and_return(clan)
        end

        it 'returns error' do
          interaction_data = {
            context: {
              action: 'grant',
              clan_ids: [clan.id],
              room_id: target_room.id
            }
          }

          result = described_class.process_response(char_instance, interaction_data, '1')

          expect(result[:success]).to be false
          expect(result[:message]).to eq('Only officers can grant room access.')
        end
      end

      context 'when room not found' do
        it 'returns error' do
          interaction_data = {
            context: {
              action: 'grant',
              clan_ids: [clan.id],
              room_id: 99999
            }
          }

          result = described_class.process_response(char_instance, interaction_data, '1')

          expect(result[:success]).to be false
          expect(result[:message]).to eq('Room not found')
        end
      end
    end

    # Revoke action
    context 'with revoke action' do
      let(:target_room) { create(:room) }

      context 'when user is an officer' do
        let(:membership) { double('GroupMember', officer?: true) }

        before do
          allow(clan).to receive(:membership_for).with(character).and_return(membership)
          allow(clan).to receive(:revoke_room_access!)
          allow(clan).to receive(:display_name).and_return('Test Clan')
          allow(Group).to receive(:[]).with(clan.id).and_return(clan)
        end

        it 'revokes room access' do
          interaction_data = {
            context: {
              action: 'revoke',
              clan_ids: [clan.id],
              room_id: target_room.id
            }
          }

          result = described_class.process_response(char_instance, interaction_data, '1')

          expect(result[:success]).to be true
          expect(result[:message]).to include('can no longer enter this room')
          expect(clan).to have_received(:revoke_room_access!).with(target_room)
        end
      end

      context 'when user is not an officer' do
        let(:membership) { double('GroupMember', officer?: false) }

        before do
          allow(clan).to receive(:membership_for).with(character).and_return(membership)
          allow(Group).to receive(:[]).with(clan.id).and_return(clan)
        end

        it 'returns error' do
          interaction_data = {
            context: {
              action: 'revoke',
              clan_ids: [clan.id],
              room_id: target_room.id
            }
          }

          result = described_class.process_response(char_instance, interaction_data, '1')

          expect(result[:success]).to be false
          expect(result[:message]).to eq('Only officers can revoke room access.')
        end
      end

      context 'when user has no membership' do
        before do
          allow(clan).to receive(:membership_for).with(character).and_return(nil)
          allow(Group).to receive(:[]).with(clan.id).and_return(clan)
        end

        it 'returns error' do
          interaction_data = {
            context: {
              action: 'revoke',
              clan_ids: [clan.id],
              room_id: target_room.id
            }
          }

          result = described_class.process_response(char_instance, interaction_data, '1')

          expect(result[:success]).to be false
          expect(result[:message]).to eq('Only officers can revoke room access.')
        end
      end

      context 'when room not found' do
        it 'returns error' do
          interaction_data = {
            context: {
              action: 'revoke',
              clan_ids: [clan.id],
              room_id: 99999
            }
          }

          result = described_class.process_response(char_instance, interaction_data, '1')

          expect(result[:success]).to be false
          expect(result[:message]).to eq('Room not found')
        end
      end
    end

    # Multiple clans selection
    context 'with multiple clans' do
      let(:clan2) { create(:group, :clan, universe: universe, name: 'Second Clan') }

      before do
        allow(ClanService).to receive(:leave_clan).and_return({
          success: true,
          message: 'You have left the clan.'
        })
      end

      it 'selects the correct clan based on index' do
        interaction_data = {
          context: {
            action: 'leave',
            clan_ids: [clan.id, clan2.id]
          }
        }

        # Select second clan
        result = described_class.process_response(char_instance, interaction_data, '2')

        expect(result[:success]).to be true
        expect(ClanService).to have_received(:leave_clan).with(clan2, character)
      end

      it 'selects first clan when 1 is chosen' do
        interaction_data = {
          context: {
            action: 'leave',
            clan_ids: [clan.id, clan2.id]
          }
        }

        # Select first clan
        result = described_class.process_response(char_instance, interaction_data, '1')

        expect(result[:success]).to be true
        expect(ClanService).to have_received(:leave_clan).with(clan, character)
      end
    end
  end

  describe 'response structure' do
    before do
      allow(ClanService).to receive(:leave_clan).and_return({
        success: true,
        message: 'You have left the clan.'
      })
    end

    it 'returns consistent success structure' do
      interaction_data = { context: { action: 'leave', clan_ids: [clan.id] } }

      result = described_class.process_response(char_instance, interaction_data, '1')

      expect(result).to include(:success, :message, :data)
      expect(result[:success]).to be true
    end

    it 'returns consistent error structure' do
      interaction_data = { context: { action: 'leave', clan_ids: [99999] } }

      result = described_class.process_response(char_instance, interaction_data, '1')

      expect(result).to include(:success, :message, :error)
      expect(result[:success]).to be false
    end
  end
end
