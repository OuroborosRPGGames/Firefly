# frozen_string_literal: true

require 'fileutils'
require 'shellwords'

class GrammarDownloadService
  CDN_URL_TEMPLATE = 'https://languagetool.org/download/ngram-data/ngrams-%s-20150817.zip'
  NGRAM_PATH = ENV.fetch('LT_NGRAM_PATH', '/opt/firefly/lt-ngrams')
  RESTART_SCRIPT = File.expand_path('../../scripts/languagetool.sh', __dir__)

  class << self
    def start_download(language_code)
      supported = GrammarLanguage::SUPPORTED_LANGUAGES.find { |l| l[:code] == language_code }
      return { success: false, error: "Language '#{language_code}' is not supported" } unless supported

      lang = GrammarLanguage.first(language_code: language_code)

      if lang&.status == 'downloading'
        return { success: false, error: "Language '#{language_code}' is already downloading" }
      end

      if lang
        lang.update(status: 'downloading', error_message: nil)
      else
        lang = GrammarLanguage.create(
          language_code: language_code,
          language_name: supported[:name],
          status: 'downloading'
        )
      end

      Thread.new do
        perform_download(language_code, lang.id)
      end

      { success: true }
    end

    def perform_download(language_code, lang_id)
      url = format(CDN_URL_TEMPLATE, language_code)
      temp_file = File.join(NGRAM_PATH, "#{language_code}.zip")
      lang_dir = File.join(NGRAM_PATH, language_code)

      FileUtils.mkdir_p(NGRAM_PATH)

      unless system_download(url, temp_file)
        update_status(lang_id, 'error', 'Download failed')
        FileUtils.rm_f(temp_file)
        return
      end

      FileUtils.mkdir_p(lang_dir)
      unless system_extract(temp_file, NGRAM_PATH)
        update_status(lang_id, 'error', 'Extraction failed')
        FileUtils.rm_f(temp_file)
        FileUtils.rm_rf(lang_dir)
        return
      end

      FileUtils.rm_f(temp_file)

      size = directory_size(lang_dir)
      update_status(lang_id, 'ready', nil, size)

      restart_container
    rescue Errno::ENOSPC => e
      warn "[GrammarDownloadService] Disk full: #{e.message}"
      cleanup_partial(language_code)
      update_status_safe(lang_id, 'error', 'Disk full — not enough space for n-gram data')
    rescue StandardError => e
      warn "[GrammarDownloadService] Download failed for #{language_code}: #{e.message}"
      cleanup_partial(language_code)
      update_status_safe(lang_id, 'error', e.message)
    end

    def remove_language(language_code)
      lang_dir = File.join(NGRAM_PATH, language_code)
      FileUtils.rm_rf(lang_dir) if File.exist?(lang_dir)

      lang = GrammarLanguage.first(language_code: language_code)
      lang&.update(status: 'pending', size_bytes: 0, error_message: nil)

      { success: true }
    end

    def cancel_download(language_code)
      cleanup_partial(language_code)
      lang = GrammarLanguage.first(language_code: language_code)
      lang&.update(status: 'pending', error_message: nil)
    end

    def status_summary
      {
        service_healthy: GrammarProxyService.healthy?,
        languages: GrammarLanguage.all.map do |l|
          {
            code: l.language_code,
            name: l.language_name,
            status: l.status,
            error_message: l.error_message,
            size_bytes: l.size_bytes,
            updated_at: l.updated_at&.iso8601
          }
        end
      }
    end

    # Public for testability (stubbed in specs). Implementation details.

    def system_download(url, dest)
      system("curl", "-fSL", "-o", dest, url)
    end

    def system_extract(zip_file, dest_dir)
      system("unzip", "-o", "-q", zip_file, "-d", dest_dir)
    end

    def restart_container
      system(RESTART_SCRIPT, "restart") if File.executable?(RESTART_SCRIPT)
    end

    def directory_size(path)
      return 0 unless File.directory?(path)
      `du -sb #{Shellwords.escape(path)} 2>/dev/null`.split("\t").first.to_i
    end

    private

    def update_status(lang_id, status, error_message = nil, size_bytes = nil)
      DB.synchronize do
        lang = GrammarLanguage[lang_id]
        return unless lang
        updates = { status: status, error_message: error_message }
        updates[:size_bytes] = size_bytes if size_bytes
        lang.update(updates)
      end
    end

    def update_status_safe(lang_id, status, error_message)
      update_status(lang_id, status, error_message)
    rescue StandardError => e
      warn "[GrammarDownloadService] Failed to update status: #{e.message}"
    end

    def cleanup_partial(language_code)
      temp_file = File.join(NGRAM_PATH, "#{language_code}.zip")
      lang_dir = File.join(NGRAM_PATH, language_code)
      FileUtils.rm_f(temp_file) if File.exist?(temp_file)
      FileUtils.rm_rf(lang_dir) if File.exist?(lang_dir)
    end
  end
end
