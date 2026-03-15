# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'zip'

RSpec.describe EarthImport::DataDownloader do
  let(:cache_dir) { Dir.mktmpdir('earth_download_test') }
  let(:cache_manager) { EarthImport::CacheManager.new(cache_dir: cache_dir) }
  let(:downloader) { described_class.new(cache_manager: cache_manager) }

  after { FileUtils.rm_rf(cache_dir) }

  describe '#download_file' do
    let(:url) { 'https://example.com/data.zip' }
    let(:filename) { 'data.zip' }

    context 'when file is cached and valid' do
      before do
        cache_manager.store(filename, 'cached content')
      end

      it 'returns cached path without downloading' do
        # Mock HTTP to ensure it's not called
        http_double = instance_double(Net::HTTP)
        allow(Net::HTTP).to receive(:start).and_return(http_double)

        result = downloader.download_file(url, filename)

        expect(result).to eq(cache_manager.cache_path(filename))
        expect(Net::HTTP).not_to have_received(:start)
      end

      it 'reads content from cache' do
        result = downloader.download_file(url, filename)
        expect(File.read(result)).to eq('cached content')
      end
    end

    context 'when file is not cached' do
      let(:response_double) { instance_double(Net::HTTPSuccess, body: 'downloaded content') }

      before do
        allow(response_double).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
        allow(Net::HTTP).to receive(:get_response).and_return(response_double)
      end

      it 'downloads and caches the file' do
        result = downloader.download_file(url, filename)

        expect(result).to eq(cache_manager.cache_path(filename))
        expect(File.read(result)).to eq('downloaded content')
      end

      it 'stores the file with valid checksum' do
        downloader.download_file(url, filename)
        expect(cache_manager.valid_checksum?(filename)).to be true
      end
    end

    context 'when download fails' do
      let(:error_response) { instance_double(Net::HTTPServerError, code: '500') }

      before do
        allow(error_response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)
        allow(Net::HTTP).to receive(:get_response).and_return(error_response)
        # Speed up retries for tests
        stub_const('EarthImport::DataDownloader::RETRY_DELAYS', [0, 0, 0])
      end

      it 'retries up to 3 times then raises' do
        expect { downloader.download_file(url, filename) }
          .to raise_error(EarthImport::DownloadError, /Failed to download/)
        expect(Net::HTTP).to have_received(:get_response).exactly(3).times
      end
    end

    context 'when network error occurs' do
      before do
        allow(Net::HTTP).to receive(:get_response).and_raise(SocketError.new('Connection refused'))
        stub_const('EarthImport::DataDownloader::RETRY_DELAYS', [0, 0, 0])
      end

      it 'retries and raises DownloadError' do
        expect { downloader.download_file(url, filename) }
          .to raise_error(EarthImport::DownloadError, /Connection refused/)
      end
    end

    context 'when cache is expired' do
      before do
        # Store file then make it expired
        cache_manager.store(filename, 'old content')
        path = cache_manager.cache_path(filename)
        FileUtils.touch(path, mtime: Time.now - (31 * 24 * 60 * 60))

        # Mock fresh download
        response_double = instance_double(Net::HTTPSuccess, body: 'fresh content')
        allow(response_double).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
        allow(Net::HTTP).to receive(:get_response).and_return(response_double)
      end

      it 'downloads fresh content' do
        result = downloader.download_file(url, filename)
        expect(File.read(result)).to eq('fresh content')
      end
    end
  end

  describe '#download_and_extract' do
    let(:url) { 'https://example.com/test.zip' }
    let(:prefix) { 'test_data' }

    context 'with valid zip file' do
      before do
        zip_content = create_mock_zip('data.txt' => 'test content')
        response_double = instance_double(Net::HTTPSuccess, body: zip_content)
        allow(response_double).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
        allow(Net::HTTP).to receive(:get_response).and_return(response_double)
      end

      it 'extracts zip contents to subdirectory' do
        result = downloader.send(:download_and_extract, url, prefix)

        expect(Dir.exist?(result)).to be true
        expect(File.exist?(File.join(result, 'data.txt'))).to be true
        expect(File.read(File.join(result, 'data.txt'))).to eq('test content')
      end

      it 'returns the extraction directory path' do
        result = downloader.send(:download_and_extract, url, prefix)
        expect(result).to eq(File.join(cache_dir, prefix))
      end
    end

    context 'with nested zip structure' do
      before do
        zip_content = create_mock_zip('subdir/nested.txt' => 'nested content')
        response_double = instance_double(Net::HTTPSuccess, body: zip_content)
        allow(response_double).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
        allow(Net::HTTP).to receive(:get_response).and_return(response_double)
      end

      it 'preserves directory structure' do
        result = downloader.send(:download_and_extract, url, prefix)

        nested_path = File.join(result, 'subdir', 'nested.txt')
        expect(File.exist?(nested_path)).to be true
        expect(File.read(nested_path)).to eq('nested content')
      end
    end
  end

  describe '#download_natural_earth' do
    before do
      # Mock all Natural Earth downloads
      zip_content = create_mock_zip('shapefile.shp' => 'shape data')
      response_double = instance_double(Net::HTTPSuccess, body: zip_content)
      allow(response_double).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow(Net::HTTP).to receive(:get_response).and_return(response_double)
    end

    it 'returns hash with all expected keys' do
      result = downloader.download_natural_earth

      expect(result).to be_a(Hash)
      expect(result.keys).to include(:coastlines, :lakes, :land, :land_cover)
    end

    it 'extracts files for each dataset' do
      result = downloader.download_natural_earth

      result.each_value do |path|
        expect(Dir.exist?(path)).to be true
      end
    end
  end

  describe '#download_hydrosheds' do
    before do
      zip_content = create_mock_zip('rivers.shp' => 'river data')
      response_double = instance_double(Net::HTTPSuccess, body: zip_content)
      allow(response_double).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow(Net::HTTP).to receive(:get_response).and_return(response_double)
    end

    it 'returns hash with rivers key' do
      result = downloader.download_hydrosheds

      expect(result).to be_a(Hash)
      expect(result).to include(:rivers)
    end

    it 'extracts river data' do
      result = downloader.download_hydrosheds

      expect(Dir.exist?(result[:rivers])).to be true
    end
  end

  describe 'URL constants' do
    it 'defines Natural Earth URLs' do
      urls = described_class::NATURAL_EARTH_URLS

      expect(urls[:coastlines]).to include('naciscdn.org')
      expect(urls[:lakes]).to include('naciscdn.org')
      expect(urls[:land]).to include('naciscdn.org')
      expect(urls[:land_cover]).to include('naciscdn.org')
    end

    it 'defines HydroSHEDS URL' do
      url = described_class::HYDROSHEDS_URL
      expect(url).to include('hydrosheds.org')
    end
  end

  describe 'initialization' do
    it 'accepts custom cache manager' do
      custom_manager = EarthImport::CacheManager.new(cache_dir: cache_dir)
      downloader = described_class.new(cache_manager: custom_manager)
      expect(downloader.cache_manager).to eq(custom_manager)
    end

    it 'creates default cache manager when none provided' do
      downloader = described_class.new
      expect(downloader.cache_manager).to be_a(EarthImport::CacheManager)
    end
  end

  # Helper to create minimal zip file with specified contents
  def create_mock_zip(files = {})
    buffer = StringIO.new
    Zip::OutputStream.write_buffer(buffer) do |zos|
      files.each do |filename, content|
        zos.put_next_entry(filename)
        zos.write(content)
      end
    end
    buffer.rewind
    buffer.read
  end
end
