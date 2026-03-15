# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ProgressTrackerService do
  let(:character) { create(:character, forename: 'TestChar') }

  describe '.create_job' do
    it 'creates a new generation job' do
      job = described_class.create_job(
        type: :description,
        config: { target_type: 'room', target_id: 123 }
      )

      expect(job).to be_a(GenerationJob)
      expect(job.job_type).to eq('description')
      expect(job.status).to eq('pending')
    end

    it 'accepts symbol or string type' do
      job1 = described_class.create_job(type: :room, config: {})
      job2 = described_class.create_job(type: 'room', config: {})

      expect(job1.job_type).to eq('room')
      expect(job2.job_type).to eq('room')
    end

    it 'stores config in JSONB format' do
      config = { target_type: 'room', target_id: 456, options: { detailed: true } }
      job = described_class.create_job(type: :description, config: config)

      expect(job.config['target_type']).to eq('room')
      expect(job.config['target_id']).to eq(456)
    end

    it 'initializes progress tracking' do
      job = described_class.create_job(type: :description, config: {})

      expect(job.progress['current_step']).to eq(0)
      expect(job.progress['total_steps']).to eq(0)
      expect(job.progress['percent']).to eq(0)
      expect(job.progress['log']).to eq([])
    end

    it 'associates with parent job when provided' do
      parent = described_class.create_job(type: :city, config: {})
      child = described_class.create_job(
        type: :room,
        config: {},
        parent_job: parent
      )

      expect(child.parent_job_id).to eq(parent.id)
      expect(child.parent_job).to eq(parent)
    end

    it 'associates with created_by character when provided' do
      job = described_class.create_job(
        type: :description,
        config: {},
        created_by: character
      )

      expect(job.created_by_id).to eq(character.id)
    end
  end

  describe '.start' do
    let(:job) { described_class.create_job(type: :description, config: {}) }

    it 'marks job as running' do
      described_class.start(job: job)

      expect(job.reload.status).to eq('running')
    end

    it 'sets started_at timestamp' do
      described_class.start(job: job)

      expect(job.reload.started_at).not_to be_nil
    end

    it 'sets total steps and initial message' do
      described_class.start(job: job, total_steps: 5, message: 'Beginning generation')

      expect(job.reload.progress['total_steps']).to eq(5)
      expect(job.progress['message']).to eq('Beginning generation')
    end

    it 'uses default message when not provided' do
      described_class.start(job: job)

      expect(job.reload.progress['message']).to eq('Starting...')
    end
  end

  describe '.update_progress' do
    let(:job) do
      j = described_class.create_job(type: :description, config: {})
      described_class.start(job: j, total_steps: 10)
      j
    end

    it 'updates step and total' do
      described_class.update_progress(job: job, step: 5, total: 10)

      expect(job.reload.progress['current_step']).to eq(5)
      expect(job.reload.progress['total_steps']).to eq(10)
    end

    it 'calculates percent complete' do
      described_class.update_progress(job: job, step: 5, total: 10)

      expect(job.reload.progress['percent']).to eq(50.0)
    end

    it 'updates message when provided' do
      described_class.update_progress(job: job, step: 3, total: 10, message: 'Processing step 3')

      expect(job.reload.progress['message']).to eq('Processing step 3')
    end

    it 'handles zero total gracefully' do
      described_class.update_progress(job: job, step: 0, total: 0)

      expect(job.reload.progress['percent']).to eq(0)
    end
  end

  describe '.log' do
    let(:job) { described_class.create_job(type: :description, config: {}) }

    it 'adds log entry with timestamp' do
      described_class.log(job: job, message: 'Something happened')

      log = job.reload.progress['log']
      expect(log.length).to eq(1)
      expect(log[0]['message']).to eq('Something happened')
      expect(log[0]['time']).not_to be_nil
    end

    it 'appends multiple log entries' do
      described_class.log(job: job, message: 'First message')
      described_class.log(job: job, message: 'Second message')

      log = job.reload.progress['log']
      expect(log.length).to eq(2)
      expect(log[0]['message']).to eq('First message')
      expect(log[1]['message']).to eq('Second message')
    end
  end

  describe '.complete' do
    let(:job) do
      j = described_class.create_job(type: :description, config: {})
      described_class.start(job: j)
      j
    end

    it 'marks job as completed' do
      described_class.complete(job: job)

      expect(job.reload.status).to eq('completed')
    end

    it 'sets completed_at timestamp' do
      described_class.complete(job: job)

      expect(job.reload.completed_at).not_to be_nil
    end

    it 'stores results' do
      described_class.complete(job: job, results: { description: 'A cozy room' })

      expect(job.reload.results['description']).to eq('A cozy room')
    end

    context 'with parent job' do
      let(:parent_job) { described_class.create_job(type: :city, config: {}) }
      let(:child_job1) do
        j = described_class.create_job(type: :room, config: {}, parent_job: parent_job)
        described_class.start(job: j)
        j
      end
      let(:child_job2) do
        j = described_class.create_job(type: :room, config: {}, parent_job: parent_job)
        described_class.start(job: j)
        j
      end

      before do
        described_class.start(job: parent_job, total_steps: 2)
        # Create child jobs
        child_job1
        child_job2
      end

      it 'updates parent progress when child completes' do
        described_class.complete(job: child_job1, results: { room_id: 1 })

        parent = parent_job.reload
        expect(parent.progress['current_step']).to eq(1)
      end

      it 'completes parent when all children are done' do
        described_class.complete(job: child_job1, results: { room_id: 1 })
        described_class.complete(job: child_job2, results: { room_id: 2 })

        expect(parent_job.reload.status).to eq('completed')
      end
    end
  end

  describe '.fail' do
    let(:job) do
      j = described_class.create_job(type: :description, config: {})
      described_class.start(job: j)
      j
    end

    it 'marks job as failed' do
      described_class.fail(job: job, error: 'Something went wrong')

      expect(job.reload.status).to eq('failed')
    end

    it 'stores error message from string' do
      described_class.fail(job: job, error: 'API timeout')

      expect(job.reload.error_message).to eq('API timeout')
    end

    it 'stores error message from exception' do
      exception = StandardError.new('Network error')
      described_class.fail(job: job, error: exception)

      expect(job.reload.error_message).to include('StandardError')
      expect(job.reload.error_message).to include('Network error')
    end

    it 'sets completed_at timestamp' do
      described_class.fail(job: job, error: 'Error')

      expect(job.reload.completed_at).not_to be_nil
    end

    context 'with parent job' do
      let(:parent_job) { described_class.create_job(type: :city, config: {}) }
      let(:child_job) do
        j = described_class.create_job(type: :room, config: {}, parent_job: parent_job)
        described_class.start(job: j)
        j
      end

      before do
        described_class.start(job: parent_job)
        child_job
      end

      it 'logs failure in parent job' do
        described_class.fail(job: child_job, error: 'Child failed')

        parent_log = parent_job.reload.progress['log']
        expect(parent_log).not_to be_empty
        expect(parent_log.last['message']).to include('failed')
      end
    end
  end

  describe '.cancel' do
    let(:job) do
      j = described_class.create_job(type: :description, config: {})
      described_class.start(job: j)
      j
    end

    it 'marks job as cancelled' do
      described_class.cancel(job: job)

      expect(job.reload.status).to eq('cancelled')
    end

    it 'sets completed_at timestamp' do
      described_class.cancel(job: job)

      expect(job.reload.completed_at).not_to be_nil
    end

    context 'with child jobs' do
      let(:child_job1) do
        j = described_class.create_job(type: :room, config: {}, parent_job: job)
        described_class.start(job: j)
        j
      end
      let(:child_job2) do
        j = described_class.create_job(type: :room, config: {}, parent_job: job)
        described_class.start(job: j)
        j
      end

      before do
        child_job1
        child_job2
      end

      it 'cancels all child jobs' do
        described_class.cancel(job: job)

        expect(child_job1.reload.status).to eq('cancelled')
        expect(child_job2.reload.status).to eq('cancelled')
      end

      it 'does not cancel already finished child jobs' do
        described_class.complete(job: child_job1, results: {})
        described_class.cancel(job: job)

        expect(child_job1.reload.status).to eq('completed')
        expect(child_job2.reload.status).to eq('cancelled')
      end
    end
  end

  describe '.progress' do
    let(:job) do
      j = described_class.create_job(
        type: :description,
        config: {},
        created_by: character
      )
      described_class.start(job: j, total_steps: 5)
      described_class.update_progress(job: j, step: 2, total: 5, message: 'Processing')
      j
    end

    it 'returns progress hash with all fields' do
      progress = described_class.progress(job: job)

      expect(progress[:id]).to eq(job.id)
      expect(progress[:type]).to eq('Description')
      expect(progress[:status]).to eq('running')
      expect(progress[:percent]).to eq(40.0)
      expect(progress[:message]).to eq('Processing')
    end

    it 'includes timestamp fields' do
      progress = described_class.progress(job: job)

      expect(progress[:created_at]).to be_a(String)
      expect(progress[:started_at]).to be_a(String)
    end

    it 'includes child progress for parent jobs' do
      child = described_class.create_job(type: :room, config: {}, parent_job: job)
      described_class.start(job: child, total_steps: 3)

      progress = described_class.progress(job: job)

      expect(progress[:has_children]).to be true
      expect(progress[:child_progress]).to be_an(Array)
      expect(progress[:child_progress].length).to eq(1)
    end

    it 'includes results when completed' do
      described_class.complete(job: job, results: { output: 'test' })

      progress = described_class.progress(job: job)

      # Results are stored with symbol keys
      expect(progress[:results][:output]).to eq('test')
    end

    it 'includes error when failed' do
      described_class.fail(job: job, error: 'Something broke')

      progress = described_class.progress(job: job)

      expect(progress[:error]).to eq('Something broke')
    end
  end

  describe '.active_jobs_for' do
    let!(:pending_job) do
      described_class.create_job(type: :description, config: {}, created_by: character)
    end
    let!(:running_job) do
      j = described_class.create_job(type: :room, config: {}, created_by: character)
      described_class.start(job: j)
      j
    end
    let!(:completed_job) do
      j = described_class.create_job(type: :npc, config: {}, created_by: character)
      described_class.start(job: j)
      described_class.complete(job: j, results: {})
      j
    end

    it 'returns only pending and running jobs' do
      active = described_class.active_jobs_for(character)

      expect(active.length).to eq(2)
      expect(active.map { |j| j[:id] }).to include(pending_job.id, running_job.id)
      expect(active.map { |j| j[:id] }).not_to include(completed_job.id)
    end

    it 'returns formatted progress info' do
      active = described_class.active_jobs_for(character)

      expect(active.first).to have_key(:id)
      expect(active.first).to have_key(:type)
      expect(active.first).to have_key(:status)
    end
  end

  describe '.recent_jobs_for' do
    before do
      5.times do |i|
        j = described_class.create_job(type: :description, config: { n: i }, created_by: character)
        described_class.start(job: j)
        described_class.complete(job: j, results: {})
      end
    end

    it 'returns recent jobs up to limit' do
      recent = described_class.recent_jobs_for(character, limit: 3)

      expect(recent.length).to eq(3)
    end

    it 'orders by creation date descending' do
      recent = described_class.recent_jobs_for(character)

      ids = recent.map { |j| j[:id] }
      expect(ids).to eq(ids.sort.reverse)
    end
  end

  describe '.with_job' do
    it 'creates and starts a job' do
      job = described_class.with_job(
        type: :description,
        config: { test: true }
      ) do |j|
        # Block receives the job
        expect(j).to be_a(GenerationJob)
        expect(j.running?).to be true
        { result: 'success' }
      end

      expect(job.status).to eq('completed')
      # Results are stored with symbol keys
      expect(job.results[:result]).to eq('success')
    end

    it 'fails job on exception' do
      expect do
        described_class.with_job(type: :description, config: {}) do |_j|
          raise 'Test error'
        end
      end.to raise_error('Test error')

      # Job should be failed
      job = GenerationJob.order(Sequel.desc(:id)).first
      expect(job.status).to eq('failed')
      expect(job.error_message).to include('Test error')
    end

    it 'accepts created_by parameter' do
      job = described_class.with_job(
        type: :description,
        config: {},
        created_by: character
      ) { { done: true } }

      expect(job.created_by_id).to eq(character.id)
    end

    it 'accepts total_steps parameter' do
      job = described_class.with_job(
        type: :description,
        config: {},
        total_steps: 10
      ) { { done: true } }

      expect(job.progress['total_steps']).to eq(10)
    end
  end

  describe '.spawn_async' do
    let(:job) do
      j = described_class.create_job(type: :description, config: {})
      described_class.start(job: j)
      j
    end

    it 'returns a Thread object' do
      thread = described_class.spawn_async(job: job) { |_j| nil }

      expect(thread).to be_a(Thread)
      thread.join(0.1)
    end

    it 'executes the block with the job' do
      job_received = nil

      thread = described_class.spawn_async(job: job) do |j|
        job_received = j
      end

      thread.join(1)

      expect(job_received).to eq(job)
    end

    it 'handles exceptions by calling fail on the job' do
      # Stub the fail method to verify it's called with correct params
      expect(described_class).to receive(:fail).with(
        job: job,
        error: an_instance_of(RuntimeError)
      )

      thread = described_class.spawn_async(job: job) do |_j|
        raise 'Async error'
      end

      thread.join(1)
    end
  end

  describe '.cleanup_old_jobs!' do
    before do
      # Create old completed jobs (stub time)
      old_time = Time.now - (8 * 86_400)

      3.times do
        j = described_class.create_job(type: :description, config: {})
        described_class.start(job: j)
        described_class.complete(job: j, results: {})
        DB[:generation_jobs].where(id: j.id).update(completed_at: old_time)
      end

      # Create recent job
      j = described_class.create_job(type: :description, config: {})
      described_class.start(job: j)
      described_class.complete(job: j, results: {})
    end

    it 'deletes old completed jobs' do
      expect { described_class.cleanup_old_jobs! }.to change { GenerationJob.count }.by(-3)
    end

    it 'keeps recent jobs' do
      described_class.cleanup_old_jobs!

      expect(GenerationJob.count).to eq(1)
    end
  end

  describe '.mark_stale_jobs_failed!' do
    before do
      # Create stale running job
      stale_time = Time.now - GameConfig::Timeouts::GENERATION_JOB_TIMEOUT_SECONDS - 60

      @stale_job = described_class.create_job(type: :description, config: {})
      described_class.start(job: @stale_job)
      DB[:generation_jobs].where(id: @stale_job.id).update(started_at: stale_time)

      # Create recent running job
      @recent_job = described_class.create_job(type: :description, config: {})
      described_class.start(job: @recent_job)
    end

    it 'fails stale running jobs' do
      count = described_class.mark_stale_jobs_failed!

      expect(count).to eq(1)
      expect(@stale_job.reload.status).to eq('failed')
      expect(@stale_job.error_message).to include('timed out')
    end

    it 'leaves recent jobs running' do
      described_class.mark_stale_jobs_failed!

      expect(@recent_job.reload.status).to eq('running')
    end
  end

  describe 'private methods' do
    describe '#check_parent_completion' do
      let(:parent) do
        j = described_class.create_job(type: :city, config: {})
        described_class.start(job: j, total_steps: 2)
        j
      end
      let(:child1) do
        j = described_class.create_job(type: :room, config: {}, parent_job: parent)
        described_class.start(job: j)
        j
      end
      let(:child2) do
        j = described_class.create_job(type: :room, config: {}, parent_job: parent)
        described_class.start(job: j)
        j
      end

      before do
        child1
        child2
      end

      it 'updates parent progress when one child completes' do
        described_class.complete(job: child1, results: { id: 1 })

        parent_progress = parent.reload.progress
        expect(parent_progress['current_step']).to eq(1)
        expect(parent_progress['total_steps']).to eq(2)
      end

      it 'completes parent when all children finish' do
        described_class.complete(job: child1, results: { id: 1 })
        described_class.complete(job: child2, results: { id: 2 })

        expect(parent.reload.status).to eq('completed')
        expect(parent.results['children_results']).to be_an(Array)
      end
    end
  end
end
