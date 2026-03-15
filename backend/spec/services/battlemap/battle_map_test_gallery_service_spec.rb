# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

RSpec.describe BattleMapTestGalleryService do
  around do |example|
    Dir.mktmpdir do |tmpdir|
      original_dir = described_class::RESULTS_DIR
      original_file = described_class::RESULTS_FILE

      described_class.send(:remove_const, :RESULTS_DIR)
      described_class.send(:remove_const, :RESULTS_FILE)
      described_class.const_set(:RESULTS_DIR, tmpdir)
      described_class.const_set(:RESULTS_FILE, File.join(tmpdir, 'results.json'))

      begin
        example.run
      ensure
        described_class.send(:remove_const, :RESULTS_DIR)
        described_class.send(:remove_const, :RESULTS_FILE)
        described_class.const_set(:RESULTS_DIR, original_dir)
        described_class.const_set(:RESULTS_FILE, original_file)
      end
    end
  end

  let(:service) { described_class.new }

  describe 'result persistence' do
    it 'returns empty hash when results file does not exist' do
      expect(service.load_results).to eq({})
    end

    it 'returns empty hash when results file has invalid json' do
      File.write(described_class::RESULTS_FILE, '{invalid')
      expect(service.load_results).to eq({})
    end

    it 'saves and reloads result entries' do
      service.save_result(0, { 'success' => true, 'room_id' => 101 })
      service.save_result(1, { 'success' => false, 'error' => 'boom' })

      results = service.load_results
      expect(results['0']).to include('success' => true, 'room_id' => 101)
      expect(results['1']).to include('success' => false, 'error' => 'boom')
    end

    it 'updates an existing result atomically' do
      service.save_result(2, { 'success' => true, 'tags' => ['a'] })

      service.update_result(2) do |data|
        data['tags'] << 'b'
        data['updated'] = true
      end

      results = service.load_results
      expect(results['2']['tags']).to eq(%w[a b])
      expect(results['2']['updated']).to be true
    end
  end

  describe '#build_spatial_chunks' do
    it 'returns a single chunk when hex count is below target size' do
      coords = [[0, 0], [2, 0], [0, 4]]
      chunks = service.send(:build_spatial_chunks, coords, 10)

      expect(chunks.length).to eq(1)
      expect(chunks.first[:coords]).to eq(coords)
      expect(chunks.first[:grid_pos]).to eq({ gx: 0, gy: 0, nx: 1, ny: 1 })
    end

    it 'falls back to a single chunk when coordinate lookup is missing' do
      coords = [[0, 0], [2, 0], [0, 4], [2, 4]]
      service.instance_variable_set(:@coord_lookup, nil)

      chunks = service.send(:build_spatial_chunks, coords, 2)

      expect(chunks.length).to eq(1)
      expect(chunks.first[:coords]).to eq(coords)
    end

    it 'splits into spatial chunks when pixel lookup exists' do
      coords = [[0, 0], [2, 0], [0, 4], [2, 4]]
      service.instance_variable_set(:@coord_lookup, {
                                      [0, 0] => { px: 10, py: 10 },
                                      [2, 0] => { px: 90, py: 10 },
                                      [0, 4] => { px: 10, py: 30 },
                                      [2, 4] => { px: 90, py: 30 }
                                    })

      chunks = service.send(:build_spatial_chunks, coords, 2)

      expect(chunks.length).to eq(2)
      expect(chunks[0][:grid_pos]).to include(gx: 0, gy: 0, nx: 2, ny: 1)
      expect(chunks[1][:grid_pos]).to include(gx: 1, gy: 0, nx: 2, ny: 1)
    end
  end

  describe '#chunk_position_label' do
    it 'returns center for a single-cell grid' do
      label = service.send(:chunk_position_label, { gx: 0, gy: 0, nx: 1, ny: 1 })
      expect(label).to eq('center of the map')
    end

    it 'returns top-left for a corner chunk' do
      label = service.send(:chunk_position_label, { gx: 0, gy: 0, nx: 3, ny: 3 })
      expect(label).to eq('top-left of the map')
    end

    it 'returns left when only horizontal context exists' do
      label = service.send(:chunk_position_label, { gx: 0, gy: 0, nx: 3, ny: 1 })
      expect(label).to eq('left of the map')
    end
  end

  describe '#assign_chunk_grid_labels' do
    it 'labels chunks as A1, A2, B1 by grid position' do
      chunks = [
        { grid_pos: { gx: 0, gy: 0, nx: 2, ny: 2 } },
        { grid_pos: { gx: 1, gy: 0, nx: 2, ny: 2 } },
        { grid_pos: { gx: 0, gy: 1, nx: 2, ny: 2 } }
      ]

      labels = service.send(:assign_chunk_grid_labels, chunks)

      expect(labels).to eq({ 0 => 'A1', 1 => 'A2', 2 => 'B1' })
    end
  end

  describe '#dominant_trait' do
    it 'prefers off_map over all other traits' do
      data = { 'is_off_map' => true, 'is_window' => true, 'is_wall' => true, 'is_exit' => true }
      expect(service.send(:dominant_trait, data)).to eq('off_map')
    end

    it 'returns water trait when water depth is present' do
      data = { 'water_depth' => 'deep', 'hazards' => ['fire'] }
      expect(service.send(:dominant_trait, data)).to eq('water_deep')
    end

    it 'returns open when no trait matches' do
      data = {
        'is_off_map' => false, 'is_window' => false, 'is_wall' => false, 'is_exit' => false,
        'water_depth' => 'none', 'hazards' => [], 'elevation' => 0,
        'provides_cover' => false, 'provides_concealment' => false, 'difficult_terrain' => false
      }
      expect(service.send(:dominant_trait, data)).to eq('open')
    end
  end

  describe '#hex_display_label' do
    it 'uses abbreviated hex_type when provided' do
      expect(service.send(:hex_display_label, { 'hex_type' => 'dense_trees' })).to eq('DnsTr')
    end

    it 'uses hazard abbreviation when hazards are present' do
      data = {
        'hazards' => ['electricity'],
        'water_depth' => 'none',
        'elevation' => 0
      }
      expect(service.send(:hex_display_label, data)).to eq('Ele')
    end

    it 'formats elevation labels with signed value' do
      data = {
        'elevation' => 3,
        'hazards' => [],
        'water_depth' => 'none'
      }
      expect(service.send(:hex_display_label, data)).to eq('Up+3')
    end
  end

  describe '#abbreviate_hex_type' do
    it 'uses known abbreviations for mapped types' do
      expect(service.send(:abbreviate_hex_type, 'open_window')).to eq('OpWin')
    end

    it 'builds abbreviation for multi-part types' do
      expect(service.send(:abbreviate_hex_type, 'stone_table_large')).to eq('StoTab')
    end

    it 'truncates single-word type names' do
      expect(service.send(:abbreviate_hex_type, 'bridge')).to eq('Bridg')
    end
  end
end
