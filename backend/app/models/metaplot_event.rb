# frozen_string_literal: true

# MetaplotEvent tracks significant story events for continuity.
# Tagged with locations and characters for future reference.
class MetaplotEvent < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  many_to_one :location
  many_to_one :room

  EVENT_TYPES = %w[battle discovery betrayal alliance death resurrection
                   artifact political natural_disaster ceremony revelation].freeze
  SIGNIFICANCE = %w[minor notable major legendary].freeze

  def validate
    super
    validates_presence [:title, :summary, :event_type, :occurred_at]
    validates_max_length 200, :title
    validates_includes EVENT_TYPES, :event_type
    validates_includes SIGNIFICANCE, :significance if significance
  end

  def before_save
    super
    self.significance ||= 'minor'
    self.occurred_at ||= Time.now
    self.is_public ||= true
  end

  def legendary?
    significance == 'legendary'
  end

  def major?
    %w[major legendary].include?(significance)
  end

  def public?
    is_public
  end

  # Characters involved (stored as JSON array of IDs)
  def character_ids
    JSON.parse(characters_involved || '[]')
  end

  def add_character(character)
    ids = character_ids
    ids << character.id unless ids.include?(character.id)
    update(characters_involved: ids.to_json)
  end

  def involves?(character)
    character_ids.include?(character.id)
  end

  # Search events relevant to a location or character
  def self.involving_location(location)
    where(location_id: location.id).order(Sequel.desc(:occurred_at))
  end

  def self.involving_character(character)
    all.select { |e| e.involves?(character) }
  end

  def self.recent(days: 30)
    where { occurred_at > Time.now - (days * 86400) }
      .order(Sequel.desc(:occurred_at))
  end

  def self.major_events
    where(significance: %w[major legendary]).order(Sequel.desc(:occurred_at))
  end
end
