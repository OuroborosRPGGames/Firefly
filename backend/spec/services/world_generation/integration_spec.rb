# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'World Generation Integration', type: :integration do
  let(:world) { create(:world) }

  describe 'full pipeline' do
    WorldGeneration::PresetConfig.all_presets.each_key do |preset|
      context "with #{preset} preset" do
        let(:job) do
          WorldGenerationJob.create(
            world_id: world.id,
            job_type: 'procedural',
            status: 'pending',
            config: { 'preset' => preset.to_s, 'seed' => 42 }
          )
        end

        it 'generates a complete world' do
          WorldGeneration::PipelineService.new(job).run

          job.reload
          expect(job.status).to eq('completed')

          hexes = WorldHex.where(world_id: world.id)
          expect(hexes.count).to be > 100

          terrain_types = hexes.select_map(:terrain_type).uniq
          expect(terrain_types).to include('ocean')
          expect(terrain_types.length).to be > 3
        end

        it 'is reproducible with same seed' do
          # First run
          WorldGeneration::PipelineService.new(job).run
          first_hexes = WorldHex.where(world_id: world.id).order(:globe_hex_id).select_map(:terrain_type)

          # Second run with same seed
          WorldHex.where(world_id: world.id).delete
          job2 = WorldGenerationJob.create(
            world_id: world.id,
            job_type: 'procedural',
            status: 'pending',
            config: { 'preset' => preset.to_s, 'seed' => 42 }
          )
          WorldGeneration::PipelineService.new(job2).run
          second_hexes = WorldHex.where(world_id: world.id).order(:globe_hex_id).select_map(:terrain_type)

          expect(first_hexes).to eq(second_hexes)
        end
      end
    end
  end

  describe 'ocean coverage targets' do
    {
      earth_like: 0.70,
      pangaea: 0.55,
      archipelago: 0.85,
      waterworld: 0.92,
      arid: 0.45
    }.each do |preset, target|
      it "#{preset} has ~#{(target * 100).to_i}% ocean" do
        job = WorldGenerationJob.create(
          world_id: world.id,
          job_type: 'procedural',
          status: 'pending',
          config: { 'preset' => preset.to_s, 'seed' => 123 }
        )

        WorldGeneration::PipelineService.new(job).run

        hexes = WorldHex.where(world_id: world.id)
        ocean_count = hexes.where(terrain_type: 'ocean').count
        coverage = ocean_count.to_f / hexes.count

        expect(coverage).to be_within(0.15).of(target)
      end
    end
  end
end
