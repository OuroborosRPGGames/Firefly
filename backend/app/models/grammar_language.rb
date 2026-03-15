# frozen_string_literal: true

class GrammarLanguage < Sequel::Model
  VALID_STATUSES = %w[pending downloading ready error].freeze

  SUPPORTED_LANGUAGES = [
    { code: 'en', name: 'English (US)', estimated_size: '8.2 GB' },
    { code: 'fr', name: 'French', estimated_size: '3.5 GB' },
    { code: 'de', name: 'German', estimated_size: '6.2 GB' },
    { code: 'es', name: 'Spanish', estimated_size: '2.8 GB' },
    { code: 'nl', name: 'Dutch', estimated_size: '2.1 GB' },
    { code: 'pt', name: 'Portuguese', estimated_size: '1.9 GB' }
  ].freeze

  dataset_module do
    def ready
      where(status: 'ready')
    end
  end

  def initialize(values = {}, *args)
    values[:status] ||= 'pending'
    super
  end

  def validate
    super
    errors.add(:language_code, 'is required') if language_code.nil? || language_code.empty?
    errors.add(:language_name, 'is required') if language_name.nil? || language_name.empty?
    errors.add(:status, "must be one of: #{VALID_STATUSES.join(', ')}") unless VALID_STATUSES.include?(status)
  end

  def before_save
    self.updated_at = Time.now
    super
  end
end
