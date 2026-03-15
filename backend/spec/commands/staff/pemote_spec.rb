# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Staff::PEmote, type: :command do
  let(:room) { create(:room, name: 'Town Square') }
  let(:reality) { create(:reality) }
  let(:staff_user) { create(:user, :admin) }
  let(:staff_character) { create(:character, user: staff_user, is_staff_character: true, forename: 'Staff') }
  let(:character_instance) do
    create(:character_instance,
           character: staff_character,
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

  it_behaves_like "command metadata", 'pemote', :staff, ['puppet emote', 'npcemote', 'npc emote']

  describe '#execute' do
    context 'when user is not staff' do
      let(:non_staff_character) { create(:character, is_staff_character: false, forename: 'Regular') }
      let(:non_staff_instance) do
        create(:character_instance,
               character: non_staff_character,
               current_room: room,
               reality: reality,
               online: true)
      end
      let(:non_staff_command) { described_class.new(non_staff_instance) }

      it 'returns error' do
        result = non_staff_command.execute('pemote waves hello')

        expect(result[:success]).to be false
        expect(result[:error]).to include('staff members')
      end
    end

    context 'with empty arguments' do
      it 'returns error about missing emote text' do
        result = command.execute('pemote')

        expect(result[:success]).to be false
        expect(result[:error]).to include('What should the NPC do?')
      end
    end

    context 'when not puppeting any NPC' do
      before do
        allow(character_instance).to receive(:puppets).and_return([])
      end

      it 'returns error about no puppets' do
        result = command.execute('pemote waves hello')

        expect(result[:success]).to be false
        expect(result[:error]).to include("not puppeting any NPCs")
        expect(result[:error]).to include("puppet <npc>")
      end
    end

    context 'when puppeting a single NPC' do
      before do
        allow(character_instance).to receive(:puppets).and_return([npc_instance])
        allow(npc_instance).to receive(:full_name).and_return('Merchant')
        allow(npc_instance).to receive(:current_room).and_return(room)
        allow(npc_instance).to receive(:current_room_id).and_return(room.id)
        allow(npc_instance).to receive(:reality_id).and_return(reality.id)
        allow(npc_instance).to receive(:pending_puppet_suggestion).and_return(nil)
        allow(npc_instance).to receive(:clear_puppet_suggestion!)
        allow(NpcAnimationHandler).to receive(:apply_committed_emote_side_effects)
        allow(BroadcastService).to receive(:to_room)
        allow(RpLoggingService).to receive(:log_to_room)
      end

      it 'performs emote with the NPC' do
        expect(BroadcastService).to receive(:to_room).with(
          room.id,
          hash_including(content: include('Merchant')),
          hash_including(type: :emote, sender_instance: npc_instance)
        )

        result = command.execute('pemote waves hello')

        expect(result[:success]).to be true
        expect(result[:message]).to include('[Puppet]')
        expect(result[:message]).to include('waves hello')
      end

      it 'prepends NPC name if not already present' do
        expect(BroadcastService).to receive(:to_room).with(
          room.id,
          hash_including(content: start_with('Merchant')),
          anything
        )

        command.execute('pemote smiles warmly')
      end

      it 'does not prepend name if already present' do
        expect(BroadcastService).to receive(:to_room).with(
          room.id,
          hash_including(content: 'Merchant waves and laughs.'),
          anything
        )

        command.execute('pemote Merchant waves and laughs')
      end

      it 'adds punctuation if missing' do
        expect(BroadcastService).to receive(:to_room).with(
          room.id,
          hash_including(content: end_with('.')),
          anything
        )

        command.execute('pemote nods quietly')
      end

      it 'does not add punctuation if present' do
        expect(BroadcastService).to receive(:to_room).with(
          room.id,
          hash_including(content: end_with('!')),
          anything
        )

        command.execute('pemote cheers loudly!')
      end

      it 'clears puppet suggestion after emote' do
        expect(npc_instance).to receive(:clear_puppet_suggestion!)

        command.execute('pemote waves')
      end

      it 'logs the roleplay action' do
        expect(IcActivityService).to receive(:record).with(
          hash_including(
            room_id: room.id,
            content: 'Merchant waves.',
            sender: npc_instance,
            type: :emote
          )
        )

        command.execute('pemote waves')
      end

      it 'applies animation side effects after explicit staff commit' do
        allow(npc_instance).to receive(:pending_puppet_suggestion).and_return('Merchant nods thoughtfully.')

        command.execute('pemote waves')

        expect(NpcAnimationHandler).to have_received(:apply_committed_emote_side_effects).with(
          npc_instance: npc_instance,
          emote_text: 'Merchant waves.',
          suggestion_text: 'Merchant nods thoughtfully.'
        )
      end

      it 'returns correct action data' do
        result = command.execute('pemote waves')

        expect(result[:data][:action]).to eq('puppet_emote')
        expect(result[:data][:npc_id]).to eq(npc_instance.id)
        expect(result[:data][:npc_name]).to eq('Merchant')
      end

      context 'when staff is in different room' do
        let(:other_room) { create(:room, name: 'Other Room') }

        before do
          allow(character_instance).to receive(:current_room_id).and_return(other_room.id)
        end

        it 'shows room location in confirmation' do
          result = command.execute('pemote waves')

          expect(result[:message]).to include('[Puppet in Town Square]')
        end
      end

      context 'when NPC is not in a valid room' do
        before do
          allow(npc_instance).to receive(:current_room).and_return(nil)
        end

        it 'returns error' do
          result = command.execute('pemote waves')

          expect(result[:success]).to be false
          expect(result[:error]).to include('not in a valid room')
        end
      end
    end

    context 'when puppeting multiple NPCs' do
      let(:second_npc_character) { create(:character, :npc, forename: 'Guard') }
      let(:second_npc_instance) do
        create(:character_instance,
               character: second_npc_character,
               current_room: room,
               reality: reality,
               online: true)
      end

      before do
        allow(character_instance).to receive(:puppets).and_return([npc_instance, second_npc_instance])
        allow(npc_instance).to receive(:full_name).and_return('Merchant')
        allow(second_npc_instance).to receive(:full_name).and_return('Guard')
      end

      context 'without specifying which NPC' do
        it 'returns error listing puppets' do
          result = command.execute('pemote waves hello')

          expect(result[:success]).to be false
          expect(result[:error]).to include('Could not determine which NPC')
          expect(result[:error]).to include('Merchant')
          expect(result[:error]).to include('Guard')
          expect(result[:error]).to include('pemote <npc name> <emote text>')
        end
      end

      context 'with NPC specified by name' do
        before do
          allow(npc_instance).to receive(:current_room).and_return(room)
          allow(npc_instance).to receive(:current_room_id).and_return(room.id)
          allow(npc_instance).to receive(:reality_id).and_return(reality.id)
          allow(npc_instance).to receive(:pending_puppet_suggestion).and_return(nil)
          allow(npc_instance).to receive(:clear_puppet_suggestion!)
          allow(NpcAnimationHandler).to receive(:apply_committed_emote_side_effects)
          allow(BroadcastService).to receive(:to_room)
          allow(RpLoggingService).to receive(:log_to_room)
        end

        it 'performs emote with specified NPC using natural language' do
          expect(BroadcastService).to receive(:to_room).with(
            room.id,
            hash_including(content: include('Merchant')),
            anything
          )

          result = command.execute('pemote Merchant waves hello')

          expect(result[:success]).to be true
        end

        it 'backward compat: works with = separator' do
          expect(BroadcastService).to receive(:to_room).with(
            room.id,
            hash_including(content: include('Merchant')),
            anything
          )

          result = command.execute('pemote Merchant = waves hello')

          expect(result[:success]).to be true
        end

        it 'returns error if NPC not found in puppets' do
          result = command.execute('pemote Unknown waves')

          expect(result[:success]).to be false
          expect(result[:error]).to include('Could not determine')
        end
      end
    end
  end

  describe '#parse_pemote_input' do
    let(:puppet_list) { [npc_instance] }

    before do
      allow(npc_instance).to receive(:full_name).and_return('Merchant')
    end

    context 'with single puppet' do
      it 'returns puppet and text directly' do
        npc, text = command.send(:parse_pemote_input, 'waves hello', puppet_list)

        expect(npc).to eq(npc_instance)
        expect(text).to eq('waves hello')
      end
    end

    context 'with multiple puppets and name prefix' do
      let(:second_npc_char) { double('Character', forename: 'Guard') }
      let(:second_npc) { double('NPC', full_name: 'Guard', character: second_npc_char) }
      let(:multi_puppet_list) { [npc_instance, second_npc] }

      it 'matches by forename prefix' do
        npc, text = command.send(:parse_pemote_input, 'Merchant waves hello', multi_puppet_list)

        expect(npc).to eq(npc_instance)
        expect(text).to eq('waves hello')
      end

      it 'returns nil for ambiguous input without name match' do
        npc, text = command.send(:parse_pemote_input, 'waves hello', multi_puppet_list)

        expect(npc).to be_nil
        expect(text).to be_nil
      end
    end

    context 'with = format (backward compat)' do
      let(:second_npc_char) { double('Character', forename: 'Guard') }
      let(:second_npc) { double('NPC', full_name: 'Guard', character: second_npc_char) }
      let(:multi_puppet_list) { [npc_instance, second_npc] }

      it 'parses NPC name and emote text' do
        npc, text = command.send(:parse_pemote_input, 'Merchant = waves hello', multi_puppet_list)

        expect(npc).to eq(npc_instance)
        expect(text).to eq('waves hello')
      end
    end
  end

  describe '#find_puppet_by_name' do
    let(:puppet_list) { [npc_instance] }

    before do
      allow(npc_instance).to receive(:full_name).and_return('Old Merchant')
    end

    it 'finds by exact match' do
      found = command.send(:find_puppet_by_name, puppet_list, 'Old Merchant')
      expect(found).to eq(npc_instance)
    end

    it 'finds by forename' do
      found = command.send(:find_puppet_by_name, puppet_list, 'Merchant')
      expect(found).to eq(npc_instance)
    end

    it 'finds by prefix' do
      found = command.send(:find_puppet_by_name, puppet_list, 'Old')
      expect(found).to eq(npc_instance)
    end

    it 'finds by partial match' do
      found = command.send(:find_puppet_by_name, puppet_list, 'erch')
      expect(found).to eq(npc_instance)
    end

    it 'is case insensitive' do
      found = command.send(:find_puppet_by_name, puppet_list, 'OLD MERCHANT')
      expect(found).to eq(npc_instance)
    end

    it 'returns nil if not found' do
      found = command.send(:find_puppet_by_name, puppet_list, 'NotExist')
      expect(found).to be_nil
    end
  end

  describe '#add_punctuation' do
    it 'adds period to text without punctuation' do
      expect(command.send(:add_punctuation, 'waves hello')).to eq('waves hello.')
    end

    it 'preserves existing period' do
      expect(command.send(:add_punctuation, 'waves hello.')).to eq('waves hello.')
    end

    it 'preserves existing exclamation' do
      expect(command.send(:add_punctuation, 'waves hello!')).to eq('waves hello!')
    end

    it 'preserves existing question mark' do
      expect(command.send(:add_punctuation, 'waves hello?')).to eq('waves hello?')
    end

    it 'handles nil input' do
      expect(command.send(:add_punctuation, nil)).to be_nil
    end

    it 'handles empty input' do
      expect(command.send(:add_punctuation, '')).to eq('')
    end
  end
end
