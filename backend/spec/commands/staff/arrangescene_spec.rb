# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Staff::ArrangeScene, type: :command do
  let(:room) { create(:room, name: 'Town Square') }
  let(:meeting_room) { create(:room, name: 'Reception Hall') }
  let(:rp_room) { create(:room, name: 'Private Office') }
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
  let(:pc_user) { create(:user) }
  let(:pc_character) { create(:character, user: pc_user, forename: 'Alice') }

  subject(:command) { described_class.new(character_instance) }

  describe 'command registration' do
    it 'is registered in the command registry' do
      expect(Commands::Base::Registry.commands['arrangescene']).to eq(described_class)
    end

    it 'has alias setupscene' do
      cmd_class, = Commands::Base::Registry.find_command('setupscene')
      expect(cmd_class).to eq(described_class)
    end

    it 'has alias createscene' do
      cmd_class, = Commands::Base::Registry.find_command('createscene')
      expect(cmd_class).to eq(described_class)
    end
  end

  describe 'command metadata' do
    it 'has correct command name' do
      expect(described_class.command_name).to eq('arrangescene')
    end

    it 'has category staff' do
      expect(described_class.category).to eq(:staff)
    end

    it 'has help text' do
      expect(described_class.help_text).to include('Arrange')
    end

    it 'has usage' do
      expect(described_class.usage).to include('arrangescene')
    end

    it 'has examples' do
      expect(described_class.examples).to include('arrangescene Bob for Carol at tavern')
    end
  end

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
        result = non_staff_command.execute('arrangescene Merchant for Alice at tavern')

        expect(result[:success]).to be false
        expect(result[:error]).to include('staff members')
      end
    end

    context 'with empty arguments' do
      it 'shows usage message' do
        result = command.execute('arrangescene')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Usage')
        expect(result[:error]).to include('<npc> for <pc>')
      end
    end

    context 'with invalid format' do
      it 'shows usage message for missing "for" keyword' do
        result = command.execute('arrangescene Merchant Alice tavern')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Usage')
      end
    end

    context 'with valid format: <npc> for <pc> at <room>' do
      before do
        npc_character
        pc_character
        meeting_room
      end

      it 'creates arranged scene successfully' do
        scene_mock = double('ArrangedScene',
                            id: 1,
                            display_name: 'Meeting with Merchant')
        allow(ArrangedSceneService).to receive(:create_scene)
          .and_return({ success: true, scene: scene_mock })

        result = command.execute('arrangescene Merchant for Alice at Reception Hall')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Arranged scene created')
        expect(result[:message]).to include('Merchant')
        expect(result[:message]).to include('Alice')
        expect(result[:data][:action]).to eq('scene_created')
      end

      it 'returns error when NPC not found' do
        result = command.execute('arrangescene NotExist for Alice at Reception Hall')

        expect(result[:success]).to be false
        expect(result[:error]).to include("Could not find an NPC named 'NotExist'")
      end

      it 'returns error when PC not found' do
        result = command.execute('arrangescene Merchant for NotExist at Reception Hall')

        expect(result[:success]).to be false
        expect(result[:error]).to include("Could not find a PC named 'NotExist'")
      end

      it 'returns error when room not found' do
        result = command.execute('arrangescene Merchant for Alice at NotExist')

        expect(result[:success]).to be false
        expect(result[:error]).to include("Could not find a room named 'NotExist'")
      end

      it 'handles service failure' do
        allow(ArrangedSceneService).to receive(:create_scene)
          .and_return({ success: false, message: 'Scene creation failed' })

        result = command.execute('arrangescene Merchant for Alice at Reception Hall')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Scene creation failed')
      end
    end

    context 'with valid format: <npc> for <pc> meeting <room1> rp <room2>' do
      before do
        npc_character
        pc_character
        meeting_room
        rp_room
      end

      it 'creates scene with separate meeting and RP rooms' do
        scene_mock = double('ArrangedScene',
                            id: 1,
                            display_name: 'Meeting with Merchant')
        allow(ArrangedSceneService).to receive(:create_scene)
          .with(hash_including(
                  meeting_room: meeting_room,
                  rp_room: rp_room
                ))
          .and_return({ success: true, scene: scene_mock })

        result = command.execute('arrangescene Merchant for Alice meeting Reception Hall rp Private Office')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Reception Hall')
        expect(result[:message]).to include('Private Office')
      end

      it 'returns error when RP room not found' do
        result = command.execute('arrangescene Merchant for Alice meeting Reception Hall rp NotExist')

        expect(result[:success]).to be false
        expect(result[:error]).to include("Could not find a room named 'NotExist'")
      end
    end
  end

  describe '#find_npc' do
    before { npc_character }

    it 'finds NPC by exact name' do
      found = command.send(:find_npc, 'Merchant')
      expect(found).to eq(npc_character)
    end

    it 'finds NPC by partial name' do
      found = command.send(:find_npc, 'Merch')
      expect(found).to eq(npc_character)
    end

    it 'is case insensitive' do
      found = command.send(:find_npc, 'MERCHANT')
      expect(found).to eq(npc_character)
    end

    it 'returns nil for non-existent NPC' do
      found = command.send(:find_npc, 'NotExist')
      expect(found).to be_nil
    end
  end

  describe '#find_pc' do
    before { pc_character }

    it 'finds PC by exact name' do
      found = command.send(:find_pc, 'Alice')
      expect(found).to eq(pc_character)
    end

    it 'finds PC by partial name' do
      found = command.send(:find_pc, 'Ali')
      expect(found).to eq(pc_character)
    end

    it 'is case insensitive' do
      found = command.send(:find_pc, 'ALICE')
      expect(found).to eq(pc_character)
    end

    it 'returns nil for non-existent PC' do
      found = command.send(:find_pc, 'NotExist')
      expect(found).to be_nil
    end
  end

  describe '#find_room' do
    before { meeting_room }

    it 'finds room by exact name' do
      found = command.send(:find_room, 'Reception Hall')
      expect(found).to eq(meeting_room)
    end

    it 'finds room by partial name' do
      found = command.send(:find_room, 'Reception')
      expect(found).to eq(meeting_room)
    end

    it 'is case insensitive' do
      found = command.send(:find_room, 'RECEPTION HALL')
      expect(found).to eq(meeting_room)
    end

    it 'returns nil for non-existent room' do
      found = command.send(:find_room, 'NotExist')
      expect(found).to be_nil
    end
  end

  describe '#parse_scene_command' do
    it 'parses "npc for pc at room" format' do
      result = command.send(:parse_scene_command, 'Bob for Alice at tavern')

      expect(result[:success]).to be true
      expect(result[:npc_name]).to eq('Bob')
      expect(result[:pc_name]).to eq('Alice')
      expect(result[:meeting_room]).to eq('tavern')
      expect(result[:rp_room]).to be_nil
    end

    it 'parses "npc for pc meeting room1 rp room2" format' do
      result = command.send(:parse_scene_command, 'Bob for Alice meeting reception rp office')

      expect(result[:success]).to be true
      expect(result[:npc_name]).to eq('Bob')
      expect(result[:pc_name]).to eq('Alice')
      expect(result[:meeting_room]).to eq('reception')
      expect(result[:rp_room]).to eq('office')
    end

    it 'handles names with spaces' do
      result = command.send(:parse_scene_command, 'Old Merchant for Alice Smith at Town Square')

      expect(result[:success]).to be true
      expect(result[:npc_name]).to eq('Old Merchant')
      expect(result[:pc_name]).to eq('Alice Smith')
      expect(result[:meeting_room]).to eq('Town Square')
    end

    it 'returns error for invalid format' do
      result = command.send(:parse_scene_command, 'invalid format text')

      expect(result[:success]).to be false
      expect(result[:message]).to include('Usage')
    end
  end
end
