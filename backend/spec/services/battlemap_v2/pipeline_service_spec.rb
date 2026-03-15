# frozen_string_literal: true

require 'spec_helper'
require 'vips'

RSpec.describe BattlemapV2::PipelineService do
  let(:room) do
    instance_double('Room',
      id: 42,
      min_x: 0, max_x: 40,
      min_y: 0, max_y: 40,
      update: nil,
      room_hexes_dataset: double('dataset', where: double('scope', each: nil))
    )
  end
  let(:image_path) { 'spec/fixtures/test_battlemap.png' }
  let(:service) { described_class.new(room: room, image_path: image_path) }

  let(:minimal_l1_data) do
    {
      'standard_types_present' => [
        { 'type_name' => 'open_floor', 'visual_description' => 'plain stone floor' }
      ],
      'custom_types' => [],
      'scene_description' => 'A simple room with stone floors.',
      'light_sources' => []
    }
  end

  let(:empty_hex_data) { [{ 'hex_type' => 'normal', 'x' => 0, 'y' => 0 }] }

  before do
    # Stub private pipeline phase methods
    allow(service).to receive(:run_l1_analysis).and_return(minimal_l1_data)
    allow(service).to receive(:run_wall_door_recolor).and_return(nil)
    allow(service).to receive(:run_depth_estimation).and_return(nil)

    # Stub ReplicateSamService so effect mask threads are skipped
    stub_const('ReplicateSamService', Module.new)
    allow(ReplicateSamService).to receive(:available?).and_return(false)

    # Stub SamSegmentationService
    sam_instance = instance_double('BattlemapV2::SamSegmentationService')
    allow(BattlemapV2::SamSegmentationService).to receive(:new).and_return(sam_instance)
    allow(sam_instance).to receive(:segment_objects_parallel).and_return({})
    allow(sam_instance).to receive(:segment_generic_list).and_return({ success: true, high_conf: [], low_conf: [] })

    # Stub WallDoorService
    wall_door_instance = instance_double('BattlemapV2::WallDoorService')
    allow(BattlemapV2::WallDoorService).to receive(:new).and_return(wall_door_instance)
    allow(wall_door_instance).to receive(:recolor_walls).and_return(nil)
    allow(wall_door_instance).to receive(:instance_variable_set)
    allow(wall_door_instance).to receive(:build_pixel_mask).and_return({
      wall_mask_path: nil,
      width: 800,
      height: 600
    })

    # Stub HexOverlayService
    hex_overlay_instance = instance_double('BattlemapV2::HexOverlayService')
    allow(BattlemapV2::HexOverlayService).to receive(:new).and_return(hex_overlay_instance)
    allow(hex_overlay_instance).to receive(:classify_hexes).and_return(empty_hex_data)
    allow(hex_overlay_instance).to receive(:generate_debug_images).with(anything, hash_including(output_dir: anything))

    # Stub persist helpers to do nothing
    allow(service).to receive(:persist_wall_mask)
    allow(service).to receive(:persist_effect_masks)
    allow(service).to receive(:extract_light_sources)
  end

  describe '#run' do
    it 'returns an Array' do
      result = service.run
      expect(result).to be_an(Array)
    end

    it 'returns hex data from HexOverlayService' do
      result = service.run
      expect(result).to eq(empty_hex_data)
    end

    it 'returns an empty array when L1 analysis fails' do
      allow(service).to receive(:run_l1_analysis).and_return(nil)
      result = service.run
      expect(result).to eq([])
    end

    it 'returns an empty array when an unexpected error occurs' do
      allow(service).to receive(:run_l1_analysis).and_raise(StandardError, 'unexpected failure')
      result = service.run
      expect(result).to eq([])
    end

    it 'invokes persist_wall_mask after classification' do
      expect(service).to receive(:persist_wall_mask)
      service.run
    end

    it 'invokes persist_effect_masks after classification' do
      expect(service).to receive(:persist_effect_masks)
      service.run
    end

    it 'invokes extract_light_sources after classification' do
      expect(service).to receive(:extract_light_sources)
      service.run
    end
  end

  describe 'light source extraction' do
    let(:mask_path) { image_path }
    let(:thread_result) { { mask_path: mask_path } }
    let(:light_thread) { instance_double('Thread', value: thread_result) }

    before do
      allow(service).to receive(:extract_light_sources).and_call_original
      allow(Sequel).to receive(:pg_jsonb_wrap) { |value| value }
    end

    it 'derives center from L1 squares when percentages are absent' do
      img = Vips::Image.new_from_file(mask_path)
      expected_x = (img.width.to_f / 3.0).round # squares 1 + 2 centroid
      expected_y = (img.height.to_f / 6.0).round

      expect(room).to receive(:update) do |attrs|
        sources = attrs[:detected_light_sources]
        expect(sources.length).to eq(1)
        source = sources.first
        expect(source['type']).to eq('fire')
        expect(source['source_type']).to eq('fire')
        expect(source['center_x']).to be_within(1).of(expected_x)
        expect(source['center_y']).to be_within(1).of(expected_y)
        expect(source['radius_px']).to be >= 20
      end

      service.send(
        :extract_light_sources,
        [{ 'source_type' => 'fire', 'squares' => [1, 2], 'description' => 'hearth fire' }],
        { 'light_fire' => light_thread }
      )
    end

    it 'uses x_pct/y_pct when provided' do
      img = Vips::Image.new_from_file(mask_path)
      expected_x = (img.width * 0.80).round
      expected_y = (img.height * 0.20).round

      expect(room).to receive(:update) do |attrs|
        source = attrs[:detected_light_sources].first
        expect(source['type']).to eq('torch')
        expect(source['center_x']).to be_within(1).of(expected_x)
        expect(source['center_y']).to be_within(1).of(expected_y)
      end

      service.send(
        :extract_light_sources,
        [{ 'source_type' => 'torch', 'x_pct' => 80, 'y_pct' => 20, 'squares' => [9] }],
        { 'light_torch' => light_thread }
      )
    end
  end
end
