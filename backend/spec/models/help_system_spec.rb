# frozen_string_literal: true

require 'spec_helper'

RSpec.describe HelpSystem do
  # Clear help systems and helpfiles that may have been seeded to avoid conflicts
  before(:all) do
    HelpfileSynonym.dataset.delete
    Helpfile.dataset.delete
    HelpSystem.dataset.delete
  end

  describe 'validations' do
    it 'requires name' do
      system = described_class.new
      expect(system.valid?).to be false
      expect(system.errors[:name]).to include('is not present')
    end

    it 'requires unique name' do
      described_class.create(name: 'test_system')
      duplicate = described_class.new(name: 'test_system')
      expect(duplicate.valid?).to be false
      expect(duplicate.errors[:name]).to include('is already taken')
    end

    it 'validates name max length of 50' do
      system = described_class.new(name: 'a' * 51)
      expect(system.valid?).to be false
      expect(system.errors[:name]).not_to be_empty
    end

    it 'validates display_name max length of 100' do
      system = described_class.new(name: 'test', display_name: 'a' * 101)
      expect(system.valid?).to be false
      expect(system.errors[:display_name]).not_to be_empty
    end

    it 'validates summary max length of 500' do
      system = described_class.new(name: 'test', summary: 'a' * 501)
      expect(system.valid?).to be false
      expect(system.errors[:summary]).not_to be_empty
    end

    it 'allows nil display_name' do
      system = described_class.new(name: 'test', display_name: nil)
      expect(system.valid?).to be true
    end

    it 'allows nil summary' do
      system = described_class.new(name: 'test', summary: nil)
      expect(system.valid?).to be true
    end
  end

  describe '#before_save' do
    it 'converts command_names array to pg_array' do
      system = described_class.create(name: 'cmd_test', command_names: %w[look walk run])
      system.reload
      expect(system.command_names.to_a).to eq(%w[look walk run])
    end

    it 'converts related_systems array to pg_array' do
      system = described_class.create(name: 'related_test', related_systems: %w[combat navigation])
      system.reload
      expect(system.related_systems.to_a).to eq(%w[combat navigation])
    end

    it 'converts key_files array to pg_array' do
      system = described_class.create(name: 'files_test', key_files: %w[file1.rb file2.rb])
      system.reload
      expect(system.key_files.to_a).to eq(%w[file1.rb file2.rb])
    end

    it 'converts constants_json hash to pg_jsonb' do
      system = described_class.create(name: 'const_test', constants_json: { 'key' => 'value' })
      system.reload
      expect(system.constants_json).to eq({ 'key' => 'value' })
    end
  end

  describe 'constants' do
    it 'defines SYSTEM_DEFINITIONS' do
      expect(described_class::SYSTEM_DEFINITIONS).to be_an(Array)
      expect(described_class::SYSTEM_DEFINITIONS).not_to be_empty
    end
  end

  describe '.find_by_name' do
    let!(:system) { described_class.create(name: 'navigation', display_name: 'Navigation') }

    it 'finds system by exact name' do
      expect(described_class.find_by_name('navigation')).to eq(system)
    end

    it 'finds system case-insensitively' do
      expect(described_class.find_by_name('NAVIGATION')).to eq(system)
      expect(described_class.find_by_name('Navigation')).to eq(system)
    end

    it 'returns nil for non-existent name' do
      expect(described_class.find_by_name('nonexistent')).to be_nil
    end

    it 'returns nil for nil name' do
      expect(described_class.find_by_name(nil)).to be_nil
    end

    it 'returns nil for empty name' do
      expect(described_class.find_by_name('')).to be_nil
    end

    it 'returns nil for whitespace name' do
      expect(described_class.find_by_name('   ')).to be_nil
    end

    it 'strips whitespace from name' do
      expect(described_class.find_by_name('  navigation  ')).to eq(system)
    end
  end

  describe '.ordered' do
    before do
      described_class.where(true).delete
      described_class.create(name: 'zeta', display_order: 30)
      described_class.create(name: 'alpha', display_order: 10)
      described_class.create(name: 'beta', display_order: 20)
    end

    it 'returns systems ordered by display_order' do
      ordered = described_class.ordered
      expect(ordered.map(&:name)).to eq(%w[alpha beta zeta])
    end

    it 'orders by name as secondary sort' do
      described_class.create(name: 'gamma', display_order: 10)
      ordered = described_class.ordered
      expect(ordered.first(2).map(&:name)).to eq(%w[alpha gamma])
    end
  end

  describe '.seed_defaults!' do
    it 'creates systems from SYSTEM_DEFINITIONS' do
      count = described_class.seed_defaults!
      expect(count).to eq(described_class::SYSTEM_DEFINITIONS.length)
    end

    it 'updates existing systems instead of duplicating' do
      described_class.seed_defaults!
      initial_count = described_class.count
      described_class.seed_defaults!
      expect(described_class.count).to eq(initial_count)
    end
  end

  describe '#helpfiles' do
    let(:system) { described_class.create(name: 'test_system', command_names: %w[look walk]) }

    it 'returns empty array when command_names is nil' do
      system.update(command_names: nil)
      expect(system.helpfiles).to eq([])
    end

    it 'returns empty array when command_names is empty' do
      system.update(command_names: [])
      expect(system.helpfiles).to eq([])
    end

    it 'returns helpfiles matching command_names' do
      Helpfile.create(command_name: 'look', topic: 'look', plugin: 'navigation', summary: 'Look around')
      Helpfile.create(command_name: 'walk', topic: 'walk', plugin: 'navigation', summary: 'Walk somewhere')
      helpfiles = system.helpfiles
      expect(helpfiles.map(&:command_name)).to match_array(%w[look walk])
    end
  end

  describe '#related' do
    let!(:combat_system) { described_class.create(name: 'combat') }
    let!(:navigation_system) { described_class.create(name: 'navigation', related_systems: ['combat']) }

    it 'returns related HelpSystem objects' do
      expect(navigation_system.related).to include(combat_system)
    end

    it 'returns empty array when related_systems is nil' do
      navigation_system.update(related_systems: nil)
      expect(navigation_system.related).to eq([])
    end

    it 'returns empty array when related_systems is empty' do
      navigation_system.update(related_systems: [])
      expect(navigation_system.related).to eq([])
    end
  end

  describe '#to_player_display' do
    let(:system) do
      described_class.create(
        name: 'test',
        display_name: 'Test System',
        summary: 'A test system',
        description: 'Detailed description',
        command_names: %w[cmd1 cmd2],
        related_systems: %w[other]
      )
    end

    it 'includes display name in header' do
      expect(system.to_player_display).to include('Test System')
    end

    it 'includes summary' do
      expect(system.to_player_display).to include('A test system')
    end

    it 'includes description' do
      expect(system.to_player_display).to include('Detailed description')
    end

    it 'includes Commands section' do
      expect(system.to_player_display).to include('Commands:')
    end

    it 'includes related systems' do
      expect(system.to_player_display).to include('Related: other')
    end

    it 'uses capitalized name when display_name is nil' do
      system.update(display_name: nil)
      expect(system.to_player_display).to include('Test')
    end
  end

  describe '#to_staff_display' do
    let(:system) do
      described_class.create(
        name: 'test',
        staff_notes: 'Staff-only notes',
        key_files: ['app/services/test.rb']
      )
    end

    it 'includes player display content' do
      allow(system).to receive(:to_player_display).and_return('Player content')
      expect(system.to_staff_display).to include('Player content')
    end

    it 'includes staff notes section' do
      expect(system.to_staff_display).to include('Staff Information')
      expect(system.to_staff_display).to include('Staff-only notes')
    end

    it 'includes key files section' do
      expect(system.to_staff_display).to include('Key Files:')
      expect(system.to_staff_display).to include('app/services/test.rb')
    end
  end

  describe '#to_agent_format' do
    let(:system) do
      described_class.create(
        name: 'test',
        display_name: 'Test System',
        summary: 'Summary',
        description: 'Description',
        player_guide: 'Guide',
        quick_reference: 'Quick ref',
        command_names: ['cmd'],
        related_systems: ['other'],
        staff_notes: 'Notes',
        staff_guide: 'Staff guide',
        key_files: ['file.rb'],
        constants_json: { 'MAX' => 100 }
      )
    end

    it 'returns hash with all fields' do
      format = system.to_agent_format
      expect(format[:name]).to eq('test')
      expect(format[:display_name]).to eq('Test System')
      expect(format[:summary]).to eq('Summary')
      expect(format[:description]).to eq('Description')
      expect(format[:player_guide]).to eq('Guide')
      expect(format[:quick_reference]).to eq('Quick ref')
      expect(format[:command_names]).to eq(['cmd'])
      expect(format[:related_systems]).to eq(['other'])
      expect(format[:staff_notes]).to eq('Notes')
      expect(format[:staff_guide]).to eq('Staff guide')
      expect(format[:key_files]).to eq(['file.rb'])
      expect(format[:constants]).to eq({ 'MAX' => 100 })
    end

    it 'returns empty arrays for nil array fields' do
      system.update(command_names: nil, related_systems: nil, key_files: nil)
      format = system.to_agent_format
      expect(format[:command_names]).to eq([])
      expect(format[:related_systems]).to eq([])
      expect(format[:key_files]).to eq([])
    end
  end

  describe '#player_guide_html' do
    it 'returns nil when player_guide is nil' do
      system = described_class.new
      system.values[:player_guide] = nil
      expect(system.player_guide_html).to be_nil
    end

    it 'returns nil when player_guide is empty' do
      system = described_class.new
      system.values[:player_guide] = '   '
      expect(system.player_guide_html).to be_nil
    end

    it 'renders markdown when player_guide is present' do
      system = described_class.new
      system.values[:player_guide] = '# Test Guide'
      expect(system.player_guide_html).to include('<h1')
    end

    it 'renders GFM markdown' do
      system = described_class.new
      system.values[:player_guide] = "```ruby\nputs 'hello'\n```"
      html = system.player_guide_html
      expect(html).to include('code')
    end
  end

  describe '#staff_guide_html' do
    it 'returns nil when staff_guide is nil' do
      system = described_class.new
      system.values[:staff_guide] = nil
      expect(system.staff_guide_html).to be_nil
    end

    it 'returns nil when staff_guide is empty' do
      system = described_class.new
      system.values[:staff_guide] = '   '
      expect(system.staff_guide_html).to be_nil
    end

    it 'renders markdown when staff_guide is present' do
      system = described_class.new
      system.values[:staff_guide] = '# Staff Guide'
      expect(system.staff_guide_html).to include('<h1')
    end
  end

  describe '#quick_reference_html' do
    it 'returns nil when quick_reference is nil' do
      system = described_class.new
      system.values[:quick_reference] = nil
      expect(system.quick_reference_html).to be_nil
    end

    it 'returns nil when quick_reference is empty' do
      system = described_class.new
      system.values[:quick_reference] = '   '
      expect(system.quick_reference_html).to be_nil
    end

    it 'renders markdown when quick_reference is present' do
      system = described_class.new
      system.values[:quick_reference] = '| Command | Description |'
      expect(system.quick_reference_html).to be_a(String)
    end
  end

  describe '#parsed_constants' do
    it 'returns empty hash when constants_json is nil' do
      system = described_class.new
      system.values[:constants_json] = nil
      expect(system.parsed_constants).to eq({})
    end

    it 'returns hash when constants_json is a hash' do
      system = described_class.new
      system.values[:constants_json] = { 'key' => 'value' }
      expect(system.parsed_constants).to eq({ 'key' => 'value' })
    end

    it 'parses JSON string to hash' do
      system = described_class.new
      system.values[:constants_json] = '{"key": "value"}'
      expect(system.parsed_constants).to eq({ 'key' => 'value' })
    end

    it 'returns empty hash for invalid JSON string' do
      system = described_class.new
      system.values[:constants_json] = 'invalid json'
      expect(system.parsed_constants).to eq({})
    end
  end

  describe '#has_player_guide?' do
    it 'returns false when player_guide is nil' do
      system = described_class.new
      system.values[:player_guide] = nil
      expect(system.has_player_guide?).to be false
    end

    it 'returns false when player_guide is empty' do
      system = described_class.new
      system.values[:player_guide] = '   '
      expect(system.has_player_guide?).to be false
    end

    it 'returns true when player_guide has content' do
      system = described_class.new
      system.values[:player_guide] = '# Guide'
      expect(system.has_player_guide?).to be true
    end
  end

  describe '#has_staff_guide?' do
    it 'returns false when staff_guide is nil' do
      system = described_class.new
      system.values[:staff_guide] = nil
      expect(system.has_staff_guide?).to be false
    end

    it 'returns false when staff_guide is empty' do
      system = described_class.new
      system.values[:staff_guide] = '   '
      expect(system.has_staff_guide?).to be false
    end

    it 'returns true when staff_guide has content' do
      system = described_class.new
      system.values[:staff_guide] = '# Staff Guide'
      expect(system.has_staff_guide?).to be true
    end
  end

  describe 'SYSTEM_DEFINITIONS content' do
    it 'includes local movement system' do
      nav_system = described_class::SYSTEM_DEFINITIONS.find { |s| s[:name] == 'local_movement' }
      expect(nav_system).not_to be_nil
      expect(nav_system[:display_name]).to eq('Within-Location Movement')
    end

    it 'includes combat system' do
      combat_system = described_class::SYSTEM_DEFINITIONS.find { |s| s[:name] == 'combat' }
      expect(combat_system).not_to be_nil
    end

    it 'includes communication system' do
      comm_system = described_class::SYSTEM_DEFINITIONS.find { |s| s[:name] == 'communication' }
      expect(comm_system).not_to be_nil
    end

    it 'each definition has required fields' do
      described_class::SYSTEM_DEFINITIONS.each do |definition|
        expect(definition).to have_key(:name)
        expect(definition).to have_key(:display_name)
        expect(definition).to have_key(:summary)
      end
    end
  end
end
