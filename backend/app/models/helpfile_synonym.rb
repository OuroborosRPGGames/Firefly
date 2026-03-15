# frozen_string_literal: true

# HelpfileSynonym model for alternative lookup terms
#
# Allows finding helpfiles by any of their synonyms/aliases.
# Provides fast O(1) lookup for help topics.
#
class HelpfileSynonym < Sequel::Model
  plugin :timestamps, update_on_create: true
  plugin :validation_helpers

  many_to_one :helpfile

  # Validations
  def validate
    super
    validates_presence [:helpfile_id, :synonym]
    validates_unique :synonym
  end

  # Normalize synonym before save
  def before_save
    self.synonym = synonym&.downcase&.strip
    super
  end

  # Find helpfile by synonym
  # @param term [String] search term
  # @return [Helpfile, nil]
  def self.find_helpfile(term)
    return nil if term.nil? || term.empty?

    synonym = first(synonym: term.downcase.strip)
    synonym&.helpfile
  end
end
