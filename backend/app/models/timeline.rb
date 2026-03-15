# frozen_string_literal: true

class Timeline < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  TIMELINE_TYPES = %w[snapshot historical].freeze
  DEFAULT_RESTRICTIONS = {
    'no_death' => true,
    'no_prisoner' => true,
    'no_xp' => true,
    'rooms_read_only' => true
  }.freeze

  many_to_one :reality
  many_to_one :source_character, class: :Character, key: :source_character_id
  many_to_one :zone
  many_to_one :snapshot, class: :CharacterSnapshot, key: :snapshot_id
  one_to_many :character_instances, key: :timeline_id
  one_to_many :items, class: :Item, key: :timeline_id

  def validate
    super
    validates_presence [:reality_id, :timeline_type, :name]
    validates_includes TIMELINE_TYPES, :timeline_type
    validates_unique :reality_id
    validates_max_length 200, :name
    validates_max_length 100, :era, allow_nil: true

    # Historical timelines require both year and zone
    if timeline_type == 'historical'
      validates_presence [:year, :zone_id]
    end

    # Snapshot timelines require a snapshot
    if timeline_type == 'snapshot'
      validates_presence [:snapshot_id]
    end
  end

  # Type checks
  def snapshot?
    timeline_type == 'snapshot'
  end

  def historical?
    timeline_type == 'historical'
  end

  def past_timeline?
    snapshot? || historical?
  end

  # Restriction checks
  def parsed_restrictions
    return {} if restrictions.nil?

    if restrictions.is_a?(String)
      begin
        JSON.parse(restrictions)
      rescue JSON::ParserError => e
        warn "[Timeline] Invalid JSON in restrictions for timeline #{id}: #{e.message}"
        {}
      end
    else
      restrictions
    end
  end

  def restriction_active?(restriction_name)
    parsed_restrictions[restriction_name] == true
  end

  def no_death?
    restriction_active?('no_death')
  end

  def no_prisoner?
    restriction_active?('no_prisoner')
  end

  def no_xp?
    restriction_active?('no_xp')
  end

  def rooms_read_only?
    rooms_read_only || restriction_active?('rooms_read_only')
  end

  # Create a new historical timeline for a year/zone combination
  # Global shared timelines - all characters in same year/zone see each other
  def self.find_or_create_historical(year:, zone:, created_by: nil)
    DB.transaction do
      existing = first(
        timeline_type: 'historical',
        year: year,
        zone_id: zone.id,
        is_active: true
      )
      return existing if existing

      reality = Reality.create(
        name: "Year #{year} - #{zone.name}",
        reality_type: 'flashback',
        time_offset: 0
      )

      create(
        reality_id: reality.id,
        timeline_type: 'historical',
        name: "Year #{year} - #{zone.name}",
        year: year,
        zone_id: zone.id,
        source_character_id: created_by&.id,
        restrictions: Sequel.pg_jsonb_wrap(DEFAULT_RESTRICTIONS),
        is_active: true,
        rooms_read_only: true
      )
    end
  rescue Sequel::UniqueConstraintViolation
    first(
      timeline_type: 'historical',
      year: year,
      zone_id: zone.id,
      is_active: true
    ) || raise
  end

  # Create a timeline from a snapshot
  def self.find_or_create_from_snapshot(snapshot)
    DB.transaction do
      existing = first(snapshot_id: snapshot.id, is_active: true)
      return existing if existing

      reality = Reality.create(
        name: "Snapshot: #{snapshot.name}",
        reality_type: 'flashback',
        time_offset: 0
      )

      create(
        reality_id: reality.id,
        timeline_type: 'snapshot',
        name: snapshot.name,
        snapshot_id: snapshot.id,
        source_character_id: snapshot.character_id,
        restrictions: Sequel.pg_jsonb_wrap(DEFAULT_RESTRICTIONS),
        is_active: true,
        rooms_read_only: true
      )
    end
  rescue Sequel::UniqueConstraintViolation
    first(snapshot_id: snapshot.id, is_active: true) || raise
  end

  # Get the display name for this timeline
  def display_name
    if historical?
      (era && !era.to_s.strip.empty?) ? "#{year} #{era} - #{zone&.name}" : "Year #{year} - #{zone&.name}"
    else
      name
    end
  end

  # Deactivate this timeline
  def deactivate!
    update(is_active: false)
  end

  # Check if anyone is currently using this timeline
  def in_use?
    character_instances_dataset.where(online: true).any?
  end
end
