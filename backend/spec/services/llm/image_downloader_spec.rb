# frozen_string_literal: true

require 'spec_helper'

RSpec.describe LLM::ImageDownloader do
  describe '.download' do
    let(:image_url) { 'https://example.com/image.png' }
    let(:image_data) { 'fake image data' }
    let(:faraday_connection) { instance_double(Faraday::Connection) }
    let(:faraday_response) { instance_double(Faraday::Response) }

    before do
      allow(CloudStorageService).to receive(:upload).and_return('https://storage.example.com/images/test.png')
      allow(Faraday).to receive(:new).and_return(faraday_connection)
    end

    context 'with valid URL' do
      before do
        allow(faraday_response).to receive(:success?).and_return(true)
        allow(faraday_response).to receive(:body).and_return(image_data)
        allow(faraday_connection).to receive(:get).and_return(faraday_response)
      end

      it 'downloads and stores the image' do
        result = described_class.download(image_url)
        expect(result).to eq('https://storage.example.com/images/test.png')
      end

      it 'calls CloudStorageService with correct params' do
        described_class.download(image_url)
        expect(CloudStorageService).to have_received(:upload)
          .with(image_data, anything, hash_including(content_type: 'image/png'))
      end

      it 'generates storage key with date directory' do
        described_class.download(image_url)
        expect(CloudStorageService).to have_received(:upload) do |_data, key, _opts|
          expect(key).to match(%r{^generated/\d{4}/\d{2}/.+\.png$})
        end
      end
    end

    context 'with request object' do
      let(:request) { double('LLMRequest', id: 12345) }

      before do
        allow(faraday_response).to receive(:success?).and_return(true)
        allow(faraday_response).to receive(:body).and_return(image_data)
        allow(faraday_connection).to receive(:get).and_return(faraday_response)
      end

      it 'includes request id in storage key' do
        described_class.download(image_url, request)
        expect(CloudStorageService).to have_received(:upload) do |_data, key, _opts|
          expect(key).to include('12345')
        end
      end
    end

    context 'with nil or empty URL' do
      it 'returns nil for nil URL' do
        expect(described_class.download(nil)).to be_nil
      end

      it 'returns nil for empty URL' do
        expect(described_class.download('')).to be_nil
      end
    end

    context 'with HTTP error' do
      before do
        allow(faraday_response).to receive(:success?).and_return(false)
        allow(faraday_response).to receive(:status).and_return(404)
        allow(faraday_connection).to receive(:get).and_return(faraday_response)
      end

      it 'returns nil' do
        expect(described_class.download(image_url)).to be_nil
      end
    end

    context 'with file too large' do
      let(:large_data) { 'x' * (GameConfig::LLM::FILE_LIMITS[:max_image_size] + 1) }

      before do
        allow(faraday_response).to receive(:success?).and_return(true)
        allow(faraday_response).to receive(:body).and_return(large_data)
        allow(faraday_connection).to receive(:get).and_return(faraday_response)
      end

      it 'returns nil' do
        expect(described_class.download(image_url)).to be_nil
      end
    end

    context 'with network error' do
      before do
        allow(faraday_connection).to receive(:get).and_raise(Faraday::ConnectionFailed.new('Connection refused'))
      end

      it 'returns nil' do
        expect(described_class.download(image_url)).to be_nil
      end
    end
  end

  describe '.extract_extension' do
    it 'extracts png extension' do
      result = described_class.send(:extract_extension, 'https://example.com/image.png')
      expect(result).to eq('png')
    end

    it 'extracts jpg extension' do
      result = described_class.send(:extract_extension, 'https://example.com/image.jpg')
      expect(result).to eq('jpg')
    end

    it 'normalizes jpeg to jpg' do
      result = described_class.send(:extract_extension, 'https://example.com/image.jpeg')
      expect(result).to eq('jpg')
    end

    it 'extracts webp extension' do
      result = described_class.send(:extract_extension, 'https://example.com/image.webp')
      expect(result).to eq('webp')
    end

    it 'defaults to png for unknown extension' do
      result = described_class.send(:extract_extension, 'https://example.com/image.xyz')
      expect(result).to eq('png')
    end

    it 'defaults to png for no extension' do
      result = described_class.send(:extract_extension, 'https://example.com/image')
      expect(result).to eq('png')
    end

    it 'handles URLs with query strings' do
      result = described_class.send(:extract_extension, 'https://example.com/image.png?token=abc')
      expect(result).to eq('png')
    end
  end

  describe '.detect_content_type' do
    it 'returns image/png for png' do
      result = described_class.send(:detect_content_type, 'https://example.com/image.png')
      expect(result).to eq('image/png')
    end

    it 'returns image/jpeg for jpg' do
      result = described_class.send(:detect_content_type, 'https://example.com/image.jpg')
      expect(result).to eq('image/jpeg')
    end

    it 'returns image/webp for webp' do
      result = described_class.send(:detect_content_type, 'https://example.com/image.webp')
      expect(result).to eq('image/webp')
    end

    it 'returns image/gif for gif' do
      result = described_class.send(:detect_content_type, 'https://example.com/image.gif')
      expect(result).to eq('image/gif')
    end
  end

  describe '.generate_storage_key' do
    it 'includes date directory' do
      result = described_class.send(:generate_storage_key, 'https://example.com/image.png', nil)
      expect(result).to start_with('generated/')
      expect(result).to match(%r{generated/\d{4}/\d{2}/})
    end

    it 'includes request id when provided' do
      request = double('LLMRequest', id: 99)
      result = described_class.send(:generate_storage_key, 'https://example.com/image.png', request)
      expect(result).to include('99')
    end

    it 'includes correct extension' do
      result = described_class.send(:generate_storage_key, 'https://example.com/image.jpg', nil)
      expect(result).to end_with('.jpg')
    end
  end
end
