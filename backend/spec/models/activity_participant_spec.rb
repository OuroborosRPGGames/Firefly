# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ActivityParticipant, type: :model do
  let(:activity) { create(:activity) }
  let(:room) { create(:room) }
  let(:instance) { create(:activity_instance, activity: activity, room: room) }
  let(:character) { create(:character) }

  describe 'validations' do
    it 'requires instance_id' do
      participant = ActivityParticipant.new(char_id: character.id)
      expect(participant.valid?).to be false
      expect(participant.errors[:instance_id]).not_to be_empty
    end

    it 'requires char_id' do
      participant = ActivityParticipant.new(instance_id: instance.id)
      expect(participant.valid?).to be false
      expect(participant.errors[:char_id]).not_to be_empty
    end

    it 'is valid with required attributes' do
      participant = ActivityParticipant.new(instance_id: instance.id, char_id: character.id)
      expect(participant).to be_valid
    end
  end

  describe 'status checks' do
    describe '#active?' do
      it 'returns true when continue is true' do
        participant = build(:activity_participant, continue: true)
        expect(participant.active?).to be true
      end

      it 'returns false when continue is false' do
        participant = build(:activity_participant, :inactive)
        expect(participant.active?).to be false
      end
    end

    describe '#has_chosen?' do
      it 'returns true when action_chosen is set' do
        participant = build(:activity_participant, :with_choice)
        expect(participant.has_chosen?).to be true
      end

      it 'returns true when effort is recover' do
        participant = build(:activity_participant, :recovering)
        expect(participant.has_chosen?).to be true
      end

      it 'returns false when effort is help without a target' do
        participant = build(:activity_participant, :helping)
        expect(participant.has_chosen?).to be false
      end

      it 'returns true when effort is help and a target is set' do
        participant = build(:activity_participant, :helping, action_target: 10)
        expect(participant.has_chosen?).to be true
      end

      it 'returns falsy when no choice made' do
        participant = build(:activity_participant, action_chosen: nil)
        # Returns nil (falsy) due to Ruby short-circuit evaluation
        expect(participant.has_chosen?).to be_falsy
      end
    end

    describe '#ready?' do
      it 'delegates to has_chosen?' do
        participant = build(:activity_participant, :with_choice)
        expect(participant.ready?).to eq(participant.has_chosen?)
      end
    end
  end

  describe 'willpower' do
    let(:participant) { create(:activity_participant, instance: instance, character: character, willpower: 5, willpower_ticks: 3) }

    describe '#available_willpower' do
      it 'returns willpower value' do
        expect(participant.available_willpower).to eq(5)
      end

      it 'returns 0 when nil' do
        participant.willpower = nil
        expect(participant.available_willpower).to eq(0)
      end
    end

    describe '#willpower_ticks_remaining' do
      it 'returns willpower_ticks value' do
        expect(participant.willpower_ticks_remaining).to eq(3)
      end
    end

    describe '#can_use_willpower?' do
      it 'returns true when willpower > 0' do
        expect(participant.can_use_willpower?).to be true
      end

      it 'returns false when willpower is 0' do
        participant.willpower = 0
        expect(participant.can_use_willpower?).to be false
      end
    end

    describe '#use_willpower!' do
      it 'decreases willpower' do
        expect(participant.use_willpower!(2)).to be true
        expect(participant.available_willpower).to eq(3)
      end

      it 'returns false when insufficient willpower' do
        expect(participant.use_willpower!(10)).to be false
        expect(participant.available_willpower).to eq(5)
      end
    end

    describe '#gain_willpower!' do
      it 'increases willpower up to max 10' do
        participant.gain_willpower!(3)
        expect(participant.available_willpower).to eq(8)
      end

      it 'caps at 10' do
        participant.gain_willpower!(20)
        expect(participant.available_willpower).to eq(10)
      end
    end

    describe '#tick_willpower!' do
      it 'gains 1 willpower and decreases ticks' do
        participant.tick_willpower!
        expect(participant.available_willpower).to eq(6)
        expect(participant.willpower_ticks_remaining).to eq(2)
      end

      it 'does nothing when no ticks remaining' do
        participant.willpower_ticks = 0
        participant.tick_willpower!
        expect(participant.available_willpower).to eq(5)
      end
    end
  end

  describe 'risk choices' do
    let(:participant) { build(:activity_participant) }

    describe '#has_risk?' do
      it 'returns true when risk is set' do
        participant.risk_chosen = 'high'
        expect(participant.has_risk?).to be true
      end

      it 'returns falsy when risk is nil' do
        participant.risk_chosen = nil
        # Returns nil (falsy) due to Ruby short-circuit evaluation
        expect(participant.has_risk?).to be_falsy
      end

      it 'returns falsy when risk is empty' do
        participant.risk_chosen = ''
        expect(participant.has_risk?).to be_falsy
      end
    end
  end

  describe 'special ability flags' do
    let(:participant) { build(:activity_participant, done_wildcard: true, done_extreme: false) }

    describe '#used_wildcard?' do
      it 'returns true when done_wildcard is true' do
        expect(participant.used_wildcard?).to be true
      end
    end

    describe '#used_extreme?' do
      it 'returns false when done_extreme is false' do
        expect(participant.used_extreme?).to be false
      end
    end

    describe '#can_use_wildcard?' do
      it 'returns true when not already used' do
        participant.done_wildcard = false
        expect(participant.can_use_wildcard?).to be true
      end

      it 'returns false when already used' do
        expect(participant.can_use_wildcard?).to be false
      end
    end
  end

  describe 'status effects' do
    let(:participant) { build(:activity_participant, injured: true, warned: false, cursed: true, vulnerable: false, is_star: true) }

    describe '#injured?' do
      it 'returns correct value' do
        expect(participant.injured?).to be true
      end
    end

    describe '#warned?' do
      it 'returns correct value' do
        expect(participant.warned?).to be false
      end
    end

    describe '#cursed?' do
      it 'returns correct value' do
        expect(participant.cursed?).to be true
      end
    end

    describe '#vulnerable?' do
      it 'returns correct value' do
        expect(participant.vulnerable?).to be false
      end
    end

    describe '#is_star?' do
      it 'returns correct value' do
        expect(participant.is_star?).to be true
      end
    end
  end

  describe 'season mechanics' do
    let(:participant) { build(:activity_participant, season_taking: 2, season_giving: 3) }

    describe '#taking_bonus' do
      it 'returns season_taking value' do
        expect(participant.taking_bonus).to eq(2)
      end
    end

    describe '#giving_penalty' do
      it 'returns season_giving value' do
        expect(participant.giving_penalty).to eq(3)
      end
    end
  end

  describe 'score' do
    let(:participant) { create(:activity_participant, instance: instance, character: character, score: 5.5) }

    describe '#current_score' do
      it 'returns score value' do
        expect(participant.current_score).to eq(5.5)
      end
    end

    describe '#add_score!' do
      it 'adds to current score' do
        participant.add_score!(2.5)
        expect(participant.current_score).to eq(8.0)
      end
    end
  end

  describe 'roll tracking' do
    let(:participant) { build(:activity_participant, roll_result: 15, expect_roll: 12, effort_bonus: 3) }

    describe '#last_roll' do
      it 'returns roll_result' do
        expect(participant.last_roll).to eq(15)
      end
    end

    describe '#expected_roll' do
      it 'returns expect_roll' do
        expect(participant.expected_roll).to eq(12)
      end
    end

    describe '#roll_bonus' do
      it 'returns effort_bonus' do
        expect(participant.roll_bonus).to eq(3)
      end
    end
  end

  describe 'team' do
    let(:instance) { create(:activity_instance, activity: activity, room: room, team_name_one: 'Red Team', team_name_two: 'Blue Team') }
    let(:participant) { build(:activity_participant, instance: instance, team: 'one') }

    describe '#on_team?' do
      it 'returns true when on specified team' do
        expect(participant.on_team?('one')).to be true
      end

      it 'returns false when not on specified team' do
        expect(participant.on_team?('two')).to be false
      end
    end

    describe '#team_name' do
      it 'returns team name for team one' do
        expect(participant.team_name).to eq('Red Team')
      end

      it 'returns team name for team two' do
        participant.team = 'two'
        expect(participant.team_name).to eq('Blue Team')
      end

      it 'returns nil when no team' do
        participant.team = nil
        expect(participant.team_name).to be_nil
      end
    end
  end

  describe 'choice submission' do
    let(:participant) { create(:activity_participant, instance: instance, character: character) }

    describe '#submit_choice!' do
      it 'sets choice fields' do
        participant.submit_choice!(action_id: 5, risk: 'high', target_id: 10, willpower: 2)
        expect(participant.action_chosen).to eq(5)
        expect(participant.risk_chosen).to eq('high')
        expect(participant.action_target).to eq(10)
        expect(participant.willpower_to_spend).to eq(2)
        expect(participant.chosen_when).not_to be_nil
      end
    end

    describe '#clear_choice!' do
      let(:participant) { create(:activity_participant, :with_choice, instance: instance, character: character) }

      it 'clears all choice fields' do
        participant.clear_choice!
        expect(participant.action_chosen).to be_nil
        expect(participant.effort_chosen).to be_nil
        expect(participant.risk_chosen).to be_nil
        expect(participant.willpower_to_spend).to eq(0)
        expect(participant.roll_result).to be_nil
        expect(participant.chosen_when).to be_nil
      end
    end
  end

  describe 'favored skill tracking' do
    let(:participant) { create(:activity_participant, instance: instance, character: character, used_favored: false) }

    describe '#used_favored?' do
      it 'returns false initially' do
        expect(participant.used_favored?).to be false
      end
    end

    describe '#mark_favored_used!' do
      it 'sets used_favored to true' do
        participant.mark_favored_used!
        expect(participant.used_favored?).to be true
      end
    end
  end

  describe 'branch voting' do
    let(:participant) { create(:activity_participant, instance: instance, character: character, branch_vote: nil) }

    describe '#vote_for_branch!' do
      it 'sets branch vote' do
        participant.vote_for_branch!(2)
        expect(participant.branch_vote).to eq(2)
      end
    end

    describe '#has_voted_branch?' do
      it 'returns false when not voted' do
        expect(participant.has_voted_branch?).to be false
      end

      it 'returns true when voted' do
        participant.vote_for_branch!(1)
        expect(participant.has_voted_branch?).to be true
      end
    end
  end

  describe 'rest round voting' do
    let(:participant) { create(:activity_participant, instance: instance, character: character, voted_continue: false) }

    describe '#voted_continue?' do
      it 'returns false initially' do
        expect(participant.voted_continue?).to be false
      end
    end

    describe '#vote_to_continue!' do
      it 'sets voted_continue to true' do
        participant.vote_to_continue!
        expect(participant.voted_continue?).to be true
      end
    end
  end

  describe 'free roll round' do
    let(:participant) { create(:activity_participant, instance: instance, character: character, assess_used: false, action_count: 2) }

    describe '#assess_used?' do
      it 'returns false initially' do
        expect(participant.assess_used?).to be false
      end
    end

    describe '#use_assess!' do
      it 'sets assess_used to true' do
        participant.use_assess!
        expect(participant.assess_used?).to be true
      end
    end

    describe '#reset_assess!' do
      it 'sets assess_used to false' do
        participant.assess_used = true
        participant.reset_assess!
        expect(participant.assess_used?).to be false
      end
    end

    describe '#increment_action_count!' do
      it 'increases action count' do
        participant.increment_action_count!
        expect(participant.total_actions).to eq(3)
      end
    end

    describe '#total_actions' do
      it 'returns action_count' do
        expect(participant.total_actions).to eq(2)
      end
    end
  end

  describe 'help mechanics' do
    let(:helper) { create(:activity_participant, instance: instance, character: create(:character), effort_chosen: 'help') }
    let(:participant) { create(:activity_participant, instance: instance, character: character) }

    describe '#helping?' do
      it 'returns true when effort is help and target set' do
        helper.action_target = participant.id
        expect(helper.helping?).to be true
      end

      it 'returns false when no target' do
        expect(helper.helping?).to be false
      end
    end

    describe '#being_helped_by' do
      it 'returns helpers targeting this participant' do
        helper.update(action_target: participant.id)
        expect(participant.being_helped_by).to include(helper)
      end
    end

    describe '#helper_count' do
      it 'returns number of helpers' do
        helper.update(action_target: participant.id)
        expect(participant.helper_count).to eq(1)
      end
    end

    describe '#has_advantage?' do
      it 'returns true when has helpers' do
        helper.update(action_target: participant.id)
        expect(participant.has_advantage?).to be true
      end

      it 'returns false when no helpers' do
        expect(participant.has_advantage?).to be false
      end
    end

    describe '#recovering?' do
      it 'returns true when effort is recover' do
        participant.effort_chosen = 'recover'
        expect(participant.recovering?).to be true
      end

      it 'returns false otherwise' do
        expect(participant.recovering?).to be false
      end
    end
  end

  describe '#display_name' do
    it 'returns character name' do
      participant = build(:activity_participant, character: character)
      expect(participant.display_name).to eq(character.full_name)
    end
  end

  describe '#status_text' do
    let(:participant) { build(:activity_participant, continue: true) }

    it 'returns Inactive when not active' do
      participant.continue = false
      expect(participant.status_text).to eq('Inactive')
    end

    it 'returns Ready when has chosen' do
      participant.action_chosen = 1
      expect(participant.status_text).to eq('Ready')
    end

    it 'returns Choosing when active but not chosen' do
      participant.action_chosen = nil
      expect(participant.status_text).to eq('Choosing')
    end
  end
end
