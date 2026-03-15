# frozen_string_literal: true

# CloudStorageService provides a unified interface for file storage that works
# with both local filesystem and Cloudflare R2 (S3-compatible) storage.
#
# When R2 is disabled, files are stored locally in public/uploads/.
# When R2 is enabled, files are uploaded to the configured R2 bucket.
#
# Usage:
#   # Upload data (binary string)
#   url = CloudStorageService.upload(image_data, 'generated/2026/01/abc.png', content_type: 'image/png')
#
#   # Upload from file path
#   url = CloudStorageService.upload('/tmp/image.png', 'images/abc.png')
#
#   # Get public URL for a key
#   url = CloudStorageService.public_url('generated/2026/01/abc.png')
#
#   # Delete a file
#   CloudStorageService.delete('generated/2026/01/abc.png')
#
#   # Check if R2 is enabled
#   CloudStorageService.enabled?
#
class CloudStorageService
  LOCAL_UPLOAD_DIR = 'public/uploads'

  class << self
    # Check if R2 storage is enabled and properly configured
    # @return [Boolean] true if R2 should be used for storage
    def enabled?
      GameSetting.boolean('storage_r2_enabled') &&
        !GameSetting.get('storage_r2_bucket').to_s.strip.empty?
    end

    # Upload data to storage (R2 or local)
    # @param data [String, Pathname] binary data or file path to upload
    # @param key [String] storage key (path within storage)
    # @param content_type [String] MIME type of the file
    # @return [String] public URL of the uploaded file
    def upload(data, key, content_type: 'image/png')
      if enabled?
        upload_to_r2(data, key, content_type)
      else
        upload_locally(data, key)
      end
    rescue StandardError => e
      warn "[CloudStorageService] Upload failed for #{key}: #{e.message}"
      raise
    end

    # Get the public URL for a storage key
    # @param key [String] storage key
    # @return [String] public URL
    def public_url(key)
      if enabled?
        public_url_base = GameSetting.get('storage_r2_public_url').to_s.strip
        return "/uploads/#{key}" if public_url_base.empty?

        "#{public_url_base.chomp('/')}/#{key}"
      else
        "/uploads/#{key}"
      end
    end

    # Delete a file from storage
    # @param key [String] storage key to delete
    # @return [Boolean] true if deletion succeeded
    def delete(key)
      if enabled?
        delete_from_r2(key)
      else
        delete_locally(key)
      end
    rescue StandardError => e
      warn "[CloudStorageService] Delete failed for #{key}: #{e.message}"
      false
    end

    # Test the R2 connection by listing bucket contents
    # @raise [StandardError] if connection fails
    # @return [Hash] connection test result
    def test_connection!
      raise ArgumentError, 'R2 storage is not enabled' unless enabled?

      endpoint = GameSetting.get('storage_r2_endpoint')
      bucket = GameSetting.get('storage_r2_bucket')

      raise ArgumentError, 'R2 endpoint is not configured' if endpoint.to_s.strip.empty?
      raise ArgumentError, 'R2 bucket is not configured' if bucket.to_s.strip.empty?

      # Try to list objects (limited to 1) to verify connection
      r2_client.list_objects_v2(bucket: bucket, max_keys: 1)

      { success: true, message: 'Successfully connected to R2 bucket' }
    end

    # Reset the R2 client (call after settings change)
    def reset_client!
      @r2_client = nil
    end

    # Check if a key exists in storage
    # @param key [String] storage key
    # @return [Boolean] true if file exists
    def exists?(key)
      if enabled?
        r2_client.head_object(bucket: GameSetting.get('storage_r2_bucket'), key: key)
        true
      else
        File.exist?(File.join(LOCAL_UPLOAD_DIR, key))
      end
    rescue Aws::S3::Errors::NotFound
      false
    rescue StandardError => e
      warn "[CloudStorageService] exists? check failed for #{key}: #{e.message}"
      false
    end

    private

    def r2_client
      @r2_client ||= begin
        require 'aws-sdk-s3'

        endpoint = GameSetting.get('storage_r2_endpoint')
        access_key = GameSetting.get('storage_r2_access_key')
        secret_key = GameSetting.get('storage_r2_secret_key')

        Aws::S3::Client.new(
          region: 'auto',
          endpoint: endpoint,
          access_key_id: access_key,
          secret_access_key: secret_key,
          force_path_style: true
        )
      end
    end

    def upload_to_r2(data, key, content_type)
      bucket = GameSetting.get('storage_r2_bucket')

      # Handle both raw data and file paths
      # Check for file path: must not contain null bytes and must exist on disk
      body = if data.is_a?(Pathname)
               File.binread(data.to_s)
             elsif data.is_a?(String) && !data.include?("\0") && data.length < 4096 && File.file?(data)
               File.binread(data)
             else
               data
             end

      r2_client.put_object(
        bucket: bucket,
        key: key,
        body: body,
        content_type: content_type
      )

      public_url(key)
    end

    def upload_locally(data, key)
      path = File.join(LOCAL_UPLOAD_DIR, key)
      FileUtils.mkdir_p(File.dirname(path))

      # Handle both raw data and file paths
      # Check for file path: must not contain null bytes and must exist on disk
      content = if data.is_a?(Pathname)
                  File.binread(data.to_s)
                elsif data.is_a?(String) && !data.include?("\0") && data.length < 4096 && File.file?(data)
                  File.binread(data)
                else
                  data
                end

      File.binwrite(path, content)
      "/uploads/#{key}"
    end

    def delete_from_r2(key)
      bucket = GameSetting.get('storage_r2_bucket')
      r2_client.delete_object(bucket: bucket, key: key)
      true
    end

    def delete_locally(key)
      path = File.join(LOCAL_UPLOAD_DIR, key)
      return false unless File.exist?(path)

      File.delete(path)
      true
    end
  end
end
