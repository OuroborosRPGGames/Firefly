# frozen_string_literal: true

module NameGeneration
  # PatternGenerator is a Ruby port of the fantasyname pattern compiler.
  # It generates names based on pattern strings using symbol substitution.
  #
  # Pattern Syntax:
  #   s - generic syllable
  #   v - vowel
  #   V - vowel or vowel combination
  #   c - consonant
  #   B - consonant or consonant combination suitable for beginning a word
  #   C - consonant or consonant combination suitable anywhere in a word
  #   i - insult word
  #   m - mushy name
  #   M - mushy name ending
  #   D - consonant suited for a stupid person's name
  #   d - syllable suited for a stupid person's name (begins with vowel)
  #
  #   () - literal group (text emitted as-is)
  #   <> - symbol group (patterns interpreted)
  #   |  - random choice between options
  #   !  - capitalize the next component
  #   ~  - reverse the next component
  #
  # @example Basic usage
  #   gen = PatternGenerator.compile("!BsacC")
  #   gen.generate  # => "Drachack"
  #
  # @example With choices
  #   gen = PatternGenerator.compile("!B(a|e|i)ss")
  #   gen.generate  # => "Grass" or "Bress" or "Criss"
  #
  class PatternGenerator
    # Symbol tables for pattern substitution
    SYMBOLS = {
      # Generic syllables
      's' => %w[
        ach ack ad age ald ale an ang ar ard
        as ash at ath augh aw ban bel bur cer
        cha che dan dar del den dra dyn ech eld
        elm em en end eng enth er ess est et
        gar gha hat hin hon ia ight ild im ina
        ine ing ir is iss it kal kel kim kin
        ler lor lye mor mos nal ny nys old om
        on or orm os ough per pol qua que rad
        rak ran ray ril ris rod roth ryn sam
        say ser shy skel sul tai tan tas ther
        tia tin ton tor tur um und unt urn usk
        ust ver ves vor war wor yer
      ],

      # Single vowels
      'v' => %w[a e i o u y],

      # Vowels and vowel combinations
      'V' => %w[
        a e i o u y ae ai au ay ea ee
        ei eu ey ia ie oe oi oo ou ui
      ],

      # Single consonants
      'c' => %w[b c d f g h j k l m n p q r s t v w x y z],

      # Beginning consonants (suitable for word start)
      'B' => %w[
        b bl br c ch chr cl cr d dr f g
        h j k l ll m n p ph qu r rh s
        sch sh sl sm sn st str sw t th thr
        tr v w wh y z zh
      ],

      # Interior consonants (suitable anywhere in word)
      'C' => %w[
        b c ch ck d f g gh h k l ld ll
        lt m n nd nn nt p ph q r rd rr
        rt s sh ss st t th v w y z
      ],

      # Insult words
      'i' => %w[
        air ankle ball beef bone bum bumble bump
        cheese clod clot clown corn dip dolt doof
        dork dumb face finger foot fumble goof
        grumble head knock knocker knuckle loaf lump
        lunk meat muck munch nit numb pin puff
        skull snark sneeze thimble twerp twit wad
        wimp wipe
      ],

      # Mushy names
      'm' => %w[
        baby booble bunker cuddle cuddly cutie doodle
        foofie gooble honey kissie lover lovey moofie
        mooglie moopie moopsie nookum poochie poof
        poofie pookie schmoopie schnoogle schnookie
        schnookum smooch smoochie smoosh snoogle snoogy
        snookie snookum snuggy sweetie woogle woogy
        wookie wookum wuddle wuddly wuggy wunny
      ],

      # Mushy name endings
      'M' => %w[
        boo bunch bunny cake cakes cute darling
        dumpling dumplings face foof goo head kin
        kins lips love mush pie poo pooh pook pums
      ],

      # Consonants for stupid names
      'D' => %w[
        b bl br cl d f fl fr g gh gl gr
        h j k kl m n p th w
      ],

      # Syllables for stupid names (starts with vowel)
      'd' => %w[
        elch idiot ob og ok olph olt omph ong
        onk oo oob oof oog ook ooz org ork orm
        oron ub uck ug ulf ult um umb ump umph
        un unb ung unk unph unt uzz
      ]
    }.freeze

    # Abstract base class for generator nodes
    class Generator
      def generate
        raise NotImplementedError
      end

      def to_s
        generate
      end
    end

    # Emits a literal string
    class Literal < Generator
      def initialize(text)
        @text = text
      end

      def generate
        @text
      end
    end

    # Randomly selects from an array of generators
    class Random < Generator
      def initialize(generators)
        @generators = generators
      end

      def generate
        return '' if @generators.empty?

        @generators.sample.generate
      end
    end

    # Runs generators in sequence and concatenates output
    class Sequence < Generator
      def initialize(generators)
        @generators = generators
      end

      def generate
        @generators.map(&:generate).join
      end
    end

    # Capitalizes the output of wrapped generator
    class Capitalizer < Generator
      def initialize(generator)
        @generator = generator
      end

      def generate
        result = @generator.generate
        result.empty? ? result : result[0].upcase + result[1..]
      end
    end

    # Reverses the output of wrapped generator
    class Reverser < Generator
      def initialize(generator)
        @generator = generator
      end

      def generate
        @generator.generate.reverse
      end
    end

    # Builds up a grouping during compilation
    class Group
      attr_reader :set, :wrappers

      def initialize
        @set = [[]]
        @wrappers = []
      end

      def add(generator)
        wrapped = @wrappers.reduce(generator) { |g, wrapper| wrapper.new(g) }
        @wrappers.clear
        @set.last << wrapped
        self
      end

      def split
        @set << []
        self
      end

      def wrap(wrapper_class)
        @wrappers << wrapper_class
        self
      end

      def emit
        sequences = @set.map { |s| Sequence.new(compress(s)) }
        Random.new(sequences)
      end

      private

      def compress(generators)
        result = []
        buffer = []

        generators.each do |g|
          if g.is_a?(Literal)
            buffer << g.generate
          else
            unless buffer.empty?
              result << Literal.new(buffer.join)
              buffer.clear
            end
            result << g
          end
        end

        unless buffer.empty?
          result << Literal.new(buffer.join)
        end

        result
      end
    end

    # Builds literal grouping (characters emitted as-is)
    class LiteralGroup < Group
      def add(char)
        super(Literal.new(char))
      end
    end

    # Builds symbol grouping (characters interpreted as symbols)
    class SymbolGroup < Group
      def add(char, literal: false)
        generator = if literal
                      char
                    elsif SYMBOLS.key?(char)
                      Random.new(SYMBOLS[char].map { |s| Literal.new(s) })
                    else
                      Literal.new(char)
                    end
        super(generator)
      end
    end

    class << self
      # Compile a pattern string into a generator
      # @param pattern [String] The pattern to compile
      # @return [Generator] A generator that can produce names
      def compile(pattern)
        stack = [SymbolGroup.new]

        pattern.each_char do |c|
          case c
          when '<'
            stack.push(SymbolGroup.new)
          when '('
            stack.push(LiteralGroup.new)
          when '>', ')'
            raise 'Unbalanced brackets' if stack.length == 1

            if c == '>' && stack.last.is_a?(LiteralGroup)
              raise 'Unexpected ">" in input'
            end
            if c == ')' && stack.last.is_a?(SymbolGroup)
              raise 'Unexpected ")" in input'
            end

            last = stack.pop.emit
            stack.last.add(last, literal: true)
          when '|'
            stack.last.split
          when '!'
            if stack.last.is_a?(SymbolGroup)
              stack.last.wrap(Capitalizer)
            else
              stack.last.add(c)
            end
          when '~'
            if stack.last.is_a?(SymbolGroup)
              stack.last.wrap(Reverser)
            else
              stack.last.add(c)
            end
          else
            stack.last.add(c)
          end
        end

        raise 'Missing closing bracket' if stack.length != 1

        stack.first.emit
      end

      # Generate a single name from a pattern
      # @param pattern [String] The pattern to use
      # @return [String] A generated name
      def generate(pattern)
        compile(pattern).generate
      end
    end

    # Pre-compiled common patterns for fantasy names
    PATTERNS = {
      # Elven patterns (flowing, many vowels)
      elf: [
        '!sVsV',
        "!BVsV'sV",
        '!VsVsV',
        '!sV(l|r)Vs',
        '!BVsVss'
      ],

      # Dwarven patterns (hard consonants, short)
      dwarf: [
        '!BVrC',
        '!BVCin',
        '!BVrCin',
        '!DVC',
        '!BVrCon'
      ],

      # Orc patterns (harsh, guttural)
      orc: [
        '!Dorg',
        '!DVC(uk|ak|og)',
        '!DdC',
        "!Bd'VC",
        '!DvCog'
      ],

      # Human fantasy patterns
      human_fantasy: [
        '!BVs',
        '!sVs',
        '!BVsVn',
        '!sVCVs',
        '!BVsCVs'
      ],

      # Sci-fi alien patterns
      alien: [
        "!BV'sVC",
        '!BVxVC',
        "!sV'xVs",
        '!zVsVC',
        "!BV'CVx"
      ],

      # Demon/dark patterns
      demon: [
        "!Ds'VCs",
        "!BVd'Vs",
        '!DvCvd',
        "!Bd'VCd",
        '!DvCvCs'
      ]
    }.freeze

    # Generate a name for a given race/category
    # @param race [Symbol] The race/category (:elf, :dwarf, :orc, :human_fantasy, :alien, :demon)
    # @return [String] A generated name
    def self.generate_for_race(race)
      patterns = PATTERNS[race] || PATTERNS[:human_fantasy]
      generate(patterns.sample)
    end
  end
end
