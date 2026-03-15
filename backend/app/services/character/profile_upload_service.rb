# frozen_string_literal: true

# ProfileUploadService handles image uploads for profile pictures and backgrounds.
# Images are stored via CloudStorageService (R2 or local).
#
# Usage:
#   # Upload a profile picture (max 5MB)
#   result = ProfileUploadService.upload_picture(file, character.id)
#   # => { success: true, message: 'Image uploaded', data: { url: '/uploads/...', filename: '...' } }
#
#   # Upload a profile background (max 10MB)
#   result = ProfileUploadService.upload_background(file, character.id)
#
#   # Delete a profile image
#   ProfileUploadService.delete('/uploads/profiles/pictures/123_abc.jpg')
#
class ProfileUploadService
  extend ResultHandler

  PICTURE_MAX_SIZE = 5 * 1024 * 1024      # 5MB
  BACKGROUND_MAX_SIZE = 10 * 1024 * 1024  # 10MB
  ALLOWED_TYPES = %w[image/jpeg image/png image/gif image/webp].freeze

  class << self
    # Upload a profile picture
    # @param file [Hash] Rack uploaded file with :tempfile, :filename, :type
    # @param character_id [Integer] Character ID for naming
    # @return [Result] Success with url and filename, or error
    def upload_picture(file, character_id)
      upload_image(file, character_id, 'pictures', PICTURE_MAX_SIZE)
    end

    # Upload a profile background
    # @param file [Hash] Rack uploaded file with :tempfile, :filename, :type
    # @param character_id [Integer] Character ID for naming
    # @return [Result] Success with url and filename, or error
    def upload_background(file, character_id)
      upload_image(file, character_id, 'backgrounds', BACKGROUND_MAX_SIZE)
    end

    # Delete a profile image from storage
    # @param url [String] Full URL or path to the image
    # @return [Boolean] true if deletion succeeded
    def delete(url)
      return false unless url.is_a?(String) && !url.strip.empty?

      filename = File.basename(url)
      folder = url.include?('/backgrounds/') ? 'backgrounds' : 'pictures'
      key = "profiles/#{folder}/#{filename}"
      CloudStorageService.delete(key)
    end

    private

    def upload_image(file, character_id, folder, max_size)
      return error('No file provided') unless file
      return error('Invalid file format') unless file[:tempfile]

      content_type = file[:type] || detect_content_type(file[:tempfile])
      unless ALLOWED_TYPES.include?(content_type)
        return error("Invalid file type: #{content_type}. Allowed: JPEG, PNG, GIF, WebP")
      end

      file[:tempfile].rewind
      file_size = file[:tempfile].size
      max_mb = max_size / 1024 / 1024
      if file_size > max_size
        return error("File too large. Maximum size: #{max_mb}MB")
      end

      ext = File.extname(file[:filename] || '').downcase
      ext = '.jpg' if ext.empty? || !%w[.jpg .jpeg .png .gif .webp].include?(ext)
      filename = "#{character_id}_#{SecureRandom.hex(16)}#{ext}"
      key = "profiles/#{folder}/#{filename}"

      begin
        file[:tempfile].rewind
        data = file[:tempfile].read
        url = CloudStorageService.upload(data, key, content_type: content_type)
      rescue StandardError => e
        warn "[ProfileUploadService] Upload failed: #{e.message}"
        return error("Failed to save file: #{e.message}")
      end

      success('Image uploaded', data: { url: url, filename: filename })
    end

    # Detect content type from file magic bytes
    # @param tempfile [IO] File-like object
    # @return [String] MIME type
    def detect_content_type(tempfile)
      tempfile.rewind
      header = tempfile.read(12)
      tempfile.rewind

      return 'application/octet-stream' unless header

      case header
      when /\A\x89PNG/n then 'image/png'
      when /\A\xFF\xD8\xFF/n then 'image/jpeg'
      when /\AGIF8/n then 'image/gif'
      when /\ARIFF....WEBP/n then 'image/webp'
      else 'application/octet-stream'
      end
    end
  end
end
