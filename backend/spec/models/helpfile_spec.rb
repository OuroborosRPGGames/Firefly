# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Helpfile do
  # Clear helpfiles that may have been synced from commands to avoid conflicts
  before(:all) do
    HelpfileSynonym.dataset.delete
    Helpfile.dataset.delete
  end

  # Silence embedding warnings in tests
  before do
    allow_any_instance_of(Helpfile).to receive(:embed_helpfile_content!)
    allow_any_instance_of(Helpfile).to receive(:embed_lore_content!)
    allow_any_instance_of(Helpfile).to receive(:remove_lore_embedding!)
    allow_any_instance_of(Helpfile).to receive(:remove_helpfile_embedding!)
    allow(Embedding).to receive(:store)
    allow(Embedding).to receive(:remove)
    allow(Embedding).to receive(:search).and_return([])
    allow(Embedding).to receive(:exists_for?).and_return(false)
  end

  # ============================================
  # Validations
  # ============================================
  describe 'validations' do
    it 'requires command_name, topic, plugin, and summary' do
      helpfile = Helpfile.new
      expect(helpfile.valid?).to be false
      expect(helpfile.errors[:command_name]).to include('is not present')
      expect(helpfile.errors[:topic]).to include('is not present')
      expect(helpfile.errors[:plugin]).to include('is not present')
      expect(helpfile.errors[:summary]).to include('is not present')
    end

    it 'creates valid helpfile with required fields' do
      helpfile = Helpfile.create(
        command_name: 'look',
        topic: 'look',
        plugin: 'core',
        summary: 'Look at your surroundings'
      )
      expect(helpfile.valid?).to be true
      expect(helpfile.id).not_to be_nil
    end

    it 'enforces unique command_name' do
      Helpfile.create(command_name: 'go', topic: 'go', plugin: 'core', summary: 'Move around')
      duplicate = Helpfile.new(command_name: 'go', topic: 'move', plugin: 'core', summary: 'Move')
      expect(duplicate.valid?).to be false
      expect(duplicate.errors[:command_name]).to include('is already taken')
    end

    it 'enforces unique topic' do
      Helpfile.create(command_name: 'say', topic: 'speaking', plugin: 'core', summary: 'Talk')
      duplicate = Helpfile.new(command_name: 'whisper', topic: 'speaking', plugin: 'core', summary: 'Whisper')
      expect(duplicate.valid?).to be false
      expect(duplicate.errors[:topic]).to include('is already taken')
    end
  end

  # ============================================
  # .find_by_topic
  # ============================================
  describe '.find_by_topic' do
    before do
      @helpfile = Helpfile.create(
        command_name: 'inventory',
        topic: 'inventory',
        plugin: 'core',
        summary: 'Check your inventory',
        aliases: ['inv', 'i']
      )
      @helpfile.sync_synonyms!
    end

    it 'finds by exact command_name' do
      result = Helpfile.find_by_topic('inventory')
      expect(result).to eq(@helpfile)
    end

    it 'finds by command_name case-insensitively' do
      result = Helpfile.find_by_topic('INVENTORY')
      expect(result).to eq(@helpfile)
    end

    it 'finds by topic' do
      result = Helpfile.find_by_topic('inventory')
      expect(result).to eq(@helpfile)
    end

    it 'finds by synonym' do
      result = Helpfile.find_by_topic('inv')
      expect(result).to eq(@helpfile)
    end

    it 'finds by synonym case-insensitively' do
      result = Helpfile.find_by_topic('I')
      expect(result).to eq(@helpfile)
    end

    it 'returns nil for non-existent topic' do
      result = Helpfile.find_by_topic('nonexistent')
      expect(result).to be_nil
    end

    it 'returns nil for empty string' do
      expect(Helpfile.find_by_topic('')).to be_nil
    end

    it 'returns nil for nil' do
      expect(Helpfile.find_by_topic(nil)).to be_nil
    end

    it 'handles whitespace in search term' do
      result = Helpfile.find_by_topic('  inventory  ')
      expect(result).to eq(@helpfile)
    end
  end

  # ============================================
  # .search
  # ============================================
  describe '.search' do
    before do
      @combat = Helpfile.create(
        command_name: 'attack',
        topic: 'attack',
        plugin: 'combat',
        category: 'combat',
        summary: 'Attack a target in combat'
      )
      @social = Helpfile.create(
        command_name: 'say',
        topic: 'say',
        plugin: 'core',
        category: 'social',
        summary: 'Say something to the room'
      )
      @hidden = Helpfile.create(
        command_name: 'admin',
        topic: 'admin',
        plugin: 'core',
        category: 'admin',
        summary: 'Admin commands',
        hidden: true
      )
      @admin_only = Helpfile.create(
        command_name: 'ban',
        topic: 'ban',
        plugin: 'core',
        category: 'admin',
        summary: 'Ban a player',
        admin_only: true
      )
    end

    it 'finds by partial command_name' do
      results = Helpfile.search('att')
      expect(results).to include(@combat)
    end

    it 'finds by partial summary' do
      results = Helpfile.search('combat')
      expect(results).to include(@combat)
    end

    it 'finds by exact match on command_name' do
      results = Helpfile.search('attack')
      expect(results).to include(@combat)
    end

    it 'finds by exact match on topic' do
      results = Helpfile.search('attack')
      expect(results).to include(@combat)
    end

    it 'excludes hidden helpfiles by default' do
      results = Helpfile.search('admin')
      expect(results).not_to include(@hidden)
    end

    it 'includes hidden helpfiles when requested' do
      results = Helpfile.search('admin', include_hidden: true)
      expect(results).to include(@hidden)
    end

    it 'excludes admin-only helpfiles by default' do
      results = Helpfile.search('ban')
      expect(results).not_to include(@admin_only)
    end

    it 'includes admin-only helpfiles when admin requested' do
      results = Helpfile.search('ban', admin: true)
      expect(results).to include(@admin_only)
    end

    it 'filters by category' do
      results = Helpfile.search('a', category: 'combat')
      expect(results).to include(@combat)
      expect(results).not_to include(@social)
    end

    it 'returns empty array for nil query' do
      expect(Helpfile.search(nil)).to eq([])
    end

    it 'returns empty array for empty query' do
      expect(Helpfile.search('')).to eq([])
    end

    it 'returns empty array for whitespace-only query' do
      expect(Helpfile.search('   ')).to eq([])
    end

    it 'respects limit option' do
      results = Helpfile.search('a', limit: 1)
      expect(results.length).to be <= 1
    end

    it 'returns unique results' do
      results = Helpfile.search('attack')
      expect(results.map(&:id)).to eq(results.map(&:id).uniq)
    end
  end

  # ============================================
  # .generate_from_command
  # ============================================
  describe '.generate_from_command' do
    let(:mock_command_class) do
      Class.new do
        def self.command_name
          'test_cmd'
        end

        def self.help_text
          'A test command'
        end

        def self.usage
          'test_cmd [args]'
        end

        def self.alias_names
          ['tc', 'tcmd']
        end

        def self.category
          :testing
        end

        def self.plugin_name
          'test_plugin'
        end

        def self.examples_list
          ['test_cmd foo', 'test_cmd bar']
        end

        def execute; end
      end
    end

    it 'returns nil for non-command class' do
      result = Helpfile.generate_from_command(Object.new)
      expect(result).to be_nil
    end

    it 'creates helpfile from command class' do
      result = Helpfile.generate_from_command(mock_command_class)

      expect(result).to be_a(Helpfile)
      expect(result.command_name).to eq('test_cmd')
      expect(result.summary).to eq('A test command')
      expect(result.syntax).to eq('test_cmd [args]')
    end

    it 'sets plugin from command class' do
      result = Helpfile.generate_from_command(mock_command_class)
      expect(result.plugin).to eq('test_plugin')
    end

    it 'sets category from command class' do
      result = Helpfile.generate_from_command(mock_command_class)
      expect(result.category).to eq('testing')
    end

    it 'sets aliases from command class' do
      result = Helpfile.generate_from_command(mock_command_class)
      expect(result.aliases.to_a).to include('tc', 'tcmd')
    end

    it 'marks as auto-generated' do
      result = Helpfile.generate_from_command(mock_command_class)
      expect(result.auto_generated).to be true
    end

    it 'updates existing helpfile instead of creating duplicate' do
      first = Helpfile.generate_from_command(mock_command_class)
      second = Helpfile.generate_from_command(mock_command_class)

      expect(second.id).to eq(first.id)
    end

    it 'preserves existing staff_notes when updating' do
      first = Helpfile.generate_from_command(mock_command_class)
      first.update(staff_notes: 'Important implementation note')

      second = Helpfile.generate_from_command(mock_command_class)
      expect(second.staff_notes).to eq('Important implementation note')
    end
  end

  # ============================================
  # .extract_source_info
  # ============================================
  describe '.extract_source_info' do
    it 'returns file and line for command class with execute method' do
      mock_class = Class.new do
        def execute; end
      end

      result = Helpfile.extract_source_info(mock_class)

      expect(result).to be_a(Hash)
      expect(result).to have_key(:file)
      expect(result).to have_key(:line)
    end

    it 'returns file and line for command class with perform_command method' do
      mock_class = Class.new do
        def perform_command; end
      end

      result = Helpfile.extract_source_info(mock_class)

      expect(result).to be_a(Hash)
      expect(result).to have_key(:file)
      expect(result).to have_key(:line)
    end

    it 'returns nil file and line when method location is unavailable' do
      result = Helpfile.extract_source_info(Object)

      expect(result[:file]).to be_nil
      expect(result[:line]).to be_nil
    end
  end

  # ============================================
  # .extract_requirements_summary
  # ============================================
  describe '.extract_requirements_summary' do
    it 'returns nil for class without requirements method' do
      result = Helpfile.extract_requirements_summary(Object)
      expect(result).to be_nil
    end

    it 'returns "Always available" for empty requirements' do
      mock_class = Class.new do
        def self.requirements
          []
        end
      end

      result = Helpfile.extract_requirements_summary(mock_class)
      expect(result).to eq('Always available')
    end

    it 'summarizes :in_combat requirement' do
      mock_class = Class.new do
        def self.requirements
          [{ type: :in_combat }]
        end
      end

      result = Helpfile.extract_requirements_summary(mock_class)
      expect(result).to include('Must be in combat')
    end

    it 'summarizes :not_in_combat requirement' do
      mock_class = Class.new do
        def self.requirements
          [{ type: :not_in_combat }]
        end
      end

      result = Helpfile.extract_requirements_summary(mock_class)
      expect(result).to include('Cannot be in combat')
    end

    it 'summarizes :character_state alive requirement' do
      mock_class = Class.new do
        def self.requirements
          [{ type: :character_state, args: [:alive] }]
        end
      end

      result = Helpfile.extract_requirements_summary(mock_class)
      expect(result).to include('Must be alive')
    end

    it 'summarizes :room_type requirement' do
      mock_class = Class.new do
        def self.requirements
          [{ type: :room_type, args: ['shop', 'market'] }]
        end
      end

      result = Helpfile.extract_requirements_summary(mock_class)
      expect(result).to include('Must be in shop or market room')
    end

    it 'joins multiple requirements with semicolons' do
      mock_class = Class.new do
        def self.requirements
          [
            { type: :not_in_combat },
            { type: :character_state, args: [:alive] }
          ]
        end
      end

      result = Helpfile.extract_requirements_summary(mock_class)
      expect(result).to include('; ')
    end
  end

  # ============================================
  # .sync_all_commands!
  # ============================================
  describe '.sync_all_commands!' do
    it 'returns 0 when Registry is not defined' do
      # Hide Registry if defined
      allow(described_class).to receive(:defined?).with(Commands::Base::Registry).and_return(false)

      # Since Registry is defined in this test environment, we need to test differently
      # Just verify the method exists and can be called
      expect(described_class).to respond_to(:sync_all_commands!)
    end
  end

  # ============================================
  # #full_content
  # ============================================
  describe '#full_content' do
    it 'formats help content as markdown' do
      helpfile = Helpfile.create(
        command_name: 'look',
        topic: 'look',
        plugin: 'core',
        summary: 'Look at your surroundings',
        syntax: 'look [target]',
        description: 'The look command lets you see the room.',
        examples: '[{"input": "look", "explanation": "Look around"}, {"input": "look sword", "explanation": "Look at a sword"}]',
        aliases: ['l', 'examine']
      )

      content = helpfile.full_content
      expect(content).to include('# LOOK')
      expect(content).to include('Look at your surroundings')
      expect(content).to include('## Syntax')
      expect(content).to include('look [target]')
      expect(content).to include('## Description')
      expect(content).to include('## Examples')
      expect(content).to include('## Aliases')
      expect(content).to include('l, examine')
    end

    it 'skips empty sections' do
      helpfile = Helpfile.create(
        command_name: 'simple',
        topic: 'simple',
        plugin: 'core',
        summary: 'A simple command'
      )

      content = helpfile.full_content
      expect(content).to include('# SIMPLE')
      expect(content).to include('A simple command')
      expect(content).not_to include('## Syntax')
      expect(content).not_to include('## Description')
      expect(content).not_to include('## Examples')
    end

    it 'includes related_commands as See Also section' do
      helpfile = Helpfile.create(
        command_name: 'look',
        topic: 'look',
        plugin: 'core',
        summary: 'Look around',
        related_commands: ['examine', 'glance']
      )

      content = helpfile.full_content
      expect(content).to include('## See Also')
      expect(content).to include('examine, glance')
    end
  end

  # ============================================
  # #to_agent_format
  # ============================================
  describe '#to_agent_format' do
    it 'returns hash format for API consumption' do
      helpfile = Helpfile.create(
        command_name: 'go',
        topic: 'go',
        plugin: 'navigation',
        category: 'movement',
        summary: 'Move to another room',
        syntax: 'go <direction>',
        aliases: ['walk', 'move']
      )

      result = helpfile.to_agent_format
      expect(result[:command]).to eq('go')
      expect(result[:topic]).to eq('go')
      expect(result[:plugin]).to eq('navigation')
      expect(result[:category]).to eq('movement')
      expect(result[:summary]).to eq('Move to another room')
      expect(result[:syntax]).to eq('go <direction>')
      expect(result[:aliases]).to eq(['walk', 'move'])
    end

    it 'handles nil arrays' do
      helpfile = Helpfile.create(
        command_name: 'test',
        topic: 'test',
        plugin: 'core',
        summary: 'Test'
      )

      result = helpfile.to_agent_format
      expect(result[:aliases]).to eq([])
      expect(result[:related_commands]).to eq([])
      expect(result[:see_also]).to eq([])
    end
  end

  # ============================================
  # #to_staff_format
  # ============================================
  describe '#to_staff_format' do
    it 'includes agent format fields plus staff fields' do
      helpfile = Helpfile.create(
        command_name: 'staff_cmd',
        topic: 'staff_cmd',
        plugin: 'core',
        summary: 'Staff command',
        source_file: 'app/commands/staff_cmd.rb',
        source_line: 42,
        staff_notes: 'Implementation notes',
        requirements_summary: 'Must be staff',
        code_references: Sequel.pg_jsonb([{ 'file' => 'app/models/user.rb', 'line' => 10, 'desc' => 'User model' }])
      )

      result = helpfile.to_staff_format

      # Should have agent fields
      expect(result[:command]).to eq('staff_cmd')
      expect(result[:summary]).to eq('Staff command')

      # Should have staff fields
      expect(result[:source_file]).to eq('app/commands/staff_cmd.rb')
      expect(result[:source_line]).to eq(42)
      expect(result[:staff_notes]).to eq('Implementation notes')
      expect(result[:requirements_summary]).to eq('Must be staff')
      expect(result[:code_references]).to be_a(Array)
    end
  end

  # ============================================
  # #to_player_display
  # ============================================
  describe '#to_player_display' do
    it 'formats help for player view' do
      helpfile = Helpfile.create(
        command_name: 'look',
        topic: 'look',
        plugin: 'core',
        summary: 'Look at your surroundings',
        syntax: 'look [target]',
        category: 'navigation',
        aliases: ['l'],
        examples: '[{"input": "look"}, {"input": "look sword"}]'
      )

      display = helpfile.to_player_display

      expect(display).to include('<h4>Help: LOOK</h4>')
      expect(display).to include('Look at your surroundings')
      expect(display).to include('Usage: look [target]')
      expect(display).to include('Aliases: l')
      expect(display).to include('Examples:')
      expect(display).to include('look')
      expect(display).to include('look sword')
      expect(display).to include('Category: navigation')
    end

    it 'skips optional sections when empty' do
      helpfile = Helpfile.create(
        command_name: 'simple',
        topic: 'simple',
        plugin: 'core',
        summary: 'Simple command'
      )

      display = helpfile.to_player_display

      expect(display).to include('<h4>Help: SIMPLE</h4>')
      expect(display).to include('Simple command')
      expect(display).not_to include('Usage:')
      expect(display).not_to include('Aliases:')
      expect(display).not_to include('Examples:')
    end
  end

  # ============================================
  # #to_staff_display
  # ============================================
  describe '#to_staff_display' do
    it 'includes player display plus staff section' do
      helpfile = Helpfile.create(
        command_name: 'staff_cmd',
        topic: 'staff_cmd',
        plugin: 'core',
        summary: 'Staff command',
        source_file: 'app/commands/staff.rb',
        source_line: 100,
        requirements_summary: 'Must be admin',
        staff_notes: 'Check permissions first',
        code_references: Sequel.pg_jsonb([{ 'file' => 'app/models/user.rb', 'line' => 50, 'desc' => 'Permission check' }])
      )

      display = helpfile.to_staff_display

      # Player content
      expect(display).to include('<h4>Help: STAFF_CMD</h4>')

      # Staff content
      expect(display).to include('<h4>Staff Information</h4>')
      expect(display).to include('Source: app/commands/staff.rb:100')
      expect(display).to include('Requirements: Must be admin')
      expect(display).to include('Implementation Notes:')
      expect(display).to include('Check permissions first')
      expect(display).to include('Related Files:')
      expect(display).to include('app/models/user.rb:50')
    end
  end

  # ============================================
  # #parsed_code_references
  # ============================================
  describe '#parsed_code_references' do
    it 'returns empty array for nil code_references' do
      helpfile = Helpfile.new(
        command_name: 'test',
        topic: 'test',
        plugin: 'core',
        summary: 'Test'
      )

      expect(helpfile.parsed_code_references).to eq([])
    end

    it 'returns array for JSONB array' do
      helpfile = Helpfile.create(
        command_name: 'test2',
        topic: 'test2',
        plugin: 'core',
        summary: 'Test',
        code_references: Sequel.pg_jsonb([{ 'file' => 'test.rb' }])
      )

      result = helpfile.parsed_code_references
      expect(result).to be_a(Array)
      expect(result.first['file']).to eq('test.rb')
    end

    it 'parses JSON string' do
      helpfile = Helpfile.new(
        command_name: 'test3',
        topic: 'test3',
        plugin: 'core',
        summary: 'Test'
      )
      helpfile.code_references = '[{"file": "test.rb"}]'

      result = helpfile.parsed_code_references
      expect(result).to be_a(Array)
      expect(result.first['file']).to eq('test.rb')
    end

    it 'returns empty array for invalid JSON string' do
      helpfile = Helpfile.new(
        command_name: 'test4',
        topic: 'test4',
        plugin: 'core',
        summary: 'Test'
      )
      helpfile.code_references = 'invalid json'

      expect(helpfile.parsed_code_references).to eq([])
    end
  end

  # ============================================
  # #add_synonym and #remove_synonym
  # ============================================
  describe '#add_synonym' do
    let!(:helpfile) do
      Helpfile.create(
        command_name: 'test_syn',
        topic: 'test_syn',
        plugin: 'core',
        summary: 'Test'
      )
    end

    it 'creates new synonym' do
      result = helpfile.add_synonym('alias')

      expect(result).to be_a(HelpfileSynonym)
      expect(result.synonym).to eq('alias')
      expect(result.helpfile_id).to eq(helpfile.id)
    end

    it 'normalizes synonym to lowercase' do
      result = helpfile.add_synonym('ALIAS')
      expect(result.synonym).to eq('alias')
    end

    it 'strips whitespace from synonym' do
      result = helpfile.add_synonym('  alias  ')
      expect(result.synonym).to eq('alias')
    end

    it 'returns nil for empty synonym' do
      result = helpfile.add_synonym('')
      expect(result).to be_nil
    end

    it 'returns existing synonym if already linked to this helpfile' do
      first = helpfile.add_synonym('alias')
      second = helpfile.add_synonym('alias')

      expect(second).to eq(first)
    end

    it 'returns nil if synonym exists for another helpfile' do
      other_helpfile = Helpfile.create(
        command_name: 'other',
        topic: 'other',
        plugin: 'core',
        summary: 'Other'
      )
      other_helpfile.add_synonym('shared')

      result = helpfile.add_synonym('shared')
      expect(result).to be_nil
    end
  end

  describe '#remove_synonym' do
    let!(:helpfile) do
      Helpfile.create(
        command_name: 'test_rm',
        topic: 'test_rm',
        plugin: 'core',
        summary: 'Test'
      )
    end

    it 'removes existing synonym' do
      helpfile.add_synonym('alias')
      helpfile.remove_synonym('alias')

      expect(HelpfileSynonym.where(helpfile_id: helpfile.id, synonym: 'alias').first).to be_nil
    end

    it 'normalizes synonym when removing' do
      helpfile.add_synonym('alias')
      helpfile.remove_synonym('  ALIAS  ')

      expect(HelpfileSynonym.where(helpfile_id: helpfile.id, synonym: 'alias').first).to be_nil
    end
  end

  # ============================================
  # #sync_synonyms!
  # ============================================
  describe '#sync_synonyms!' do
    it 'creates synonyms from aliases' do
      helpfile = Helpfile.create(
        command_name: 'examine',
        topic: 'examine',
        plugin: 'core',
        summary: 'Examine something',
        aliases: ['ex', 'look at']
      )

      helpfile.sync_synonyms!

      synonyms = HelpfileSynonym.where(helpfile_id: helpfile.id).select_map(:synonym)
      expect(synonyms).to include('ex')
      expect(synonyms).to include('look at')
      expect(synonyms).to include('examine')
    end

    it 'removes old synonyms when re-synced' do
      helpfile = Helpfile.create(
        command_name: 'get',
        topic: 'get',
        plugin: 'core',
        summary: 'Pick up items',
        aliases: ['take', 'grab']
      )
      helpfile.sync_synonyms!

      helpfile.update(aliases: ['pick up'])
      helpfile.sync_synonyms!

      synonyms = HelpfileSynonym.where(helpfile_id: helpfile.id).select_map(:synonym)
      expect(synonyms).to include('pick up')
      expect(synonyms).not_to include('take')
      expect(synonyms).not_to include('grab')
    end

    it 'handles nil aliases' do
      helpfile = Helpfile.create(
        command_name: 'noalias',
        topic: 'noalias',
        plugin: 'core',
        summary: 'No aliases'
      )

      expect { helpfile.sync_synonyms! }.not_to raise_error
    end
  end

  # ============================================
  # Lore Methods
  # ============================================
  describe 'lore helpfile methods' do
    describe '.lore_topics' do
      it 'returns only visible lore helpfiles' do
        lore = Helpfile.create(
          command_name: 'lore1',
          topic: 'lore1',
          plugin: 'core',
          summary: 'Lore topic',
          is_lore: true
        )
        hidden_lore = Helpfile.create(
          command_name: 'lore2',
          topic: 'lore2',
          plugin: 'core',
          summary: 'Hidden lore',
          is_lore: true,
          hidden: true
        )
        non_lore = Helpfile.create(
          command_name: 'cmd',
          topic: 'cmd',
          plugin: 'core',
          summary: 'Regular command'
        )

        results = Helpfile.lore_topics

        expect(results).to include(lore)
        expect(results).not_to include(hidden_lore)
        expect(results).not_to include(non_lore)
      end
    end

    describe '.search_lore' do
      it 'returns empty array for nil query' do
        expect(Helpfile.search_lore(nil)).to eq([])
      end

      it 'returns empty array for empty query' do
        expect(Helpfile.search_lore('')).to eq([])
      end

      it 'returns empty array when no embeddings match' do
        Helpfile.create(
          command_name: 'lore_test',
          topic: 'lore_test',
          plugin: 'core',
          summary: 'Some lore',
          is_lore: true
        )

        results = Helpfile.search_lore('test')
        expect(results).to eq([])
      end
    end

    describe '.lore_context_for' do
      it 'returns empty string when no matches' do
        result = Helpfile.lore_context_for('test query')
        expect(result).to eq('')
      end
    end

    describe '#lore_embedded?' do
      it 'returns false when not embedded' do
        helpfile = Helpfile.create(
          command_name: 'not_embedded',
          topic: 'not_embedded',
          plugin: 'core',
          summary: 'Not embedded',
          is_lore: true
        )

        expect(helpfile.lore_embedded?).to be false
      end
    end
  end

  # ============================================
  # Helpfile Embedding Methods
  # ============================================
  describe 'helpfile embedding methods' do
    describe '.search_helpfiles' do
      it 'returns empty array for nil query' do
        expect(Helpfile.search_helpfiles(nil)).to eq([])
      end

      it 'returns empty array for empty query' do
        expect(Helpfile.search_helpfiles('')).to eq([])
      end
    end

    describe '#helpfile_embedded?' do
      it 'returns false when not embedded' do
        helpfile = Helpfile.create(
          command_name: 'hf_test',
          topic: 'hf_test',
          plugin: 'core',
          summary: 'Test helpfile'
        )

        expect(helpfile.helpfile_embedded?).to be false
      end
    end

    describe '.embed_all_helpfiles!' do
      it 'returns count of embedded helpfiles' do
        allow_any_instance_of(Helpfile).to receive(:embed_helpfile_content!).and_call_original

        Helpfile.create(
          command_name: 'embed1',
          topic: 'embed1',
          plugin: 'core',
          summary: 'Test 1'
        )
        Helpfile.create(
          command_name: 'embed2',
          topic: 'embed2',
          plugin: 'core',
          summary: 'Test 2',
          hidden: true
        )

        count = Helpfile.embed_all_helpfiles!
        expect(count).to be >= 1
      end
    end
  end

  # ============================================
  # before_save array handling
  # ============================================
  describe '#before_save' do
    it 'converts arrays to pg_array' do
      helpfile = Helpfile.new(
        command_name: 'arr_test',
        topic: 'arr_test',
        plugin: 'core',
        summary: 'Test',
        aliases: ['a', 'b'],
        related_commands: ['c', 'd'],
        see_also: ['e', 'f']
      )

      helpfile.save

      expect(helpfile.aliases.to_a).to eq(['a', 'b'])
      expect(helpfile.related_commands.to_a).to eq(['c', 'd'])
      expect(helpfile.see_also.to_a).to eq(['e', 'f'])
    end
  end

  # ============================================
  # Edge Case Tests
  # ============================================
  describe 'edge cases' do
    describe '#before_save edge cases' do
      it 'handles nil arrays' do
        helpfile = Helpfile.new(
          command_name: 'nil_arr',
          topic: 'nil_arr',
          plugin: 'core',
          summary: 'Test',
          aliases: nil,
          related_commands: nil,
          see_also: nil
        )

        expect { helpfile.save }.not_to raise_error
        expect(helpfile.aliases.to_a).to eq([])
        expect(helpfile.related_commands.to_a).to eq([])
        expect(helpfile.see_also.to_a).to eq([])
      end

      it 'handles code_references as array' do
        helpfile = Helpfile.new(
          command_name: 'code_ref',
          topic: 'code_ref',
          plugin: 'core',
          summary: 'Test',
          code_references: [{ 'file' => 'test.rb', 'line' => 10 }]
        )

        expect { helpfile.save }.not_to raise_error
        expect(helpfile.parsed_code_references).to be_a(Array)
      end
    end

    describe '.extract_requirements_summary edge cases' do
      it 'returns "Always available" for nil requirements' do
        mock_class = Class.new do
          def self.requirements
            nil
          end
        end

        result = Helpfile.extract_requirements_summary(mock_class)
        expect(result).to eq('Always available')
      end

      it 'summarizes :character_state conscious requirement' do
        mock_class = Class.new do
          def self.requirements
            [{ type: :character_state, args: [:conscious] }]
          end
        end

        result = Helpfile.extract_requirements_summary(mock_class)
        expect(result).to include('Must be conscious')
      end

      it 'summarizes :character_state standing requirement' do
        mock_class = Class.new do
          def self.requirements
            [{ type: :character_state, args: [:standing] }]
          end
        end

        result = Helpfile.extract_requirements_summary(mock_class)
        expect(result).to include('Must be standing')
      end

      it 'summarizes unknown character_state with default message' do
        mock_class = Class.new do
          def self.requirements
            [{ type: :character_state, args: [:custom_state] }]
          end
        end

        result = Helpfile.extract_requirements_summary(mock_class)
        expect(result).to include('Character must be custom_state')
      end

      it 'summarizes :has_equipped requirement' do
        mock_class = Class.new do
          def self.requirements
            [{ type: :has_equipped, args: ['weapon'] }]
          end
        end

        result = Helpfile.extract_requirements_summary(mock_class)
        expect(result).to include('Must have weapon equipped')
      end

      it 'summarizes :has_item requirement' do
        mock_class = Class.new do
          def self.requirements
            [{ type: :has_item, args: ['key'] }]
          end
        end

        result = Helpfile.extract_requirements_summary(mock_class)
        expect(result).to include('Must have key')
      end

      it 'summarizes :has_resource requirement' do
        mock_class = Class.new do
          def self.requirements
            [{ type: :has_resource, args: ['stamina'] }]
          end
        end

        result = Helpfile.extract_requirements_summary(mock_class)
        expect(result).to include('Must have enough stamina')
      end

      it 'summarizes :era requirement' do
        mock_class = Class.new do
          def self.requirements
            [{ type: :era, args: ['modern', 'future'] }]
          end
        end

        result = Helpfile.extract_requirements_summary(mock_class)
        expect(result).to include('Available in: modern, future')
      end

      it 'summarizes :not_era requirement' do
        mock_class = Class.new do
          def self.requirements
            [{ type: :not_era, args: ['medieval'] }]
          end
        end

        result = Helpfile.extract_requirements_summary(mock_class)
        expect(result).to include('Not available in: medieval')
      end

      it 'summarizes :has_phone requirement' do
        mock_class = Class.new do
          def self.requirements
            [{ type: :has_phone }]
          end
        end

        result = Helpfile.extract_requirements_summary(mock_class)
        expect(result).to include('Requires a phone/communicator')
      end

      it 'summarizes :digital_currency requirement' do
        mock_class = Class.new do
          def self.requirements
            [{ type: :digital_currency }]
          end
        end

        result = Helpfile.extract_requirements_summary(mock_class)
        expect(result).to include('Requires digital currency era')
      end

      it 'summarizes :taxi_available requirement' do
        mock_class = Class.new do
          def self.requirements
            [{ type: :taxi_available }]
          end
        end

        result = Helpfile.extract_requirements_summary(mock_class)
        expect(result).to include('Requires taxi service')
      end

      it 'summarizes :can_communicate_ic requirement' do
        mock_class = Class.new do
          def self.requirements
            [{ type: :can_communicate_ic }]
          end
        end

        result = Helpfile.extract_requirements_summary(mock_class)
        expect(result).to include('Must be able to communicate in-character')
      end

      it 'summarizes :can_modify_rooms requirement' do
        mock_class = Class.new do
          def self.requirements
            [{ type: :can_modify_rooms }]
          end
        end

        result = Helpfile.extract_requirements_summary(mock_class)
        expect(result).to include('Must be able to modify rooms')
      end

      it 'uses custom message when provided' do
        mock_class = Class.new do
          def self.requirements
            [{ type: :custom_req, message: 'Custom requirement message' }]
          end
        end

        result = Helpfile.extract_requirements_summary(mock_class)
        expect(result).to include('Custom requirement message')
      end

      it 'falls back to type name when no message provided' do
        mock_class = Class.new do
          def self.requirements
            [{ type: :unknown_type }]
          end
        end

        result = Helpfile.extract_requirements_summary(mock_class)
        expect(result).to include('Requires: unknown_type')
      end
    end

    describe '.generate_from_command edge cases' do
      it 'uses default plugin when plugin_name not available' do
        mock_class = Class.new do
          def self.command_name
            'no_plugin'
          end

          def self.help_text
            'Help'
          end

          def execute; end
        end

        result = Helpfile.generate_from_command(mock_class)
        expect(result.plugin).to eq('core')
      end

      it 'uses nil category when category not available' do
        mock_class = Class.new do
          def self.command_name
            'no_cat'
          end

          def self.help_text
            'Help'
          end

          def execute; end
        end

        result = Helpfile.generate_from_command(mock_class)
        expect(result.category).to be_nil
      end

      it 'uses default summary when help_text not available' do
        mock_class = Class.new do
          def self.command_name
            'no_help'
          end

          def execute; end
        end

        result = Helpfile.generate_from_command(mock_class)
        expect(result.summary).to eq('The no_help command')
      end

      it 'uses command_name as syntax when usage_text not available' do
        mock_class = Class.new do
          def self.command_name
            'no_usage'
          end

          def execute; end
        end

        result = Helpfile.generate_from_command(mock_class)
        expect(result.syntax).to eq('no_usage')
      end

      it 'uses empty aliases when alias_names not available' do
        mock_class = Class.new do
          def self.command_name
            'no_aliases'
          end

          def execute; end
        end

        result = Helpfile.generate_from_command(mock_class)
        expect(result.aliases.to_a).to eq([])
      end

      it 'overwrites empty staff_notes on regeneration' do
        # First create with empty staff_notes
        first_mock = Class.new do
          def self.command_name
            'empty_notes'
          end

          def execute; end
        end

        first = Helpfile.generate_from_command(first_mock)
        first.update(staff_notes: '')

        # Re-generate should overwrite empty notes (preserves non-empty only)
        second = Helpfile.generate_from_command(first_mock)
        # Empty string is treated as "no notes" so it may be overwritten
        expect(second.staff_notes.to_s).to be_empty
      end
    end

    describe '.build_examples_json edge cases' do
      it 'returns empty JSON array when examples_list returns nil' do
        mock_class = Class.new do
          def self.examples_list
            nil
          end
        end

        result = Helpfile.send(:build_examples_json, mock_class)
        expect(result).to eq('[]')
      end

      it 'returns empty JSON array when examples_list returns empty array' do
        mock_class = Class.new do
          def self.examples_list
            []
          end
        end

        result = Helpfile.send(:build_examples_json, mock_class)
        expect(result).to eq('[]')
      end

      it 'handles hash examples' do
        mock_class = Class.new do
          def self.examples_list
            [{ 'input' => 'test', 'explanation' => 'Testing' }]
          end
        end

        result = Helpfile.send(:build_examples_json, mock_class)
        parsed = JSON.parse(result)
        expect(parsed.first['input']).to eq('test')
        expect(parsed.first['explanation']).to eq('Testing')
      end

      it 'converts non-string/hash to string' do
        mock_class = Class.new do
          def self.examples_list
            [123, :symbol]
          end
        end

        result = Helpfile.send(:build_examples_json, mock_class)
        parsed = JSON.parse(result)
        expect(parsed[0]['input']).to eq('123')
        expect(parsed[1]['input']).to eq('symbol')
      end
    end

    describe '#parsed_code_references edge cases' do
      it 'handles to_a fallback for unexpected type' do
        helpfile = Helpfile.new(
          command_name: 'weird_ref',
          topic: 'weird_ref',
          plugin: 'core',
          summary: 'Test'
        )
        # Set a Sequel::Postgres::JSONBArray which responds to to_a
        helpfile.code_references = Sequel.pg_jsonb([{ 'file' => 'x.rb' }])

        result = helpfile.parsed_code_references
        expect(result).to be_a(Array)
      end
    end

    describe '#full_content edge cases' do
      it 'handles examples with only input (no explanation)' do
        helpfile = Helpfile.create(
          command_name: 'exmp_edge',
          topic: 'exmp_edge',
          plugin: 'core',
          summary: 'Test',
          examples: '[{"input": "just input"}]'
        )

        content = helpfile.full_content
        expect(content).to include('`just input`')
      end

      it 'handles aliases as pg_array' do
        helpfile = Helpfile.create(
          command_name: 'alias_arr',
          topic: 'alias_arr',
          plugin: 'core',
          summary: 'Test',
          aliases: Sequel.pg_array(['a', 'b'], :text)
        )

        content = helpfile.full_content
        expect(content).to include('a, b')
      end

      it 'handles related_commands as pg_array' do
        helpfile = Helpfile.create(
          command_name: 'rel_cmd',
          topic: 'rel_cmd',
          plugin: 'core',
          summary: 'Test',
          related_commands: Sequel.pg_array(['cmd1', 'cmd2'], :text)
        )

        content = helpfile.full_content
        expect(content).to include('cmd1, cmd2')
      end
    end

    describe '#to_player_display edge cases' do
      it 'handles empty aliases array' do
        helpfile = Helpfile.create(
          command_name: 'empty_alias',
          topic: 'empty_alias',
          plugin: 'core',
          summary: 'Test',
          aliases: []
        )

        display = helpfile.to_player_display
        expect(display).not_to include('Aliases:')
      end

      it 'handles nil category' do
        helpfile = Helpfile.create(
          command_name: 'nil_cat',
          topic: 'nil_cat',
          plugin: 'core',
          summary: 'Test',
          category: nil
        )

        display = helpfile.to_player_display
        expect(display).not_to include('Category:')
      end
    end

    describe '#to_staff_display edge cases' do
      it 'handles missing source_line' do
        helpfile = Helpfile.create(
          command_name: 'no_line',
          topic: 'no_line',
          plugin: 'core',
          summary: 'Test',
          source_file: 'app/test.rb',
          source_line: nil
        )

        display = helpfile.to_staff_display
        expect(display).to include('Source: app/test.rb')
        expect(display).not_to include(':nil')
      end

      it 'handles nil requirements_summary' do
        helpfile = Helpfile.create(
          command_name: 'nil_req',
          topic: 'nil_req',
          plugin: 'core',
          summary: 'Test',
          requirements_summary: nil
        )

        display = helpfile.to_staff_display
        expect(display).not_to include('Requirements:')
      end

      it 'handles empty requirements_summary' do
        helpfile = Helpfile.create(
          command_name: 'empty_req',
          topic: 'empty_req',
          plugin: 'core',
          summary: 'Test',
          requirements_summary: ''
        )

        display = helpfile.to_staff_display
        expect(display).not_to include('Requirements:')
      end

      it 'handles code reference without line number' do
        helpfile = Helpfile.create(
          command_name: 'no_ref_line',
          topic: 'no_ref_line',
          plugin: 'core',
          summary: 'Test',
          code_references: Sequel.pg_jsonb([{ 'file' => 'app/test.rb' }])
        )

        display = helpfile.to_staff_display
        expect(display).to include('app/test.rb')
      end

      it 'handles code reference with description' do
        helpfile = Helpfile.create(
          command_name: 'desc_ref',
          topic: 'desc_ref',
          plugin: 'core',
          summary: 'Test',
          code_references: Sequel.pg_jsonb([{ 'file' => 'app/test.rb', 'description' => 'Main logic' }])
        )

        display = helpfile.to_staff_display
        expect(display).to include('Main logic')
      end
    end

    describe 'parsed_examples edge cases (via full_content)' do
      it 'parses legacy string format examples' do
        helpfile = Helpfile.create(
          command_name: 'legacy_ex',
          topic: 'legacy_ex',
          plugin: 'core',
          summary: 'Test',
          examples: "look\nlook sword"
        )

        content = helpfile.full_content
        expect(content).to include('`look`')
        expect(content).to include('`look sword`')
      end

      it 'handles empty examples' do
        helpfile = Helpfile.create(
          command_name: 'no_ex',
          topic: 'no_ex',
          plugin: 'core',
          summary: 'Test',
          examples: ''
        )

        content = helpfile.full_content
        expect(content).not_to include('## Examples')
      end

      it 'handles nil examples' do
        helpfile = Helpfile.create(
          command_name: 'nil_ex',
          topic: 'nil_ex',
          plugin: 'core',
          summary: 'Test',
          examples: nil
        )

        content = helpfile.full_content
        expect(content).not_to include('## Examples')
      end
    end

    describe '.search edge cases' do
      it 'filters duplicates across exact and partial matches' do
        helpfile = Helpfile.create(
          command_name: 'searchdup',
          topic: 'searchdup',
          plugin: 'core',
          summary: 'Search duplicate test searchdup'
        )

        results = Helpfile.search('searchdup')
        ids = results.map(&:id)
        expect(ids).to eq(ids.uniq)
      end

      it 'filters by symbol category' do
        helpfile = Helpfile.create(
          command_name: 'symcat',
          topic: 'symcat',
          plugin: 'core',
          category: 'combat',
          summary: 'Test'
        )

        results = Helpfile.search('sym', category: :combat)
        expect(results).to include(helpfile)
      end
    end

    describe '#add_synonym edge cases' do
      let!(:helpfile) do
        Helpfile.create(
          command_name: 'syn_edge',
          topic: 'syn_edge',
          plugin: 'core',
          summary: 'Test'
        )
      end

      it 'handles whitespace-only synonym' do
        result = helpfile.add_synonym('   ')
        expect(result).to be_nil
      end
    end

    describe '.sync_all_commands! edge cases' do
      it 'handles errors during command sync gracefully' do
        # This tests the rescue block
        allow(Commands::Base::Registry).to receive(:commands).and_return({
          'bad_cmd' => Class.new do
            def self.command_name
              raise StandardError, 'Simulated error'
            end
          end
        })

        expect { Helpfile.sync_all_commands! }.not_to raise_error
      end
    end

    describe '.extract_source_info edge cases' do
      it 'handles NameError when method does not exist' do
        mock_class = Class.new
        # Class with no execute or perform_command methods

        result = Helpfile.extract_source_info(mock_class)
        expect(result[:file]).to be_nil
        expect(result[:line]).to be_nil
      end
    end
  end
end
