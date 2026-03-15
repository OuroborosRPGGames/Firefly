# frozen_string_literal: true

require 'spec_helper'

RSpec.describe GenerationJob do
  # Helper to create a job with required fields
  def create_job(**attrs)
    defaults = {
      job_type: 'room',
      status: 'pending',
      config: {},
      progress: {},
      results: {}
    }
    described_class.create(defaults.merge(attrs))
  end

  describe 'constants' do
    it 'defines JOB_TYPES' do
      expect(described_class::JOB_TYPES).to include(
        'city', 'place', 'room', 'npc', 'item',
        'description', 'image', 'schedule', 'mission'
      )
    end

    it 'defines MISSION_PHASES' do
      expect(described_class::MISSION_PHASES).to eq(%w[brainstorm synthesis round_detail building])
    end

    it 'defines STATUSES' do
      expect(described_class::STATUSES).to eq(%w[pending running completed failed cancelled])
    end
  end

  describe 'associations' do
    let(:character) { create(:character) }

    it 'belongs to created_by (character)' do
      job = create_job(created_by_id: character.id)
      expect(job.created_by).to eq(character)
    end

    it 'belongs to parent_job' do
      parent = create_job
      child = create_job(parent_job_id: parent.id)
      expect(child.parent_job).to eq(parent)
    end

    it 'has many child_jobs' do
      parent = create_job
      child1 = create_job(parent_job_id: parent.id)
      child2 = create_job(parent_job_id: parent.id)

      expect(parent.child_jobs).to include(child1, child2)
    end
  end

  describe 'validations' do
    it 'requires job_type' do
      job = described_class.new(status: 'pending')
      expect(job.valid?).to be false
      expect(job.errors[:job_type]).not_to be_empty
    end

    it 'validates job_type is in JOB_TYPES' do
      job = described_class.new(job_type: 'invalid')
      expect(job.valid?).to be false
    end

    it 'accepts valid job_types' do
      described_class::JOB_TYPES.each do |type|
        job = described_class.new(job_type: type)
        job.valid?
        # Check that job_type specifically has no validation error (returns nil when no errors)
        expect(job.errors[:job_type]).to be_nil
      end
    end

    it 'validates status is in STATUSES when present' do
      job = described_class.new(job_type: 'room', status: 'invalid')
      expect(job.valid?).to be false
    end

    it 'accepts valid statuses' do
      described_class::STATUSES.each do |status|
        job = described_class.new(job_type: 'room', status: status)
        job.valid?
        # Check that status specifically has no validation error (returns nil when no errors)
        expect(job.errors[:status]).to be_nil
      end
    end
  end

  describe '#before_save' do
    it 'wraps config hash in pg_jsonb' do
      job = create_job(config: { key: 'value' })
      expect(job.config).to eq({ 'key' => 'value' })
    end

    it 'wraps progress hash in pg_jsonb' do
      job = create_job(progress: { step: 1 })
      expect(job.progress).to eq({ 'step' => 1 })
    end

    it 'wraps results hash in pg_jsonb' do
      job = create_job(results: { output: 'data' })
      expect(job.results).to eq({ 'output' => 'data' })
    end
  end

  describe 'status helpers' do
    describe '#pending?' do
      it 'returns true when status is pending' do
        job = create_job(status: 'pending')
        expect(job.pending?).to be true
      end

      it 'returns false for other statuses' do
        job = create_job(status: 'running')
        expect(job.pending?).to be false
      end
    end

    describe '#running?' do
      it 'returns true when status is running' do
        job = create_job(status: 'running')
        expect(job.running?).to be true
      end
    end

    describe '#completed?' do
      it 'returns true when status is completed' do
        job = create_job(status: 'completed')
        expect(job.completed?).to be true
      end
    end

    describe '#failed?' do
      it 'returns true when status is failed' do
        job = create_job(status: 'failed')
        expect(job.failed?).to be true
      end
    end

    describe '#cancelled?' do
      it 'returns true when status is cancelled' do
        job = create_job(status: 'cancelled')
        expect(job.cancelled?).to be true
      end
    end

    describe '#finished?' do
      it 'returns true when completed' do
        expect(create_job(status: 'completed').finished?).to be true
      end

      it 'returns true when failed' do
        expect(create_job(status: 'failed').finished?).to be true
      end

      it 'returns true when cancelled' do
        expect(create_job(status: 'cancelled').finished?).to be true
      end

      it 'returns false when pending' do
        expect(create_job(status: 'pending').finished?).to be false
      end

      it 'returns false when running' do
        expect(create_job(status: 'running').finished?).to be false
      end
    end
  end

  describe 'state transitions' do
    describe '#start!' do
      it 'sets status to running' do
        job = create_job(status: 'pending')
        job.start!
        expect(job.status).to eq('running')
      end

      it 'sets started_at' do
        job = create_job(status: 'pending')
        job.start!
        expect(job.started_at).to be_within(2).of(Time.now)
      end
    end

    describe '#complete!' do
      it 'sets status to completed' do
        job = create_job(status: 'running')
        job.complete!
        expect(job.status).to eq('completed')
      end

      it 'sets completed_at' do
        job = create_job(status: 'running')
        job.complete!
        expect(job.completed_at).to be_within(2).of(Time.now)
      end

      it 'merges result data into results' do
        job = create_job(status: 'running', results: { existing: 'data' })
        job.complete!('new' => 'result')
        expect(job.results['existing']).to eq('data')
        expect(job.results['new']).to eq('result')
      end
    end

    describe '#fail!' do
      it 'sets status to failed' do
        job = create_job(status: 'running')
        job.fail!('Something went wrong')
        expect(job.status).to eq('failed')
      end

      it 'sets error_message from string' do
        job = create_job(status: 'running')
        job.fail!('Something went wrong')
        expect(job.error_message).to eq('Something went wrong')
      end

      it 'sets error_message from exception' do
        job = create_job(status: 'running')
        job.fail!(StandardError.new('Test error'))
        expect(job.error_message).to eq('StandardError: Test error')
      end

      it 'sets completed_at' do
        job = create_job(status: 'running')
        job.fail!('error')
        expect(job.completed_at).to be_within(2).of(Time.now)
      end
    end

    describe '#cancel!' do
      it 'sets status to cancelled' do
        job = create_job(status: 'running')
        job.cancel!
        expect(job.status).to eq('cancelled')
      end

      it 'sets completed_at' do
        job = create_job(status: 'running')
        job.cancel!
        expect(job.completed_at).to be_within(2).of(Time.now)
      end
    end
  end

  describe '#update_progress!' do
    it 'updates current_step and total_steps' do
      job = create_job
      job.update_progress!(step: 3, total: 10)
      expect(job.progress['current_step']).to eq(3)
      expect(job.progress['total_steps']).to eq(10)
    end

    it 'calculates percent' do
      job = create_job
      job.update_progress!(step: 5, total: 10)
      expect(job.progress['percent']).to eq(50.0)
    end

    it 'handles zero total' do
      job = create_job
      job.update_progress!(step: 0, total: 0)
      expect(job.progress['percent']).to eq(0)
    end

    it 'includes message when provided' do
      job = create_job
      job.update_progress!(step: 1, total: 5, message: 'Processing')
      expect(job.progress['message']).to eq('Processing')
    end
  end

  describe '#log_progress!' do
    it 'adds entry to progress log' do
      job = create_job
      job.log_progress!('Started processing')

      log = job.progress['log']
      expect(log).to be_an(Array)
      expect(log.length).to eq(1)
      expect(log.first['message']).to eq('Started processing')
    end

    it 'appends to existing log' do
      job = create_job
      job.log_progress!('First entry')
      job.log_progress!('Second entry')

      log = job.progress['log']
      expect(log.length).to eq(2)
      expect(log.last['message']).to eq('Second entry')
    end

    it 'includes timestamp' do
      job = create_job
      job.log_progress!('Entry')

      time_str = job.progress['log'].first['time']
      expect(Time.parse(time_str)).to be_within(5).of(Time.now)
    end
  end

  describe '#config_value' do
    it 'returns nil when config is nil' do
      job = create_job
      job.update(config: nil)
      expect(job.config_value('key')).to be_nil
    end

    it 'returns value for string key' do
      job = create_job(config: { 'key' => 'value' })
      expect(job.config_value('key')).to eq('value')
    end

    it 'returns value for symbol key' do
      job = create_job(config: { key: 'value' })
      expect(job.config_value(:key)).to eq('value')
    end
  end

  describe '#result_value' do
    it 'returns nil when results is nil' do
      job = create_job
      job.update(results: nil)
      expect(job.result_value('key')).to be_nil
    end

    it 'returns value for string key' do
      job = create_job(results: { 'key' => 'value' })
      expect(job.result_value('key')).to eq('value')
    end
  end

  describe '#total_progress' do
    it 'returns own progress when no child jobs' do
      job = create_job(progress: { 'percent' => 50.0 })
      expect(job.total_progress).to eq(50.0)
    end

    it 'returns 0 when progress is nil' do
      job = create_job
      job.update(progress: nil)
      expect(job.total_progress).to eq(0)
    end

    it 'averages child job progress' do
      parent = create_job
      child1 = create_job(parent_job_id: parent.id, progress: { 'percent' => 100.0 })
      child2 = create_job(parent_job_id: parent.id, progress: { 'percent' => 50.0 })

      # Need to reload to get child_jobs
      parent.reload
      expect(parent.total_progress).to eq(75.0)
    end
  end

  describe '#children_complete?' do
    it 'returns true when all children are finished' do
      parent = create_job
      create_job(parent_job_id: parent.id, status: 'completed')
      create_job(parent_job_id: parent.id, status: 'failed')

      parent.reload
      expect(parent.children_complete?).to be true
    end

    it 'returns false when any child is not finished' do
      parent = create_job
      create_job(parent_job_id: parent.id, status: 'completed')
      create_job(parent_job_id: parent.id, status: 'running')

      parent.reload
      expect(parent.children_complete?).to be false
    end

    it 'returns true when no children exist' do
      job = create_job
      expect(job.children_complete?).to be true
    end
  end

  describe '#status_display' do
    it 'returns "Waiting to start" for pending' do
      job = create_job(status: 'pending')
      expect(job.status_display).to eq('Waiting to start')
    end

    it 'returns progress message when running with message' do
      job = create_job(status: 'running', progress: { 'message' => 'Generating rooms' })
      expect(job.status_display).to eq('Generating rooms')
    end

    it 'returns percent when running without message' do
      job = create_job(status: 'running', progress: { 'percent' => 45 })
      expect(job.status_display).to eq('Running (45%)')
    end

    it 'returns "Completed" for completed' do
      job = create_job(status: 'completed')
      expect(job.status_display).to eq('Completed')
    end

    it 'includes error message for failed' do
      job = create_job(status: 'failed')
      job.update(error_message: 'Connection timeout')
      expect(job.status_display).to eq('Failed: Connection timeout')
    end

    it 'returns "Cancelled" for cancelled' do
      job = create_job(status: 'cancelled')
      expect(job.status_display).to eq('Cancelled')
    end
  end

  describe '#type_display' do
    it 'returns human-readable names for known types' do
      expect(create_job(job_type: 'city').type_display).to eq('City Generation')
      expect(create_job(job_type: 'place').type_display).to eq('Place/Building')
      expect(create_job(job_type: 'room').type_display).to eq('Room')
      expect(create_job(job_type: 'npc').type_display).to eq('NPC')
      expect(create_job(job_type: 'item').type_display).to eq('Item')
      expect(create_job(job_type: 'description').type_display).to eq('Description')
      expect(create_job(job_type: 'image').type_display).to eq('Image')
      expect(create_job(job_type: 'schedule').type_display).to eq('NPC Schedule')
      expect(create_job(job_type: 'mission').type_display).to eq('Mission Generation')
    end

    it 'returns titleized version for unknown type' do
      # Create job then update to bypass validation
      job = create_job(job_type: 'room')
      job.this.update(job_type: 'custom_type')
      job.refresh
      expect(job.type_display).to eq('Custom Type')
    end
  end

  describe '#status_display edge cases' do
    it 'returns status itself for unknown status' do
      job = create_job(status: 'running')
      job.this.update(status: 'unknown_status')
      job.refresh
      expect(job.status_display).to eq('unknown_status')
    end

    it 'returns Running with 0% when running with no progress percent' do
      job = create_job(status: 'running', progress: {})
      expect(job.status_display).to eq('Running (0%)')
    end
  end

  describe '#update_phase!' do
    it 'updates phase' do
      job = create_job(job_type: 'mission')
      job.update_phase!('brainstorm')
      expect(job.phase).to eq('brainstorm')
    end

    it 'logs progress entry' do
      job = create_job(job_type: 'mission')
      job.update_phase!('synthesis')
      expect(job.progress['log'].last['message']).to include('synthesis')
    end
  end

  describe '#store_brainstorm!' do
    it 'stores brainstorm outputs' do
      job = create_job(job_type: 'mission')
      job.store_brainstorm!('ideas' => ['idea1', 'idea2'])
      job.reload
      expect(job.brainstorm_outputs['ideas']).to eq(['idea1', 'idea2'])
    end
  end

  describe '#store_synthesis!' do
    it 'stores synthesized plan' do
      job = create_job(job_type: 'mission')
      job.store_synthesis!('objectives' => [{ 'name' => 'Objective 1' }])
      job.reload
      expect(job.synthesized_plan['objectives']).to eq([{ 'name' => 'Objective 1' }])
    end
  end

  describe '#duration' do
    it 'returns nil when not started' do
      job = create_job
      expect(job.duration).to be_nil
    end

    it 'returns elapsed time when running' do
      job = create_job(started_at: Time.now - 60)
      expect(job.duration).to be_within(2).of(60)
    end

    it 'returns total time when completed' do
      job = create_job(
        started_at: Time.now - 120,
        completed_at: Time.now - 60
      )
      expect(job.duration).to be_within(2).of(60)
    end
  end

  describe '#duration_display' do
    it 'returns "Not started" when not started' do
      job = create_job
      expect(job.duration_display).to eq('Not started')
    end

    it 'returns seconds for short duration' do
      job = create_job(started_at: Time.now - 30, completed_at: Time.now)
      expect(job.duration_display).to match(/^\d+(\.\d)?s$/)
    end

    it 'returns minutes for medium duration' do
      job = create_job(started_at: Time.now - 300, completed_at: Time.now)
      expect(job.duration_display).to match(/^\d+(\.\d)?m$/)
    end

    it 'returns hours for long duration' do
      job = create_job(started_at: Time.now - 7200, completed_at: Time.now)
      expect(job.duration_display).to match(/^\d+(\.\d)?h$/)
    end
  end

  describe 'class methods' do
    let(:character) { create(:character) }

    describe '.active_for_character' do
      it 'returns pending and running jobs for character' do
        pending_job = create_job(created_by_id: character.id, status: 'pending')
        running_job = create_job(created_by_id: character.id, status: 'running')
        completed_job = create_job(created_by_id: character.id, status: 'completed')

        result = described_class.active_for_character(character.id)
        expect(result).to include(pending_job, running_job)
        expect(result).not_to include(completed_job)
      end
    end

    describe '.recent_for_character' do
      it 'returns jobs for character ordered by created_at desc' do
        old_job = create_job(created_by_id: character.id)
        new_job = create_job(created_by_id: character.id)

        result = described_class.recent_for_character(character.id)
        expect(result.first).to eq(new_job)
      end

      it 'respects limit parameter' do
        5.times { create_job(created_by_id: character.id) }

        result = described_class.recent_for_character(character.id, limit: 3)
        expect(result.length).to eq(3)
      end
    end

    describe '.stale_running' do
      it 'returns jobs running for over timeout period' do
        timeout = GameConfig::Timeouts::GENERATION_JOB_TIMEOUT_SECONDS
        stale_job = create_job(
          status: 'running',
          started_at: Time.now - timeout - 60
        )
        recent_job = create_job(
          status: 'running',
          started_at: Time.now - 60
        )

        result = described_class.stale_running
        expect(result).to include(stale_job)
        expect(result).not_to include(recent_job)
      end
    end

    describe '.cleanup_old!' do
      it 'deletes completed jobs older than 7 days' do
        old_job = create_job(
          status: 'completed',
          completed_at: Time.now - (8 * 86_400)
        )
        recent_job = create_job(
          status: 'completed',
          completed_at: Time.now - 86_400
        )

        count = described_class.cleanup_old!
        expect(count).to eq(1)
        expect(described_class.where(id: old_job.id).count).to eq(0)
        expect(described_class.where(id: recent_job.id).count).to eq(1)
      end
    end
  end
end
