# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ActivityRound, type: :model do
  let(:activity) { create(:activity) }

  describe 'validations' do
    it 'requires activity_id' do
      round = ActivityRound.new(round_number: 1)
      expect(round.valid?).to be false
      expect(round.errors[:activity_id]).not_to be_empty
    end

    it 'requires round_number' do
      round = ActivityRound.new(activity_id: activity.id)
      expect(round.valid?).to be false
      expect(round.errors[:round_number]).not_to be_empty
    end

    it 'validates rtype against allowed values' do
      round = ActivityRound.new(activity_id: activity.id, round_number: 1, rtype: 'invalid')
      expect(round.valid?).to be false
      expect(round.errors[:rtype]).not_to be_empty
    end

    it 'allows valid round types' do
      ActivityRound::ROUND_TYPES.each do |type|
        round = ActivityRound.new(activity_id: activity.id, round_number: 1, rtype: type)
        round.valid?
        # Sequel's errors returns nil when valid, not an empty hash
        rtype_errors = round.errors && round.errors[:rtype]
        expect(rtype_errors).to be_nil.or(be_empty)
      end
    end
  end

  describe 'type checks' do
    describe '#standard?' do
      it 'returns true for standard type' do
        round = build(:activity_round, :standard)
        expect(round.standard?).to be true
      end

      it 'returns true for nil type' do
        round = build(:activity_round, rtype: nil)
        expect(round.standard?).to be true
      end
    end

    describe '#reflex?' do
      it 'returns true for reflex type' do
        round = build(:activity_round, :reflex)
        expect(round.reflex?).to be true
      end
    end

    describe '#group_check?' do
      it 'returns true for group_check type' do
        round = build(:activity_round, :group_check)
        expect(round.group_check?).to be true
      end
    end

    describe '#combat?' do
      it 'returns true for combat type' do
        round = build(:activity_round, :combat)
        expect(round.combat?).to be true
      end
    end

    describe '#free_roll?' do
      it 'returns true for free_roll type' do
        round = build(:activity_round, :free_roll)
        expect(round.free_roll?).to be true
      end
    end

    describe '#persuade?' do
      it 'returns true for persuade type' do
        round = build(:activity_round, :persuade)
        expect(round.persuade?).to be true
      end
    end

    describe '#rest?' do
      it 'returns true for rest type' do
        round = build(:activity_round, :rest)
        expect(round.rest?).to be true
      end
    end

    describe '#branch?' do
      it 'returns true for branch type' do
        round = build(:activity_round, :branch)
        expect(round.branch?).to be true
      end
    end

    describe '#break?' do
      it 'returns true for break type' do
        round = build(:activity_round, rtype: 'break')
        expect(round.break?).to be true
      end
    end

    describe '#llm_based?' do
      it 'returns true for free_roll' do
        round = build(:activity_round, :free_roll)
        expect(round.llm_based?).to be true
      end

      it 'returns true for persuade' do
        round = build(:activity_round, :persuade)
        expect(round.llm_based?).to be true
      end

      it 'returns false for standard' do
        round = build(:activity_round, :standard)
        expect(round.llm_based?).to be false
      end
    end

    describe '#mandatory_roll?' do
      it 'returns true for reflex' do
        round = build(:activity_round, :reflex)
        expect(round.mandatory_roll?).to be true
      end

      it 'returns true for group_check' do
        round = build(:activity_round, :group_check)
        expect(round.mandatory_roll?).to be true
      end

      it 'returns false for standard' do
        round = build(:activity_round, :standard)
        expect(round.mandatory_roll?).to be false
      end
    end

    describe '#no_roll?' do
      it 'returns true for branch' do
        round = build(:activity_round, :branch)
        expect(round.no_roll?).to be true
      end

      it 'returns true for rest' do
        round = build(:activity_round, :rest)
        expect(round.no_roll?).to be true
      end

      it 'returns false for standard' do
        round = build(:activity_round, :standard)
        expect(round.no_roll?).to be false
      end
    end
  end

  describe 'text accessors' do
    let(:round) { build(:activity_round, emit: 'Begin!', succ_text: 'Victory!', fail_text: 'Defeat!', fail_con: 'difficulty') }

    it '#emit_text returns emit' do
      expect(round.emit_text).to eq('Begin!')
    end

    it '#success_text returns succ_text' do
      expect(round.success_text).to eq('Victory!')
    end

    it '#failure_text returns fail_text' do
      expect(round.failure_text).to eq('Defeat!')
    end

    it '#failure_consequence returns fail_con' do
      expect(round.failure_consequence).to eq('difficulty')
    end
  end

  describe 'failure configuration' do
    describe '#can_fail_repeat?' do
      it 'returns true when fail_repeat is true' do
        round = build(:activity_round, :can_repeat)
        expect(round.can_fail_repeat?).to be true
      end
    end

    describe '#reverts_to_main?' do
      it 'returns true when revert_main is true' do
        round = build(:activity_round, revert_main: true)
        expect(round.reverts_to_main?).to be true
      end
    end

    describe '#can_knockout?' do
      it 'returns true when knockout is true' do
        round = build(:activity_round, :knockout)
        expect(round.can_knockout?).to be true
      end
    end

    describe '#single_solution?' do
      it 'returns true when single_solution is true' do
        round = build(:activity_round, single_solution: true)
        expect(round.single_solution?).to be true
      end
    end

    describe '#group_actions?' do
      it 'returns true when group_actions is true' do
        round = build(:activity_round, group_actions: true)
        expect(round.group_actions?).to be true
      end
    end
  end

  describe 'timeout' do
    describe '#round_timeout' do
      it 'returns custom timeout when set' do
        round = build(:activity_round, timeout_seconds: 300)
        expect(round.round_timeout).to eq(300)
      end

      it 'returns reflex timeout for reflex rounds' do
        round = build(:activity_round, :reflex)
        expect(round.round_timeout).to eq(ActivityRound::REFLEX_TIMEOUT)
      end

      it 'returns default timeout for standard rounds' do
        round = build(:activity_round, :standard)
        expect(round.round_timeout).to eq(ActivityRound::DEFAULT_TIMEOUT)
      end
    end
  end

  describe '#available_actions' do
    it 'preserves the order configured in the round actions array' do
      action_one = create(:activity_action, activity: activity, choice_string: 'First')
      action_two = create(:activity_action, activity: activity, choice_string: 'Second')
      action_three = create(:activity_action, activity: activity, choice_string: 'Third')

      round = create(
        :activity_round,
        activity: activity,
        actions: Sequel.pg_array([action_three.id, action_one.id, action_two.id], :integer)
      )

      expect(round.available_actions.map(&:id)).to eq([action_three.id, action_one.id, action_two.id])
    end
  end

  describe 'round navigation' do
    let!(:round1) { create(:activity_round, activity: activity, round_number: 1, branch: 0) }
    let!(:round2) { create(:activity_round, activity: activity, round_number: 2, branch: 0) }
    let!(:round3) { create(:activity_round, activity: activity, round_number: 3, branch: 0) }

    describe '#next_round' do
      it 'returns the next round' do
        expect(round1.next_round).to eq(round2)
        expect(round2.next_round).to eq(round3)
      end

      it 'returns nil for last round' do
        expect(round3.next_round).to be_nil
      end
    end

    describe '#previous_round' do
      it 'returns the previous round' do
        expect(round3.previous_round).to eq(round2)
        expect(round2.previous_round).to eq(round1)
      end

      it 'returns nil for first round' do
        expect(round1.previous_round).to be_nil
      end
    end
  end

  describe '#display_name' do
    it 'returns round number' do
      round = build(:activity_round, round_number: 3, branch: 0)
      expect(round.display_name).to eq('Round 3')
    end

    it 'includes branch info' do
      round = build(:activity_round, round_number: 3, branch: 2)
      expect(round.display_name).to eq('Round 3 (Branch 2)')
    end
  end

  describe 'branch configuration' do
    let(:target_round) { create(:activity_round, activity: activity, round_number: 5, branch: 1) }
    let(:round) { build(:activity_round, :branch, activity: activity, branch_to: target_round.id) }

    describe '#branch_target' do
      it 'returns the target round' do
        expect(round.branch_target).to eq(target_round)
      end

      it 'returns nil when no target' do
        round.branch_to = nil
        expect(round.branch_target).to be_nil
      end
    end

    describe '#branch_choices' do
      it 'returns branch choices' do
        choices = round.branch_choices
        expect(choices.length).to eq(2)
        expect(choices[0][:text]).to eq('Take the left path')
        expect(choices[1][:text]).to eq('Take the right path')
      end

      it 'returns empty for non-branch rounds' do
        standard = build(:activity_round, :standard)
        expect(standard.branch_choices).to be_empty
      end
    end

    describe '#expanded_branch_choices' do
      it 'returns branch choices with full info' do
        choices = round.expanded_branch_choices
        expect(choices[0][:text]).to eq('Take the left path')
        expect(choices[0][:branch_to_round_id]).to eq(target_round.id)
      end
    end
  end

  describe 'failure consequence methods' do
    describe '#fail_consequence_type' do
      it 'returns fail_con value' do
        round = build(:activity_round, fail_con: 'injury')
        expect(round.fail_consequence_type).to eq('injury')
      end

      it 'defaults to none' do
        round = build(:activity_round, fail_con: nil)
        expect(round.fail_consequence_type).to eq('none')
      end
    end

    describe '#applies_difficulty_penalty?' do
      it 'returns true for difficulty consequence' do
        round = build(:activity_round, fail_con: 'difficulty')
        expect(round.applies_difficulty_penalty?).to be true
      end
    end

    describe '#applies_injury?' do
      it 'returns true for injury consequence' do
        round = build(:activity_round, fail_con: 'injury')
        expect(round.applies_injury?).to be true
      end
    end

    describe '#makes_finale_harder?' do
      it 'returns true for harder_finale consequence' do
        round = build(:activity_round, fail_con: 'harder_finale')
        expect(round.makes_finale_harder?).to be true
      end
    end

    describe '#branches_on_failure?' do
      it 'returns true for branch consequence with target' do
        target = create(:activity_round, activity: activity, round_number: 10, branch: 1)
        round = build(:activity_round, fail_con: 'branch', fail_branch_to: target.id)
        expect(round.branches_on_failure?).to be true
      end

      it 'returns false without target' do
        round = build(:activity_round, fail_con: 'branch', fail_branch_to: nil)
        expect(round.branches_on_failure?).to be false
      end
    end
  end

  describe 'stat bonuses' do
    let(:round) do
      build(:activity_round, activity: activity,
            sboneone: 1, sbonetwo: 2, sbonethree: 3,
            sbtwoone: 4, sbtwotwo: 5, sbtwothree: 6)
    end

    describe '#stat_bonus_for' do
      it 'returns correct bonus for role and stat' do
        expect(round.stat_bonus_for(1, 1)).to eq(1)
        expect(round.stat_bonus_for(1, 2)).to eq(2)
        expect(round.stat_bonus_for(1, 3)).to eq(3)
        expect(round.stat_bonus_for(2, 1)).to eq(4)
        expect(round.stat_bonus_for(2, 2)).to eq(5)
        expect(round.stat_bonus_for(2, 3)).to eq(6)
      end

      it 'returns 0 for invalid indices' do
        expect(round.stat_bonus_for(0, 1)).to eq(0)
        expect(round.stat_bonus_for(5, 1)).to eq(0)
        expect(round.stat_bonus_for(1, 0)).to eq(0)
        expect(round.stat_bonus_for(1, 4)).to eq(0)
      end
    end
  end

  describe 'persuade configuration' do
    let(:round) { build(:activity_round, :persuade) }

    describe '#persuade_dc' do
      it 'returns base DC' do
        expect(round.persuade_dc).to eq(15)
      end

      it 'adds modifier' do
        expect(round.persuade_dc(5)).to eq(20)
      end
    end
  end

  describe 'combat configuration' do
    let(:round) { build(:activity_round, :combat, combat_difficulty: 'hard') }

    describe '#combat_difficulty_level' do
      it 'returns combat difficulty' do
        expect(round.combat_difficulty_level).to eq('hard')
      end

      it 'defaults to normal' do
        round.combat_difficulty = nil
        expect(round.combat_difficulty_level).to eq('normal')
      end
    end

    describe '#finale_battle?' do
      it 'returns true when finale' do
        round = build(:activity_round, :finale)
        expect(round.finale_battle?).to be true
      end
    end
  end

  describe 'room configuration' do
    let(:custom_room) { create(:room) }
    let(:activity_room) { create(:room) }
    let(:activity_with_room) { create(:activity, location: activity_room.id) }

    describe '#effective_room' do
      it 'returns round room when set and not using activity room' do
        round = build(:activity_round, activity: activity_with_room, round_room_id: custom_room.id, use_activity_room: false)
        expect(round.effective_room).to eq(custom_room)
      end

      it 'returns activity location when using activity room' do
        round = build(:activity_round, activity: activity_with_room, use_activity_room: true)
        expect(round.effective_room).to eq(activity_room)
      end
    end

    describe '#has_custom_room?' do
      it 'returns true when round has custom room' do
        round = build(:activity_round, round_room_id: custom_room.id, use_activity_room: false)
        expect(round.has_custom_room?).to be true
      end

      it 'returns false when using activity room' do
        round = build(:activity_round, round_room_id: custom_room.id, use_activity_room: true)
        expect(round.has_custom_room?).to be false
      end
    end
  end

  describe 'media configuration' do
    describe '#has_media?' do
      it 'returns true when media_url is set' do
        round = build(:activity_round, :with_media)
        expect(round.has_media?).to be true
      end

      it 'returns false when no media' do
        round = build(:activity_round)
        expect(round.has_media?).to be false
      end
    end

    describe '#youtube?' do
      it 'returns true for youtube media type' do
        round = build(:activity_round, media_type: 'youtube')
        expect(round.youtube?).to be true
      end

      it 'detects youtube URLs' do
        round = build(:activity_round, media_url: 'https://www.youtube.com/watch?v=abc123')
        expect(round.youtube?).to be true
      end
    end

    describe '#audio?' do
      it 'returns true for audio media type' do
        round = build(:activity_round, media_type: 'audio')
        expect(round.audio?).to be true
      end

      it 'detects audio URLs' do
        round = build(:activity_round, media_url: 'https://example.com/song.mp3')
        expect(round.audio?).to be true
      end
    end

    describe '#youtube_embed_url' do
      it 'generates embed URL from watch URL' do
        round = build(:activity_round, media_url: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ')
        expect(round.youtube_embed_url).to eq('https://www.youtube.com/embed/dQw4w9WgXcQ?autoplay=1')
      end

      it 'generates embed URL from short URL' do
        round = build(:activity_round, media_url: 'https://youtu.be/dQw4w9WgXcQ')
        expect(round.youtube_embed_url).to eq('https://www.youtube.com/embed/dQw4w9WgXcQ?autoplay=1')
      end

      it 'returns nil for non-youtube' do
        round = build(:activity_round, media_url: 'https://example.com/video.mp4')
        expect(round.youtube_embed_url).to be_nil
      end
    end

    describe 'media duration modes' do
      it '#media_stops_on_round_end? returns true for round mode' do
        round = build(:activity_round, media_duration_mode: 'round')
        expect(round.media_stops_on_round_end?).to be true
      end

      it '#media_continues_to_activity_end? returns true for activity mode' do
        round = build(:activity_round, media_duration_mode: 'activity')
        expect(round.media_continues_to_activity_end?).to be true
      end

      it '#media_continues_until_replaced? returns true for until_replaced mode' do
        round = build(:activity_round, media_duration_mode: 'until_replaced')
        expect(round.media_continues_until_replaced?).to be true
      end
    end
  end

  describe 'canvas positioning' do
    let(:round) { build(:activity_round, canvas_x: 100, canvas_y: 200) }

    describe '#canvas_position' do
      it 'returns position as hash' do
        expect(round.canvas_position).to eq({ x: 100, y: 200 })
      end
    end

    describe '#set_canvas_position' do
      it 'sets position' do
        round.set_canvas_position(150, 250)
        expect(round.canvas_x).to eq(150)
        expect(round.canvas_y).to eq(250)
      end
    end
  end

  describe '#to_builder_json' do
    let(:round) { create(:activity_round, activity: activity, round_number: 1, rtype: 'combat') }

    it 'returns round data as hash' do
      json = round.to_builder_json
      expect(json[:id]).to eq(round.id)
      expect(json[:activity_id]).to eq(activity.id)
      expect(json[:round_number]).to eq(1)
      expect(json[:round_type]).to eq('combat')
      expect(json[:is_combat]).to be true
    end
  end

  describe '#to_node_json' do
    let(:round) { create(:activity_round, activity: activity, round_number: 2, canvas_x: 50, canvas_y: 75) }

    it 'returns compact node data' do
      json = round.to_node_json
      expect(json[:id]).to eq(round.id)
      expect(json[:round_number]).to eq(2)
      expect(json[:canvas_x]).to eq(50)
      expect(json[:canvas_y]).to eq(75)
    end
  end
end
