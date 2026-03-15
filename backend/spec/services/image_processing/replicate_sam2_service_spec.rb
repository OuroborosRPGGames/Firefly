# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'tempfile'

RSpec.describe ReplicateSam2Service do
  let(:conn) { instance_double(Faraday::Connection) }
  let(:request_obj) { Struct.new(:headers, :body).new({}, nil) }

  describe '.available?' do
    it 'returns false when API key is not configured' do
      allow(AIProviderService).to receive(:api_key_for).with('replicate').and_return(nil)
      expect(described_class.available?).to be false
    end

    it 'returns true when API key is configured' do
      allow(AIProviderService).to receive(:api_key_for).with('replicate').and_return('token')
      expect(described_class.available?).to be true
    end
  end

  describe '.auto_segment' do
    it 'returns error when image file is missing' do
      result = described_class.auto_segment('/no/such/file.png', masks_dir: '/tmp/masks')
      expect(result[:success]).to be false
      expect(result[:error]).to include('not found')
    end

    it 'returns error when API key is missing' do
      Tempfile.create(['sam2', '.png']) do |f|
        allow(AIProviderService).to receive(:api_key_for).with('replicate').and_return(nil)

        result = described_class.auto_segment(f.path, masks_dir: '/tmp/masks')

        expect(result[:success]).to be false
        expect(result[:error]).to include('not configured')
      end
    end

    it 'returns error when model version cannot be resolved' do
      Tempfile.create(['sam2', '.png']) do |f|
        allow(AIProviderService).to receive(:api_key_for).with('replicate').and_return('api-key')
        allow(described_class).to receive(:build_connection).and_return(conn)
        allow(described_class).to receive(:resolve_model_version).with(conn, described_class::MODEL).and_return(nil)

        result = described_class.auto_segment(f.path, masks_dir: '/tmp/masks')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Could not resolve')
      end
    end

    it 'submits prediction and handles succeeded response' do
      Tempfile.create(['sam2', '.png']) do |f|
        allow(AIProviderService).to receive(:api_key_for).with('replicate').and_return('api-key')
        allow(described_class).to receive(:build_connection).and_return(conn)
        allow(described_class).to receive(:resolve_model_version).with(conn, described_class::MODEL).and_return('ver_123')

        response = instance_double(
          Faraday::Response,
          success?: true,
          body: {
            'status' => 'succeeded',
            'output' => { 'individual_masks' => %w[https://mask-1 https://mask-2] }
          }.to_json
        )
        allow(conn).to receive(:post).with('predictions').and_yield(request_obj).and_return(response)
        allow(described_class).to receive(:download_masks).with(%w[https://mask-1 https://mask-2], '/tmp/masks')
                                                     .and_return({ success: true, masks_dir: '/tmp/masks', mask_count: 2 })

        result = described_class.auto_segment(f.path, masks_dir: '/tmp/masks', points_per_side: 32)

        expect(result[:success]).to be true
        expect(result[:mask_count]).to eq(2)
        expect(request_obj.headers['Prefer']).to eq('wait=60')
        expect(request_obj.body[:version]).to eq('ver_123')
        expect(request_obj.body[:input]).to include(points_per_side: 32)
      end
    end

    it 'polls for async prediction when status is processing' do
      Tempfile.create(['sam2', '.png']) do |f|
        allow(AIProviderService).to receive(:api_key_for).with('replicate').and_return('api-key')
        allow(described_class).to receive(:build_connection).and_return(conn)
        allow(described_class).to receive(:resolve_model_version).with(conn, described_class::MODEL).and_return('ver_123')

        response = instance_double(
          Faraday::Response,
          success?: true,
          body: {
            'status' => 'processing',
            'urls' => { 'get' => 'https://api.replicate.com/v1/predictions/abc' }
          }.to_json
        )
        allow(conn).to receive(:post).and_yield(request_obj).and_return(response)
        allow(described_class).to receive(:poll_prediction).and_return(
          { success: true, masks_dir: '/tmp/masks', mask_count: 3 }
        )

        result = described_class.auto_segment(f.path, masks_dir: '/tmp/masks')

        expect(result[:success]).to be true
        expect(result[:mask_count]).to eq(3)
        expect(described_class).to have_received(:poll_prediction).with(
          hash_including(
            status_url: 'https://api.replicate.com/v1/predictions/abc',
            api_key: 'api-key',
            max_attempts: described_class::MAX_POLL_ATTEMPTS,
            poll_interval: described_class::POLL_INTERVAL,
            on_success: kind_of(Proc),
            on_failed: kind_of(Proc),
            on_canceled: kind_of(Proc)
          )
        )
      end
    end

    it 'returns failed status from prediction response' do
      Tempfile.create(['sam2', '.png']) do |f|
        allow(AIProviderService).to receive(:api_key_for).with('replicate').and_return('api-key')
        allow(described_class).to receive(:build_connection).and_return(conn)
        allow(described_class).to receive(:resolve_model_version).with(conn, described_class::MODEL).and_return('ver_123')

        response = instance_double(Faraday::Response, success?: true, body: { 'status' => 'failed', 'error' => 'bad input' }.to_json)
        allow(conn).to receive(:post).and_yield(request_obj).and_return(response)

        result = described_class.auto_segment(f.path, masks_dir: '/tmp/masks')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Prediction failed: bad input')
      end
    end

    it 'returns API status/body when prediction request fails' do
      Tempfile.create(['sam2', '.png']) do |f|
        allow(AIProviderService).to receive(:api_key_for).with('replicate').and_return('api-key')
        allow(described_class).to receive(:build_connection).and_return(conn)
        allow(described_class).to receive(:resolve_model_version).with(conn, described_class::MODEL).and_return('ver_123')

        response = instance_double(Faraday::Response, success?: false, status: 500, body: 'replicate server error')
        allow(conn).to receive(:post).and_yield(request_obj).and_return(response)

        result = described_class.auto_segment(f.path, masks_dir: '/tmp/masks')

        expect(result[:success]).to be false
        expect(result[:error]).to include('500')
        expect(result[:error]).to include('replicate server error')
      end
    end

    it 'returns rescued error message on unexpected exception' do
      Tempfile.create(['sam2', '.png']) do |f|
        allow(AIProviderService).to receive(:api_key_for).with('replicate').and_return('api-key')
        allow(described_class).to receive(:build_connection).and_raise(StandardError, 'connection exploded')

        result = described_class.auto_segment(f.path, masks_dir: '/tmp/masks')

        expect(result[:success]).to be false
        expect(result[:error]).to include('connection exploded')
      end
    end
  end

  describe '.download_masks (private)' do
    it 'returns error when no mask urls were provided' do
      result = described_class.send(:download_masks, [], '/tmp/masks')
      expect(result[:success]).to be false
      expect(result[:error]).to include('No individual_masks')
    end

    it 'downloads masks and returns saved count' do
      Dir.mktmpdir do |dir|
        ok = instance_double(Faraday::Response, success?: true, body: 'png-bytes')
        allow(Faraday).to receive(:get).and_return(ok)

        result = described_class.send(:download_masks, %w[u1 u2], dir)

        expect(result[:success]).to be true
        expect(result[:mask_count]).to eq(2)
        expect(File.exist?(File.join(dir, 'mask_0000.png'))).to be true
        expect(File.exist?(File.join(dir, 'mask_0001.png'))).to be true
      end
    end
  end
end
