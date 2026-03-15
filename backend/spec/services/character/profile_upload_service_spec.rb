# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ProfileUploadService do
  let(:character) { create(:character) }

  describe 'constants' do
    it 'defines PICTURE_MAX_SIZE as 5MB' do
      expect(described_class::PICTURE_MAX_SIZE).to eq(5 * 1024 * 1024)
    end

    it 'defines BACKGROUND_MAX_SIZE as 10MB' do
      expect(described_class::BACKGROUND_MAX_SIZE).to eq(10 * 1024 * 1024)
    end

    it 'defines ALLOWED_TYPES' do
      expect(described_class::ALLOWED_TYPES).to include('image/jpeg', 'image/png', 'image/gif', 'image/webp')
    end
  end

  describe '.upload_picture' do
    let(:valid_png_file) do
      tempfile = StringIO.new("\x89PNG\r\n\x1a\n" + ('x' * 100))
      { tempfile: tempfile, filename: 'test.png', type: 'image/png' }
    end

    let(:valid_jpeg_file) do
      tempfile = StringIO.new("\xFF\xD8\xFF" + ('x' * 100))
      { tempfile: tempfile, filename: 'test.jpg', type: 'image/jpeg' }
    end

    before do
      allow(CloudStorageService).to receive(:upload).and_return('/uploads/profiles/pictures/test.png')
    end

    it 'uploads a valid PNG image' do
      result = described_class.upload_picture(valid_png_file, character.id)

      expect(result[:success]).to be true
      expect(result[:message]).to eq('Image uploaded')
      expect(result[:data][:url]).to include('/uploads/')
    end

    it 'uploads a valid JPEG image' do
      result = described_class.upload_picture(valid_jpeg_file, character.id)

      expect(result[:success]).to be true
    end

    it 'generates unique filename with character ID' do
      allow(SecureRandom).to receive(:hex).with(16).and_return('abc123def456')

      result = described_class.upload_picture(valid_png_file, character.id)

      expect(result[:data][:filename]).to eq("#{character.id}_abc123def456.png")
    end

    it 'passes correct key to CloudStorageService' do
      allow(SecureRandom).to receive(:hex).with(16).and_return('abc123def456')

      expect(CloudStorageService).to receive(:upload).with(
        anything,
        "profiles/pictures/#{character.id}_abc123def456.png",
        content_type: 'image/png'
      )

      described_class.upload_picture(valid_png_file, character.id)
    end

    it 'rejects files over 5MB' do
      large_file = valid_png_file.dup
      large_file[:tempfile] = StringIO.new("\x89PNG\r\n\x1a\n" + ('x' * 6_000_000))

      result = described_class.upload_picture(large_file, character.id)

      expect(result[:success]).to be false
      expect(result[:message]).to include('too large')
      expect(result[:message]).to include('5MB')
    end

    it 'rejects invalid file types' do
      bad_file = {
        tempfile: StringIO.new('not an image'),
        filename: 'test.pdf',
        type: 'application/pdf'
      }

      result = described_class.upload_picture(bad_file, character.id)

      expect(result[:success]).to be false
      expect(result[:message]).to include('Invalid file type')
      expect(result[:message]).to include('application/pdf')
    end

    it 'returns error when no file provided' do
      result = described_class.upload_picture(nil, character.id)

      expect(result[:success]).to be false
      expect(result[:message]).to eq('No file provided')
    end

    it 'returns error when tempfile is missing' do
      invalid_file = { filename: 'test.png', type: 'image/png' }

      result = described_class.upload_picture(invalid_file, character.id)

      expect(result[:success]).to be false
      expect(result[:message]).to eq('Invalid file format')
    end

    it 'handles CloudStorageService errors gracefully' do
      allow(CloudStorageService).to receive(:upload).and_raise(StandardError, 'Storage error')

      result = described_class.upload_picture(valid_png_file, character.id)

      expect(result[:success]).to be false
      expect(result[:message]).to include('Failed to save file')
      expect(result[:message]).to include('Storage error')
    end

    context 'content type detection' do
      it 'detects PNG from magic bytes when type not provided' do
        file_without_type = {
          tempfile: StringIO.new("\x89PNG\r\n\x1a\n" + ('x' * 100)),
          filename: 'test.png'
        }

        expect(CloudStorageService).to receive(:upload).with(
          anything,
          anything,
          content_type: 'image/png'
        )

        described_class.upload_picture(file_without_type, character.id)
      end

      it 'detects JPEG from magic bytes when type not provided' do
        file_without_type = {
          tempfile: StringIO.new("\xFF\xD8\xFF" + ('x' * 100)),
          filename: 'test.jpg'
        }

        expect(CloudStorageService).to receive(:upload).with(
          anything,
          anything,
          content_type: 'image/jpeg'
        )

        described_class.upload_picture(file_without_type, character.id)
      end

      it 'detects GIF from magic bytes when type not provided' do
        file_without_type = {
          tempfile: StringIO.new("GIF89a" + ('x' * 100)),
          filename: 'test.gif'
        }

        expect(CloudStorageService).to receive(:upload).with(
          anything,
          anything,
          content_type: 'image/gif'
        )

        described_class.upload_picture(file_without_type, character.id)
      end

      it 'detects WebP from magic bytes when type not provided' do
        file_without_type = {
          tempfile: StringIO.new("RIFF\x00\x00\x00\x00WEBP" + ('x' * 100)),
          filename: 'test.webp'
        }

        expect(CloudStorageService).to receive(:upload).with(
          anything,
          anything,
          content_type: 'image/webp'
        )

        described_class.upload_picture(file_without_type, character.id)
      end

      it 'rejects unknown file types detected from magic bytes' do
        file_with_bad_content = {
          tempfile: StringIO.new('random data that is not an image'),
          filename: 'test.png',
          type: nil
        }

        result = described_class.upload_picture(file_with_bad_content, character.id)

        expect(result[:success]).to be false
        expect(result[:message]).to include('Invalid file type')
        expect(result[:message]).to include('application/octet-stream')
      end
    end

    context 'filename extension handling' do
      it 'preserves valid extension from filename' do
        allow(SecureRandom).to receive(:hex).with(16).and_return('abc123')

        file = { tempfile: StringIO.new("\x89PNG\r\n\x1a\n"), filename: 'image.png', type: 'image/png' }
        result = described_class.upload_picture(file, character.id)

        expect(result[:data][:filename]).to end_with('.png')
      end

      it 'defaults to .jpg when extension missing' do
        allow(SecureRandom).to receive(:hex).with(16).and_return('abc123')

        file = { tempfile: StringIO.new("\xFF\xD8\xFF"), filename: 'image', type: 'image/jpeg' }
        result = described_class.upload_picture(file, character.id)

        expect(result[:data][:filename]).to end_with('.jpg')
      end

      it 'defaults to .jpg for invalid extensions' do
        allow(SecureRandom).to receive(:hex).with(16).and_return('abc123')

        file = { tempfile: StringIO.new("\xFF\xD8\xFF"), filename: 'image.bmp', type: 'image/jpeg' }
        result = described_class.upload_picture(file, character.id)

        expect(result[:data][:filename]).to end_with('.jpg')
      end

      it 'handles nil filename' do
        allow(SecureRandom).to receive(:hex).with(16).and_return('abc123')

        file = { tempfile: StringIO.new("\xFF\xD8\xFF"), filename: nil, type: 'image/jpeg' }
        result = described_class.upload_picture(file, character.id)

        expect(result[:data][:filename]).to end_with('.jpg')
      end
    end
  end

  describe '.upload_background' do
    let(:valid_file) do
      tempfile = StringIO.new("\xFF\xD8\xFF" + ('x' * 100))
      { tempfile: tempfile, filename: 'bg.jpg', type: 'image/jpeg' }
    end

    before do
      allow(CloudStorageService).to receive(:upload).and_return('/uploads/profiles/backgrounds/bg.jpg')
    end

    it 'uploads a valid background image' do
      result = described_class.upload_background(valid_file, character.id)

      expect(result[:success]).to be true
      expect(result[:data][:url]).to include('/uploads/')
    end

    it 'uses backgrounds folder' do
      allow(SecureRandom).to receive(:hex).with(16).and_return('abc123def456')

      expect(CloudStorageService).to receive(:upload).with(
        anything,
        "profiles/backgrounds/#{character.id}_abc123def456.jpg",
        content_type: 'image/jpeg'
      )

      described_class.upload_background(valid_file, character.id)
    end

    it 'allows larger files for backgrounds (up to 10MB)' do
      large_bg = valid_file.dup
      large_bg[:tempfile] = StringIO.new("\xFF\xD8\xFF" + ('x' * 8_000_000))

      result = described_class.upload_background(large_bg, character.id)

      expect(result[:success]).to be true
    end

    it 'accepts files just under 10MB' do
      max_size_file = valid_file.dup
      max_size_file[:tempfile] = StringIO.new("\xFF\xD8\xFF" + ('x' * (10 * 1024 * 1024 - 10)))

      result = described_class.upload_background(max_size_file, character.id)

      expect(result[:success]).to be true
    end

    it 'rejects files over 10MB' do
      huge_file = valid_file.dup
      huge_file[:tempfile] = StringIO.new("\xFF\xD8\xFF" + ('x' * 11_000_000))

      result = described_class.upload_background(huge_file, character.id)

      expect(result[:success]).to be false
      expect(result[:message]).to include('too large')
      expect(result[:message]).to include('10MB')
    end

    it 'accepts 6MB files (would fail for pictures)' do
      medium_file = valid_file.dup
      medium_file[:tempfile] = StringIO.new("\xFF\xD8\xFF" + ('x' * 6_000_000))

      result = described_class.upload_background(medium_file, character.id)

      expect(result[:success]).to be true
    end
  end

  describe '.delete' do
    context 'with picture URLs' do
      it 'delegates to CloudStorageService with correct key' do
        expect(CloudStorageService).to receive(:delete).with('profiles/pictures/123_abc.jpg')

        described_class.delete('/uploads/profiles/pictures/123_abc.jpg')
      end

      it 'handles full R2 URLs' do
        expect(CloudStorageService).to receive(:delete).with('profiles/pictures/123_abc.jpg')

        described_class.delete('https://cdn.example.com/uploads/profiles/pictures/123_abc.jpg')
      end
    end

    context 'with background URLs' do
      it 'delegates to CloudStorageService with backgrounds folder' do
        expect(CloudStorageService).to receive(:delete).with('profiles/backgrounds/123_abc.jpg')

        described_class.delete('/uploads/profiles/backgrounds/123_abc.jpg')
      end

      it 'handles full R2 URLs for backgrounds' do
        expect(CloudStorageService).to receive(:delete).with('profiles/backgrounds/bg_xyz.png')

        described_class.delete('https://cdn.example.com/profiles/backgrounds/bg_xyz.png')
      end
    end

    context 'with invalid input' do
      it 'returns false for nil input' do
        expect(CloudStorageService).not_to receive(:delete)

        result = described_class.delete(nil)

        expect(result).to be false
      end

      it 'returns false for non-string input' do
        expect(CloudStorageService).not_to receive(:delete)

        result = described_class.delete(123)

        expect(result).to be false
      end

      it 'returns false for empty string' do
        expect(CloudStorageService).not_to receive(:delete)

        result = described_class.delete('')

        expect(result).to be false
      end

      it 'returns false for whitespace-only string' do
        expect(CloudStorageService).not_to receive(:delete)

        result = described_class.delete('   ')

        expect(result).to be false
      end
    end

    it 'returns CloudStorageService result' do
      allow(CloudStorageService).to receive(:delete).and_return(true)
      expect(described_class.delete('/uploads/profiles/pictures/test.jpg')).to be true

      allow(CloudStorageService).to receive(:delete).and_return(false)
      expect(described_class.delete('/uploads/profiles/pictures/test.jpg')).to be false
    end
  end
end
