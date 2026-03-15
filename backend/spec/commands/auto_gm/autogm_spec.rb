# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::AutoGm::Autogm, type: :command do
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
  let(:other_character) { create(:character, forename: 'Bob') }
  let(:other_instance) do
    create(:character_instance,
           character: other_character,
           current_room: room,
           reality: reality,
           online: true)
  end

  subject(:command) { described_class.new(character_instance) }

  describe 'command registration' do
    it 'is registered in the command registry' do
      expect(Commands::Base::Registry.commands['autogm']).to eq(described_class)
    end

    it 'has alias agm' do
      cmd_class, = Commands::Base::Registry.find_command('agm')
      expect(cmd_class).to eq(described_class)
    end

    it 'has alias adventure' do
      cmd_class, = Commands::Base::Registry.find_command('adventure')
      expect(cmd_class).to eq(described_class)
    end
  end

  describe 'command metadata' do
    it 'has correct command name' do
      expect(described_class.command_name).to eq('autogm')
    end

    it 'has category staff' do
      expect(described_class.category).to eq(:staff)
    end

    it 'has help text' do
      expect(described_class.help_text).to include('adventure')
    end

    it 'has usage' do
      expect(described_class.usage).to include('autogm')
    end

    it 'has examples' do
      expect(described_class.examples).to include('autogm start')
    end
  end

  describe '#execute' do
    context 'with no arguments or help' do
      it 'shows usage information' do
        result = command.execute('autogm')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Auto-GM Commands')
        expect(result[:message]).to include('autogm start')
        expect(result[:message]).to include('autogm status')
        expect(result[:message]).to include('autogm leave')
        expect(result[:message]).to include('autogm end')
      end

      it 'shows usage with help subcommand' do
        result = command.execute('autogm help')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Auto-GM Commands')
      end

      it 'shows usage with empty string subcommand' do
        result = command.execute('autogm  ')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Auto-GM Commands')
      end
    end

    context 'with unknown subcommand' do
      it 'returns error for invalid subcommand' do
        result = command.execute('autogm invalid')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Unknown subcommand')
        expect(result[:error]).to include('invalid')
      end
    end
  end

  describe '#start_adventure' do
    before do
      # Stub the session service
      allow(::AutoGm::AutoGmSessionService).to receive(:active_session_in_room).and_return(nil)
      allow(::AutoGm::AutoGmSessionService).to receive(:active_sessions_for).and_return([])
      allow(GameSetting).to receive(:get).with('auto_gm_enabled').and_return(nil)
    end

    context 'when auto-gm is disabled by setting' do
      before do
        allow(GameSetting).to receive(:get).with('auto_gm_enabled').and_return(false)
      end

      it 'returns an error and does not start a session' do
        expect(::AutoGm::AutoGmSessionService).not_to receive(:start_session)
        result = command.execute('autogm start')

        expect(result[:success]).to be false
        expect(result[:error]).to include('currently disabled')
      end
    end

    context 'when no active session exists' do
      let(:mock_session) { double('AutoGmSession', id: 123) }

      before do
        allow(::AutoGm::AutoGmSessionService).to receive(:start_session).and_return(mock_session)
      end

      it 'starts a new adventure' do
        result = command.execute('autogm start')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Starting a new Auto-GM adventure')
        expect(result[:message]).to include('Gathering context')
        expect(result[:data][:session_id]).to eq(123)
      end

      it 'works with begin alias' do
        result = command.execute('autogm begin')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Starting a new Auto-GM adventure')
      end

      it 'works with new alias' do
        result = command.execute('autogm new')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Starting a new Auto-GM adventure')
      end

      it 'includes character as participant' do
        expect(::AutoGm::AutoGmSessionService).to receive(:start_session).with(
          hash_including(participants: [character_instance])
        ).and_return(mock_session)

        command.execute('autogm start')
      end
    end

    context 'with other characters specified' do
      let(:mock_session) { double('AutoGmSession', id: 123) }

      before do
        other_instance # Ensure exists
        allow(::AutoGm::AutoGmSessionService).to receive(:start_session).and_return(mock_session)
      end

      it 'includes specified characters as participants' do
        expect(::AutoGm::AutoGmSessionService).to receive(:start_session).with(
          hash_including(participants: array_including(character_instance, other_instance))
        ).and_return(mock_session)

        result = command.execute('autogm start with Bob')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Alice')
        expect(result[:message]).to include('Bob')
      end

      it 'handles "with" keyword' do
        expect(::AutoGm::AutoGmSessionService).to receive(:start_session).with(
          hash_including(participants: array_including(character_instance, other_instance))
        ).and_return(mock_session)

        command.execute('autogm start with Bob')
      end

      it 'handles multiple character names' do
        third_character = create(:character, forename: 'Charlie')
        create(:character_instance,
               character: third_character,
               current_room: room,
               reality: reality,
               online: true)

        result = command.execute('autogm start with Bob Charlie')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Alice')
        expect(result[:message]).to include('Bob')
        expect(result[:message]).to include('Charlie')
      end

      it 'ignores empty names' do
        result = command.execute('autogm start with   ')

        expect(result[:success]).to be true
      end

      it 'returns error for characters not in room' do
        away_character = create(:character, forename: 'Diana')
        other_room = create(:room)
        create(:character_instance,
               character: away_character,
               current_room: other_room,
               reality: reality,
               online: true)

        result = command.execute('autogm start with Diana')

        expect(result[:success]).to be false
        expect(result[:error]).to include("Could not find 'Diana'")
      end
    end

    context 'when active session exists in room' do
      let(:existing_session) do
        double('AutoGmSession',
               sketch: { 'title' => 'Existing Adventure' })
      end

      before do
        allow(::AutoGm::AutoGmSessionService).to receive(:active_session_in_room)
          .and_return(existing_session)
      end

      it 'returns error about existing session' do
        result = command.execute('autogm start')

        expect(result[:success]).to be false
        expect(result[:error]).to include("already an active adventure")
        expect(result[:error]).to include('Existing Adventure')
      end
    end

    context 'when character is already in a session' do
      let(:existing_session) do
        double('AutoGmSession',
               sketch: { 'title' => 'My Adventure' })
      end

      before do
        allow(::AutoGm::AutoGmSessionService).to receive(:active_sessions_for)
          .and_return([existing_session])
      end

      it 'returns error about existing participation' do
        result = command.execute('autogm start')

        expect(result[:success]).to be false
        expect(result[:error]).to include("already in an adventure")
        expect(result[:error]).to include('My Adventure')
      end
    end

    context 'when session service raises ArgumentError' do
      before do
        allow(::AutoGm::AutoGmSessionService).to receive(:start_session)
          .and_raise(ArgumentError.new('Invalid parameters'))
      end

      it 'returns error with message' do
        result = command.execute('autogm start')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Could not start adventure')
        expect(result[:error]).to include('Invalid parameters')
      end
    end

    context 'when session service raises StandardError' do
      before do
        allow(::AutoGm::AutoGmSessionService).to receive(:start_session)
          .and_raise(StandardError.new('Unexpected error'))
      end

      it 'returns error with message' do
        result = command.execute('autogm start')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Error starting adventure')
        expect(result[:error]).to include('Unexpected error')
      end
    end
  end

  describe '#show_status' do
    context 'when character is not in any session' do
      before do
        allow(::AutoGm::AutoGmSessionService).to receive(:active_sessions_for).and_return([])
        allow(::AutoGm::AutoGmSessionService).to receive(:active_session_in_room).and_return(nil)
      end

      it 'returns message about no active adventure' do
        result = command.execute('autogm status')

        expect(result[:success]).to be false
        expect(result[:error]).to include('not in any active adventure')
        expect(result[:error]).to include('autogm start')
      end
    end

    context 'when character is participating in a session' do
      let(:session) do
        double('AutoGmSession',
               sketch: { 'title' => 'Test Adventure' },
               stat_block_id: nil)
      end
      let(:status) do
        {
          title: 'Test Adventure',
          status: 'active',
          current_stage: 1,
          total_stages: 5,
          countdown: nil,
          chaos_level: 3,
          action_count: 10,
          started_at: Time.now - 600,
          elapsed_seconds: 600,
          timeout_in_seconds: 6600,
          in_combat: false,
          resolved: false,
          resolution_type: nil
        }
      end

      before do
        allow(::AutoGm::AutoGmSessionService).to receive(:active_sessions_for)
          .and_return([session])
        allow(::AutoGm::AutoGmSessionService).to receive(:status)
          .and_return(status)
        allow(::AutoGm::AutoGmCompressionService).to receive(:get_relevant_summary)
          .and_return('')
      end

      it 'shows session status' do
        result = command.execute('autogm status')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Adventure: Test Adventure')
        expect(result[:message]).to include('Status: Active')
        expect(result[:message]).to include('Stage 2 of 5')
        expect(result[:message]).to include('Chaos Level: 3/9')
        expect(result[:message]).to include('Actions: 10')
      end

      it 'works with stat alias' do
        result = command.execute('autogm stat')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Adventure: Test Adventure')
      end

      it 'works with info alias' do
        result = command.execute('autogm info')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Adventure: Test Adventure')
      end

      it 'shows countdown when present' do
        status[:countdown] = 'Something is about to happen...'

        result = command.execute('autogm status')

        expect(result[:message]).to include('Countdown:')
      end

      it 'shows combat status when in combat' do
        status[:in_combat] = true

        result = command.execute('autogm status')

        expect(result[:message]).to include('Currently in combat!')
      end

      it 'shows resolution when resolved' do
        status[:resolved] = true
        status[:resolution_type] = 'success'

        result = command.execute('autogm status')

        expect(result[:message]).to include('Resolution: SUCCESS')
      end

      it 'shows recent context when available' do
        allow(::AutoGm::AutoGmCompressionService).to receive(:get_relevant_summary)
          .and_return('The party entered a dark cave.')

        result = command.execute('autogm status')

        expect(result[:message]).to include('Recent events:')
        expect(result[:message]).to include('dark cave')
      end

      it 'truncates long context' do
        long_context = 'A' * 300
        allow(::AutoGm::AutoGmCompressionService).to receive(:get_relevant_summary)
          .and_return(long_context)

        result = command.execute('autogm status')

        expect(result[:message]).to include('...')
      end
    end

    context 'when room has session but character is not participating' do
      let(:room_session) do
        double('AutoGmSession',
               sketch: { 'title' => 'Room Adventure' },
               stat_block_id: nil)
      end
      let(:status) do
        {
          title: 'Room Adventure',
          status: 'active',
          current_stage: 0,
          total_stages: 3,
          countdown: nil,
          chaos_level: 1,
          action_count: 5,
          started_at: Time.now - 300,
          elapsed_seconds: 300,
          timeout_in_seconds: 7000,
          in_combat: false,
          resolved: false,
          resolution_type: nil
        }
      end

      before do
        allow(::AutoGm::AutoGmSessionService).to receive(:active_sessions_for).and_return([])
        allow(::AutoGm::AutoGmSessionService).to receive(:active_session_in_room)
          .and_return(room_session)
        allow(::AutoGm::AutoGmSessionService).to receive(:status).and_return(status)
        allow(::AutoGm::AutoGmCompressionService).to receive(:get_relevant_summary)
          .and_return('')
      end

      it 'shows status with non-participation notice' do
        result = command.execute('autogm status')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Room Adventure')
        expect(result[:message]).to include('not participating')
      end
    end

    context 'when session has no title yet' do
      let(:session) { double('AutoGmSession', sketch: nil, stat_block_id: nil) }
      let(:status) do
        {
          title: nil,
          status: 'initializing',
          current_stage: 0,
          total_stages: 0,
          countdown: nil,
          chaos_level: 5,
          action_count: 0,
          started_at: Time.now,
          elapsed_seconds: 5,
          timeout_in_seconds: 7200,
          in_combat: false,
          resolved: false,
          resolution_type: nil
        }
      end

      before do
        allow(::AutoGm::AutoGmSessionService).to receive(:active_sessions_for)
          .and_return([session])
        allow(::AutoGm::AutoGmSessionService).to receive(:status).and_return(status)
        allow(::AutoGm::AutoGmCompressionService).to receive(:get_relevant_summary)
          .and_return('The adventure has just begun.')
      end

      it 'shows placeholder title' do
        result = command.execute('autogm status')

        expect(result[:message]).to include('being designed')
      end
    end
  end

  describe '#end_adventure' do
    context 'when character is not in any session' do
      before do
        allow(::AutoGm::AutoGmSessionService).to receive(:active_sessions_for).and_return([])
      end

      it 'returns error' do
        result = command.execute('autogm end')

        expect(result[:success]).to be false
        expect(result[:error]).to include('not in any active adventure')
      end

      it 'works with stop alias' do
        result = command.execute('autogm stop')

        expect(result[:success]).to be false
      end

      it 'works with quit alias' do
        result = command.execute('autogm quit')

        expect(result[:success]).to be false
      end

      it 'works with abort alias' do
        result = command.execute('autogm abort')

        expect(result[:success]).to be false
      end
    end

    context 'when character is the initiator' do
      let(:session) do
        double('AutoGmSession',
               id: 1,
               sketch: { 'title' => 'My Adventure' },
               created_by_id: character.id)
      end

      before do
        allow(::AutoGm::AutoGmSessionService).to receive(:active_sessions_for)
          .and_return([session])
      end

      it 'ends the adventure with abandoned resolution by default' do
        expect(::AutoGm::AutoGmSessionService).to receive(:end_session)
          .with(session, hash_including(resolution_type: :abandoned, reason: 'Ended by player'))
          .and_return({ success: true })

        result = command.execute('autogm end')

        expect(result[:success]).to be true
        expect(result[:message]).to include('has ended')
        expect(result[:message]).to include('ABANDONED')
      end

      it 'ends with success resolution' do
        expect(::AutoGm::AutoGmSessionService).to receive(:end_session)
          .with(session, hash_including(resolution_type: :success))
          .and_return({ success: true })

        result = command.execute('autogm end success')

        expect(result[:message]).to include('SUCCESS')
      end

      it 'ends with failure resolution' do
        expect(::AutoGm::AutoGmSessionService).to receive(:end_session)
          .with(session, hash_including(resolution_type: :failure))
          .and_return({ success: true })

        result = command.execute('autogm end failure')

        expect(result[:message]).to include('FAILURE')
      end

      it 'accepts win alias for success' do
        expect(::AutoGm::AutoGmSessionService).to receive(:end_session)
          .with(session, hash_including(resolution_type: :success))
          .and_return({ success: true })

        command.execute('autogm end win')
      end

      it 'accepts victory alias for success' do
        expect(::AutoGm::AutoGmSessionService).to receive(:end_session)
          .with(session, hash_including(resolution_type: :success))
          .and_return({ success: true })

        command.execute('autogm end victory')
      end

      it 'accepts fail alias for failure' do
        expect(::AutoGm::AutoGmSessionService).to receive(:end_session)
          .with(session, hash_including(resolution_type: :failure))
          .and_return({ success: true })

        command.execute('autogm end fail')
      end

      it 'accepts defeat alias for failure' do
        expect(::AutoGm::AutoGmSessionService).to receive(:end_session)
          .with(session, hash_including(resolution_type: :failure))
          .and_return({ success: true })

        command.execute('autogm end defeat')
      end

      it 'shows memory creation notice when present' do
        allow(::AutoGm::AutoGmSessionService).to receive(:end_session)
          .and_return({ success: true, memory: double('memory') })

        result = command.execute('autogm end')

        expect(result[:message]).to include('memory')
        expect(result[:message]).to include('recorded')
      end

      it 'handles end_session failure' do
        allow(::AutoGm::AutoGmSessionService).to receive(:end_session)
          .and_return({ success: false, error: 'Database error' })

        result = command.execute('autogm end')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Failed to end adventure')
        expect(result[:error]).to include('Database error')
      end
    end

    context 'when character is not the initiator' do
      let(:other_character_id) { other_character.id }
      let(:session) do
        double('AutoGmSession',
               id: 1,
               sketch: { 'title' => 'Not My Adventure' },
               created_by_id: other_character_id)
      end

      before do
        allow(::AutoGm::AutoGmSessionService).to receive(:active_sessions_for)
          .and_return([session])
      end

      it 'returns error about not being initiator' do
        result = command.execute('autogm end')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Only the adventure initiator')
        expect(result[:error]).to include("autogm leave")
      end
    end
  end

  describe '#leave_adventure' do
    context 'when character is not in any session' do
      before do
        allow(::AutoGm::AutoGmSessionService).to receive(:active_sessions_for).and_return([])
      end

      it 'returns an error' do
        result = command.execute('autogm leave')
        expect(result[:success]).to be false
        expect(result[:error]).to include('not in any active adventure')
      end
    end

    context 'when leave succeeds but session continues' do
      let(:session) { double('AutoGmSession', sketch: { 'title' => 'My Adventure' }) }

      before do
        allow(::AutoGm::AutoGmSessionService).to receive(:active_sessions_for).and_return([session])
        allow(::AutoGm::AutoGmSessionService).to receive(:leave_session).and_return({ success: true, ended: false })
      end

      it 'returns success message' do
        result = command.execute('autogm leave')
        expect(result[:success]).to be true
        expect(result[:message]).to include('You leave')
      end
    end

    context 'when leave ends the session (last participant)' do
      let(:session) { double('AutoGmSession', sketch: { 'title' => 'My Adventure' }) }

      before do
        allow(::AutoGm::AutoGmSessionService).to receive(:active_sessions_for).and_return([session])
        allow(::AutoGm::AutoGmSessionService).to receive(:leave_session).and_return({ success: true, ended: true })
      end

      it 'mentions that the adventure ended' do
        result = command.execute('autogm leave')
        expect(result[:success]).to be true
        expect(result[:message]).to include('adventure has ended')
      end
    end
  end

  describe '#find_character_in_room' do
    before { other_instance } # Ensure exists

    it 'finds character by exact name match' do
      found = command.send(:find_character_in_room, 'Bob')

      expect(found).to eq(other_instance)
    end

    it 'finds character by partial name match' do
      found = command.send(:find_character_in_room, 'Bo')

      expect(found).to eq(other_instance)
    end

    it 'is case insensitive' do
      found = command.send(:find_character_in_room, 'BOB')

      expect(found).to eq(other_instance)
    end

    it 'returns nil for empty name' do
      found = command.send(:find_character_in_room, '')

      expect(found).to be_nil
    end

    it 'returns nil for nil name' do
      found = command.send(:find_character_in_room, nil)

      expect(found).to be_nil
    end

    it 'does not find offline characters' do
      other_instance.update(online: false)

      found = command.send(:find_character_in_room, 'Bob')

      expect(found).to be_nil
    end

    it 'does not find characters in other rooms' do
      other_room = create(:room)
      other_instance.update(current_room: other_room)

      found = command.send(:find_character_in_room, 'Bob')

      expect(found).to be_nil
    end
  end

  describe '#room alias' do
    it 'returns location' do
      expect(command.room).to eq(command.send(:location))
    end
  end
end
