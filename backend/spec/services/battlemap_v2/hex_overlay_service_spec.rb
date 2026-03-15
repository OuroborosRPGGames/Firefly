# frozen_string_literal: true

require 'spec_helper'

RSpec.describe BattlemapV2::HexOverlayService do
  let(:room) { instance_double('Room', min_x: 0, max_x: 40, min_y: 0, max_y: 40, id: 999) }
  let(:image_path) { 'spec/fixtures/test_battlemap.png' }
  let(:service) { described_class.new(room: room, image_path: image_path) }

  describe '#classify_hexes' do
    it 'returns an array of hex data hashes' do
      allow(service).to receive(:generate_hex_coordinates).and_return([[0, 0], [1, 2]])
      allow(service).to receive(:build_hex_pixel_map).and_return({
        hex_size: 20,
        '0,0' => { hx: 0, hy: 0, px: 10, py: 10 },
        '1,2' => { hx: 1, hy: 2, px: 30, py: 30 }
      })
      allow_any_instance_of(Vips::Image).to receive(:width).and_return(100)
      allow_any_instance_of(Vips::Image).to receive(:height).and_return(100)

      hex_data = service.classify_hexes(object_masks: {})
      expect(hex_data).to be_an(Array)
      expect(hex_data).not_to be_empty
      expect(hex_data.first).to include(:x, :y, :hex_type)
    end

    it 'starts all hexes as normal (floor) type' do
      allow(service).to receive(:generate_hex_coordinates).and_return([[0, 0]])
      allow(service).to receive(:build_hex_pixel_map).and_return({
        hex_size: 20,
        '0,0' => { hx: 0, hy: 0, px: 10, py: 10 }
      })
      allow_any_instance_of(Vips::Image).to receive(:width).and_return(100)
      allow_any_instance_of(Vips::Image).to receive(:height).and_return(100)

      hex_data = service.classify_hexes(object_masks: {})
      expect(hex_data.map { |h| h[:hex_type] }).to all(eq('normal'))
    end
  end
end
