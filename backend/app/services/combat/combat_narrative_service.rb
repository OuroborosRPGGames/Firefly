# frozen_string_literal: true

# Generates interlaced, detailed combat narrative from round events.
# Produces prose that reads like a real fight, not just a summary.
#
# Key features:
# - Events processed in segment order for proper temporal flow
# - Interlaced exchanges between combatants (back-and-forth, not grouped)
# - Weapon descriptions and switching
# - Movement and positioning
# - Ability/spell casting with effects
# - Damage summary at end: [Alpha takes X dmg(Y HP)]
#
# @example
#   service = CombatNarrativeService.new(fight)
#   narrative = service.generate
#
class CombatNarrativeService
  attr_reader :fight, :round_events

  # Number words for prose
  NUMBER_WORDS = {
    1 => 'one', 2 => 'two', 3 => 'three', 4 => 'four', 5 => 'five',
    6 => 'six', 7 => 'seven', 8 => 'eight', 9 => 'nine', 10 => 'ten',
    11 => 'eleven', 12 => 'twelve'
  }.freeze

  # Weapon-specific action descriptions
  # verb: participle for "batters...throwing", verb_3p: third person for "throws"
  WEAPON_ACTIONS = {
    unarmed: { verb: 'throwing', verb_3p: 'throws', noun: 'punches and kicks', noun_singular: 'blow', singular: 'a punch' },
    fists: { verb: 'throwing', verb_3p: 'throws', noun: 'punches', noun_singular: 'punch', singular: 'a punch' },
    sword: { verb: 'swinging', verb_3p: 'swings', noun: 'slashes', noun_singular: 'slash', singular: 'a slash' },
    blade: { verb: 'slashing', verb_3p: 'slashes', noun: 'cuts', noun_singular: 'cut', singular: 'a cut' },
    knife: { verb: 'stabbing', verb_3p: 'stabs', noun: 'thrusts', noun_singular: 'thrust', singular: 'a stab' },
    dagger: { verb: 'stabbing', verb_3p: 'stabs', noun: 'thrusts', noun_singular: 'thrust', singular: 'a stab' },
    axe: { verb: 'swinging', verb_3p: 'swings', noun: 'chops', noun_singular: 'chop', singular: 'a chop' },
    hammer: { verb: 'swinging', verb_3p: 'swings', noun: 'strikes', noun_singular: 'strike', singular: 'a strike' },
    club: { verb: 'swinging', verb_3p: 'swings', noun: 'swings', noun_singular: 'swing', singular: 'a swing' },
    staff: { verb: 'swinging', verb_3p: 'swings', noun: 'strikes', noun_singular: 'strike', singular: 'a strike' },
    spear: { verb: 'thrusting', verb_3p: 'thrusts', noun: 'thrusts', noun_singular: 'thrust', singular: 'a thrust' },
    pistol: { verb: 'firing', verb_3p: 'fires', noun: 'shots', noun_singular: 'shot', singular: 'a shot' },
    rifle: { verb: 'firing', verb_3p: 'fires', noun: 'shots', noun_singular: 'shot', singular: 'a shot' },
    gun: { verb: 'firing', verb_3p: 'fires', noun: 'shots', noun_singular: 'shot', singular: 'a shot' },
    bow: { verb: 'loosing', verb_3p: 'looses', noun: 'arrows', noun_singular: 'arrow', singular: 'an arrow' }
  }.freeze

  DEFAULT_WEAPON_ACTION = { verb: 'swinging', verb_3p: 'swings', noun: 'strikes', noun_singular: 'strike', singular: 'a strike' }.freeze

  # Touch descriptions for spar mode (verb phrases: "scores a touch on [target]")
  TOUCH_DESCRIPTIONS = {
    1 => ['scores a touch on', 'lands a clean hit on', 'tags', 'marks a point against'],
    2 => ['scores two touches on', 'lands two solid hits on', 'tags twice'],
    3 => ['scores three touches on', 'dominates with three hits on']
  }.freeze

  # Touch descriptions as noun phrases (for "inflicts X" pattern)
  TOUCH_NOUN_PHRASES = {
    1 => ['a touch', 'a clean hit', 'a solid tag', 'a scoring blow'],
    2 => ['two touches', 'two clean hits', 'two solid tags'],
    3 => ['three touches', 'three clean hits', 'a dominant series of hits'],
    4 => ['a devastating flurry of touches', 'four clean hits', 'an overwhelming barrage']
  }.freeze

  # Defensive stance descriptions (self-contained verb phrases)
  DEFEND_PHRASES = [
    'sets a defensive stance',
    'braces for incoming attacks',
    'raises their guard',
    'focuses on defense'
  ].freeze

  DODGE_PHRASES = [
    'weaves and dodges',
    'bobs and weaves',
    'ducks and sidesteps',
    'focuses on evasion'
  ].freeze

  SPRINT_PHRASES = [
    'sprints across the battlefield',
    'dashes across the arena',
    'breaks into a full sprint',
    'races across the ground'
  ].freeze

  PASS_PHRASES = [
    'holds position',
    'bides their time',
    'watches and waits',
    'stands their ground'
  ].freeze

  # Movement + attack integration phrases
  MOVEMENT_ATTACK_VERBS = {
    # Melee weapon + moving towards = approaching (not "charges"/"closes with" — separate message when they arrive in melee)
    melee_towards: ['moves toward', 'advances on', 'approaches', 'heads toward'],
    # Melee weapon + retreating = fighting withdrawal
    melee_away: ['backs away from', 'retreats from', 'disengages from'],
    # Ranged weapon + moving towards = advancing fire
    ranged_towards: ['advances on', 'closes in on', 'moves in on'],
    # Ranged weapon + retreating = covering fire
    ranged_away: ['retreats from', 'backs away from', 'falls back from'],
    # Standing still with ranged = steady aim
    ranged_still: ['takes aim at', 'opens fire on', 'targets'],
    # Standing still with melee = holding ground
    melee_still: ['faces off against', 'engages', 'squares up against']
  }.freeze

  # Weapon transition phrases for mid-round weapon switches
  # Direction-aware: towards (charging), away (retreating), still (stationary)
  WEAPON_TRANSITION_PHRASES = {
    ranged_to_melee_towards: [
      'closes to melee range, drawing',
      'charges in, switching to',
      'closes the distance and draws',
      'rushes in and pulls out'
    ],
    ranged_to_melee_still: [
      'switches to',
      'draws',
      'pulls out',
      'readies'
    ],
    ranged_to_melee_away: [
      'switches to',
      'draws',
      'pulls out',
      'readies'
    ],
    melee_to_ranged_towards: [
      'switches to',
      'brings up',
      'draws',
      'pulls out'
    ],
    melee_to_ranged_still: [
      'switches to',
      'brings up',
      'draws',
      'pulls out'
    ],
    melee_to_ranged_away: [
      'falls back, drawing',
      'disengages and switches to',
      'backs off and brings up',
      'retreats, pulling out'
    ]
  }.freeze

  # Ordinal words for attack position references
  ORDINAL_WORDS = {
    1 => 'first', 2 => 'second', 3 => 'third', 4 => 'fourth', 5 => 'fifth',
    6 => 'sixth', 7 => 'seventh', 8 => 'eighth', 9 => 'ninth', 10 => 'tenth'
  }.freeze

  # Miss flavor descriptions by weapon category
  MISS_FLAVORS = {
    melee: ['blocks', 'parries', 'deflects', 'turns aside', 'wards off', 'sidesteps'],
    ranged: ['goes wide', 'misses', 'whizzes past', 'sails overhead', 'flies wide', 'go astray']
  }.freeze

  # Spar mode miss flavors
  SPAR_MISS_FLAVORS = ['blocks', 'deflects', 'sidesteps', 'ducks under', 'wards off'].freeze

  # Impact descriptions by damage type and HP lost (1-4+)
  IMPACT_DESCRIPTIONS = {
    slashing: {
      1 => ['a cutting blow', 'a slash that draws blood', 'a shallow cut', 'a stinging slash'],
      2 => ['a deep gash', 'a vicious slash', 'two cutting blows', 'a brutal cut'],
      3 => ['a devastating slash', 'a savage cut that bites deep', 'three cutting blows', 'a near-severing strike'],
      4 => ['a horrific wound', 'a devastating series of cuts', 'a butchering assault', 'a near-fatal slash']
    },
    piercing: {
      1 => ['a clean stab', 'a puncture', 'a piercing thrust', 'a jab that finds its mark'],
      2 => ['a deep thrust', 'two piercing hits', 'a skewering blow', 'a vicious stab'],
      3 => ['a savage thrust', 'an impaling strike', 'three piercing hits', 'a devastating puncture'],
      4 => ['a mortal thrust', 'a gutting blow', 'a devastating series of thrusts', 'a run-through']
    },
    bludgeoning: {
      1 => ['a solid hit', 'a jarring blow', 'a stinging impact', 'a blow that connects'],
      2 => ['a staggering blow', 'a bone-jarring hit', 'two solid hits', 'a punishing strike'],
      3 => ['a crushing strike', 'a bone-breaking hit', 'three solid impacts', 'a devastating blow'],
      4 => ['a pulverizing strike', 'a shattering blow', 'a bone-crushing assault', 'a ruinous impact']
    },
    fire: {
      1 => ['a searing hit', 'a flash of burning pain', 'scorching contact'],
      2 => ['a blazing strike', 'searing burns', 'two scorching hits'],
      3 => ['an engulfing blast', 'devastating burns', 'an inferno of pain'],
      4 => ['a catastrophic conflagration', 'all-consuming flames', 'hellish burns']
    },
    cold: {
      1 => ['a numbing hit', 'a frost-bitten strike', 'a chilling blow'],
      2 => ['a freezing strike', 'a bone-chilling hit', 'two numbing blows'],
      3 => ['a devastating freeze', 'a glacial assault', 'three freezing strikes'],
      4 => ['a soul-freezing blow', 'a catastrophic freeze', 'an arctic devastation']
    },
    lightning: {
      1 => ['a shocking jolt', 'a crackling hit', 'an electric strike'],
      2 => ['a powerful shock', 'a convulsing jolt', 'two electric hits'],
      3 => ['a devastating shock', 'a thunderous strike', 'a chain of lightning'],
      4 => ['a catastrophic electrocution', 'a storm of lightning', 'a devastating arc']
    },
    acid: {
      1 => ['a stinging splash', 'a corrosive hit', 'burning acid'],
      2 => ['a dissolving strike', 'two acid burns', 'a caustic splash'],
      3 => ['a devastating acid burn', 'a flesh-melting strike', 'corrosive devastation'],
      4 => ['a catastrophic acid bath', 'a bone-deep burn', 'horrific dissolution']
    },
    poison: {
      1 => ['a toxic sting', 'a venomous hit', 'a poisonous strike'],
      2 => ['a debilitating dose', 'two toxic hits', 'a spreading poison'],
      3 => ['a devastating toxin', 'a lethal dose', 'overwhelming poison'],
      4 => ['a catastrophic poisoning', 'a near-fatal dose', 'system-wide toxicity']
    },
    psychic: {
      1 => ['a mind-splitting strike', 'a psychic jab', 'a disorienting hit'],
      2 => ['a staggering psychic blow', 'two mind-rending strikes', 'a searing mental assault'],
      3 => ['a devastating psychic attack', 'a mind-shattering strike', 'overwhelming mental agony'],
      4 => ['a catastrophic psychic assault', 'a soul-rending strike', 'total mental devastation']
    },
    radiant: {
      1 => ['a flash of holy fire', 'a searing radiance', 'a purifying strike'],
      2 => ['a blinding radiant blast', 'two holy strikes', 'searing divine light'],
      3 => ['a devastating radiant burst', 'an overwhelming holy fire', 'a soul-scorching blast'],
      4 => ['a catastrophic divine strike', 'an apocalyptic radiance', 'all-consuming holy fire']
    },
    necrotic: {
      1 => ['a draining touch', 'a withering strike', 'a chill of decay'],
      2 => ['a life-sapping blow', 'two withering strikes', 'a draining assault'],
      3 => ['a devastating drain', 'a flesh-rotting strike', 'overwhelming necrosis'],
      4 => ['a catastrophic drain', 'a soul-rending decay', 'near-fatal necrosis']
    },
    generic: {
      1 => ['a solid hit', 'a clean strike', 'a blow that connects', 'an impact that tells'],
      2 => ['a staggering blow', 'two solid hits', 'a punishing strike', 'a brutal combination'],
      3 => ['a devastating strike', 'three solid hits', 'a crushing assault', 'a brutal barrage'],
      4 => ['a catastrophic assault', 'a devastating barrage', 'a near-fatal beating', 'a ruinous onslaught']
    }
  }.freeze

  # Spar mode impact descriptions
  SPAR_IMPACT_DESCRIPTIONS = {
    1 => ['a clean tag', 'a solid touch', 'a scoring hit', 'a point'],
    2 => ['two clean tags', 'a quick one-two', 'two scoring touches', 'an impressive double-tap'],
    3 => ['three clean tags', 'a dominant flurry', 'three scoring touches', 'an impressive combination'],
    4 => ['a devastating flurry of tags', 'four clean touches', 'an overwhelming display', 'total dominance']
  }.freeze

  # Defense verbs for melee misses (used in patterns)
  MELEE_DEFENSE_VERBS = ['blocks', 'parries', 'deflects', 'turns aside', 'catches'].freeze

  # Ranged miss verbs
  RANGED_MISS_VERBS = ['go wide', 'miss', 'fly wide', 'go astray', 'sail past'].freeze

  def initialize(fight, enhance_prose: nil)
    @fight = fight
    @participant_cache = {}  # Must be initialized before parse_round_events
    @movement_by_actor = {}  # Movement context per actor
    @movement_timeline = {}  # Per-actor array of movement_step events sorted by segment
    @consumed_terrain_beats = {}  # Track which beats have been emitted per actor
    @round_events = parse_round_events
    @name_service = CombatNameAlternationService.new(fight)
    @wound_service = CombatWoundDescriptionService.new
    @damage_totals = Hash.new(0)
    @hit_counts = Hash.new(0)
    @miss_counts = Hash.new(0)
    # Auto-detect enhancement setting if not explicitly specified
    @enhance_prose = enhance_prose.nil? ? CombatProseEnhancementService.enabled? : enhance_prose
  end

  # Generate the full narrative for the round
  # @return [String] the narrative text
  def generate
    return 'The combatants size each other up...' if @round_events.empty?

    # Sort events by segment for proper temporal ordering
    sorted_events = @round_events.sort_by { |e| e[:segment] || 0 }

    # Separate different event types - movement extracted at round level
    movement_events = sorted_events.select { |e| %w[move movement_step].include?(e[:event_type]) }
    movement_blocked_events = sorted_events.select { |e| e[:event_type] == 'movement_blocked' }
    hazard_events = sorted_events.select { |e| e[:event_type] == 'hazard_damage' }
    combat_events = sorted_events.select { |e| attack_event?(e) }
    damage_events = sorted_events.select { |e| e[:event_type] == 'damage_applied' }
    knockout_events = sorted_events.select { |e| e[:event_type] == 'knockout' }

    # Track actors who had combat narrative (movement opening already included)
    @actors_in_combat = Set.new
    combat_events.each do |e|
      @actors_in_combat << e[:actor_id] if e[:actor_id]
    end

    # Build movement context for integrated descriptions
    @movement_by_actor = build_movement_context(movement_events)

    # Build per-actor movement timeline for terrain beat interlacing
    @movement_timeline = build_movement_timeline(movement_events)

    # Build the narrative
    paragraphs = []
    paragraphs << generate_opening

    # Generate interlaced combat narrative with integrated movement
    combat_narrative = generate_interlaced_narrative(combat_events)
    paragraphs << combat_narrative if combat_narrative && !combat_narrative.empty?

    # Describe movement for actors not covered by combat narrative
    # (e.g., all their attacks were out-of-range, or they had no attacks)
    movement_text = describe_uncovered_movement
    paragraphs << movement_text if movement_text && !movement_text.empty?

    # Describe non-attack stances (defend, dodge, sprint, pass)
    stance_text = describe_non_attack_stances
    paragraphs << stance_text if stance_text

    # Describe movement blocked (snared, etc.)
    blocked_text = describe_movement_blocked(movement_blocked_events)
    paragraphs << blocked_text if blocked_text

    # Add hazard damage descriptions
    hazard_text = describe_hazard_damage(hazard_events)
    paragraphs << hazard_text if hazard_text

    # Add knockout announcements inline if any
    knockout_text = generate_knockouts(knockout_events)
    paragraphs << knockout_text if knockout_text

    # Note: damage summary is now broadcast separately as combat_damage_summary
    # by CombatResolutionService, not appended to narrative text

    # Filter and enhance if enabled
    final_paragraphs = paragraphs.compact.reject(&:empty?)
    final_paragraphs = enhance_paragraphs(final_paragraphs) if @enhance_prose

    final_paragraphs.join("\n")
  end

  # Build movement context hash for each actor
  # @param movements [Array<Hash>] movement events
  # @return [Hash] actor_id => { direction:, target_name:, entered_melee: }
  def build_movement_context(movements)
    context = {}
    movements.group_by { |e| e[:actor_id] }.each do |actor_id, events|
      first_event = events.first
      last_event = events.last
      details = first_event[:details] || {}
      direction = details[:direction]
      target_name = details[:target_name]

      # For hex/maintain/generic movement, infer relative direction from position change
      # Compare start position (first event's old_x/y) to end position (last event's new_x/y)
      if direction && !%w[towards away stand_still].include?(direction)
        direction = infer_relative_direction(first_event, last_event, actor_id)
      end

      entered_melee = details[:entered_melee] || direction == 'towards'
      context[actor_id] = {
        direction: direction,
        target_name: target_name,
        entered_melee: entered_melee,
        moved: direction && direction != 'stand_still',
        # Terrain summary fields from hex data on movement_step events
        elevation_change: compute_elevation_change(events),
        elevation_delta: compute_elevation_delta(events),
        climbed_via: detect_climb_method(events),
        traversed_difficult: any_difficult_terrain?(events),
        traversed_water: detect_water_type(events),
        entered_cover: detect_cover_entry(events),
        left_cover: detect_cover_exit(events),
        notable_object: detect_notable_object(events)
      }
    end
    context
  end

  # Build per-actor movement timeline: array of movement_step events sorted by segment
  # @param movements [Array<Hash>] movement events
  # @return [Hash] actor_id => [movement_step events sorted by segment]
  def build_movement_timeline(movements)
    timeline = {}
    movements.select { |e| e[:event_type] == 'movement_step' }.group_by { |e| e[:actor_id] }.each do |actor_id, steps|
      timeline[actor_id] = steps.sort_by { |e| e[:segment] || 0 }
    end
    timeline
  end

  # Detect terrain beats (significant terrain transitions) for an actor's movement timeline
  # @param actor_id [Integer]
  # @return [Array<Hash>] array of beat hashes with :segment, :type, :object
  def terrain_beats_for_actor(actor_id)
    steps = @movement_timeline[actor_id] || []
    return [] if steps.empty?

    beats = []

    # Check first step for initial terrain beat (entering interesting terrain from starting position)
    first_beat = detect_first_step_beat(steps.first)
    beats << first_beat if first_beat

    # Check consecutive steps for transitions
    steps.each_cons(2) do |prev_step, curr_step|
      beat = detect_terrain_beat(prev_step, curr_step)
      beats << beat if beat
    end

    beats
  end

  # Detect a terrain beat from the first movement step (entering terrain from starting position)
  # @param step [Hash] first movement_step event
  # @return [Hash, nil] beat hash or nil
  def detect_first_step_beat(step)
    details = step[:details] || {}
    segment = step[:segment] || 0

    # Entering cover from no cover
    if details[:has_cover] && !details[:old_has_cover]
      return { segment: segment, type: :enter_cover, object: details[:cover_object] }
    end

    # Entering water
    if details[:water_type] && !details[:old_water_type]
      return { segment: segment, type: :water, detail: details[:water_type].to_s }
    end

    # Entering difficult terrain
    if details[:difficult_terrain] && !details[:old_difficult_terrain]
      return { segment: segment, type: :difficult }
    end

    # Elevation change on first step
    old_elev = details[:old_elevation_level]
    new_elev = details[:elevation_level]
    if old_elev && new_elev
      diff = new_elev.to_i - old_elev.to_i
      if diff > 0
        return { segment: segment, type: :elevation_up, object: details[:cover_object] }
      elsif diff < 0
        return { segment: segment, type: :elevation_down }
      end
    end

    nil
  end

  # Detect a terrain beat between two consecutive movement steps
  # @param prev_step [Hash] previous movement_step event
  # @param curr_step [Hash] current movement_step event
  # @return [Hash, nil] beat hash or nil
  def detect_terrain_beat(prev_step, curr_step)
    prev_details = prev_step[:details] || {}
    curr_details = curr_step[:details] || {}
    segment = curr_step[:segment] || 0

    # Elevation change
    prev_elev = prev_details[:elevation_level] || prev_details[:old_elevation_level]
    curr_elev = curr_details[:elevation_level]
    if prev_elev && curr_elev
      diff = curr_elev.to_i - prev_elev.to_i
      if diff > 0
        return { segment: segment, type: :elevation_up, object: curr_details[:cover_object] }
      elsif diff < 0
        return { segment: segment, type: :elevation_down }
      end
    end

    # Cover transitions
    prev_cover = prev_details[:has_cover]
    curr_cover = curr_details[:has_cover]
    if !prev_cover && curr_cover
      return { segment: segment, type: :enter_cover, object: curr_details[:cover_object] }
    elsif prev_cover && !curr_cover
      return { segment: segment, type: :leave_cover, object: prev_details[:cover_object] }
    end

    # Water entry
    prev_water = prev_details[:water_type]
    curr_water = curr_details[:water_type]
    if !prev_water && curr_water
      return { segment: segment, type: :water, detail: curr_water.to_s }
    end

    # Difficult terrain entry
    prev_difficult = prev_details[:difficult_terrain]
    curr_difficult = curr_details[:difficult_terrain]
    if !prev_difficult && curr_difficult
      return { segment: segment, type: :difficult }
    end

    nil
  end

  # Get terrain beats for an actor that fall between two segments (exclusive),
  # consuming them so they aren't repeated
  # @param actor_id [Integer]
  # @param after_segment [Integer] beats must be after this segment
  # @param before_segment [Integer] beats must be before this segment
  # @return [Array<Hash>] matching beats
  def pending_terrain_beats(actor_id, after_segment, before_segment)
    @terrain_beats_cache ||= {}
    @terrain_beats_cache[actor_id] ||= terrain_beats_for_actor(actor_id)
    @consumed_terrain_beats[actor_id] ||= Set.new

    beats = @terrain_beats_cache[actor_id].select do |beat|
      seg = beat[:segment]
      seg > after_segment && seg < before_segment && !@consumed_terrain_beats[actor_id].include?(beat.object_id)
    end

    beats.each { |beat| @consumed_terrain_beats[actor_id].add(beat.object_id) }
    beats
  end

  # Generate a terrain beat narrative sentence
  # @param actor_id [Integer]
  # @param beat [Hash] terrain beat hash
  # @return [String, nil]
  def terrain_beat_narrative(actor_id, beat)
    actor = participant(actor_id)
    return nil unless actor

    name = capitalize_name(name_for(actor))

    case beat[:type]
    when :elevation_up
      obj = humanize_cover_object(beat[:object])
      obj ? "#{name} climbs onto #{obj}." : "#{name} climbs to higher ground."
    when :elevation_down
      "#{name} drops to lower ground."
    when :enter_cover
      obj = humanize_cover_object(beat[:object])
      obj ? "#{name} ducks behind #{obj}." : "#{name} takes cover."
    when :leave_cover
      obj = humanize_cover_object(beat[:object])
      obj ? "#{name} breaks from #{obj}." : "#{name} leaves cover."
    when :water
      beat[:detail] == 'swimming' ? "#{name} plunges into deep water." : "#{name} splashes through water."
    when :difficult
      "#{name} picks through rough terrain."
    end
  end

  # Infer whether movement was towards or away from the actor's combat target
  # by comparing distances at start vs end of movement
  def infer_relative_direction(first_event, last_event, actor_id)
    first_details = first_event[:details] || {}
    last_details = last_event[:details] || {}

    old_x = first_details[:old_x]
    old_y = first_details[:old_y]
    new_x = last_details[:new_x]
    new_y = last_details[:new_y]

    return 'towards' unless old_x && old_y && new_x && new_y

    # Find this actor's combat target from attack events
    target_participant = find_attack_target_for(actor_id)
    return 'towards' unless target_participant

    target_x = target_participant.hex_x
    target_y = target_participant.hex_y
    return 'towards' unless target_x && target_y

    old_distance = HexGrid.hex_distance(old_x, old_y, target_x, target_y)
    new_distance = HexGrid.hex_distance(new_x, new_y, target_x, target_y)

    if new_distance < old_distance
      'towards'
    elsif new_distance > old_distance
      'away'
    else
      'towards' # Same distance = lateral movement, treat as neutral/towards
    end
  end

  # Find the combat target for an actor from attack events in this round
  def find_attack_target_for(actor_id)
    target_id = @round_events.find { |e| e[:actor_id] == actor_id && attack_event?(e) }&.dig(:target_id)
    target_id ? participant(target_id) : nil
  end

  private

  # Enhance paragraphs using LLM for more vivid prose
  # @param paragraphs [Array<String>] paragraphs to enhance
  # @return [Array<String>] enhanced paragraphs
  def enhance_paragraphs(paragraphs)
    service = CombatProseEnhancementService.new
    return paragraphs unless service.available?

    # Only enhance the combat narrative paragraphs, not opening/damage summary
    # Typically: opening (index 0), movement, combat, knockouts, damage summary (last)
    # We want to enhance movement and combat, skip opening and damage summary

    enhanced = paragraphs.dup

    # Identify paragraphs to enhance (skip round markers and damage summaries)
    enhanceable_indices = paragraphs.each_with_index.map do |para, idx|
      # Skip "Round X." openings
      next nil if para.match?(/\ARound \d+\.?\z/)
      # Skip damage summaries in brackets
      next nil if para.start_with?('[') && para.end_with?(']')
      # Skip very short paragraphs
      next nil if para.length < 20

      idx
    end.compact

    return paragraphs if enhanceable_indices.empty?

    # Extract paragraphs to enhance
    to_enhance = enhanceable_indices.map { |i| paragraphs[i] }

    # Build name mapping and pass to enhancement service
    name_mapping = build_name_mapping
    enhanced_texts = service.enhance_paragraphs(to_enhance, name_mapping: name_mapping)

    # Put enhanced texts back in place
    enhanceable_indices.each_with_index do |para_idx, enhance_idx|
      enhanced[para_idx] = enhanced_texts[enhance_idx]
    end

    enhanced
  end

  # Build mapping of full character names to simplified short names for LLM.
  # Simplifies names like "Linis 'Lin' Dao" to "Lin" to avoid LLM mangling
  # nickname quotes. Handles collisions by appending surname initial.
  # @return [Hash<String,String>] full_name => short_name
  def build_name_mapping
    mapping = {}
    participants = @fight.fight_participants_dataset.eager(:character_instance => :character).all

    # Collect entries where full_name differs from short_name
    entries = participants.filter_map do |p|
      char = p.character_instance&.character
      full = p.character_name
      short = p.short_name
      next if full == short

      { full_name: full, short_name: short, surname: char&.surname }
    end

    # Detect short_name collisions (case-insensitive)
    short_counts = entries.group_by { |e| e[:short_name]&.downcase }

    entries.each do |entry|
      group = short_counts[entry[:short_name]&.downcase]
      if group.length > 1 && entry[:surname] && !entry[:surname].to_s.strip.empty?
        # Disambiguate: "John S."
        entry[:short_name] = "#{entry[:short_name]} #{entry[:surname][0].upcase}."
      elsif group.length > 1
        next # can't disambiguate, skip simplification for this one
      end
      mapping[entry[:full_name]] = entry[:short_name]
    end

    mapping
  end

  def combat_event?(event)
    %w[hit miss move ability_hit ability_heal status_applied shot_blocked weapon_switch].include?(event[:event_type])
  end

  # Attack events only (excluding movement which is handled separately)
  # out_of_range is intentionally excluded — actors with no in-range attacks
  # simply don't appear in combat narrative; their movement opening explains positioning.
  def attack_event?(event)
    %w[hit miss ability_start ability_hit ability_heal status_applied shot_blocked weapon_switch].include?(event[:event_type])
  end

  def parse_round_events
    # Read from FightEvent records (source of truth from CombatResolutionService)
    fight_events = FightEvent.where(fight_id: fight.id, round_number: fight.round_number).all

    return [] if fight_events.empty?

    # Convert FightEvent records to the event hash format expected by narrative generation
    fight_events.map do |fe|
      details = parse_details(fe.details)

      # Look up names from participants if not in details
      actor_name = details[:actor_name] || lookup_participant_name(fe.actor_participant_id)
      target_name = details[:target_name] || lookup_participant_name(fe.target_participant_id)

      {
        segment: fe.segment,
        actor_id: fe.actor_participant_id,
        target_id: fe.target_participant_id,
        event_type: fe.event_type,
        details: details.merge(actor_name: actor_name, target_name: target_name),
        # Also include top-level copies for convenience
        actor_name: actor_name,
        target_name: target_name
      }
    end
  end

  def lookup_participant_name(participant_id)
    return nil unless participant_id

    p = participant(participant_id)
    p&.character_name
  end

  def parse_details(raw)
    return {} unless raw

    result = if raw.respond_to?(:to_h)
               raw.to_h
             elsif raw.is_a?(String)
               JSON.parse(raw, symbolize_names: true)
             elsif raw.is_a?(Hash)
               raw
             else
               {}
             end

    deep_symbolize_keys(result)
  rescue JSON::ParserError => e
    warn "[CombatNarrativeService] Failed to parse event details: #{e.message}"
    {}
  end

  def deep_symbolize_keys(hash)
    return hash unless hash.is_a?(Hash)

    hash.transform_keys(&:to_sym).transform_values do |v|
      v.is_a?(Hash) ? deep_symbolize_keys(v) : v
    end
  end

  def participant(id)
    @participant_cache[id] ||= FightParticipant[id]
  end

  def generate_opening
    ''
  end

  # Generate interlaced narrative from combat events
  def generate_interlaced_narrative(events)
    return nil if events.empty?

    # Cluster events by participant interactions (who attacks whom)
    # so each cluster becomes a separate narrative paragraph
    clusters = CombatInteractionClusterService.cluster(events)

    # Track which actors have already had a movement opening this round
    @actors_with_opening = Set.new

    if clusters.length > 1
      # Multiple clusters — narrate each group separately as its own paragraph
      parts = clusters.map do |cluster_ids|
        cluster_set = cluster_ids.to_set
        cluster_events = events.select do |e|
          actor = e[:actor_id]
          target = e[:target_id] || e.dig(:details, :target_participant_id)
          cluster_set.include?(actor) || cluster_set.include?(target)
        end
        next if cluster_events.empty?

        narrate_exchanges(cluster_events)
      end

      parts.compact.reject(&:empty?).join("\n\n")
    else
      # Single cluster or no clusters — use sequential exchange grouping
      narrate_exchanges(events)
    end
  end

  # Narrate a set of events: group into exchanges, consolidate all-miss exchanges,
  # then generate text for each — with terrain beats interlaced chronologically.
  def narrate_exchanges(events)
    exchanges = group_into_exchanges(events)

    # Classify exchanges as all-miss or not, tracking their target
    classified = exchanges.map do |exchange|
      has_hit = exchange.any? { |e| e[:event_type] == 'hit' }
      # An all-miss exchange is one where every attack event is a miss
      attack_events = exchange.select { |e| %w[hit miss].include?(e[:event_type]) }
      all_miss = attack_events.any? && !has_hit
      target_id = exchange.first&.dig(:target_id) || exchange.first&.dig(:details, :target_participant_id)
      { exchange: exchange, all_miss: all_miss, target_id: target_id }
    end

    # Group consecutive all-miss exchanges against the same defender
    result_parts = []
    last_segment = 0
    i = 0
    while i < classified.length
      entry = classified[i]

      # Insert terrain beats that occurred between last exchange and this one
      first_seg = entry[:exchange].first&.dig(:segment) || 0
      exchange_actors = entry[:exchange].map { |e| e[:actor_id] }.compact.uniq
      exchange_actors.each do |actor_id|
        beats = pending_terrain_beats(actor_id, last_segment, first_seg)
        beats.each do |beat|
          text = terrain_beat_narrative(actor_id, beat)
          result_parts << text if text
        end
      end

      if entry[:all_miss] && entry[:target_id]
        # Collect consecutive all-miss exchanges against the same target
        miss_group = [entry]
        j = i + 1
        while j < classified.length &&
              classified[j][:all_miss] &&
              classified[j][:target_id] == entry[:target_id]
          miss_group << classified[j]
          j += 1
        end

        last_seg_in_group = miss_group.last[:exchange].last&.dig(:segment) || last_segment

        if miss_group.length >= 3
          # Consolidate 3+ all-miss exchanges into one compact sentence
          text = consolidate_all_miss_exchanges(miss_group)
          result_parts << text if text && !text.empty?
          i = j
        else
          # 1-2 misses: narrate individually
          miss_group.each do |mg|
            text = generate_exchange_narrative(mg[:exchange])
            result_parts << text if text && !text.empty?
          end
          i = j
        end
        last_segment = last_seg_in_group
      else
        text = generate_exchange_narrative(entry[:exchange])
        result_parts << text if text && !text.empty?
        last_segment = entry[:exchange].last&.dig(:segment) || last_segment
        i += 1
      end
    end

    # Any remaining terrain beats after last exchange (post-combat movement)
    @movement_timeline.each_key do |actor_id|
      next unless events.any? { |e| e[:actor_id] == actor_id }

      beats = pending_terrain_beats(actor_id, last_segment, 101)
      beats.each do |beat|
        text = terrain_beat_narrative(actor_id, beat)
        result_parts << text if text
      end
    end

    result_parts.join(' ')
  end

  # Consolidate 3+ all-miss exchanges against the same defender into one sentence.
  # e.g., "Agent Charlie fends off Delve Spider's bite, Delve Rat's bite, and Delve Skeleton's slam."
  def consolidate_all_miss_exchanges(miss_group)
    target_id = miss_group.first[:target_id]
    target = participant(target_id)
    return nil unless target

    defender_name = capitalize_name(name_for(target))
    spar = @fight.spar_mode?
    pool = spar ? SPAR_MISS_FLAVORS : MISS_FLAVORS[:melee]

    # Build a list of "attacker's attack_noun" for each exchange
    attack_descriptions = miss_group.filter_map do |entry|
      exchange = entry[:exchange]
      actor_id = exchange.first&.dig(:actor_id)
      next unless actor_id

      actor = participant(actor_id)
      next unless actor

      attack_events = exchange.select { |e| %w[hit miss].include?(e[:event_type]) }
      next if attack_events.empty?

      attacker_name = name_for(actor)
      evt_weapon_type = attack_events.first&.dig(:details, :weapon_type)
      is_ranged = %w[ranged natural_ranged].include?(evt_weapon_type)
      action = weapon_action_for(actor, is_ranged: is_ranged, event_weapon_type: evt_weapon_type)
      count = attack_events.length

      if count == 1
        "#{attacker_name}'s #{action[:noun_singular]}"
      else
        "#{attacker_name}'s #{action[:noun]}"
      end
    end

    return nil if attack_descriptions.empty?

    verb = pool.sample
    attack_list = if attack_descriptions.length == 2
                    attack_descriptions.join(' and ')
                  else
                    "#{attack_descriptions[0..-2].join(', ')}, and #{attack_descriptions.last}"
                  end

    "#{defender_name} #{verb} #{attack_list}."
  end

  # Group events into exchanges based on participant interactions
  # An exchange is a back-and-forth between combatants
  def group_into_exchanges(events)
    return [] if events.empty?

    # For ability events, we need to keep ability_start with its corresponding ability_hit
    # So we'll group by actor for abilities, and by actor-target pair for regular attacks
    exchanges = []
    current_exchange = []
    current_pair = nil

    events.each do |event|
      actor_id = event[:actor_id]
      target_id = event[:target_id] || event.dig(:details, :target_participant_id)

      # Skip events without clear actor/target
      next unless actor_id

      # For ability events without targets (ability_start), use the actor as the pair key
      # This keeps ability_start grouped with the subsequent ability_hit from the same actor
      # Also include status_applied as it's often triggered by abilities
      is_ability_event = %w[ability_start ability_hit ability_heal status_applied].include?(event[:event_type])

      if is_ability_event
        # Group ability events by actor only, so start and hit stay together
        pair = [actor_id]
      else
        pair = [actor_id, target_id].compact.sort
        pair = [actor_id] if pair.empty?
      end

      if current_pair.nil? || current_pair == pair
        current_exchange << event
        current_pair = pair
      else
        # New pair - save current exchange and start new one
        exchanges << current_exchange unless current_exchange.empty?
        current_exchange = [event]
        current_pair = pair
      end
    end

    exchanges << current_exchange unless current_exchange.empty?
    exchanges
  end

  # Generate narrative for a single exchange between combatants
  # Note: Movement is handled at round level, not here
  def generate_exchange_narrative(events)
    return nil if events.empty?

    # Identify the combatants in this exchange
    actor_ids = events.map { |e| e[:actor_id] }.compact.uniq
    target_ids = events.map { |e| e[:target_id] || e.dig(:details, :target_participant_id) }.compact.uniq
    all_ids = (actor_ids + target_ids).uniq

    # Get participant objects
    participants = all_ids.map { |id| participant(id) }.compact
    return nil if participants.empty?

    # Tally hits and misses per actor (store events to get target info)
    hits_by_actor = Hash.new { |h, k| h[k] = [] }
    misses_by_actor = Hash.new { |h, k| h[k] = [] }
    ability_starts = []
    ability_effects = []
    status_events = []
    shot_blocked_events = []
    events.each do |event|
      actor_id = event[:actor_id]
      case event[:event_type]
      when 'hit'
        hits_by_actor[actor_id] << event
        @hit_counts[actor_id] += 1
        @damage_totals[event[:target_id]] += (event.dig(:details, :effective_damage) || event.dig(:details, :total) || 1)
      when 'miss'
        misses_by_actor[actor_id] << event
        @miss_counts[actor_id] += 1
      when 'ability_start'
        ability_starts << event
      when 'ability_hit', 'ability_heal'
        ability_effects << event
      when 'status_applied'
        status_events << event
      when 'shot_blocked'
        shot_blocked_events << event
      end
    end

    # Build the narrative
    parts = []

    # Ability cast announcements first (before effects resolve)
    ability_starts.each do |start_event|
      start_text = describe_ability_start(start_event)
      parts << start_text if start_text
    end

    # Describe the main combat exchange
    if hits_by_actor.any? || misses_by_actor.any?
      combat_text = describe_combat_exchange(hits_by_actor, misses_by_actor, participants)
      parts << combat_text if combat_text

      # Add partial cover narrative for attacks that passed through cover
      all_attacks = hits_by_actor.values.flatten + misses_by_actor.values.flatten
      cover_text = describe_partial_cover(all_attacks)
      parts << cover_text if cover_text
    end

    # Describe shots blocked by cover
    shot_blocked_events.each do |blocked_event|
      blocked_text = describe_shot_blocked(blocked_event)
      parts << blocked_text if blocked_text
    end

    # Describe ability effects (hits/heals)
    ability_effects.each do |ability_event|
      ability_text = describe_ability(ability_event)
      parts << ability_text if ability_text
    end

    # Describe status effects applied
    status_events.each do |status_event|
      status_text = describe_status_applied(status_event)
      parts << status_text if status_text
    end

    parts.join(' ')
  end

  # Describe hazard damage (fire, acid, etc.)
  def describe_hazard_damage(hazard_events)
    return nil if hazard_events.empty?

    descriptions = hazard_events.map do |event|
      details = event[:details] || {}
      target_name = event[:target_name] || details[:target_name]
      hazard_type = details[:hazard_type] || 'hazard'
      damage = details[:damage] || 0

      case hazard_type.to_s.downcase
      when 'fire', 'flames', 'burning'
        "#{target_name} stumbles through flames, taking #{damage} damage!"
      when 'acid', 'corrosive'
        "#{target_name} splashes through acid, suffering #{damage} damage!"
      when 'poison', 'toxic'
        "#{target_name} breathes toxic fumes, taking #{damage} damage!"
      when 'cold', 'ice', 'freezing'
        "#{target_name} wades through freezing terrain, taking #{damage} damage!"
      when 'electric', 'lightning', 'shocked'
        "#{target_name} is zapped by electrical discharge, taking #{damage} damage!"
      else
        "#{target_name} moves through dangerous terrain, taking #{damage} damage!"
      end
    end

    descriptions.join(' ')
  end

  # Describe a shot blocked by cover
  def describe_shot_blocked(event)
    details = event[:details] || {}
    actor_name = event[:actor_name] || details[:actor_name]
    target_name = event[:target_name] || details[:target_name]
    return nil unless actor_name && target_name

    obj = humanize_cover_object(details[:cover_object])
    cover_phrase = obj || 'cover'

    [
      "#{capitalize_name(actor_name)} fires at #{target_name}, but the shot strikes #{cover_phrase}.",
      "#{capitalize_name(actor_name)}'s shot is blocked by #{cover_phrase} before reaching #{target_name}.",
      "#{capitalize_name(actor_name)} takes a shot at #{target_name}, but it ricochets off #{cover_phrase}.",
      "#{capitalize_name(target_name)} is shielded behind #{cover_phrase} as #{actor_name}'s shot goes wide."
    ].sample
  end

  # Build a partial-cover clause for hit events where cover reduced damage
  # Returns a sentence like "the shot clips past a barrel, losing some of its force."
  # @param hit_events [Array<Hash>] hit events from one or more actors in this exchange
  # @return [String, nil]
  def describe_partial_cover(hit_events)
    # Find hits that had cover damage reduction
    cover_hits = hit_events.select { |e| e.dig(:details, :cover_damage_reduction) }
    return nil if cover_hits.empty?

    # Group by cover_object to avoid repeating the same object
    by_object = cover_hits.group_by { |e| e.dig(:details, :cover_object) }

    clauses = by_object.filter_map do |raw_obj, hits|
      obj = humanize_cover_object(raw_obj)
      target_name = hits.first[:target_name] || hits.first.dig(:details, :target_name)
      next unless target_name

      if obj
        [
          "The shot clips past #{obj}, losing some of its force.",
          "The shot grazes #{obj} on the way to #{target_name}, weakened by the cover.",
          "#{capitalize_name(target_name)}'s cover behind #{obj} absorbs part of the impact."
        ].sample
      else
        [
          "The shot punches through cover, losing some of its force.",
          "Cover absorbs part of the impact before the shot reaches #{target_name}."
        ].sample
      end
    end

    clauses.empty? ? nil : clauses.join(' ')
  end

  # Describe movement blocked by status effects (snare, etc.)
  def describe_movement_blocked(blocked_events)
    return nil if blocked_events.empty?

    descriptions = blocked_events.map do |event|
      details = event[:details] || {}
      actor_name = event[:actor_name] || details[:actor_name]
      next unless actor_name

      reason = details[:reason] || details[:status_effect]
      case reason.to_s.downcase
      when 'snared', 'snare'
        "#{capitalize_name(actor_name)} struggles against the snare, unable to move."
      when 'rooted'
        "#{capitalize_name(actor_name)} is rooted in place, unable to move."
      when 'stunned'
        "#{capitalize_name(actor_name)} is stunned and can't move."
      when 'frozen'
        "#{capitalize_name(actor_name)} is frozen solid, unable to move."
      else
        "#{capitalize_name(actor_name)} is held in place, unable to move."
      end
    end

    descriptions.compact.join(' ')
  end

  # Get movement-integrated opening for an actor
  # Returns a phrase like "advances on Alpha" or "retreats from Alpha, firing"
  def movement_attack_opening(actor_id, target_name, is_ranged: false)
    movement = @movement_by_actor[actor_id] || {}
    direction = movement[:direction]
    moved = movement[:moved]

    # Determine the key for verb lookup
    weapon_type = is_ranged ? :ranged : :melee
    if moved
      key = direction == 'away' ? "#{weapon_type}_away".to_sym : "#{weapon_type}_towards".to_sym
    else
      key = "#{weapon_type}_still".to_sym
    end

    verbs = MOVEMENT_ATTACK_VERBS[key] || MOVEMENT_ATTACK_VERBS[:melee_still]
    verb = verbs.sample

    # Build the phrase with optional terrain flavor
    phrase = if is_ranged && direction == 'away'
               "#{verb} #{target_name}, firing"
             else
               "#{verb} #{target_name}"
             end
    terrain_clause = movement_terrain_clause_short(movement)
    phrase = "#{phrase} #{terrain_clause}" if terrain_clause
    phrase
  end

  # Split events into phases by weapon type (melee vs ranged)
  # Returns array of phase hashes: [{ weapon_type: 'melee', events: [...] }, ...]
  def split_by_weapon_phase(events)
    return [{ weapon_type: 'melee', events: [] }] if events.empty?

    phases = []
    current_phase = { weapon_type: events.first.dig(:details, :weapon_type) || 'melee', events: [] }

    events.each do |event|
      wt = event.dig(:details, :weapon_type) || 'melee'
      if wt != current_phase[:weapon_type]
        phases << current_phase unless current_phase[:events].empty?
        current_phase = { weapon_type: wt, events: [] }
      end
      current_phase[:events] << event
    end
    phases << current_phase unless current_phase[:events].empty?
    phases
  end

  # Build a weapon transition phrase like "then closes to melee range, drawing his longsword"
  def weapon_transition_phrase(from_type, to_type, actor, to_is_ranged, actor_id: nil)
    # Use direction-aware transition phrase
    movement = actor_id ? (@movement_by_actor[actor_id] || {}) : {}
    direction = movement[:direction]
    dir_suffix = case direction
                 when 'towards' then '_towards'
                 when 'away' then '_away'
                 else '_still'
                 end

    key = "#{from_type}_to_#{to_type}#{dir_suffix}".to_sym
    phrases = WEAPON_TRANSITION_PHRASES[key]
    # Fallback to still variant if direction-specific key not found
    phrases ||= WEAPON_TRANSITION_PHRASES["#{from_type}_to_#{to_type}_still".to_sym]
    return nil unless phrases

    possessive = @name_service.possessive_for(actor)
    weapon_name = weapon_name_for(actor, is_ranged: to_is_ranged)
    weapon_short = weapon_name.gsub(/^(a|an|the|his|her|their)\s+/i, '')

    "then #{phrases.sample} #{possessive} #{weapon_short}"
  end

  # Describe participants who chose non-attack stances this round
  def describe_non_attack_stances
    participants = @fight.fight_participants.reject(&:is_knocked_out)
    descriptions = []

    participants.each do |p|
      case p.main_action
      when 'defend'
        descriptions << "#{capitalize_name(name_for(p))} #{DEFEND_PHRASES.sample}."
      when 'dodge'
        descriptions << "#{capitalize_name(name_for(p))} #{DODGE_PHRASES.sample}."
      when 'sprint'
        descriptions << "#{capitalize_name(name_for(p))} #{SPRINT_PHRASES.sample}."
      when 'pass'
        descriptions << "#{capitalize_name(name_for(p))} #{PASS_PHRASES.sample}."
      end
    end

    return nil if descriptions.empty?

    descriptions.join(' ')
  end

  # Describe movement for actors who weren't part of any combat narrative.
  # These are actors who moved but had no in-range attacks (all out-of-range),
  # so their movement opening was never generated by the combat exchange code.
  def describe_uncovered_movement
    return nil if @movement_by_actor.empty?

    # Only describe movement for actors NOT already covered by combat narrative
    uncovered = @movement_by_actor.select do |actor_id, movement|
      movement && movement[:moved] && !@actors_in_combat.include?(actor_id)
    end

    return nil if uncovered.empty?

    sentences = []
    uncovered.each do |actor_id, movement|
      actor = participant(actor_id)
      next unless actor

      actor_name = capitalize_name(name_for(actor))
      target_name = movement[:target_name] || 'their opponent'
      direction = movement[:direction]

      base = case direction
             when 'towards' then "#{actor_name} advances on #{target_name}"
             when 'away' then "#{actor_name} falls back from #{target_name}"
             else "#{actor_name} repositions"
             end

      clauses = movement_terrain_clauses(movement)
      cover_clause = movement_cover_clause(movement, actor_name)

      if clauses.any?
        sentences << "#{base}, #{clauses.join(' and ')}."
      else
        sentences << "#{base}."
      end
      sentences << cover_clause if cover_clause
    end

    return nil if sentences.empty?
    sentences.join(' ')
  end

  # Describe movement when no combat events exist at all in the round
  # Enriched with hex terrain data (elevation, water, cover, difficult terrain)
  def describe_movement_only
    sentences = []

    @movement_by_actor.each do |actor_id, movement|
      next unless movement[:moved]

      actor = participant(actor_id)
      next unless actor

      actor_name = capitalize_name(name_for(actor))
      target_name = movement[:target_name] || 'their opponent'
      direction = movement[:direction]

      base = case direction
             when 'towards' then "#{actor_name} advances on #{target_name}"
             when 'away' then "#{actor_name} falls back from #{target_name}"
             else "#{actor_name} repositions"
             end

      clauses = movement_terrain_clauses(movement)
      cover_clause = movement_cover_clause(movement, actor_name)

      if clauses.any?
        sentences << "#{base}, #{clauses.join(' and ')}."
      else
        sentences << "#{base}."
      end
      sentences << cover_clause if cover_clause
    end

    return nil if sentences.empty?
    sentences.join(' ')
  end

  # Describe a combat exchange with proper back-and-forth
  def describe_combat_exchange(hits_by_actor, misses_by_actor, participants)
    return nil if hits_by_actor.empty? && misses_by_actor.values.sum(&:length) == 0

    # Get actor/defender info
    actors = hits_by_actor.keys + misses_by_actor.keys
    actors = actors.uniq

    if actors.length == 1
      # One-sided attack
      describe_one_sided_attack(actors.first, hits_by_actor[actors.first], misses_by_actor[actors.first])
    elsif actors.length == 2
      # Exchange between two combatants
      describe_two_way_exchange(actors, hits_by_actor, misses_by_actor)
    else
      # Multi-way melee
      describe_melee(actors, hits_by_actor, misses_by_actor)
    end
  end

  # Describe one combatant attacking (defender is passive)
  def describe_one_sided_attack(actor_id, hits, misses)
    actor = participant(actor_id)
    return nil unless actor

    attacker_name = name_for(actor)
    # Ensure event_type is set so analyze_attack_sequence can classify correctly
    tagged_hits = (hits || []).map { |e| e[:event_type] ? e : e.merge(event_type: 'hit') }
    tagged_misses = (misses || []).map { |e| e[:event_type] ? e : e.merge(event_type: 'miss') }
    all_events = (tagged_hits + tagged_misses).sort_by { |e| e[:segment] || 0 }
    return nil if all_events.empty?

    target_id = all_events.first&.dig(:target_id) ||
                all_events.first&.dig(:details, :target_participant_id)
    target = target_id ? participant(target_id) : nil
    defender_name = target ? name_for(target) : 'their opponent'

    # Split events by weapon phase
    phases = split_by_weapon_phase(all_events)

    if phases.length <= 1
      # Single phase - existing logic
      evt_weapon_type = all_events.first&.dig(:details, :weapon_type)
      is_ranged = %w[ranged natural_ranged].include?(evt_weapon_type)
      action = weapon_action_for(actor, is_ranged: is_ranged, event_weapon_type: evt_weapon_type)
      weapon_name = weapon_name_for(actor, is_ranged: is_ranged)

      analysis = analyze_attack_sequence(all_events)
      attack_prose = describe_attack_pattern(analysis, attacker_name, defender_name, action[:noun], attack_noun_singular: action[:noun_singular])

      # Skip movement opening if this actor already had one this round
      if @actors_with_opening&.include?(actor_id)
        attack_prose
      else
        @actors_with_opening&.add(actor_id)
        movement_opening = build_movement_opening(actor_id, actor, defender_name, is_ranged, weapon_name, action)
        count_phrase = attack_count_phrase(analysis[:total_attacks], action)
        if count_phrase
          "#{movement_opening}, #{count_phrase}. #{attack_prose}"
        else
          "#{movement_opening}. #{attack_prose}"
        end
      end
    else
      # Multiple phases - describe each with transitions
      describe_multi_phase_attack(phases, actor_id, actor, attacker_name, defender_name)
    end
  end

  # Describe a multi-phase attack where the weapon changes mid-round
  def describe_multi_phase_attack(phases, actor_id, actor, attacker_name, defender_name)
    parts = []

    phases.each_with_index do |phase, idx|
      phase_weapon_type = phase[:weapon_type]
      is_ranged = %w[ranged natural_ranged].include?(phase_weapon_type)
      action = weapon_action_for(actor, is_ranged: is_ranged, event_weapon_type: phase_weapon_type)
      analysis = analyze_attack_sequence(phase[:events])
      attack_prose = describe_attack_pattern(analysis, attacker_name, defender_name, action[:noun], attack_noun_singular: action[:noun_singular])

      count_phrase = attack_count_phrase(analysis[:total_attacks], action)

      if idx == 0
        # First phase: use "still" movement since transition phrase describes the directional change
        weapon_name = weapon_name_for(actor, is_ranged: is_ranged)
        saved_movement = @movement_by_actor[actor_id]
        @movement_by_actor[actor_id] = { direction: nil, moved: false }
        movement_opening = build_movement_opening(actor_id, actor, defender_name, is_ranged, weapon_name, action)
        @movement_by_actor[actor_id] = saved_movement
        if count_phrase
          parts << "#{movement_opening}, #{count_phrase}. #{attack_prose}"
        else
          parts << "#{movement_opening}. #{attack_prose}"
        end
      else
        # Subsequent phases: transition phrase + attack count + pattern
        prev_type = phases[idx - 1][:weapon_type] == 'ranged' ? :ranged : :melee
        curr_type = is_ranged ? :ranged : :melee
        cap_attacker = capitalize_name(actor.character_name || name_for(actor))
        transition = weapon_transition_phrase(prev_type, curr_type, actor, is_ranged, actor_id: actor_id)
        if count_phrase
          parts << "#{cap_attacker} #{transition}, #{count_phrase}. #{attack_prose}"
        else
          parts << "#{cap_attacker} #{transition}. #{attack_prose}"
        end
      end
    end

    parts.join(' ')
  end

  # Build a movement-integrated opening phrase
  # e.g., "Alpha charges at Beta with his longsword" or "Alpha advances on Beta, firing his pistols"
  def build_movement_opening(actor_id, actor, target_name, is_ranged, weapon_name, action)
    movement = @movement_by_actor[actor_id] || {}
    direction = movement[:direction]
    moved = movement[:moved]
    # Use actual character name for sentence starts (not descriptors like "the person")
    cap_attacker = capitalize_name(actor.character_name || name_for(actor))

    # If opponent already moved towards us, we're already engaged — treat as stationary
    # This prevents "Spider closes with Lin" then "Lin closes with Spider"
    if moved && direction == 'towards'
      target_participant = find_attack_target_for(actor_id)
      if target_participant
        target_movement = @movement_by_actor[target_participant.id] || {}
        if target_movement[:moved] && target_movement[:direction] == 'towards'
          moved = false
          direction = nil
        end
      end
    end

    # Determine the key for verb lookup
    weapon_type = is_ranged ? :ranged : :melee
    if moved
      key = direction == 'away' ? "#{weapon_type}_away".to_sym : "#{weapon_type}_towards".to_sym
    else
      key = "#{weapon_type}_still".to_sym
    end

    verbs = MOVEMENT_ATTACK_VERBS[key] || MOVEMENT_ATTACK_VERBS[:melee_still]
    verb = verbs.sample

    # Strip article and possessive pronouns from weapon name for certain constructions
    weapon_short = weapon_name.gsub(/^(a|an|the|his|her|their)\s+/i, '')
    possessive = @name_service.possessive_for(actor)

    # Build the phrase based on weapon type and movement
    phrase = if is_ranged && moved
               # Moving + ranged: "advances on Beta, firing his pistols"
               "#{cap_attacker} #{verb} #{target_name}, #{action[:verb]} #{possessive} #{weapon_short}"
             elsif is_ranged
               # Stationary + ranged: "takes aim at Beta with his rifle"
               "#{cap_attacker} #{verb} #{target_name} with #{possessive} #{weapon_short}"
             elsif moved && direction == 'towards'
               if action[:is_natural]
                 "#{cap_attacker} #{verb} #{target_name}"
               else
                 "#{cap_attacker} #{verb} #{target_name}, #{weapon_short} raised"
               end
             elsif moved && direction == 'away'
               if action[:is_natural]
                 "#{cap_attacker} #{verb} #{target_name}, #{action[:verb]} defensively"
               else
                 "#{cap_attacker} #{verb} #{target_name}, #{action[:verb]} #{possessive} #{weapon_short} defensively"
               end
             else
               if action[:is_natural]
                 "#{cap_attacker} #{verb} #{target_name}"
               else
                 "#{cap_attacker} #{verb} #{target_name} with #{possessive} #{weapon_short}"
               end
             end

    # Append terrain flavor when the actor moved through interesting terrain
    terrain_clause = movement_terrain_clause_short(movement)
    phrase = "#{phrase} #{terrain_clause}" if terrain_clause && moved
    phrase
  end

  # Describe a two-way exchange
  def describe_two_way_exchange(actor_ids, hits_by_actor, misses_by_actor)
    actor1_id, actor2_id = actor_ids
    actor1 = participant(actor1_id)
    actor2 = participant(actor2_id)
    return nil unless actor1 && actor2

    name1 = name_for(actor1)
    name2 = name_for(actor2)

    # Tag events with event_type if not already set (for tests calling this directly)
    tagged_hits1 = (hits_by_actor[actor1_id] || []).map { |e| e[:event_type] ? e : e.merge(event_type: 'hit') }
    tagged_misses1 = (misses_by_actor[actor1_id] || []).map { |e| e[:event_type] ? e : e.merge(event_type: 'miss') }
    tagged_hits2 = (hits_by_actor[actor2_id] || []).map { |e| e[:event_type] ? e : e.merge(event_type: 'hit') }
    tagged_misses2 = (misses_by_actor[actor2_id] || []).map { |e| e[:event_type] ? e : e.merge(event_type: 'miss') }
    events1 = (tagged_hits1 + tagged_misses1).sort_by { |e| e[:segment] || 0 }
    events2 = (tagged_hits2 + tagged_misses2).sort_by { |e| e[:segment] || 0 }

    parts = []

    # Actor 1's attack (with weapon phase support)
    if events1.any?
      phases1 = split_by_weapon_phase(events1)
      if phases1.length > 1
        parts << describe_multi_phase_attack(phases1, actor1_id, actor1, name1, name2)
      else
        evt_weapon_type1 = events1.first&.dig(:details, :weapon_type)
        is_ranged1 = evt_weapon_type1 == 'ranged'
        action1 = weapon_action_for(actor1, is_ranged: is_ranged1, event_weapon_type: evt_weapon_type1)
        analysis1 = analyze_attack_sequence(events1)
        prose1 = describe_attack_pattern(analysis1, name1, name2, action1[:noun], attack_noun_singular: action1[:noun_singular])

        if @actors_with_opening&.include?(actor1_id)
          parts << prose1
        else
          @actors_with_opening&.add(actor1_id)
          weapon1 = weapon_name_for(actor1, is_ranged: is_ranged1)
          movement_opening1 = build_movement_opening(actor1_id, actor1, name2, is_ranged1, weapon1, action1)
          parts << "#{movement_opening1}. #{prose1}"
        end
      end
    end

    # Actor 2's attack — no movement opening needed, actor 1 already set the scene
    if events2.any?
      phases2 = split_by_weapon_phase(events2)
      if phases2.length > 1
        parts << describe_multi_phase_attack(phases2, actor2_id, actor2, name2, name1)
      else
        evt_weapon_type2 = events2.first&.dig(:details, :weapon_type)
        is_ranged2 = evt_weapon_type2 == 'ranged'
        action2 = weapon_action_for(actor2, is_ranged: is_ranged2, event_weapon_type: evt_weapon_type2)
        analysis2 = analyze_attack_sequence(events2)
        prose2 = describe_attack_pattern(analysis2, name2, name1, action2[:noun], attack_noun_singular: action2[:noun_singular])
        parts << prose2
      end
      @actors_with_opening&.add(actor2_id)
    end

    parts.join(' ')
  end

  # Describe a multi-way melee
  def describe_melee(actor_ids, hits_by_actor, misses_by_actor)
    parts = []
    parts << 'A chaotic melee ensues.'

    actor_ids.each do |actor_id|
      actor = participant(actor_id)
      next unless actor

      # Tag events with event_type if not already set (for tests calling this directly)
      tagged_hits = (hits_by_actor[actor_id] || []).map { |e| e[:event_type] ? e : e.merge(event_type: 'hit') }
      tagged_misses = (misses_by_actor[actor_id] || []).map { |e| e[:event_type] ? e : e.merge(event_type: 'miss') }
      all_events = (tagged_hits + tagged_misses).sort_by { |e| e[:segment] || 0 }
      next if all_events.empty?

      target_id = all_events.first&.dig(:target_id) ||
                  all_events.first&.dig(:details, :target_participant_id)
      target = target_id ? participant(target_id) : nil
      target_name = target ? name_for(target) : 'their opponent'
      attacker_name = name_for(actor)

      # Split by weapon phase
      phases = split_by_weapon_phase(all_events)
      if phases.length > 1
        parts << describe_multi_phase_attack(phases, actor_id, actor, attacker_name, target_name)
      else
        evt_weapon_type = all_events.first&.dig(:details, :weapon_type)
        is_ranged = %w[ranged natural_ranged].include?(evt_weapon_type)
        action = weapon_action_for(actor, is_ranged: is_ranged, event_weapon_type: evt_weapon_type)
        weapon_name = weapon_name_for(actor, is_ranged: is_ranged)

        movement_opening = build_movement_opening(actor_id, actor, target_name, is_ranged, weapon_name, action)
        analysis = analyze_attack_sequence(all_events)
        prose = describe_attack_pattern(analysis, attacker_name, target_name, action[:noun], attack_noun_singular: action[:noun_singular])
        parts << "#{movement_opening}. #{prose}"
      end
    end

    parts.join(' ')
  end

  # Describe ability start/casting - pure narrative, no numbers
  def describe_ability_start(event)
    actor = participant(event[:actor_id])
    return nil unless actor

    details = event[:details] || {}
    ability_name = details[:ability_name] || 'an ability'

    name = name_for(actor)
    "#{capitalize_name(name)} unleashes #{ability_name}!"
  end

  # Describe an ability effect - pure narrative, damage numbers go in summary
  def describe_ability(event)
    details = event[:details] || {}
    ability_name = details[:ability_name] || 'an ability'
    target_name = details[:target_name] || event[:target_name]
    is_chain = details[:is_chain]
    chain_index = details[:chain_index]

    if event[:event_type] == 'ability_heal'
      return "#{ability_name} washes over #{target_name} with restorative energy."
    end

    # Chain hits get special description
    if is_chain && chain_index && chain_index > 0
      "The energy arcs to #{target_name}!"
    else
      "#{ability_name} slams into #{target_name}!"
    end
  end

  # Describe a status effect being applied - pure narrative, no duration numbers
  def describe_status_applied(event)
    details = event[:details] || {}
    effect_name = details[:effect_name] || 'a condition'
    target_name = details[:target_name] || event[:target_name]

    case effect_name.to_s.downcase
    when 'burning'
      "#{target_name} catches fire!"
    when 'poisoned'
      "#{target_name} is poisoned!"
    when 'stunned'
      "#{target_name} is stunned!"
    when 'blinded'
      "#{target_name} is blinded!"
    when 'slowed'
      "#{target_name} is slowed!"
    when 'prone'
      "#{target_name} is knocked prone!"
    when 'bleeding'
      "#{target_name} starts bleeding!"
    when 'frozen'
      "#{target_name} is frozen solid!"
    when 'weakened'
      "#{target_name} is weakened!"
    when 'empowered'
      "#{target_name} feels empowered!"
    when 'shielded'
      "A magical shield surrounds #{target_name}."
    when 'regenerating'
      "#{target_name} begins to regenerate."
    else
      effect_display = effect_name.to_s.tr('_', ' ').capitalize
      "#{target_name} is affected by #{effect_display}."
    end
  end

  # Generate knockout announcements
  # In spar mode, these become "wins the sparring match" messages
  def generate_knockouts(events)
    return nil if events.empty?

    if @fight.spar_mode?
      # In spar mode, the loser reached max touches
      # Use actual_name_for (not name_for) to avoid random alternation in knockout messages
      events.map do |event|
        target = event[:target_name]
        winner = @fight.fight_participants.reject { |p| actual_name_for(p) == target }.first
        winner_name = winner ? actual_name_for(winner) : 'Their opponent'
        "#{winner_name} wins the sparring match against #{target}!"
      end.join(' ')
    else
      events.map do |event|
        target = event[:target_name]
        # NPCs in monster fights die; PCs get knocked out
        target_participant = event[:target_participant] || @fight.fight_participants.find { |p| actual_name_for(p) == target }
        if target_participant&.is_npc
          "#{target} collapses, slain!"
        else
          "#{target} collapses, knocked out!"
        end
      end.join(' ')
    end
  end

  # Generate damage summary with ALL crunchy numbers
  # Format: [Alpha: 15 dmg (-2 HP), burning 3 rds; Beta: healed 8 HP]
  def generate_damage_summary(damage_events)
    # Collect all numeric data from round events
    participant_data = Hash.new { |h, k| h[k] = { damage: 0, hp_lost: 0, healed: 0, statuses: [] } }

    @round_events.each do |event|
      details = event[:details] || {}
      target_name = details[:target_name] || event[:target_name]
      next unless target_name

      case event[:event_type]
      when 'ability_hit'
        damage = details[:effective_damage] || 0
        participant_data[target_name][:damage] += damage
      when 'ability_heal'
        healed = details[:actual_heal] || 0
        participant_data[target_name][:healed] += healed
      when 'status_applied'
        effect = details[:effect_name]
        duration = details[:duration_rounds]
        if effect
          participant_data[target_name][:statuses] << { effect: effect, duration: duration }
        end
      end
    end

    # Add damage_applied totals (weapon attacks)
    damage_events.each do |event|
      target = event[:target_name]
      details = event[:details] || {}
      damage = details[:total_damage] || 0
      hp_lost = details[:hp_lost] || 0

      next unless target

      participant_data[target][:damage] += damage
      participant_data[target][:hp_lost] = hp_lost  # Use the final HP lost value
    end

    # Build summary strings
    summaries = participant_data.map do |name, data|
      parts = []

      if data[:damage] > 0
        if @fight.spar_mode?
          # In spar mode, show touches instead of HP loss
          touches = data[:hp_lost]
          parts << "+#{touches} touch#{'es' if touches != 1}" if touches > 0
        else
          parts << "#{data[:damage]} dmg (-#{data[:hp_lost]} HP)"
        end
      end

      if data[:healed] > 0 && !@fight.spar_mode?
        # No healing display in spar mode
        parts << "healed #{data[:healed]} HP"
      end

      data[:statuses].each do |status|
        effect_name = status[:effect].to_s.tr('_', ' ')
        duration = status[:duration]
        if duration && duration > 1
          parts << "#{effect_name} #{duration} rds"
        else
          parts << effect_name
        end
      end

      next nil if parts.empty?

      # In spar mode, add total touch count
      if @fight.spar_mode?
        participant = @fight.fight_participants.find { |p| name_for(p) == name }
        total_touches = participant&.touch_count || 0
        max_touches = participant&.max_hp || 6
        "#{name}: #{total_touches}/#{max_touches} touches#{parts.empty? ? '' : " (#{parts.join(', ')})"}"
      else
        "#{name}: #{parts.join(', ')}"
      end
    end.compact

    return nil if summaries.empty?

    "[#{summaries.join('; ')}]"
  end

  # Helper methods

  def name_for(participant_or_id)
    p = participant_or_id.is_a?(FightParticipant) ? participant_or_id : participant(participant_or_id)
    return 'Unknown' unless p

    @name_service.name_for(p)
  end

  # Get wound or touch description based on fight mode
  # In spar mode, uses touch noun phrases instead of wound descriptions
  def describe_hit_result(hp_lost:, damage_type: nil)
    if @fight.spar_mode?
      phrases = TOUCH_NOUN_PHRASES[[hp_lost, 4].min] || TOUCH_NOUN_PHRASES[1]
      phrases.sample
    else
      @wound_service.describe_wound(hp_lost: hp_lost, damage_type: damage_type)
    end
  end

  # Get actual character name without alternation (for knockout/win messages)
  def actual_name_for(participant_or_id)
    p = participant_or_id.is_a?(FightParticipant) ? participant_or_id : participant(participant_or_id)
    return 'Unknown' unless p

    name = p.character_name
    name = p.character_instance&.character&.full_name if name.nil? || name.empty?
    name || 'Unknown'
  end

  def weapon_name_for(participant_or_id, is_ranged: false)
    p = participant_or_id.is_a?(FightParticipant) ? participant_or_id : participant(participant_or_id)
    return 'bare hands' unless p

    # Natural attack NPCs don't have weapons — use attack name
    if p.using_natural_attacks?
      attack = is_ranged ? p.npc_archetype&.primary_ranged_attack : p.npc_archetype&.primary_melee_attack
      attack ||= p.npc_archetype&.parsed_npc_attacks&.first
      return attack ? attack.name.downcase : 'natural weapons'
    end

    # Use appropriate weapon based on attack type
    weapon_type = is_ranged ? :ranged : :melee
    @name_service.weapon_name_for(p, weapon_type: weapon_type)
  end

  # Get weapon action description (verb, noun, singular)
  # @param event_weapon_type [String, nil] weapon type from event details (e.g. 'unarmed', 'natural_melee', 'ranged', 'melee')
  def weapon_action_for(participant_or_id, is_ranged: false, event_weapon_type: nil)
    # If the event explicitly says unarmed or natural_melee, return unarmed actions directly
    # This prevents fallback to equipped ranged weapon when the attack was actually unarmed
    return WEAPON_ACTIONS[:unarmed] if event_weapon_type == 'unarmed'

    p = participant_or_id.is_a?(FightParticipant) ? participant_or_id : participant(participant_or_id)
    return WEAPON_ACTIONS[:unarmed] unless p

    # Check for natural attacks first (NPC monsters with archetype)
    if %w[natural_melee natural_ranged].include?(event_weapon_type) || p.using_natural_attacks?
      attack = is_ranged ? p.npc_archetype&.primary_ranged_attack : p.npc_archetype&.primary_melee_attack
      attack ||= p.npc_archetype&.parsed_npc_attacks&.first
      return natural_attack_action(attack) if attack
      return WEAPON_ACTIONS[:unarmed] if event_weapon_type == 'natural_melee'
    end

    # Select weapon based on attack type
    weapon = is_ranged ? (p.ranged_weapon || p.melee_weapon) : (p.melee_weapon || p.ranged_weapon)
    return WEAPON_ACTIONS[:unarmed] unless weapon&.pattern

    weapon_type = infer_weapon_type(weapon.pattern)
    WEAPON_ACTIONS[weapon_type] || DEFAULT_WEAPON_ACTION
  end

  # Infer weapon type from pattern for action lookup
  def infer_weapon_type(pattern)
    # Use description first as it contains the actual weapon name
    # name is delegated to unified_object_type which may be generic like "Test Weapon"
    name = (pattern.description || pattern.name || '').gsub(/<[^>]+>/, '').downcase

    case name
    when /fist|unarmed|bare/ then :fists
    when /sword|blade|saber|katana|rapier/ then :sword
    when /knife|dagger|shiv/ then :knife
    when /axe|hatchet/ then :axe
    when /hammer|mace|maul/ then :hammer
    when /club|bat|baton/ then :club
    when /staff|pole|quarterstaff/ then :staff
    when /spear|lance|pike|javelin/ then :spear
    when /pistol|revolver|handgun/ then :pistol
    when /rifle|carbine|musket/ then :rifle
    when /gun|firearm/ then :gun
    when /bow|crossbow/ then :bow
    else :unarmed
    end
  end

  # Convert an NpcAttack into a WEAPON_ACTIONS-compatible hash
  # Derives verb forms dynamically from the attack name
  def natural_attack_action(attack)
    name = attack.name&.downcase || 'attack'
    verb_ing = case name
               when /bite/ then 'biting'
               when /claw/ then 'clawing'
               when /slam/ then 'slamming'
               when /sting/ then 'stinging'
               when /spit/ then 'spitting'
               when /breath|fire|hell/ then 'breathing'
               else "#{name.chomp('e')}ing"
               end
    verb_3p = case name
              when /bite/ then 'bites'
              when /claw/ then 'claws'
              when /slam/ then 'slams'
              when /sting/ then 'stings'
              when /spit/ then 'spits'
              when /breath|fire|hell/ then 'breathes fire at'
              else "#{name}s"
              end
    noun_plural = case name
                  when /bite/ then 'bites'
                  when /claw/ then 'claws'
                  when /slam/ then 'slams'
                  when /sting/ then 'stings'
                  when /spit/ then 'spits'
                  else "#{name}s"
                  end

    {
      verb: verb_ing,
      verb_3p: verb_3p,
      noun: noun_plural,
      noun_singular: name,
      singular: "a #{name}",
      is_natural: true
    }
  end

  # Check if two participants are using matching weapons
  def weapons_match?(actor1, actor2)
    type1 = weapon_action_for(actor1)
    type2 = weapon_action_for(actor2)
    type1 == type2
  end

  # Build the "verbing N nouns" phrase for attack counts
  # Returns nil for single attacks (prose already covers it), string for 2+
  def attack_count_phrase(count, action)
    return nil if count <= 1

    if action[:is_natural]
      # Natural attacks: "biting four times" instead of "biting four bites"
      "#{action[:verb]} #{number_word(count)} times"
    else
      "#{action[:verb]} #{number_word(count)} #{action[:noun]}"
    end
  end

  # Convert number to word for prose
  def number_word(n)
    NUMBER_WORDS[n] || n.to_s
  end

  # Convert plural attack noun to singular
  # Handles compound nouns like "punches and kicks" → "punch"
  def singular_noun(noun_plural)
    # For compound nouns ("punches and kicks"), take just the first word
    first_word = noun_plural.split(/\s+(?:and|&)\s+/).first || noun_plural
    # Handle common English pluralization rules:
    # "bites" → "bite" (not "bit"), "slashes" → "slash", "punches" → "punch"
    if first_word.end_with?('shes', 'ches', 'xes', 'sses', 'zes')
      first_word.sub(/es$/, '')
    elsif first_word.end_with?('ies')
      first_word.sub(/ies$/, 'y')
    elsif first_word.end_with?('ves')
      first_word.sub(/ves$/, 'fe')
    elsif first_word.end_with?('es')
      # "bites" → "bite", "slashes" handled above
      first_word.sub(/s$/, '')
    elsif first_word.end_with?('s')
      first_word.sub(/s$/, '')
    else
      first_word
    end
  end

  # Capitalize a name for sentence start (handles "the" descriptors)
  def capitalize_name(name)
    return name if name.nil? || name.empty?

    name.sub(/\A\w/, &:upcase)
  end

  # Get an attack verb for a participant using their weapon
  def attack_verb_for(participant)
    action = weapon_action_for(participant)
    # Convert "throwing" to "throws", "swinging" to "swings", etc.
    verb = action[:verb]
    # Simple present tense conversion
    if verb.end_with?('ing')
      verb.sub(/ing$/, 's')
    else
      verb + 's'
    end
  end

  def damage_type(actor, hit_event)
    # Try to get from event details first
    damage_type = hit_event&.dig(:details, :damage_type)
    return damage_type if damage_type

    # Check if this was a ranged attack based on event
    is_ranged = %w[ranged natural_ranged].include?(hit_event&.dig(:details, :weapon_type))

    # Fall back to appropriate weapon based on attack type
    weapon = is_ranged ? (actor.ranged_weapon || actor.melee_weapon) : (actor.melee_weapon || actor.ranged_weapon)
    return 'bludgeoning' unless weapon&.pattern

    # Pattern may not have damage_type column - use respond_to? for safety
    pattern = weapon.pattern
    (pattern.respond_to?(:damage_type) && pattern.damage_type) || infer_damage_type(pattern)
  end

  def infer_damage_type(pattern)
    name = (pattern.description || pattern.name || '').gsub(/<[^>]+>/, '').downcase

    case name
    when /sword|blade|knife|dagger|axe|claw/ then 'slashing'
    when /spear|arrow|lance|rapier|pike|pistol|rifle|gun|bow|crossbow/ then 'piercing'
    when /hammer|mace|club|staff|fist/ then 'bludgeoning'
    when /fire|flame|burn/ then 'fire'
    when /ice|frost|cold/ then 'cold'
    when /lightning|shock/ then 'lightning'
    else 'bludgeoning'
    end
  end

  # Analyze a sequence of hit/miss events for one attacker->defender pair
  def analyze_attack_sequence(events)
    hit_indices = []
    miss_indices = []
    threshold_indices = []
    total_hp_lost = 0
    weapon_type = nil
    damage_type = nil

    events.each_with_index do |event, idx|
      details = event[:details] || {}
      weapon_type ||= details[:weapon_type]
      damage_type ||= details[:damage_type]

      if event[:event_type] == 'hit'
        hit_indices << idx
        hp_lost = details[:hp_lost_this_attack] || 0
        threshold_crossed = details[:threshold_crossed]

        if threshold_crossed.nil?
          # Backwards compat: no threshold data, treat all hits as threshold crossings
          threshold_indices << idx
          total_hp_lost += 1
        elsif threshold_crossed
          threshold_indices << idx
          total_hp_lost += hp_lost
        end
      else
        miss_indices << idx
      end
    end

    {
      total_attacks: events.length,
      hit_indices: hit_indices,
      miss_indices: miss_indices,
      threshold_indices: threshold_indices,
      total_hp_lost: total_hp_lost,
      weapon_type: weapon_type || 'melee',
      damage_type: damage_type || 'bludgeoning'
    }
  end

  # Generate natural prose describing an attack pattern
  def describe_attack_pattern(analysis, attacker_name, defender_name, attack_noun_plural, attack_noun_singular: nil)
    total = analysis[:total_attacks]
    hits = analysis[:hit_indices]
    misses = analysis[:miss_indices]
    hp_lost = analysis[:total_hp_lost]
    is_ranged = %w[ranged natural_ranged].include?(analysis[:weapon_type])
    damage_type = analysis[:damage_type]
    spar = @fight.spar_mode?
    noun_singular = attack_noun_singular || singular_noun(attack_noun_plural)

    impact = hp_lost > 0 ? impact_phrase(hp_lost, damage_type, spar) : nil

    if misses.empty? && hits.any?
      describe_all_hits(total, attacker_name, defender_name, attack_noun_plural, impact)
    elsif hits.empty? && misses.any?
      describe_all_misses(total, attacker_name, defender_name, attack_noun_plural, is_ranged, spar)
    else
      describe_mixed_attacks(analysis, attacker_name, defender_name, attack_noun_plural, noun_singular, is_ranged, impact, spar)
    end
  end

  def impact_phrase(hp_lost, damage_type, spar)
    if spar
      pool = SPAR_IMPACT_DESCRIPTIONS[[hp_lost, 4].min] || SPAR_IMPACT_DESCRIPTIONS[1]
      return pool.sample
    end

    type_sym = (damage_type || 'generic').to_s.downcase.to_sym
    type_pool = IMPACT_DESCRIPTIONS[type_sym] || IMPACT_DESCRIPTIONS[:generic]
    clamped = [hp_lost, 4].min
    pool = type_pool[clamped] || type_pool[1]
    pool.sample
  end

  def describe_all_hits(total, attacker_name, defender_name, noun_plural, impact)
    cap_attacker = capitalize_name(attacker_name)
    if total == 1
      "#{cap_attacker} catches #{defender_name} with #{impact || 'a solid hit'}."
    elsif total == 2
      "#{cap_attacker} lands both #{noun_plural} on #{defender_name}, inflicting #{impact || 'solid damage'}."
    else
      "#{cap_attacker} lands all #{number_word(total)} #{noun_plural} on #{defender_name}, inflicting #{impact || 'solid damage'}."
    end
  end

  def describe_all_misses(total, attacker_name, defender_name, noun_plural, is_ranged, spar)
    cap_defender = capitalize_name(defender_name)
    n_word = number_word(total)
    quantifier = total == 2 ? 'both' : "all #{n_word}"

    if is_ranged
      verb = RANGED_MISS_VERBS.sample
      if total == 1
        "#{capitalize_name(attacker_name)}'s shot #{verb.sub('go ', 'goes ').sub(/^miss$/, 'misses')}."
      else
        "#{quantifier.capitalize} of #{attacker_name}'s #{noun_plural} #{verb}."
      end
    else
      pool = spar ? SPAR_MISS_FLAVORS : MISS_FLAVORS[:melee]
      verb = pool.sample
      if total == 1
        "#{cap_defender} #{verb} #{attacker_name}'s #{singular_noun(noun_plural)}."
      else
        "#{cap_defender} #{verb} #{quantifier} of #{attacker_name}'s #{noun_plural}."
      end
    end
  end

  def describe_mixed_attacks(analysis, attacker_name, defender_name, noun_plural, noun_singular, is_ranged, impact, spar)
    hits = analysis[:hit_indices]
    misses = analysis[:miss_indices]
    cap_defender = capitalize_name(defender_name)
    cap_attacker = capitalize_name(attacker_name)

    hit_ordinals = hits.map { |i| ordinal_word(i + 1) }
    miss_count = misses.length

    miss_verb = if is_ranged
                  RANGED_MISS_VERBS.sample
                else
                  pool = spar ? SPAR_MISS_FLAVORS : MISS_FLAVORS[:melee]
                  pool.sample
                end

    if hits.length == 1
      single_hit_pattern(cap_defender, cap_attacker, attacker_name, defender_name,
                         hit_ordinals.first, noun_plural, noun_singular, miss_verb, is_ranged, miss_count, impact, spar)
    else
      multi_hit_pattern(cap_defender, cap_attacker, attacker_name, defender_name,
                        hit_ordinals, noun_plural, noun_singular, miss_verb, is_ranged, miss_count, impact, spar)
    end
  end

  def single_hit_pattern(cap_defender, cap_attacker, attacker_name, defender_name,
                         hit_ord, noun_plural, noun_singular, miss_verb, is_ranged, miss_count, impact, spar)
    others = miss_count == 1 ? 'the other' : 'the others'

    templates = if is_ranged
      [
        "#{cap_attacker}'s #{hit_ord} #{noun_singular} finds its mark, inflicting #{impact || 'a hit'}, while #{others} #{miss_verb}.",
        "#{cap_attacker} lands the #{hit_ord} #{noun_singular} on #{defender_name}, inflicting #{impact || 'a hit'}, as #{others} #{miss_verb}."
      ]
    else
      [
        "#{cap_defender} #{miss_verb} #{attacker_name}'s #{noun_plural} but the #{hit_ord} breaks through, inflicting #{impact || 'a hit'}.",
        "#{cap_attacker}'s #{hit_ord} #{noun_singular} connects, inflicting #{impact || 'a hit'}, as #{defender_name} #{miss_verb} #{others}.",
        "#{cap_defender} #{miss_verb} #{others}, but #{attacker_name}'s #{hit_ord} #{noun_singular} lands #{impact || 'a hit'}."
      ]
    end

    templates.sample
  end

  def multi_hit_pattern(cap_defender, cap_attacker, attacker_name, defender_name,
                        hit_ordinals, noun_plural, noun_singular, miss_verb, is_ranged, miss_count, impact, spar)
    others = miss_count == 1 ? 'the other' : 'the others'
    ordinal_list = join_ordinals(hit_ordinals)

    templates = if is_ranged
      [
        "#{cap_attacker}'s #{ordinal_list} #{noun_plural} find their mark, inflicting #{impact || 'solid damage'}, while #{others} #{miss_verb}.",
        "#{cap_attacker} lands the #{ordinal_list} #{noun_plural} on #{defender_name}, inflicting #{impact || 'solid damage'}, as #{others} #{miss_verb}."
      ]
    else
      [
        "#{cap_attacker} lands the #{ordinal_list} #{noun_plural} on #{defender_name}, inflicting #{impact || 'solid damage'}, as #{defender_name} #{miss_verb} #{others}.",
        "#{cap_defender} #{miss_verb} #{others}, but #{attacker_name}'s #{ordinal_list} #{noun_plural} land #{impact || 'solid damage'}.",
        "#{cap_attacker}'s #{ordinal_list} #{noun_plural} break through, inflicting #{impact || 'solid damage'}, as #{defender_name} #{miss_verb} #{others}."
      ]
    end

    templates.sample
  end

  def ordinal_word(n)
    ORDINAL_WORDS[n] || "#{n}th"
  end

  def join_ordinals(ordinals)
    case ordinals.length
    when 1 then ordinals.first
    when 2 then "#{ordinals[0]} and #{ordinals[1]}"
    else
      "#{ordinals[0..-2].join(', ')}, and #{ordinals[-1]}"
    end
  end

  # --- Movement terrain helpers ---

  # Compare first event's old_elevation_level to last event's elevation_level
  # @return [Symbol, nil] :climbed_up, :descended, :level, or nil
  def compute_elevation_change(events)
    return nil if events.empty?
    first_details = events.first[:details] || {}
    last_details = events.last[:details] || {}
    old_elev = first_details[:old_elevation_level]
    new_elev = last_details[:elevation_level]
    return nil if old_elev.nil? || new_elev.nil?

    diff = new_elev.to_i - old_elev.to_i
    if diff > 0
      :climbed_up
    elsif diff < 0
      :descended
    else
      :level
    end
  end

  # Absolute elevation difference between start and end
  def compute_elevation_delta(events)
    return 0 if events.empty?
    first_details = events.first[:details] || {}
    last_details = events.last[:details] || {}
    old_elev = (first_details[:old_elevation_level] || 0).to_i
    new_elev = (last_details[:elevation_level] || 0).to_i
    (new_elev - old_elev).abs
  end

  # Detect stairs/ladder/ramp in any movement step
  def detect_climb_method(events)
    events.each do |e|
      d = e[:details] || {}
      return :stairs if d[:is_stairs]
      return :ladder if d[:is_ladder]
      return :ramp if d[:is_ramp]
    end
    nil
  end

  # Any step with difficult_terrain: true?
  def any_difficult_terrain?(events)
    events.any? { |e| (e[:details] || {})[:difficult_terrain] }
  end

  # Highest water type encountered (swimming > wading > nil)
  WATER_PRIORITY = { 'swimming' => 3, 'deep' => 3, 'wading' => 2, 'puddle' => 1 }.freeze

  def detect_water_type(events)
    best = nil
    best_priority = 0
    events.each do |e|
      wt = (e[:details] || {})[:water_type]
      next unless wt
      p = WATER_PRIORITY[wt.to_s] || 1
      if p > best_priority
        best = wt.to_s
        best_priority = p
      end
    end
    # Normalize deep → swimming for narrative
    best == 'deep' ? 'swimming' : best
  end

  # If last step has cover and first step's origin didn't, return cover_object
  def detect_cover_entry(events)
    return nil if events.empty?
    last_details = events.last[:details] || {}
    last_has_cover = last_details[:has_cover]
    return nil unless last_has_cover

    first_has_cover = events.length > 1 ? (events.first[:details] || {})[:has_cover] : false
    return nil if first_has_cover

    last_details[:cover_object]
  end

  # Inverse: first step origin had cover, last step doesn't
  def detect_cover_exit(events)
    return nil if events.empty?
    last_details = events.last[:details] || {}
    return nil if last_details[:has_cover]

    events[0...-1].each do |e|
      d = e[:details] || {}
      return d[:cover_object] if d[:has_cover]
    end
    nil
  end

  # First step with a non-nil cover_object that isn't start/end cover
  def detect_notable_object(events)
    start_cover = events.first&.dig(:details, :cover_object)
    end_cover = events.last&.dig(:details, :cover_object)

    events.each do |e|
      obj = (e[:details] || {})[:cover_object]
      next if obj.nil?
      next if obj == start_cover || obj == end_cover
      return obj
    end
    nil
  end

  # Build array of short terrain clauses for describe_movement_only
  def movement_terrain_clauses(movement)
    clauses = []

    case movement[:elevation_change]
    when :climbed_up
      via = case movement[:climbed_via]
            when :stairs then 'up the stairs'
            when :ladder then 'up a ladder'
            when :ramp then 'up the ramp'
            else 'climbing higher'
            end
      clauses << via
    when :descended
      via = case movement[:climbed_via]
            when :stairs then 'down the stairs'
            when :ladder then 'down a ladder'
            when :ramp then 'down the ramp'
            else 'dropping to lower ground'
            end
      clauses << via
    end

    if movement[:traversed_water]
      water_clause = case movement[:traversed_water]
                     when 'swimming' then 'swimming through deep water'
                     when 'wading' then 'wading through water'
                     else nil
                     end
      clauses << water_clause if water_clause
    end

    clauses << 'picking through difficult terrain' if movement[:traversed_difficult] && clauses.empty?

    clauses.compact
  end

  # Single most impactful terrain detail for movement_attack_opening
  def movement_terrain_clause_short(movement)
    return nil unless movement[:moved]

    case movement[:elevation_change]
    when :climbed_up then return 'climbing higher'
    when :descended then return 'dropping down'
    end

    return 'splashing through water' if movement[:traversed_water]

    if movement[:entered_cover]
      obj = humanize_cover_object(movement[:entered_cover])
      return "ducking behind #{obj}" if obj
    end

    return 'picking through debris' if movement[:traversed_difficult]

    nil
  end

  # Build a cover transition sentence
  def movement_cover_clause(movement, actor_name)
    if movement[:entered_cover]
      obj = humanize_cover_object(movement[:entered_cover])
      obj ? "#{actor_name} takes cover behind #{obj}." : "#{actor_name} ducks into cover."
    elsif movement[:left_cover]
      obj = humanize_cover_object(movement[:left_cover])
      obj ? "#{actor_name} breaks from the shelter of #{obj}." : "#{actor_name} leaves cover."
    end
  end

  # Convert a raw cover_object name (e.g. "barrel", "wall_low") into a human-readable
  # phrase with an article (e.g. "a barrel", "a low wall").
  # @param raw [String, nil]
  # @return [String, nil]
  def humanize_cover_object(raw)
    return nil if raw.nil? || raw.to_s.strip.empty?

    name = raw.to_s.gsub('_', ' ').strip
    return nil if name.empty?

    article = %w[a e i o u].include?(name[0]&.downcase) ? 'an' : 'a'
    "#{article} #{name}"
  end
end
