# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ActivityLoggingService do
  let(:location) { create(:location) }
  let(:room) { create(:room, location: location) }
  let(:character) { create(:character) }
  let(:activity) do
    double('Activity',
           name: 'Test Mission',
           activity_type: 'mission',
           logging_enabled: true,
           logs_visible_to: 'public')
  end
  let(:instance) do
    double('ActivityInstance',
           id: 1,
           activity: activity,
           rounds_done: 3,
           rcount: 5,
           completed_at: nil,
           log_summary: nil,
           participants: [])
  end
  let(:round) do
    double('ActivityRound',
           id: 1,
           display_name: 'Challenge Round',
           emit_text: 'Face the challenge ahead',
           round_type: 'standard')
  end
  let(:participant) do
    double('ActivityParticipant',
           id: 1,
           character: character,
           score: 100,
           status_text: 'active')
  end

  describe '.log_narrative' do
    before do
      allow(ActivityLog).to receive(:next_sequence).and_return(1)
      allow(ActivityLog).to receive(:create).and_return(true)
    end

    it 'creates a narrative log entry' do
      expect(ActivityLog).to receive(:create).with(hash_including(
                                                     log_type: 'narrative',
                                                     text: 'The door opens slowly...',
                                                     activity_instance_id: instance.id
                                                   ))
      described_class.log_narrative(instance, 'The door opens slowly...')
    end

    it 'includes optional title' do
      expect(ActivityLog).to receive(:create).with(hash_including(title: 'Discovery'))
      described_class.log_narrative(instance, 'You find treasure!', title: 'Discovery')
    end

    it 'includes optional html content' do
      expect(ActivityLog).to receive(:create).with(hash_including(html_content: '<p>Test</p>'))
      described_class.log_narrative(instance, 'Test', html: '<p>Test</p>')
    end

    it 'uses current round_number by default' do
      expect(ActivityLog).to receive(:create).with(hash_including(round_number: 3))
      described_class.log_narrative(instance, 'Test')
    end

    it 'allows override of round_number' do
      expect(ActivityLog).to receive(:create).with(hash_including(round_number: 5))
      described_class.log_narrative(instance, 'Test', round_number: 5)
    end

    it 'returns without creating log when logging disabled' do
      allow(activity).to receive(:logging_enabled).and_return(false)
      expect(ActivityLog).not_to receive(:create)
      described_class.log_narrative(instance, 'Test')
    end
  end

  describe '.log_round_start' do
    before do
      allow(ActivityLog).to receive(:next_sequence).and_return(1)
      allow(ActivityLog).to receive(:create).and_return(true)
    end

    it 'creates a round_start log entry' do
      expect(ActivityLog).to receive(:create).with(hash_including(
                                                     log_type: 'round_start',
                                                     title: 'Challenge Round',
                                                     round_number: 4,
                                                     activity_round_id: round.id
                                                   ))
      described_class.log_round_start(instance, round)
    end

    it 'uses round number as title when no display_name provided' do
      allow(round).to receive(:display_name).and_return(nil)
      allow(round).to receive(:emit_text).and_return(nil)
      expect(ActivityLog).to receive(:create).with(hash_including(title: 'Round 4'))
      described_class.log_round_start(instance, round)
    end

    it 'generates HTML with round info' do
      expect(ActivityLog).to receive(:create) do |args|
        expect(args[:html_content]).to include('Round 4')
        expect(args[:html_content]).to include('Challenge Round')
      end
      described_class.log_round_start(instance, round)
    end

    it 'falls back to display_name and emit_text when title/description are missing' do
      fallback_round = double('ActivityRound',
                              id: 77,
                              round_type: 'reflex',
                              display_name: 'Bridge Collapse',
                              emit_text: 'Debris rains from above.')

      expect(ActivityLog).to receive(:create).with(hash_including(
                                                     title: 'Bridge Collapse',
                                                     text: 'Debris rains from above.'
                                                   ))

      described_class.log_round_start(instance, fallback_round)
    end
  end

  describe '.log_round_end' do
    before do
      allow(ActivityLog).to receive(:next_sequence).and_return(1)
      allow(ActivityLog).to receive(:create).and_return(true)
    end

    let(:outcomes) do
      {
        summary: 'Round completed successfully',
        participants: [
          { name: 'Hero', outcome: 'success', roll: 18, result: 'Succeeded' }
        ]
      }
    end

    it 'creates a round_end log entry' do
      expect(ActivityLog).to receive(:create).with(hash_including(
                                                     log_type: 'round_end',
                                                     title: 'Round 3 Complete'
                                                   ))
      described_class.log_round_end(instance, round, outcomes)
    end

    it 'includes summary in text' do
      expect(ActivityLog).to receive(:create).with(hash_including(text: 'Round completed successfully'))
      described_class.log_round_end(instance, round, outcomes)
    end

    it 'generates HTML with participant outcomes' do
      expect(ActivityLog).to receive(:create) do |args|
        expect(args[:html_content]).to include('Hero')
        expect(args[:html_content]).to include('outcome-success')
      end
      described_class.log_round_end(instance, round, outcomes)
    end
  end

  describe '.log_action' do
    before do
      allow(ActivityLog).to receive(:next_sequence).and_return(1)
      allow(ActivityLog).to receive(:create).and_return(true)
    end

    it 'creates an action log entry' do
      expect(ActivityLog).to receive(:create).with(hash_including(
                                                     log_type: 'action',
                                                     title: 'Attack',
                                                     action_name: 'Attack',
                                                     character_id: character.id
                                                   ))
      described_class.log_action(instance, participant, 'Attack')
    end

    it 'includes risk details in HTML' do
      expect(ActivityLog).to receive(:create) do |args|
        expect(args[:html_content]).to include('Risk: medium')
      end
      described_class.log_action(instance, participant, 'Attack', risk: 'medium')
    end
  end

  describe '.log_outcome' do
    before do
      allow(ActivityLog).to receive(:next_sequence).and_return(1)
      allow(ActivityLog).to receive(:create).and_return(true)
    end

    it 'creates an outcome log entry' do
      expect(ActivityLog).to receive(:create).with(hash_including(
                                                     log_type: 'outcome',
                                                     outcome: 'success',
                                                     character_id: character.id
                                                   ))
      described_class.log_outcome(instance, participant, 'success')
    end

    it 'includes roll and difficulty' do
      expect(ActivityLog).to receive(:create).with(hash_including(
                                                     roll_result: 18,
                                                     difficulty: 15
                                                   ))
      described_class.log_outcome(instance, participant, 'success', roll: 18, difficulty: 15)
    end

    it 'generates appropriate title for success' do
      expect(ActivityLog).to receive(:create).with(hash_including(title: 'Success!'))
      described_class.log_outcome(instance, participant, 'success')
    end

    it 'generates appropriate title for partial' do
      expect(ActivityLog).to receive(:create).with(hash_including(title: 'Partial Success'))
      described_class.log_outcome(instance, participant, 'partial')
    end

    it 'generates appropriate title for failure' do
      expect(ActivityLog).to receive(:create).with(hash_including(title: 'Failure'))
      described_class.log_outcome(instance, participant, 'failure')
    end
  end

  describe '.log_combat' do
    before do
      allow(ActivityLog).to receive(:next_sequence).and_return(1)
      allow(ActivityLog).to receive(:create).and_return(true)
    end

    it 'creates a combat log entry' do
      expect(ActivityLog).to receive(:create).with(hash_including(
                                                     log_type: 'combat',
                                                     text: 'The enemy attacks!'
                                                   ))
      described_class.log_combat(instance, 'The enemy attacks!')
    end

    it 'includes optional title' do
      expect(ActivityLog).to receive(:create).with(hash_including(title: 'Boss Fight'))
      described_class.log_combat(instance, 'Combat begins', title: 'Boss Fight')
    end

    it 'generates HTML with damage info' do
      expect(ActivityLog).to receive(:create) do |args|
        expect(args[:html_content]).to include('Damage: 15')
      end
      described_class.log_combat(instance, 'Hit!', damage: 15)
    end
  end

  describe '.log_system' do
    before do
      allow(ActivityLog).to receive(:next_sequence).and_return(1)
      allow(ActivityLog).to receive(:create).and_return(true)
    end

    it 'creates a system log entry' do
      expect(ActivityLog).to receive(:create).with(hash_including(
                                                     log_type: 'system',
                                                     title: 'System',
                                                     text: 'Game saved'
                                                   ))
      described_class.log_system(instance, 'Game saved')
    end

    it 'allows custom title' do
      expect(ActivityLog).to receive(:create).with(hash_including(title: 'Warning'))
      described_class.log_system(instance, 'Low health', title: 'Warning')
    end
  end

  describe '.log_summary' do
    before do
      allow(ActivityLog).to receive(:next_sequence).and_return(1)
      allow(ActivityLog).to receive(:create).and_return(true)
      allow(instance).to receive(:update)
      allow(instance).to receive(:participants).and_return([participant])
    end

    it 'creates a summary log entry' do
      expect(ActivityLog).to receive(:create).with(hash_including(
                                                     log_type: 'summary',
                                                     title: 'Mission Complete'
                                                   ))
      described_class.log_summary(instance)
    end

    it 'updates instance with summary and completion time' do
      expect(instance).to receive(:update).with(hash_including(:log_summary, :completed_at))
      described_class.log_summary(instance)
    end

    it 'uses custom summary when provided' do
      custom = { text: 'Custom ending!' }
      expect(ActivityLog).to receive(:create).with(hash_including(text: 'Custom ending!'))
      described_class.log_summary(instance, custom)
    end

    it 'generates auto summary with participant scores' do
      expect(instance).to receive(:update) do |args|
        expect(args[:log_summary]).to include('Test Mission')
        expect(args[:log_summary]).to include('3 rounds')
      end
      described_class.log_summary(instance)
    end

    it 'uses status_text when participant does not expose status' do
      participant_without_status = double('ActivityParticipant',
                                          character: character,
                                          score: 50,
                                          status_text: 'Ready')
      allow(instance).to receive(:participants).and_return([participant_without_status])

      expect { described_class.log_summary(instance) }.not_to raise_error
    end
  end

  describe '.logs_for_instance' do
    before do
      allow(ActivityLog).to receive(:for_instance).and_return(
        double(map: [{ id: 1, log_type: 'narrative' }])
      )
    end

    it 'returns logs as api hashes' do
      result = described_class.logs_for_instance(instance)
      expect(result).to be_an(Array)
    end

    it 'returns empty array when viewer cannot view logs' do
      allow(activity).to receive(:logs_visible_to).and_return('private')
      result = described_class.logs_for_instance(instance, viewer: character)
      expect(result).to eq([])
    end
  end

  describe '.logs_by_round' do
    let(:log1) { double('ActivityLog', round_number: 1) }
    let(:log2) { double('ActivityLog', round_number: 1) }
    let(:log3) { double('ActivityLog', round_number: 2) }

    before do
      allow(ActivityLog).to receive(:for_instance).and_return(
        double(all: [log1, log2, log3])
      )
    end

    it 'returns logs grouped by round' do
      result = described_class.logs_by_round(instance)
      expect(result).to be_a(Hash)
      expect(result[1]).to contain_exactly(log1, log2)
      expect(result[2]).to contain_exactly(log3)
    end

    it 'returns empty hash when viewer cannot view logs' do
      allow(activity).to receive(:logs_visible_to).and_return('private')
      result = described_class.logs_by_round(instance, viewer: character)
      expect(result).to eq({})
    end
  end

  describe '.logs_as_html' do
    let(:log) { double('ActivityLog', formatted_content: '<p>Test</p>') }

    before do
      allow(ActivityLog).to receive(:for_instance).and_return(double(all: [log]))
    end

    it 'returns full HTML document' do
      result = described_class.logs_as_html(instance)
      expect(result).to include('<!DOCTYPE html>')
      expect(result).to include('Test Mission')
      expect(result).to include('<p>Test</p>')
    end

    it 'returns nil when viewer cannot view logs' do
      allow(activity).to receive(:logs_visible_to).and_return('private')
      result = described_class.logs_as_html(instance, viewer: character)
      expect(result).to be_nil
    end

    it 'includes CSS styling' do
      result = described_class.logs_as_html(instance)
      expect(result).to include('<style>')
      expect(result).to include('font-family')
    end
  end

  describe '.can_view_logs?' do
    it 'returns false when instance is nil' do
      expect(described_class.can_view_logs?(nil, character)).to be false
    end

    it 'returns true for public visibility' do
      allow(activity).to receive(:logs_visible_to).and_return('public')
      expect(described_class.can_view_logs?(instance, character)).to be true
    end

    it 'returns false for private visibility' do
      allow(activity).to receive(:logs_visible_to).and_return('private')
      expect(described_class.can_view_logs?(instance, character)).to be false
    end

    context 'with participants visibility' do
      before do
        allow(activity).to receive(:logs_visible_to).and_return('participants')
      end

      it 'returns true when viewer is nil (API access)' do
        expect(described_class.can_view_logs?(instance, nil)).to be true
      end

      it 'returns true when viewer is a participant' do
        allow(instance).to receive(:participants).and_return([participant])
        allow(participant).to receive(:character).and_return(character)
        expect(described_class.can_view_logs?(instance, character)).to be true
      end

      it 'returns false when viewer is not a participant' do
        other_char = create(:character)
        allow(instance).to receive(:participants).and_return([participant])
        expect(described_class.can_view_logs?(instance, other_char)).to be false
      end
    end

    it 'returns true when activity is nil (default allow)' do
      allow(instance).to receive(:activity).and_return(nil)
      expect(described_class.can_view_logs?(instance, character)).to be true
    end
  end

  describe 'private method: logging_enabled?' do
    it 'returns false when instance is nil' do
      expect(described_class.send(:logging_enabled?, nil)).to be false
    end

    it 'returns true when activity is nil' do
      allow(instance).to receive(:activity).and_return(nil)
      expect(described_class.send(:logging_enabled?, instance)).to be true
    end

    it 'returns true when logging_enabled is true' do
      allow(activity).to receive(:logging_enabled).and_return(true)
      expect(described_class.send(:logging_enabled?, instance)).to be true
    end

    it 'returns false when logging_enabled is false' do
      allow(activity).to receive(:logging_enabled).and_return(false)
      expect(described_class.send(:logging_enabled?, instance)).to be false
    end
  end

  describe 'private method: outcome_title' do
    it 'returns Success! for success' do
      expect(described_class.send(:outcome_title, 'success')).to eq('Success!')
    end

    it 'returns Partial Success for partial' do
      expect(described_class.send(:outcome_title, 'partial')).to eq('Partial Success')
    end

    it 'returns Failure for failure' do
      expect(described_class.send(:outcome_title, 'failure')).to eq('Failure')
    end

    it 'capitalizes other outcomes' do
      expect(described_class.send(:outcome_title, 'custom')).to eq('Custom')
    end

    it 'returns Result for nil' do
      expect(described_class.send(:outcome_title, nil)).to eq('Result')
    end
  end

  describe 'HTML generation' do
    before do
      allow(ActivityLog).to receive(:next_sequence).and_return(1)
      allow(ActivityLog).to receive(:create).and_return(true)
    end

    describe 'build_round_start_html' do
      it 'includes round number and total' do
        html = described_class.send(:build_round_start_html, instance, round)
        expect(html).to include('Round 4 of 5')
      end

      it 'includes round title' do
        html = described_class.send(:build_round_start_html, instance, round)
        expect(html).to include('Challenge Round')
      end

      it 'includes description when present' do
        html = described_class.send(:build_round_start_html, instance, round)
        expect(html).to include('Face the challenge ahead')
      end

      it 'includes round type when not standard' do
        allow(round).to receive(:round_type).and_return('combat')
        html = described_class.send(:build_round_start_html, instance, round)
        expect(html).to include('Type: combat')
      end
    end

    describe 'build_action_html' do
      it 'includes character name' do
        html = described_class.send(:build_action_html, character, 'Attack', {})
        expect(html).to include(character.full_name)
      end

      it 'includes action name' do
        html = described_class.send(:build_action_html, character, 'Attack', {})
        expect(html).to include('Attack')
      end

      it 'includes risk level when provided' do
        html = described_class.send(:build_action_html, character, 'Attack', risk: 'high')
        expect(html).to include('Risk: high')
      end

      it 'does not include risk when not provided' do
        html = described_class.send(:build_action_html, character, 'Attack', {})
        expect(html).not_to include('Risk:')
      end
    end

    describe 'build_outcome_html' do
      it 'uses success class for success outcome' do
        html = described_class.send(:build_outcome_html, character, 'success', {})
        expect(html).to include('outcome-success')
      end

      it 'uses partial class for partial outcome' do
        html = described_class.send(:build_outcome_html, character, 'partial', {})
        expect(html).to include('outcome-partial')
      end

      it 'uses failure class for failure outcome' do
        html = described_class.send(:build_outcome_html, character, 'failure', {})
        expect(html).to include('outcome-failure')
      end

      it 'includes roll and difficulty when both provided' do
        html = described_class.send(:build_outcome_html, character, 'success', roll: 18, difficulty: 15)
        expect(html).to include('Roll: 18 vs DC 15')
      end

      it 'includes just roll when difficulty not provided' do
        html = described_class.send(:build_outcome_html, character, 'success', roll: 18)
        expect(html).to include('Roll: 18')
        expect(html).not_to include('DC')
      end
    end

    describe 'build_combat_html' do
      it 'includes description' do
        html = described_class.send(:build_combat_html, 'Enemy attacks!', {})
        expect(html).to include('Enemy attacks!')
      end

      it 'includes title when provided' do
        html = described_class.send(:build_combat_html, 'Combat', title: 'Boss Battle')
        expect(html).to include('Boss Battle')
      end

      it 'includes damage when provided' do
        html = described_class.send(:build_combat_html, 'Hit!', damage: 25)
        expect(html).to include('Damage: 25')
      end
    end

    describe 'build_summary_html' do
      let(:summary) do
        {
          text: 'Mission complete!',
          total_rounds: 5,
          winner: { name: 'Hero' },
          participants: [{ name: 'Hero', score: 100 }]
        }
      end

      it 'includes activity name' do
        html = described_class.send(:build_summary_html, instance, summary)
        expect(html).to include('Test Mission')
      end

      it 'includes total rounds' do
        html = described_class.send(:build_summary_html, instance, summary)
        expect(html).to include('Rounds: 5')
      end

      it 'includes winner' do
        html = described_class.send(:build_summary_html, instance, summary)
        expect(html).to include('Winner: Hero')
      end

      it 'includes participant scores' do
        html = described_class.send(:build_summary_html, instance, summary)
        expect(html).to include('Score: 100')
      end

      it 'includes summary text' do
        html = described_class.send(:build_summary_html, instance, summary)
        expect(html).to include('Mission complete!')
      end
    end
  end
end
