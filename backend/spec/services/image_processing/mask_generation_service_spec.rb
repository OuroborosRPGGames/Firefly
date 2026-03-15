# frozen_string_literal: true

require 'spec_helper'
require 'chunky_png'

RSpec.describe MaskGenerationService do
  let(:room) { create(:room) }

  describe '.available?' do
    it 'returns true when Replicate API key is configured' do
      allow(AIProviderService).to receive(:api_key_for).with('replicate').and_return('r8_test_key')
      expect(described_class.available?).to be true
    end

    it 'returns false when Replicate API key is missing' do
      allow(AIProviderService).to receive(:api_key_for).with('replicate').and_return(nil)
      expect(described_class.available?).to be false
    end
  end

  describe '.generate' do
    context 'when room has no background image' do
      before { allow(room).to receive(:default_background_url).and_return(nil) }

      it 'returns error' do
        result = described_class.generate(room)
        expect(result[:success]).to be false
        expect(result[:error]).to include('No background image')
      end
    end

    context 'when room has an empty background image' do
      before { allow(room).to receive(:default_background_url).and_return('') }

      it 'returns error' do
        result = described_class.generate(room)
        expect(result[:success]).to be false
        expect(result[:error]).to include('No background image')
      end
    end

    context 'when Replicate API key is not configured' do
      before do
        allow(room).to receive(:default_background_url).and_return('/uploads/generated/bg.png')
        allow(AIProviderService).to receive(:api_key_for).with('replicate').and_return(nil)
      end

      it 'returns error' do
        result = described_class.generate(room)
        expect(result[:success]).to be false
        expect(result[:error]).to include('Replicate API key not configured')
      end
    end

    context 'when background image cannot be loaded' do
      before do
        allow(room).to receive(:default_background_url).and_return('/uploads/nonexistent.png')
        allow(AIProviderService).to receive(:api_key_for).with('replicate').and_return('r8_test')
      end

      it 'returns error' do
        result = described_class.generate(room)
        expect(result[:success]).to be false
        expect(result[:error]).to include('Could not load background image')
      end
    end

    context 'when segmentation succeeds' do
      let(:service) { described_class.new(room) }

      before do
        allow(room).to receive(:default_background_url).and_return('/uploads/generated/bg.png')
        allow(room).to receive(:id).and_return(1)
        allow(room).to receive(:update)
        allow(AIProviderService).to receive(:api_key_for).with('replicate').and_return('r8_test')

        allow(described_class).to receive(:new).and_return(service)
        allow(service).to receive(:load_image_as_data_uri).and_return('data:image/png;base64,abc')

        # Stub segmentation to return sky + house
        allow(service).to receive(:run_segmentation).and_return(
          success: true,
          segment_url: 'https://replicate.delivery/seg.png',
          objects: [
            { 'label' => 'sky', 'color' => [80, 50, 50] },
            { 'label' => 'house', 'color' => [9, 7, 230] }
          ]
        )

        # Create a small segmentation map with sky (top) and house (bottom)
        seg_img = ChunkyPNG::Image.new(4, 4)
        2.times { |y| 4.times { |x| seg_img[x, y] = ChunkyPNG::Color.rgb(80, 50, 50) } }   # sky
        2.times { |y| 4.times { |x| seg_img[x, y + 2] = ChunkyPNG::Color.rgb(9, 7, 230) } } # house
        seg_blob = seg_img.to_blob

        seg_response = instance_double(Faraday::Response, success?: true, body: seg_blob)
        allow(Faraday).to receive(:new).and_wrap_original do |method, *args, &block|
          conn = method.call(*args, &block)
          allow(conn).to receive(:get).and_return(seg_response)
          conn
        end

        allow(CloudStorageService).to receive(:upload).and_return('/uploads/masks/2026/02/abc.png')
      end

      it 'generates mask, uploads, and updates room' do
        result = described_class.generate(room)
        expect(result[:success]).to be true
        expect(result[:mask_url]).to eq('/uploads/masks/2026/02/abc.png')
        expect(room).to have_received(:update).with(mask_url: '/uploads/masks/2026/02/abc.png')
      end

      it 'uploads mask via CloudStorageService' do
        described_class.generate(room)
        expect(CloudStorageService).to have_received(:upload).with(
          kind_of(String),
          match(%r{^masks/\d{4}/\d{2}/[a-f0-9]+\.png$}),
          content_type: 'image/png'
        )
      end
    end

    context 'when no relevant regions detected' do
      let(:service) { described_class.new(room) }

      before do
        allow(room).to receive(:default_background_url).and_return('/uploads/generated/bg.png')
        allow(room).to receive(:id).and_return(1)
        allow(AIProviderService).to receive(:api_key_for).with('replicate').and_return('r8_test')

        allow(described_class).to receive(:new).and_return(service)
        allow(service).to receive(:load_image_as_data_uri).and_return('data:image/png;base64,abc')

        # Only detect irrelevant labels (e.g., earth, grass)
        allow(service).to receive(:run_segmentation).and_return(
          success: true,
          segment_url: 'https://replicate.delivery/seg.png',
          objects: [
            { 'label' => 'grass', 'color' => [0, 255, 0] },
            { 'label' => 'earth', 'color' => [100, 50, 0] }
          ]
        )
      end

      it 'returns error' do
        result = described_class.generate(room)
        expect(result[:success]).to be false
        expect(result[:error]).to include('No relevant regions')
      end
    end

    context 'when segmentation API fails' do
      let(:service) { described_class.new(room) }

      before do
        allow(room).to receive(:default_background_url).and_return('/uploads/generated/bg.png')
        allow(room).to receive(:id).and_return(1)
        allow(AIProviderService).to receive(:api_key_for).with('replicate').and_return('r8_test')

        allow(described_class).to receive(:new).and_return(service)
        allow(service).to receive(:load_image_as_data_uri).and_return('data:image/png;base64,abc')
        allow(service).to receive(:run_segmentation).and_return(
          success: false, error: 'Model failed'
        )
      end

      it 'returns error' do
        result = described_class.generate(room)
        expect(result[:success]).to be false
        expect(result[:error]).to include('Model failed')
      end
    end
  end

  describe '#build_channel_map' do
    let(:service) { described_class.new(room) }

    it 'maps sky to red channel' do
      objects = [{ 'label' => 'sky', 'color' => [80, 50, 50] }]
      map = service.send(:build_channel_map, objects)
      expect(map[[80, 50, 50]]).to eq(:red)
    end

    it 'maps window to green channel' do
      objects = [{ 'label' => 'window', 'color' => [100, 200, 255] }]
      map = service.send(:build_channel_map, objects)
      expect(map[[100, 200, 255]]).to eq(:green)
    end

    it 'maps house to blue channel' do
      objects = [{ 'label' => 'house', 'color' => [9, 7, 230] }]
      map = service.send(:build_channel_map, objects)
      expect(map[[9, 7, 230]]).to eq(:blue)
    end

    it 'ignores unrecognized labels' do
      objects = [{ 'label' => 'grass', 'color' => [0, 255, 0] }]
      map = service.send(:build_channel_map, objects)
      expect(map).to be_empty
    end

    it 'handles multiple objects' do
      objects = [
        { 'label' => 'sky', 'color' => [80, 50, 50] },
        { 'label' => 'window', 'color' => [100, 200, 255] },
        { 'label' => 'house', 'color' => [9, 7, 230] },
        { 'label' => 'tree', 'color' => [120, 120, 80] }
      ]
      map = service.send(:build_channel_map, objects)
      expect(map.size).to eq(3) # sky, window, house — not tree
    end
  end
end
