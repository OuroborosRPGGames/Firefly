# frozen_string_literal: true

require 'kramdown'

require_relative '../data/help_system_definitions'
# HelpSystem model for system-level documentation
#
# Groups related commands together with overview descriptions
# and staff notes for implementation architecture details.
#
# New fields for comprehensive documentation:
# - player_guide: Full markdown player documentation
# - staff_guide: Full markdown staff documentation (implementation details)
# - quick_reference: Command quick reference card
# - constants_json: Extracted constants with values for staff reference
#
class HelpSystem < Sequel::Model
  plugin :timestamps, update_on_create: true
  plugin :validation_helpers

  # Ensure array columns are handled as pg arrays
  def before_save
    self.command_names = Sequel.pg_array(command_names || [], :text) if command_names.is_a?(Array)
    self.related_systems = Sequel.pg_array(related_systems || [], :text) if related_systems.is_a?(Array)
    self.key_files = Sequel.pg_array(key_files || [], :text) if key_files.is_a?(Array)
    # Ensure constants_json is valid JSONB
    if constants_json.is_a?(Hash) || constants_json.is_a?(Array)
      self.constants_json = Sequel.pg_jsonb_wrap(constants_json)
    elsif constants_json.is_a?(String) && !constants_json.empty?
      begin
        parsed = JSON.parse(constants_json)
        self.constants_json = Sequel.pg_jsonb_wrap(parsed)
      rescue JSON::ParserError
        # Keep as-is if parsing fails
      end
    end
    super
  end

  # Validations
  def validate
    super
    validates_presence [:name]
    validates_unique :name
    validates_max_length 50, :name
    validates_max_length 100, :display_name, allow_nil: true
    validates_max_length 500, :summary, allow_nil: true
  end

  # Aliases for system names (alternate name → canonical name)
  SYSTEM_ALIASES = {
    'activities' => 'missions',
    'activity' => 'missions',
    'heists' => 'missions',
    'items' => 'items_economy',
    'economy' => 'items_economy',
    'roleplaying' => 'roleplay_scenes',
    'scenes' => 'roleplay_scenes',
    'cards' => 'cards_games',
    'games' => 'cards_games',
    'info' => 'help_info',
    'help' => 'help_info',
    'ui' => 'commands_ui',
    'commands' => 'commands_ui'
  }.freeze

  # Find by name (case-insensitive), checking aliases if no direct match
  # @param system_name [String]
  # @return [HelpSystem, nil]
  def self.find_by_name(system_name)
    return nil if StringHelper.blank?(system_name)

    normalized = system_name.downcase.strip
    result = first(Sequel.function(:lower, :name) => normalized)
    return result if result

    # Check aliases
    canonical = SYSTEM_ALIASES[normalized]
    return nil unless canonical

    first(Sequel.function(:lower, :name) => canonical)
  end

  # Get all systems ordered for display
  # @return [Array<HelpSystem>]
  def self.ordered
    order(:display_order, :name).all
  end

  # Get commands for this system from the helpfiles table
  # @return [Array<Helpfile>]
  def helpfiles
    return [] if command_names.nil? || command_names.empty?

    Helpfile.where(command_name: command_names.to_a).all
  end

  # Get related HelpSystem objects
  # @return [Array<HelpSystem>]
  def related
    return [] if related_systems.nil? || related_systems.empty?

    self.class.where(name: related_systems.to_a).all
  end

  # Format for player display
  # @return [String]
  def to_player_display
    lines = []
    lines << "<h3>#{display_name || name.capitalize}</h3>"
    lines << summary if summary && !summary.empty?
    lines << ''

    if description && !description.empty?
      lines << description
      lines << ''
    end

    if command_names && !command_names.empty?
      lines << 'Commands:'
      helpfiles.each do |hf|
        lines << "  #{hf.command_name.ljust(12)} - #{hf.summary}"
      end
      lines << ''
    end

    if related_systems && !related_systems.empty?
      lines << "Related: #{related_systems.to_a.join(', ')}"
    end

    lines.join("\n")
  end

  # Format for staff display (includes implementation details)
  # @return [String]
  def to_staff_display
    lines = [to_player_display]

    if staff_notes && !staff_notes.empty?
      lines << ''
      lines << '<h4>Staff Information</h4>'
      lines << staff_notes
    end

    if key_files && !key_files.empty?
      lines << ''
      lines << 'Key Files:'
      key_files.to_a.each do |file|
        lines << "  - #{file}"
      end
    end

    lines.join("\n")
  end

  # Format for API/agent consumption
  # @return [Hash]
  def to_agent_format
    {
      name: name,
      display_name: display_name,
      summary: summary,
      description: description,
      player_guide: player_guide,
      quick_reference: quick_reference,
      command_names: command_names&.to_a || [],
      related_systems: related_systems&.to_a || [],
      staff_notes: staff_notes,
      staff_guide: staff_guide,
      key_files: key_files&.to_a || [],
      constants: parsed_constants
    }
  end

  # Render player_guide markdown to HTML
  # @return [String, nil]
  def player_guide_html
    return nil if player_guide.nil? || player_guide.strip.empty?

    Kramdown::Document.new(player_guide, input: 'GFM', hard_wrap: false).to_html
  end

  # Render staff_guide markdown to HTML
  # @return [String, nil]
  def staff_guide_html
    return nil if staff_guide.nil? || staff_guide.strip.empty?

    Kramdown::Document.new(staff_guide, input: 'GFM', hard_wrap: false).to_html
  end

  # Render staff_notes markdown to HTML
  # @return [String, nil]
  def staff_notes_html
    return nil if staff_notes.nil? || staff_notes.strip.empty?

    Kramdown::Document.new(staff_notes, input: 'GFM', hard_wrap: false).to_html
  end

  # Render quick_reference markdown to HTML
  # @return [String, nil]
  def quick_reference_html
    return nil if quick_reference.nil? || quick_reference.strip.empty?

    Kramdown::Document.new(quick_reference, input: 'GFM', hard_wrap: false).to_html
  end

  # Parse constants_json into a structured hash
  # @return [Hash]
  def parsed_constants
    return {} if constants_json.nil?

    case constants_json
    when Hash
      constants_json
    when String
      begin
        JSON.parse(constants_json)
      rescue JSON::ParserError
        {}
      end
    else
      constants_json.to_h rescue {}
    end
  end

  # Check if system has comprehensive documentation
  # @return [Boolean]
  def has_player_guide?
    !player_guide.nil? && !player_guide.strip.empty?
  end
  alias player_guide? has_player_guide?

  # Check if system has staff documentation
  # @return [Boolean]
  def has_staff_guide?
    !staff_guide.nil? && !staff_guide.strip.empty?
  end
  alias staff_guide? has_staff_guide?

  # Seed default systems and remove any that are no longer defined
  # @return [Integer] number of systems created/updated
  def self.seed_defaults!
    count = 0
    gn = GameSetting.get('game_name') || 'Firefly'
    defined_names = SYSTEM_DEFINITIONS.map { |d| d[:name] }

    SYSTEM_DEFINITIONS.each do |defn|
      # Substitute game name in text fields
      resolved = defn.dup
      if gn != 'Firefly'
        %i[description extended_help].each do |field|
          resolved[field] = resolved[field].gsub('Firefly', gn) if resolved[field].is_a?(String)
        end
      end

      existing = find_by_name(resolved[:name])
      if existing
        existing.update(resolved)
      else
        create(resolved)
      end
      count += 1
    end

    # Remove systems no longer in SYSTEM_DEFINITIONS
    where(Sequel.~(name: defined_names)).delete

    count
  end

  # Default system definitions — 21 consolidated help system categories
  SYSTEM_DEFINITIONS = HelpSystemDefinitions::SYSTEM_DEFINITIONS
end
