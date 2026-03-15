# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Python World Generation Integration', :slow do
  let(:world) { create(:world) }

  it 'generates and imports a small world' do
    skip 'Python worldgen not installed' unless python_worldgen_available?

    job = WorldGenerationJob.create(
      world_id: world.id,
      job_type: 'procedural',
      status: 'pending',
      config: {
        'seed' => 12345,
        'subdivision_level' => 2  # Small for fast test
      }
    )

    WorldGeneration::PythonRunnerService.new(job).run

    job.reload
    expect(job.status).to eq('completed')

    # Verify hexes were created
    hex_count = WorldHex.where(world_id: world.id).count
    expect(hex_count).to be > 0

    # Verify terrain types are set
    hex = WorldHex.where(world_id: world.id).first
    expect(hex.terrain_type).not_to be_empty
  end

  private

  def python_worldgen_available?
    # Path from spec/services/world_generation/ to backend/python_worldgen
    python_path = File.expand_path('../../../python_worldgen', __dir__)
    system("cd #{python_path} && python3 -c 'import worldgen' 2>/dev/null")
  end
end
