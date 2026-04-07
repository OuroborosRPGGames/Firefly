# frozen_string_literal: true

class HexDescriptionCache < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps, update: nil

  def validate
    super
    validates_presence [:template_hash, :template_text, :description]
    validates_unique :template_hash
  end

  class << self
    # Look up cached description by template hash
    # @param hash [String] SHA256 of template text
    # @return [HexDescriptionCache, nil]
    def find_by_hash(hash)
      first(template_hash: hash)
    end

    # Store a smoothed description for a template
    # @param template [String] the raw template text
    # @param hash [String] SHA256 of template text
    # @param description [String] LLM-smoothed description
    # @return [HexDescriptionCache]
    def store(template:, hash:, description:)
      # Use insert_conflict to handle race conditions from parallel threads
      insert_conflict(target: :template_hash, update: { description: description })
        .insert(template_hash: hash, template_text: template, description: description)
      find_by_hash(hash)
    rescue StandardError => e
      warn "[HexDescriptionCache] Store failed: #{e.message}"
      nil
    end
  end
end
