# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ScheduledTask do
  describe 'validations' do
    it 'requires name' do
      task = described_class.new(task_type: 'cron')
      expect(task.valid?).to be false
      expect(task.errors[:name]).to include('is not present')
    end

    it 'requires task_type' do
      task = described_class.new(name: 'test_task')
      expect(task.valid?).to be false
      expect(task.errors[:task_type]).to include('is not present')
    end

    it 'requires unique name' do
      described_class.create(name: 'unique_task', task_type: 'cron')
      duplicate = described_class.new(name: 'unique_task', task_type: 'cron')
      expect(duplicate.valid?).to be false
      expect(duplicate.errors[:name]).to include('is already taken')
    end

    it 'validates task_type is one of cron, interval, tick' do
      task = described_class.new(name: 'test', task_type: 'invalid')
      expect(task.valid?).to be false
      expect(task.errors[:task_type]).not_to be_empty
    end

    it 'accepts cron task_type' do
      task = described_class.new(name: 'cron_task', task_type: 'cron')
      expect(task.valid?).to be true
    end

    it 'accepts interval task_type' do
      task = described_class.new(name: 'interval_task', task_type: 'interval')
      expect(task.valid?).to be true
    end

    it 'accepts tick task_type' do
      task = described_class.new(name: 'tick_task', task_type: 'tick')
      expect(task.valid?).to be true
    end
  end

  describe '#before_save' do
    it 'converts cron_minutes array to pg_array' do
      task = described_class.create(name: 'cron_test', task_type: 'cron', cron_minutes: [0, 15, 30, 45])
      task.reload
      expect(task.cron_minutes.to_a).to eq([0, 15, 30, 45])
    end

    it 'converts cron_hours array to pg_array' do
      task = described_class.create(name: 'cron_hours_test', task_type: 'cron', cron_hours: [0, 12])
      task.reload
      expect(task.cron_hours.to_a).to eq([0, 12])
    end

    it 'converts cron_days array to pg_array' do
      task = described_class.create(name: 'cron_days_test', task_type: 'cron', cron_days: [1, 15])
      task.reload
      expect(task.cron_days.to_a).to eq([1, 15])
    end

    it 'converts cron_weekdays array to pg_array' do
      task = described_class.create(name: 'cron_weekdays_test', task_type: 'cron', cron_weekdays: [0, 6])
      task.reload
      expect(task.cron_weekdays.to_a).to eq([0, 6])
    end
  end

  describe '#should_run?' do
    context 'when disabled' do
      it 'returns false' do
        task = described_class.create(name: 'disabled_task', task_type: 'cron', enabled: false)
        expect(task.should_run?).to be false
      end
    end

    context 'when enabled cron task' do
      it 'returns true when next_run_at is in the past' do
        task = described_class.create(
          name: 'past_cron',
          task_type: 'cron',
          enabled: true,
          next_run_at: Time.now - 3600
        )
        expect(task.should_run?).to be true
      end

      it 'returns false when next_run_at is in the future' do
        task = described_class.create(
          name: 'future_cron',
          task_type: 'cron',
          enabled: true,
          next_run_at: Time.now + 3600
        )
        expect(task.should_run?).to be false
      end

      it 'returns false when next_run_at is nil' do
        task = described_class.create(
          name: 'nil_next_run',
          task_type: 'cron',
          enabled: true,
          next_run_at: nil
        )
        expect(task.should_run?).to be false
      end
    end

    context 'when enabled interval task' do
      it 'returns true when never run' do
        task = described_class.create(
          name: 'never_run',
          task_type: 'interval',
          enabled: true,
          interval_seconds: 60,
          last_run_at: nil
        )
        expect(task.should_run?).to be true
      end

      it 'returns true when interval has passed' do
        task = described_class.create(
          name: 'interval_passed',
          task_type: 'interval',
          enabled: true,
          interval_seconds: 60,
          last_run_at: Time.now - 120
        )
        expect(task.should_run?).to be true
      end

      it 'returns false when interval has not passed' do
        task = described_class.create(
          name: 'interval_not_passed',
          task_type: 'interval',
          enabled: true,
          interval_seconds: 60,
          last_run_at: Time.now - 30
        )
        expect(task.should_run?).to be false
      end

      it 'returns false when interval_seconds is nil' do
        task = described_class.create(
          name: 'no_interval',
          task_type: 'interval',
          enabled: true,
          interval_seconds: nil,
          last_run_at: Time.now - 3600
        )
        expect(task.should_run?).to be false
      end
    end

    context 'when enabled tick task' do
      it 'returns true' do
        task = described_class.create(
          name: 'tick_task',
          task_type: 'tick',
          enabled: true,
          tick_interval: 5
        )
        expect(task.should_run?).to be true
      end
    end

    context 'with invalid task_type' do
      it 'returns false' do
        task = described_class.create(name: 'valid_type', task_type: 'cron', enabled: true)
        task.values[:task_type] = 'invalid' # Bypass validation
        expect(task.should_run?).to be false
      end
    end
  end

  describe '#execute!' do
    let(:task) do
      described_class.create(
        name: 'executable_task',
        task_type: 'interval',
        enabled: true,
        interval_seconds: 60,
        handler_class: 'TestHandler'
      )
    end

    context 'when should not run' do
      it 'returns false' do
        allow(task).to receive(:should_run?).and_return(false)
        expect(task.execute!).to be false
      end
    end

    context 'when handler is not found' do
      it 'returns false' do
        allow(task).to receive(:should_run?).and_return(true)
        allow($stderr).to receive(:puts)
        expect(task.execute!).to be false
      end
    end

    context 'when handler raises error' do
      before do
        stub_const('TestHandler', Class.new do
          def self.call(_task)
            raise StandardError, 'Handler error'
          end
        end)
      end

      it 'returns false' do
        allow(task).to receive(:should_run?).and_return(true)
        expect(task.execute!).to be false
      end

      it 'records the error' do
        allow(task).to receive(:should_run?).and_return(true)
        task.execute!
        task.reload
        expect(task.error_count).to eq(1)
        expect(task.last_error).to include('Handler error')
      end
    end

    context 'when handler executes successfully' do
      before do
        stub_const('TestHandler', Class.new do
          def self.call(_task)
            # Success
          end
        end)
      end

      it 'returns true' do
        allow(task).to receive(:should_run?).and_return(true)
        expect(task.execute!).to be true
      end

      it 'records success' do
        allow(task).to receive(:should_run?).and_return(true)
        task.execute!
        task.reload
        expect(task.run_count).to eq(1)
        expect(task.last_run_at).not_to be_nil
      end
    end
  end

  describe '#record_success!' do
    let(:task) do
      described_class.create(
        name: 'success_task',
        task_type: 'interval',
        enabled: true,
        interval_seconds: 60,
        run_count: 5
      )
    end

    it 'updates last_run_at' do
      expect { task.record_success! }.to change { task.reload.last_run_at }
    end

    it 'increments run_count' do
      expect { task.record_success! }.to change { task.reload.run_count }.by(1)
    end

    it 'calculates next_run_at' do
      task.record_success!
      task.reload
      expect(task.next_run_at).to be_within(5).of(Time.now + 60)
    end
  end

  describe '#record_error!' do
    let(:task) do
      described_class.create(
        name: 'error_task',
        task_type: 'cron',
        enabled: true,
        error_count: 2
      )
    end
    let(:error) { StandardError.new('Test error message') }

    it 'updates last_run_at' do
      expect { task.record_error!(error) }.to change { task.reload.last_run_at }
    end

    it 'increments error_count' do
      expect { task.record_error!(error) }.to change { task.reload.error_count }.by(1)
    end

    it 'records last_error with class and message' do
      task.record_error!(error)
      task.reload
      expect(task.last_error).to eq('StandardError: Test error message')
    end
  end

  describe '#calculate_next_run' do
    context 'for cron task' do
      it 'uses Firefly::Cron.next_occurrence' do
        task = described_class.new(task_type: 'cron', cron_minutes: [0])
        allow(Firefly::Cron).to receive(:next_occurrence).and_return(Time.now + 3600)
        expect(task.calculate_next_run).to be_within(5).of(Time.now + 3600)
      end
    end

    context 'for interval task' do
      it 'returns time plus interval_seconds' do
        task = described_class.new(task_type: 'interval', interval_seconds: 120)
        expect(task.calculate_next_run).to be_within(5).of(Time.now + 120)
      end
    end

    context 'for tick task' do
      it 'returns nil' do
        task = described_class.new(task_type: 'tick')
        expect(task.calculate_next_run).to be_nil
      end
    end
  end

  describe '#cron_spec' do
    it 'returns hash with cron arrays converted to arrays' do
      task = described_class.create(
        name: 'cron_spec_test',
        task_type: 'cron',
        cron_minutes: [0, 30],
        cron_hours: [9, 17],
        cron_days: [1],
        cron_weekdays: [1, 2, 3, 4, 5]
      )
      spec = task.cron_spec
      expect(spec[:minutes]).to eq([0, 30])
      expect(spec[:hours]).to eq([9, 17])
      expect(spec[:days]).to eq([1])
      expect(spec[:weekdays]).to eq([1, 2, 3, 4, 5])
    end

    it 'returns empty arrays for nil values' do
      task = described_class.new(task_type: 'cron')
      spec = task.cron_spec
      expect(spec[:minutes]).to eq([])
      expect(spec[:hours]).to eq([])
      expect(spec[:days]).to eq([])
      expect(spec[:weekdays]).to eq([])
    end
  end

  describe '.due_tasks' do
    before do
      described_class.where(true).delete
    end

    it 'returns tasks with next_run_at in the past' do
      past_task = described_class.create(
        name: 'past_task',
        task_type: 'cron',
        enabled: true,
        next_run_at: Time.now - 60
      )
      expect(described_class.due_tasks).to include(past_task)
    end

    it 'returns tasks with nil next_run_at' do
      nil_task = described_class.create(
        name: 'nil_task',
        task_type: 'cron',
        enabled: true,
        next_run_at: nil
      )
      expect(described_class.due_tasks).to include(nil_task)
    end

    it 'excludes disabled tasks' do
      disabled_task = described_class.create(
        name: 'disabled',
        task_type: 'cron',
        enabled: false,
        next_run_at: Time.now - 60
      )
      expect(described_class.due_tasks).not_to include(disabled_task)
    end

    it 'excludes future tasks' do
      future_task = described_class.create(
        name: 'future',
        task_type: 'cron',
        enabled: true,
        next_run_at: Time.now + 3600
      )
      expect(described_class.due_tasks).not_to include(future_task)
    end
  end

  describe '.tick_tasks' do
    before do
      described_class.where(true).delete
    end

    it 'returns tick tasks where tick_count is divisible by tick_interval' do
      tick_5 = described_class.create(
        name: 'tick_5',
        task_type: 'tick',
        enabled: true,
        tick_interval: 5
      )
      expect(described_class.tick_tasks(10)).to include(tick_5)
    end

    it 'excludes tick tasks where tick_count is not divisible' do
      tick_3 = described_class.create(
        name: 'tick_3',
        task_type: 'tick',
        enabled: true,
        tick_interval: 3
      )
      expect(described_class.tick_tasks(10)).not_to include(tick_3)
    end

    it 'excludes non-tick tasks' do
      cron_task = described_class.create(
        name: 'cron_task',
        task_type: 'cron',
        enabled: true
      )
      expect(described_class.tick_tasks(10)).not_to include(cron_task)
    end

    it 'excludes disabled tasks' do
      disabled_tick = described_class.create(
        name: 'disabled_tick',
        task_type: 'tick',
        enabled: false,
        tick_interval: 5
      )
      expect(described_class.tick_tasks(10)).not_to include(disabled_tick)
    end
  end

  describe '.register' do
    it 'creates a new task if none exists' do
      expect {
        described_class.register('new_task', 'cron', { enabled: true })
      }.to change(described_class, :count).by(1)
    end

    it 'updates existing task if one exists' do
      task = described_class.create(name: 'existing_task', task_type: 'cron', enabled: false)

      expect {
        described_class.register('existing_task', 'interval', { enabled: true, interval_seconds: 60 })
      }.not_to change(described_class, :count)

      task.reload
      expect(task.task_type).to eq('interval')
      expect(task.enabled).to be true
      expect(task.interval_seconds).to eq(60)
    end

    it 'returns the task' do
      task = described_class.register('return_task', 'tick', { tick_interval: 5 })
      expect(task).to be_a(described_class)
      expect(task.name).to eq('return_task')
    end
  end
end
