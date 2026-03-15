# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ReplicateClientHelper do
  let(:dummy_class) do
    Class.new do
      extend ReplicateClientHelper
    end
  end

  describe '.replicate_api_key_configured?' do
    it 'returns true when key is present' do
      allow(AIProviderService).to receive(:api_key_for).with('replicate').and_return('token')
      expect(dummy_class.send(:replicate_api_key_configured?)).to be true
    end

    it 'returns false when key is nil' do
      allow(AIProviderService).to receive(:api_key_for).with('replicate').and_return(nil)
      expect(dummy_class.send(:replicate_api_key_configured?)).to be false
    end
  end

  describe '.detect_mime_type' do
    it 'detects png/jpg/webp and defaults to png' do
      expect(dummy_class.send(:detect_mime_type, '/tmp/a.png')).to eq('image/png')
      expect(dummy_class.send(:detect_mime_type, '/tmp/a.jpg?x=1')).to eq('image/jpeg')
      expect(dummy_class.send(:detect_mime_type, '/tmp/a.webp')).to eq('image/webp')
      expect(dummy_class.send(:detect_mime_type, '/tmp/a.bmp')).to eq('image/png')
    end
  end

  describe '.resolve_model_version' do
    let(:conn) { instance_double(Faraday::Connection) }

    before do
      dummy_class.instance_variable_set(:@version_cache, nil)
    end

    it 'returns latest version id and caches it' do
      response = instance_double(Faraday::Response, success?: true, body: { 'latest_version' => { 'id' => 'ver_123' } }.to_json)
      allow(conn).to receive(:get).with('models/meta/sam-2').and_return(response)

      first = dummy_class.send(:resolve_model_version, conn, 'meta/sam-2')
      second = dummy_class.send(:resolve_model_version, conn, 'meta/sam-2')

      expect(first).to eq('ver_123')
      expect(second).to eq('ver_123')
      expect(conn).to have_received(:get).once
    end

    it 'returns nil when model lookup is unsuccessful' do
      response = instance_double(Faraday::Response, success?: false)
      allow(conn).to receive(:get).and_return(response)

      expect(dummy_class.send(:resolve_model_version, conn, 'meta/sam-2')).to be_nil
    end

    it 'returns nil when request raises' do
      allow(conn).to receive(:get).and_raise(StandardError, 'boom')
      expect(dummy_class.send(:resolve_model_version, conn, 'meta/sam-2')).to be_nil
    end
  end

  describe '.handle_prediction_result' do
    it 'dispatches succeeded status to downloader' do
      downloader = ->(output, path) { { success: true, output: output, path: path } }
      poller = ->(_url, _key, _path) { { success: false } }

      result = dummy_class.send(
        :handle_prediction_result,
        result: { 'status' => 'succeeded', 'output' => 'https://cdn/file.png' },
        api_key: 'k',
        original_path: '/tmp/src.png',
        failed_prefix: 'Prediction failed',
        poller: poller,
        downloader: downloader
      )

      expect(result).to eq(success: true, output: 'https://cdn/file.png', path: '/tmp/src.png')
    end

    it 'dispatches processing status to poller' do
      downloader = ->(_output, _path) { { success: false } }
      poller = ->(url, key, path) { { success: true, polled: [url, key, path] } }

      result = dummy_class.send(
        :handle_prediction_result,
        result: { 'status' => 'processing', 'urls' => { 'get' => 'https://api.replicate/p/1' } },
        api_key: 'k',
        original_path: '/tmp/src.png',
        failed_prefix: 'Prediction failed',
        poller: poller,
        downloader: downloader
      )

      expect(result).to eq(success: true, polled: ['https://api.replicate/p/1', 'k', '/tmp/src.png'])
    end

    it 'returns prefixed failed error' do
      result = dummy_class.send(
        :handle_prediction_result,
        result: { 'status' => 'failed', 'error' => 'bad request' },
        api_key: 'k',
        original_path: '/tmp/src.png',
        failed_prefix: 'Prediction failed',
        poller: ->(*_) { nil },
        downloader: ->(*_) { nil }
      )

      expect(result).to eq(success: false, error: 'Prediction failed: bad request')
    end

    it 'returns unexpected status error' do
      result = dummy_class.send(
        :handle_prediction_result,
        result: { 'status' => 'mystery' },
        api_key: 'k',
        original_path: '/tmp/src.png',
        failed_prefix: 'Prediction failed',
        poller: ->(*_) { nil },
        downloader: ->(*_) { nil }
      )

      expect(result).to eq(success: false, error: 'Unexpected status: mystery')
    end
  end

  describe '.poll_prediction' do
    let(:conn) { instance_double(Faraday::Connection) }

    it 'returns error when status URL is missing' do
      result = dummy_class.send(
        :poll_prediction,
        status_url: nil,
        api_key: 'k',
        max_attempts: 2,
        poll_interval: 0,
        timeout_error: 'timeout',
        on_success: ->(_r) { { success: true } }
      )

      expect(result).to eq(success: false, error: 'No status URL for polling')
    end

    it 'returns success when polling reaches succeeded' do
      allow(dummy_class).to receive(:build_connection).and_return(conn)
      allow(dummy_class).to receive(:sleep)

      responses = [
        instance_double(Faraday::Response, body: { 'status' => 'processing' }.to_json),
        instance_double(Faraday::Response, body: { 'status' => 'succeeded', 'output' => 'ok' }.to_json)
      ]
      allow(conn).to receive(:get).and_return(*responses)

      result = dummy_class.send(
        :poll_prediction,
        status_url: 'https://api.replicate/p/1',
        api_key: 'k',
        max_attempts: 3,
        poll_interval: 0,
        timeout_error: 'timeout',
        on_success: ->(r) { { success: true, output: r['output'] } }
      )

      expect(result).to eq(success: true, output: 'ok')
    end

    it 'uses on_failed callback when status is failed' do
      allow(dummy_class).to receive(:build_connection).and_return(conn)
      allow(dummy_class).to receive(:sleep)
      allow(conn).to receive(:get).and_return(instance_double(Faraday::Response, body: { 'status' => 'failed', 'error' => 'bad' }.to_json))

      result = dummy_class.send(
        :poll_prediction,
        status_url: 'https://api.replicate/p/1',
        api_key: 'k',
        max_attempts: 1,
        poll_interval: 0,
        timeout_error: 'timeout',
        on_success: ->(_r) { { success: true } },
        on_failed: ->(r) { { success: false, err: r['error'] } }
      )

      expect(result).to eq(success: false, err: 'bad')
    end

    it 'returns timeout error when attempts are exhausted' do
      allow(dummy_class).to receive(:build_connection).and_return(conn)
      allow(dummy_class).to receive(:sleep)
      allow(conn).to receive(:get).and_return(instance_double(Faraday::Response, body: { 'status' => 'processing' }.to_json))

      result = dummy_class.send(
        :poll_prediction,
        status_url: 'https://api.replicate/p/1',
        api_key: 'k',
        max_attempts: 2,
        poll_interval: 0,
        timeout_error: 'timed out',
        on_success: ->(_r) { { success: true } }
      )

      expect(result).to eq(success: false, error: 'timed out')
    end

    it 'returns polling error when an exception is raised' do
      allow(dummy_class).to receive(:build_connection).and_raise(StandardError, 'net down')

      result = dummy_class.send(
        :poll_prediction,
        status_url: 'https://api.replicate/p/1',
        api_key: 'k',
        max_attempts: 1,
        poll_interval: 0,
        timeout_error: 'timed out',
        on_success: ->(_r) { { success: true } }
      )

      expect(result).to eq(success: false, error: 'Polling error: net down')
    end
  end

  describe '.inferred_replicate_timeout' do
    it 'uses class SYNC_TIMEOUT + 10 when present' do
      with_timeout_class = Class.new do
        extend ReplicateClientHelper
      end
      with_timeout_class.const_set(:SYNC_TIMEOUT, 45)

      expect(with_timeout_class.send(:inferred_replicate_timeout)).to eq(55)
    end

    it 'uses default 70 when SYNC_TIMEOUT is absent' do
      no_timeout_class = Class.new do
        extend ReplicateClientHelper
      end

      expect(no_timeout_class.send(:inferred_replicate_timeout)).to eq(70)
    end
  end
end
