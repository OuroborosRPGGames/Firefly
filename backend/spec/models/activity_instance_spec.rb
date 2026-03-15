# frozen_string_literal: true

require 'spec_helper'

# Skip if activity_instances table doesn't exist
return unless DB.table_exists?(:activity_instances)

RSpec.describe ActivityInstance do
  let(:room) { create(:room) }
  let(:activity) { create(:activity) }

  let(:instance) do
    create(:activity_instance, activity: activity, room: room)
  end

  describe 'validations' do
    it 'requires activity_id' do
      invalid = ActivityInstance.new(room_id: room.id)
      expect(invalid.valid?).to be false
    end

    it 'requires room_id' do
      invalid = ActivityInstance.new(activity_id: activity.id)
      expect(invalid.valid?).to be false
    end

    it 'is valid with required attributes' do
      valid = ActivityInstance.new(
        activity_id: activity.id,
        room_id: room.id
      )
      expect(valid.valid?).to be true
    end
  end

  describe '#running?' do
    it 'returns true when running is true' do
      instance.update(running: true)
      expect(instance.running?).to be true
    end

    it 'returns false when running is false' do
      instance.update(running: false)
      expect(instance.running?).to be false
    end
  end

  describe '#in_setup?' do
    it 'returns true for pre-start setup stages' do
      instance.update(setup_stage: 0)
      expect(instance.in_setup?).to be true

      instance.update(setup_stage: 1)
      expect(instance.in_setup?).to be true
    end

    it 'returns false once activity has started' do
      instance.update(setup_stage: 2)
      expect(instance.in_setup?).to be false
    end

    it 'returns false when setup_stage >= 3' do
      instance.update(setup_stage: 3)
      expect(instance.in_setup?).to be false
    end

    it 'returns falsy when setup_stage is nil' do
      instance.update(setup_stage: nil)
      # Returns nil (falsy) because Ruby short-circuits on nil
      expect(instance.in_setup?).to be_falsy
    end
  end

  describe '#completed?' do
    it 'returns true when not running' do
      instance.update(running: false, setup_stage: 0)
      expect(instance.completed?).to be true
    end

    it 'returns true when setup_stage is 3' do
      instance.update(running: true, setup_stage: 3)
      expect(instance.completed?).to be true
    end

    it 'returns false when running and setup_stage < 3' do
      instance.update(running: true, setup_stage: 0)
      expect(instance.completed?).to be false
    end
  end

  describe '#test_run?' do
    it 'returns true when test_run is true' do
      instance.update(test_run: true)
      expect(instance.test_run?).to be true
    end

    it 'returns true when admin_test is true' do
      instance.update(admin_test: true)
      expect(instance.test_run?).to be true
    end

    it 'returns false when both are false' do
      instance.update(test_run: false, admin_test: false)
      expect(instance.test_run?).to be false
    end
  end

  describe '#current_round_number' do
    it 'returns rounds_done + 1' do
      instance.update(rounds_done: 0)
      expect(instance.current_round_number).to eq(1)

      instance.update(rounds_done: 2)
      expect(instance.current_round_number).to eq(3)
    end
  end

  describe '#progress_percentage' do
    it 'returns 0 when total_rounds is 0' do
      allow(instance).to receive(:total_rounds).and_return(0)
      expect(instance.progress_percentage).to eq(0)
    end

    it 'calculates correct percentage' do
      instance.update(rounds_done: 1, rcount: 4)
      expect(instance.progress_percentage).to eq(25)

      instance.update(rounds_done: 2, rcount: 4)
      expect(instance.progress_percentage).to eq(50)
    end
  end

  describe '#current_difficulty' do
    it 'returns base difficulty when no modifiers' do
      instance.update(
        this_enemy: 12,
        random_difficulty: 0,
        char_difficulty: 0,
        inc_difficulty: 0
      )
      expect(instance.current_difficulty).to eq(12)
    end

    it 'adds all modifiers together' do
      instance.update(
        this_enemy: 10,
        random_difficulty: 2,
        char_difficulty: 3,
        inc_difficulty: 1
      )
      expect(instance.current_difficulty).to eq(16)
    end

    it 'defaults to 10 when this_enemy is nil' do
      instance.update(
        this_enemy: nil,
        random_difficulty: 0,
        char_difficulty: 0,
        inc_difficulty: 0
      )
      expect(instance.current_difficulty).to eq(10)
    end
  end

  describe '#difficulty_modifier' do
    it 'returns inc_difficulty' do
      instance.update(inc_difficulty: 5)
      expect(instance.difficulty_modifier).to eq(5)
    end

    it 'returns 0 when inc_difficulty is nil' do
      instance.update(inc_difficulty: nil)
      expect(instance.difficulty_modifier).to eq(0)
    end
  end

  describe '#add_difficulty_modifier!' do
    it 'increases difficulty modifier by specified amount' do
      instance.update(inc_difficulty: 0)
      instance.add_difficulty_modifier!(3)
      expect(instance.refresh.inc_difficulty).to eq(3)
    end

    it 'defaults to adding 1' do
      instance.update(inc_difficulty: 2)
      instance.add_difficulty_modifier!
      expect(instance.refresh.inc_difficulty).to eq(3)
    end
  end

  describe '#team scoring' do
    describe '#team_one_total' do
      it 'returns team_one_score' do
        instance.update(team_one_score: 15)
        expect(instance.team_one_total).to eq(15)
      end

      it 'returns 0 when nil' do
        instance.update(team_one_score: nil)
        expect(instance.team_one_total).to eq(0)
      end
    end

    describe '#team_two_total' do
      it 'returns team_two_score' do
        instance.update(team_two_score: 10)
        expect(instance.team_two_total).to eq(10)
      end

      it 'returns 0 when nil' do
        instance.update(team_two_score: nil)
        expect(instance.team_two_total).to eq(0)
      end
    end

    describe '#leading_team' do
      it 'returns nil when tied' do
        instance.update(team_one_score: 5, team_two_score: 5)
        expect(instance.leading_team).to be_nil
      end

      it 'returns one when team one is ahead' do
        instance.update(team_one_score: 10, team_two_score: 5)
        expect(instance.leading_team).to eq('one')
      end

      it 'returns two when team two is ahead' do
        instance.update(team_one_score: 5, team_two_score: 10)
        expect(instance.leading_team).to eq('two')
      end
    end
  end

  describe '#paused_for_combat?' do
    it 'returns true when paused_for_fight_id is set' do
      instance.update(paused_for_fight_id: 123)
      expect(instance.paused_for_combat?).to be true
    end

    it 'returns false when paused_for_fight_id is nil' do
      instance.update(paused_for_fight_id: nil)
      expect(instance.paused_for_combat?).to be false
    end
  end

  describe '#on_main_branch?' do
    it 'returns true when branch is 0' do
      instance.update(branch: 0)
      expect(instance.on_main_branch?).to be true
    end

    it 'returns false when branch is not 0' do
      instance.update(branch: 1)
      expect(instance.on_main_branch?).to be false
    end
  end

  describe '#reset_participant_choices!' do
    let(:character) { create(:character) }
    let!(:participant) do
      create(
        :activity_participant,
        instance: instance,
        character: character,
        continue: true,
        action_chosen: 12,
        effort_chosen: 'recover',
        risk_chosen: 'high',
        branch_vote: 2,
        voted_continue: true,
        assess_used: true,
        action_count: 3,
        has_emoted: true
      )
    end

    it 'clears per-round state including free-roll action_count' do
      instance.reset_participant_choices!
      participant.refresh

      expect(participant.action_chosen).to be_nil
      expect(participant.effort_chosen).to be_nil
      expect(participant.branch_vote).to be_nil
      expect(participant.voted_continue).to be false
      expect(participant.assess_used).to be false
      expect(participant.action_count).to eq(0)
      expect(participant.has_emoted).to be false
    end
  end

  describe 'post-resolution hold tracking' do
    it 'queues and clears hold timestamps' do
      hold_until = instance.queue_post_resolution_hold!(15)

      expect(hold_until).to be_a(Time)
      expect(instance.refresh.post_resolution_hold_pending?).to be true
      expect(instance.post_resolution_hold_remaining_seconds).to be > 0

      instance.clear_post_resolution_hold!
      expect(instance.refresh.post_resolution_hold_pending?).to be false
      expect(instance.post_resolution_hold_remaining_seconds).to eq(0)
    end

    it 'detects due holds' do
      instance.update(current_round: (Time.now - 5).to_i)

      expect(instance.post_resolution_hold_pending?).to be true
      expect(instance.post_resolution_hold_due?).to be true
      expect(instance.post_resolution_hold_active?).to be false
    end
  end

  describe '#active_aspects' do
    it 'returns empty array when no aspects' do
      expect(instance.active_aspects).to eq([])
    end

    it 'includes active aspects' do
      instance.update(dragon: true, phoenix: true)
      expect(instance.active_aspects).to include(:dragon, :phoenix)
    end
  end

  describe '#has_aspect?' do
    it 'returns true for active aspect' do
      instance.update(dragon: true)
      expect(instance.has_aspect?(:dragon)).to be true
    end

    it 'returns false for inactive aspect' do
      instance.update(dragon: false)
      expect(instance.has_aspect?(:dragon)).to be false
    end
  end

  describe '#status_text' do
    it 'returns Completed when completed' do
      instance.update(running: false, setup_stage: 3)
      expect(instance.status_text).to eq('Completed')
    end

    it 'returns Setting Up during setup' do
      instance.update(running: true, setup_stage: 1)
      expect(instance.status_text).to eq('Setting Up')
    end

    it 'returns Waiting for Input when running with no ready participants' do
      instance.update(running: true, setup_stage: nil)
      # With no participants, all_ready? returns false, so waiting_for_input? is true
      expect(instance.status_text).to eq('Waiting for Input')
    end

    it 'does not report Setting Up once started (setup_stage 2)' do
      instance.update(running: true, setup_stage: 2)
      expect(instance.status_text).not_to eq('Setting Up')
    end
  end

  describe '#complete!' do
    it 'sets running to false' do
      instance.complete!
      expect(instance.refresh.running).to be false
    end

    it 'sets setup_stage to 3' do
      instance.complete!
      expect(instance.refresh.setup_stage).to eq(3)
    end

    it 'does not update activity stats for test runs' do
      instance.update(test_run: true)
      original_wins = activity.wins || 0
      instance.complete!(success: true)
      expect(activity.refresh.wins).to eq(original_wins)
    end

    it 'updates activity wins for successful real runs' do
      instance.update(test_run: false, admin_test: false)
      original_wins = activity.wins || 0
      instance.complete!(success: true)
      expect(activity.refresh.wins).to eq(original_wins + 1)
    end

    it 'updates activity losses for failed real runs' do
      instance.update(test_run: false, admin_test: false)
      original_losses = activity.losses || 0
      instance.complete!(success: false)
      expect(activity.refresh.losses).to eq(original_losses + 1)
    end
  end

  describe '#time_since_last_round' do
    it 'returns nil when last_round is nil' do
      instance.update(last_round: nil)
      expect(instance.time_since_last_round).to be_nil
    end

    it 'returns elapsed time' do
      past_time = Time.now - 60
      instance.update(last_round: past_time)
      expect(instance.time_since_last_round).to be_within(1).of(60)
    end
  end

  describe '#start_round_timer!' do
    it 'sets round_started_at to current time' do
      instance.start_round_timer!
      expect(instance.refresh.round_started_at).to be_within(2).of(Time.now)
    end
  end

  describe '#switch_branch!' do
    it 'updates branch and branch_round_at' do
      instance.update(rounds_done: 5)
      instance.switch_branch!(2)
      instance.refresh

      expect(instance.branch).to eq(2)
      expect(instance.branch_round_at).to eq(5)
    end
  end

  # Skip remote observer tests if the table doesn't exist yet
  if DB.table_exists?(:activity_remote_observers)
    describe 'remote observers' do
      let(:observer_char) { create(:character_instance) }

      describe '#remote_observers' do
        it 'returns associated observers' do
          ActivityRemoteObserver.create(
            activity_instance_id: instance.id,
            character_instance_id: observer_char.id,
            consented_by_id: observer_char.id,
            role: 'support'
          )

          expect(instance.remote_observers.count).to eq(1)
        end

        it 'returns empty array when no observers' do
          expect(instance.remote_observers).to eq([])
        end
      end

      describe '#supporters' do
        it 'returns only active support observers' do
          ActivityRemoteObserver.create(
            activity_instance_id: instance.id,
            character_instance_id: observer_char.id,
            consented_by_id: observer_char.id,
            role: 'support',
            active: true
          )

          expect(instance.supporters.count).to eq(1)
          expect(instance.opposers.count).to eq(0)
        end

        it 'excludes inactive observers' do
          ActivityRemoteObserver.create(
            activity_instance_id: instance.id,
            character_instance_id: observer_char.id,
            consented_by_id: observer_char.id,
            role: 'support',
            active: false
          )

          expect(instance.supporters.count).to eq(0)
        end
      end

      describe '#opposers' do
        it 'returns only active oppose observers' do
          ActivityRemoteObserver.create(
            activity_instance_id: instance.id,
            character_instance_id: observer_char.id,
            consented_by_id: observer_char.id,
            role: 'oppose',
            active: true
          )

          expect(instance.opposers.count).to eq(1)
          expect(instance.supporters.count).to eq(0)
        end
      end

      describe '#remote_observer_for' do
        it 'returns observer for character' do
          ActivityRemoteObserver.create(
            activity_instance_id: instance.id,
            character_instance_id: observer_char.id,
            consented_by_id: observer_char.id,
            role: 'support',
            active: true
          )

          observer = instance.remote_observer_for(observer_char)
          expect(observer).not_to be_nil
          expect(observer.role).to eq('support')
        end

        it 'returns nil when not observing' do
          expect(instance.remote_observer_for(observer_char)).to be_nil
        end

        it 'returns nil for inactive observers' do
          ActivityRemoteObserver.create(
            activity_instance_id: instance.id,
            character_instance_id: observer_char.id,
            consented_by_id: observer_char.id,
            role: 'support',
            active: false
          )

          expect(instance.remote_observer_for(observer_char)).to be_nil
        end
      end

      describe '#has_remote_observer?' do
        it 'returns true when character is observing' do
          ActivityRemoteObserver.create(
            activity_instance_id: instance.id,
            character_instance_id: observer_char.id,
            consented_by_id: observer_char.id,
            role: 'support',
            active: true
          )

          expect(instance.has_remote_observer?(observer_char)).to be true
        end

        it 'returns false when character is not observing' do
          expect(instance.has_remote_observer?(observer_char)).to be false
        end
      end

      describe '#broadcast_to_observers' do
        it 'sends message to all active observers' do
          ActivityRemoteObserver.create(
            activity_instance_id: instance.id,
            character_instance_id: observer_char.id,
            consented_by_id: observer_char.id,
            role: 'support',
            active: true
          )

          expect(BroadcastService).to receive(:to_character).with(
            observer_char,
            { content: 'Test message', html: nil },
            type: :observer_feed
          )

          instance.broadcast_to_observers('Test message')
        end

        it 'sends message with html when provided' do
          ActivityRemoteObserver.create(
            activity_instance_id: instance.id,
            character_instance_id: observer_char.id,
            consented_by_id: observer_char.id,
            role: 'support',
            active: true
          )

          expect(BroadcastService).to receive(:to_character).with(
            observer_char,
            { content: 'Test message', html: '<p>Test</p>' },
            type: :observer_feed
          )

          instance.broadcast_to_observers('Test message', html: '<p>Test</p>')
        end

        it 'does not send to inactive observers' do
          ActivityRemoteObserver.create(
            activity_instance_id: instance.id,
            character_instance_id: observer_char.id,
            consented_by_id: observer_char.id,
            role: 'support',
            active: false
          )

          expect(BroadcastService).not_to receive(:to_character)

          instance.broadcast_to_observers('Test message')
        end
      end

      describe '#clear_observer_actions!' do
        it 'clears all observer actions' do
          observer = ActivityRemoteObserver.create(
            activity_instance_id: instance.id,
            character_instance_id: observer_char.id,
            consented_by_id: observer_char.id,
            role: 'support',
            action_type: 'reroll_ones',
            action_target_id: 123,
            action_secondary_target_id: 456,
            action_message: 'Test message',
            action_submitted_at: Time.now
          )

          instance.clear_observer_actions!
          observer.refresh

          expect(observer.action_type).to be_nil
          expect(observer.action_target_id).to be_nil
          expect(observer.action_secondary_target_id).to be_nil
          expect(observer.action_message).to be_nil
          expect(observer.action_submitted_at).to be_nil
        end

        it 'clears actions for multiple observers' do
          observer1 = ActivityRemoteObserver.create(
            activity_instance_id: instance.id,
            character_instance_id: observer_char.id,
            consented_by_id: observer_char.id,
            role: 'support',
            action_type: 'reroll_ones'
          )

          other_char = create(:character_instance)
          observer2 = ActivityRemoteObserver.create(
            activity_instance_id: instance.id,
            character_instance_id: other_char.id,
            consented_by_id: other_char.id,
            role: 'oppose',
            action_type: 'block_explosions'
          )

          instance.clear_observer_actions!

          expect(observer1.refresh.action_type).to be_nil
          expect(observer2.refresh.action_type).to be_nil
        end
      end
    end
  end
end
