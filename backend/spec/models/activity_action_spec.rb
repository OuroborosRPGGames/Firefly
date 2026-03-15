# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ActivityAction, type: :model do
  let(:activity) { create(:activity) }

  describe 'validations' do
    it 'requires activity_parent' do
      action = ActivityAction.new(choice_string: 'Test')
      expect(action.valid?).to be false
      expect(action.errors[:activity_parent]).not_to be_empty
    end

    it 'requires choice_string' do
      action = ActivityAction.new(activity_parent: activity.id)
      expect(action.valid?).to be false
      expect(action.errors[:choice_string]).not_to be_empty
    end

    it 'is valid with required attributes' do
      action = ActivityAction.new(activity_parent: activity.id, choice_string: 'Test Action')
      expect(action).to be_valid
    end
  end

  describe 'associations' do
    let(:action) { create(:activity_action, activity: activity) }

    describe '#activity' do
      it 'returns the parent activity' do
        expect(action.activity).to eq(activity)
      end
    end
  end

  describe 'text accessors' do
    let(:action) do
      build(:activity_action,
            choice_string: 'Cast Fireball',
            output_string: 'The fireball explodes!',
            fail_string: 'The spell fizzles!')
    end

    describe '#choice_text' do
      it 'returns choice_string' do
        expect(action.choice_text).to eq('Cast Fireball')
      end
    end

    describe '#success_text' do
      it 'returns output_string' do
        expect(action.success_text).to eq('The fireball explodes!')
      end
    end

    describe '#failure_text' do
      it 'returns fail_string' do
        expect(action.failure_text).to eq('The spell fizzles!')
      end
    end
  end

  describe 'skill requirements' do
    describe '#required_skills' do
      it 'returns skills that are set' do
        action = build(:activity_action, skill_one: 1, skill_two: 2, skill_three: nil, skill_four: 0, skill_five: 5)
        skills = action.required_skills
        expect(skills).to include(1)
        expect(skills).to include(2)
        expect(skills).to include(5)
        expect(skills).not_to include(0)
        expect(skills.length).to eq(3)
      end

      it 'returns empty array when no skills' do
        action = build(:activity_action)
        expect(action.required_skills).to be_empty
      end
    end

    describe '#skill_ids' do
      it 'returns skill_list if set' do
        action = build(:activity_action, skill_list: [10, 20, 30])
        expect(action.skill_ids).to eq([10, 20, 30])
      end

      it 'falls back to required_skills' do
        action = build(:activity_action, skill_list: nil, skill_one: 1, skill_two: 2)
        expect(action.skill_ids).to eq([1, 2])
      end
    end

    describe '#skill_count' do
      it 'returns count of skill_ids' do
        action = build(:activity_action, :with_skills)
        expect(action.skill_count).to eq(2)
      end
    end
  end

  describe '#display_name' do
    it 'returns the choice_string' do
      action = build(:activity_action, choice_string: 'Use Shield')
      expect(action.display_name).to eq('Use Shield')
    end
  end

  describe 'stat calculation' do
    # These tests would require more setup with CharacterInstance and Stats
    # For now we test the basic structure

    describe '#stat_values_for' do
      it 'returns empty array when character_instance is nil' do
        action = build(:activity_action)
        expect(action.stat_values_for(nil)).to be_empty
      end
    end

    describe '#stat_bonus_for' do
      it 'returns 0 when no stats available' do
        action = build(:activity_action)
        expect(action.stat_bonus_for(nil)).to eq(0)
      end
    end
  end

  describe 'role filtering' do
    describe '#available_to_role?' do
      context 'with allowed_roles set' do
        let(:action) { build(:activity_action, allowed_roles: 'attacker,defender') }

        it 'returns true for allowed role' do
          expect(action.available_to_role?('attacker')).to be true
          expect(action.available_to_role?('defender')).to be true
        end

        it 'returns false for disallowed role' do
          expect(action.available_to_role?('healer')).to be false
        end

        it 'is case insensitive' do
          expect(action.available_to_role?('ATTACKER')).to be true
          expect(action.available_to_role?('Defender')).to be true
        end

        it 'handles whitespace in allowed_roles' do
          action = build(:activity_action, allowed_roles: ' attacker , defender ')
          expect(action.available_to_role?('attacker')).to be true
        end
      end

      context 'when allowed_roles is nil' do
        let(:action) { build(:activity_action, allowed_roles: nil) }

        it 'returns true for any role' do
          expect(action.available_to_role?('anything')).to be true
          expect(action.available_to_role?('attacker')).to be true
        end
      end

      context 'when allowed_roles is empty string' do
        let(:action) { build(:activity_action, allowed_roles: '') }

        it 'returns true for any role' do
          expect(action.available_to_role?('anything')).to be true
        end
      end

      context 'when participant has no role' do
        let(:action) { build(:activity_action, allowed_roles: 'attacker') }

        it 'returns true for nil role' do
          expect(action.available_to_role?(nil)).to be true
        end

        it 'returns true for empty string role' do
          expect(action.available_to_role?('')).to be true
        end
      end
    end

    describe '#allowed_role_list' do
      it 'returns array of roles' do
        action = build(:activity_action, allowed_roles: 'attacker,defender,healer')
        expect(action.allowed_role_list).to eq(%w[attacker defender healer])
      end

      it 'returns empty array when allowed_roles is nil' do
        action = build(:activity_action, allowed_roles: nil)
        expect(action.allowed_role_list).to eq([])
      end

      it 'strips whitespace from roles' do
        action = build(:activity_action, allowed_roles: ' attacker , defender ')
        expect(action.allowed_role_list).to eq(%w[attacker defender])
      end
    end
  end
end
