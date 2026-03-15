# frozen_string_literal: true

require 'spec_helper'

RSpec.describe DescriptionUploadService do
  describe 'constants' do
    it 'defines ALLOWED_TYPES' do
      expect(described_class::ALLOWED_TYPES).to include('image/jpeg', 'image/png', 'image/gif', 'image/webp')
    end

    it 'defines MAX_FILE_SIZE' do
      expect(described_class::MAX_FILE_SIZE).to eq(5 * 1024 * 1024)
    end

    it 'defines LOCAL_UPLOAD_DIR' do
      expect(described_class::LOCAL_UPLOAD_DIR).to be_a(String)
      expect(described_class::LOCAL_UPLOAD_DIR).to include('uploads/descriptions')
    end
  end

  describe '.upload' do
    let(:character_id) { 123 }
    let(:tempfile) { StringIO.new("\x89PNG\r\n\x1a\n" + ('x' * 100)) }
    let(:file) do
      {
        tempfile: tempfile,
        filename: 'test.png',
        type: 'image/png'
      }
    end

    before do
      allow(CloudStorageService).to receive(:upload).and_return('/uploads/descriptions/test_file.png')
    end

    it 'returns error when no file provided' do
      result = described_class.upload(nil, character_id)
      expect(result[:success]).to be false
      expect(result[:message]).to eq('No file provided')
    end

    it 'returns error when file has no tempfile' do
      result = described_class.upload({ filename: 'test.png' }, character_id)
      expect(result[:success]).to be false
      expect(result[:message]).to eq('Invalid file format')
    end

    it 'returns error for invalid file type' do
      invalid_file = {
        tempfile: StringIO.new('not an image'),
        filename: 'test.txt',
        type: 'text/plain'
      }
      result = described_class.upload(invalid_file, character_id)
      expect(result[:success]).to be false
      expect(result[:message]).to include('Invalid file type')
    end

    it 'returns error when file is too large' do
      # Create a file larger than MAX_FILE_SIZE
      large_tempfile = StringIO.new("\x89PNG" + ('x' * (6 * 1024 * 1024)))
      large_file = {
        tempfile: large_tempfile,
        filename: 'large.png',
        type: 'image/png'
      }
      result = described_class.upload(large_file, character_id)
      expect(result[:success]).to be false
      expect(result[:message]).to include('File too large')
    end

    it 'returns success with url and filename' do
      result = described_class.upload(file, character_id)
      expect(result[:success]).to be true
      expect(result[:message]).to eq('Image uploaded')
      expect(result[:data][:url]).to eq('/uploads/descriptions/test_file.png')
      expect(result[:data][:filename]).to be_a(String)
    end

    it 'generates unique filename with character_id prefix' do
      result = described_class.upload(file, character_id)
      expect(result[:data][:filename]).to start_with("#{character_id}_")
    end

    it 'preserves file extension from original filename' do
      result = described_class.upload(file, character_id)
      expect(result[:data][:filename]).to end_with('.png')
    end

    it 'defaults to .jpg extension when none provided' do
      no_ext_file = {
        tempfile: StringIO.new("\xFF\xD8\xFF" + ('x' * 100)),
        filename: 'test',
        type: 'image/jpeg'
      }
      result = described_class.upload(no_ext_file, character_id)
      expect(result[:data][:filename]).to end_with('.jpg')
    end

    it 'calls CloudStorageService.upload with correct parameters' do
      expect(CloudStorageService).to receive(:upload).with(
        anything,
        match(/^descriptions\/#{character_id}_/),
        content_type: 'image/png'
      )
      described_class.upload(file, character_id)
    end

    it 'returns error when CloudStorageService fails' do
      allow(CloudStorageService).to receive(:upload).and_raise(StandardError.new('Storage error'))
      result = described_class.upload(file, character_id)
      expect(result[:success]).to be false
      expect(result[:message]).to include('Failed to save file')
    end

    context 'content type detection' do
      it 'detects PNG from header' do
        png_file = {
          tempfile: StringIO.new("\x89PNG\r\n\x1a\n" + ('x' * 100)),
          filename: 'image.bin',
          type: nil
        }
        expect(CloudStorageService).to receive(:upload).with(
          anything, anything, content_type: 'image/png'
        )
        described_class.upload(png_file, character_id)
      end

      it 'detects JPEG from header' do
        jpeg_file = {
          tempfile: StringIO.new("\xFF\xD8\xFF" + ('x' * 100)),
          filename: 'image.bin',
          type: nil
        }
        expect(CloudStorageService).to receive(:upload).with(
          anything, anything, content_type: 'image/jpeg'
        )
        described_class.upload(jpeg_file, character_id)
      end

      it 'detects GIF from header' do
        gif_file = {
          tempfile: StringIO.new("GIF89a" + ('x' * 100)),
          filename: 'image.bin',
          type: nil
        }
        expect(CloudStorageService).to receive(:upload).with(
          anything, anything, content_type: 'image/gif'
        )
        described_class.upload(gif_file, character_id)
      end
    end
  end

  describe '.delete' do
    before do
      allow(CloudStorageService).to receive(:delete).and_return(true)
    end

    it 'returns false when url is nil' do
      expect(described_class.delete(nil)).to be false
    end

    it 'returns false when url is not a string' do
      expect(described_class.delete(123)).to be false
    end

    it 'extracts filename and calls CloudStorageService.delete' do
      expect(CloudStorageService).to receive(:delete).with('descriptions/test_file.png')
      described_class.delete('/uploads/descriptions/test_file.png')
    end

    it 'works with full CDN URLs' do
      expect(CloudStorageService).to receive(:delete).with('descriptions/cdn_file.jpg')
      described_class.delete('https://cdn.example.com/descriptions/cdn_file.jpg')
    end
  end

  describe '.cleanup_orphaned_files' do
    let(:upload_dir) { described_class::LOCAL_UPLOAD_DIR }

    context 'when upload directory does not exist' do
      before do
        allow(Dir).to receive(:exist?).with(upload_dir).and_return(false)
      end

      it 'returns 0' do
        expect(described_class.cleanup_orphaned_files).to eq(0)
      end
    end

    context 'when upload directory exists' do
      before do
        allow(Dir).to receive(:exist?).with(upload_dir).and_return(true)
        allow(CharacterDefaultDescription).to receive_message_chain(:exclude, :select_map).and_return([])
        allow(CharacterDescription).to receive_message_chain(:exclude, :select_map).and_return([])
        allow(Dir).to receive(:glob).and_return([])
      end

      it 'queries CharacterDefaultDescription for image_urls' do
        expect(CharacterDefaultDescription).to receive(:exclude).with(image_url: nil).and_return(double(select_map: []))
        described_class.cleanup_orphaned_files
      end

      it 'queries CharacterDescription for image_urls' do
        expect(CharacterDescription).to receive(:exclude).with(image_url: nil).and_return(double(select_map: []))
        described_class.cleanup_orphaned_files
      end

      it 'returns count of deleted files' do
        allow(Dir).to receive(:glob).and_return(['/path/to/orphan1.jpg', '/path/to/orphan2.png'])
        allow(File).to receive(:delete).and_return(true)

        expect(described_class.cleanup_orphaned_files).to eq(2)
      end

      it 'skips hidden files' do
        allow(Dir).to receive(:glob).and_return(['/path/to/.hidden_file', '/path/to/orphan.jpg'])
        allow(File).to receive(:delete).and_return(true)

        expect(described_class.cleanup_orphaned_files).to eq(1)
      end

      it 'does not delete referenced files' do
        allow(CharacterDefaultDescription).to receive_message_chain(:exclude, :select_map).and_return(['/uploads/referenced.jpg'])
        allow(Dir).to receive(:glob).and_return(['/path/to/referenced.jpg', '/path/to/orphan.jpg'])
        allow(File).to receive(:delete).and_return(true)

        expect(described_class.cleanup_orphaned_files).to eq(1)
      end
    end
  end
end
