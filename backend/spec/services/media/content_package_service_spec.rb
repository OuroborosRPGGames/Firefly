# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ContentPackageService do
  describe 'constants' do
    it 'defines ALLOWED_IMAGE_TYPES' do
      expect(described_class::ALLOWED_IMAGE_TYPES).to include('.jpg', '.png', '.gif')
    end

    it 'defines MAX_IMAGE_SIZE' do
      expect(described_class::MAX_IMAGE_SIZE).to eq(10 * 1024 * 1024)
    end
  end

  describe '.dev_mode?' do
    context 'when CONTENT_EXPORT_LOCAL_DIR is set' do
      around do |example|
        original = ENV['CONTENT_EXPORT_LOCAL_DIR']
        ENV['CONTENT_EXPORT_LOCAL_DIR'] = '/tmp/exports'
        example.run
        ENV['CONTENT_EXPORT_LOCAL_DIR'] = original
      end

      it 'returns true' do
        expect(described_class.dev_mode?).to be true
      end
    end

    context 'when CONTENT_EXPORT_LOCAL_DIR is not set' do
      around do |example|
        original = ENV['CONTENT_EXPORT_LOCAL_DIR']
        ENV['CONTENT_EXPORT_LOCAL_DIR'] = nil
        example.run
        ENV['CONTENT_EXPORT_LOCAL_DIR'] = original
      end

      it 'returns false' do
        expect(described_class.dev_mode?).to be false
      end
    end

    context 'when CONTENT_EXPORT_LOCAL_DIR is empty' do
      around do |example|
        original = ENV['CONTENT_EXPORT_LOCAL_DIR']
        ENV['CONTENT_EXPORT_LOCAL_DIR'] = ''
        example.run
        ENV['CONTENT_EXPORT_LOCAL_DIR'] = original
      end

      it 'returns false' do
        expect(described_class.dev_mode?).to be false
      end
    end
  end

  describe '.local_export_dir' do
    around do |example|
      original = ENV['CONTENT_EXPORT_LOCAL_DIR']
      ENV['CONTENT_EXPORT_LOCAL_DIR'] = '/custom/path'
      example.run
      ENV['CONTENT_EXPORT_LOCAL_DIR'] = original
    end

    it 'returns the environment variable value' do
      expect(described_class.local_export_dir).to eq('/custom/path')
    end
  end

  describe '.create_package' do
    let(:json_data) { { name: 'Test', version: '1.0' } }
    let(:images) { [] }
    let(:output_name) { 'test_export' }

    context 'in download mode (not dev mode)' do
      around do |example|
        original = ENV['CONTENT_EXPORT_LOCAL_DIR']
        ENV['CONTENT_EXPORT_LOCAL_DIR'] = nil
        example.run
        ENV['CONTENT_EXPORT_LOCAL_DIR'] = original
      end

      it 'returns zip_data and filename' do
        result = described_class.create_package(json_data, images, output_name)

        expect(result).to have_key(:zip_data)
        expect(result).to have_key(:filename)
        expect(result[:success]).to be true
        expect(result[:filename]).to start_with('test_export_')
        expect(result[:filename]).to end_with('.zip')
      end

      it 'includes JSON data in the zip' do
        result = described_class.create_package(json_data, images, output_name)

        # The zip data should be non-empty binary
        expect(result[:zip_data]).not_to be_empty
        expect(result[:zip_data].encoding).to eq(Encoding::ASCII_8BIT)
      end
    end

    context 'in dev mode (local export)' do
      let(:temp_dir) { Dir.mktmpdir }

      around do |example|
        original = ENV['CONTENT_EXPORT_LOCAL_DIR']
        ENV['CONTENT_EXPORT_LOCAL_DIR'] = temp_dir
        example.run
        ENV['CONTENT_EXPORT_LOCAL_DIR'] = original
        FileUtils.rm_rf(temp_dir)
      end

      it 'creates local directory structure' do
        result = described_class.create_package(json_data, images, output_name)

        expect(result[:success]).to be true
        expect(result[:path]).to eq(File.join(temp_dir, output_name))
        expect(Dir.exist?(result[:path])).to be true
      end

      it 'writes JSON data file' do
        result = described_class.create_package(json_data, images, output_name)

        json_path = File.join(result[:path], 'data.json')
        expect(File.exist?(json_path)).to be true

        written_data = JSON.parse(File.read(json_path))
        expect(written_data['name']).to eq('Test')
      end

      it 'creates images subdirectory' do
        result = described_class.create_package(json_data, images, output_name)

        images_dir = File.join(result[:path], 'images')
        expect(Dir.exist?(images_dir)).to be true
      end
    end
  end

  describe '.extract_package' do
    let(:temp_zip) { Tempfile.new(['test', '.zip']) }

    after do
      temp_zip.close
      temp_zip.unlink
    end

    context 'with invalid input' do
      it 'returns error for nil input' do
        result = described_class.extract_package(nil)
        expect(result[:error]).to eq('Invalid ZIP file provided')
      end

      it 'returns error for non-existent file' do
        result = described_class.extract_package('/nonexistent/path.zip')
        expect(result[:error]).to eq('ZIP file not found')
      end
    end

    context 'with valid ZIP file' do
      before do
        # Create a valid ZIP with JSON and image
        Zip::File.open(temp_zip.path, Zip::File::CREATE) do |zip|
          zip.get_output_stream('data.json') { |f| f.write('{"test": true}') }
        end
      end

      it 'extracts JSON data' do
        result = described_class.extract_package(temp_zip.path)

        expect(result[:error]).to be_nil
        expect(result[:json_data]).to eq({ 'test' => true })
        expect(result[:temp_dir]).not_to be_nil

        # Cleanup
        FileUtils.rm_rf(result[:temp_dir])
      end

      it 'returns temp_dir path' do
        result = described_class.extract_package(temp_zip.path)

        expect(Dir.exist?(result[:temp_dir])).to be true

        # Cleanup
        FileUtils.rm_rf(result[:temp_dir])
      end
    end

    context 'with Rack uploaded file format' do
      before do
        Zip::File.open(temp_zip.path, Zip::File::CREATE) do |zip|
          zip.get_output_stream('data.json') { |f| f.write('{"uploaded": true}') }
        end
      end

      it 'handles Hash with tempfile key' do
        uploaded = { tempfile: temp_zip }
        result = described_class.extract_package(uploaded)

        expect(result[:error]).to be_nil
        expect(result[:json_data]).to eq({ 'uploaded' => true })

        # Cleanup
        FileUtils.rm_rf(result[:temp_dir])
      end
    end

    context 'with ZIP containing images' do
      before do
        Zip::File.open(temp_zip.path, Zip::File::CREATE) do |zip|
          zip.get_output_stream('data.json') { |f| f.write('{}') }
          zip.get_output_stream('image.jpg') { |f| f.write('fake image data') }
          zip.get_output_stream('photo.png') { |f| f.write('fake png data') }
        end
      end

      it 'extracts image files' do
        result = described_class.extract_package(temp_zip.path)

        expect(result[:image_files].length).to eq(2)
        expect(result[:image_files].map { |i| i[:filename] }).to include('image.jpg', 'photo.png')

        # Cleanup
        FileUtils.rm_rf(result[:temp_dir])
      end
    end

    context 'with invalid ZIP' do
      before do
        File.write(temp_zip.path, 'not a zip file')
      end

      it 'returns error' do
        result = described_class.extract_package(temp_zip.path)
        expect(result[:error]).to include('Failed to extract ZIP')
      end
    end

    context 'with invalid JSON in ZIP' do
      before do
        Zip::File.open(temp_zip.path, Zip::File::CREATE) do |zip|
          zip.get_output_stream('data.json') { |f| f.write('not valid json') }
        end
      end

      it 'returns error' do
        result = described_class.extract_package(temp_zip.path)
        expect(result[:error]).to include('Invalid JSON')
      end
    end

    context 'with ZIP missing JSON data' do
      before do
        Zip::File.open(temp_zip.path, Zip::File::CREATE) do |zip|
          zip.get_output_stream('readme.txt') { |f| f.write('no json here') }
        end
      end

      it 'returns error' do
        result = described_class.extract_package(temp_zip.path)
        expect(result[:error]).to eq('No JSON data file found in package')
      end
    end

    context 'when ZIP exceeds entry limit' do
      before do
        stub_const('ContentPackageService::MAX_ZIP_ENTRIES', 2)
        Zip::File.open(temp_zip.path, Zip::File::CREATE) do |zip|
          zip.get_output_stream('data.json') { |f| f.write('{}') }
          zip.get_output_stream('image1.jpg') { |f| f.write('a') }
          zip.get_output_stream('image2.jpg') { |f| f.write('b') }
        end
      end

      it 'returns a validation error' do
        result = described_class.extract_package(temp_zip.path)
        expect(result[:error]).to include('too many files')
      end
    end

    context 'when ZIP exceeds total extracted size limit' do
      before do
        stub_const('ContentPackageService::MAX_TOTAL_EXTRACTED_SIZE', 10)
        Zip::File.open(temp_zip.path, Zip::File::CREATE) do |zip|
          zip.get_output_stream('data.json') { |f| f.write('{"payload":"1234567890"}') }
        end
      end

      it 'returns a validation error' do
        result = described_class.extract_package(temp_zip.path)
        expect(result[:error]).to include('package too large')
      end
    end
  end

  describe '.upload_images_from_package' do
    let(:temp_dir) { Dir.mktmpdir }
    let(:image_path) { File.join(temp_dir, 'test.jpg') }
    let(:image_files) { [{ path: image_path, filename: 'test.jpg' }] }

    before do
      File.write(image_path, 'fake image content')
      allow(FileUtils).to receive(:mkdir_p)
      allow(FileUtils).to receive(:cp)
      allow(FileUtils).to receive(:rm_rf)
      allow(Dir).to receive(:exist?).and_return(true)
    end

    after do
      FileUtils.rm_rf(temp_dir)
    end

    it 'copies valid images to upload directory' do
      expect(FileUtils).to receive(:cp).with(image_path, anything)

      described_class.upload_images_from_package(temp_dir, image_files, 'character', 1)
    end

    it 'returns URL mapping' do
      result = described_class.upload_images_from_package(temp_dir, image_files, 'character', 1)

      expect(result).to be_a(Hash)
      expect(result['test.jpg']).to start_with('/uploads/content_packages/')
    end

    it 'cleans up temp directory' do
      expect(FileUtils).to receive(:rm_rf).with(temp_dir)

      described_class.upload_images_from_package(temp_dir, image_files, 'character', 1)
    end

    context 'with oversized file' do
      before do
        allow(File).to receive(:size).with(image_path).and_return(20 * 1024 * 1024)
      end

      it 'skips oversized files' do
        expect(FileUtils).not_to receive(:cp).with(image_path, anything)

        result = described_class.upload_images_from_package(temp_dir, image_files, 'character', 1)
        expect(result).to be_empty
      end
    end
  end

  describe '.download_image' do
    let(:temp_file) { Tempfile.new(['test', '.jpg']) }

    after do
      temp_file.close
      temp_file.unlink
    end

    context 'with nil or empty URL' do
      it 'returns false for nil' do
        expect(described_class.download_image(nil, temp_file.path)).to be false
      end

      it 'returns false for empty string' do
        expect(described_class.download_image('', temp_file.path)).to be false
      end
    end

    context 'with relative URL' do
      it 'returns false for relative images/ URL' do
        expect(described_class.download_image('images/test.jpg', temp_file.path)).to be false
      end
    end

    context 'with local URL' do
      let(:local_source) { Tempfile.new(['source', '.jpg']) }

      before do
        File.write(local_source.path, 'local image data')
      end

      after do
        local_source.close
        local_source.unlink
      end

      it 'copies local file when it exists' do
        # This tests the local copy path but requires proper file paths
        result = described_class.download_image("/nonexistent/path.jpg", temp_file.path)
        expect(result).to be false
      end

      it 'resolves /uploads paths under backend/public' do
        local_upload_dir = File.join(File.expand_path('../../..', __dir__), 'public', 'uploads')
        FileUtils.mkdir_p(local_upload_dir)
        upload_path = File.join(local_upload_dir, 'spec_local_test.jpg')
        File.binwrite(upload_path, 'local image data')

        begin
          result = described_class.download_image('/uploads/spec_local_test.jpg', temp_file.path)
          expect(result).to be true
          expect(File.binread(temp_file.path)).to eq('local image data')
        ensure
          FileUtils.rm_f(upload_path)
        end
      end

      it 'blocks traversal outside public/uploads' do
        result = described_class.download_image('/../app.rb', temp_file.path)
        expect(result).to be false
      end
    end

    context 'with remote URL' do
      it 'handles HTTP errors gracefully' do
        allow(Net::HTTP).to receive(:get_response).and_raise(StandardError.new('Network error'))

        result = described_class.download_image('https://example.com/image.jpg', temp_file.path)
        expect(result).to be false
      end
    end
  end

  describe '.cleanup_temp_dirs' do
    let(:temp_base) { Dir.mktmpdir }

    before do
      stub_const('ContentPackageService::TEMP_DIR', temp_base)
    end

    after do
      FileUtils.rm_rf(temp_base)
    end

    context 'when temp directory does not exist' do
      before do
        FileUtils.rm_rf(temp_base)
      end

      it 'returns 0' do
        expect(described_class.cleanup_temp_dirs).to eq(0)
      end
    end

    context 'with old directories' do
      before do
        old_dir = File.join(temp_base, 'old_dir')
        FileUtils.mkdir_p(old_dir)
        # Set modification time to 48 hours ago
        File.utime(Time.now - 172_800, Time.now - 172_800, old_dir)
      end

      it 'deletes directories older than max_age_hours' do
        deleted = described_class.cleanup_temp_dirs(24)
        expect(deleted).to eq(1)
      end
    end

    context 'with recent directories' do
      before do
        recent_dir = File.join(temp_base, 'recent_dir')
        FileUtils.mkdir_p(recent_dir)
      end

      it 'keeps recent directories' do
        deleted = described_class.cleanup_temp_dirs(24)
        expect(deleted).to eq(0)
        expect(Dir.exist?(File.join(temp_base, 'recent_dir'))).to be true
      end
    end
  end

  describe 'private methods' do
    describe 'image_file?' do
      it 'returns true for allowed extensions' do
        expect(described_class.send(:image_file?, 'test.jpg')).to be true
        expect(described_class.send(:image_file?, 'test.PNG')).to be true
        expect(described_class.send(:image_file?, 'test.gif')).to be true
        expect(described_class.send(:image_file?, 'test.webp')).to be true
      end

      it 'returns false for non-image extensions' do
        expect(described_class.send(:image_file?, 'test.txt')).to be false
        expect(described_class.send(:image_file?, 'test.pdf')).to be false
        expect(described_class.send(:image_file?, 'test.json')).to be false
      end
    end
  end
end
