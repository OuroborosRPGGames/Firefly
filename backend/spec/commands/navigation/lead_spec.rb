# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Navigation::Lead, type: :command do
  let(:room) { create(:room) }
  let(:reality) { create(:reality) }
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user, forename: 'Alice') }
  let(:character_instance) do
    create(:character_instance,
           character: character,
           current_room: room,
           reality: reality,
           online: true)
  end
  let(:other_user) { create(:user) }
  let(:other_character) { create(:character, user: other_user, forename: 'Bob') }
  let(:other_instance) do
    create(:character_instance,
           character: other_character,
           current_room: room,
           reality: reality,
           online: true)
  end
  let(:npc_character) { create(:character, :npc, forename: 'Merchant') }
  let(:npc_instance) do
    create(:character_instance,
           character: npc_character,
           current_room: room,
           reality: reality,
           online: true)
  end

  subject(:command) { described_class.new(character_instance) }

  it_behaves_like "command metadata", 'lead', :navigation, %w[allow permit carry]

  describe '#execute' do
    context 'with no arguments' do
      it 'shows current followers when none' do
        result = command.execute('lead')

        expect(result[:success]).to be true
        expect(result[:message]).to include('No one is currently following you')
      end

      it 'shows current followers when present' do
        other_instance.update(following_id: character_instance.id)

        result = command.execute('lead')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Currently following you')
        expect(result[:message]).to include('Bob')
      end

      it 'shows multiple followers' do
        third_character = create(:character, forename: 'Carol')
        third_instance = create(:character_instance,
                                character: third_character,
                                current_room: room,
                                reality: reality,
                                online: true,
                                following_id: character_instance.id)
        other_instance.update(following_id: character_instance.id)

        result = command.execute('lead')

        expect(result[:message]).to include('Bob')
        expect(result[:message]).to include('Carol')
      end
    end

    context 'with PC target' do
      before do
        other_instance # Ensure exists
        allow(command).to receive(:resolve_character_with_menu).and_return({ match: other_instance })
        allow(UserPermission).to receive(:lead_follow_allowed?).and_return(true)
      end

      it 'grants follow permission to PC' do
        movement_result = double(success: true, message: 'Bob can now follow you.')
        allow(MovementService).to receive(:grant_follow_permission)
          .with(character_instance, other_instance)
          .and_return(movement_result)

        result = command.execute('lead Bob')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Bob can now follow you')
      end

      it 'returns error when movement service fails' do
        movement_result = double(success: false, message: 'Cannot grant permission.')
        allow(MovementService).to receive(:grant_follow_permission)
          .and_return(movement_result)

        result = command.execute('lead Bob')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Cannot grant permission')
      end

      it 'returns error when target has blocked lead/follow' do
        allow(UserPermission).to receive(:lead_follow_allowed?).and_return(false)

        result = command.execute('lead Bob')

        expect(result[:success]).to be false
        expect(result[:error]).to include('blocked lead/follow')
      end

      it 'handles disambiguation quickmenu' do
        allow(command).to receive(:resolve_character_with_menu)
          .and_return({ disambiguation: true, result: 'quickmenu_data' })
        allow(command).to receive(:disambiguation_result).and_return({ quickmenu: true })

        result = command.execute('lead B')

        expect(result).to have_key(:quickmenu)
      end

      it 'handles target not found' do
        allow(command).to receive(:resolve_character_with_menu)
          .and_return({ error: "You don't see 'NotExist' here." })

        result = command.execute('lead NotExist')

        expect(result[:success]).to be false
        expect(result[:error]).to include("don't see")
      end
    end

    context 'with NPC target' do
      before do
        npc_instance # Ensure exists
        allow(command).to receive(:resolve_character_with_menu).and_return({ match: npc_instance })
      end

      context 'when NPC can be led' do
        before do
          allow(NpcLeadershipService).to receive(:can_be_led?).with(npc_character).and_return(true)
          allow(NpcLeadershipService).to receive(:on_lead_cooldown?).and_return(false)
        end

        it 'submits lead request' do
          expect(NpcLeadershipService).to receive(:request_lead).with(
            npc_instance: npc_instance,
            pc_instance: character_instance
          )

          result = command.execute('lead Merchant')

          expect(result[:success]).to be true
          expect(result[:message]).to include('You ask')
          expect(result[:message]).to include('Merchant')
          expect(result[:message]).to include('to follow you')
        end

        it 'returns error when NPC is already following' do
          npc_instance.update(following_id: character_instance.id)

          result = command.execute('lead Merchant')

          expect(result[:success]).to be false
          expect(result[:error]).to include('already following you')
        end

        it 'returns error when NPC is following someone else' do
          another_instance = create(:character_instance,
                                    character: other_character,
                                    current_room: room,
                                    reality: reality,
                                    online: true)
          npc_instance.update(following_id: another_instance.id)

          result = command.execute('lead Merchant')

          expect(result[:success]).to be false
          expect(result[:error]).to include('already following')
        end

        it 'returns error when on lead cooldown' do
          allow(NpcLeadershipService).to receive(:on_lead_cooldown?).and_return(true)
          allow(NpcLeadershipService).to receive(:lead_cooldown_remaining).and_return(120)

          result = command.execute('lead Merchant')

          expect(result[:success]).to be false
          expect(result[:error]).to include('recently declined')
          expect(result[:error]).to include('2 minutes')
        end
      end

      context 'when NPC cannot be led' do
        before do
          allow(NpcLeadershipService).to receive(:can_be_led?).with(npc_character).and_return(false)
        end

        it 'returns error about NPC not being leadable' do
          result = command.execute('lead Merchant')

          expect(result[:success]).to be false
          expect(result[:error]).to include('cannot be led')
        end
      end
    end

    context 'with "stop" subcommand' do
      before do
        other_instance # Ensure exists
        allow(command).to receive(:find_all_online_characters).and_return([other_instance])
      end

      it 'revokes follow permission' do
        allow(TargetResolverService).to receive(:resolve_character_with_disambiguation)
          .and_return({ match: other_instance })
        movement_result = double(success: true, message: 'Bob can no longer follow you.')
        allow(MovementService).to receive(:revoke_follow_permission)
          .with(character_instance, other_instance)
          .and_return(movement_result)

        result = command.execute('lead stop Bob')

        expect(result[:success]).to be true
        expect(result[:message]).to include('can no longer follow')
      end

      it 'works with "revoke" subcommand' do
        allow(TargetResolverService).to receive(:resolve_character_with_disambiguation)
          .and_return({ match: other_instance })
        movement_result = double(success: true, message: 'Permission revoked.')
        allow(MovementService).to receive(:revoke_follow_permission)
          .and_return(movement_result)

        result = command.execute('lead revoke Bob')

        expect(result[:success]).to be true
      end

      it 'returns error when no name specified' do
        result = command.execute('lead stop')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Who do you want to stop leading?')
      end

      it 'handles disambiguation' do
        allow(TargetResolverService).to receive(:resolve_character_with_disambiguation)
          .and_return({ quickmenu: 'quickmenu_data' })
        allow(command).to receive(:disambiguation_result).and_return({ quickmenu: true })

        result = command.execute('lead stop B')

        expect(result).to have_key(:quickmenu)
      end

      it 'returns error when target not found' do
        allow(TargetResolverService).to receive(:resolve_character_with_disambiguation)
          .and_return({ error: "Unknown character" })

        result = command.execute('lead stop NotExist')

        expect(result[:success]).to be false
        expect(result[:error]).to include("Unknown character")
      end

      it 'handles movement service failure' do
        allow(TargetResolverService).to receive(:resolve_character_with_disambiguation)
          .and_return({ match: other_instance })
        movement_result = double(success: false, message: 'Cannot revoke.')
        allow(MovementService).to receive(:revoke_follow_permission)
          .and_return(movement_result)

        result = command.execute('lead stop Bob')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Cannot revoke')
      end
    end
  end

  describe '#check_lead_follow_permission' do
    let(:target_instance) { other_instance }

    it 'returns nil when allowed' do
      allow(UserPermission).to receive(:lead_follow_allowed?).and_return(true)

      result = command.send(:check_lead_follow_permission, target_instance)

      expect(result).to be_nil
    end

    it 'returns error when blocked' do
      allow(UserPermission).to receive(:lead_follow_allowed?).and_return(false)

      result = command.send(:check_lead_follow_permission, target_instance)

      expect(result[:success]).to be false
      expect(result[:error]).to include('blocked lead/follow')
    end

    it 'allows when target has no user (NPC)' do
      allow(target_instance.character).to receive(:user).and_return(nil)

      result = command.send(:check_lead_follow_permission, target_instance)

      expect(result).to be_nil
    end
  end
end
