# frozen_string_literal: true

require 'fileutils'
require 'ipaddr'
require 'zip'
require 'json'
require 'net/http'
require 'uri'
require 'tempfile'

# ContentPackageService handles ZIP creation and extraction for content export/import.
# Supports dev mode for local filesystem operations (useful for testing).
class ContentPackageService
  UPLOAD_DIR = File.join(File.expand_path('../..', __dir__), 'public', 'uploads', 'content_packages')
  TEMP_DIR = File.join(Dir.tmpdir, 'firefly_content_packages')
  ALLOWED_IMAGE_TYPES = %w[.jpg .jpeg .png .gif .webp].freeze
  MAX_IMAGE_SIZE = 10 * 1024 * 1024 # 10MB per image
  MAX_ZIP_ENTRIES = 500
  MAX_SINGLE_EXTRACTED_SIZE = 15 * 1024 * 1024 # 15MB per entry
  MAX_TOTAL_EXTRACTED_SIZE = 100 * 1024 * 1024 # 100MB per package
  MAX_COMPRESSION_RATIO = 100.0

  class PackageValidationError < StandardError; end

  class << self
    # Check if dev mode is enabled (local filesystem instead of browser download)
    def dev_mode?
      !ENV['CONTENT_EXPORT_LOCAL_DIR'].nil? && !ENV['CONTENT_EXPORT_LOCAL_DIR'].empty?
    end

    # Get the local export directory (dev mode only)
    def local_export_dir
      ENV['CONTENT_EXPORT_LOCAL_DIR']
    end

    # Create a package (ZIP file) containing JSON data and images
    # @param json_data [Hash] The data to serialize as JSON
    # @param images [Array<Hash>] Array of {original_url:, filename:} for images to include
    # @param output_name [String] Base name for the output file
    # @return [Hash] In dev mode: {path:}, otherwise: {zip_data:, filename:}
    def create_package(json_data, images, output_name)
      if dev_mode?
        create_local_package(json_data, images, output_name)
      else
        create_download_package(json_data, images, output_name)
      end
    end

    # Extract a package (ZIP file) and return contents
    # @param zip_file [Hash|String] Rack uploaded file or path to ZIP
    # @return [Hash] {json_data:, image_files:, temp_dir:, error:}
    def extract_package(zip_file)
      # Determine the source
      zip_path = if zip_file.is_a?(Hash) && zip_file[:tempfile]
                   zip_file[:tempfile].path
                 elsif zip_file.is_a?(String)
                   zip_file
                 else
                   return { error: 'Invalid ZIP file provided' }
                 end

      return { error: 'ZIP file not found' } unless File.exist?(zip_path)

      # Create temp extraction directory
      temp_dir = File.join(TEMP_DIR, SecureRandom.hex(8))
      FileUtils.mkdir_p(temp_dir)

      json_data = nil
      image_files = []
      entry_count = 0
      total_uncompressed_size = 0

      begin
        Zip::File.open(zip_path) do |zip|
          zip.each do |entry|
            # Skip directories
            next if entry.directory?

            entry_count += 1
            if entry_count > MAX_ZIP_ENTRIES
              raise PackageValidationError, "ZIP contains too many files (max #{MAX_ZIP_ENTRIES})"
            end

            uncompressed_size = entry.size.to_i
            compressed_size = entry.compressed_size.to_i
            if uncompressed_size > MAX_SINGLE_EXTRACTED_SIZE
              raise PackageValidationError, "ZIP entry too large: #{entry.name}"
            end

            total_uncompressed_size += uncompressed_size
            if total_uncompressed_size > MAX_TOTAL_EXTRACTED_SIZE
              raise PackageValidationError, "ZIP package too large (max #{MAX_TOTAL_EXTRACTED_SIZE} bytes)"
            end

            if compressed_size <= 0
              raise PackageValidationError, "Invalid compressed entry size for #{entry.name}" if uncompressed_size.positive?
            elsif (uncompressed_size.to_f / compressed_size) > MAX_COMPRESSION_RATIO
              raise PackageValidationError, "Suspicious compression ratio for #{entry.name}"
            end

            # Sanitize filename to prevent directory traversal
            safe_name = File.basename(entry.name)
            extract_path = File.join(temp_dir, safe_name)

            # Extract the file
            entry.extract(extract_path)

            if safe_name.end_with?('.json')
              json_data = JSON.parse(File.read(extract_path))
            elsif image_file?(safe_name)
              image_files << { path: extract_path, filename: safe_name }
            end
          end
        end
      rescue Zip::Error => e
        FileUtils.rm_rf(temp_dir)
        return { error: "Failed to extract ZIP: #{e.message}" }
      rescue PackageValidationError => e
        FileUtils.rm_rf(temp_dir)
        return { error: e.message }
      rescue JSON::ParserError => e
        FileUtils.rm_rf(temp_dir)
        return { error: "Invalid JSON in package: #{e.message}" }
      end

      if json_data.nil?
        FileUtils.rm_rf(temp_dir)
        return { error: 'No JSON data file found in package' }
      end

      {
        json_data: json_data,
        image_files: image_files,
        temp_dir: temp_dir
      }
    end

    # Upload images from extracted package to permanent storage
    # @param temp_dir [String] Temporary directory with extracted files
    # @param image_files [Array<Hash>] Array of {path:, filename:}
    # @param entity_type [String] 'character' or 'property'
    # @param entity_id [Integer] ID of the character or room
    # @return [Hash] Mapping of original_filename => new_url
    def upload_images_from_package(temp_dir, image_files, entity_type, entity_id)
      ensure_upload_directory!

      url_mapping = {}

      begin
        image_files.each do |img|
          begin
            next unless File.exist?(img[:path])
            next if File.size(img[:path]) > MAX_IMAGE_SIZE

            # Generate unique filename
            ext = File.extname(img[:filename]).downcase
            ext = '.jpg' unless ALLOWED_IMAGE_TYPES.include?(ext)
            new_filename = "#{entity_type}_#{entity_id}_#{SecureRandom.hex(8)}#{ext}"
            new_path = File.join(UPLOAD_DIR, new_filename)

            FileUtils.cp(img[:path], new_path)
            url_mapping[img[:filename]] = "/uploads/content_packages/#{new_filename}"
          rescue StandardError => e
            warn "[ContentPackageService] Failed to copy image #{img[:filename]}: #{e.message}"
          end
        end
      ensure
        # Cleanup temp directory
        FileUtils.rm_rf(temp_dir) if temp_dir && Dir.exist?(temp_dir)
      end

      url_mapping
    end

    # Download an image from a URL
    # @param url [String] The URL to download from
    # @param target_path [String] Where to save the file
    # @return [Boolean] True if successful
    def download_image(url, target_path)
      return false if url.nil? || url.empty?
      return false if url.start_with?('images/') # Relative URL in export, skip

      # Handle local URLs
      if url.start_with?('/')
        return false unless url.start_with?('/uploads/')

        public_dir = File.join(File.expand_path('../../..', __dir__), 'public')
        uploads_dir = File.expand_path(File.join(public_dir, 'uploads'))
        relative_url = url.sub(%r{\A/}, '')
        local_path = File.expand_path(File.join(public_dir, relative_url))
        unless local_path == uploads_dir || local_path.start_with?("#{uploads_dir}#{File::SEPARATOR}")
          warn "[ContentPackageService] Blocked local path traversal attempt: #{url}"
          return false
        end

        if File.file?(local_path)
          FileUtils.cp(local_path, target_path)
          return true
        end
        return false
      end

      # Handle remote URLs — block requests to internal/private networks
      # NOTE: We use get_response (not open-uri/get) which does NOT follow redirects.
      # If redirect-following is ever added, re-validate DNS on each hop to prevent SSRF.
      begin
        uri = URI.parse(url)
        return false unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)

        # In production, require HTTPS
        if ENV['RACK_ENV'] == 'production' && !uri.is_a?(URI::HTTPS)
          warn "[ContentPackageService] Blocked non-HTTPS URL in production: #{uri.host}"
          return false
        end

        # Block requests to private/internal IPs
        resolved = Addrinfo.getaddrinfo(uri.host, nil, :INET).first
        if resolved
          ip = IPAddr.new(resolved.ip_address)
          if ip.private? || ip.loopback? || ip.link_local?
            warn "[ContentPackageService] Blocked SSRF attempt to #{uri.host}"
            return false
          end
        end

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.is_a?(URI::HTTPS)
        http.open_timeout = 5
        http.read_timeout = 10
        response = http.request(Net::HTTP::Get.new(uri))
        return false unless response.is_a?(Net::HTTPSuccess)

        # Check Content-Length before reading body into memory
        content_length = response['Content-Length']&.to_i
        if content_length && content_length > MAX_IMAGE_SIZE
          warn "[ContentPackageService] Remote image too large: #{content_length} bytes"
          return false
        end

        body = response.body
        if body.bytesize > MAX_IMAGE_SIZE
          warn "[ContentPackageService] Remote image body too large: #{body.bytesize} bytes"
          return false
        end

        File.open(target_path, 'wb') { |f| f.write(body) }

        # Validate downloaded file is actually an image via magic bytes
        unless valid_image_file?(target_path)
          warn "[ContentPackageService] Downloaded file is not a valid image: #{url}"
          File.delete(target_path) if File.exist?(target_path)
          return false
        end

        true
      rescue Net::OpenTimeout, Net::ReadTimeout => e
        warn "[ContentPackageService] Timeout downloading #{url}: #{e.message}"
        false
      rescue StandardError => e
        warn "[ContentPackageService] Failed to download #{url}: #{e.message}"
        false
      end
    end

    # Clean up old temporary directories
    def cleanup_temp_dirs(max_age_hours = 24)
      return 0 unless Dir.exist?(TEMP_DIR)

      deleted = 0
      cutoff = Time.now - (max_age_hours * 3600)

      Dir.glob(File.join(TEMP_DIR, '*')).each do |dir|
        next unless File.directory?(dir)
        next unless File.mtime(dir) < cutoff

        FileUtils.rm_rf(dir)
        deleted += 1
      end

      deleted
    end

    private

    def create_local_package(json_data, images, output_name)
      output_dir = File.join(local_export_dir, output_name)
      FileUtils.mkdir_p(output_dir)

      # Write JSON
      json_path = File.join(output_dir, 'data.json')
      File.write(json_path, JSON.pretty_generate(json_data))

      # Create images subdirectory
      images_dir = File.join(output_dir, 'images')
      FileUtils.mkdir_p(images_dir)

      # Download images
      images.each do |img|
        target_path = File.join(images_dir, img[:filename])
        download_image(img[:original_url], target_path)
      end

      { path: output_dir, success: true }
    end

    def create_download_package(json_data, images, output_name)
      # Create in-memory ZIP
      zip_buffer = Zip::OutputStream.write_buffer do |zip|
        # Add JSON data
        zip.put_next_entry('data.json')
        zip.write(JSON.pretty_generate(json_data))

        # Download and add images
        images.each do |img|
          next if img[:original_url].nil? || img[:original_url].empty?

          # Create temp file for download
          Tempfile.create(['img', File.extname(img[:filename])]) do |temp|
            if download_image(img[:original_url], temp.path)
              temp.rewind
              zip.put_next_entry("images/#{img[:filename]}")
              zip.write(temp.read)
            end
          end
        end
      end

      zip_buffer.rewind
      filename = "#{output_name}_#{Time.now.strftime('%Y%m%d_%H%M%S')}.zip"

      {
        zip_data: zip_buffer.read,
        filename: filename,
        success: true
      }
    end

    def image_file?(filename)
      ALLOWED_IMAGE_TYPES.include?(File.extname(filename).downcase)
    end

    # Validate a file on disk is actually an image by checking magic bytes
    def valid_image_file?(path)
      return false unless File.exist?(path)

      header = File.binread(path, 12)
      return false unless header && header.bytesize >= 3

      case header
      when /\A\x89PNG/n then true
      when /\A\xFF\xD8\xFF/n then true
      when /\AGIF8/n then true
      when /\ARIFF....WEBP/n then header.bytesize >= 12
      else false
      end
    end

    def ensure_upload_directory!
      FileUtils.mkdir_p(UPLOAD_DIR) unless Dir.exist?(UPLOAD_DIR)
    end
  end
end
