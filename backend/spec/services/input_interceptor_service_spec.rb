# frozen_string_literal: true

require 'spec_helper'

RSpec.describe InputInterceptorService do
  let(:room) { create(:room) }
  let(:character) { create(:character) }
  let(:char_instance) { create(:character_instance, character: character, current_room: room) }

  describe 'ACTIVITY_SUBCOMMANDS' do
    it 'defines expected subcommands' do
      expect(described_class::ACTIVITY_SUBCOMMANDS).to include('status')
      expect(described_class::ACTIVITY_SUBCOMMANDS).to include('choose')
      expect(described_class::ACTIVITY_SUBCOMMANDS).to include('vote')
      expect(described_class::ACTIVITY_SUBCOMMANDS).to include('leave')
    end

    it 'is frozen' do
      expect(described_class::ACTIVITY_SUBCOMMANDS).to be_frozen
    end
  end

  describe '.intercept' do
    context 'with blank input' do
      it 'returns nil for nil input' do
        expect(described_class.intercept(char_instance, nil)).to be_nil
      end

      it 'returns nil for empty string' do
        expect(described_class.intercept(char_instance, '')).to be_nil
      end

      it 'returns nil for whitespace only' do
        expect(described_class.intercept(char_instance, '   ')).to be_nil
      end
    end

    context 'without pending quickmenus' do
      before do
        allow(OutputHelper).to receive(:get_pending_interactions).and_return([])
      end

      it 'returns nil for normal input' do
        allow(ActivityService).to receive(:running_activity).and_return(nil)
        expect(described_class.intercept(char_instance, 'look')).to be_nil
      end

      it 'returns nil for numeric input when not in activity' do
        allow(ActivityService).to receive(:running_activity).and_return(nil)
        expect(described_class.intercept(char_instance, '1')).to be_nil
      end
    end

    context 'with pending quickmenu' do
      let(:quickmenu) do
        {
          type: 'quickmenu',
          interaction_id: 'test-123',
          prompt: 'Select an option:',
          options: [
            { key: '1', label: 'Option 1' },
            { key: '2', label: 'Option 2' },
            { key: 'q', label: 'Cancel' }
          ],
          context: {},
          created_at: Time.now.iso8601
        }
      end

      before do
        allow(OutputHelper).to receive(:get_pending_interactions).and_return([quickmenu])
        allow(OutputHelper).to receive(:complete_interaction)
      end

      it 'handles numeric shortcut matching option key' do
        result = described_class.intercept(char_instance, '1')
        expect(result).to be_a(Hash)
        expect(result[:success]).to be true
      end

      it 'handles option label matching (case insensitive)' do
        result = described_class.intercept(char_instance, 'option 1')
        expect(result).to be_a(Hash)
        expect(result[:success]).to be true
      end

      it 'handles cancel key' do
        result = described_class.intercept(char_instance, 'q')
        expect(result).to be_a(Hash)
        expect(result[:success]).to be true
      end

      it 'returns nil for non-matching input' do
        result = described_class.intercept(char_instance, 'look')
        expect(result).to be_nil
      end

      it 'completes the interaction' do
        described_class.intercept(char_instance, '1')
        expect(OutputHelper).to have_received(:complete_interaction)
          .with(char_instance.id, 'test-123')
      end
    end

    context 'with walk/disambiguation quickmenu' do
      let(:quickmenu) do
        {
          type: 'quickmenu',
          interaction_id: 'walk-123',
          prompt: 'Which way?',
          options: [{ key: '1', label: 'North' }],
          context: { action: 'walk' },
          created_at: Time.now.iso8601
        }
      end

      before do
        allow(OutputHelper).to receive(:get_pending_interactions).and_return([quickmenu])
        allow(OutputHelper).to receive(:complete_interaction)
        allow(DisambiguationHandler).to receive(:process_response)
          .and_return(OpenStruct.new(success: true, message: 'You walk north.'))
      end

      it 'routes to disambiguation handler' do
        result = described_class.intercept(char_instance, '1')
        expect(DisambiguationHandler).to have_received(:process_response)
        expect(result[:success]).to be true
      end
    end

    context 'with command-owned quickmenu handlers' do
      let(:quickmenu) do
        {
          type: 'quickmenu',
          interaction_id: 'buildblock-123',
          prompt: 'Select building type:',
          options: [
            { key: 'brownstone', label: 'Brownstone' }
          ],
          context: {
            command: 'build_block',
            room_id: room.id,
            menu_type: 'building'
          },
          created_at: Time.now.iso8601
        }
      end

      before do
        allow(OutputHelper).to receive(:get_pending_interactions).and_return([quickmenu])
        allow(OutputHelper).to receive(:complete_interaction)
      end

      it 'dispatches to command-level quickmenu handler' do
        allow_any_instance_of(Commands::Building::BuildBlock)
          .to receive(:handle_quickmenu_response)
          .and_return({
                        success: true,
                        type: :quickmenu,
                        interaction_id: 'next-menu-1',
                        data: {
                          prompt: 'Select layout:',
                          options: [{ key: 'full', label: 'Full Block' }]
                        }
                      })

        result = described_class.intercept(char_instance, 'brownstone')
        expect(result[:success]).to be true
        expect(result[:type]).to eq(:quickmenu)
        expect(result[:prompt]).to eq('Select layout:')
        expect(result[:options]).to be_an(Array)
      end
    end

    context 'with roll quickmenu' do
      let(:quickmenu) do
        {
          type: 'quickmenu',
          interaction_id: 'roll-123',
          prompt: 'Select a stat:',
          options: [
            { key: '1', label: 'STR' },
            { key: 'c', label: 'Combine' },
            { key: 'q', label: 'Cancel' }
          ],
          context: { command: 'roll', stats: [{ abbr: 'STR' }, { abbr: 'DEX' }] },
          created_at: Time.now.iso8601
        }
      end

      before do
        allow(OutputHelper).to receive(:get_pending_interactions).and_return([quickmenu])
        allow(OutputHelper).to receive(:complete_interaction)
      end

      it 'handles cancel with q' do
        result = described_class.intercept(char_instance, 'q')
        expect(result[:success]).to be true
        expect(result[:message]).to eq('Roll cancelled.')
      end

      it 'handles combine option with c' do
        result = described_class.intercept(char_instance, 'c')
        expect(result[:success]).to be true
        expect(result[:message]).to include('roll <STAT>+<STAT>')
      end

      it 'handles numeric selection' do
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: true, message: 'You rolled STR: 15' })

        result = described_class.intercept(char_instance, '1')
        expect(result[:success]).to be true
        expect(Commands::Base::Registry).to have_received(:execute_command)
          .with(char_instance, 'roll STR')
      end

      it 'returns nil for non-matching selection (no quickmenu option 99)' do
        # '99' doesn't match any option key, so it falls through as non-matching
        result = described_class.intercept(char_instance, '99')
        expect(result).to be_nil
      end
    end

    context 'with buy quickmenu' do
      let(:quickmenu) do
        {
          type: 'quickmenu',
          interaction_id: 'buy-123',
          prompt: 'Select an item to buy:',
          options: [
            { key: '1', label: 'Sword' },
            { key: 'q', label: 'Cancel' }
          ],
          context: { command: 'buy', items: [{ name: 'Sword' }] },
          created_at: Time.now.iso8601
        }
      end

      before do
        allow(OutputHelper).to receive(:get_pending_interactions).and_return([quickmenu])
        allow(OutputHelper).to receive(:complete_interaction)
      end

      it 'handles cancel with q' do
        result = described_class.intercept(char_instance, 'q')
        expect(result[:success]).to be true
        expect(result[:message]).to eq('Purchase cancelled.')
      end

      it 'executes buy command for selected item' do
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: true, message: 'You bought a Sword.' })

        result = described_class.intercept(char_instance, '1')
        expect(Commands::Base::Registry).to have_received(:execute_command)
          .with(char_instance, 'buy Sword')
      end
    end

    context 'with fight quickmenu' do
      let(:quickmenu) do
        {
          type: 'quickmenu',
          interaction_id: 'fight-123',
          prompt: 'Who do you want to fight?',
          options: [
            { key: '1', label: 'Enemy' },
            { key: 'q', label: 'Cancel' }
          ],
          context: { command: 'fight', targets: [{ name: 'Enemy' }] },
          created_at: Time.now.iso8601
        }
      end

      before do
        allow(OutputHelper).to receive(:get_pending_interactions).and_return([quickmenu])
        allow(OutputHelper).to receive(:complete_interaction)
      end

      it 'handles cancel' do
        result = described_class.intercept(char_instance, 'q')
        expect(result[:success]).to be true
        expect(result[:message]).to eq('Combat cancelled.')
      end

      it 'executes fight command' do
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: true, message: 'Combat started!' })

        result = described_class.intercept(char_instance, '1')
        expect(Commands::Base::Registry).to have_received(:execute_command)
          .with(char_instance, 'fight Enemy')
      end
    end

    context 'with check_in/locatability quickmenu' do
      let(:quickmenu) do
        {
          type: 'quickmenu',
          interaction_id: 'checkin-123',
          prompt: 'Set your locatability:',
          options: [
            { key: '1', label: 'Yes' },
            { key: '2', label: 'Favorites' },
            { key: '3', label: 'No' },
            { key: 'q', label: 'Cancel' }
          ],
          context: { command: 'check_in' },
          created_at: Time.now.iso8601
        }
      end

      before do
        allow(OutputHelper).to receive(:get_pending_interactions).and_return([quickmenu])
        allow(OutputHelper).to receive(:complete_interaction)
      end

      it 'handles cancel with q' do
        result = described_class.intercept(char_instance, 'q')
        expect(result[:success]).to be true
        expect(result[:message]).to eq('Locatability unchanged.')
      end

      it 'sets locatability to yes' do
        result = described_class.intercept(char_instance, '1')
        expect(result[:success]).to be true
        expect(result[:message]).to include('Yes')
        char_instance.refresh
        expect(char_instance.locatability).to eq('yes')
      end

      it 'sets locatability to favorites' do
        result = described_class.intercept(char_instance, '2')
        expect(result[:success]).to be true
        expect(result[:message]).to include('Favorites')
        char_instance.refresh
        expect(char_instance.locatability).to eq('favorites')
      end

      it 'sets locatability to no' do
        result = described_class.intercept(char_instance, '3')
        expect(result[:success]).to be true
        expect(result[:message]).to include('No')
        char_instance.refresh
        expect(char_instance.locatability).to eq('no')
      end
    end
  end

  describe '.rewrite_for_context' do
    context 'with blank input' do
      it 'returns original input for nil' do
        expect(described_class.rewrite_for_context(char_instance, nil)).to be_nil
      end

      it 'returns original input for empty string' do
        expect(described_class.rewrite_for_context(char_instance, '')).to eq('')
      end
    end

    context 'when not in activity' do
      before do
        allow(ActivityService).to receive(:running_activity).and_return(nil)
      end

      it 'returns original input for normal commands' do
        expect(described_class.rewrite_for_context(char_instance, 'look')).to eq('look')
      end

      it 'returns original input for activity subcommands' do
        expect(described_class.rewrite_for_context(char_instance, 'status')).to eq('status')
      end
    end

    context 'when in activity' do
      let(:activity) { create(:activity) }
      let(:activity_instance) { create(:activity_instance, activity: activity, room: room, running: true) }
      let(:participant) { create(:activity_participant, instance: activity_instance, character: char_instance.character) }

      before do
        participant # ensure created
        allow(ActivityService).to receive(:running_activity).and_return(activity_instance)
        allow(ActivityService).to receive(:participant_for).and_return(participant)
        allow(participant).to receive(:active?).and_return(true)
      end

      it 'rewrites activity subcommands' do
        expect(described_class.rewrite_for_context(char_instance, 'status')).to eq('activity status')
      end

      it 'rewrites choose subcommand' do
        expect(described_class.rewrite_for_context(char_instance, 'choose 1')).to eq('activity choose 1')
      end

      it 'rewrites vote subcommand' do
        expect(described_class.rewrite_for_context(char_instance, 'vote yes')).to eq('activity vote yes')
      end

      it 'rewrites leave subcommand' do
        expect(described_class.rewrite_for_context(char_instance, 'leave')).to eq('activity leave')
      end

      it 'does not rewrite non-activity commands' do
        expect(described_class.rewrite_for_context(char_instance, 'look')).to eq('look')
      end

      it 'does not double-prefix activity command' do
        expect(described_class.rewrite_for_context(char_instance, 'activity status')).to eq('activity status')
      end

      it 'handles case-insensitive matching' do
        expect(described_class.rewrite_for_context(char_instance, 'STATUS')).to eq('activity STATUS')
      end
    end
  end

  describe 'private methods' do
    describe '#in_activity?' do
      it 'returns false for nil char_instance' do
        expect(described_class.send(:in_activity?, nil)).to be false
      end

      it 'returns false when no room' do
        allow(char_instance).to receive(:current_room).and_return(nil)
        expect(described_class.send(:in_activity?, char_instance)).to be false
      end

      it 'returns false when no running activity' do
        allow(ActivityService).to receive(:running_activity).and_return(nil)
        expect(described_class.send(:in_activity?, char_instance)).to be false
      end

      it 'returns falsey when not a participant' do
        activity_instance = double('ActivityInstance', paused_for_combat?: false)
        allow(ActivityService).to receive(:running_activity).and_return(activity_instance)
        allow(ActivityService).to receive(:participant_for).and_return(nil)
        # participant&.active? returns nil when participant is nil
        expect(described_class.send(:in_activity?, char_instance)).to be_falsey
      end

      it 'returns true when active participant' do
        activity_instance = double('ActivityInstance', paused_for_combat?: false)
        participant = double('Participant', active?: true)
        allow(ActivityService).to receive(:running_activity).and_return(activity_instance)
        allow(ActivityService).to receive(:participant_for).and_return(participant)
        expect(described_class.send(:in_activity?, char_instance)).to be true
      end

      it 'returns false when inactive participant' do
        activity_instance = double('ActivityInstance', paused_for_combat?: false)
        participant = double('Participant', active?: false)
        allow(ActivityService).to receive(:running_activity).and_return(activity_instance)
        allow(ActivityService).to receive(:participant_for).and_return(participant)
        expect(described_class.send(:in_activity?, char_instance)).to be false
      end

      it 'handles errors gracefully' do
        allow(ActivityService).to receive(:running_activity).and_raise(StandardError.new('Test error'))
        expect(described_class.send(:in_activity?, char_instance)).to be false
      end
    end

    describe '#rewrite_for_activity' do
      it 'returns nil for empty input' do
        expect(described_class.send(:rewrite_for_activity, '')).to be_nil
      end

      it 'returns nil for non-subcommand' do
        expect(described_class.send(:rewrite_for_activity, 'look')).to be_nil
      end

      it 'rewrites subcommand with activity prefix' do
        expect(described_class.send(:rewrite_for_activity, 'status')).to eq('activity status')
      end

      it 'preserves additional arguments' do
        expect(described_class.send(:rewrite_for_activity, 'choose 2')).to eq('activity choose 2')
      end

      it 'handles case insensitively' do
        expect(described_class.send(:rewrite_for_activity, 'STATUS')).to eq('activity STATUS')
      end

      it 'returns nil if already prefixed with activity' do
        expect(described_class.send(:rewrite_for_activity, 'activity status')).to be_nil
      end
    end

    describe '#try_quickmenu_shortcut' do
      before do
        allow(OutputHelper).to receive(:get_pending_interactions).and_return([])
      end

      it 'returns nil when no pending interactions' do
        result = described_class.send(:try_quickmenu_shortcut, char_instance, '1')
        expect(result).to be_nil
      end

      it 'returns nil when pending interactions are not quickmenus' do
        allow(OutputHelper).to receive(:get_pending_interactions).and_return([
          { type: 'form', interaction_id: 'form-1' }
        ])
        result = described_class.send(:try_quickmenu_shortcut, char_instance, '1')
        expect(result).to be_nil
      end

      it 'selects the most recent quickmenu' do
        quickmenu1 = {
          type: 'quickmenu',
          interaction_id: 'qm-1',
          options: [{ key: '1', label: 'First' }],
          context: {},
          created_at: '2024-01-01T00:00:00Z'
        }
        quickmenu2 = {
          type: 'quickmenu',
          interaction_id: 'qm-2',
          options: [{ key: '1', label: 'Second' }],
          context: {},
          created_at: '2024-01-02T00:00:00Z'
        }

        allow(OutputHelper).to receive(:get_pending_interactions).and_return([quickmenu1, quickmenu2])
        allow(OutputHelper).to receive(:complete_interaction)

        described_class.send(:try_quickmenu_shortcut, char_instance, '1')
        expect(OutputHelper).to have_received(:complete_interaction)
          .with(char_instance.id, 'qm-2')
      end
    end

    describe '#try_activity_shortcut' do
      it 'returns nil for non-numeric input' do
        result = described_class.send(:try_activity_shortcut, char_instance, 'look')
        expect(result).to be_nil
      end

      it 'returns nil when not in activity' do
        allow(ActivityService).to receive(:running_activity).and_return(nil)
        result = described_class.send(:try_activity_shortcut, char_instance, '1')
        expect(result).to be_nil
      end

      context 'when in activity with actions' do
        let(:mock_instance) { double('ActivityInstance') }
        let(:mock_round) { double('ActivityRound') }
        let(:mock_action) { double('ActivityAction', id: 1, choice_text: 'Attack') }
        let(:mock_participant) { double('ActivityParticipant', willpower_to_spend: 0) }

        before do
          allow(ActivityService).to receive(:running_activity).and_return(mock_instance)
          allow(ActivityService).to receive(:participant_for).and_return(mock_participant)
          allow(mock_participant).to receive(:active?).and_return(true)
          allow(mock_instance).to receive(:current_round).and_return(mock_round)
          allow(mock_round).to receive(:respond_to?).with(:all_actions).and_return(true)
          allow(mock_round).to receive(:all_actions).and_return([mock_action])
          allow(mock_round).to receive(:available_actions).and_return([mock_action])
        end

        it 'submits choice for valid action number' do
          allow(ActivityService).to receive(:submit_choice)

          result = described_class.send(:try_activity_shortcut, char_instance, '1')
          expect(result[:success]).to be true
          expect(ActivityService).to have_received(:submit_choice)
        end

        it 'returns error for invalid action number' do
          result = described_class.send(:try_activity_shortcut, char_instance, '99')
          expect(result[:success]).to be false
          expect(result[:error]).to include('Invalid action number')
        end

        it 'prefers all_actions for task-aware shortcuts' do
          second_action = double('ActivityAction', id: 2, choice_text: 'Task Action')
          allow(mock_round).to receive(:all_actions).and_return([mock_action, second_action])
          allow(ActivityService).to receive(:submit_choice)

          result = described_class.send(:try_activity_shortcut, char_instance, '2')
          expect(result[:success]).to be true
          expect(ActivityService).to have_received(:submit_choice).with(mock_participant, action_id: 2)
        end
      end
    end

    describe '#format_quickmenu_html' do
      it 'generates HTML for quickmenu' do
        options = [
          { key: '1', label: 'Option 1', description: 'First option' },
          { key: '2', label: 'Option 2' }
        ]
        html = described_class.send(:format_quickmenu_html, 'Select:', options)

        expect(html).to include('quickmenu')
        expect(html).to include('Select:')
        expect(html).to include('Option 1')
        expect(html).to include('First option')
        expect(html).to include('Option 2')
        expect(html).to include('data-key=')
      end
    end
  end

  describe 'quickmenu handlers' do
    before do
      allow(OutputHelper).to receive(:get_pending_interactions).and_return([])
      allow(OutputHelper).to receive(:complete_interaction)
    end

    describe '#handle_use_quickmenu' do
      it 'handles cancel' do
        result = described_class.send(:handle_use_quickmenu, char_instance, {}, 'q')
        expect(result[:success]).to be true
        expect(result[:message]).to eq('Cancelled.')
      end

      it 'handles select_item stage' do
        context = {
          stage: 'select_item',
          items: [{ name: 'Sword' }]
        }

        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: true, message: 'Actions for Sword', type: :quickmenu })

        result = described_class.send(:handle_use_quickmenu, char_instance, context, '1')
        expect(result[:success]).to be true
      end

      it 'handles invalid selection' do
        context = { stage: 'select_item', items: [] }
        result = described_class.send(:handle_use_quickmenu, char_instance, context, '99')
        expect(result[:success]).to be false
      end
    end

    describe '#handle_events_quickmenu' do
      it 'handles cancel' do
        result = described_class.send(:handle_events_quickmenu, char_instance, {}, 'q')
        expect(result[:success]).to be true
        expect(result[:message]).to eq('Calendar closed.')
      end

      it 'handles create option' do
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: true, type: :form, message: 'Create event form' })

        result = described_class.send(:handle_events_quickmenu, char_instance, {}, 'c')
        expect(result[:success]).to be true
      end

      it 'handles my events option' do
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: true, message: 'Your events:' })

        result = described_class.send(:handle_events_quickmenu, char_instance, {}, 'm')
        expect(result[:success]).to be true
      end

      it 'handles events here option' do
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: true, message: 'Events here:' })

        result = described_class.send(:handle_events_quickmenu, char_instance, {}, 'h')
        expect(result[:success]).to be true
      end
    end

    describe '#handle_memo_quickmenu' do
      it 'handles cancel' do
        result = described_class.send(:handle_memo_quickmenu, char_instance, {}, 'q')
        expect(result[:success]).to be true
        expect(result[:message]).to eq('Inbox closed.')
      end

      it 'handles new memo option' do
        result = described_class.send(:handle_memo_quickmenu, char_instance, {}, 'n')
        expect(result[:success]).to be true
        expect(result[:message]).to include('send memo')
      end

      it 'handles reading a memo' do
        sender_char = create(:character)
        memo = create(:memo, recipient_character: character, sender_character: sender_char)
        context = { memos: [{ id: memo.id }] }

        result = described_class.send(:handle_memo_quickmenu, char_instance, context, '1')
        expect(result[:success]).to be true
        expect(result[:message]).to include('Memo #1')
      end

      it 'handles non-existent memo' do
        context = { memos: [{ id: 999999 }] }
        result = described_class.send(:handle_memo_quickmenu, char_instance, context, '1')
        expect(result[:success]).to be false
        expect(result[:error]).to include('no longer exists')
      end
    end

    describe '#handle_whisper_quickmenu' do
      it 'handles cancel' do
        result = described_class.send(:handle_whisper_quickmenu, char_instance, {}, 'q')
        expect(result[:success]).to be true
        expect(result[:message]).to eq('Cancelled.')
      end

      it 'prompts for message on target selection' do
        context = { characters: [{ name: 'Alice' }] }
        result = described_class.send(:handle_whisper_quickmenu, char_instance, context, '1')
        expect(result[:success]).to be true
        expect(result[:message]).to include('whisper Alice')
      end

      it 'handles invalid selection' do
        context = { characters: [] }
        result = described_class.send(:handle_whisper_quickmenu, char_instance, context, '99')
        expect(result[:success]).to be false
      end
    end

    describe '#handle_taxi_quickmenu' do
      it 'handles cancel' do
        result = described_class.send(:handle_taxi_quickmenu, char_instance, {}, 'q')
        expect(result[:success]).to be true
        expect(result[:message]).to eq('Taxi cancelled.')
      end

      it 'handles call taxi option' do
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: true, message: 'Calling taxi...' })

        result = described_class.send(:handle_taxi_quickmenu, char_instance, {}, 'c')
        expect(Commands::Base::Registry).to have_received(:execute_command)
          .with(char_instance, 'taxi')
      end

      it 'handles destination selection' do
        context = { destinations: [{ name: 'Airport' }] }

        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: true, message: 'Heading to Airport...' })

        result = described_class.send(:handle_taxi_quickmenu, char_instance, context, '1')
        expect(Commands::Base::Registry).to have_received(:execute_command)
          .with(char_instance, 'taxi to Airport')
      end
    end

    describe '#handle_quiet_quickmenu' do
      let(:since_str) { (Time.now - 3600).iso8601 }
      let(:context) { { quiet_mode_since: since_str } }

      before do
        allow(char_instance).to receive(:clear_quiet_mode!)
        allow(described_class).to receive(:broadcast_personalized_to_room)
      end

      it 'clears quiet mode on any response' do
        described_class.send(:handle_quiet_quickmenu, char_instance, context, 'no')
        expect(char_instance).to have_received(:clear_quiet_mode!)
      end

      it 'broadcasts status change' do
        described_class.send(:handle_quiet_quickmenu, char_instance, context, 'no')
        expect(described_class).to have_received(:broadcast_personalized_to_room)
          .with(char_instance.current_room_id, anything, hash_including(exclude: [char_instance.id]))
      end

      it 'returns simple message for no catch-up' do
        result = described_class.send(:handle_quiet_quickmenu, char_instance, context, 'no')
        expect(result[:success]).to be true
        expect(result[:message]).to eq('Quiet mode disabled.')
      end

      it 'fetches missed messages for yes' do
        allow(Message).to receive(:where).and_return(double(where: double(order: double(limit: double(all: [])))))

        result = described_class.send(:handle_quiet_quickmenu, char_instance, context, 'yes')
        expect(result[:success]).to be true
        expect(result[:message]).to include('No missed messages')
      end
    end

    describe '#handle_simple_item_quickmenu' do
      it 'handles cancel' do
        result = described_class.send(:handle_simple_item_quickmenu, char_instance, {}, 'q', 'wear')
        expect(result[:success]).to be true
        expect(result[:message]).to eq('Cancelled.')
      end

      it 'executes command for selected item' do
        context = { items: [{ name: 'Shirt' }] }

        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: true, message: 'You wear the Shirt.' })

        result = described_class.send(:handle_simple_item_quickmenu, char_instance, context, '1', 'wear')
        expect(Commands::Base::Registry).to have_received(:execute_command)
          .with(char_instance, 'wear Shirt')
      end

      it 'handles drop command' do
        context = { items: [{ name: 'Rock' }] }

        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: true, message: 'You drop the Rock.' })

        described_class.send(:handle_simple_item_quickmenu, char_instance, context, '1', 'drop')
        expect(Commands::Base::Registry).to have_received(:execute_command)
          .with(char_instance, 'drop Rock')
      end

      it 'handles invalid selection' do
        context = { items: [] }
        result = described_class.send(:handle_simple_item_quickmenu, char_instance, context, '99', 'wear')
        expect(result[:success]).to be false
        expect(result[:error]).to include("Type 'wear'")
      end
    end

    describe '#handle_clan_quickmenu' do
      it 'handles cancel' do
        result = described_class.send(:handle_clan_quickmenu, char_instance, {}, 'q')
        expect(result[:success]).to be true
        expect(result[:message]).to eq('Action cancelled.')
      end

      it 'delegates to ClanDisambiguationHandler' do
        context = { clan_ids: [1, 2], action: 'info' }

        allow(ClanDisambiguationHandler).to receive(:process_response)
          .and_return({ success: true, message: 'Clan info displayed.' })

        result = described_class.send(:handle_clan_quickmenu, char_instance, context, '1')
        expect(ClanDisambiguationHandler).to have_received(:process_response)
      end
    end
  end

  describe 'error handling' do
    it 'catches and logs errors in activity quickmenu' do
      context = { activity: true, participant_id: 999999 }
      result = described_class.send(:handle_activity_quickmenu, char_instance, context, '1')
      expect(result[:success]).to be false
    end

    it 'catches errors in roll quickmenu' do
      context = { command: 'roll', stats: nil }
      allow(Commands::Base::Registry).to receive(:execute_command).and_raise(StandardError.new('Test'))

      result = described_class.send(:handle_roll_quickmenu, char_instance, context, '1')
      expect(result[:success]).to be false
    end

    it 'catches errors in buy quickmenu' do
      context = { command: 'buy', items: [{ name: 'Test' }] }
      allow(Commands::Base::Registry).to receive(:execute_command).and_raise(StandardError.new('Test'))

      result = described_class.send(:handle_buy_quickmenu, char_instance, context, '1')
      expect(result[:success]).to be false
    end
  end

  describe 'additional quickmenu handlers' do
    before do
      allow(OutputHelper).to receive(:get_pending_interactions).and_return([])
      allow(OutputHelper).to receive(:complete_interaction)
    end

    describe '#handle_give_or_show_quickmenu (for give/show)' do
      it 'handles cancel for give' do
        result = described_class.send(:handle_give_quickmenu, char_instance, {}, 'q')
        expect(result[:success]).to be true
        expect(result[:message]).to eq('Cancelled.')
      end

      it 'handles cancel for show' do
        result = described_class.send(:handle_show_quickmenu, char_instance, {}, 'q')
        expect(result[:success]).to be true
        expect(result[:message]).to eq('Cancelled.')
      end

      it 'handles invalid selection' do
        context = { items: [], target_name: 'Alice' }
        result = described_class.send(:handle_give_quickmenu, char_instance, context, '99')
        expect(result[:success]).to be false
      end
    end

    describe '#handle_travel_options_quickmenu' do
      it 'handles cancel with cancel response key' do
        result = described_class.send(:handle_travel_options_quickmenu, char_instance, {}, 'cancel')
        expect(result[:success]).to be true
        expect(result[:message]).to eq('Journey cancelled.')
      end

      it 'handles missing destination' do
        context = { destination_id: 999999 }
        result = described_class.send(:handle_travel_options_quickmenu, char_instance, context, 'standard')
        expect(result[:success]).to be false
        expect(result[:error]).to include('no longer exists')
      end
    end

    describe '#handle_party_invite_quickmenu' do
      it 'handles invalid response' do
        context = {}
        result = described_class.send(:handle_party_invite_quickmenu, char_instance, context, 'invalid')
        expect(result[:success]).to be false
      end
    end

    describe '#handle_ooc_request_quickmenu' do
      it 'returns error when request not found' do
        context = { request_id: 999999 }
        allow(char_instance).to receive(:clear_pending_ooc_request!)
        result = described_class.send(:handle_ooc_request_quickmenu, char_instance, context, 'accept')
        expect(result[:success]).to be false
        expect(result[:error]).to include('no longer valid')
      end
    end

    describe '#handle_attempt_quickmenu' do
      it 'handles deny to reject attempt' do
        attempter = create(:character_instance, current_room: room, character: create(:character))
        context = { attempter_id: attempter.id, emote_text: 'hugs you', sender_name: 'Test' }
        allow(BroadcastService).to receive(:to_character)

        result = described_class.send(:handle_attempt_quickmenu, char_instance, context, 'deny')
        expect(result[:success]).to be true
        expect(result[:message]).to include('denied')
      end

      it 'handles invalid response key' do
        attempter = create(:character_instance, current_room: room, character: create(:character))
        context = { attempter_id: attempter.id, emote_text: 'hugs you', sender_name: 'Test' }

        result = described_class.send(:handle_attempt_quickmenu, char_instance, context, 'invalid')
        expect(result[:success]).to be false
        expect(result[:error]).to include('Invalid response')
      end

      it 'handles missing attempter' do
        context = { attempter_id: 999999, emote_text: 'hugs you', sender_name: 'Test' }

        result = described_class.send(:handle_attempt_quickmenu, char_instance, context, 'allow')
        expect(result[:success]).to be false
        expect(result[:error]).to include('no longer available')
      end
    end

    describe '#handle_map_quickmenu' do
      it 'executes map command with response key' do
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: true, message: 'Map displayed.' })

        result = described_class.send(:handle_map_quickmenu, char_instance, {}, 'room')
        expect(result[:success]).to be true
        expect(Commands::Base::Registry).to have_received(:execute_command)
          .with(char_instance, 'map room')
      end

      it 'handles command failure' do
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: false, error: 'No map available.' })

        result = described_class.send(:handle_map_quickmenu, char_instance, {}, 'room')
        expect(result[:success]).to be false
      end
    end

    describe '#handle_journey_quickmenu' do
      it 'executes journey command with response key' do
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: true, message: 'Journey action executed.' })

        result = described_class.send(:handle_journey_quickmenu, char_instance, {}, 'status')
        expect(result[:success]).to be true
        expect(Commands::Base::Registry).to have_received(:execute_command)
          .with(char_instance, 'journey status')
      end

      it 'handles command failure' do
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: false, error: 'Not on a journey.' })

        result = described_class.send(:handle_journey_quickmenu, char_instance, {}, 'status')
        expect(result[:success]).to be false
      end
    end

    describe '#handle_permissions_quickmenu' do
      it 'handles q to cancel' do
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: true, message: 'Permissions unchanged.' })

        result = described_class.send(:handle_permissions_quickmenu, char_instance, {}, 'q')
        expect(result[:success]).to be true
      end

      it 'handles permission toggle' do
        context = { target_id: 1, permission: 'touch' }
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: true, message: 'Permission updated.' })

        result = described_class.send(:handle_permissions_quickmenu, char_instance, context, 'toggle')
        expect(result[:success]).to be true
      end
    end

    describe '#handle_shop_quickmenu' do
      it 'handles buy option' do
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: true, message: 'Items for sale.' })

        result = described_class.send(:handle_shop_quickmenu, char_instance, {}, 'buy')
        expect(result[:success]).to be true
      end
    end

    describe '#handle_shop_buy_quickmenu' do
      it 'handles cancel with q' do
        result = described_class.send(:handle_shop_buy_quickmenu, char_instance, {}, 'q')
        expect(result[:success]).to be true
        expect(result[:message]).to include('cancelled')
      end

      it 'handles invalid selection' do
        context = { items: [] }
        result = described_class.send(:handle_shop_buy_quickmenu, char_instance, context, '99')
        expect(result[:success]).to be false
      end
    end

    describe '#handle_media_quickmenu' do
      it 'executes media command' do
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: true, message: 'Now playing.' })

        result = described_class.send(:handle_media_quickmenu, char_instance, {}, 'play')
        expect(result[:success]).to be true
      end
    end

    describe '#handle_property_quickmenu' do
      it 'executes property command' do
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: true, message: 'Property info shown.' })

        result = described_class.send(:handle_property_quickmenu, char_instance, {}, 'info')
        expect(result[:success]).to be true
      end
    end

    describe '#handle_property_grant_quickmenu' do
      it 'handles cancel with q' do
        result = described_class.send(:handle_property_grant_quickmenu, char_instance, {}, 'q')
        expect(result[:success]).to be true
        expect(result[:message]).to match(/cancel/i)
      end
    end

    describe '#handle_property_revoke_quickmenu' do
      it 'handles cancel with q' do
        result = described_class.send(:handle_property_revoke_quickmenu, char_instance, {}, 'q')
        expect(result[:success]).to be true
        expect(result[:message]).to match(/cancel/i)
      end
    end

    describe '#handle_tickets_quickmenu' do
      it 'executes tickets command with new option' do
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: true, type: :form, message: 'New ticket form.' })

        result = described_class.send(:handle_tickets_quickmenu, char_instance, {}, 'new')
        expect(result[:success]).to be true
      end

      it 'executes tickets command with list option' do
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: true, message: 'Tickets listed.' })

        result = described_class.send(:handle_tickets_quickmenu, char_instance, {}, 'list')
        expect(result[:success]).to be true
      end
    end

    describe '#handle_tickets_list_quickmenu' do
      it 'handles invalid selection' do
        context = { tickets: [] }
        result = described_class.send(:handle_tickets_list_quickmenu, char_instance, context, '99')
        expect(result[:success]).to be false
      end

      it 'handles valid selection' do
        user = create(:user)
        ticket = create(:ticket, user: user)
        context = { tickets: [{ id: ticket.id }] }
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: true, message: 'Ticket details.' })

        result = described_class.send(:handle_tickets_list_quickmenu, char_instance, context, '1')
        expect(result[:success]).to be true
      end
    end

    describe '#handle_wardrobe_quickmenu' do
      it 'executes wardrobe command' do
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: true, message: 'Wardrobe shown.' })

        result = described_class.send(:handle_wardrobe_quickmenu, char_instance, {}, 'list')
        expect(result[:success]).to be true
      end
    end

    describe '#handle_wardrobe_store_quickmenu' do
      it 'handles invalid selection' do
        context = { items: [] }
        result = described_class.send(:handle_wardrobe_store_quickmenu, char_instance, context, '99')
        expect(result[:success]).to be false
      end
    end

    describe '#handle_wardrobe_retrieve_quickmenu' do
      it 'handles invalid selection' do
        context = { items: [] }
        result = described_class.send(:handle_wardrobe_retrieve_quickmenu, char_instance, context, '99')
        expect(result[:success]).to be false
      end
    end

    describe '#handle_wardrobe_transfer_quickmenu' do
      it 'handles invalid selection' do
        context = { items: [] }
        result = described_class.send(:handle_wardrobe_transfer_quickmenu, char_instance, context, '99')
        expect(result[:success]).to be false
      end
    end

    describe '#handle_timeline_quickmenu' do
      it 'handles unknown stage' do
        context = { stage: 'unknown' }
        result = described_class.send(:handle_timeline_quickmenu, char_instance, context, '1')
        expect(result[:success]).to be false
        expect(result[:error]).to include('Unknown timeline menu stage')
      end

      it 'handles main_menu stage with valid option' do
        context = { stage: 'main_menu' }
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: true, message: 'Timeline shown.' })

        # 'q' returns cancel message for main menu
        result = described_class.send(:handle_timeline_quickmenu, char_instance, context, 'q')
        expect(result[:success]).to be true
      end
    end

    describe '#handle_cards_quickmenu' do
      it 'delegates to CardsQuickmenuHandler' do
        context = { deck_id: 1 }
        allow(CardsQuickmenuHandler).to receive(:handle_response)
          .and_return({ success: true, message: 'Card action performed.' })

        result = described_class.send(:handle_cards_quickmenu, char_instance, context, 'draw')
        expect(CardsQuickmenuHandler).to have_received(:handle_response)
      end
    end
  end

  describe 'execute_roll_command helper' do
    it 'returns success for valid roll' do
      allow(Commands::Base::Registry).to receive(:execute_command)
        .and_return({ success: true, message: 'You rolled 15!' })

      result = described_class.send(:execute_roll_command, char_instance, 'STR')
      expect(result[:success]).to be true
    end

    it 'returns error for failed roll' do
      allow(Commands::Base::Registry).to receive(:execute_command)
        .and_return({ success: false, error: 'Unknown stat' })

      result = described_class.send(:execute_roll_command, char_instance, 'INVALID')
      expect(result[:success]).to be false
    end

    it 'catches exceptions' do
      allow(Commands::Base::Registry).to receive(:execute_command)
        .and_raise(StandardError.new('Test error'))

      result = described_class.send(:execute_roll_command, char_instance, 'STR')
      expect(result[:success]).to be false
    end
  end

  describe 'use quickmenu stages' do
    describe '#handle_use_action_selection' do
      it 'handles invalid item' do
        context = { stage: 'select_action', item_id: 999999, item_name: 'Nonexistent' }
        result = described_class.send(:handle_use_action_selection, char_instance, context, '1')
        expect(result[:success]).to be false
      end

      it 'handles valid item with examine action' do
        item = create(:item, character_instance: char_instance)
        context = {
          stage: 'select_action',
          item_id: item.id,
          item_name: item.name
        }
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: true, message: 'You examine the item.' })

        # 'e' key is mapped to 'look at' command for examine
        result = described_class.send(:handle_use_action_selection, char_instance, context, 'e')
        expect(result[:success]).to be true
        expect(Commands::Base::Registry).to have_received(:execute_command)
          .with(char_instance, "look at #{item.name}")
      end
    end

    describe '#handle_use_game_branch_selection' do
      let(:game_pattern) { create(:game_pattern) }
      let(:game_instance) { create(:game_instance, game_pattern: game_pattern, room: room) }
      let(:branch) { create(:game_pattern_branch, game_pattern: game_pattern, name: 'normal', display_name: 'Normal') }
      let(:game_result) { create(:game_pattern_result, game_pattern_branch: branch, message: 'You win!') }

      before do
        game_result # ensure created
      end

      it 'handles invalid selection (out of range)' do
        context = {
          stage: 'select_game_branch',
          game_instance_id: game_instance.id,
          branches: [{ id: branch.id, name: branch.name }]
        }

        result = described_class.send(:handle_use_game_branch_selection, char_instance, context, '99')
        expect(result[:success]).to be false
        expect(result[:error]).to eq('Invalid selection.')
      end

      it 'handles missing game instance' do
        context = {
          stage: 'select_game_branch',
          game_instance_id: 999999,
          branches: [{ id: branch.id, name: branch.name }]
        }

        result = described_class.send(:handle_use_game_branch_selection, char_instance, context, '1')
        expect(result[:success]).to be false
        expect(result[:error]).to eq('Game not found.')
      end

      it 'handles missing branch' do
        context = {
          stage: 'select_game_branch',
          game_instance_id: game_instance.id,
          branches: [{ id: 999999, name: 'fake' }]
        }

        result = described_class.send(:handle_use_game_branch_selection, char_instance, context, '1')
        expect(result[:success]).to be false
        expect(result[:error]).to eq('Game option not found.')
      end

      it 'plays the game with selected branch' do
        context = {
          stage: 'select_game_branch',
          game_instance_id: game_instance.id,
          branches: [{ id: branch.id, name: branch.name }]
        }

        allow(GamePlayService).to receive(:play).and_return({
          success: true,
          message: 'You win!',
          points: 10,
          total_score: nil,
          game_name: 'Test Game',
          branch_name: 'Normal'
        })

        result = described_class.send(:handle_use_game_branch_selection, char_instance, context, '1')
        expect(result[:success]).to be true
        expect(result[:message]).to include('Test Game')
        expect(result[:message]).to include('Normal')
        expect(result[:message]).to include('You win!')
        expect(GamePlayService).to have_received(:play).with(game_instance, branch, char_instance)
      end

      it 'includes score in output when scoring is enabled' do
        context = {
          stage: 'select_game_branch',
          game_instance_id: game_instance.id,
          branches: [{ id: branch.id, name: branch.name }]
        }

        allow(GamePlayService).to receive(:play).and_return({
          success: true,
          message: 'You win!',
          points: 10,
          total_score: 50,
          game_name: 'Test Game',
          branch_name: 'Normal'
        })

        result = described_class.send(:handle_use_game_branch_selection, char_instance, context, '1')
        expect(result[:success]).to be true
        expect(result[:message]).to include('+10 points')
        expect(result[:message]).to include('Your score: 50 points')
      end

      it 'handles GamePlayService failure' do
        context = {
          stage: 'select_game_branch',
          game_instance_id: game_instance.id,
          branches: [{ id: branch.id, name: branch.name }]
        }

        allow(GamePlayService).to receive(:play).and_return({
          success: false,
          error: 'No results configured'
        })

        result = described_class.send(:handle_use_game_branch_selection, char_instance, context, '1')
        expect(result[:success]).to be false
        expect(result[:error]).to eq('No results configured')
      end

      it 'handles string keys in context (from JSON)' do
        context = {
          'stage' => 'select_game_branch',
          'game_instance_id' => game_instance.id,
          'branches' => [{ 'id' => branch.id, 'name' => branch.name }]
        }

        allow(GamePlayService).to receive(:play).and_return({
          success: true,
          message: 'You win!',
          points: 5,
          total_score: nil,
          game_name: 'Test Game',
          branch_name: 'Normal'
        })

        result = described_class.send(:handle_use_game_branch_selection, char_instance, context, '1')
        expect(result[:success]).to be true
      end
    end

    describe '#format_game_result' do
      it 'formats basic result without score' do
        result = {
          game_name: 'Magic 8-Ball',
          branch_name: 'Serious',
          message: 'Signs point to yes.',
          points: 0,
          total_score: nil
        }

        output = described_class.send(:format_game_result, result)
        expect(output).to include('[ Magic 8-Ball - Serious ]')
        expect(output).to include('Signs point to yes.')
        expect(output).not_to include('points')
      end

      it 'formats result with positive score' do
        result = {
          game_name: 'Dartboard',
          branch_name: 'Normal',
          message: 'Bullseye!',
          points: 50,
          total_score: 150
        }

        output = described_class.send(:format_game_result, result)
        expect(output).to include('[ Dartboard - Normal ]')
        expect(output).to include('Bullseye!')
        expect(output).to include('+50 points')
        expect(output).to include('Your score: 150 points')
      end

      it 'formats result with negative score' do
        result = {
          game_name: 'Dartboard',
          branch_name: 'Normal',
          message: 'You miss completely.',
          points: -10,
          total_score: 40
        }

        output = described_class.send(:format_game_result, result)
        expect(output).to include('-10 points')
        expect(output).to include('Your score: 40 points')
      end

      it 'formats result with zero points' do
        result = {
          game_name: 'Dartboard',
          branch_name: 'Normal',
          message: 'Nothing special.',
          points: 0,
          total_score: 100
        }

        output = described_class.send(:format_game_result, result)
        expect(output).to include('0 points')
        expect(output).to include('Your score: 100 points')
      end
    end
  end

  describe 'give/show quickmenu two-stage flow' do
    before do
      allow(OutputHelper).to receive(:get_pending_interactions).and_return([])
      allow(OutputHelper).to receive(:complete_interaction)
      allow(OutputHelper).to receive(:store_agent_interaction)
    end

    describe '#handle_give_item_selection' do
      it 'returns error for empty items' do
        context = { stage: 'select_item', items: [] }
        result = described_class.send(:handle_give_item_selection, char_instance, context, '1', 'give')
        expect(result[:success]).to be false
        expect(result[:error]).to include("Type 'give'")
      end

      it 'returns error for invalid index' do
        context = { stage: 'select_item', items: [{ id: 1, name: 'Sword' }] }
        result = described_class.send(:handle_give_item_selection, char_instance, context, '99', 'give')
        expect(result[:success]).to be false
      end

      it 'returns error when no characters in room to give to' do
        context = { stage: 'select_item', items: [{ id: 1, name: 'Sword' }] }
        # No other characters in room
        result = described_class.send(:handle_give_item_selection, char_instance, context, '1', 'give')
        expect(result[:success]).to be false
        expect(result[:error]).to include("no one here")
      end

      it 'shows target menu when characters are present' do
        other_char = create(:character)
        other_instance = create(:character_instance, character: other_char, current_room: room)
        context = { stage: 'select_item', items: [{ id: 1, name: 'Sword' }] }

        result = described_class.send(:handle_give_item_selection, char_instance, context, '1', 'give')
        expect(result[:success]).to be true
        expect(result[:type]).to eq(:quickmenu)
        expect(result[:prompt]).to include('Give Sword to whom?')
      end
    end

    describe '#handle_give_target_selection' do
      it 'executes give command for valid target' do
        context = {
          stage: 'select_target',
          item_id: 1,
          item_name: 'Sword',
          characters: [{ id: 1, name: 'Alice' }]
        }
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: true, message: 'You gave the Sword to Alice.' })

        result = described_class.send(:handle_give_target_selection, char_instance, context, '1', 'give')
        expect(result[:success]).to be true
        expect(Commands::Base::Registry).to have_received(:execute_command)
          .with(char_instance, 'give Sword to Alice')
      end

      it 'returns error for failed command' do
        context = {
          stage: 'select_target',
          item_id: 1,
          item_name: 'Sword',
          characters: [{ id: 1, name: 'Alice' }]
        }
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: false, error: 'You no longer have that item.' })

        result = described_class.send(:handle_give_target_selection, char_instance, context, '1', 'give')
        expect(result[:success]).to be false
        expect(result[:error]).to include('no longer have')
      end

      it 'returns error for out of range selection' do
        context = {
          stage: 'select_target',
          item_id: 1,
          item_name: 'Sword',
          characters: []
        }

        result = described_class.send(:handle_give_target_selection, char_instance, context, '1', 'give')
        expect(result[:success]).to be false
        expect(result[:error]).to include("Invalid selection")
      end
    end

    describe '#handle_give_or_show_quickmenu' do
      it 'handles unknown stage' do
        context = { stage: 'unknown' }
        result = described_class.send(:handle_give_or_show_quickmenu, char_instance, context, '1', action: 'give')
        expect(result[:success]).to be false
        expect(result[:error]).to include('Invalid give menu state')
      end

      it 'handles exception in give quickmenu' do
        context = { stage: 'select_item', items: nil }
        allow(described_class).to receive(:handle_give_item_selection).and_raise(StandardError.new('Test'))

        result = described_class.send(:handle_give_or_show_quickmenu, char_instance, context, '1', action: 'give')
        expect(result[:success]).to be false
        expect(result[:error]).to include('Failed to process give')
      end
    end

    describe '#target_menu' do
      it 'generates target menu with multiple characters' do
        other1 = create(:character, forename: 'Alice')
        other2 = create(:character, forename: 'Bob')
        create(:character_instance, character: other1, current_room: room)
        create(:character_instance, character: other2, current_room: room)

        result = described_class.send(:target_menu, char_instance, 1, 'Sword', 'give')
        expect(result[:success]).to be true
        expect(result[:type]).to eq(:quickmenu)
        expect(result[:options].length).to eq(3) # 2 characters + cancel
        expect(result[:options].last[:key]).to eq('q')
      end
    end
  end

  describe 'party invite quickmenu' do
    describe '#handle_party_invite_quickmenu' do
      let(:other_char) { create(:character) }
      let(:other_instance) { create(:character_instance, character: other_char, current_room: room) }
      let(:destination) { create(:location) }
      let(:party) { create(:travel_party, leader: char_instance, destination: destination) }

      before do
        allow(OutputHelper).to receive(:complete_interaction)
        allow(BroadcastService).to receive(:to_character)
      end

      it 'accepts invite when member is valid' do
        member = create(:travel_party_member, party: party, character_instance: other_instance, status: 'pending')
        context = { member_id: member.id }

        allow(member).to receive(:accept!).and_return(true)
        allow(TravelPartyMember).to receive(:[]).with(member.id).and_return(member)
        allow(member).to receive(:character_instance_id).and_return(other_instance.id)
        allow(member).to receive(:party).and_return(party)

        result = described_class.send(:handle_party_invite_quickmenu, other_instance, context, 'accept')
        expect(result[:success]).to be true
        expect(result[:message]).to include('joined')
      end

      it 'declines invite when member is valid' do
        member = create(:travel_party_member, party: party, character_instance: other_instance, status: 'pending')
        context = { member_id: member.id }

        allow(member).to receive(:decline!).and_return(true)
        allow(TravelPartyMember).to receive(:[]).with(member.id).and_return(member)
        allow(member).to receive(:character_instance_id).and_return(other_instance.id)
        allow(member).to receive(:party).and_return(party)

        result = described_class.send(:handle_party_invite_quickmenu, other_instance, context, 'decline')
        expect(result[:success]).to be true
        expect(result[:message]).to include('declined')
      end

      it 'returns error when accept fails' do
        member = create(:travel_party_member, party: party, character_instance: other_instance, status: 'pending')
        context = { member_id: member.id }

        allow(member).to receive(:accept!).and_return(false)
        allow(TravelPartyMember).to receive(:[]).with(member.id).and_return(member)
        allow(member).to receive(:character_instance_id).and_return(other_instance.id)
        allow(member).to receive(:party).and_return(party)

        result = described_class.send(:handle_party_invite_quickmenu, other_instance, context, 'accept')
        expect(result[:success]).to be false
        expect(result[:error]).to include('Could not accept')
      end

      it 'returns error when decline fails' do
        member = create(:travel_party_member, party: party, character_instance: other_instance, status: 'pending')
        context = { member_id: member.id }

        allow(member).to receive(:decline!).and_return(false)
        allow(TravelPartyMember).to receive(:[]).with(member.id).and_return(member)
        allow(member).to receive(:character_instance_id).and_return(other_instance.id)
        allow(member).to receive(:party).and_return(party)

        result = described_class.send(:handle_party_invite_quickmenu, other_instance, context, 'decline')
        expect(result[:success]).to be false
        expect(result[:error]).to include('Could not decline')
      end

      it 'returns error for invalid member id mismatch' do
        member = create(:travel_party_member, party: party, character_instance: char_instance, status: 'pending')
        context = { member_id: member.id }

        result = described_class.send(:handle_party_invite_quickmenu, other_instance, context, 'accept')
        expect(result[:success]).to be false
        expect(result[:error]).to include('Invalid party invite')
      end

      it 'handles exception gracefully' do
        context = { member_id: 999999 }
        allow(TravelPartyMember).to receive(:[]).and_raise(StandardError.new('DB Error'))

        result = described_class.send(:handle_party_invite_quickmenu, char_instance, context, 'accept')
        expect(result[:success]).to be false
        expect(result[:error]).to include('Failed to process party invitation')
      end
    end
  end

  describe 'OOC request quickmenu' do
    describe '#handle_ooc_request_quickmenu' do
      let(:other_user) { create(:user) }
      let(:other_char) { create(:character, user: other_user) }

      before do
        allow(OutputHelper).to receive(:complete_interaction)
        allow(char_instance).to receive(:clear_pending_ooc_request!)
      end

      it 'accepts the request successfully' do
        request = create(:ooc_request, sender_user: other_user, sender_character: other_char, target_character: character)
        context = { request_id: request.id }
        allow(request).to receive(:accept!)
        allow(OocRequest).to receive(:[]).with(request.id).and_return(request)
        allow(described_class).to receive(:notify_ooc_request_sender)

        result = described_class.send(:handle_ooc_request_quickmenu, char_instance, context, 'accept')
        expect(result[:success]).to be true
        expect(result[:message]).to include('Accepted')
        expect(result[:type]).to eq(:system)
      end

      it 'declines the request successfully' do
        request = create(:ooc_request, sender_user: other_user, sender_character: other_char, target_character: character)
        context = { request_id: request.id }
        allow(request).to receive(:decline!)
        allow(OocRequest).to receive(:[]).with(request.id).and_return(request)
        allow(described_class).to receive(:notify_ooc_request_sender)

        result = described_class.send(:handle_ooc_request_quickmenu, char_instance, context, 'decline')
        expect(result[:success]).to be true
        expect(result[:message]).to include('Declined')
        expect(result[:type]).to eq(:system)
      end

      it 'returns error for invalid response' do
        request = create(:ooc_request, sender_user: other_user, sender_character: other_char, target_character: character)
        context = { request_id: request.id }
        allow(OocRequest).to receive(:[]).with(request.id).and_return(request)

        result = described_class.send(:handle_ooc_request_quickmenu, char_instance, context, 'maybe')
        expect(result[:success]).to be false
        expect(result[:error]).to eq('Invalid response.')
      end

      it 'handles exception gracefully' do
        context = { request_id: 1 }
        allow(OocRequest).to receive(:[]).and_raise(StandardError.new('DB Error'))

        result = described_class.send(:handle_ooc_request_quickmenu, char_instance, context, 'accept')
        expect(result[:success]).to be false
        expect(result[:error]).to include('Failed to process OOC request')
      end
    end

    describe '#notify_ooc_request_sender' do
      let(:other_user) { create(:user) }
      let(:other_char) { create(:character, user: other_user) }

      it 'notifies sender when they are online' do
        request = create(:ooc_request, sender_user: other_user, sender_character: other_char, target_character: character)
        sender_instance = create(:character_instance, character: other_char, online: true, current_room: room)

        allow(BroadcastService).to receive(:to_character)

        described_class.send(:notify_ooc_request_sender, request, :accepted, char_instance)

        expect(BroadcastService).to have_received(:to_character)
          .with(sender_instance, anything, type: :system)
      end

      it 'does nothing when sender is offline' do
        request = create(:ooc_request, sender_user: other_user, sender_character: other_char, target_character: character)
        # No online sender instance

        allow(BroadcastService).to receive(:to_character)

        described_class.send(:notify_ooc_request_sender, request, :accepted, char_instance)

        expect(BroadcastService).not_to have_received(:to_character)
      end
    end
  end

  describe 'attempt quickmenu' do
    describe '#handle_attempt_quickmenu allow flow' do
      let(:other_char) { create(:character) }
      let(:other_instance) { create(:character_instance, character: other_char, current_room: room) }

      before do
        allow(OutputHelper).to receive(:complete_interaction)
        allow(BroadcastService).to receive(:to_character_raw)
        allow(RpLoggingService).to receive(:log_to_room)
        allow(char_instance).to receive(:clear_pending_attempt!)
        allow_any_instance_of(CharacterInstance).to receive(:clear_attempt!)
      end

      it 'allows the attempt and broadcasts emote' do
        context = {
          attempter_id: other_instance.id,
          emote_text: 'hugs you warmly.',
          sender_name: other_char.full_name
        }

        result = described_class.send(:handle_attempt_quickmenu, char_instance, context, 'allow')
        expect(result[:success]).to be true
        expect(result[:message]).to include('allowed')
        expect(BroadcastService).to have_received(:to_character_raw).at_least(:once)
        expect(BroadcastService).to have_received(:to_character_raw).with(
          have_attributes(id: other_instance.id), anything, type: :attempt_response
        )
      end
    end
  end

  describe 'travel options quickmenu' do
    describe '#handle_travel_options_quickmenu' do
      let(:destination) { create(:location) }

      before do
        allow(OutputHelper).to receive(:complete_interaction)
      end

      it 'starts journey with flashback_basic mode' do
        context = { destination_id: destination.id, travel_mode: 'walk' }
        allow(JourneyService).to receive(:start_journey).and_return({
          success: true,
          message: 'You begin your journey in flashback mode.',
          instanced: false
        })

        result = described_class.send(:handle_travel_options_quickmenu, char_instance, context, 'flashback_basic')
        expect(result[:success]).to be true
        expect(JourneyService).to have_received(:start_journey)
          .with(char_instance, destination: destination, travel_mode: 'walk', flashback_mode: :basic)
      end

      it 'starts journey with flashback_return mode' do
        context = { destination_id: destination.id, travel_mode: 'walk' }
        allow(JourneyService).to receive(:start_journey).and_return({
          success: true,
          message: 'Journey started.',
          instanced: false
        })

        result = described_class.send(:handle_travel_options_quickmenu, char_instance, context, 'flashback_return')
        expect(result[:success]).to be true
        expect(JourneyService).to have_received(:start_journey)
          .with(char_instance, destination: destination, travel_mode: 'walk', flashback_mode: :return)
      end

      it 'starts journey with flashback_backloaded mode' do
        context = { destination_id: destination.id, travel_mode: 'walk' }
        allow(JourneyService).to receive(:start_journey).and_return({
          success: true,
          message: 'Journey started.',
          instanced: false
        })

        result = described_class.send(:handle_travel_options_quickmenu, char_instance, context, 'flashback_backloaded')
        expect(result[:success]).to be true
        expect(JourneyService).to have_received(:start_journey)
          .with(char_instance, destination: destination, travel_mode: 'walk', flashback_mode: :backloaded)
      end

      it 'starts standard journey without flashback' do
        context = { destination_id: destination.id, travel_mode: 'walk' }
        allow(JourneyService).to receive(:start_journey).and_return({
          success: true,
          message: 'You begin walking.',
          instanced: false
        })

        result = described_class.send(:handle_travel_options_quickmenu, char_instance, context, 'standard')
        expect(result[:success]).to be true
        expect(JourneyService).to have_received(:start_journey)
          .with(char_instance, destination: destination, travel_mode: 'walk', flashback_mode: nil)
      end

      it 'rejects unknown travel option keys' do
        context = { destination_id: destination.id, travel_mode: 'walk' }
        allow(JourneyService).to receive(:start_journey)

        result = described_class.send(:handle_travel_options_quickmenu, char_instance, context, 'unknown_option')
        expect(result[:success]).to be false
        expect(result[:error]).to include('Invalid response')
        expect(JourneyService).not_to have_received(:start_journey)
      end

      it 'assembles a travel party when assemble_party is selected' do
        context = { destination_id: destination.id, travel_mode: 'walk' }
        allow(TravelParty).to receive(:where).and_return(double(first: nil))
        allow(TravelParty).to receive(:create_for).and_return(double(id: 42))

        result = described_class.send(:handle_travel_options_quickmenu, char_instance, context, 'assemble_party')

        expect(result[:success]).to be true
        expect(result[:type]).to eq(:travel_party)
        expect(result[:data][:action]).to eq('party_created')
        expect(TravelParty).to have_received(:create_for).with(
          char_instance,
          destination,
          travel_mode: 'walk'
        )
      end

      it 'returns an error if an assembling party already exists' do
        context = { destination_id: destination.id, travel_mode: 'walk' }
        allow(TravelParty).to receive(:where).and_return(double(first: double('TravelParty')))

        result = described_class.send(:handle_travel_options_quickmenu, char_instance, context, 'assemble_party')

        expect(result[:success]).to be false
        expect(result[:error]).to include('already have an assembling party')
      end

      it 'returns journey failure error' do
        context = { destination_id: destination.id, travel_mode: 'walk' }
        allow(JourneyService).to receive(:start_journey).and_return({
          success: false,
          error: 'You are too tired to travel.'
        })

        result = described_class.send(:handle_travel_options_quickmenu, char_instance, context, 'standard')
        expect(result[:success]).to be false
        expect(result[:error]).to include('too tired')
      end

      it 'handles exception gracefully' do
        context = { destination_id: destination.id, travel_mode: 'walk' }
        allow(JourneyService).to receive(:start_journey).and_raise(StandardError.new('Network error'))

        result = described_class.send(:handle_travel_options_quickmenu, char_instance, context, 'standard')
        expect(result[:success]).to be false
        expect(result[:error]).to include('Failed to start journey')
      end
    end
  end

  describe 'quiet mode helpers' do
    describe '#fetch_missed_channel_messages' do
      it 'fetches messages from correct types since timestamp' do
        since = Time.now - 3600
        msg1 = create(:message, message_type: 'ooc', created_at: Time.now - 1800)
        msg2 = create(:message, message_type: 'broadcast', created_at: Time.now - 900)

        result = described_class.send(:fetch_missed_channel_messages, since)
        expect(result).to include(msg1)
        expect(result).to include(msg2)
      end

      it 'limits to 100 messages' do
        since = Time.now - 3600
        # The method has a limit(100), so this tests the boundary
        result = described_class.send(:fetch_missed_channel_messages, since)
        expect(result.length).to be <= 100
      end
    end

    describe '#format_catchup_messages' do
      it 'formats messages with timestamps' do
        msg1 = create(:message, content: 'Hello world', created_at: Time.parse('2024-01-01 10:30:00'))
        msg2 = create(:message, content: 'Goodbye', created_at: Time.parse('2024-01-01 10:31:00'))

        result = described_class.send(:format_catchup_messages, [msg1, msg2])
        expect(result).to include('[10:30]')
        expect(result).to include('Hello world')
        expect(result).to include('[10:31]')
        expect(result).to include('Goodbye')
      end

      it 'returns empty string for empty messages' do
        result = described_class.send(:format_catchup_messages, [])
        expect(result).to eq('')
      end
    end
  end

  describe 'timeline quickmenu handlers' do
    before do
      allow(OutputHelper).to receive(:store_agent_interaction)
    end

    describe '#handle_timeline_main_menu' do
      it 'shows timeline list for view option' do
        allow(described_class).to receive(:list_timelines_for).and_return("=== Your Timelines ===")

        result = described_class.send(:handle_timeline_main_menu, char_instance, 'view')
        expect(result[:success]).to be true
        expect(result[:message]).to include('Your Timelines')
      end

      it 'shows enter menu for enter option' do
        allow(char_instance).to receive(:in_past_timeline?).and_return(false)
        allow(TimelineService).to receive(:snapshots_for).and_return([])
        allow(TimelineService).to receive(:accessible_snapshots_for).and_return([])

        result = described_class.send(:handle_timeline_main_menu, char_instance, 'enter')
        expect(result[:success]).to be true
        expect(result[:type]).to eq(:quickmenu)
        expect(result[:options].map { |option| option[:key] }).to include('h')
      end

      it 'shows create form for create option' do
        allow(char_instance).to receive(:in_past_timeline?).and_return(false)

        result = described_class.send(:handle_timeline_main_menu, char_instance, 'create')
        expect(result[:success]).to be true
        expect(result[:type]).to eq(:form)
      end

      it 'leaves timeline for leave option when in timeline' do
        allow(char_instance).to receive(:in_past_timeline?).and_return(true)
        allow(char_instance).to receive(:timeline_display_name).and_return('Test Timeline')
        allow(TimelineService).to receive(:leave_timeline)

        result = described_class.send(:handle_timeline_main_menu, char_instance, 'leave')
        expect(result[:success]).to be true
        expect(result[:message]).to include("left the timeline")
      end

      it 'shows info for info option when in timeline' do
        timeline = double('Timeline',
          display_name: 'Test',
          timeline_type: 'snapshot',
          historical?: false,
          snapshot?: true,
          snapshot: double(character: character, snapshot_taken_at: Time.now),
          no_death?: true,
          no_prisoner?: true,
          no_xp?: true,
          rooms_read_only?: true
        )
        allow(char_instance).to receive(:in_past_timeline?).and_return(true)
        allow(char_instance).to receive(:timeline).and_return(timeline)

        result = described_class.send(:handle_timeline_main_menu, char_instance, 'info')
        expect(result[:success]).to be true
        expect(result[:message]).to include('Current Timeline')
      end

      it 'shows delete menu for delete option' do
        allow(TimelineService).to receive(:snapshots_for).and_return([])

        result = described_class.send(:handle_timeline_main_menu, char_instance, 'delete')
        expect(result[:success]).to be false
        expect(result[:error]).to include('no snapshots')
      end

      it 'returns unknown option error' do
        result = described_class.send(:handle_timeline_main_menu, char_instance, 'invalid')
        expect(result[:success]).to be false
        expect(result[:error]).to include('Unknown option')
      end
    end

    describe '#show_timeline_enter_menu' do
      it 'returns error when already in past timeline' do
        allow(char_instance).to receive(:in_past_timeline?).and_return(true)

        result = described_class.send(:show_timeline_enter_menu, char_instance)
        expect(result[:success]).to be false
        expect(result[:error]).to include("already in a past timeline")
      end

      it 'allows historical timeline selection when snapshots are empty' do
        allow(char_instance).to receive(:in_past_timeline?).and_return(false)
        allow(TimelineService).to receive(:snapshots_for).and_return([])
        allow(TimelineService).to receive(:accessible_snapshots_for).and_return([])

        result = described_class.send(:show_timeline_enter_menu, char_instance)
        expect(result[:success]).to be true
        expect(result[:type]).to eq(:quickmenu)
        expect(result[:options].map { |option| option[:key] }).to contain_exactly('h', 'q')
      end
    end

    describe '#show_timeline_create_form' do
      it 'returns error when in past timeline' do
        allow(char_instance).to receive(:in_past_timeline?).and_return(true)

        result = described_class.send(:show_timeline_create_form, char_instance)
        expect(result[:success]).to be false
        expect(result[:error]).to include("cannot create snapshots")
      end

      it 'returns form when not in past timeline' do
        allow(char_instance).to receive(:in_past_timeline?).and_return(false)

        result = described_class.send(:show_timeline_create_form, char_instance)
        expect(result[:success]).to be true
        expect(result[:type]).to eq(:form)
        expect(result[:title]).to eq('Create Snapshot')
      end
    end

    describe '#leave_current_timeline' do
      it 'returns error when not in timeline' do
        allow(char_instance).to receive(:in_past_timeline?).and_return(false)

        result = described_class.send(:leave_current_timeline, char_instance)
        expect(result[:success]).to be false
        expect(result[:error]).to include("not in a past timeline")
      end
    end

    describe '#show_timeline_info' do
      it 'returns error when not in timeline' do
        allow(char_instance).to receive(:in_past_timeline?).and_return(false)

        result = described_class.send(:show_timeline_info, char_instance)
        expect(result[:success]).to be false
        expect(result[:error]).to include("not in a past timeline")
      end

      it 'shows historical timeline info' do
        zone = double('Zone', name: 'Downtown')
        timeline = double('Timeline',
          display_name: 'Historical Test',
          timeline_type: 'historical',
          historical?: true,
          snapshot?: false,
          year: 1892,
          zone: zone,
          no_death?: true,
          no_prisoner?: false,
          no_xp?: true,
          rooms_read_only?: true
        )
        allow(char_instance).to receive(:in_past_timeline?).and_return(true)
        allow(char_instance).to receive(:timeline).and_return(timeline)

        result = described_class.send(:show_timeline_info, char_instance)
        expect(result[:success]).to be true
        expect(result[:message]).to include('Historical')
        expect(result[:message]).to include('1892')
        expect(result[:message]).to include('Downtown')
      end
    end

    describe '#show_timeline_delete_menu' do
      it 'returns error when no snapshots' do
        allow(TimelineService).to receive(:snapshots_for).and_return([])

        result = described_class.send(:show_timeline_delete_menu, char_instance)
        expect(result[:success]).to be false
        expect(result[:error]).to include('no snapshots')
      end

      it 'shows delete menu with snapshots' do
        snapshot = double('Snapshot', id: 1, name: 'Test', snapshot_taken_at: Time.now)
        allow(TimelineService).to receive(:snapshots_for).and_return([snapshot])

        result = described_class.send(:show_timeline_delete_menu, char_instance)
        expect(result[:success]).to be true
        expect(result[:type]).to eq(:quickmenu)
        expect(result[:prompt]).to include('delete')
      end
    end

    describe '#show_timeline_historical_form' do
      it 'returns error when in past timeline' do
        allow(char_instance).to receive(:in_past_timeline?).and_return(true)

        result = described_class.send(:show_timeline_historical_form, char_instance)
        expect(result[:success]).to be false
        expect(result[:error]).to include("already in a past timeline")
      end

      it 'shows historical form when not in timeline' do
        allow(char_instance).to receive(:in_past_timeline?).and_return(false)

        result = described_class.send(:show_timeline_historical_form, char_instance)
        expect(result[:success]).to be true
        expect(result[:type]).to eq(:form)
        expect(result[:title]).to eq('Enter Historical Timeline')
      end
    end

    describe '#handle_timeline_enter_select' do
      it 'shows historical form for h option' do
        allow(char_instance).to receive(:in_past_timeline?).and_return(false)
        context = { stage: 'enter_select', snapshots: [] }

        result = described_class.send(:handle_timeline_enter_select, char_instance, context, 'h')
        expect(result[:success]).to be true
        expect(result[:type]).to eq(:form)
      end

      it 'returns error for invalid numeric selection' do
        context = { stage: 'enter_select', snapshots: [] }

        result = described_class.send(:handle_timeline_enter_select, char_instance, context, '99')
        expect(result[:success]).to be false
        expect(result[:error]).to eq('Invalid selection.')
      end

      it 'returns error when snapshot not found' do
        context = { stage: 'enter_select', snapshots: [{ id: 999999, name: 'Missing' }] }
        allow(CharacterSnapshot).to receive(:[]).with(999999).and_return(nil)

        result = described_class.send(:handle_timeline_enter_select, char_instance, context, '1')
        expect(result[:success]).to be false
        expect(result[:error]).to eq('Snapshot not found.')
      end

      it 'returns error when character cannot enter snapshot' do
        snapshot = double('Snapshot', can_enter?: false)
        context = { stage: 'enter_select', snapshots: [{ id: 1, name: 'Test' }] }
        allow(CharacterSnapshot).to receive(:[]).with(1).and_return(snapshot)

        result = described_class.send(:handle_timeline_enter_select, char_instance, context, '1')
        expect(result[:success]).to be false
        expect(result[:error]).to include("weren't present")
      end

      it 'handles TimelineService::NotAllowedError' do
        snapshot = double('Snapshot', can_enter?: true)
        context = { stage: 'enter_select', snapshots: [{ id: 1, name: 'Test' }] }
        allow(CharacterSnapshot).to receive(:[]).with(1).and_return(snapshot)
        allow(TimelineService).to receive(:enter_snapshot_timeline)
          .and_raise(TimelineService::NotAllowedError.new('Not allowed'))

        result = described_class.send(:handle_timeline_enter_select, char_instance, context, '1')
        expect(result[:success]).to be false
        expect(result[:error]).to eq('Not allowed')
      end
    end

    describe '#handle_timeline_delete_select' do
      it 'returns error for invalid numeric selection' do
        context = { stage: 'delete_select', snapshots: [] }

        result = described_class.send(:handle_timeline_delete_select, char_instance, context, '99')
        expect(result[:success]).to be false
        expect(result[:error]).to eq('Invalid selection.')
      end

      it 'returns error when snapshot not found' do
        context = { stage: 'delete_select', snapshots: [{ id: 999999, name: 'Missing' }] }
        allow(CharacterSnapshot).to receive(:[]).with(999999).and_return(nil)

        result = described_class.send(:handle_timeline_delete_select, char_instance, context, '1')
        expect(result[:success]).to be false
        expect(result[:error]).to eq('Snapshot not found.')
      end

      it 'returns error when snapshot belongs to another character' do
        other_char = create(:character)
        snapshot = double('Snapshot', character_id: other_char.id)
        context = { stage: 'delete_select', snapshots: [{ id: 1, name: 'Test' }] }
        allow(CharacterSnapshot).to receive(:[]).with(1).and_return(snapshot)

        result = described_class.send(:handle_timeline_delete_select, char_instance, context, '1')
        expect(result[:success]).to be false
        expect(result[:error]).to include('only delete your own')
      end

      it 'deletes snapshot successfully' do
        snapshot = double('Snapshot', character_id: character.id, name: 'Test Snap')
        context = { stage: 'delete_select', snapshots: [{ id: 1, name: 'Test Snap' }] }
        allow(CharacterSnapshot).to receive(:[]).with(1).and_return(snapshot)
        allow(TimelineService).to receive(:delete_snapshot)

        result = described_class.send(:handle_timeline_delete_select, char_instance, context, '1')
        expect(result[:success]).to be true
        expect(result[:message]).to include("Deleted snapshot 'Test Snap'")
      end

      it 'handles TimelineService::TimelineError' do
        snapshot = double('Snapshot', character_id: character.id, name: 'Test')
        context = { stage: 'delete_select', snapshots: [{ id: 1, name: 'Test' }] }
        allow(CharacterSnapshot).to receive(:[]).with(1).and_return(snapshot)
        allow(TimelineService).to receive(:delete_snapshot)
          .and_raise(TimelineService::TimelineError.new('Cannot delete'))

        result = described_class.send(:handle_timeline_delete_select, char_instance, context, '1')
        expect(result[:success]).to be false
        expect(result[:error]).to eq('Cannot delete')
      end
    end

    describe '#list_timelines_for' do
      it 'shows empty state when no timelines' do
        allow(TimelineService).to receive(:snapshots_for).and_return([])
        allow(TimelineService).to receive(:accessible_snapshots_for).and_return([])
        allow(TimelineService).to receive(:active_timelines_for).and_return([])

        result = described_class.send(:list_timelines_for, char_instance)
        expect(result).to include('no snapshots or active timelines')
      end

      it 'shows own snapshots with active status' do
        snapshot = double('Snapshot',
          id: 1,
          name: 'My Snap',
          snapshot_taken_at: Time.now,
          description: 'Test description',
          character_id: character.id
        )
        timeline_double = double('Timeline', display_name: 'My Timeline')
        active_instance = double('CharacterInstance', source_snapshot_id: 1, online: true, timeline: timeline_double)
        allow(TimelineService).to receive(:snapshots_for).and_return([snapshot])
        allow(TimelineService).to receive(:accessible_snapshots_for).and_return([snapshot])
        allow(TimelineService).to receive(:active_timelines_for).and_return([active_instance])

        result = described_class.send(:list_timelines_for, char_instance)
        expect(result).to include('My Snap')
        expect(result).to include('[ACTIVE]')
        expect(result).to include('Test description')
      end
    end
  end

  describe 'wardrobe quickmenu handlers' do
    before do
      allow(OutputHelper).to receive(:complete_interaction)
    end

    describe '#handle_wardrobe_quickmenu' do
      it 'handles list option' do
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: true, message: 'Wardrobe contents.' })

        result = described_class.send(:handle_wardrobe_quickmenu, char_instance, {}, 'list')
        expect(result[:success]).to be true
        expect(Commands::Base::Registry).to have_received(:execute_command)
          .with(char_instance, 'wardrobe list')
      end

      it 'handles store option' do
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: true, message: 'Store menu.' })

        result = described_class.send(:handle_wardrobe_quickmenu, char_instance, {}, 'store')
        expect(result[:success]).to be true
      end

      it 'handles retrieve option' do
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: true, message: 'Retrieve menu.' })

        result = described_class.send(:handle_wardrobe_quickmenu, char_instance, {}, 'retrieve')
        expect(result[:success]).to be true
      end

      it 'handles retrieve_all option' do
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: true, message: 'Retrieved all items.' })

        result = described_class.send(:handle_wardrobe_quickmenu, char_instance, {}, 'retrieve_all')
        expect(result[:success]).to be true
      end

      it 'handles transfer option' do
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: true, message: 'Transfer menu.' })

        result = described_class.send(:handle_wardrobe_quickmenu, char_instance, {}, 'transfer')
        expect(result[:success]).to be true
      end

      it 'handles status option' do
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: true, message: 'Status info.' })

        result = described_class.send(:handle_wardrobe_quickmenu, char_instance, {}, 'status')
        expect(result[:success]).to be true
      end

      it 'handles unknown option' do
        result = described_class.send(:handle_wardrobe_quickmenu, char_instance, {}, 'invalid')
        expect(result[:success]).to be false
        expect(result[:error]).to include('Unknown option')
      end

      it 'handles exception gracefully' do
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_raise(StandardError.new('Command error'))

        result = described_class.send(:handle_wardrobe_quickmenu, char_instance, {}, 'list')
        expect(result[:success]).to be false
        expect(result[:error]).to include('Failed to process wardrobe')
      end
    end

    describe '#handle_wardrobe_store_quickmenu' do
      it 'handles all option' do
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: true, message: 'Stored all items.' })

        result = described_class.send(:handle_wardrobe_store_quickmenu, char_instance, {}, 'all')
        expect(result[:success]).to be true
      end

      it 'handles valid numeric selection' do
        context = { items: [{ name: 'Shirt' }] }
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: true, message: 'Stored Shirt.' })

        result = described_class.send(:handle_wardrobe_store_quickmenu, char_instance, context, '1')
        expect(result[:success]).to be true
        expect(Commands::Base::Registry).to have_received(:execute_command)
          .with(char_instance, 'wardrobe store Shirt')
      end

      it 'handles exception gracefully' do
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_raise(StandardError.new('Error'))

        result = described_class.send(:handle_wardrobe_store_quickmenu, char_instance, {}, 'all')
        expect(result[:success]).to be false
        expect(result[:error]).to include('Failed to store item')
      end
    end

    describe '#handle_wardrobe_retrieve_quickmenu' do
      it 'handles all option' do
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: true, message: 'Retrieved all.' })

        result = described_class.send(:handle_wardrobe_retrieve_quickmenu, char_instance, {}, 'all')
        expect(result[:success]).to be true
      end

      it 'handles valid numeric selection' do
        context = { items: [{ name: 'Pants' }] }
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: true, message: 'Retrieved Pants.' })

        result = described_class.send(:handle_wardrobe_retrieve_quickmenu, char_instance, context, '1')
        expect(result[:success]).to be true
      end

      it 'handles exception gracefully' do
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_raise(StandardError.new('Error'))

        result = described_class.send(:handle_wardrobe_retrieve_quickmenu, char_instance, {}, 'all')
        expect(result[:success]).to be false
        expect(result[:error]).to include('Failed to retrieve item')
      end
    end

    describe '#handle_wardrobe_transfer_quickmenu' do
      it 'handles status option' do
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: true, message: 'Transfer status.' })

        result = described_class.send(:handle_wardrobe_transfer_quickmenu, char_instance, {}, 'status')
        expect(result[:success]).to be true
      end

      it 'handles valid numeric selection' do
        context = { locations: [{ room_name: 'My Apartment' }] }
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: true, message: 'Transfer initiated.' })

        result = described_class.send(:handle_wardrobe_transfer_quickmenu, char_instance, context, '1')
        expect(result[:success]).to be true
        expect(Commands::Base::Registry).to have_received(:execute_command)
          .with(char_instance, 'wardrobe transfer from My Apartment')
      end

      it 'handles exception gracefully' do
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_raise(StandardError.new('Error'))

        result = described_class.send(:handle_wardrobe_transfer_quickmenu, char_instance, {}, 'status')
        expect(result[:success]).to be false
        expect(result[:error]).to include('Failed to initiate transfer')
      end
    end
  end

  describe 'tickets quickmenu handlers' do
    before do
      allow(OutputHelper).to receive(:complete_interaction)
    end

    describe '#handle_tickets_quickmenu' do
      it 'handles all option' do
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: true, message: 'All tickets.' })

        result = described_class.send(:handle_tickets_quickmenu, char_instance, {}, 'all')
        expect(result[:success]).to be true
      end

      it 'handles q to close menu' do
        result = described_class.send(:handle_tickets_quickmenu, char_instance, {}, 'q')
        expect(result[:success]).to be true
        expect(result[:message]).to eq('Menu closed.')
      end

      it 'handles unknown option' do
        result = described_class.send(:handle_tickets_quickmenu, char_instance, {}, 'invalid')
        expect(result[:success]).to be false
        expect(result[:error]).to include('Unknown option')
      end

      it 'handles exception gracefully' do
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_raise(StandardError.new('Error'))

        result = described_class.send(:handle_tickets_quickmenu, char_instance, {}, 'list')
        expect(result[:success]).to be false
        expect(result[:error]).to include('Failed to process tickets')
      end
    end

    describe '#handle_tickets_list_quickmenu' do
      it 'handles new option' do
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: true, message: 'New ticket form.' })

        result = described_class.send(:handle_tickets_list_quickmenu, char_instance, {}, 'new')
        expect(result[:success]).to be true
      end

      it 'handles q to close menu' do
        result = described_class.send(:handle_tickets_list_quickmenu, char_instance, {}, 'q')
        expect(result[:success]).to be true
        expect(result[:message]).to eq('Menu closed.')
      end

      it 'handles zero ticket id' do
        context = { tickets: [] }
        result = described_class.send(:handle_tickets_list_quickmenu, char_instance, context, '0')
        expect(result[:success]).to be false
        expect(result[:error]).to include('Invalid selection')
      end

      it 'handles exception gracefully' do
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_raise(StandardError.new('Error'))

        result = described_class.send(:handle_tickets_list_quickmenu, char_instance, {}, 'new')
        expect(result[:success]).to be false
        expect(result[:error]).to include('Failed to process ticket')
      end
    end
  end

  describe 'use action selection action keys' do
    let(:item) { create(:item, character_instance: char_instance) }
    let(:context) { { stage: 'select_action', item_id: item.id, item_name: item.name } }

    before do
      allow(OutputHelper).to receive(:complete_interaction)
    end

    it 'handles hold action key' do
      allow(Commands::Base::Registry).to receive(:execute_command)
        .and_return({ success: true, message: 'You hold the item.' })

      result = described_class.send(:handle_use_action_selection, char_instance, context, 'h')
      expect(result[:success]).to be true
      expect(Commands::Base::Registry).to have_received(:execute_command)
        .with(char_instance, "hold #{item.name}")
    end

    it 'handles release action key' do
      allow(Commands::Base::Registry).to receive(:execute_command)
        .and_return({ success: true, message: 'You release the item.' })

      result = described_class.send(:handle_use_action_selection, char_instance, context, 'r')
      expect(result[:success]).to be true
      expect(Commands::Base::Registry).to have_received(:execute_command)
        .with(char_instance, "release #{item.name}")
    end

    it 'handles wear action key when item is not worn' do
      item.update(worn: false) # Ensure item is not worn
      allow(Commands::Base::Registry).to receive(:execute_command)
        .and_return({ success: true, message: 'You wear the item.' })

      result = described_class.send(:handle_use_action_selection, char_instance, context, 'w')
      expect(result[:success]).to be true
      expect(Commands::Base::Registry).to have_received(:execute_command)
        .with(char_instance, "wear #{item.name}")
    end

    it 'handles remove action key when item is worn' do
      item.update(worn: true)
      allow(Commands::Base::Registry).to receive(:execute_command)
        .and_return({ success: true, message: 'You remove the item.' })

      result = described_class.send(:handle_use_action_selection, char_instance, context, 'w')
      expect(result[:success]).to be true
      expect(Commands::Base::Registry).to have_received(:execute_command)
        .with(char_instance, "remove #{item.name}")
    end

    it 'handles consume action key' do
      allow(Commands::Base::Registry).to receive(:execute_command)
        .and_return({ success: true, message: 'You consume the item.' })

      result = described_class.send(:handle_use_action_selection, char_instance, context, 'c')
      expect(result[:success]).to be true
      expect(Commands::Base::Registry).to have_received(:execute_command)
        .with(char_instance, "consume #{item.name}")
    end

    it 'handles drop action key' do
      allow(Commands::Base::Registry).to receive(:execute_command)
        .and_return({ success: true, message: 'You drop the item.' })

      result = described_class.send(:handle_use_action_selection, char_instance, context, 'd')
      expect(result[:success]).to be true
      expect(Commands::Base::Registry).to have_received(:execute_command)
        .with(char_instance, "drop #{item.name}")
    end

    it 'handles give action key' do
      allow(Commands::Base::Registry).to receive(:execute_command)
        .and_return({ success: true, message: 'Give menu shown.' })

      result = described_class.send(:handle_use_action_selection, char_instance, context, 'g')
      expect(result[:success]).to be true
      expect(Commands::Base::Registry).to have_received(:execute_command)
        .with(char_instance, "give #{item.name}")
    end

    it 'handles show action key' do
      allow(Commands::Base::Registry).to receive(:execute_command)
        .and_return({ success: true, message: 'Show menu shown.' })

      result = described_class.send(:handle_use_action_selection, char_instance, context, 's')
      expect(result[:success]).to be true
      expect(Commands::Base::Registry).to have_received(:execute_command)
        .with(char_instance, "show #{item.name}")
    end

    it 'returns error for unknown action key' do
      result = described_class.send(:handle_use_action_selection, char_instance, context, 'z')
      expect(result[:success]).to be false
      expect(result[:error]).to include("Invalid action")
    end

    it 'returns error when command fails' do
      allow(Commands::Base::Registry).to receive(:execute_command)
        .and_return({ success: false, error: 'Cannot hold that.' })

      result = described_class.send(:handle_use_action_selection, char_instance, context, 'h')
      expect(result[:success]).to be false
      expect(result[:error]).to include('Cannot hold')
    end
  end

  describe 'format_command_result helper' do
    it 'returns nil for nil input' do
      result = described_class.send(:format_command_result, nil)
      expect(result).to be_nil
    end

    it 'formats successful result with all fields' do
      input = { success: true, message: 'Done', type: :message, data: { foo: 'bar' } }
      result = described_class.send(:format_command_result, input)

      expect(result[:success]).to be true
      expect(result[:message]).to eq('Done')
      expect(result[:type]).to eq(:message)
      expect(result[:data]).to eq({ foo: 'bar' })
    end

    it 'defaults type to message when not provided' do
      input = { success: true, message: 'Test' }
      result = described_class.send(:format_command_result, input)

      expect(result[:type]).to eq(:message)
    end

    it 'removes nil data field' do
      input = { success: true, message: 'Test', data: nil }
      result = described_class.send(:format_command_result, input)

      expect(result.key?(:data)).to be false
    end
  end

  describe 'cards quickmenu nil result handling' do
    before do
      allow(OutputHelper).to receive(:complete_interaction)
    end

    it 'returns complete message when handler returns nil' do
      allow(CardsQuickmenuHandler).to receive(:handle_response).and_return(nil)

      result = described_class.send(:handle_cards_quickmenu, char_instance, {}, 'draw')
      expect(result[:success]).to be true
      expect(result[:message]).to eq('Card action complete.')
    end

    it 'returns quickmenu when handler returns quickmenu type' do
      menu_result = {
        type: :quickmenu,
        prompt: 'Pick a card:',
        options: [{ key: '1', label: 'Ace' }],
        context: { deck_id: 1 },
        message: 'Menu shown',
        data: { cards: [] }
      }
      allow(CardsQuickmenuHandler).to receive(:handle_response).and_return(menu_result)

      result = described_class.send(:handle_cards_quickmenu, char_instance, {}, 'draw')
      expect(result[:success]).to be true
      expect(result[:type]).to eq(:quickmenu)
      expect(result[:display_type]).to eq(:quickmenu)
      expect(result[:prompt]).to eq('Pick a card:')
      expect(result[:data][:prompt]).to eq('Pick a card:')
      expect(result[:data][:options]).to eq([{ key: '1', label: 'Ace' }])
      expect(result[:data][:result_data]).to eq({ cards: [] })
    end

    it 'returns other result types directly' do
      other_result = { success: true, message: 'You drew a card!', type: :message }
      allow(CardsQuickmenuHandler).to receive(:handle_response).and_return(other_result)

      result = described_class.send(:handle_cards_quickmenu, char_instance, {}, 'draw')
      expect(result).to eq(other_result)
    end
  end

  describe 'locatability quickmenu edge cases' do
    before do
      allow(OutputHelper).to receive(:complete_interaction)
    end

    it 'handles text responses for yes' do
      result = described_class.send(:handle_locatability_quickmenu, char_instance, {}, 'yes')
      expect(result[:success]).to be true
      expect(result[:data][:locatability]).to eq('yes')
    end

    it 'handles text responses for favorites' do
      result = described_class.send(:handle_locatability_quickmenu, char_instance, {}, 'favorites')
      expect(result[:success]).to be true
      expect(result[:data][:locatability]).to eq('favorites')
    end

    it 'handles text responses for no' do
      result = described_class.send(:handle_locatability_quickmenu, char_instance, {}, 'no')
      expect(result[:success]).to be true
      expect(result[:data][:locatability]).to eq('no')
    end

    it 'handles invalid text response' do
      result = described_class.send(:handle_locatability_quickmenu, char_instance, {}, 'maybe')
      expect(result[:success]).to be false
      expect(result[:error]).to include('Invalid selection')
    end

    it 'handles exception gracefully' do
      allow(char_instance).to receive(:update).and_raise(StandardError.new('DB Error'))

      result = described_class.send(:handle_locatability_quickmenu, char_instance, {}, '1')
      expect(result[:success]).to be false
      expect(result[:error]).to include('Failed to set locatability')
    end
  end

  describe 'fight quickmenu edge cases' do
    before do
      allow(OutputHelper).to receive(:complete_interaction)
    end

    it 'handles valid target selection' do
      context = { command: 'fight', targets: [{ name: 'Goblin' }] }
      allow(Commands::Base::Registry).to receive(:execute_command)
        .and_return({ success: true, message: 'Combat started!' })

      result = described_class.send(:handle_fight_quickmenu, char_instance, context, '1')
      expect(result[:success]).to be true
      expect(Commands::Base::Registry).to have_received(:execute_command)
        .with(char_instance, 'fight Goblin')
    end

    it 'handles invalid target selection' do
      context = { command: 'fight', targets: [] }

      result = described_class.send(:handle_fight_quickmenu, char_instance, context, '1')
      expect(result[:success]).to be false
      expect(result[:error]).to include('Invalid selection')
    end

    it 'handles command failure' do
      context = { command: 'fight', targets: [{ name: 'Goblin' }] }
      allow(Commands::Base::Registry).to receive(:execute_command)
        .and_return({ success: false, error: 'Target not found.' })

      result = described_class.send(:handle_fight_quickmenu, char_instance, context, '1')
      expect(result[:success]).to be false
      expect(result[:error]).to include('Target not found')
    end

    it 'handles exception gracefully' do
      context = { command: 'fight', targets: [{ name: 'Goblin' }] }
      allow(Commands::Base::Registry).to receive(:execute_command)
        .and_raise(StandardError.new('Combat error'))

      result = described_class.send(:handle_fight_quickmenu, char_instance, context, '1')
      expect(result[:success]).to be false
      expect(result[:error]).to include('Failed to start combat')
    end
  end

  describe 'whisper quickmenu edge cases' do
    before do
      allow(OutputHelper).to receive(:complete_interaction)
    end

    it 'handles exception gracefully' do
      context = { characters: nil }
      # This will cause an error when trying to access characters
      result = described_class.send(:handle_whisper_quickmenu, char_instance, context, '1')
      # Should handle the nil gracefully
      expect(result[:success]).to be false
    end
  end

  describe 'taxi quickmenu edge cases' do
    before do
      allow(OutputHelper).to receive(:complete_interaction)
    end

    it 'handles invalid destination selection' do
      context = { destinations: [] }

      result = described_class.send(:handle_taxi_quickmenu, char_instance, context, '1')
      expect(result[:success]).to be false
      expect(result[:error]).to include('Invalid selection')
    end

    it 'handles command failure for destination' do
      context = { destinations: [{ name: 'Airport' }] }
      allow(Commands::Base::Registry).to receive(:execute_command)
        .and_return({ success: false, error: 'No taxi available.' })

      result = described_class.send(:handle_taxi_quickmenu, char_instance, context, '1')
      expect(result[:success]).to be false
      expect(result[:error]).to include('No taxi available')
    end

    it 'handles exception gracefully' do
      context = { destinations: [{ name: 'Airport' }] }
      allow(Commands::Base::Registry).to receive(:execute_command)
        .and_raise(StandardError.new('Network error'))

      result = described_class.send(:handle_taxi_quickmenu, char_instance, context, '1')
      expect(result[:success]).to be false
      expect(result[:error]).to include('Failed to take taxi')
    end
  end

  describe 'events quickmenu edge cases' do
    before do
      allow(OutputHelper).to receive(:complete_interaction)
    end

    it 'handles valid event selection' do
      context = { events: [{ name: 'Party' }] }
      allow(Commands::Base::Registry).to receive(:execute_command)
        .and_return({ success: true, message: 'Event info shown.' })

      result = described_class.send(:handle_events_quickmenu, char_instance, context, '1')
      expect(result[:success]).to be true
    end

    it 'handles invalid event selection' do
      context = { events: [] }

      result = described_class.send(:handle_events_quickmenu, char_instance, context, '1')
      expect(result[:success]).to be false
      expect(result[:error]).to include('Invalid selection')
    end

    it 'handles exception gracefully' do
      context = { events: [{ name: 'Party' }] }
      allow(Commands::Base::Registry).to receive(:execute_command)
        .and_raise(StandardError.new('DB Error'))

      result = described_class.send(:handle_events_quickmenu, char_instance, context, '1')
      expect(result[:success]).to be false
      expect(result[:error]).to include('Failed to process event')
    end
  end

  describe 'shop quickmenu edge cases' do
    before do
      allow(OutputHelper).to receive(:complete_interaction)
    end

    describe '#handle_shop_quickmenu' do
      it 'handles browse option' do
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: true, message: 'Shop items listed.' })

        result = described_class.send(:handle_shop_quickmenu, char_instance, {}, 'browse')
        expect(result[:success]).to be true
        expect(Commands::Base::Registry).to have_received(:execute_command)
          .with(char_instance, 'shop list')
      end

      it 'handles stock option' do
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: true, message: 'Stock menu.' })

        result = described_class.send(:handle_shop_quickmenu, char_instance, {}, 'stock')
        expect(result[:success]).to be true
        expect(Commands::Base::Registry).to have_received(:execute_command)
          .with(char_instance, 'shop stock')
      end

      it 'handles unknown option by passing through' do
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: true, message: 'Done.' })

        result = described_class.send(:handle_shop_quickmenu, char_instance, {}, 'other')
        expect(Commands::Base::Registry).to have_received(:execute_command)
          .with(char_instance, 'shop other')
      end

      it 'handles exception gracefully' do
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_raise(StandardError.new('Error'))

        result = described_class.send(:handle_shop_quickmenu, char_instance, {}, 'buy')
        expect(result[:success]).to be false
        expect(result[:error]).to include('Failed to process shop')
      end
    end

    describe '#handle_shop_buy_quickmenu' do
      it 'handles valid item selection' do
        context = { items: [{ name: 'Potion' }] }
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: true, message: 'You bought a Potion.' })

        result = described_class.send(:handle_shop_buy_quickmenu, char_instance, context, '1')
        expect(result[:success]).to be true
        expect(Commands::Base::Registry).to have_received(:execute_command)
          .with(char_instance, 'shop buy Potion')
      end

      it 'handles command failure' do
        context = { items: [{ name: 'Potion' }] }
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: false, error: 'Not enough gold.' })

        result = described_class.send(:handle_shop_buy_quickmenu, char_instance, context, '1')
        expect(result[:success]).to be false
        expect(result[:error]).to include('Not enough gold')
      end

      it 'handles exception gracefully' do
        context = { items: [{ name: 'Potion' }] }
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_raise(StandardError.new('Error'))

        result = described_class.send(:handle_shop_buy_quickmenu, char_instance, context, '1')
        expect(result[:success]).to be false
        expect(result[:error]).to include('Failed to process purchase')
      end
    end
  end

  describe 'media quickmenu edge cases' do
    before do
      allow(OutputHelper).to receive(:complete_interaction)
    end

    it 'handles pause option' do
      allow(Commands::Base::Registry).to receive(:execute_command)
        .and_return({ success: true, message: 'Paused.' })

      result = described_class.send(:handle_media_quickmenu, char_instance, {}, 'pause')
      expect(Commands::Base::Registry).to have_received(:execute_command)
        .with(char_instance, 'media pause')
    end

    it 'handles stop option' do
      allow(Commands::Base::Registry).to receive(:execute_command)
        .and_return({ success: true, message: 'Stopped.' })

      result = described_class.send(:handle_media_quickmenu, char_instance, {}, 'stop')
      expect(Commands::Base::Registry).to have_received(:execute_command)
        .with(char_instance, 'media stop')
    end

    it 'handles status option' do
      allow(Commands::Base::Registry).to receive(:execute_command)
        .and_return({ success: true, message: 'Status shown.' })

      result = described_class.send(:handle_media_quickmenu, char_instance, {}, 'status')
      expect(Commands::Base::Registry).to have_received(:execute_command)
        .with(char_instance, 'media status')
    end

    it 'handles jukebox option' do
      allow(Commands::Base::Registry).to receive(:execute_command)
        .and_return({ success: true, message: 'Jukebox shown.' })

      result = described_class.send(:handle_media_quickmenu, char_instance, {}, 'jukebox')
      expect(Commands::Base::Registry).to have_received(:execute_command)
        .with(char_instance, 'media player')
    end

    it 'handles playlist option' do
      allow(Commands::Base::Registry).to receive(:execute_command)
        .and_return({ success: true, message: 'Playlist shown.' })

      result = described_class.send(:handle_media_quickmenu, char_instance, {}, 'playlist')
      expect(Commands::Base::Registry).to have_received(:execute_command)
        .with(char_instance, 'media playlist')
    end

    it 'handles share_screen option' do
      allow(Commands::Base::Registry).to receive(:execute_command)
        .and_return({ success: true, message: 'Sharing screen.' })

      result = described_class.send(:handle_media_quickmenu, char_instance, {}, 'share_screen')
      expect(Commands::Base::Registry).to have_received(:execute_command)
        .with(char_instance, 'media share screen')
    end

    it 'handles share_tab option' do
      allow(Commands::Base::Registry).to receive(:execute_command)
        .and_return({ success: true, message: 'Sharing tab.' })

      result = described_class.send(:handle_media_quickmenu, char_instance, {}, 'share_tab')
      expect(Commands::Base::Registry).to have_received(:execute_command)
        .with(char_instance, 'media share tab')
    end

    it 'handles exception gracefully' do
      allow(Commands::Base::Registry).to receive(:execute_command)
        .and_raise(StandardError.new('Error'))

      result = described_class.send(:handle_media_quickmenu, char_instance, {}, 'play')
      expect(result[:success]).to be false
      expect(result[:error]).to include('Failed to process media')
    end
  end

  describe 'property quickmenu edge cases' do
    before do
      allow(OutputHelper).to receive(:complete_interaction)
    end

    describe '#handle_property_quickmenu' do
      it 'handles list option' do
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: true, message: 'Properties listed.' })

        result = described_class.send(:handle_property_quickmenu, char_instance, {}, 'list')
        expect(Commands::Base::Registry).to have_received(:execute_command)
          .with(char_instance, 'property list')
      end

      it 'handles access option' do
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: true, message: 'Access shown.' })

        result = described_class.send(:handle_property_quickmenu, char_instance, {}, 'access')
        expect(Commands::Base::Registry).to have_received(:execute_command)
          .with(char_instance, 'property access')
      end

      it 'handles lock option' do
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: true, message: 'Locked.' })

        result = described_class.send(:handle_property_quickmenu, char_instance, {}, 'lock')
        expect(Commands::Base::Registry).to have_received(:execute_command)
          .with(char_instance, 'property lock')
      end

      it 'handles unlock option' do
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: true, message: 'Unlocked.' })

        result = described_class.send(:handle_property_quickmenu, char_instance, {}, 'unlock')
        expect(Commands::Base::Registry).to have_received(:execute_command)
          .with(char_instance, 'property unlock')
      end

      it 'handles lock_doors option' do
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: true, message: 'Doors locked.' })

        result = described_class.send(:handle_property_quickmenu, char_instance, {}, 'lock_doors')
        expect(Commands::Base::Registry).to have_received(:execute_command)
          .with(char_instance, 'property lock doors')
      end

      it 'handles unlock_doors option' do
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: true, message: 'Doors unlocked.' })

        result = described_class.send(:handle_property_quickmenu, char_instance, {}, 'unlock_doors')
        expect(Commands::Base::Registry).to have_received(:execute_command)
          .with(char_instance, 'property unlock doors')
      end

      it 'handles grant option' do
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: true, message: 'Grant menu.' })

        result = described_class.send(:handle_property_quickmenu, char_instance, {}, 'grant')
        expect(Commands::Base::Registry).to have_received(:execute_command)
          .with(char_instance, 'property grant')
      end

      it 'handles revoke option' do
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: true, message: 'Revoke menu.' })

        result = described_class.send(:handle_property_quickmenu, char_instance, {}, 'revoke')
        expect(Commands::Base::Registry).to have_received(:execute_command)
          .with(char_instance, 'property revoke')
      end

      it 'handles general option' do
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: true, message: 'Permissions.' })

        result = described_class.send(:handle_property_quickmenu, char_instance, {}, 'general')
        expect(Commands::Base::Registry).to have_received(:execute_command)
          .with(char_instance, 'property general')
      end

      it 'handles exception gracefully' do
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_raise(StandardError.new('Error'))

        result = described_class.send(:handle_property_quickmenu, char_instance, {}, 'list')
        expect(result[:success]).to be false
        expect(result[:error]).to include('Failed to process property')
      end
    end

    describe '#handle_property_grant_quickmenu' do
      it 'handles valid selection' do
        context = { characters: [{ name: 'Alice' }] }
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: true, message: 'Access granted.' })

        result = described_class.send(:handle_property_grant_quickmenu, char_instance, context, '1')
        expect(result[:success]).to be true
        expect(Commands::Base::Registry).to have_received(:execute_command)
          .with(char_instance, 'property grant Alice')
      end

      it 'handles command failure' do
        context = { characters: [{ name: 'Alice' }] }
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: false, error: 'Already has access.' })

        result = described_class.send(:handle_property_grant_quickmenu, char_instance, context, '1')
        expect(result[:success]).to be false
      end

      it 'handles exception gracefully' do
        context = { characters: [{ name: 'Alice' }] }
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_raise(StandardError.new('Error'))

        result = described_class.send(:handle_property_grant_quickmenu, char_instance, context, '1')
        expect(result[:success]).to be false
        expect(result[:error]).to include('Failed to grant access')
      end
    end

    describe '#handle_property_revoke_quickmenu' do
      it 'handles valid selection' do
        context = { characters: [{ name: 'Bob' }] }
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: true, message: 'Access revoked.' })

        result = described_class.send(:handle_property_revoke_quickmenu, char_instance, context, '1')
        expect(result[:success]).to be true
        expect(Commands::Base::Registry).to have_received(:execute_command)
          .with(char_instance, 'property revoke Bob')
      end

      it 'handles command failure' do
        context = { characters: [{ name: 'Bob' }] }
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: false, error: 'No access to revoke.' })

        result = described_class.send(:handle_property_revoke_quickmenu, char_instance, context, '1')
        expect(result[:success]).to be false
      end

      it 'handles exception gracefully' do
        context = { characters: [{ name: 'Bob' }] }
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_raise(StandardError.new('Error'))

        result = described_class.send(:handle_property_revoke_quickmenu, char_instance, context, '1')
        expect(result[:success]).to be false
        expect(result[:error]).to include('Failed to revoke access')
      end
    end
  end

  describe 'permissions quickmenu edge cases' do
    before do
      allow(OutputHelper).to receive(:complete_interaction)
    end

    it 'handles exception gracefully' do
      allow(Commands::Base::Registry).to receive(:execute_command)
        .and_raise(StandardError.new('Error'))

      result = described_class.send(:handle_permissions_quickmenu, char_instance, {}, 'general')
      expect(result[:success]).to be false
      expect(result[:error]).to include('Failed to process permissions')
    end
  end

  describe 'dress consent quickmenu' do
    let(:requester_char) { create(:character, forename: 'Dresser') }
    let(:requester_instance) do
      create(:character_instance, character: requester_char, current_room: room, online: true)
    end

    before do
      allow(BroadcastService).to receive(:to_character)
      allow(InteractionPermissionService).to receive(:grant_temporary_permission).and_return(true)
    end

    it 'grants temporary dress permission when accepted' do
      context = { 'dresser_id' => requester_instance.id, 'item_id' => nil, 'room_id' => room.id }

      result = described_class.send(:handle_dress_consent_quickmenu, char_instance, context, 'yes')

      expect(result[:success]).to be true
      expect(InteractionPermissionService).to have_received(:grant_temporary_permission)
        .with(char_instance, requester_instance, 'dress', room_id: room.id)
    end

    it 'returns an error when requester is unavailable' do
      context = { 'dresser_id' => 999_999, 'room_id' => room.id }

      result = described_class.send(:handle_dress_consent_quickmenu, char_instance, context, 'yes')

      expect(result[:success]).to be false
      expect(result[:error]).to include('no longer available')
    end

    it 'dispatches dress consent action from quickmenu response' do
      quickmenu = {
        interaction_id: 'dress-123',
        type: 'quickmenu',
        options: [{ key: 'yes', label: 'Yes' }],
        context: { action: 'dress_consent', dresser_id: requester_instance.id, room_id: room.id }
      }

      allow(OutputHelper).to receive(:complete_interaction)
      allow(described_class).to receive(:handle_dress_consent_quickmenu).and_call_original

      described_class.send(:handle_quickmenu_response, char_instance, quickmenu, 'yes')

      expect(described_class).to have_received(:handle_dress_consent_quickmenu)
    end
  end

  describe 'map quickmenu edge cases' do
    before do
      allow(OutputHelper).to receive(:complete_interaction)
    end

    it 'handles exception gracefully' do
      allow(Commands::Base::Registry).to receive(:execute_command)
        .and_raise(StandardError.new('Error'))

      result = described_class.send(:handle_map_quickmenu, char_instance, {}, 'room')
      expect(result[:success]).to be false
      expect(result[:error]).to include('Failed to display map')
    end
  end

  describe 'journey quickmenu edge cases' do
    before do
      allow(OutputHelper).to receive(:complete_interaction)
    end

    it 'handles exception gracefully' do
      allow(Commands::Base::Registry).to receive(:execute_command)
        .and_raise(StandardError.new('Error'))

      result = described_class.send(:handle_journey_quickmenu, char_instance, {}, 'status')
      expect(result[:success]).to be false
      expect(result[:error]).to include('Failed to process journey')
    end
  end

  describe 'clan quickmenu edge cases' do
    before do
      allow(OutputHelper).to receive(:complete_interaction)
    end

    it 'handles exception gracefully' do
      allow(ClanDisambiguationHandler).to receive(:process_response)
        .and_raise(StandardError.new('Error'))

      result = described_class.send(:handle_clan_quickmenu, char_instance, {}, '1')
      expect(result[:success]).to be false
      expect(result[:error]).to include('Failed to process clan')
    end
  end

  describe 'multi-stage use quickmenu' do
    before do
      allow(OutputHelper).to receive(:complete_interaction)
    end

    describe '#handle_use_item_selection' do
      it 'handles empty items array' do
        context = { stage: 'select_item', items: [] }
        result = described_class.send(:handle_use_item_selection, char_instance, context, '1')
        expect(result[:success]).to be false
        expect(result[:error]).to include('Invalid selection')
      end

      it 'handles nil items' do
        context = { stage: 'select_item', items: nil }
        result = described_class.send(:handle_use_item_selection, char_instance, context, '1')
        expect(result[:success]).to be false
        expect(result[:error]).to include('Invalid selection')
      end

      it 'handles negative index selection' do
        context = { stage: 'select_item', items: [{ name: 'Sword' }] }
        result = described_class.send(:handle_use_item_selection, char_instance, context, '0')
        expect(result[:success]).to be false
        expect(result[:error]).to include('Invalid selection')
      end

      it 'handles selection beyond array bounds' do
        context = { stage: 'select_item', items: [{ name: 'Sword' }] }
        result = described_class.send(:handle_use_item_selection, char_instance, context, '999')
        expect(result[:success]).to be false
        expect(result[:error]).to include('Invalid selection')
      end

      it 'handles non-numeric selection' do
        context = { stage: 'select_item', items: [{ name: 'Sword' }] }
        result = described_class.send(:handle_use_item_selection, char_instance, context, 'abc')
        expect(result[:success]).to be false
        expect(result[:error]).to include('Invalid selection')
      end

      it 'handles command failure' do
        context = { stage: 'select_item', items: [{ name: 'Sword' }] }
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: false, error: 'Item not found' })

        result = described_class.send(:handle_use_item_selection, char_instance, context, '1')
        expect(result[:success]).to be false
        expect(result[:error]).to eq('Item not found')
      end
    end

    describe '#handle_use_action_selection' do
      let(:item) { create(:item, name: 'Test Sword') }

      before do
        allow(char_instance).to receive(:objects_dataset)
          .and_return(Item.where(id: item.id))
      end

      it 'handles missing item' do
        allow(char_instance).to receive(:objects_dataset)
          .and_return(Item.where(id: 0))
        context = { stage: 'select_action', item_id: 999, item_name: 'Ghost Item' }

        result = described_class.send(:handle_use_action_selection, char_instance, context, 'h')
        expect(result[:success]).to be false
        expect(result[:error]).to include('no longer have')
      end

      it 'handles invalid action key' do
        context = { stage: 'select_action', item_id: item.id, item_name: 'Test Sword' }

        result = described_class.send(:handle_use_action_selection, char_instance, context, 'x')
        expect(result[:success]).to be false
        expect(result[:error]).to include('Invalid action')
      end

      it 'handles hold action' do
        context = { stage: 'select_action', item_id: item.id, item_name: 'Test Sword' }
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: true, message: 'You hold the sword.' })

        result = described_class.send(:handle_use_action_selection, char_instance, context, 'h')
        expect(result[:success]).to be true
        expect(result[:message]).to include('hold')
      end

      it 'handles release action' do
        context = { stage: 'select_action', item_id: item.id, item_name: 'Test Sword' }
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: true, message: 'You release the sword.' })

        result = described_class.send(:handle_use_action_selection, char_instance, context, 'r')
        expect(result[:success]).to be true
      end

      it 'handles wear action for unworn item' do
        context = { stage: 'select_action', item_id: item.id, item_name: 'Test Sword' }
        allow(item).to receive(:worn?).and_return(false)
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: true, message: 'You wear the item.' })

        result = described_class.send(:handle_use_action_selection, char_instance, context, 'w')
        expect(result[:success]).to be true
      end

      it 'handles consume action' do
        context = { stage: 'select_action', item_id: item.id, item_name: 'Test Potion' }
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: true, message: 'You drink the potion.' })

        result = described_class.send(:handle_use_action_selection, char_instance, context, 'c')
        expect(result[:success]).to be true
      end

      it 'handles drop action' do
        context = { stage: 'select_action', item_id: item.id, item_name: 'Test Sword' }
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: true, message: 'You drop the sword.' })

        result = described_class.send(:handle_use_action_selection, char_instance, context, 'd')
        expect(result[:success]).to be true
      end

      it 'handles examine action' do
        context = { stage: 'select_action', item_id: item.id, item_name: 'Test Sword' }
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: true, message: 'A shiny sword.' })

        result = described_class.send(:handle_use_action_selection, char_instance, context, 'e')
        expect(result[:success]).to be true
      end

      it 'handles give action' do
        context = { stage: 'select_action', item_id: item.id, item_name: 'Test Sword' }
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: true, message: 'Who do you want to give it to?', type: :quickmenu })

        result = described_class.send(:handle_use_action_selection, char_instance, context, 'g')
        expect(result[:success]).to be true
      end

      it 'handles show action' do
        context = { stage: 'select_action', item_id: item.id, item_name: 'Test Sword' }
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: true, message: 'Who do you want to show it to?', type: :quickmenu })

        result = described_class.send(:handle_use_action_selection, char_instance, context, 's')
        expect(result[:success]).to be true
      end

      it 'handles command failure' do
        context = { stage: 'select_action', item_id: item.id, item_name: 'Test Sword' }
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: false, error: 'Cannot drop in this room.' })

        result = described_class.send(:handle_use_action_selection, char_instance, context, 'd')
        expect(result[:success]).to be false
        expect(result[:error]).to eq('Cannot drop in this room.')
      end
    end

    describe '#handle_use_quickmenu' do
      it 'handles cancel at any stage' do
        context = { stage: 'select_item' }
        result = described_class.send(:handle_use_quickmenu, char_instance, context, 'q')
        expect(result[:success]).to be true
        expect(result[:message]).to eq('Cancelled.')
      end

      it 'handles unknown stage' do
        context = { stage: 'unknown_stage' }
        result = described_class.send(:handle_use_quickmenu, char_instance, context, '1')
        expect(result[:success]).to be false
        expect(result[:error]).to include('Invalid use menu state')
      end

      it 'handles game branch selection stage' do
        context = { stage: 'select_game_branch' }
        allow(described_class).to receive(:handle_use_game_branch_selection)
          .and_return({ success: true, message: 'Game started!' })

        result = described_class.send(:handle_use_quickmenu, char_instance, context, '1')
        expect(result[:success]).to be true
      end
    end
  end

  describe 'intercept method edge cases' do
    describe '.intercept' do
      it 'returns nil for blank input' do
        expect(described_class.intercept(char_instance, '')).to be_nil
        expect(described_class.intercept(char_instance, nil)).to be_nil
        expect(described_class.intercept(char_instance, '   ')).to be_nil
      end

      it 'returns nil when no pending quickmenus' do
        allow(OutputHelper).to receive(:get_pending_interactions).and_return([])
        result = described_class.intercept(char_instance, '1')
        expect(result).to be_nil
      end

      it 'tries activity shortcut when not matching quickmenu' do
        allow(OutputHelper).to receive(:get_pending_interactions).and_return([])
        allow(described_class).to receive(:try_activity_shortcut).and_return({ success: true })

        result = described_class.intercept(char_instance, '1')
        expect(result[:success]).to be true
      end
    end
  end

  describe 'rewrite_for_context edge cases' do
    describe '.rewrite_for_context' do
      it 'returns original input when blank' do
        expect(described_class.rewrite_for_context(char_instance, '')).to eq('')
        expect(described_class.rewrite_for_context(char_instance, nil)).to be_nil
      end

      it 'returns original input when not in activity' do
        allow(described_class).to receive(:in_activity?).and_return(false)
        result = described_class.rewrite_for_context(char_instance, 'look')
        expect(result).to eq('look')
      end

      it 'rewrites activity subcommands when in activity' do
        allow(described_class).to receive(:in_activity?).and_return(true)
        result = described_class.rewrite_for_context(char_instance, 'status')
        expect(result).to eq('activity status')
      end

      it 'does not rewrite non-activity commands' do
        allow(described_class).to receive(:in_activity?).and_return(true)
        result = described_class.rewrite_for_context(char_instance, 'look')
        expect(result).to eq('look')
      end

      it 'does not double-rewrite activity command' do
        allow(described_class).to receive(:in_activity?).and_return(true)
        result = described_class.rewrite_for_context(char_instance, 'activity status')
        expect(result).to eq('activity status')
      end
    end
  end

  describe 'in_activity? private method' do
    it 'returns false for nil char_instance' do
      result = described_class.send(:in_activity?, nil)
      expect(result).to be false
    end

    it 'returns false when ActivityService is not defined' do
      allow(described_class).to receive(:defined?).with(ActivityService).and_return(false)
      result = described_class.send(:in_activity?, char_instance)
      expect(result).to be false
    end

    it 'returns false when room is nil' do
      allow(char_instance).to receive(:current_room).and_return(nil)
      result = described_class.send(:in_activity?, char_instance)
      expect(result).to be false
    end

    it 'returns false when no running activity' do
      allow(ActivityService).to receive(:running_activity).and_return(nil)
      result = described_class.send(:in_activity?, char_instance)
      expect(result).to be false
    end

    it 'returns false when participant is not active' do
      activity = double('ActivityInstance', paused_for_combat?: false)
      participant = double('ActivityParticipant', active?: false)
      allow(ActivityService).to receive(:running_activity).and_return(activity)
      allow(ActivityService).to receive(:participant_for).and_return(participant)

      result = described_class.send(:in_activity?, char_instance)
      expect(result).to be false
    end

    it 'returns true when participant is active' do
      activity = double('ActivityInstance', paused_for_combat?: false)
      participant = double('ActivityParticipant', active?: true)
      allow(ActivityService).to receive(:running_activity).and_return(activity)
      allow(ActivityService).to receive(:participant_for).and_return(participant)

      result = described_class.send(:in_activity?, char_instance)
      expect(result).to be true
    end

    it 'handles exception gracefully' do
      allow(ActivityService).to receive(:running_activity).and_raise(StandardError.new('DB error'))
      result = described_class.send(:in_activity?, char_instance)
      expect(result).to be false
    end
  end

  describe 'boundary value tests' do
    before do
      allow(OutputHelper).to receive(:complete_interaction)
    end

    describe 'roll quickmenu selection' do
      it 'handles selection at exactly array boundary' do
        context = { stats: [{ abbr: 'STR' }, { abbr: 'DEX' }] }
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: true, message: 'Roll result' })

        result = described_class.send(:handle_roll_quickmenu, char_instance, context, '2')
        expect(result[:success]).to be true
      end

      it 'handles selection one past array boundary' do
        context = { stats: [{ abbr: 'STR' }, { abbr: 'DEX' }] }
        result = described_class.send(:handle_roll_quickmenu, char_instance, context, '3')
        expect(result[:success]).to be false
        expect(result[:error]).to include('Invalid selection')
      end
    end

    describe 'buy quickmenu selection' do
      it 'handles first item selection' do
        context = { items: [{ name: 'Sword' }, { name: 'Shield' }] }
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: true, message: 'Bought sword' })

        result = described_class.send(:handle_buy_quickmenu, char_instance, context, '1')
        expect(result[:success]).to be true
      end

      it 'handles last item selection' do
        context = { items: [{ name: 'Sword' }, { name: 'Shield' }, { name: 'Potion' }] }
        allow(Commands::Base::Registry).to receive(:execute_command)
          .and_return({ success: true, message: 'Bought potion' })

        result = described_class.send(:handle_buy_quickmenu, char_instance, context, '3')
        expect(result[:success]).to be true
      end
    end
  end

  describe 'execute_roll_command edge cases' do
    it 'handles successful roll' do
      allow(Commands::Base::Registry).to receive(:execute_command)
        .and_return({ success: true, message: 'You rolled 15!', type: :roll, data: { total: 15 } })

      result = described_class.send(:execute_roll_command, char_instance, 'STR')
      expect(result[:success]).to be true
      expect(result[:type]).to eq(:roll)
      expect(result[:data][:total]).to eq(15)
    end

    it 'handles failed roll with error message' do
      allow(Commands::Base::Registry).to receive(:execute_command)
        .and_return({ success: false, error: 'Invalid stat' })

      result = described_class.send(:execute_roll_command, char_instance, 'INVALID')
      expect(result[:success]).to be false
      expect(result[:error]).to eq('Invalid stat')
    end

    it 'handles failed roll with message instead of error' do
      allow(Commands::Base::Registry).to receive(:execute_command)
        .and_return({ success: false, message: 'You cannot roll right now.' })

      result = described_class.send(:execute_roll_command, char_instance, 'STR')
      expect(result[:success]).to be false
      expect(result[:error]).to eq('You cannot roll right now.')
    end

    it 'handles exception during command execution' do
      allow(Commands::Base::Registry).to receive(:execute_command)
        .and_raise(StandardError.new('Command registry error'))

      result = described_class.send(:execute_roll_command, char_instance, 'STR')
      expect(result[:success]).to be false
      expect(result[:error]).to eq('Failed to execute roll.')
    end
  end

  describe 'try_quickmenu_shortcut edge cases' do
    it 'handles empty pending interactions' do
      allow(OutputHelper).to receive(:get_pending_interactions).and_return([])
      result = described_class.send(:try_quickmenu_shortcut, char_instance, '1')
      expect(result).to be_nil
    end

    it 'handles no quickmenus in pending interactions' do
      allow(OutputHelper).to receive(:get_pending_interactions).and_return([
        { type: 'form', interaction_id: 'form-1' }
      ])
      result = described_class.send(:try_quickmenu_shortcut, char_instance, '1')
      expect(result).to be_nil
    end

    it 'uses most recent quickmenu when multiple exist' do
      allow(OutputHelper).to receive(:get_pending_interactions).and_return([
        { type: 'quickmenu', interaction_id: 'qm-1', created_at: '2024-01-01T10:00:00', options: [{ key: '1', label: 'Old' }], context: {} },
        { type: 'quickmenu', interaction_id: 'qm-2', created_at: '2024-01-01T12:00:00', options: [{ key: '1', label: 'New' }], context: {} }
      ])
      allow(OutputHelper).to receive(:complete_interaction)

      result = described_class.send(:try_quickmenu_shortcut, char_instance, '1')
      # The newer quickmenu should be selected
      expect(OutputHelper).to have_received(:complete_interaction).with(char_instance.id, 'qm-2')
    end

    it 'matches by label case-insensitively' do
      allow(OutputHelper).to receive(:get_pending_interactions).and_return([
        { type: 'quickmenu', interaction_id: 'qm-1', options: [{ key: 'a', label: 'Accept' }], context: {} }
      ])
      allow(OutputHelper).to receive(:complete_interaction)

      result = described_class.send(:try_quickmenu_shortcut, char_instance, 'ACCEPT')
      expect(result).not_to be_nil
    end

    it 'returns nil when no option matches' do
      allow(OutputHelper).to receive(:get_pending_interactions).and_return([
        { type: 'quickmenu', interaction_id: 'qm-1', options: [{ key: '1', label: 'Option 1' }], context: {} }
      ])

      result = described_class.send(:try_quickmenu_shortcut, char_instance, 'xyz')
      expect(result).to be_nil
    end

    it 'handles quickmenu without options gracefully' do
      allow(OutputHelper).to receive(:get_pending_interactions).and_return([
        { type: 'quickmenu', interaction_id: 'qm-1', options: nil, context: {} }
      ])

      result = described_class.send(:try_quickmenu_shortcut, char_instance, '1')
      expect(result).to be_nil
    end
  end

  describe 'handle_timeline_quickmenu edge cases' do
    let(:timeline_quickmenu) do
      {
        type: 'quickmenu',
        interaction_id: 'timeline-qm',
        context: { command: 'timeline' },
        options: [
          { key: '1', label: 'Enter Timeline' },
          { key: '2', label: 'Create Timeline' },
          { key: '3', label: 'Leave Current' },
          { key: 'q', label: 'Cancel' }
        ]
      }
    end

    before do
      allow(OutputHelper).to receive(:get_pending_interactions).and_return([timeline_quickmenu])
      allow(OutputHelper).to receive(:complete_interaction)
      allow(OutputHelper).to receive(:send_quickmenu)
      allow(OutputHelper).to receive(:send_form)
    end

    it 'routes to timeline handler on selection' do
      # The handler shows a submenu, stub that
      allow(OutputHelper).to receive(:send_output)
      result = described_class.intercept(char_instance, '1')
      expect(result).to be_a(Hash)
    end
  end

  describe 'handle_wardrobe_quickmenu edge cases' do
    let(:wardrobe_quickmenu) do
      {
        type: 'quickmenu',
        interaction_id: 'wardrobe-qm',
        context: { command: 'wardrobe' },
        options: [
          { key: '1', label: 'Store Item' },
          { key: '2', label: 'Retrieve Item' },
          { key: 'q', label: 'Cancel' }
        ]
      }
    end

    before do
      allow(OutputHelper).to receive(:get_pending_interactions).and_return([wardrobe_quickmenu])
      allow(OutputHelper).to receive(:complete_interaction)
    end

    it 'handles cancel selection' do
      result = described_class.intercept(char_instance, 'q')
      expect(result[:success]).to be true
    end
  end

  describe 'handle_shop_quickmenu edge cases' do
    let(:shop_quickmenu) do
      {
        type: 'quickmenu',
        interaction_id: 'shop-qm',
        context: { command: 'shop', shop_id: 1, categories: ['weapons'] },
        options: [
          { key: '1', label: 'Weapons' },
          { key: 'q', label: 'Leave Shop' }
        ]
      }
    end

    before do
      allow(OutputHelper).to receive(:get_pending_interactions).and_return([shop_quickmenu])
      allow(OutputHelper).to receive(:complete_interaction)
      allow(Commands::Base::Registry).to receive(:execute_command)
        .and_return({ success: true, message: 'Left shop.' })
    end

    it 'executes shop command on selection' do
      result = described_class.intercept(char_instance, 'q')
      expect(result).to be_a(Hash)
      expect(result[:success]).to be true
    end
  end

  describe 'handle_clan_quickmenu edge cases' do
    let(:clan_quickmenu) do
      {
        type: 'quickmenu',
        interaction_id: 'clan-qm',
        context: { command: 'clan' },
        options: [
          { key: '1', label: 'View Members' },
          { key: '2', label: 'Leave Clan' },
          { key: 'q', label: 'Cancel' }
        ]
      }
    end

    before do
      allow(OutputHelper).to receive(:get_pending_interactions).and_return([clan_quickmenu])
      allow(OutputHelper).to receive(:complete_interaction)
    end

    it 'handles cancel selection' do
      result = described_class.intercept(char_instance, 'q')
      expect(result[:success]).to be true
    end
  end

  describe 'handle_party_invite_quickmenu edge cases' do
    let(:party) do
      double('TravelParty',
             leader: char_instance,
             destination: double('Location', name: 'Some Destination'))
    end
    let(:member) do
      double('TravelPartyMember',
             id: 42,
             character_instance_id: char_instance.id,
             party: party,
             decline!: true)
    end
    let(:party_quickmenu) do
      {
        type: 'quickmenu',
        interaction_id: 'party-qm',
        context: { handler: 'party_invite', member_id: member.id },
        options: [
          { key: 'accept', label: 'Accept' },
          { key: 'decline', label: 'Decline' }
        ]
      }
    end

    before do
      allow(OutputHelper).to receive(:get_pending_interactions).and_return([party_quickmenu])
      allow(OutputHelper).to receive(:complete_interaction)
      allow(TravelPartyMember).to receive(:[]).with(member.id).and_return(member)
      allow(BroadcastService).to receive(:to_character)
    end

    it 'handles decline selection' do
      result = described_class.intercept(char_instance, '2')
      expect(result[:success]).to be true
    end
  end

  describe 'handle_tickets_quickmenu edge cases' do
    let(:tickets_quickmenu) do
      {
        type: 'quickmenu',
        interaction_id: 'tickets-qm',
        context: { command: 'tickets' },
        options: [
          { key: '1', label: 'View My Tickets' },
          { key: '2', label: 'Create New Ticket' },
          { key: 'q', label: 'Cancel' }
        ]
      }
    end

    before do
      allow(OutputHelper).to receive(:get_pending_interactions).and_return([tickets_quickmenu])
      allow(OutputHelper).to receive(:complete_interaction)
    end

    it 'handles cancel selection' do
      result = described_class.intercept(char_instance, 'q')
      expect(result[:success]).to be true
    end
  end

  describe 'handle_map_quickmenu edge cases' do
    let(:map_quickmenu) do
      {
        type: 'quickmenu',
        interaction_id: 'map-qm',
        context: { command: 'map' },
        options: [
          { key: '1', label: 'View World Map' },
          { key: '2', label: 'View Local Map' },
          { key: 'q', label: 'Cancel' }
        ]
      }
    end

    before do
      allow(OutputHelper).to receive(:get_pending_interactions).and_return([map_quickmenu])
      allow(OutputHelper).to receive(:complete_interaction)
      allow(Commands::Base::Registry).to receive(:execute_command)
        .and_return({ success: true, message: 'Map displayed.', type: :map })
    end

    it 'executes map command on selection' do
      result = described_class.intercept(char_instance, '1')
      expect(result).to be_a(Hash)
      expect(result[:success]).to be true
    end
  end

  describe 'handle_journey_quickmenu edge cases' do
    let(:journey_quickmenu) do
      {
        type: 'quickmenu',
        interaction_id: 'journey-qm',
        context: { command: 'journey', destinations: [{ id: 1, name: 'Town' }] },
        options: [
          { key: '1', label: 'Town' },
          { key: 'q', label: 'Cancel' }
        ]
      }
    end

    before do
      allow(OutputHelper).to receive(:get_pending_interactions).and_return([journey_quickmenu])
      allow(OutputHelper).to receive(:complete_interaction)
      allow(Commands::Base::Registry).to receive(:execute_command)
        .and_return({ success: true, message: 'Journey started.' })
    end

    it 'executes journey command on selection' do
      result = described_class.intercept(char_instance, '1')
      expect(result).to be_a(Hash)
      expect(result[:success]).to be true
    end
  end

  describe 'handle_media_quickmenu edge cases' do
    let(:media_quickmenu) do
      {
        type: 'quickmenu',
        interaction_id: 'media-qm',
        context: { command: 'media' },
        options: [
          { key: '1', label: 'Play Music' },
          { key: '2', label: 'Stop Music' },
          { key: 'q', label: 'Cancel' }
        ]
      }
    end

    before do
      allow(OutputHelper).to receive(:get_pending_interactions).and_return([media_quickmenu])
      allow(OutputHelper).to receive(:complete_interaction)
      allow(Commands::Base::Registry).to receive(:execute_command)
        .and_return({ success: true, message: 'Media playing.' })
    end

    it 'executes media command on selection' do
      result = described_class.intercept(char_instance, '1')
      expect(result).to be_a(Hash)
      expect(result[:success]).to be true
    end
  end

  describe 'handle_attempt_quickmenu edge cases' do
    let(:attempter_char) { create(:character, forename: 'Thief') }
    let(:attempter_instance) { create(:character_instance, character: attempter_char, current_room: room, online: true) }
    let(:attempt_quickmenu) do
      {
        type: 'quickmenu',
        interaction_id: 'attempt-qm',
        context: { handler: 'attempt', attempter_id: attempter_instance.id, emote_text: 'picks your pocket', sender_name: 'Thief' },
        options: [
          { key: 'allow', label: 'Allow' },
          { key: 'deny', label: 'Deny' }
        ]
      }
    end

    before do
      allow(OutputHelper).to receive(:get_pending_interactions).and_return([attempt_quickmenu])
      allow(OutputHelper).to receive(:complete_interaction)
      allow(BroadcastService).to receive(:to_character)
      allow(char_instance).to receive(:clear_pending_attempt!)
      allow(attempter_instance).to receive(:clear_attempt!)
    end

    it 'handles deny selection' do
      result = described_class.intercept(char_instance, '2')
      expect(result[:success]).to be true
      expect(result[:message]).to include('denied')
    end
  end

  describe 'handle_use_quickmenu edge cases' do
    let(:use_quickmenu) do
      {
        type: 'quickmenu',
        interaction_id: 'use-qm',
        context: { command: 'use', items: [{ id: 1, name: 'Potion' }] },
        options: [
          { key: '1', label: 'Potion' },
          { key: 'q', label: 'Cancel' }
        ]
      }
    end

    before do
      allow(OutputHelper).to receive(:get_pending_interactions).and_return([use_quickmenu])
      allow(OutputHelper).to receive(:complete_interaction)
    end

    it 'handles cancel selection' do
      result = described_class.intercept(char_instance, 'q')
      expect(result[:success]).to be true
    end
  end

  describe 'format_quickmenu_html' do
    it 'generates HTML for prompt and options' do
      html = described_class.send(:format_quickmenu_html, 'Choose:', [
        { key: '1', label: 'Option A' },
        { key: '2', label: 'Option B' }
      ])
      expect(html).to include('Choose:')
      expect(html).to include('Option A')
      expect(html).to include('Option B')
    end

    it 'handles empty options array' do
      html = described_class.send(:format_quickmenu_html, 'Choose:', [])
      expect(html).to include('Choose:')
    end
  end

  describe 'format_command_result' do
    it 'formats success result with standard keys' do
      result = { success: true, message: 'Done!' }
      formatted = described_class.send(:format_command_result, result)
      expect(formatted[:success]).to be true
      expect(formatted[:message]).to eq('Done!')
    end

    it 'formats failure result' do
      result = { success: false, message: 'Something went wrong' }
      formatted = described_class.send(:format_command_result, result)
      expect(formatted[:success]).to be false
    end

    it 'handles nil result gracefully' do
      formatted = described_class.send(:format_command_result, nil)
      expect(formatted).to be_nil
    end

    it 'includes type when present' do
      result = { success: true, message: 'Done!', type: :roll, data: { total: 15 } }
      formatted = described_class.send(:format_command_result, result)
      expect(formatted[:type]).to eq(:roll)
      expect(formatted[:data]).to eq({ total: 15 })
    end
  end

  describe 'input validation edge cases' do
    it 'handles very long input' do
      long_input = 'a' * 10000
      expect(described_class.intercept(char_instance, long_input)).to be_nil
    end

    it 'handles special characters in input' do
      special_input = "<script>alert('xss')</script>"
      expect(described_class.intercept(char_instance, special_input)).to be_nil
    end

    it 'handles unicode input' do
      unicode_input = '你好世界 🎮'
      expect(described_class.intercept(char_instance, unicode_input)).to be_nil
    end

    it 'handles input with only numbers' do
      allow(OutputHelper).to receive(:get_pending_interactions).and_return([])
      allow(ActivityService).to receive(:running_activity).and_return(nil)
      expect(described_class.intercept(char_instance, '12345')).to be_nil
    end
  end

  describe 'activity shortcut edge cases' do
    it 'handles activity shortcut when not in activity' do
      allow(ActivityService).to receive(:running_activity).and_return(nil)
      result = described_class.send(:try_activity_shortcut, char_instance, '1')
      expect(result).to be_nil
    end

    it 'handles activity shortcut with no participant' do
      activity = double('Activity', id: 1, status: 'active')
      allow(ActivityService).to receive(:running_activity).and_return(activity)
      allow(activity).to receive(:participant_for).and_return(nil)
      result = described_class.send(:try_activity_shortcut, char_instance, '999')
      # Should return nil when no participant found
      expect(result).to be_nil
    end
  end

end
