#!/usr/bin/env ruby
# frozen_string_literal: true

# Name Import Script
# Imports names from multiple source repositories:
# 1. names repo (text files)
# 2. faker repo (TypeScript arrays)
# 3. nvjob repo (C# arrays)

require 'yaml'
require 'fileutils'
require 'time'

class NameImporter
  NAMES_REPO = ENV.fetch('NAMES_REPO_PATH', File.expand_path('../../vendor/names/namedata', __dir__))
  FAKER_REPO = ENV.fetch('FAKER_REPO_PATH', File.expand_path('../../vendor/faker/src/locales', __dir__))
  NVJOB_REPO = ENV.fetch('NVJOB_REPO_PATH', File.expand_path('../../vendor/nvjob-name-generator/Assets/#NVJOB Name Generator/Name Generator', __dir__))
  OUTPUT_DIR = File.expand_path('../data/names', __dir__)

  # Mapping from names repo file patterns to our culture categories
  NAMES_REPO_MAPPING = {
    # Western European
    'engf' => { culture: :western, gender: :female, source: 'names_repo' },
    'engm' => { culture: :western, gender: :male, source: 'names_repo' },
    'engsur' => { culture: :western, type: :surname, source: 'names_repo' },
    'frenchf' => { culture: :french, gender: :female, source: 'names_repo' },
    'frenchm' => { culture: :french, gender: :male, source: 'names_repo' },
    'frenchsur' => { culture: :french, type: :surname, source: 'names_repo' },

    # Nordic/Scandinavian
    'norsef' => { culture: :nordic, gender: :female, source: 'names_repo' },
    'norsem' => { culture: :nordic, gender: :male, source: 'names_repo' },
    'swedishm' => { culture: :swedish, gender: :male, source: 'names_repo' },

    # Norman (Medieval French/English)
    'normanf' => { culture: :norman, gender: :female, source: 'names_repo' },
    'normanm' => { culture: :norman, gender: :male, source: 'names_repo' },
    'normansur' => { culture: :norman, type: :surname, source: 'names_repo' },

    # Anglo-Saxon/Gothic (Historical)
    'saxonf' => { culture: :saxon, gender: :female, source: 'names_repo' },
    'saxonm' => { culture: :saxon, gender: :male, source: 'names_repo' },
    'gothf' => { culture: :gothic, gender: :female, source: 'names_repo' },
    'gothm' => { culture: :gothic, gender: :male, source: 'names_repo' },

    # Latin/Roman
    'latinf' => { culture: :latin, gender: :female, source: 'names_repo' },
    'latinm' => { culture: :latin, gender: :male, source: 'names_repo' },

    # Arabic
    'arabicf' => { culture: :arabic, gender: :female, source: 'names_repo' },
    'arabicm' => { culture: :arabic, gender: :male, source: 'names_repo' },

    # Japanese
    'japanf' => { culture: :japanese, gender: :female, source: 'names_repo' },
    'japanm' => { culture: :japanese, gender: :male, source: 'names_repo' },
    'japansur' => { culture: :japanese, type: :surname, source: 'names_repo' },

    # Eastern European
    'czechf' => { culture: :czech, gender: :female, source: 'names_repo' },
    'czechm' => { culture: :czech, gender: :male, source: 'names_repo' },
    'czechsur' => { culture: :czech, type: :surname, source: 'names_repo' },
    'albanianf' => { culture: :albanian, gender: :female, source: 'names_repo' },
    'albanianm' => { culture: :albanian, gender: :male, source: 'names_repo' },
    'albaniansur' => { culture: :albanian, type: :surname, source: 'names_repo' },
    'azerbaijanf' => { culture: :azerbaijani, gender: :female, source: 'names_repo' },
    'azerbaijanm' => { culture: :azerbaijani, gender: :male, source: 'names_repo' },
    'azerbaijansur' => { culture: :azerbaijani, type: :surname, source: 'names_repo' },

    # Ancient/Fantasy
    'sumerianf' => { culture: :sumerian, gender: :female, source: 'names_repo' },
    'sumerianm' => { culture: :sumerian, gender: :male, source: 'names_repo' },
    'incaf' => { culture: :inca, gender: :female, source: 'names_repo' },
    'incam' => { culture: :inca, gender: :male, source: 'names_repo' },
    'arthurianf' => { culture: :arthurian, gender: :female, source: 'names_repo' },
    'arthurianm' => { culture: :arthurian, gender: :male, source: 'names_repo' },

    # Fantasy/Fictional
    'demon' => { culture: :demon, gender: :neutral, source: 'names_repo' },
    'duskvolgiven' => { culture: :duskvol, gender: :neutral, source: 'names_repo' },
    'duskvolsur' => { culture: :duskvol, type: :surname, source: 'names_repo' },

    # Place names (for city generation)
    'engbynames' => { type: :place_suffix, source: 'names_repo' },
    'englocalities' => { type: :place_names, source: 'names_repo' },
    'oldengsurnames' => { culture: :western, type: :surname_historic, source: 'names_repo' },
    'engtradenames' => { type: :trade_names, source: 'names_repo' },
    'provinces' => { type: :provinces, source: 'names_repo' },
    'countries' => { type: :countries, source: 'names_repo' },

    # Scientific (for alien/scifi names)
    'asteroids' => { type: :asteroids, source: 'names_repo' },
    'flowergenus' => { type: :flora_genus, source: 'names_repo' },
    'flowerspecies' => { type: :flora_species, source: 'names_repo' }
  }.freeze

  # Faker locale to culture mapping
  FAKER_LOCALE_MAPPING = {
    'en' => :western,
    'en_AU' => :western,
    'en_CA' => :western,
    'en_GB' => :western,
    'en_US' => :western,
    'en_IE' => :western,
    'en_IN' => :indian,
    'en_ZA' => :african,
    'de' => :german,
    'de_AT' => :german,
    'de_CH' => :german,
    'fr' => :french,
    'fr_BE' => :french,
    'fr_CA' => :french,
    'fr_CH' => :french,
    'es' => :spanish,
    'es_MX' => :spanish,
    'it' => :italian,
    'pt_BR' => :portuguese,
    'pt_PT' => :portuguese,
    'nl' => :dutch,
    'nl_BE' => :dutch,
    'pl' => :polish,
    'ru' => :russian,
    'uk' => :ukrainian,
    'cs_CZ' => :czech,
    'sk' => :slovak,
    'ro' => :romanian,
    'ro_MD' => :romanian,
    'hu' => :hungarian,
    'sv' => :swedish,
    'da' => :danish,
    'nb_NO' => :norwegian,
    'fi' => :finnish,
    'el' => :greek,
    'tr' => :turkish,
    'ar' => :arabic,
    'he' => :hebrew,
    'fa' => :persian,
    'ur' => :urdu,
    'hi' => :hindi,
    'ja' => :japanese,
    'ko' => :korean,
    'zh_CN' => :chinese,
    'zh_TW' => :chinese,
    'vi' => :vietnamese,
    'th' => :thai,
    'id_ID' => :indonesian,
    'af_ZA' => :afrikaans,
    'zu_ZA' => :zulu,
    'yo_NG' => :yoruba,
    'hy' => :armenian,
    'ka_GE' => :georgian,
    'az' => :azerbaijani,
    'lv' => :latvian,
    'lt' => :lithuanian,
    'et' => :estonian,
    'hr' => :croatian,
    'sr_RS_latin' => :serbian,
    'mk' => :macedonian,
    'ne' => :nepali,
    'ku_ckb' => :kurdish,
    'uz_UZ_latin' => :uzbek,
    'dv' => :maldivian
  }.freeze

  def initialize
    @imported_data = {}
    @stats = { names_repo: 0, faker: 0, nvjob: 0 }
  end

  def run
    puts "Starting name import..."
    puts "=" * 60

    import_names_repo
    import_faker_repo
    import_nvjob_repo

    write_output_files
    print_summary
  end

  private

  def import_names_repo
    puts "\n[1/3] Importing from names repo..."

    Dir.glob(File.join(NAMES_REPO, '*.txt')).each do |file|
      basename = File.basename(file, '.txt')
      mapping = NAMES_REPO_MAPPING[basename]

      next unless mapping

      names = read_text_file(file)
      next if names.empty?

      add_names(names, mapping)
      @stats[:names_repo] += names.length
      puts "  #{basename}: #{names.length} names"
    end
  end

  def import_faker_repo
    puts "\n[2/3] Importing from faker repo..."

    Dir.glob(File.join(FAKER_REPO, '*/person')).each do |person_dir|
      locale = File.basename(File.dirname(person_dir))
      culture = FAKER_LOCALE_MAPPING[locale]

      next unless culture

      # Import first names (generic or gendered)
      import_faker_first_names(person_dir, locale, culture)

      # Import last names
      import_faker_last_names(person_dir, locale, culture)
    end
  end

  def import_faker_first_names(person_dir, locale, culture)
    first_name_file = File.join(person_dir, 'first_name.ts')

    if File.exist?(first_name_file)
      content = File.read(first_name_file)

      # Check for gendered arrays
      if content.include?('female:') || content.include?('male:')
        female_names = extract_ts_array(content, 'female')
        male_names = extract_ts_array(content, 'male')

        if female_names.any?
          add_names(female_names, { culture: culture, gender: :female, source: "faker_#{locale}" })
          @stats[:faker] += female_names.length
          puts "  #{locale} female: #{female_names.length} names"
        end

        if male_names.any?
          add_names(male_names, { culture: culture, gender: :male, source: "faker_#{locale}" })
          @stats[:faker] += male_names.length
          puts "  #{locale} male: #{male_names.length} names"
        end
      else
        # Generic names
        generic_names = extract_ts_array(content, 'generic') + extract_ts_default_array(content)
        if generic_names.any?
          add_names(generic_names, { culture: culture, gender: :neutral, source: "faker_#{locale}" })
          @stats[:faker] += generic_names.length
          puts "  #{locale} generic: #{generic_names.length} names"
        end
      end
    end
  end

  def import_faker_last_names(person_dir, locale, culture)
    last_name_file = File.join(person_dir, 'last_name.ts')

    if File.exist?(last_name_file)
      content = File.read(last_name_file)
      surnames = extract_ts_default_array(content) + extract_ts_array(content, 'generic')

      if surnames.any?
        add_names(surnames, { culture: culture, type: :surname, source: "faker_#{locale}" })
        @stats[:faker] += surnames.length
        puts "  #{locale} surnames: #{surnames.length} names"
      end
    end
  end

  def import_nvjob_repo
    puts "\n[3/3] Importing from nvjob repo..."

    nvjob_file = File.join(NVJOB_REPO, 'NVJOBNameGen.cs')
    return unless File.exist?(nvjob_file)

    content = File.read(nvjob_file)

    # Extract English names (type == 0: female, type == 1: male)
    english_female = extract_csharp_array(content, /type\s*==\s*0.*?firstName\s*=\s*new\s+string\[\]\s*\{([^}]+)\}/m)
    english_male = extract_csharp_array(content, /type\s*==\s*1.*?firstName\s*=\s*new\s+string\[\]\s*\{([^}]+)\}/m)

    if english_female.any?
      add_names(english_female, { culture: :western, gender: :female, source: 'nvjob' })
      @stats[:nvjob] += english_female.length
      puts "  English female: #{english_female.length} names"
    end

    if english_male.any?
      add_names(english_male, { culture: :western, gender: :male, source: 'nvjob' })
      @stats[:nvjob] += english_male.length
      puts "  English male: #{english_male.length} names"
    end

    # Extract Fantasy names (type == 5: female fantasy, type == 6: male fantasy)
    fantasy_female = extract_csharp_array(content, /type\s*==\s*5.*?firstName\s*=\s*new\s+string\[\]\s*\{([^}]+)\}/m)
    fantasy_male = extract_csharp_array(content, /type\s*==\s*6.*?firstName\s*=\s*new\s+string\[\]\s*\{([^}]+)\}/m)

    if fantasy_female.any?
      add_names(fantasy_female, { culture: :fantasy, gender: :female, source: 'nvjob' })
      @stats[:nvjob] += fantasy_female.length
      puts "  Fantasy female: #{fantasy_female.length} names"
    end

    if fantasy_male.any?
      add_names(fantasy_male, { culture: :fantasy, gender: :male, source: 'nvjob' })
      @stats[:nvjob] += fantasy_male.length
      puts "  Fantasy male: #{fantasy_male.length} names"
    end

    # Extract fantasy surname components
    surname_prefixes = extract_csharp_array(content, /secondName0\s*=\s*new\s+string\[\]\s*\{([^}]+)\}/m)
    surname_suffixes = extract_csharp_array(content, /secondName1\s*=\s*new\s+string\[\]\s*\{([^}]+)\}/m)

    if surname_prefixes.any?
      add_names(surname_prefixes, { culture: :fantasy, type: :surname_prefix, source: 'nvjob' })
      puts "  Fantasy surname prefixes: #{surname_prefixes.length}"
    end

    if surname_suffixes.any?
      add_names(surname_suffixes, { culture: :fantasy, type: :surname_suffix, source: 'nvjob' })
      puts "  Fantasy surname suffixes: #{surname_suffixes.length}"
    end
  end

  def read_text_file(file)
    File.readlines(file)
        .map(&:strip)
        .reject { |line| line.empty? || line.start_with?('#') }
        .uniq
  end

  def extract_ts_array(content, key)
    # Match TypeScript array: key: ['name1', 'name2', ...]
    if content =~ /#{key}:\s*\[([^\]]+)\]/m
      extract_quoted_strings($1)
    else
      []
    end
  end

  def extract_ts_default_array(content)
    # Match default export array: export default ['name1', 'name2', ...]
    if content =~ /export\s+default\s*\[([^\]]+)\]/m
      extract_quoted_strings($1)
    else
      []
    end
  end

  def extract_csharp_array(content, pattern)
    if content =~ pattern
      extract_quoted_strings($1)
    else
      []
    end
  end

  def extract_quoted_strings(str)
    str.scan(/"([^"]+)"|'([^']+)'/).flatten.compact.map(&:strip).reject(&:empty?).uniq
  end

  def add_names(names, metadata)
    culture = metadata[:culture]
    gender = metadata[:gender]
    type = metadata[:type]

    if type == :surname || type == :surname_prefix || type == :surname_suffix || type == :surname_historic
      key = "surnames/#{culture}"
      subkey = type == :surname ? :names : type
    elsif type
      key = "special/#{type}"
      subkey = :names
    else
      key = "forenames/#{culture}_#{gender}"
      subkey = :names
    end

    @imported_data[key] ||= { metadata: metadata.except(:source), names: [], sources: [] }
    @imported_data[key][:names].concat(names)
    @imported_data[key][:sources] << metadata[:source]
  end

  def write_output_files
    puts "\nWriting output files..."

    @imported_data.each do |key, data|
      # Deduplicate and sort
      unique_names = data[:names].uniq.sort

      # Build YAML structure
      yaml_data = {
        'metadata' => {
          'sources' => data[:sources].uniq,
          'count' => unique_names.length,
          'imported_at' => Time.now.iso8601
        }.merge(data[:metadata].transform_keys(&:to_s)),
        'names' => unique_names
      }

      # Determine output path
      output_path = File.join(OUTPUT_DIR, 'character', "#{key}.yml")
      FileUtils.mkdir_p(File.dirname(output_path))

      File.write(output_path, yaml_data.to_yaml)
      puts "  Wrote #{output_path} (#{unique_names.length} names)"
    end
  end

  def print_summary
    puts "\n" + "=" * 60
    puts "Import Summary:"
    puts "  Names repo: #{@stats[:names_repo]} names"
    puts "  Faker repo: #{@stats[:faker]} names"
    puts "  NVJob repo: #{@stats[:nvjob]} names"
    puts "  Total: #{@stats.values.sum} names"
    puts "\nOutput files: #{@imported_data.keys.length}"
    puts "=" * 60
  end
end

# Run the import
NameImporter.new.run
