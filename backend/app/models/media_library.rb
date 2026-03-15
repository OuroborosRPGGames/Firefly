# frozen_string_literal: true

class MediaLibrary < Sequel::Model(:media_library)
  plugin :validation_helpers
  plugin :timestamps

  # Explicitly set primary key since database uses 'id'
  set_primary_key :id

  many_to_one :character

  # Database columns: media_type, name, content
  # These are standard Sequel column accessors, no aliasing needed

  # Legacy aliases for backward compatibility with old code
  def mtype
    media_type
  end

  def mtype=(val)
    self.media_type = val
  end

  def mname
    name
  end

  def mname=(val)
    self.name = val
  end

  def mtext
    content
  end

  def mtext=(val)
    self.content = val
  end

  MEDIA_TYPES = %w[gradient pic vid tpic tvid].freeze

  def validate
    super
    validates_presence [:character_id, :media_type, :name, :content]
    validates_includes MEDIA_TYPES, :media_type
    validates_max_length 100, :name
    validates_unique [:character_id, :name], message: 'already exists'
  end

  # Find by name (case-insensitive)
  def self.find_by_name(character, find_name)
    first(character_id: character.id) { Sequel.ilike(:name, find_name) }
  end

  # Get all gradients for a character
  def self.gradients_for(character)
    where(character_id: character.id, media_type: 'gradient').order(:name)
  end

  # Get all pictures for a character
  def self.pictures_for(character)
    where(character_id: character.id, media_type: %w[pic tpic]).order(:name)
  end

  # Get all videos for a character
  def self.videos_for(character)
    where(character_id: character.id, media_type: %w[vid tvid]).order(:name)
  end

  # Get all items for a character
  def self.for_character(character)
    where(character_id: character.id).order(:name)
  end

  def gradient?
    media_type == 'gradient'
  end

  def picture?
    %w[pic tpic].include?(media_type)
  end

  def video?
    %w[vid tvid].include?(media_type)
  end

  def text_based?
    %w[tpic tvid].include?(media_type)
  end

  # Enhanced gradient data (JSONB)
  # Structure: { version: 2, colors: [...], easings: [...], interpolation: 'ciede2000' }
  def gradient_data
    self[:gradient_data] || {}
  end

  def gradient_data=(val)
    self[:gradient_data] = val.is_a?(Hash) ? Sequel.pg_jsonb_wrap(val) : val
  end

  # Get colors from either gradient_data or legacy mtext format
  def gradient_colors
    if gradient_data['colors'].is_a?(Array)
      gradient_data['colors']
    elsif content && !content.to_s.empty?
      content.split(',').map(&:strip)
    else
      []
    end
  end

  # Get easings for alternating stops (2nd, 4th, 6th...)
  def gradient_easings
    gradient_data['easings'] || []
  end

  # Check if using CIEDE2000 interpolation
  def ciede2000?
    gradient_data['interpolation'] == 'ciede2000'
  end
end
