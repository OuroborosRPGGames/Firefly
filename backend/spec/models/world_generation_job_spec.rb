# frozen_string_literal: true

require 'spec_helper'

RSpec.describe WorldGenerationJob do
  let(:world) { create(:world) }

  describe 'associations' do
    it 'belongs to world' do
      job = WorldGenerationJob.new(world_id: world.id)
      expect(job.world.id).to eq(world.id)
    end
  end

  describe 'validations' do
    it 'requires world_id' do
      job = WorldGenerationJob.new(job_type: 'random_procedural', status: 'pending')
      expect(job.valid?).to be false
      expect(job.errors[:world_id]).not_to be_empty
    end

    it 'requires job_type' do
      job = WorldGenerationJob.new(world_id: world.id, status: 'pending')
      expect(job.valid?).to be false
      expect(job.errors[:job_type]).not_to be_empty
    end

    it 'validates job_type is in JOB_TYPES' do
      job = WorldGenerationJob.new(world_id: world.id, job_type: 'invalid', status: 'pending')
      expect(job.valid?).to be false
      expect(job.errors[:job_type]).not_to be_empty
    end

    it 'validates status is in STATUSES' do
      job = WorldGenerationJob.new(world_id: world.id, job_type: 'random_procedural', status: 'invalid')
      expect(job.valid?).to be false
      expect(job.errors[:status]).not_to be_empty
    end

    %w[random_procedural procedural procedural_flat earth_import earth_import_flat].each do |type|
      it "accepts #{type} as job_type" do
        job = WorldGenerationJob.new(world_id: world.id, job_type: type, status: 'pending')
        expect(job.valid?).to be true
      end
    end

    %w[pending running completed failed cancelled].each do |status|
      it "accepts #{status} as status" do
        job = WorldGenerationJob.new(world_id: world.id, job_type: 'random_procedural', status: status)
        expect(job.valid?).to be true
      end
    end
  end

  describe 'status helpers' do
    let(:job) { WorldGenerationJob.create(world_id: world.id, job_type: 'random_procedural', status: 'pending') }

    describe '#pending?' do
      it 'returns true when status is pending' do
        expect(job.pending?).to be true
      end

      it 'returns false otherwise' do
        job.update(status: 'running')
        expect(job.pending?).to be false
      end
    end

    describe '#running?' do
      it 'returns true when status is running' do
        job.update(status: 'running')
        expect(job.running?).to be true
      end
    end

    describe '#completed?' do
      it 'returns true when status is completed' do
        job.update(status: 'completed')
        expect(job.completed?).to be true
      end
    end

    describe '#failed?' do
      it 'returns true when status is failed' do
        job.update(status: 'failed')
        expect(job.failed?).to be true
      end
    end

    describe '#cancelled?' do
      it 'returns true when status is cancelled' do
        job.update(status: 'cancelled')
        expect(job.cancelled?).to be true
      end
    end

    describe '#finished?' do
      it 'returns true when completed' do
        job.update(status: 'completed')
        expect(job.finished?).to be true
      end

      it 'returns true when failed' do
        job.update(status: 'failed')
        expect(job.finished?).to be true
      end

      it 'returns true when cancelled' do
        job.update(status: 'cancelled')
        expect(job.finished?).to be true
      end

      it 'returns false when pending or running' do
        expect(job.finished?).to be false
        job.update(status: 'running')
        expect(job.finished?).to be false
      end
    end
  end

  describe 'state transitions' do
    let(:job) { WorldGenerationJob.create(world_id: world.id, job_type: 'random_procedural', status: 'pending') }

    describe '#start!' do
      it 'sets status to running' do
        job.start!
        job.refresh
        expect(job.status).to eq('running')
      end

      it 'sets started_at timestamp' do
        job.start!
        job.refresh
        expect(job.started_at).not_to be_nil
      end
    end

    describe '#update_progress!' do
      before { job.start! }

      it 'updates completed_regions' do
        job.update_progress!(5)
        job.refresh
        expect(job.completed_regions).to eq(5)
      end

      it 'updates total_regions when provided' do
        job.update_progress!(5, 100)
        job.refresh
        expect(job.total_regions).to eq(100)
      end

      it 'calculates progress_percentage' do
        job.update_progress!(25, 100)
        job.refresh
        expect(job.progress_percentage).to eq(25.0)
      end
    end

    describe '#complete!' do
      before { job.start! }

      it 'sets status to completed' do
        job.complete!
        job.refresh
        expect(job.status).to eq('completed')
      end

      it 'sets progress_percentage to 100' do
        job.complete!
        job.refresh
        expect(job.progress_percentage).to eq(100.0)
      end

      it 'sets completed_at timestamp' do
        job.complete!
        job.refresh
        expect(job.completed_at).not_to be_nil
      end
    end

    describe '#fail!' do
      before { job.start! }

      it 'sets status to failed' do
        job.fail!('Something went wrong')
        job.refresh
        expect(job.status).to eq('failed')
      end

      it 'stores error_message' do
        job.fail!('Something went wrong')
        job.refresh
        expect(job.error_message).to eq('Something went wrong')
      end

      it 'stores error_details when provided' do
        job.fail!('Error', 'Stack trace here')
        job.refresh
        expect(job.error_details).to eq('Stack trace here')
      end

      it 'sets completed_at timestamp' do
        job.fail!('Error')
        job.refresh
        expect(job.completed_at).not_to be_nil
      end
    end

    describe '#cancel!' do
      it 'sets status to cancelled' do
        job.cancel!
        job.refresh
        expect(job.status).to eq('cancelled')
      end

      it 'sets completed_at timestamp' do
        job.cancel!
        job.refresh
        expect(job.completed_at).not_to be_nil
      end
    end
  end

  describe '#duration' do
    let(:job) { WorldGenerationJob.create(world_id: world.id, job_type: 'random_procedural', status: 'pending') }

    it 'returns nil when not started' do
      expect(job.duration).to be_nil
    end

    it 'returns duration in seconds when started' do
      start_time = Time.now - 60
      job.update(started_at: start_time)
      expect(job.duration).to be_within(2).of(60)
    end

    it 'uses completed_at when available' do
      start_time = Time.now - 120
      end_time = Time.now - 60
      job.update(started_at: start_time, completed_at: end_time)
      expect(job.duration).to be_within(1).of(60)
    end
  end

  describe '#duration_formatted' do
    let(:job) { WorldGenerationJob.create(world_id: world.id, job_type: 'random_procedural', status: 'pending') }

    it 'returns nil when not started' do
      expect(job.duration_formatted).to be_nil
    end

    it 'formats seconds' do
      job.update(started_at: Time.now - 45, completed_at: Time.now)
      expect(job.duration_formatted).to match(/\d+s/)
    end

    it 'formats minutes and seconds' do
      job.update(started_at: Time.now - 125, completed_at: Time.now)
      expect(job.duration_formatted).to match(/\d+m \d+s/)
    end

    it 'formats hours and minutes' do
      job.update(started_at: Time.now - 3700, completed_at: Time.now)
      expect(job.duration_formatted).to match(/\d+h \d+m/)
    end
  end

  describe '#to_api_hash' do
    let(:job) { WorldGenerationJob.create(world_id: world.id, job_type: 'random_procedural', status: 'pending') }

    it 'returns hash with all fields' do
      hash = job.to_api_hash

      expect(hash[:id]).to eq(job.id)
      expect(hash[:world_id]).to eq(world.id)
      expect(hash[:job_type]).to eq('random_procedural')
      expect(hash[:status]).to eq('pending')
    end
  end

  describe '.latest_for' do
    it 'returns most recent job for world' do
      older = WorldGenerationJob.create(world_id: world.id, job_type: 'random_procedural', status: 'completed')
      newer = WorldGenerationJob.create(world_id: world.id, job_type: 'random_procedural', status: 'pending')

      expect(WorldGenerationJob.latest_for(world)).to eq(newer)
    end

    it 'returns nil when no jobs exist' do
      expect(WorldGenerationJob.latest_for(world)).to be_nil
    end
  end

  describe '.running_for' do
    it 'returns running job for world' do
      WorldGenerationJob.create(world_id: world.id, job_type: 'random_procedural', status: 'completed')
      running = WorldGenerationJob.create(world_id: world.id, job_type: 'random_procedural', status: 'running')

      expect(WorldGenerationJob.running_for(world)).to eq(running)
    end

    it 'returns nil when no running job' do
      WorldGenerationJob.create(world_id: world.id, job_type: 'random_procedural', status: 'completed')
      expect(WorldGenerationJob.running_for(world)).to be_nil
    end
  end

  describe '.create_random' do
    it 'creates a random generation job' do
      job = WorldGenerationJob.create_random(world)

      expect(job.job_type).to eq('random_procedural')
      expect(job.status).to eq('pending')
      expect(job.config).to include('seed', 'ocean_coverage', 'mountain_density', 'forest_coverage')
    end

    it 'accepts custom options' do
      job = WorldGenerationJob.create_random(world, seed: 12345, ocean_coverage: 50)

      expect(job.config['seed']).to eq(12345)
      expect(job.config['ocean_coverage']).to eq(50)
    end
  end

  describe '.create_earth_import' do
    it 'creates an earth import job' do
      job = WorldGenerationJob.create_earth_import(world)

      expect(job.job_type).to eq('earth_import')
      expect(job.status).to eq('pending')
      expect(job.config).to include('source', 'scale')
    end

    it 'accepts custom options' do
      job = WorldGenerationJob.create_earth_import(world, source: 'custom', region: 'europe')

      expect(job.config['source']).to eq('custom')
      expect(job.config['region']).to eq('europe')
    end
  end
end
