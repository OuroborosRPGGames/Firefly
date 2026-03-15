# frozen_string_literal: true

# Seed script for random seed terms
# Populates seed_term_entries table for world generation
#
# Run: bundle exec ruby scripts/setup/seed_terms.rb
#
# TABLE STRUCTURE:
# - ADJECTIVE TABLES: For inspiration during generation (weathered, ornate, etc.)
# - NOUN TABLES: For selecting WHAT to generate (only used for random selection)
# - CHARACTER TABLES: Personality, motivation, identity (for NPC generation)
# - MOOD TABLES: Tone and atmosphere

require_relative '../../app'

# ==============================================================================
# SEED TERM DATA
# ==============================================================================

SEED_TABLES = {
  # ===========================================================================
  # ADJECTIVE TABLES - Used for INSPIRATION during generation
  # These provide descriptive qualities, not things to generate
  # ===========================================================================

  # Physical appearance/condition adjectives (items, characters, places)
  physical_adjectives: %w[
    weathered scarred pristine battered polished rusted faded vibrant
    tarnished gleaming dull lustrous mottled worn smooth rough
    cracked chipped dented bent twisted warped straight sleek
    ornate plain decorated embellished etched engraved carved inlaid
    patched repaired mended broken intact whole fractured splintered
    aged new ancient antique vintage timeworn fresh yellowed
    stained spotless grimy dusty clean filthy soiled immaculate
    faded bleached sun-bleached darkened discolored bright vivid
    delicate sturdy fragile robust flimsy solid reinforced fortified
    handcrafted mass-produced artisan crude refined elegant simple
    symmetrical asymmetrical balanced lopsided even uneven regular
    genuine fake authentic replica original copied forged counterfeit
    scratched scuffed burnished buffed hammered wrought cast molded
    peeling flaking crumbling intact preserved deteriorating restored
    embossed debossed raised recessed textured patterned plain smooth
  ],

  # Materials and textures
  materials: %w[
    brass bronze copper gold silver iron steel tin pewter platinum
    oak mahogany pine cedar birch walnut cherry elm ash maple teak
    leather suede velvet silk satin linen cotton wool felt canvas
    marble granite slate limestone sandstone cobblestone brick mortar
    crystal glass ceramic porcelain clay terracotta bone ivory horn
    shell pearl coral amber jade onyx obsidian quartz ruby sapphire
    wicker rattan bamboo reed straw thatch rope twine cord hemp
    parchment vellum paper canvas burlap lace muslin cheesecloth
    enamel lacquer varnish gilt plated inlaid mosaic filigree
    fur hide scale feather down fleece mohair cashmere angora
    rubber wax resin tar pitch oil grease tallow beeswax
  ],

  # Size and scale
  size_adjectives: %w[
    massive tiny enormous minuscule huge small large petite
    towering diminutive gigantic microscopic vast compact
    sprawling cramped spacious confined expansive narrow wide
    thick thin slender bulky chunky delicate substantial slight
    oversized undersized life-sized miniature monumental modest
    cavernous intimate cozy roomy tight generous meager
    tall short long deep shallow high low broad
    voluminous sparse dense packed empty full hollow solid
    gargantuan colossal titanic immense tremendous minute wee
    stocky lanky squat elongated extended compressed stretched
  ],

  # Age and time
  age_adjectives: %w[
    ancient modern antique contemporary vintage classic timeless
    old new young aged fresh recent primordial prehistoric
    medieval renaissance baroque victorian colonial frontier
    weathered pristine preserved decayed crumbling enduring
    ancestral hereditary generational traditional newfangled
    eternal temporary fleeting permanent lasting ephemeral
    forgotten remembered legendary mythical historical recent
    bygone future present past timeworn ageless venerable
    decrepit youthful mature infantile senile sprightly
    archaic obsolete current outdated cutting-edge traditional
  ],

  # Quality and craftsmanship
  quality_adjectives: %w[
    fine crude exquisite humble grand shabby luxurious modest
    superior inferior premium common rare ordinary exceptional
    masterwork amateur professional novice expert apprentice
    flawless imperfect pristine damaged mint ruined serviceable
    expensive cheap priceless worthless valuable precious affordable
    authentic genuine fake counterfeit real imitation knockoff
    handmade machine-made bespoke custom standard generic mass-produced
    artisan industrial homemade factory-made commissioned one-of-a-kind
    ornamental functional decorative practical ceremonial everyday utility
    heirloom disposable treasured discarded prized forgotten cherished
    lavish austere opulent spartan extravagant frugal sumptuous plain
    intricate simple elaborate basic complex straightforward ornate
  ],

  # Spatial and architectural
  spatial_adjectives: %w[
    cramped spacious narrow wide open enclosed exposed sheltered
    vaulted domed arched flat sloped curved angular straight
    symmetrical asymmetrical regular irregular ordered chaotic
    central peripheral corner alcove recessed protruding jutting
    upper lower ground underground elevated sunken raised
    interior exterior indoor outdoor covered uncovered roofed
    connected isolated adjoining separate linked detached attached
    cluttered sparse organized messy tidy disheveled arranged neat
    layered tiered stacked nested compartmented unified divided
    public private hidden exposed secret revealed concealed
    accessible restricted blocked clear obstructed passable navigable
    partitioned open-plan sectioned unified segmented continuous
  ],

  # Atmosphere and mood (for places)
  atmosphere_adjectives: %w[
    welcoming forbidding inviting hostile warm cold cozy sterile
    cheerful gloomy bright dark sunny shadowy well-lit dim
    peaceful chaotic tranquil turbulent calm tense relaxed anxious
    lively dead bustling quiet active dormant vibrant dull
    comfortable uncomfortable pleasant unpleasant agreeable harsh
    safe dangerous secure threatening protected exposed vulnerable
    intimate impersonal familiar strange homely austere friendly
    sacred profane holy unholy blessed cursed sanctified desecrated
    clean filthy spotless grimy fresh stale musty fragrant aromatic
    orderly disorderly neat messy organized cluttered systematic
    magical mundane enchanted ordinary supernatural natural mystical
    romantic dreary charming bleak inspiring depressing uplifting
    oppressive liberating confining freeing claustrophobic airy
    reverent irreverent solemn festive somber celebratory mournful
  ],

  # Lighting conditions
  lighting_adjectives: %w[
    bright dim dark shadowy sunlit moonlit candlelit torchlit
    flickering steady glowing pulsing shimmering dancing wavering
    harsh soft diffuse focused scattered concentrated dappled
    warm cool golden silvery amber crimson pale vivid white
    dappled filtered streaked striped mottled uniform patchy
    blinding faint brilliant muted radiant subdued glaring
    natural artificial magical ethereal ghostly spectral eerie
    firelit starlit lamplight twilight predawn nocturnal midday
    overcast cloudy clear hazy foggy misty smoky dusty
  ],

  # Temperature and climate
  temperature_adjectives: %w[
    warm cold cool hot chilly frigid sweltering temperate
    freezing boiling mild harsh comfortable uncomfortable
    humid dry damp moist arid parched steamy stuffy
    breezy still windy gusty drafty sheltered exposed
    sunny cloudy overcast foggy misty hazy clear
    rainy snowy stormy calm mild severe inclement
    tropical arctic temperate continental coastal maritime
    balmy crisp brisk bitter scorching pleasant moderate
  ],

  # Sound qualities
  sound_adjectives: %w[
    quiet loud silent noisy hushed thunderous deafening muted
    echoing muffled reverberating resonant hollow ringing tinny
    bustling peaceful still active alive dead dormant lively
    creaking groaning whistling humming buzzing droning whirring
    melodic discordant harmonious cacophonous rhythmic erratic steady
    distant near faint clear sharp dull piercing soft gentle
    booming rumbling crackling sizzling bubbling gurgling splashing
    chattering murmuring whispering shouting laughing crying wailing
  ],

  # Smell and taste
  scent_adjectives: %w[
    fragrant musty fresh stale smoky floral acrid sweet
    pungent mild sharp subtle overwhelming faint pleasant
    earthy woody herbal spicy savory bitter sour salty
    clean foul rotten decayed fermented aged ripe
    perfumed natural chemical medicinal food cooking baking
    damp moldy dusty airy stuffy ventilated fetid rank
    aromatic redolent odorless scented perfumed cloying
  ],

  # Condition and state
  condition_adjectives: %w[
    pristine worn damaged repaired maintained neglected ruined
    functional broken working failing operational defunct serviceable
    stable unstable secure precarious solid shaky sturdy rickety
    complete incomplete partial whole fragmented assembled disassembled
    active inactive dormant awakened sleeping stirring alert
    open closed locked sealed blocked accessible barred shuttered
    occupied empty abandoned inhabited deserted populated vacant
    thriving declining prosperous struggling flourishing dying growing
    preserved decayed fossilized petrified mummified fresh rotting
    charged depleted full empty loaded unloaded armed disarmed
  ],

  # ===========================================================================
  # CHARACTER TABLES - Personality, motivation, identity for NPCs
  # ===========================================================================

  character_descriptors: %w[
    weathered scarred youthful elderly grizzled slender muscular gaunt
    towering diminutive graceful awkward elegant rugged delicate imposing
    wiry stocky lanky angular soft-featured sharp-eyed battle-worn
    sun-bronzed pale freckled tattooed pierced branded calloused
    hunched proud limping nimble slow deliberate quick restless
    immaculate disheveled pristine ragged well-groomed unkempt
    broad-shouldered narrow lean portly rotund athletic wizened
    scarlet-haired raven-haired silver-haired bald bearded clean-shaven
    one-eyed hook-nosed sharp-chinned square-jawed high-cheekboned
    weatherbeaten sun-kissed moonpale dusky olive-skinned ebony
    lithe sinewy compact massive slight hulking petite statuesque
    hawk-nosed aquiline pug-nosed flat-nosed crooked-nosed
    thin-lipped full-lipped gap-toothed gold-toothed missing-teeth
    bright-eyed hollow-eyed sunken-eyed wide-eyed squinting glaring
    hale sickly robust frail vigorous feeble spry decrepit
    handsome beautiful plain homely striking unremarkable distinctive
    intimidating approachable fierce gentle stern warm cold distant
  ],

  character_personality: %w[
    cautious reckless patient impatient generous miserly honest deceitful
    cheerful melancholy optimistic pessimistic confident insecure brave
    cowardly loyal treacherous kind cruel gentle fierce calm volatile
    curious indifferent ambitious content humble arrogant empathetic cold
    trusting suspicious playful serious stubborn flexible impulsive
    calculating passionate detached sincere manipulative idealistic cynical
    gregarious solitary diplomatic blunt tactful graceless refined crude
    witty humorless sarcastic earnest jovial dour stoic emotional
    practical dreamy pragmatic romantic methodical chaotic organized messy
    punctual tardy reliable flaky responsible irresponsible diligent lazy
    thrifty extravagant modest boastful secretive open guarded transparent
    forgiving grudging merciful ruthless just biased fair prejudiced
    devout skeptical pious irreverent spiritual materialistic mystical rational
    adventurous cautious bold timid daring reserved assertive meek
    competitive cooperative aggressive passive confrontational avoidant
    perfectionist sloppy demanding easygoing strict lenient rigid adaptable
    obsessive casual focused scattered driven aimless purposeful wandering
    nurturing neglectful protective smothering encouraging critical supportive
  ],

  character_motivations: %w[
    revenge redemption wealth power knowledge love family duty honor
    survival freedom justice vengeance protection ambition curiosity
    belonging recognition legacy security adventure escape atonement
    glory dominance service faith creativity discovery independence
    stability change acceptance proving-worth finding-purpose healing
    pleasure comfort status influence control order chaos balance
    truth answers enlightenment transcendence immortality perfection
    restoration preservation destruction transformation revolution tradition
    companionship solitude peace excitement challenge mastery
    absolution penance sacrifice martyrdom salvation damnation
    homecoming wanderlust exploration conquest liberation rebellion
    unification division harmony discord creation innovation
    remembrance forgetting mourning celebration honoring avenging
    teaching learning mentoring protecting serving ruling
  ],

  character_identity: %w[
    outcast noble peasant merchant scholar warrior priest artisan
    criminal refugee orphan heir veteran exile wanderer guardian
    leader follower loner socialite traditionalist rebel perfectionist
    dreamer pragmatist idealist skeptic believer doubter protector
    hunter gatherer builder destroyer healer teacher student seeker
    survivor victim champion underdog martyr saint sinner penitent
    prodigy failure genius fool prophet charlatan sage madman
    hero villain antihero sidekick mentor nemesis rival ally
    native foreigner immigrant emigrant settler colonist invader
    loyalist traitor patriot dissenter conformist revolutionary
    aristocrat commoner bourgeois proletarian elite pariah
    insider outsider newcomer veteran stranger familiar
    master apprentice journeyman novice expert amateur dabbler
    parent child sibling spouse lover friend enemy stranger
  ],

  # ===========================================================================
  # MOOD AND TONE TABLES - For setting atmosphere
  # ===========================================================================

  adventure_tone: %w[
    mysterious ominous foreboding hopeful desperate urgent calm
    tense relaxed dangerous safe welcoming hostile neutral eerie
    whimsical dark grim lighthearted serious comedic tragic epic
    intimate grand subtle obvious hidden revealed ancient modern
    magical mundane supernatural natural strange familiar alien
    heroic villainous morally-grey nuanced simple complex
    action-packed contemplative fast-paced leisurely frantic measured
    violent peaceful bloody clean brutal gentle harsh soft
    romantic platonic passionate cold warm frigid temperate
    political personal cosmic local universal intimate global
    religious secular spiritual material transcendent grounded
    psychological physical emotional intellectual visceral cerebral
    realistic fantastical surreal dreamlike nightmarish idyllic
    nostalgic forward-looking present-focused timeless eternal momentary
    optimistic pessimistic hopeful cynical idealistic pragmatic
    triumphant tragic bittersweet satisfying unsettling ambiguous
  ],

  # ===========================================================================
  # NOUN TABLES - For SELECTING what to generate (not for inspiration)
  # Use these when you need to pick a random type, not describe something
  # ===========================================================================

  # Object types (for random item selection)
  object_types: %w[
    sword dagger knife axe mace hammer spear bow crossbow staff
    shield helm armor gauntlets boots cloak ring amulet bracelet
    potion vial flask bottle scroll tome book journal map
    torch lantern candle lamp mirror key lock chest box
    rope chain hook grapple net trap snare
    cup mug goblet chalice plate bowl pitcher tankard
    chair table bed chest wardrobe shelf desk bench stool
    rug tapestry curtain pillow blanket sheet mattress
    brush comb scissors needle thread cloth fabric
    hammer saw chisel file drill awl plane
    pot pan kettle cauldron skillet ladle spoon fork
    bag sack pouch purse pack basket crate barrel
    instrument flute drum horn lute harp bell whistle
    toy doll figurine puppet ball game dice cards
    coin purse gem jewel pearl crystal stone
  ],

  # Location types (for random place selection)
  location_types: %w[
    tavern inn pub alehouse brewery winery distillery
    shop market bazaar stall booth vendor
    smithy forge foundry workshop studio
    temple church chapel shrine sanctuary cathedral
    castle palace manor estate villa cottage hovel
    barracks garrison watchtower fortress keep
    library archive museum gallery academy school
    hospital infirmary apothecary herbalist
    prison dungeon cell stockade gallows
    stable barn farm mill granary silo warehouse
    dock pier harbor port shipyard marina
    arena coliseum theater amphitheater stage
    garden park courtyard plaza square fountain
    street alley lane avenue road path trail
    bridge gate wall tower rampart battlement
    cave cavern tunnel mine quarry pit
    forest grove clearing glade meadow field
    river stream creek pond lake marsh swamp
    hill mountain valley canyon cliff ridge
    beach cove bay harbor island reef
    cemetery graveyard crypt tomb mausoleum
  ],

  # Creature types (for random monster/animal selection)
  creature_types: %w[
    wolf bear boar deer elk stag fox rabbit hare
    eagle hawk falcon owl raven crow sparrow
    snake serpent viper cobra asp adder
    spider scorpion beetle ant wasp bee
    rat mouse bat squirrel weasel badger
    fish salmon trout bass carp pike eel
    frog toad newt salamander turtle tortoise
    horse pony donkey mule ox cow bull
    dog hound mastiff terrier shepherd
    cat lion tiger leopard panther jaguar
    dragon wyrm drake wyvern serpent
    goblin orc troll ogre giant cyclops
    skeleton zombie ghost specter wraith shade
    demon devil imp fiend hellhound
    elemental golem construct automaton
    griffon hippogriff manticore chimera sphinx
    unicorn pegasus phoenix thunderbird
    vampire werewolf shapeshifter doppelganger
  ],

  # Character roles/occupations (for NPC type selection)
  character_roles: %w[
    blacksmith armorer weaponsmith silversmith goldsmith
    carpenter mason builder architect engineer
    tailor weaver dyer clothier seamstress
    baker butcher brewer vintner cook chef
    farmer rancher herder shepherd hunter trapper
    fisherman sailor captain navigator shipwright
    merchant trader shopkeeper vendor peddler
    innkeeper barkeep server maid porter
    guard soldier knight captain sergeant
    priest priestess monk nun acolyte bishop
    wizard mage sorcerer warlock witch druid
    healer physician surgeon herbalist midwife
    scribe clerk scholar librarian archivist
    bard musician entertainer actor dancer
    thief rogue assassin spy smuggler
    noble lord lady duke duchess baron
    servant butler maid footman groom stable-hand
    beggar vagrant urchin orphan street-rat
  ],

  # ===========================================================================
  # CREATURE DESCRIPTION TABLES - For monster/animal generation
  # ===========================================================================

  creature_adjectives: %w[
    massive tiny hulking lithe serpentine winged tentacled
    armored scaled feathered furred chitin-plated crystalline shadowy
    luminescent translucent skeletal rotting bloated withered ancient
    newborn mutated hybrid elemental ethereal demonic angelic feral
    domesticated cunning mindless ravenous territorial pack solitary
    burrowing aquatic amphibious nocturnal diurnal venomous poisonous
    horned tusked fanged clawed taloned beaked snouted muzzled
    predatory scavenging herbivorous omnivorous carnivorous parasitic
    migratory sedentary territorial nomadic colonial hive-dwelling
    bioluminescent camouflaged mimicking warning-colored cryptic
    blind deaf mute eyeless multi-eyed multi-limbed multi-headed
    gelatinous slimy mucous sticky barbed spined ridged smooth
    iridescent mottled striped spotted banded ringed patterned
  ],

  creature_abilities: %w[
    flight burrowing climbing swimming camouflage regeneration
    venom paralysis poison fire-breath ice-breath acid-spit
    electric-shock web-spinning shape-shifting invisibility teleportation
    mind-control telepathy fear-aura charm hypnosis petrification
    life-drain energy-absorption summoning duplication phasing
    tremor-sense heat-sense echolocation night-vision darkvision
    water-breathing pressure-resistance heat-resistance cold-resistance
    rapid-healing limb-regrowth size-changing density-shifting
    wall-climbing ceiling-walking water-walking shadow-step
    sonic-scream thunderclap earthquake grappling constricting
    blood-drain soul-drain illusory-form hibernate death-feign
  ],

  animal_behaviors: %w[
    stalking hunting grazing nesting migrating hibernating territorial
    curious aggressive defensive playful skittish alert sleeping
    feeding grooming mating calling warning fleeing circling
    burrowing climbing swimming diving soaring gliding perching
    foraging scavenging ambushing chasing herding pack-hunting
    basking sunning cooling wallowing dusting bathing preening
    marking patrolling guarding watching waiting pouncing
    displaying courting dancing singing nursing protecting
  ],

  # ===========================================================================
  # WORLD-BUILDING TABLES - For lore and setting elements
  # ===========================================================================

  noble_house_symbols: %w[
    lion wolf eagle serpent dragon phoenix raven stag boar bear
    falcon hawk griffin sphinx chimera unicorn kraken leviathan
    sword shield crown scepter chalice flame star moon sun tree
    tower gate bridge wall mountain river ocean storm thunder
    rose lily oak ash thorn ivy vine bloom root branch
    blood bone iron gold silver copper bronze steel
  ],

  deity_domains: %w[
    creation destruction preservation change judgment war healing
    sun moon storm sea earth fire sky death life fate
    harvest hunt forge craft music poetry love wisdom
    nature shadow light order chaos justice mercy vengeance
    knowledge secrets dreams madness time balance
    beauty youth age birth rebirth wealth fortune
    travel roads thresholds boundaries gates protection
    wilderness civilization home hearth family ancestors
  ],

  legend_elements: %w[
    hero villain monster treasure kingdom war peace alliance
    betrayal sacrifice resurrection prophecy curse blessing quest
    artifact weapon armor spell ritual gateway portal prison
    battle siege victory defeat fall rise redemption corruption
    discovery founding destruction rebirth transformation ascension
    golden-age dark-age lost-age dragon-slayer demon-binder
    sunken-city flying-castle hidden-valley lost-island
    forbidden-knowledge stolen-fire cursed-gift broken-sword
    sleeping-army wandering-hero returning-king chosen-one
  ],

  # ===========================================================================
  # NAMES - For character naming
  # ===========================================================================

  names: %w[
    Aldric Brynn Caelum Dara Elowen Faelan Gideon Helga Isolde Jareth
    Kira Lysander Mira Nolan Orla Petra Quinn Rowan Seren Theron
    Una Vance Wren Xander Yara Zephyr Ash Blaze Cinder Drake
    Ember Flint Gale Hawk Ivy Jade Kestrel Lark Moss Onyx
    Pike Quill Raven Sage Stone Thorn Vale Wilder Yarrow Zara
    Alaric Branwen Cedric Dahlia Elara Finn Gareth Hilda Ingrid Johan
    Katrina Leander Magnus Niamh Oswin Perrin Quinlan Rhys Sylvia Tristan
    Ursula Viktor Willow Xavier Yvaine Zander Amara Bastian Cordelia Dante
    Elena Felix Gwendolyn Hugo Isadora Julian Kalista Lucian Morgana Nathaniel
    Ophelia Percival Rosalind Sebastian Tatiana Ulric Valentina Wolfgang Ximena Yosef
  ]
}.freeze

# ==============================================================================
# SEEDING LOGIC
# ==============================================================================

def seed_tables!
  puts 'Seeding randomization tables for world generation...'
  puts

  # Clear existing entries
  DB[:seed_term_entries].delete
  puts 'Cleared existing entries'
  puts

  total = 0
  categories = {
    'ADJECTIVE TABLES (for inspiration)' => %i[
      physical_adjectives materials size_adjectives age_adjectives
      quality_adjectives spatial_adjectives atmosphere_adjectives
      lighting_adjectives temperature_adjectives sound_adjectives
      scent_adjectives condition_adjectives
    ],
    'CHARACTER TABLES' => %i[
      character_descriptors character_personality
      character_motivations character_identity
    ],
    'MOOD TABLES' => %i[adventure_tone],
    'NOUN TABLES (for selection)' => %i[
      object_types location_types creature_types character_roles
    ],
    'CREATURE TABLES' => %i[
      creature_adjectives creature_abilities animal_behaviors
    ],
    'WORLD-BUILDING TABLES' => %i[
      noble_house_symbols deity_domains legend_elements
    ],
    'NAME TABLES' => %i[names]
  }

  categories.each do |category_name, tables|
    puts "#{category_name}:"
    tables.each do |table_name|
      entries = SEED_TABLES[table_name]
      next unless entries

      entries.each_with_index do |entry, position|
        DB[:seed_term_entries].insert(
          table_name: table_name.to_s,
          entry: entry,
          position: position + 1
        )
      end

      puts "  #{table_name}: #{entries.length} entries"
      total += entries.length
    end
    puts
  end

  puts "Done! Loaded #{total} total entries across #{SEED_TABLES.length} tables."
end

# Run if executed directly
seed_tables! if __FILE__ == $PROGRAM_NAME
