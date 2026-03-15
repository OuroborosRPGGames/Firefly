# frozen_string_literal: true

module NameGeneration
  # CharacterNameGenerator generates character names (forename + surname)
  # with support for multiple cultures, genders, settings, and generation modes.
  #
  # Generation Modes:
  #   :pool_only      - Only select from curated name pools
  #   :pattern_only   - Only use pattern-based generation
  #   :markov_only    - Only use Markov chain generation
  #   :hybrid         - Mix real names with procedural generation (default)
  #   :auto           - Automatically select best mode for culture
  #
  # Usage:
  #   generator = CharacterNameGenerator.new
  #   result = generator.generate(gender: :female, culture: :nordic)
  #   result.forename # => "Sigrid"
  #   result.surname  # => "Eriksdotter"
  #   result.full_name # => "Sigrid Eriksdotter"
  #
  class CharacterNameGenerator < BaseGenerator
    # Probability weights for hybrid mode
    POOL_WEIGHT = 0.7
    PATTERN_WEIGHT = 0.2
    MARKOV_WEIGHT = 0.1

    # All supported cultures (mapped to forename file prefixes)
    CULTURES = %i[
      western french german italian spanish portuguese dutch
      nordic swedish danish norwegian finnish
      russian polish czech hungarian romanian ukrainian slovak serbian croatian
      greek turkish arabic persian hebrew
      japanese korean chinese vietnamese thai
      indian indonesian
      african afrikaans zulu yoruba
      albanian azerbaijani armenian georgian latvian lithuanian estonian macedonian
      sumerian inca latin gothic saxon norman arthurian
      fantasy demon duskvol
    ].freeze

    # Cultures that have gendered names
    GENDERED_CULTURES = %i[
      western french german italian spanish portuguese dutch
      nordic swedish danish norwegian finnish
      russian polish czech hungarian romanian ukrainian slovak serbian croatian
      greek turkish arabic persian hebrew
      japanese korean chinese vietnamese thai
      indian indonesian
      african afrikaans zulu yoruba
      albanian azerbaijani armenian latvian lithuanian estonian macedonian
      sumerian inca latin gothic saxon norman arthurian
      fantasy
    ].freeze

    # Cultures that use pattern-based generation
    PATTERN_CULTURES = %i[
      elf dwarf orc alien demon
    ].freeze

    # Genre to default culture mappings
    GENRE_DEFAULTS = {
      earth_historic: :western,
      earth_modern: :western,
      earth_future: :western,
      fictional_historic: :fantasy,
      fictional_contemporary: :western,
      fictional_future_human: :western,
      fictional_future_alien: :alien
    }.freeze

    # Pattern configurations for procedural generation
    RACE_PATTERNS = {
      elf: {
        forename: ['!sVsV', "!BVsV'sV", '!VsVsV', '!sV(l|r)Vs', '!BVsVss'],
        surname: ["!sV'sVs", '!BVsVsVn', '!(El|Ar|Gal|Sil)sVsV']
      },
      dwarf: {
        forename: ['!BVrC', '!BVCin', '!BVrCin', '!DVC', '!BVrCon'],
        surname: ['!BVrCson', '!BVCbeard', '!BVCaxe', '!(Iron|Stone|Gold)sVC']
      },
      orc: {
        forename: ['!Dorg', '!DVC(uk|ak|og)', '!DdC', "!Bd'VC", '!DvCog'],
        surname: ["!DVC'VC", '!DVCkill', '!DVCsmash']
      },
      alien: {
        forename: ["!BV'sVC", '!BVxVC', "!sV'xVs", '!zVsVC', "!BV'CVx"],
        surname: ["!xV'CVx", '!zVsVx', "!BV'xVC"]
      },
      demon: {
        forename: ["!Ds'VCs", "!BVd'Vs", '!DvCvd', "!Bd'VCd", '!DvCvCs'],
        surname: ['!DVCbane', "!DVC'VCd", '!DVCfire']
      }
    }.freeze

    # Generate a character name
    # @param gender [Symbol] :male, :female, :neutral, :any
    # @param culture [Symbol] any supported culture
    # @param setting [Symbol] genre preset
    # @param forename_only [Boolean] skip surname generation
    # @param mode [Symbol] :pool_only, :pattern_only, :markov_only, :hybrid, :auto
    # @return [NameResult]
    def generate(gender: :any, culture: nil, setting: :earth_modern, forename_only: false, mode: :auto)
      # Resolve culture from setting if not specified
      culture ||= GENRE_DEFAULTS[setting] || :western
      culture = normalize_culture(culture)

      # Resolve gender
      resolved_gender = resolve_gender(gender, culture)

      # Determine generation mode
      resolved_mode = resolve_mode(mode, culture)

      # Generate forename
      forename = generate_forename(resolved_gender, culture, resolved_mode)

      # Generate surname (unless forename_only)
      surname = forename_only ? nil : generate_surname(culture, resolved_mode)

      # Build full name
      full_name = [forename, surname].compact.join(' ')

      NameResult.new(
        forename: forename,
        surname: surname,
        full_name: full_name,
        metadata: {
          gender: resolved_gender,
          culture: culture,
          setting: setting,
          mode: resolved_mode
        }
      )
    end

    private

    def normalize_culture(culture)
      return culture if CULTURES.include?(culture) || PATTERN_CULTURES.include?(culture)

      # Map some common aliases
      case culture
      when :english then :western
      when :norse then :nordic
      when :japan then :japanese
      when :china then :chinese
      when :human_scifi then :western
      when :scifi then :alien
      else :western
      end
    end

    def resolve_gender(gender, culture)
      return gender if %i[male female].include?(gender)

      # For cultures with gendered names, pick randomly
      if GENDERED_CULTURES.include?(culture)
        %i[male female].sample
      else
        :neutral
      end
    end

    def resolve_mode(mode, culture)
      return mode unless mode == :auto

      # Pattern-based cultures use pattern generation
      if PATTERN_CULTURES.include?(culture)
        :pattern_only
      elsif pool_available?(culture)
        :hybrid
      else
        :pattern_only
      end
    end

    def pool_available?(culture)
      forename_file(culture, :male) || forename_file(culture, :female)
    end

    def generate_forename(gender, culture, mode)
      case mode
      when :pool_only
        generate_pool_forename(gender, culture)
      when :pattern_only
        generate_pattern_forename(culture)
      when :markov_only
        generate_markov_forename(gender, culture)
      when :hybrid
        generate_hybrid_forename(gender, culture)
      else
        generate_hybrid_forename(gender, culture)
      end
    end

    def generate_surname(culture, mode)
      case mode
      when :pool_only
        generate_pool_surname(culture)
      when :pattern_only
        generate_pattern_surname(culture)
      when :markov_only
        generate_markov_surname(culture)
      when :hybrid
        generate_hybrid_surname(culture)
      else
        generate_hybrid_surname(culture)
      end
    end

    # Pool-based generation (from imported data)
    def generate_pool_forename(gender, culture)
      names = load_forename_pool(gender, culture)
      return generate_fallback_forename if names.empty?

      weighted_select(names, category: "forename_#{culture}_#{gender}")
    end

    def generate_pool_surname(culture)
      names = load_surname_pool(culture)
      return generate_fallback_surname if names.empty?

      weighted_select(names, category: "surname_#{culture}")
    end

    # Pattern-based generation
    def generate_pattern_forename(culture)
      patterns = RACE_PATTERNS.dig(culture, :forename) || RACE_PATTERNS[:elf][:forename]
      PatternGenerator.generate(patterns.sample)
    end

    def generate_pattern_surname(culture)
      patterns = RACE_PATTERNS.dig(culture, :surname) || RACE_PATTERNS[:elf][:surname]
      PatternGenerator.generate(patterns.sample)
    end

    # Markov-based generation
    def generate_markov_forename(gender, culture)
      names = load_forename_pool(gender, culture)
      return generate_fallback_forename if names.length < 10

      markov = MarkovGenerator.build_from_names(names)
      result = markov.generate
      # Return fallback if markov generated empty string (e.g., short Unicode names)
      result.nil? || result.empty? ? generate_fallback_forename : result
    end

    def generate_markov_surname(culture)
      names = load_surname_pool(culture)
      return generate_fallback_surname if names.length < 10

      markov = MarkovGenerator.build_from_names(names)
      result = markov.generate
      # Return fallback if markov generated empty string (e.g., short Unicode names)
      result.nil? || result.empty? ? generate_fallback_surname : result
    end

    # Hybrid generation (mix of pool, pattern, and markov)
    def generate_hybrid_forename(gender, culture)
      roll = rand

      if roll < POOL_WEIGHT
        result = generate_pool_forename(gender, culture)
        return result if result && !result.empty?
      end

      if roll < POOL_WEIGHT + PATTERN_WEIGHT
        if PATTERN_CULTURES.include?(culture)
          return generate_pattern_forename(culture)
        else
          # For non-pattern cultures, try pool again or Markov
          result = generate_pool_forename(gender, culture)
          return result if result && !result.empty?
        end
      end

      # Markov fallback
      generate_markov_forename(gender, culture)
    end

    def generate_hybrid_surname(culture)
      roll = rand

      if roll < POOL_WEIGHT
        result = generate_pool_surname(culture)
        return result if result && !result.empty?
      end

      if roll < POOL_WEIGHT + PATTERN_WEIGHT
        if PATTERN_CULTURES.include?(culture)
          return generate_pattern_surname(culture)
        else
          result = generate_pool_surname(culture)
          return result if result && !result.empty?
        end
      end

      # For real cultures without surname data, combine surname components
      generate_composite_surname(culture)
    end

    def generate_composite_surname(culture)
      # Try to find a related culture with surname data
      surname_culture = find_surname_culture(culture)
      names = load_surname_pool(surname_culture)

      if names.any?
        weighted_select(names, category: "surname_#{surname_culture}")
      else
        generate_fallback_surname
      end
    end

    def find_surname_culture(culture)
      # Map cultures to a fallback with surname data
      culture_families = {
        western: %i[western french german],
        french: %i[french western],
        german: %i[german western],
        italian: %i[italian western],
        spanish: %i[spanish western],
        portuguese: %i[portuguese spanish western],
        dutch: %i[dutch german western],
        nordic: %i[nordic swedish danish],
        swedish: %i[swedish nordic],
        danish: %i[danish nordic swedish],
        norwegian: %i[norwegian nordic swedish],
        finnish: %i[finnish nordic],
        russian: %i[russian ukrainian polish],
        polish: %i[polish russian czech],
        czech: %i[czech polish slovak],
        hungarian: %i[hungarian romanian],
        romanian: %i[romanian hungarian],
        ukrainian: %i[ukrainian russian],
        slovak: %i[slovak czech polish],
        serbian: %i[serbian croatian],
        croatian: %i[croatian serbian],
        greek: %i[greek],
        turkish: %i[turkish],
        arabic: %i[arabic persian],
        persian: %i[persian arabic],
        hebrew: %i[hebrew],
        japanese: %i[japanese],
        korean: %i[korean],
        chinese: %i[chinese],
        vietnamese: %i[vietnamese],
        thai: %i[thai],
        indian: %i[indian],
        indonesian: %i[indonesian],
        african: %i[african yoruba zulu],
        afrikaans: %i[afrikaans african],
        zulu: %i[zulu african],
        yoruba: %i[yoruba african],
        albanian: %i[albanian],
        azerbaijani: %i[azerbaijani turkish],
        armenian: %i[armenian],
        georgian: %i[georgian],
        latvian: %i[latvian lithuanian],
        lithuanian: %i[lithuanian latvian],
        estonian: %i[estonian finnish],
        macedonian: %i[macedonian serbian],
        sumerian: %i[sumerian arabic],
        inca: %i[inca spanish],
        latin: %i[latin italian],
        gothic: %i[gothic german],
        saxon: %i[saxon western],
        norman: %i[norman french western],
        arthurian: %i[arthurian western],
        fantasy: %i[fantasy],
        demon: %i[demon],
        duskvol: %i[duskvol]
      }

      families = culture_families[culture] || [:western]
      families.find { |c| surname_file_exists?(c) } || :western
    end

    def surname_file_exists?(culture)
      surname_file(culture)
    end

    # File loading helpers
    def load_forename_pool(gender, culture)
      file = forename_file(culture, gender)
      return [] unless file

      data = DataLoader.load('character/forenames', file)
      data[:names] || []
    rescue ArgumentError => e
      warn "[CharacterNameGenerator] Failed to load forenames from #{file}: #{e.message}"
      []
    end

    def load_surname_pool(culture)
      file = surname_file(culture)
      return [] unless file

      data = DataLoader.load('character/surnames', file)
      data[:names] || []
    rescue ArgumentError => e
      warn "[CharacterNameGenerator] Failed to load surnames from #{file}: #{e.message}"
      []
    end

    def forename_file(culture, gender)
      # Try exact match first
      file = "#{culture}_#{gender}"
      return file if DataLoader.exists?('character/forenames', file)

      # Try neutral gender
      neutral = "#{culture}_neutral"
      return neutral if DataLoader.exists?('character/forenames', neutral)

      # Try opposite gender as fallback
      opposite = gender == :male ? :female : :male
      opposite_file = "#{culture}_#{opposite}"
      return opposite_file if DataLoader.exists?('character/forenames', opposite_file)

      nil
    end

    def surname_file(culture)
      file = culture.to_s
      DataLoader.exists?('character/surnames', file) ? file : nil
    end

    # For pool_available? check
    def forename_file_path(culture, gender)
      file = forename_file(culture, gender)
      file ? "exists" : nil
    end

    def surname_file_path(culture)
      file = surname_file(culture)
      file ? "exists" : nil
    end

    def generate_fallback_forename
      fallback_forenames = %w[Alex Jordan Morgan Casey Riley Quinn Avery Taylor]
      fallback_forenames.sample
    end

    def generate_fallback_surname
      fallback_surnames = %w[Smith Jones Taylor Brown Wilson Johnson Williams Davis]
      fallback_surnames.sample
    end
  end
end
