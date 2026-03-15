# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ReplicateEdgeDetectionService do
  describe '.available?' do
    it 'returns true when Replicate API key is configured' do
      allow(AIProviderService).to receive(:api_key_for).with('replicate').and_return('test-key')
      expect(described_class.available?).to be true
    end

    it 'returns false when API key is nil' do
      allow(AIProviderService).to receive(:api_key_for).with('replicate').and_return(nil)
      expect(described_class.available?).to be false
    end

    it 'returns false when API key is empty' do
      allow(AIProviderService).to receive(:api_key_for).with('replicate').and_return('')
      expect(described_class.available?).to be false
    end
  end

  describe '.detect' do
    let(:image_path) { '/tmp/test_battlemap.png' }
    let(:version_response) do
      instance_double(Faraday::Response, success?: true,
        body: { 'latest_version' => { 'id' => 'abc123' } }.to_json)
    end

    before { described_class.instance_variable_set(:@version_cache, nil) }

    context 'when API key is not configured' do
      before do
        allow(AIProviderService).to receive(:api_key_for).with('replicate').and_return(nil)
        allow(File).to receive(:exist?).with(image_path).and_return(true)
      end

      it 'returns failure without making API call' do
        result = described_class.detect(image_path)
        expect(result[:success]).to be false
        expect(result[:error]).to include('not configured')
      end
    end

    context 'when image file does not exist' do
      before do
        allow(AIProviderService).to receive(:api_key_for).with('replicate').and_return('test-key')
        allow(File).to receive(:exist?).with(image_path).and_return(false)
      end

      it 'returns failure' do
        result = described_class.detect(image_path)
        expect(result[:success]).to be false
        expect(result[:error]).to include('not found')
      end
    end

    context 'when API call succeeds synchronously' do
      let(:edge_map_url) { 'https://replicate.delivery/test/edge_map.png' }
      let(:api_response) do
        {
          'status' => 'succeeded',
          'output' => edge_map_url
        }
      end

      before do
        allow(AIProviderService).to receive(:api_key_for).with('replicate').and_return('test-key')
        allow(File).to receive(:exist?).with(image_path).and_return(true)
        allow(File).to receive(:binread).with(image_path).and_return('fake_png_data')

        conn = instance_double(Faraday::Connection)
        response = instance_double(Faraday::Response, success?: true, body: api_response.to_json)
        allow(Faraday).to receive(:new).and_return(conn)
        allow(conn).to receive(:get).and_return(version_response)
        allow(conn).to receive(:post).and_yield(double(headers: {}, body: nil).tap { |r|
          allow(r).to receive(:headers=)
          allow(r).to receive(:body=)
        }).and_return(response)

        download_response = instance_double(Faraday::Response, success?: true, body: 'edge_png_data')
        allow(Faraday).to receive(:get).with(edge_map_url).and_return(download_response)
        allow(File).to receive(:binwrite)
      end

      it 'returns success with edge_map_path' do
        result = described_class.detect(image_path)
        expect(result[:success]).to be true
        expect(result[:edge_map_path]).to include('_edges')
      end
    end

    context 'when API call fails' do
      before do
        allow(AIProviderService).to receive(:api_key_for).with('replicate').and_return('test-key')
        allow(File).to receive(:exist?).with(image_path).and_return(true)
        allow(File).to receive(:binread).with(image_path).and_return('fake_png_data')

        conn = instance_double(Faraday::Connection)
        response = instance_double(Faraday::Response, success?: false, status: 500, body: 'Server Error')
        allow(Faraday).to receive(:new).and_return(conn)
        allow(conn).to receive(:get).and_return(version_response)
        allow(conn).to receive(:post).and_return(response)
      end

      it 'returns failure with error message' do
        result = described_class.detect(image_path)
        expect(result[:success]).to be false
        expect(result[:error]).to include('500')
      end
    end

    context 'when an exception is raised' do
      before do
        allow(AIProviderService).to receive(:api_key_for).with('replicate').and_return('test-key')
        allow(File).to receive(:exist?).with(image_path).and_return(true)
        allow(File).to receive(:binread).and_raise(StandardError, 'disk error')
      end

      it 'returns failure and does not raise' do
        result = described_class.detect(image_path)
        expect(result[:success]).to be false
        expect(result[:error]).to include('disk error')
      end
    end
  end

  describe '.detect with mode parameter' do
    before do
      allow(AIProviderService).to receive(:api_key_for).with('replicate').and_return(nil)
    end

    it 'accepts mode: :canny' do
      result = described_class.detect('/tmp/test.png', mode: :canny)
      expect(result[:success]).to be false # fails on API key, not on mode
    end

    it 'accepts mode: :hed' do
      result = described_class.detect('/tmp/test.png', mode: :hed)
      expect(result[:success]).to be false
    end
  end
end
