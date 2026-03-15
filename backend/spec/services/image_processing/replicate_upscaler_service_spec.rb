# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ReplicateUpscalerService do
  let(:image_path) { '/tmp/test_map.png' }

  before do
    described_class.instance_variable_set(:@version_cache, nil)
  end

  describe '.available?' do
    it 'returns true when key is present' do
      allow(AIProviderService).to receive(:api_key_for).with('replicate').and_return('token')

      expect(described_class.available?).to be true
    end

    it 'returns false when key is missing' do
      allow(AIProviderService).to receive(:api_key_for).with('replicate').and_return(nil)

      expect(described_class.available?).to be false
    end
  end

  describe '.upscale' do
    let(:connection) { instance_double(Faraday::Connection) }
    let(:request_obj) { Struct.new(:headers, :body).new({}, nil) }
    let(:model_response) do
      instance_double(Faraday::Response, success?: true, body: { 'latest_version' => { 'id' => 'ver_123' } }.to_json)
    end

    before do
      allow(AIProviderService).to receive(:api_key_for).with('replicate').and_return('api-key')
      allow(File).to receive(:exist?).with(image_path).and_return(true)
      allow(File).to receive(:binread).with(image_path).and_return('png-data')
      allow(Faraday).to receive(:new).and_return(connection)
      allow(connection).to receive(:get).with('models/nightmareai/real-esrgan').and_return(model_response)
    end

    it 'returns error when source image is missing' do
      allow(File).to receive(:exist?).with(image_path).and_return(false)

      result = described_class.upscale(image_path)

      expect(result[:success]).to be false
      expect(result[:error]).to include('not found')
    end

    it 'returns error when api key is missing' do
      allow(AIProviderService).to receive(:api_key_for).with('replicate').and_return(nil)

      result = described_class.upscale(image_path)

      expect(result[:success]).to be false
      expect(result[:error]).to include('not configured')
    end

    it 'downloads output for succeeded prediction' do
      prediction = instance_double(
        Faraday::Response,
        success?: true,
        body: { 'status' => 'succeeded', 'output' => 'https://cdn.example/upscaled.png' }.to_json
      )
      download = instance_double(Faraday::Response, success?: true, body: 'upscaled-binary')

      allow(connection).to receive(:post).with('predictions').and_yield(request_obj).and_return(prediction)
      allow(Faraday).to receive(:get).with('https://cdn.example/upscaled.png').and_return(download)
      allow(File).to receive(:binwrite)

      result = described_class.upscale(image_path, scale: 4, model_key: :esrgan)

      expect(result[:success]).to be true
      expect(result[:output_path]).to eq('/tmp/test_map_upscaled.png')
      expect(File).to have_received(:binwrite).with('/tmp/test_map_upscaled.png', 'upscaled-binary')
      expect(request_obj.headers['Prefer']).to eq('wait=60')
      expect(request_obj.body[:version]).to eq('ver_123')
      expect(request_obj.body[:input]).to include(scale: 4, face_enhance: false)
    end

    it 'returns failed prediction error' do
      prediction = instance_double(
        Faraday::Response,
        success?: true,
        body: { 'status' => 'failed', 'error' => 'invalid image' }.to_json
      )
      allow(connection).to receive(:post).and_yield(request_obj).and_return(prediction)

      result = described_class.upscale(image_path)

      expect(result[:success]).to be false
      expect(result[:error]).to include('prediction failed')
    end

    it 'returns API status/body when prediction request fails' do
      prediction = instance_double(Faraday::Response, success?: false, status: 500, body: 'Server error')
      allow(connection).to receive(:post).and_yield(request_obj).and_return(prediction)

      result = described_class.upscale(image_path)

      expect(result[:success]).to be false
      expect(result[:error]).to include('500')
      expect(result[:error]).to include('Server error')
    end

    it 'polls when prediction is still processing' do
      prediction = instance_double(
        Faraday::Response,
        success?: true,
        body: {
          'status' => 'processing',
          'urls' => { 'get' => 'https://api.replicate.com/v1/predictions/abc' }
        }.to_json
      )

      allow(connection).to receive(:post).and_yield(request_obj).and_return(prediction)
      allow(described_class).to receive(:poll_for_result).with('https://api.replicate.com/v1/predictions/abc', 'api-key', image_path)
                                                .and_return({ success: true, output_path: '/tmp/async_upscaled.png' })

      result = described_class.upscale(image_path)

      expect(result[:success]).to be true
      expect(result[:output_path]).to eq('/tmp/async_upscaled.png')
    end

    it 'falls back to esrgan model for unknown model keys' do
      prediction = instance_double(
        Faraday::Response,
        success?: true,
        body: { 'status' => 'failed', 'error' => 'test' }.to_json
      )
      allow(connection).to receive(:post).and_yield(request_obj).and_return(prediction)

      described_class.upscale(image_path, model_key: :unknown_model)

      expect(connection).to have_received(:get).with('models/nightmareai/real-esrgan')
    end

    it 'uses model-specific input fields and clamps scale for crystal model' do
      allow(connection).to receive(:get).with('models/philz1337x/crystal-upscaler').and_return(model_response)

      prediction = instance_double(
        Faraday::Response,
        success?: true,
        body: { 'status' => 'failed', 'error' => 'test' }.to_json
      )
      allow(connection).to receive(:post).and_yield(request_obj).and_return(prediction)

      described_class.upscale(image_path, scale: 99, model_key: :crystal)

      expect(request_obj.body[:input]).to include(scale_factor: 4, output_format: 'png')
    end
  end

  describe 'private helpers' do
    it 'detects mime type from image extension' do
      expect(described_class.send(:detect_mime_type, '/tmp/a.png')).to eq('image/png')
      expect(described_class.send(:detect_mime_type, '/tmp/a.jpg')).to eq('image/jpeg')
      expect(described_class.send(:detect_mime_type, '/tmp/a.jpeg')).to eq('image/jpeg')
      expect(described_class.send(:detect_mime_type, '/tmp/a.webp')).to eq('image/webp')
      expect(described_class.send(:detect_mime_type, '/tmp/a.bmp')).to eq('image/png')
    end

    it 'returns error when download has no output URL' do
      result = described_class.send(:download_result, nil, '/tmp/source.png')

      expect(result[:success]).to be false
      expect(result[:error]).to include('No output URL')
    end
  end
end
