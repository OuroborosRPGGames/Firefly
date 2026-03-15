# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Social::Permissions, type: :command do
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user, forename: 'TestChar') }
  let(:room) { create(:room) }
  let(:character_instance) { create(:character_instance, character: character, current_room: room) }

  describe 'command metadata' do
    it 'has correct command_name' do
      expect(described_class.command_name).to eq('permissions')
    end

    it 'has aliases' do
      aliases = described_class.aliases.map { |a| a[:name] }
      expect(aliases).to include('perms', 'prefs', 'consent', 'block', 'unblock')
    end

    it 'has category' do
      expect(described_class.category).to eq(:social)
    end
  end

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    describe 'main menu' do
      it 'shows quickmenu when called without args' do
        result = command.execute('permissions')

        expect(result[:success]).to be true
        expect(result[:type]).to eq(:quickmenu)
      end

      it 'includes general settings option' do
        result = command.execute('permissions')

        options = result[:data][:options]
        expect(options.any? { |o| o[:key] == 'general' }).to be true
      end

      it 'includes blocks option' do
        result = command.execute('permissions')

        options = result[:data][:options]
        expect(options.any? { |o| o[:key] == 'blocks' }).to be true
      end

      it 'includes consent option' do
        result = command.execute('permissions')

        options = result[:data][:options]
        expect(options.any? { |o| o[:key] == 'consent' }).to be true
      end
    end

    describe 'general permissions' do
      it 'shows permission form for general' do
        result = command.execute('permissions general')

        expect(result[:success]).to be true
        expect(result[:type]).to eq(:form)
      end

      it 'creates generic permission if not exists' do
        expect {
          command.execute('permissions general')
        }.to change { UserPermission.where(user_id: user.id, target_user_id: nil).count }.by(1)
      end

      it 'includes visibility field' do
        result = command.execute('permissions general')

        fields = result[:data][:fields]
        expect(fields.any? { |f| f[:name] == 'visibility' }).to be true
      end

      it 'includes ooc_messaging field' do
        result = command.execute('permissions general')

        fields = result[:data][:fields]
        expect(fields.any? { |f| f[:name] == 'ooc_messaging' }).to be true
      end

      it 'includes ic_messaging field' do
        result = command.execute('permissions general')

        fields = result[:data][:fields]
        expect(fields.any? { |f| f[:name] == 'ic_messaging' }).to be true
      end

      it 'includes lead_follow field' do
        result = command.execute('permissions general')

        fields = result[:data][:fields]
        expect(fields.any? { |f| f[:name] == 'lead_follow' }).to be true
      end
    end

    describe 'character permissions' do
      let(:other_user) { create(:user) }
      let(:other_character) { create(:character, user: other_user, forename: 'Target', surname: 'Player') }
      let(:npc_character) { create(:character, :npc, forename: 'TargetNpc') }

      before do
        other_character
      end

      it 'shows permission form for specific character' do
        result = command.execute('permissions Target')

        expect(result[:success]).to be true
        expect(result[:type]).to eq(:form)
      end

      it 'returns error for non-existent character' do
        result = command.execute('permissions NonExistentCharacter')

        expect(result[:success]).to be false
        expect(result[:message]).to include('not found')
      end

      it 'creates specific permission if not exists' do
        expect {
          command.execute('permissions Target')
        }.to change { UserPermission.where(user_id: user.id, target_user_id: other_user.id).count }.by(1)
      end

      it 'includes generic option in specific permissions' do
        result = command.execute('permissions Target')

        fields = result[:data][:fields]
        visibility_field = fields.find { |f| f[:name] == 'visibility' }
        expect(visibility_field[:options].any? { |o| o[:value] == 'generic' }).to be true
      end

      it 'rejects NPC targets' do
        npc_character
        result = command.execute('permissions TargetNpc')

        expect(result[:success]).to be false
        expect(result[:message]).to include('not found')
      end
    end

    describe 'blocks management' do
      let(:other_user) { create(:user) }
      let(:other_character) { create(:character, user: other_user, forename: 'Target', surname: 'Player') }

      before do
        other_character
      end

      describe 'listing blocks' do
        context 'with no blocks' do
          it 'shows message when no blocks exist' do
            result = command.execute('permissions blocks')

            expect(result[:success]).to be true
            expect(result[:message]).to include("haven't blocked anyone")
          end
        end

        context 'with existing blocks' do
          before do
            rel = Relationship.find_or_create_between(character, other_character)
            rel.block_type!('dm')
          end

          it 'lists blocked players' do
            result = command.execute('permissions blocks')

            expect(result[:success]).to be true
            expect(result[:message]).to include('Target')
            expect(result[:message]).to include('dm')
          end
        end
      end

      describe 'adding blocks' do
        it 'blocks a character' do
          result = command.execute('permissions blocks Target')

          expect(result[:success]).to be true
          expect(result[:message]).to include('blocked')
          expect(result[:message]).to include('Target')
        end

        it 'blocks with specific type' do
          result = command.execute('permissions blocks Target dm')

          expect(result[:success]).to be true
          expect(result[:message]).to include('dm')
        end

        it 'returns error for self-blocking' do
          result = command.execute('permissions blocks TestChar')

          expect(result[:success]).to be false
          expect(result[:message]).to include('block yourself')
        end

        it 'returns error for non-existent character' do
          result = command.execute('permissions blocks NonExistent')

          expect(result[:success]).to be false
          expect(result[:message]).to include('No character found')
        end

        it 'returns error for invalid block type' do
          result = command.execute('permissions blocks Target invalid_type')

          expect(result[:success]).to be false
          expect(result[:message]).to include('Invalid block type')
        end

        it 'returns error if already blocked' do
          rel = Relationship.find_or_create_between(character, other_character)
          rel.block_type!('all')

          result = command.execute('permissions blocks Target')

          expect(result[:success]).to be false
          expect(result[:message]).to include('already')
        end
      end

      describe 'removing blocks' do
        before do
          rel = Relationship.find_or_create_between(character, other_character)
          rel.block_type!('dm')
        end

        it 'unblocks a character' do
          result = command.execute('permissions unblock Target')

          expect(result[:success]).to be true
          expect(result[:message]).to include('unblocked')
        end

        it 'unblocks specific type' do
          result = command.execute('permissions unblock Target dm')

          expect(result[:success]).to be true
          expect(result[:message]).to include('unblocked')
          expect(result[:message]).to include('dm')
        end

        it 'returns error for non-blocked character' do
          another_char = create(:character, forename: 'Another')
          result = command.execute('permissions unblock Another')

          expect(result[:success]).to be false
          expect(result[:message]).to include('not blocked')
        end

        it 'returns error for non-existent character' do
          result = command.execute('permissions unblock NonExistent')

          expect(result[:success]).to be false
          expect(result[:message]).to include('No character found')
        end

        it 'returns error for invalid block type on unblock' do
          rel = Relationship.find_or_create_between(character, other_character)
          rel.block_type!('ooc')

          result = command.execute('permissions unblock Target invalid_type')

          expect(result[:success]).to be false
          expect(result[:message]).to include('Invalid block type')
        end

        it 'returns error when type not blocked' do
          result = command.execute('permissions unblock Target ooc')

          expect(result[:success]).to be false
          expect(result[:message]).to include('not blocked for ooc')
        end
      end
    end

    describe 'consent management' do
      describe 'showing consent form' do
        context 'with no content restrictions' do
          it 'shows message when no restrictions configured' do
            ContentRestriction.where(is_active: true).delete

            result = command.execute('permissions consent')

            expect(result[:success]).to be true
            expect(result[:message]).to include('No content restrictions')
          end
        end

        context 'with content restrictions' do
          let!(:restriction) { create(:content_restriction, code: 'VIOLENCE', name: 'Violence', is_active: true) }

          it 'shows consent form' do
            result = command.execute('permissions consent')

            expect(result[:success]).to be true
            expect(result[:type]).to eq(:form)
          end

          it 'includes restriction fields' do
            result = command.execute('permissions consent')

            fields = result[:data][:fields]
            expect(fields.any? { |f| f[:name] == 'VIOLENCE' }).to be true
          end
        end
      end

      describe 'listing consents' do
        let!(:restriction) { create(:content_restriction, code: 'VIOLENCE', name: 'Violence', is_active: true) }

        it 'lists consent settings' do
          result = command.execute('permissions consent list')

          expect(result[:success]).to be true
          expect(result[:message]).to include('Violence')
        end

        it 'shows ON/OFF status' do
          result = command.execute('permissions consent list')

          expect(result[:message]).to match(/\[ON\]|\[OFF\]/)
        end
      end

      describe 'setting consents' do
        let!(:restriction) { create(:content_restriction, code: 'VIOLENCE', name: 'Violence', is_active: true) }

        it 'sets consent on' do
          result = command.execute('permissions consent set VIOLENCE yes')

          expect(result[:success]).to be true
          expect(result[:message]).to include('consent')
          expect(result[:message]).to include('Violence')
        end

        it 'sets consent off' do
          perm = UserPermission.generic_for(user)
          perm.set_content_consent!(restriction.code, 'yes')

          result = command.execute('permissions consent set VIOLENCE no')

          expect(result[:success]).to be true
          expect(result[:message]).to include('revoked')
        end

        it 'toggles consent' do
          result = command.execute('permissions consent VIOLENCE toggle')

          expect(result[:success]).to be true
        end

        it 'returns error for invalid restriction' do
          result = command.execute('permissions consent set invalid_code yes')

          expect(result[:success]).to be false
          expect(result[:message]).to include('Unknown content type')
        end
      end

      describe 'restriction info' do
        let!(:restriction) { create(:content_restriction, code: 'VIOLENCE', name: 'Violence', description: 'Violent content', severity: 'mild', is_active: true) }

        it 'shows restriction info' do
          result = command.execute('permissions consent info VIOLENCE')

          expect(result[:success]).to be true
          expect(result[:message]).to include('Violence')
          expect(result[:message]).to include('mild')
        end

        it 'returns error for invalid restriction' do
          result = command.execute('permissions consent info invalid')

          expect(result[:success]).to be false
          expect(result[:message]).to include('Unknown content type')
        end
      end
    end

    describe 'unfriend management' do
      let(:other_user) { create(:user) }
      let(:other_character) { create(:character, user: other_user, forename: 'Friend', surname: 'Player') }

      before do
        other_character
      end

      context 'when there is a relationship' do
        before do
          Relationship.create(
            character_id: character.id,
            target_character_id: other_character.id,
            status: 'accepted'
          )
        end

        it 'unfriends a character' do
          result = command.execute('permissions unfriend Friend')

          expect(result[:success]).to be true
          expect(result[:message]).to include('unfriended')
        end

        it 'updates the relationship status' do
          command.execute('permissions unfriend Friend')

          relationship = Relationship.between(character, other_character)
          expect(relationship.status).to eq('unfriended')
        end
      end

      context 'when no relationship exists' do
        it 'returns error when no prior interaction' do
          result = command.execute('permissions unfriend Friend')

          expect(result[:success]).to be false
          expect(result[:message]).to include('interacted')
        end
      end

      it 'returns error for non-existent character' do
        result = command.execute('permissions unfriend NonExistent')

        expect(result[:success]).to be false
        expect(result[:message]).to include('No character found')
      end
    end

    describe 'room consents' do
      let!(:restriction) { create(:content_restriction, code: 'VIOLENCE', name: 'Violence', is_active: true) }

      context 'when display not ready (occupancy not stable)' do
        before do
          allow(ContentConsentService).to receive(:display_ready?).and_return(false)
          allow(ContentConsentService).to receive(:time_until_display).and_return(600)
        end

        it 'shows waiting message' do
          result = command.execute('permissions consent room')

          expect(result[:success]).to be true
          expect(result[:message]).to include('minute')
        end
      end

      context 'when display ready' do
        before do
          allow(ContentConsentService).to receive(:display_ready?).and_return(true)
          allow(ContentConsentService).to receive(:consent_display_for_room).and_return({
            allowed_content: ['VIOLENCE']
          })
        end

        it 'shows room consent status' do
          result = command.execute('permissions consent room')

          expect(result[:success]).to be true
          expect(result[:message]).to include('Violence')
        end
      end

      context 'when no content is consented' do
        before do
          allow(ContentConsentService).to receive(:display_ready?).and_return(true)
          allow(ContentConsentService).to receive(:consent_display_for_room).and_return({
            allowed_content: []
          })
        end

        it 'shows no content message' do
          result = command.execute('permissions consent room')

          expect(result[:success]).to be true
          expect(result[:message]).to include('No content types')
        end
      end
    end

    describe 'consent overrides' do
      let(:other_user) { create(:user) }
      let(:other_character) { create(:character, user: other_user, forename: 'Override', surname: 'Target') }
      let!(:restriction) { create(:content_restriction, code: 'VIOLENCE', name: 'Violence', is_active: true) }

      before do
        other_character
      end

      describe 'listing overrides' do
        it 'lists consent overrides' do
          result = command.execute('permissions consent overrides')

          expect(result[:success]).to be true
        end
      end

      describe 'managing overrides' do
        it 'creates override for character' do
          result = command.execute('permissions consent override Override VIOLENCE yes')

          expect(result[:success]).to be true
          expect(result[:message]).to include('allow')
          expect(result[:message]).to include('Violence')
        end

        it 'removes override' do
          perm = UserPermission.specific_for(user, other_user, display_character: other_character)
          perm.set_content_consent!(restriction.code, 'yes')

          result = command.execute('permissions consent override Override VIOLENCE off')

          expect(result[:success]).to be true
          expect(result[:message]).to include('revoked')
        end

        it 'returns error for non-existent character' do
          result = command.execute('permissions consent override NonExistent VIOLENCE yes')

          expect(result[:success]).to be false
          expect(result[:message]).to include('not found')
        end

        it 'returns error for invalid restriction code' do
          result = command.execute('permissions consent override Override invalid_code yes')

          expect(result[:success]).to be false
          expect(result[:message]).to include('Unknown content type')
        end
      end
    end
  end
end
