# frozen_string_literal: true

# Generates deterministic room descriptions based on a combo key.
# Same combo key always produces the same description, using seeded randomness.
#
# Combo key format: "<shape>:<exit_abbrev>:<content_flags...>"
# Example: "corridor:ns", "t_branch:nes:monster:trap_east"
class DelveRoomDescriptionService
  # Opposite direction pairs for shape classification
  OPPOSITE_PAIRS = [%w[north south].to_set, %w[east west].to_set].freeze

  # Direction sort order: n, e, s, w
  DIRECTION_ORDER = { 'north' => 0, 'east' => 1, 'south' => 2, 'west' => 3 }.freeze

  # Direction abbreviations
  DIRECTION_ABBREV = { 'north' => 'n', 'south' => 's', 'east' => 'e', 'west' => 'w' }.freeze

  # Pre-written description templates per shape
  DESCRIPTIONS = {
    'dead_end' => [
      'The passage terminates here in a rough-hewn alcove. Dust motes drift lazily in the stale air, undisturbed for ages.',
      'A cramped chamber marks the end of this branch. The walls press close, scarred with ancient chisel marks.',
      'The tunnel widens briefly into a small grotto before ending abruptly at a solid wall of unworked stone.',
      'This dead-end nook is damp, its walls slick with mineral deposits that catch the faintest light.',
      'The corridor reaches its terminus in a low-ceilinged vault. Old cobwebs drape the corners like tattered curtains.',
      'A tight chamber carved from the living rock. The air here is thick and still, carrying the scent of earth and age.',
      'The passage comes to a halt at a collapsed section. Rubble and fractured stone block any further progress.',
      'A quiet pocket in the dungeon, sheltered from drafts. The floor is worn smooth by some long-forgotten purpose.'
    ],
    'corridor' => [
      'A straight passage stretches onward, its walls bearing the regular marks of careful excavation.',
      'The corridor runs true, its floor worn smooth by countless footfalls over uncounted years.',
      'A long, narrow passage with walls that glisten faintly with moisture seeping from above.',
      'The tunnel extends in a straight line, its ceiling just high enough for comfortable passage.',
      'A well-worn corridor cuts through the stone. Shallow grooves in the floor suggest heavy traffic long ago.',
      'The passage is lined with crumbling mortar between precisely fitted stones, hinting at skilled builders.',
      'A drafty corridor where the air moves sluggishly, carrying distant echoes from deeper within.',
      'The tunnel stretches ahead, its walls marked by faded symbols scratched into the stone by unknown hands.'
    ],
    'l_turn' => [
      'The passage bends sharply here, the outer wall worn smooth where countless hands steadied themselves around the turn.',
      'A right-angle turn in the corridor. The stonework at the corner is reinforced with iron brackets.',
      'The tunnel curves abruptly, the geometry awkward as if the builders were forced to route around something.',
      'A sharp bend in the passage. A draft whistles around the corner, carrying unfamiliar scents.',
      'The corridor takes a decisive turn. Water stains along the inner wall trace the path of an old leak.',
      'A tight corner where the ceiling dips lower. The masonry here shows signs of hasty construction.',
      'The passage angles away sharply, its walls bearing the tool marks of two different excavation teams.',
      'A turning point in the corridor. Scratches on the floor suggest something heavy was once dragged around this bend.'
    ],
    't_branch' => [
      'The passage opens into a junction where three corridors meet. A worn flagstone at the center marks the crosspoint.',
      'A T-shaped intersection branches off into darkness. The air currents shift as passages compete for airflow.',
      'Three tunnels converge at this junction. The walls here are reinforced with heavy timber supports.',
      'A branching point where the corridor splits. Faded directional marks have been scratched into the wall.',
      'The passage meets a perpendicular tunnel, forming a junction. Boot prints in the dust lead in multiple directions.',
      'A three-way split in the corridor. The ceiling vaults higher here, giving the junction a sense of purpose.',
      'The tunnel branches at this junction. Each passage looks equally worn, offering no hint of preference.',
      'A crossroads of sorts where three corridors converge. The stone floor is cracked from the weight of ages.'
    ],
    'crossroads' => [
      'A grand intersection where four corridors converge. The vaulted ceiling rises above, lending this space an air of importance.',
      'Four passages radiate outward from this central hub. The floor bears a faded mosaic, mostly worn to bare stone.',
      'A crossroads in the depths. Each direction beckons with its own character of shadow and sound.',
      'The corridors meet at a wide junction, its corners rounded by years of passage. Echoes arrive from every direction.',
      'A four-way crossing in the dungeon. Shallow alcoves are carved into each corner, perhaps once holding torches.',
      'The intersection opens up into a modest chamber. The air is restless here, stirred by cross-drafts from all directions.',
      'Four tunnels branch from this hub. The architecture shifts subtly in each direction, as if built by different hands.',
      'A central nexus where passages converge. The ceiling bears soot stains from ages of torch-lit traffic.'
    ]
  }.freeze

  # Content-specific flavor text appended to descriptions
  CONTENT_TEXT = {
    'monster' => [
      ' Claw marks score the walls, and a foul stench lingers.',
      ' Scratches on the stone and scattered bones hint at a lurking presence.',
      ' A warning growl echoes faintly, and gnaw marks cover the nearby supports.',
      ' The air carries a foul smell, and something has made a den in the shadows.'
    ],
    'treasure' => [
      ' A faint glint catches the eye from a crevice in the wall.',
      ' Something gleams in the dust, half-hidden beneath loose stones.',
      ' A shimmer of gold peeks from behind a collapsed section of wall.',
      ' The air has a dry, precious quality, as if a hidden cache lies nearby.'
    ],
    'trap' => [
      ' Subtle pressure plates are visible beneath a thin layer of dust.',
      ' Strange runes are etched into the threshold, pulsing with faint energy.',
      ' A barely visible mechanism lurks in the stonework, waiting to be triggered.',
      ' The floor ahead looks slightly different, a telltale sign of a concealed trap.'
    ]
  }.freeze

  class << self
    # Build a combo key from exits and content flags.
    #
    # @param exits [Array<String>] cardinal directions (e.g., %w[north south])
    # @param content [Array<String>] content flags (e.g., %w[monster trap_east])
    # @return [String] combo key like "corridor:ns" or "t_branch:nes:monster:trap_east"
    def combo_key(exits:, content:)
      shape = classify_shape(exits)
      exit_abbrev = exits
                    .sort_by { |d| DIRECTION_ORDER[d] || 99 }
                    .map { |d| DIRECTION_ABBREV[d] || d[0] }
                    .join

      parts = [shape, exit_abbrev]
      parts.concat(content.sort) if content.any?
      parts.join(':')
    end

    # Generate a deterministic description for a combo key.
    #
    # @param combo_key [String] the combo key (e.g., "corridor:ns")
    # @return [String] the room description
    def description_for(combo_key:)
      shape = combo_key.split(':').first
      templates = DESCRIPTIONS[shape] || DESCRIPTIONS['corridor']

      # Use seeded random for deterministic selection
      rng = Random.new(combo_key.hash)
      base = templates[rng.rand(templates.length)]

      # Append content-specific flavor text
      content_suffix = content_text_for(combo_key, rng)
      "#{base}#{content_suffix}"
    end

    private

    # Classify room shape based on exit count and geometry.
    #
    # @param exits [Array<String>] cardinal directions
    # @return [String] shape name
    def classify_shape(exits)
      case exits.length
      when 0, 1
        'dead_end'
      when 2
        pair = exits.to_set
        if OPPOSITE_PAIRS.include?(pair)
          'corridor'
        else
          'l_turn'
        end
      when 3
        't_branch'
      else
        'crossroads'
      end
    end

    # Generate content-specific text based on flags in the combo key.
    #
    # @param combo_key [String] the combo key
    # @param rng [Random] seeded random generator
    # @return [String] additional flavor text (may be empty)
    def content_text_for(combo_key, rng)
      parts = combo_key.split(':')
      # Skip shape and exit_abbrev, rest are content flags
      flags = parts[2..] || []
      return '' if flags.empty?

      text = +''
      CONTENT_TEXT.each do |content_type, templates|
        # Match exact flag or flag prefix (e.g., "trap_south" matches "trap")
        if flags.any? { |f| f == content_type || f.start_with?("#{content_type}_") }
          text << templates[rng.rand(templates.length)]
        end
      end
      text
    end
  end
end
