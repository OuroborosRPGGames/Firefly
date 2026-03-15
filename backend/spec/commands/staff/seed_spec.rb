# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Staff::Seed, type: :command do
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

  it_behaves_like "command metadata", 'seed', :staff, ['instruct', 'npc seed']

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
        result = non_staff_command.execute('seed Merchant mention the weather')

        expect(result[:success]).to be false
        expect(result[:error]).to include('staff members')
      end
    end

    context 'with empty arguments' do
      it 'returns error about missing instruction' do
        result = command.execute('seed')

        expect(result[:success]).to be false
        expect(result[:error]).to include('What instruction')
        expect(result[:error]).to include('Usage')
      end
    end

    context 'with only NPC name (no instruction)' do
      it 'returns error requesting message' do
        result = command.execute('seed Merchant')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/usage|message/i)
      end
    end

    context 'with empty NPC name via = separator' do
      it 'returns error' do
        result = command.execute('seed = mention the weather')

        expect(result[:success]).to be false
        expect(result[:error]).to include('specify an NPC name')
      end
    end

    context 'with empty instruction via = separator' do
      it 'returns error' do
        result = command.execute('seed Merchant =')

        expect(result[:success]).to be false
        expect(result[:error]).to include('specify an instruction')
      end
    end

    context 'with valid input' do
      before do
        npc_instance # Ensure NPC exists
        allow(npc_instance).to receive(:full_name).and_return('Merchant')
        allow(npc_instance).to receive(:current_room).and_return(room)
        allow(npc_instance).to receive(:puppet_mode?).and_return(false)
        allow(npc_instance).to receive(:seed_instruction!).and_return({ success: true })
        # Stub find_npc to return our stubbed instance
        allow(command).to receive(:find_npc).with('Merchant').and_return(npc_instance)
      end

      it 'seeds instruction to NPC' do
        expect(npc_instance).to receive(:seed_instruction!).with('mention the weather')

        result = command.execute('seed Merchant mention the weather')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Seeded instruction')
        expect(result[:message]).to include('Merchant')
        expect(result[:message]).to include('mention the weather')
      end

      it 'shows NPC location' do
        result = command.execute('seed Merchant mention the weather')

        expect(result[:message]).to include('Town Square')
      end

      it 'includes guidance about LLM action' do
        result = command.execute('seed Merchant mention the weather')

        expect(result[:message]).to include('next LLM-generated action')
      end

      it 'returns correct action data' do
        result = command.execute('seed Merchant mention the weather')

        expect(result[:data][:action]).to eq('seed_instruction')
        expect(result[:data][:npc_id]).to eq(npc_instance.id)
        expect(result[:data][:npc_name]).to eq('Merchant')
        expect(result[:data][:instruction]).to eq('mention the weather')
      end

      it 'handles seeding failure' do
        allow(npc_instance).to receive(:seed_instruction!)
          .and_return({ success: false, message: 'NPC is busy' })

        result = command.execute('seed Merchant mention the weather')

        expect(result[:success]).to be false
        expect(result[:error]).to include('NPC is busy')
      end

      it 'backward compat: works with = separator' do
        expect(npc_instance).to receive(:seed_instruction!).with('mention the weather')

        result = command.execute('seed Merchant = mention the weather')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Seeded instruction')
      end
    end

    context 'when NPC not found' do
      it 'returns error' do
        result = command.execute('seed NotExist mention the weather')

        expect(result[:success]).to be false
        expect(result[:error]).to include("Could not find an NPC named 'NotExist'")
      end
    end

    context 'when NPC is being puppeted by someone else' do
      let(:other_admin_user) { create(:user, :admin) }
      let(:other_staff) { create(:character, user: other_admin_user, is_staff_character: true, forename: 'OtherStaff') }
      let(:other_instance) { create(:character_instance, character: other_staff, current_room: room, reality: reality) }

      before do
        npc_instance # Ensure NPC exists
        allow(npc_instance).to receive(:full_name).and_return('Merchant')
        allow(npc_instance).to receive(:puppet_mode?).and_return(true)
        allow(npc_instance).to receive(:puppeted_by_instance_id).and_return(other_instance.id)
        allow(npc_instance).to receive(:puppeteer).and_return(other_staff)
        # Stub find_npc to return our stubbed instance
        allow(command).to receive(:find_npc).with('Merchant').and_return(npc_instance)
      end

      it 'returns error about puppeteer' do
        result = command.execute('seed Merchant mention the weather')

        expect(result[:success]).to be false
        expect(result[:error]).to include('being puppeted by')
        expect(result[:error].downcase).to include('otherstaff')
        expect(result[:error]).to include('Cannot seed instructions')
      end
    end

    context 'when NPC is puppeted by self' do
      before do
        npc_instance # Ensure NPC exists
        allow(npc_instance).to receive(:full_name).and_return('Merchant')
        allow(npc_instance).to receive(:current_room).and_return(room)
        allow(npc_instance).to receive(:puppet_mode?).and_return(true)
        allow(npc_instance).to receive(:puppeted_by_instance_id).and_return(character_instance.id)
        allow(npc_instance).to receive(:seed_instruction!).and_return({ success: true })
        # Stub find_npc to return our stubbed instance
        allow(command).to receive(:find_npc).with('Merchant').and_return(npc_instance)
      end

      it 'allows seeding' do
        result = command.execute('seed Merchant mention the weather')

        expect(result[:success]).to be true
      end
    end
  end

  describe '#find_npc' do
    before { npc_instance }

    context 'when NPC is in current room' do
      it 'finds by exact name' do
        found = command.send(:find_npc, 'Merchant')
        expect(found).to eq(npc_instance)
      end

      it 'finds by forename' do
        found = command.send(:find_npc, 'Merchant')
        expect(found).to eq(npc_instance)
      end

      it 'finds by prefix' do
        found = command.send(:find_npc, 'Merch')
        expect(found).to eq(npc_instance)
      end

      it 'finds by partial match' do
        found = command.send(:find_npc, 'ercha')
        expect(found).to eq(npc_instance)
      end

      it 'is case insensitive' do
        found = command.send(:find_npc, 'MERCHANT')
        expect(found).to eq(npc_instance)
      end
    end

    context 'when NPC is in different room' do
      let(:other_room) { create(:room, name: 'Other Room') }
      let(:global_npc_character) { create(:character, :npc, forename: 'GlobalMerchant') }
      let(:global_npc_instance) do
        create(:character_instance,
               character: global_npc_character,
               current_room: other_room,
               reality: reality,
               online: true)
      end

      before { global_npc_instance }

      it 'finds NPC globally' do
        found = command.send(:find_npc, 'GlobalMerchant')
        expect(found).to eq(global_npc_instance)
      end
    end

    context 'when PC character has similar name' do
      let(:pc_character) { create(:character, is_npc: false, forename: 'Alice') }
      let!(:pc_instance) do
        create(:character_instance,
               character: pc_character,
               current_room: room,
               reality: reality,
               online: true)
      end

      it 'does not find PCs' do
        found = command.send(:find_npc, 'Alice')
        expect(found).to be_nil
      end
    end

    it 'returns nil for non-existent NPC' do
      found = command.send(:find_npc, 'NotExist')
      expect(found).to be_nil
    end
  end
end
