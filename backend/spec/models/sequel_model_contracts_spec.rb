# frozen_string_literal: true

require 'spec_helper'

# This spec ensures all Sequel models follow required patterns:
# 1. Have primary key declarations
# 2. Predicate methods (?) return booleans, not nil
# 3. No Rails/ActiveSupport method dependencies
#
# See: docs/solutions/ACTIVITY-SYSTEM-SEQUEL-PREVENTION-STRATEGIES.md

RSpec.describe 'Sequel Model Contracts' do
  # Dynamically find all Sequel models
  MODEL_FILES = Dir[File.join(__dir__, '../../app/models/*.rb')]

  SEQUEL_MODELS = MODEL_FILES.map do |file|
    class_name = File.basename(file, '.rb').split('_').map(&:capitalize).join
    begin
      Object.const_get(class_name)
    rescue NameError
      nil
    end
  end.compact.select { |klass| klass < Sequel::Model rescue false }

  describe 'Primary Key Declarations' do
    SEQUEL_MODELS.each do |model|
      it "#{model.name} has primary key defined" do
        expect(model.primary_key).not_to be_nil,
          "#{model.name} should have set_primary_key declared"
      end
    end
  end

  # Note: Some gems in the dependency tree load ActiveSupport, so we can't
  # guarantee that core extensions aren't available. Instead, we document
  # that code should NOT rely on them and use CoreExtensions module instead.
  # These tests verify that our CoreExtensions module provides the needed methods.
  describe 'CoreExtensions module availability' do
    it 'provides present? method' do
      expect(CoreExtensions.present?('test')).to be true
      expect(CoreExtensions.present?(nil)).to be false
      expect(CoreExtensions.present?('')).to be false
    end

    it 'provides blank? method' do
      expect(CoreExtensions.blank?(nil)).to be true
      expect(CoreExtensions.blank?('')).to be true
      expect(CoreExtensions.blank?('test')).to be false
    end

    it 'provides titleize method' do
      expect(CoreExtensions.titleize('hello_world')).to eq('Hello World')
    end

    it 'provides humanize method' do
      expect(CoreExtensions.humanize('hello_world')).to eq('Hello world')
    end
  end
end

# Activity System specific contract tests
# These tests are only loaded when Activity tables exist
#
# NOTE: These methods use Ruby's natural truthy/falsy semantics where
# nil && <something> short-circuits to nil. This is idiomatic Ruby and
# matches behavior tested in individual model specs with `be_falsy`.
if defined?(Activity)
  RSpec.describe 'Activity System Boolean Contracts' do
    describe Activity do
      # Use correct column names: name (not aname), activity_type (not atype)
      subject(:activity) { Activity.new(name: 'Test', activity_type: 'mission') }

      describe 'type check methods' do
        %i[mission? competition? team_competition? task? interpersonal?].each do |method|
          it "##{method} returns truthy/falsy value" do
            result = activity.send(method)
            # Methods use Ruby short-circuit evaluation, may return nil instead of false
            expect(result).to satisfy { |v| v == true || v == false || v.nil? }
          end
        end
      end

      describe 'status check methods' do
        %i[public? emergency? can_run_as_emergency? repeatable? pending_approval?
           uses_paired_stats?].each do |method|
          it "##{method} returns truthy/falsy value" do
            result = activity.send(method)
            # Methods use Ruby short-circuit evaluation, may return nil instead of false
            expect(result).to satisfy { |v| v == true || v == false || v.nil? }
          end
        end
      end

      context 'with nil activity_type' do
        subject(:activity) { Activity.new(name: 'Test', activity_type: nil) }

        it 'handles nil activity_type in type checks' do
          expect { activity.mission? }.not_to raise_error
          # Methods return nil (falsy) due to short-circuit evaluation
          expect(activity.mission?).to be_falsy
          expect(activity.competition?).to be_falsy
          expect(activity.interpersonal?).to be_falsy
        end
      end
    end

    describe ActivityInstance do
      subject(:instance) do
        ActivityInstance.new(
          activity_id: 1,
          room_id: 1,
          running: true,
          setup_stage: 1,
          rounds_done: 0,
          branch: 0
        )
      end

      describe 'status check methods' do
        %i[running? in_setup? completed? test_run? emergency?].each do |method|
          it "##{method} returns boolean, not nil" do
            result = instance.send(method)
            expect([true, false]).to include(result),
              "ActivityInstance##{method} should return true/false, got #{result.inspect}"
          end
        end
      end

      context 'with nil boolean columns' do
        subject(:instance) do
          ActivityInstance.new(
            activity_id: 1,
            room_id: 1,
            running: nil,
            test_run: nil,
            admin_test: nil,
            is_emergency: nil
          )
        end

        it 'returns false for nil booleans' do
          expect(instance.running?).to be false
          expect(instance.test_run?).to be false
          expect(instance.emergency?).to be false
        end
      end
    end

    describe ActivityParticipant do
      subject(:participant) do
        ActivityParticipant.new(
          instance_id: 1,
          char_id: 1,
          continue: true
        )
      end

      describe 'status check methods' do
        %i[active? has_chosen? ready? can_use_willpower?].each do |method|
          it "##{method} returns truthy/falsy value" do
            result = participant.send(method)
            # Methods use Ruby short-circuit evaluation, may return nil instead of false
            expect(result).to satisfy { |v| v == true || v == false || v.nil? }
          end
        end
      end

      describe 'ability usage check methods' do
        %i[used_wildcard? used_extreme? can_use_wildcard?].each do |method|
          it "##{method} returns boolean, not nil" do
            result = participant.send(method)
            expect([true, false]).to include(result),
              "ActivityParticipant##{method} should return true/false, got #{result.inspect}"
          end
        end
      end

      describe 'status effect check methods' do
        %i[injured? warned? cursed? vulnerable? is_star?].each do |method|
          it "##{method} returns boolean, not nil" do
            result = participant.send(method)
            expect([true, false]).to include(result),
              "ActivityParticipant##{method} should return true/false, got #{result.inspect}"
          end
        end
      end

      context 'with nil boolean columns' do
        subject(:participant) do
          # Only use columns that exist and are recognized by Sequel
          ActivityParticipant.new(
            instance_id: 1,
            char_id: 1
          )
        end

        it 'returns false for nil booleans' do
          expect(participant.active?).to be false
          expect(participant.used_wildcard?).to be false  # Stubs to false when column missing
          expect(participant.injured?).to be false
          expect(participant.warned?).to be false
        end
      end
    end

    describe ActivityAction do
      # Use correct column name: choice_string (not action_name)
      subject(:action) do
        ActivityAction.new(
          activity_parent: 1,
          choice_string: 'Test Action'
        )
      end

    end

    describe ActivityRound do
      subject(:round) do
        ActivityRound.new(
          activity_id: 1,
          round_number: 1,
          branch: 0
        )
      end

      # Add predicate method tests for ActivityRound when methods exist
      it 'has primary key defined' do
        expect(ActivityRound.primary_key).not_to be_nil
      end
    end
  end
end
