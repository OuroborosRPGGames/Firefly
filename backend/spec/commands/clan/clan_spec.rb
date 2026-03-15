# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Clan::Clan do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area) }
  let(:room) { create(:room, location: location, name: 'Meeting Hall') }
  let(:reality) { create(:reality) }

  let(:user) { create(:user) }
  let(:character) { create(:character, user: user, forename: 'Clan', surname: 'Leader') }
  let(:character_instance) do
    create(:character_instance,
           character: character,
           reality: reality,
           current_room: room,
           online: true,
           status: 'alive')
  end

  subject(:command) { described_class.new(character_instance) }

  def execute_command(args = nil)
    input = args.nil? ? 'clan' : "clan #{args}"
    command.execute(input)
  end

  describe 'command registration' do
    it 'is registered in the command registry' do
      expect(Commands::Base::Registry.commands['clan']).to eq(described_class)
    end

    it 'has alias clans' do
      cmd_class, _ = Commands::Base::Registry.find_command('clans')
      expect(cmd_class).to eq(described_class)
    end

    it 'has alias guild' do
      cmd_class, _ = Commands::Base::Registry.find_command('guild')
      expect(cmd_class).to eq(described_class)
    end

    it 'has alias group' do
      cmd_class, _ = Commands::Base::Registry.find_command('group')
      expect(cmd_class).to eq(described_class)
    end
  end

  describe 'command metadata' do
    it 'has correct command name' do
      expect(described_class.command_name).to eq('clan')
    end

    it 'has category social' do
      expect(described_class.category).to eq(:social)
    end

    it 'has help text' do
      expect(described_class.help_text).to include('clan')
    end

    it 'has usage' do
      expect(described_class.usage).to include('clan')
    end

    it 'has examples' do
      expect(described_class.examples).to include('clan list')
    end
  end

  describe 'no subcommand' do
    it 'shows help text' do
      result = execute_command(nil)

      expect(result[:success]).to be true
      expect(result[:message]).to include('Clan Commands')
    end
  end

  describe 'subcommand: list' do
    context 'when no clans exist' do
      before do
        allow(ClanService).to receive(:list_clans_for).and_return([])
      end

      it 'shows no clans message' do
        result = execute_command('list')

        expect(result[:success]).to be true
        expect(result[:message]).to include('No clans found')
      end
    end

    context 'when clans exist' do
      let(:clan1) do
        double('Clan',
               display_name: 'The Shadows',
               member_count: 5,
               secret?: false)
      end
      let(:clan2) do
        double('Clan',
               display_name: 'Hidden Order',
               member_count: 3,
               secret?: true)
      end

      before do
        allow(ClanService).to receive(:list_clans_for).and_return([clan1, clan2])
        allow(clan1).to receive(:member?).and_return(true)
        allow(clan2).to receive(:member?).and_return(false)
      end

      it 'lists available clans' do
        result = execute_command('list')

        expect(result[:success]).to be true
        expect(result[:message]).to include('The Shadows')
        expect(result[:message]).to include('5 members')
        expect(result[:message]).to include('[Member]')
      end

      it 'shows secret clans' do
        result = execute_command('list')

        expect(result[:message]).to include('(Secret)')
      end
    end
  end

  describe 'subcommand: create' do
    context 'without name' do
      it 'returns usage error' do
        result = execute_command('create')

        expect(result[:success]).to be false
        expect(result[:message]).to include('Usage')
      end
    end

    context 'with name' do
      let(:clan) { double('Clan', name: 'The Shadows', channel: double('Channel')) }

      before do
        allow(ClanService).to receive(:create_clan).and_return({
          success: true,
          clan: clan,
          message: 'Clan created successfully!'
        })
      end

      it 'creates a clan' do
        expect(ClanService).to receive(:create_clan).with(
          character,
          hash_including(name: 'The Shadows', secret: false)
        )

        execute_command('create The Shadows')
      end

      it 'returns success message' do
        result = execute_command('create The Shadows')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Clan created')
      end

      it 'includes channel info when channel exists' do
        result = execute_command('create The Shadows')

        expect(result[:message]).to include('channel')
      end
    end

    context 'with --secret flag' do
      before do
        allow(ClanService).to receive(:create_clan).and_return({
          success: true,
          clan: double('Clan', name: 'Hidden Order', channel: nil),
          message: 'Secret clan created!'
        })
      end

      it 'creates a secret clan' do
        expect(ClanService).to receive(:create_clan).with(
          character,
          hash_including(secret: true, name: 'Hidden Order')
        )

        execute_command('create --secret Hidden Order')
      end
    end

    context 'when creation fails' do
      before do
        allow(ClanService).to receive(:create_clan).and_return({
          success: false,
          error: 'A clan with that name already exists.'
        })
      end

      it 'returns error' do
        result = execute_command('create Existing Clan')

        expect(result[:success]).to be false
        expect(result[:message]).to include('already exists')
      end
    end
  end

  describe 'subcommand: invite' do
    context 'when not in a clan' do
      before do
        allow(GroupMember).to receive(:where).and_return(
          double('Dataset', eager: double('Dataset', all: []))
        )
      end

      it 'returns error' do
        result = execute_command('invite Alice')

        expect(result[:success]).to be false
        expect(result[:message]).to include("not in a clan")
      end
    end

    context 'when in a single clan' do
      let(:clan) { double('Clan', id: 1, name: 'The Shadows', group_type: 'clan') }
      let(:membership) { double('GroupMember', group: clan) }
      let(:target_char) { double('Character', id: 2, forename: 'Alice') }

      before do
        allow(GroupMember).to receive(:where).and_return(
          double('Dataset', eager: double('Dataset', all: [membership]))
        )
        allow(command).to receive(:find_character_globally).and_return(target_char)
      end

      context 'without target name' do
        it 'returns usage error' do
          result = execute_command('invite')

          expect(result[:success]).to be false
          expect(result[:message]).to include('Usage')
        end
      end

      context 'when target not found' do
        before do
          allow(command).to receive(:find_character_globally).and_return(nil)
        end

        it 'returns not found error' do
          result = execute_command('invite Unknown')

          expect(result[:success]).to be false
          expect(result[:message]).to include('No character found')
        end
      end

      context 'when target found' do
        before do
          allow(ClanService).to receive(:invite_member).and_return({
            success: true,
            message: 'Alice has been invited to The Shadows.'
          })
        end

        it 'invites the member' do
          expect(ClanService).to receive(:invite_member).with(clan, character, target_char, hash_including(:handle))

          execute_command('invite Alice')
        end

        it 'returns success' do
          result = execute_command('invite Alice')

          expect(result[:success]).to be true
          expect(result[:message]).to include('invited')
        end
      end

      context 'with handle option' do
        before do
          allow(ClanService).to receive(:invite_member).and_return({
            success: true,
            message: 'Alice has been invited.'
          })
        end

        it 'passes handle to service' do
          expect(ClanService).to receive(:invite_member).with(
            clan, character, target_char, hash_including(handle: 'ShadowAgent')
          )

          execute_command('invite Alice as ShadowAgent')
        end
      end
    end

    context 'when in multiple clans' do
      let(:clan1) { double('Clan', id: 1, name: 'Shadows', group_type: 'clan', secret?: false, member_count: 5) }
      let(:clan2) { double('Clan', id: 2, name: 'Hidden', group_type: 'clan', secret?: true, member_count: 3) }
      let(:membership1) { double('GroupMember', group: clan1) }
      let(:membership2) { double('GroupMember', group: clan2) }
      let(:target_char) { double('Character', id: 2, forename: 'Alice') }

      before do
        allow(GroupMember).to receive(:where).and_return(
          double('Dataset', eager: double('Dataset', all: [membership1, membership2]))
        )
        allow(command).to receive(:find_character_globally).and_return(target_char)
      end

      it 'returns disambiguation quickmenu' do
        result = execute_command('invite Alice')

        expect(result[:success]).to be true
        expect(result[:type]).to eq(:quickmenu)
        expect(result[:data][:options].size).to be >= 2
      end
    end
  end

  describe 'subcommand: kick' do
    context 'when not in a clan' do
      before do
        allow(GroupMember).to receive(:where).and_return(
          double('Dataset', eager: double('Dataset', all: []))
        )
      end

      it 'returns error' do
        result = execute_command('kick Bob')

        expect(result[:success]).to be false
        expect(result[:message]).to include("not in a clan")
      end
    end

    context 'when in a single clan' do
      let(:clan) { double('Clan', id: 1, name: 'The Shadows', group_type: 'clan') }
      let(:membership) { double('GroupMember', group: clan) }
      let(:target_char) { double('Character', id: 2, forename: 'Bob') }

      before do
        allow(GroupMember).to receive(:where).and_return(
          double('Dataset', eager: double('Dataset', all: [membership]))
        )
        allow(command).to receive(:find_character_globally).and_return(target_char)
        allow(ClanService).to receive(:kick_member).and_return({
          success: true,
          message: 'Bob has been removed from The Shadows.'
        })
      end

      context 'without target name' do
        it 'returns usage error' do
          result = execute_command('kick')

          expect(result[:success]).to be false
          expect(result[:message]).to include('Usage')
        end
      end

      it 'kicks the member' do
        expect(ClanService).to receive(:kick_member).with(clan, character, target_char)

        execute_command('kick Bob')
      end

      it 'returns success' do
        result = execute_command('kick Bob')

        expect(result[:success]).to be true
        expect(result[:message]).to include('removed')
      end
    end
  end

  describe 'subcommand: leave' do
    context 'when not in a clan' do
      before do
        allow(GroupMember).to receive(:where).and_return(
          double('Dataset', eager: double('Dataset', all: []))
        )
      end

      it 'returns error' do
        result = execute_command('leave')

        expect(result[:success]).to be false
        expect(result[:message]).to include("not in a clan")
      end
    end

    context 'when in a single clan' do
      let(:clan) { double('Clan', id: 1, name: 'The Shadows', group_type: 'clan') }
      let(:membership) { double('GroupMember', group: clan) }

      before do
        allow(GroupMember).to receive(:where).and_return(
          double('Dataset', eager: double('Dataset', all: [membership]))
        )
        allow(ClanService).to receive(:leave_clan).and_return({
          success: true,
          message: 'You have left The Shadows.'
        })
      end

      it 'leaves the clan' do
        expect(ClanService).to receive(:leave_clan).with(clan, character)

        execute_command('leave')
      end

      it 'returns success' do
        result = execute_command('leave')

        expect(result[:success]).to be true
        expect(result[:message]).to include('left')
      end
    end

    context 'when in multiple clans' do
      let(:clan1) { double('Clan', id: 1, name: 'Shadows', group_type: 'clan', secret?: false, member_count: 5) }
      let(:clan2) { double('Clan', id: 2, name: 'Hidden', group_type: 'clan', secret?: true, member_count: 3) }
      let(:membership1) { double('GroupMember', group: clan1) }
      let(:membership2) { double('GroupMember', group: clan2) }

      before do
        allow(GroupMember).to receive(:where).and_return(
          double('Dataset', eager: double('Dataset', all: [membership1, membership2]))
        )
      end

      it 'returns disambiguation quickmenu' do
        result = execute_command('leave')

        expect(result[:success]).to be true
        expect(result[:type]).to eq(:quickmenu)
      end
    end
  end

  describe 'subcommand: info' do
    context 'when in a single clan without specifying name' do
      let(:clan) do
        double('Clan',
               id: 1,
               name: 'shadows',
               display_name: 'The Shadows',
               group_type: 'clan',
               member_count: 5,
               founded_at: Time.now - 86400,
               description: 'A secret organization',
               secret?: false,
               channel: double('Channel'))
      end
      let(:membership) { double('GroupMember', group: clan, rank: 'leader') }

      before do
        allow(GroupMember).to receive(:where).and_return(
          double('Dataset', eager: double('Dataset', all: [membership]))
        )
        allow(clan).to receive(:membership_for).and_return(membership)
      end

      it 'shows clan info' do
        result = execute_command('info')

        expect(result[:success]).to be true
        expect(result[:message]).to include('The Shadows')
        expect(result[:message]).to include('5')
      end

      it 'shows membership rank' do
        result = execute_command('info')

        expect(result[:message]).to include('Leader')
      end

      it 'shows description' do
        result = execute_command('info')

        expect(result[:message]).to include('secret organization')
      end
    end

    context 'when in multiple clans without specifying name' do
      let(:clan1) { double('Clan', id: 1, name: 'Shadows', display_name: 'The Shadows', group_type: 'clan', channel: nil) }
      let(:clan2) { double('Clan', id: 2, name: 'Hidden', display_name: 'The Hidden', group_type: 'clan', channel: double('Channel')) }
      let(:membership1) { double('GroupMember', group: clan1, rank: 'leader') }
      let(:membership2) { double('GroupMember', group: clan2, rank: 'member') }

      before do
        allow(GroupMember).to receive(:where).and_return(
          double('Dataset', eager: double('Dataset', all: [membership1, membership2]))
        )
        allow(clan1).to receive(:membership_for).and_return(membership1)
        allow(clan2).to receive(:membership_for).and_return(membership2)
      end

      it 'lists all clans' do
        result = execute_command('info')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Your Clans')
        expect(result[:message]).to include('The Shadows')
        expect(result[:message]).to include('The Hidden')
      end
    end

    context 'when specifying a clan name' do
      let(:clan) do
        double('Clan',
               id: 1,
               display_name: 'Guild of Heroes',
               group_type: 'clan',
               member_count: 10,
               founded_at: Time.now,
               description: nil,
               secret?: false,
               channel: nil)
      end

      before do
        allow(GroupMember).to receive(:where).and_return(
          double('Dataset', eager: double('Dataset', all: []))
        )
        allow(ClanService).to receive(:find_clan_by_name_prefix).and_return(clan)
        allow(clan).to receive(:member?).and_return(false)
        allow(clan).to receive(:membership_for).and_return(nil)
      end

      it 'shows the specified clan info' do
        result = execute_command('info Guild')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Guild of Heroes')
      end
    end

    context 'when clan not found' do
      before do
        allow(GroupMember).to receive(:where).and_return(
          double('Dataset', eager: double('Dataset', all: []))
        )
        allow(ClanService).to receive(:find_clan_by_name_prefix).and_return(nil)
      end

      it 'returns error' do
        result = execute_command('info Unknown')

        expect(result[:success]).to be false
        expect(result[:message]).to include('not found')
      end
    end

    context 'when secret clan and not a member' do
      let(:clan) { double('Clan', secret?: true) }

      before do
        allow(GroupMember).to receive(:where).and_return(
          double('Dataset', eager: double('Dataset', all: []))
        )
        allow(ClanService).to receive(:find_clan_by_name_prefix).and_return(clan)
        allow(clan).to receive(:member?).and_return(false)
      end

      it 'returns secret error' do
        result = execute_command('info SecretClan')

        expect(result[:success]).to be false
        expect(result[:message]).to include('secret')
      end
    end
  end

  describe 'subcommand: roster' do
    context 'when in a single clan' do
      let(:clan) do
        double('Clan',
               id: 1,
               name: 'shadows',
               display_name: 'The Shadows',
               group_type: 'clan',
               secret?: false)
      end
      let(:membership) { double('GroupMember', group: clan) }
      let(:roster_data) do
        [
          { display_name: 'Alice', rank: 'leader', is_leader: true },
          { display_name: 'Bob', rank: 'member', is_leader: false }
        ]
      end

      before do
        allow(GroupMember).to receive(:where).and_return(
          double('Dataset', eager: double('Dataset', all: [membership]))
        )
        allow(clan).to receive(:roster_for).and_return(roster_data)
        allow(clan).to receive(:member?).and_return(true)
      end

      it 'shows the roster' do
        result = execute_command('roster')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Alice')
        expect(result[:message]).to include('[Leader]')
        expect(result[:message]).to include('Bob')
        expect(result[:message]).to include('[Member]')
      end
    end

    context 'when in multiple clans without specifying name' do
      let(:clan1) { double('Clan', id: 1, name: 'Shadows', group_type: 'clan') }
      let(:clan2) { double('Clan', id: 2, name: 'Hidden', group_type: 'clan') }
      let(:membership1) { double('GroupMember', group: clan1) }
      let(:membership2) { double('GroupMember', group: clan2) }

      before do
        allow(GroupMember).to receive(:where).and_return(
          double('Dataset', eager: double('Dataset', all: [membership1, membership2]))
        )
      end

      it 'returns error asking to specify' do
        result = execute_command('roster')

        expect(result[:success]).to be false
        expect(result[:message]).to include('multiple clans')
      end
    end
  end

  describe 'subcommand: memo' do
    context 'when not in a clan' do
      before do
        allow(GroupMember).to receive(:where).and_return(
          double('Dataset', eager: double('Dataset', all: []))
        )
      end

      it 'returns error' do
        result = execute_command('memo')

        expect(result[:success]).to be false
        expect(result[:message]).to include("not in a clan")
      end
    end

    context 'when in a single clan' do
      let(:clan) { double('Clan', id: 1, name: 'Shadows', display_name: 'The Shadows', group_type: 'clan') }
      let(:membership) { double('GroupMember', group: clan) }

      before do
        allow(GroupMember).to receive(:where).and_return(
          double('Dataset', eager: double('Dataset', all: [membership]))
        )
      end

      it 'shows compose form' do
        result = execute_command('memo')

        expect(result[:interaction_id]).not_to be_nil
      end
    end

    context 'when in multiple clans' do
      let(:clan1) { double('Clan', id: 1, name: 'Shadows', group_type: 'clan', secret?: false, member_count: 5) }
      let(:clan2) { double('Clan', id: 2, name: 'Hidden', group_type: 'clan', secret?: true, member_count: 3) }
      let(:membership1) { double('GroupMember', group: clan1) }
      let(:membership2) { double('GroupMember', group: clan2) }

      before do
        allow(GroupMember).to receive(:where).and_return(
          double('Dataset', eager: double('Dataset', all: [membership1, membership2]))
        )
      end

      it 'returns disambiguation quickmenu' do
        result = execute_command('memo')

        expect(result[:success]).to be true
        expect(result[:type]).to eq(:quickmenu)
      end
    end

    describe 'form submission' do
      let(:clan) { double('Clan', id: 1, name: 'Shadows', display_name: 'The Shadows', group_type: 'clan') }
      let(:membership) { double('GroupMember', group: clan) }

      before do
        allow(GroupMember).to receive(:where).and_return(
          double('Dataset', eager: double('Dataset', all: [membership]))
        )
        allow(Group).to receive(:[]).with(1).and_return(clan)
      end

      context 'with valid form data' do
        before do
          allow(ClanService).to receive(:send_clan_memo).and_return({
            success: true,
            message: 'Memo sent to 5 members.'
          })
        end

        it 'sends the memo' do
          expect(ClanService).to receive(:send_clan_memo).with(
            clan, character, hash_including(subject: 'Meeting', body: 'We meet at dawn')
          )

          command.send(:handle_form_response,
            { 'subject' => 'Meeting', 'body' => 'We meet at dawn' },
            { 'action' => 'memo', 'clan_id' => 1 })
        end

        it 'returns success' do
          result = command.send(:handle_form_response,
            { 'subject' => 'Meeting', 'body' => 'We meet at dawn' },
            { 'action' => 'memo', 'clan_id' => 1 })

          expect(result[:success]).to be true
          expect(result[:message]).to include('sent')
        end
      end

      context 'with missing subject' do
        it 'returns error' do
          result = command.send(:handle_form_response,
            { 'subject' => '', 'body' => 'Hello' },
            { 'action' => 'memo', 'clan_id' => 1 })

          expect(result[:success]).to be false
          expect(result[:message]).to include('Subject is required')
        end
      end

      context 'with missing body' do
        it 'returns error' do
          result = command.send(:handle_form_response,
            { 'subject' => 'Meeting', 'body' => '' },
            { 'action' => 'memo', 'clan_id' => 1 })

          expect(result[:success]).to be false
          expect(result[:message]).to include('body is required')
        end
      end

      context 'with invalid clan' do
        before do
          allow(Group).to receive(:[]).with(999).and_return(nil)
        end

        it 'returns error' do
          result = command.send(:handle_form_response,
            { 'subject' => 'Meeting', 'body' => 'Hello' },
            { 'action' => 'memo', 'clan_id' => 999 })

          expect(result[:success]).to be false
          expect(result[:message]).to include('Clan not found')
        end
      end
    end
  end

  describe 'subcommand: handle' do
    context 'when not in a clan' do
      before do
        allow(GroupMember).to receive(:where).and_return(
          double('Dataset', eager: double('Dataset', all: []))
        )
      end

      it 'returns error' do
        result = execute_command('handle ShadowMaster')

        expect(result[:success]).to be false
        expect(result[:message]).to include("not in a clan")
      end
    end

    context 'when in a single clan' do
      let(:clan) { double('Clan', id: 1, name: 'Shadows', group_type: 'clan') }
      let(:membership) { double('GroupMember', group: clan, handle: 'Alpha', default_greek_handle: 'Alpha') }

      before do
        allow(GroupMember).to receive(:where).and_return(
          double('Dataset', eager: double('Dataset', all: [membership]))
        )
        allow(clan).to receive(:membership_for).and_return(membership)
      end

      context 'without new handle' do
        it 'shows current handle' do
          result = execute_command('handle')

          expect(result[:success]).to be true
          expect(result[:message]).to include('Alpha')
        end
      end

      context 'with new handle' do
        before do
          allow(ClanService).to receive(:set_handle).and_return({
            success: true,
            message: 'Handle changed to ShadowMaster.'
          })
        end

        it 'sets the handle' do
          expect(ClanService).to receive(:set_handle).with(clan, character, 'ShadowMaster')

          execute_command('handle ShadowMaster')
        end

        it 'returns success' do
          result = execute_command('handle ShadowMaster')

          expect(result[:success]).to be true
          expect(result[:message]).to include('ShadowMaster')
        end
      end
    end

    context 'when in multiple clans' do
      let(:clan1) { double('Clan', id: 1, name: 'Shadows', group_type: 'clan', secret?: false, member_count: 5) }
      let(:clan2) { double('Clan', id: 2, name: 'Hidden', group_type: 'clan', secret?: true, member_count: 3) }
      let(:membership1) { double('GroupMember', group: clan1, handle: 'Alpha', default_greek_handle: 'Alpha') }
      let(:membership2) { double('GroupMember', group: clan2, handle: 'Beta', default_greek_handle: 'Beta') }

      before do
        allow(GroupMember).to receive(:where).and_return(
          double('Dataset', eager: double('Dataset', all: [membership1, membership2]))
        )
        allow(clan1).to receive(:membership_for).and_return(membership1)
        allow(clan2).to receive(:membership_for).and_return(membership2)
      end

      context 'without new handle' do
        it 'shows handles for all clans' do
          result = execute_command('handle')

          expect(result[:success]).to be true
          expect(result[:message]).to include('Your Clan Handles')
        end
      end

      context 'with new handle' do
        it 'returns disambiguation quickmenu' do
          result = execute_command('handle NewName')

          expect(result[:success]).to be true
          expect(result[:type]).to eq(:quickmenu)
        end
      end
    end
  end

  describe 'subcommand: grant' do
    context 'when not in a clan' do
      before do
        allow(GroupMember).to receive(:where).and_return(
          double('Dataset', eager: double('Dataset', all: []))
        )
      end

      it 'returns error' do
        result = execute_command('grant')

        expect(result[:success]).to be false
        expect(result[:message]).to include("not in a clan")
      end
    end

    context 'when in a clan' do
      let(:clan) { double('Clan', id: 1, name: 'Shadows', display_name: 'The Shadows', group_type: 'clan') }
      let(:membership) { double('GroupMember', group: clan, rank: 'leader') }

      before do
        allow(GroupMember).to receive(:where).and_return(
          double('Dataset', eager: double('Dataset', all: [membership]))
        )
        allow(clan).to receive(:membership_for).and_return(membership)
        allow(membership).to receive(:officer?).and_return(true)
        allow(clan).to receive(:grant_room_access!)
      end

      context 'when not property owner' do
        before do
          allow(command).to receive(:require_property_ownership).and_return(
            { success: false, message: 'You do not own this property.' }
          )
        end

        it 'returns ownership error' do
          result = execute_command('grant')

          expect(result[:success]).to be false
          expect(result[:message]).to include('not own')
        end
      end

      context 'when property owner but not officer' do
        before do
          allow(command).to receive(:require_property_ownership).and_return(nil)
          allow(membership).to receive(:officer?).and_return(false)
        end

        it 'returns permission error' do
          result = execute_command('grant')

          expect(result[:success]).to be false
          expect(result[:message]).to include('Only officers')
        end
      end

      context 'when property owner and officer' do
        before do
          allow(command).to receive(:require_property_ownership).and_return(nil)
          allow(command).to receive(:location).and_return(room)
        end

        it 'grants room access' do
          expect(clan).to receive(:grant_room_access!).with(room, permanent: true)

          execute_command('grant')
        end

        it 'returns success' do
          result = execute_command('grant')

          expect(result[:success]).to be true
          expect(result[:message]).to include('can now enter')
        end
      end
    end
  end

  describe 'subcommand: revoke' do
    context 'when in a clan as officer' do
      let(:clan) { double('Clan', id: 1, name: 'Shadows', display_name: 'The Shadows', group_type: 'clan') }
      let(:membership) { double('GroupMember', group: clan, rank: 'leader') }

      before do
        allow(GroupMember).to receive(:where).and_return(
          double('Dataset', eager: double('Dataset', all: [membership]))
        )
        allow(clan).to receive(:membership_for).and_return(membership)
        allow(membership).to receive(:officer?).and_return(true)
        allow(clan).to receive(:revoke_room_access!)
        allow(command).to receive(:require_property_ownership).and_return(nil)
        allow(command).to receive(:location).and_return(room)
      end

      it 'revokes room access' do
        expect(clan).to receive(:revoke_room_access!).with(room)

        execute_command('revoke')
      end

      it 'returns success' do
        result = execute_command('revoke')

        expect(result[:success]).to be true
        expect(result[:message]).to include('no longer enter')
      end
    end
  end

  describe 'unknown subcommand' do
    it 'shows help' do
      result = execute_command('unknown')

      expect(result[:success]).to be true
      expect(result[:message]).to include('Clan Commands')
    end
  end
end
