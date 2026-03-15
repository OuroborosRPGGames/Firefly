# frozen_string_literal: true

require 'fileutils'

# DescriptionUploadService handles image uploads for character descriptions.
# Images are stored via CloudStorageService (R2 or local).
class DescriptionUploadService
  extend ResultHandler

  LOCAL_UPLOAD_DIR = File.join(File.expand_path('../..', __dir__), 'public', 'uploads', 'descriptions')
  ALLOWED_TYPES = %w[image/jpeg image/png image/gif image/webp].freeze
  MAX_FILE_SIZE = 5 * 1024 * 1024 # 5MB

  class << self
    # Upload an image for a description
    # @param file [Hash] Rack uploaded file (tempfile, filename, type)
    # @param character_id [Integer] Character ID for organizing uploads
    # @return [Result] Result with url and filename in data
    def upload(file, character_id)
      return error('No file provided') unless file
      return error('Invalid file format') unless file[:tempfile]

      # Validate file type
      content_type = file[:type] || detect_content_type(file[:tempfile])
      unless ALLOWED_TYPES.include?(content_type)
        return error("Invalid file type: #{content_type}. Allowed: JPEG, PNG, GIF, WebP")
      end

      # Validate file size
      if file[:tempfile].size > MAX_FILE_SIZE
        return error("File too large. Maximum size: #{MAX_FILE_SIZE / 1024 / 1024}MB")
      end

      # Generate unique filename and storage key
      ext = File.extname(file[:filename]).downcase
      ext = '.jpg' if ext.empty? || !%w[.jpg .jpeg .png .gif .webp].include?(ext)
      filename = "#{character_id}_#{SecureRandom.hex(16)}#{ext}"
      key = "descriptions/#{filename}"

      # Upload via CloudStorageService
      begin
        data = file[:tempfile].read
        url = CloudStorageService.upload(data, key, content_type: content_type)
      rescue StandardError => e
        return error("Failed to save file: #{e.message}")
      end

      success('Image uploaded', data: { url: url, filename: filename })
    end

    # Delete an uploaded image
    # @param url [String] The URL path of the image
    # @return [Boolean] True if deleted successfully
    def delete(url)
      return false unless url.is_a?(String)

      # Extract key from URL
      # URL could be "/uploads/descriptions/filename" or "https://cdn.example.com/descriptions/filename"
      filename = File.basename(url)
      key = "descriptions/#{filename}"

      CloudStorageService.delete(key)
    end

    # Clean up orphaned image files not referenced by any description
    # Note: Only cleans up local files. R2 files should be managed via R2 lifecycle policies.
    # @return [Integer] Number of files cleaned up
    def cleanup_orphaned_files
      return 0 unless Dir.exist?(LOCAL_UPLOAD_DIR)

      # Get all referenced image URLs
      referenced_urls = Set.new

      CharacterDefaultDescription.exclude(image_url: nil).select_map(:image_url).each do |url|
        referenced_urls.add(File.basename(url)) if url
      end

      CharacterDescription.exclude(image_url: nil).select_map(:image_url).each do |url|
        referenced_urls.add(File.basename(url)) if url
      end

      # Find and delete unreferenced local files
      deleted = 0
      Dir.glob(File.join(LOCAL_UPLOAD_DIR, '*')).each do |filepath|
        filename = File.basename(filepath)
        next if filename.start_with?('.') # Skip hidden files

        unless referenced_urls.include?(filename)
          File.delete(filepath)
          deleted += 1
        end
      end

      deleted
    end

    private

    def detect_content_type(tempfile)
      # Read first few bytes to detect file type
      tempfile.rewind
      header = tempfile.read(12)
      tempfile.rewind

      case header
      when /^\x89PNG/n
        'image/png'
      when /^\xFF\xD8\xFF/n
        'image/jpeg'
      when /^GIF8/n
        'image/gif'
      when /^RIFF....WEBP/n
        'image/webp'
      else
        'application/octet-stream'
      end
    end
  end
end
