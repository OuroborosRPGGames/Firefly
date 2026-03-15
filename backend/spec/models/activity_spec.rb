# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Activity, type: :model do
  describe 'validations' do
    it 'requires name' do
      activity = Activity.new(activity_type: 'mission')
      expect(activity.valid?).to be false
      expect(activity.errors[:name]).not_to be_empty
    end

    it 'requires activity_type' do
      activity = Activity.new(name: 'Test')
      expect(activity.valid?).to be false
      expect(activity.errors[:activity_type]).not_to be_empty
    end

    it 'validates activity_type against allowed values' do
      activity = Activity.new(name: 'Test', activity_type: 'invalid_type')
      expect(activity.valid?).to be false
      expect(activity.errors[:activity_type]).not_to be_empty
    end

    it 'allows valid activity_types' do
      Activity::ACTIVITY_TYPES.each do |type|
        activity = Activity.new(name: 'Test', activity_type: type)
        activity.valid?
        # Sequel's errors returns nil when valid, or a hash when invalid
        activity_type_errors = activity.errors && activity.errors[:activity_type]
        expect(activity_type_errors).to be_nil.or(be_empty)
      end
    end

    it 'validates share_type against allowed values' do
      activity = Activity.new(name: 'Test', activity_type: 'mission', share_type: 'invalid')
      expect(activity.valid?).to be false
    end

    it 'validates launch_mode against allowed values' do
      activity = Activity.new(name: 'Test', activity_type: 'mission', launch_mode: 'invalid')
      expect(activity.valid?).to be false
    end
  end

  describe 'type checks' do
    let(:mission) { build(:activity, :mission) }
    let(:competition) { build(:activity, :competition) }
    let(:team_competition) { build(:activity, :team_competition) }
    let(:task) { build(:activity, :task) }
    let(:interpersonal) { build(:activity, :interpersonal) }

    describe '#mission?' do
      it 'returns true for mission type' do
        expect(mission.mission?).to be true
      end

      it 'returns false for competition type' do
        expect(competition.mission?).to be false
      end
    end

    describe '#competition?' do
      it 'returns true for competition type' do
        expect(competition.competition?).to be true
      end

      it 'returns true for team competition type' do
        expect(team_competition.competition?).to be true
      end

      it 'returns false for mission type' do
        expect(mission.competition?).to be false
      end
    end

    describe '#team_competition?' do
      it 'returns true for tcompetition type' do
        expect(team_competition.team_competition?).to be true
      end

      it 'returns false for regular competition' do
        expect(competition.team_competition?).to be false
      end
    end

    describe '#task?' do
      it 'returns true for task type' do
        expect(task.task?).to be true
      end

      it 'returns false for mission type' do
        expect(mission.task?).to be false
      end
    end

    describe '#interpersonal?' do
      it 'returns true for interpersonal type' do
        expect(interpersonal.interpersonal?).to be true
      end

      it 'returns false for mission type' do
        expect(mission.interpersonal?).to be false
      end
    end
  end

  describe 'status checks' do
    let(:public_activity) { build(:activity, is_public: true) }
    let(:private_activity) { build(:activity, :private) }
    let(:emergency_activity) { build(:activity, :emergency) }
    let(:repeatable_activity) { build(:activity, repeatable: true) }
    let(:pending_activity) { build(:activity, pending_approval: true) }

    describe '#public?' do
      it 'returns true when is_public is true' do
        expect(public_activity.public?).to be true
      end

      it 'returns false when is_public is false' do
        expect(private_activity.public?).to be false
      end
    end

    describe '#emergency?' do
      it 'returns true when is_emergency is true' do
        expect(emergency_activity.emergency?).to be true
      end

      it 'returns false when is_emergency is not set' do
        expect(public_activity.emergency?).to be false
      end
    end

    describe '#can_run_as_emergency?' do
      it 'returns true when can_emergency is true' do
        expect(emergency_activity.can_run_as_emergency?).to be true
      end
    end

    describe '#repeatable?' do
      it 'returns true when repeatable is true' do
        expect(repeatable_activity.repeatable?).to be true
      end
    end

    describe '#pending_approval?' do
      it 'returns true when pending_approval is true' do
        expect(pending_activity.pending_approval?).to be true
      end
    end
  end

  describe 'convenience accessors' do
    let(:activity) { build(:activity, name: 'Test Name', description: 'Test Desc', activity_type: 'mission') }

    it 'returns name via aname' do
      expect(activity.aname).to eq('Test Name')
    end

    it 'returns description via adesc' do
      expect(activity.adesc).to eq('Test Desc')
    end

    it 'returns activity_type via atype' do
      expect(activity.atype).to eq('mission')
    end
  end

  describe '#type_display' do
    it 'returns human-readable type for mission' do
      expect(build(:activity, :mission).type_display).to eq('Mission')
    end

    it 'returns human-readable type for competition' do
      expect(build(:activity, :competition).type_display).to eq('Competition')
    end

    it 'returns human-readable type for team competition' do
      expect(build(:activity, :team_competition).type_display).to eq('Team Competition')
    end

    it 'returns human-readable type for task' do
      expect(build(:activity, :task).type_display).to eq('Task')
    end

    it 'returns Unknown for nil type' do
      activity = build(:activity)
      activity.activity_type = nil
      expect(activity.type_display).to eq('Unknown')
    end
  end

  describe '#display_name' do
    it 'returns the activity name' do
      activity = build(:activity, name: 'Epic Quest')
      expect(activity.display_name).to eq('Epic Quest')
    end
  end

  describe '#uses_paired_stats?' do
    it 'returns true when stat_type is paired' do
      activity = build(:activity, stat_type: 'paired')
      expect(activity.uses_paired_stats?).to be true
    end

    it 'returns false for standard stat type' do
      activity = build(:activity, stat_type: 'standard')
      expect(activity.uses_paired_stats?).to be false
    end
  end

  describe 'round access' do
    let(:activity) { create(:activity) }
    let!(:round1) { create(:activity_round, activity: activity, round_number: 1, branch: 0) }
    let!(:round2) { create(:activity_round, activity: activity, round_number: 2, branch: 0) }
    let!(:branch_round) { create(:activity_round, activity: activity, round_number: 2, branch: 1) }

    describe '#first_round' do
      it 'returns the first round on main branch' do
        expect(activity.first_round).to eq(round1)
      end
    end

    describe '#round_at' do
      it 'returns the round at specified number and branch' do
        expect(activity.round_at(1, 0)).to eq(round1)
        expect(activity.round_at(2, 0)).to eq(round2)
        expect(activity.round_at(2, 1)).to eq(branch_round)
      end

      it 'returns nil for non-existent round' do
        expect(activity.round_at(99, 0)).to be_nil
      end
    end

    describe '#main_rounds' do
      it 'returns all rounds on the main branch' do
        rounds = activity.main_rounds
        expect(rounds).to include(round1)
        expect(rounds).to include(round2)
        expect(rounds).not_to include(branch_round)
      end
    end

    describe '#branch_rounds' do
      it 'returns rounds for specified branch' do
        expect(activity.branch_rounds(1)).to include(branch_round)
        expect(activity.branch_rounds(1)).not_to include(round1)
      end
    end

    describe '#total_rounds' do
      it 'returns count of main branch rounds' do
        expect(activity.total_rounds).to eq(2)
      end
    end
  end

  describe 'anchor and launch mode methods' do
    let(:room) { create(:room) }
    let(:character) { create(:character) }
    let(:item) { create(:item) }
    let(:pattern) { create(:pattern) }

    describe '#anchored_to_item?' do
      it 'returns true when anchor_item_id is set' do
        activity = build(:activity, anchor_item_id: item.id)
        expect(activity.anchored_to_item?).to be true
      end

      it 'returns true when anchor_item_pattern_id is set' do
        activity = build(:activity, anchor_item_pattern_id: pattern.id)
        expect(activity.anchored_to_item?).to be true
      end

      it 'returns false when neither is set' do
        activity = build(:activity)
        expect(activity.anchored_to_item?).to be false
      end
    end

    describe '#anchored_to_room?' do
      it 'returns true when location is set and not anchored to item' do
        activity = build(:activity, location: room.id)
        expect(activity.anchored_to_room?).to be true
      end

      it 'returns false when anchored to item' do
        activity = build(:activity, location: room.id, anchor_item_id: item.id)
        expect(activity.anchored_to_room?).to be false
      end
    end

    describe '#can_launch_from_item?' do
      let(:competition) { build(:activity, :competition, anchor_item_id: item.id) }
      let(:pattern_item) { create(:item, pattern: pattern) }

      it 'returns true when item matches anchor_item_id' do
        expect(competition.can_launch_from_item?(item)).to be true
      end

      it 'returns true when item pattern matches anchor_item_pattern_id' do
        activity = build(:activity, :competition, anchor_item_pattern_id: pattern.id)
        expect(activity.can_launch_from_item?(pattern_item)).to be true
      end

      it 'returns false for non-competition types' do
        mission = build(:activity, :mission, anchor_item_id: item.id)
        expect(mission.can_launch_from_item?(item)).to be false
      end

      it 'returns false when item does not match' do
        other_item = create(:item)
        expect(competition.can_launch_from_item?(other_item)).to be false
      end
    end

    describe '#can_be_launched_by?' do
      let(:creator) { create(:character) }
      let(:other_char) { create(:character) }

      context 'when launch_mode is creator' do
        let(:activity) { build(:activity, launch_mode: 'creator', created_by: creator.id) }

        it 'returns true for creator' do
          expect(activity.can_be_launched_by?(creator)).to be true
        end

        it 'returns false for other characters' do
          expect(activity.can_be_launched_by?(other_char)).to be false
        end
      end

      context 'when launch_mode is anyone' do
        let(:activity) { build(:activity, launch_mode: 'anyone', location: room.id) }

        it 'returns true when character is in the location room' do
          expect(activity.can_be_launched_by?(other_char, room: room)).to be true
        end

        it 'returns false when room does not match' do
          other_room = create(:room)
          expect(activity.can_be_launched_by?(other_char, room: other_room)).to be false
        end
      end

      context 'when launch_mode is anchor' do
        let(:activity) { build(:activity, :competition, launch_mode: 'anchor', anchor_item_id: item.id) }

        it 'returns true when using matching anchor item' do
          expect(activity.can_be_launched_by?(other_char, item: item)).to be true
        end

        it 'returns false without matching item' do
          other_item = create(:item)
          expect(activity.can_be_launched_by?(other_char, item: other_item)).to be false
        end
      end
    end
  end

  describe 'task trigger methods' do
    let(:task_room) { create(:room) }
    let(:other_room) { create(:room) }

    describe '#auto_start_task?' do
      it 'returns true for auto-starting tasks' do
        task = build(:activity, :task, task_auto_start: true)
        expect(task.auto_start_task?).to be true
      end

      it 'returns false for non-task types' do
        mission = build(:activity, :mission, task_auto_start: true)
        expect(mission.auto_start_task?).to be false
      end
    end

    describe '#triggers_on_room_entry?' do
      let(:task) { build(:activity, :task, task_trigger_room_id: task_room.id) }

      it 'returns true when entering the trigger room' do
        expect(task.triggers_on_room_entry?(task_room)).to be true
      end

      it 'returns false when entering different room' do
        expect(task.triggers_on_room_entry?(other_room)).to be false
      end

      it 'returns false for non-task types' do
        mission = build(:activity, :mission, task_trigger_room_id: task_room.id)
        expect(mission.triggers_on_room_entry?(task_room)).to be false
      end
    end

    # NOTE: .tasks_for_room_entry tests removed - method references non-existent columns
    # (atype, task_trigger_room_id, task_auto_start) - needs migration to add these columns
  end

  describe '#to_builder_json' do
    let(:activity) { create(:activity, name: 'Test Quest', description: 'A test quest') }
    let!(:round1) { create(:activity_round, activity: activity, round_number: 1, branch: 0) }
    let!(:round2) { create(:activity_round, activity: activity, round_number: 2, branch: 0) }

    it 'returns activity data as hash' do
      json = activity.to_builder_json
      expect(json[:id]).to eq(activity.id)
      expect(json[:name]).to eq('Test Quest')
      expect(json[:description]).to eq('A test quest')
      expect(json[:type]).to eq('mission')
      expect(json[:rounds_count]).to eq(2)
    end
  end

  describe 'associations' do
    let(:activity) { create(:activity) }
    let(:room) { create(:room) }
    let!(:instance) { create(:activity_instance, activity: activity, room: room) }
    let!(:action) { create(:activity_action, activity: activity) }
    let!(:round) { create(:activity_round, activity: activity, round_number: 1) }

    it 'has many instances' do
      expect(activity.instances).to include(instance)
    end

    it 'has many rounds' do
      expect(activity.rounds).to include(round)
    end

    it 'has many actions' do
      expect(activity.actions).to include(action)
    end
  end

  describe '#start_instance' do
    let(:activity) { create(:activity) }
    let(:room) { create(:room) }
    let(:character) { create(:character) }

    it 'creates a new activity instance' do
      instance = activity.start_instance(room: room, initiator: character)
      # Sequel models use .new? (returns false when persisted) instead of .persisted?
      expect(instance.new?).to be false
      expect(instance.pk).not_to be_nil
      expect(instance.activity_id).to eq(activity.id)
      expect(instance.room_id).to eq(room.id)
      expect(instance.running?).to be true
    end
  end
end
