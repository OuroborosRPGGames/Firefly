# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Base::Registry do
  # Create test command classes before tests
  before(:all) do
    # Test command with global aliases
    @global_command_class = Class.new(Commands::Base::Command) do
      command_name 'testglobal'
      aliases 'tg', 'globaltest'

      def perform_command(_parsed_input)
        success_result("Global command!")
      end
    end

    # Test command with context-specific aliases
    @context_command_class = Class.new(Commands::Base::Command) do
      command_name 'testcontext'
      aliases 'tc', { name: 'ctx', context: :combat }

      def perform_command(_parsed_input)
        success_result("Context command!")
      end
    end

    # Test command for prefix matching
    @prefix_command_class = Class.new(Commands::Base::Command) do
      command_name 'inventory'
      aliases 'inv'

      def perform_command(_parsed_input)
        success_result("Inventory!")
      end
    end
  end

  # Helper to extract just the command class from find_command result
  def find_command_class(input, context: nil)
    result, _words_consumed = described_class.find_command(input, context: context)
    result
  end

  # Clean up registry after each test
  before(:each) do
    # Store original state
    @original_commands = described_class.commands.dup
    @original_aliases = described_class.aliases.dup
    @original_multiword = described_class.multiword_aliases.dup
    @original_contextual = described_class.contextual_aliases.dup

    # Clear for testing
    described_class.instance_variable_set(:@commands, {})
    described_class.instance_variable_set(:@aliases, {})
    described_class.instance_variable_set(:@multiword_aliases, {})
    described_class.instance_variable_set(:@contextual_aliases, {})
    described_class.instance_variable_set(:@prefix_commands, {})
  end

  after(:each) do
    # Restore original state
    described_class.instance_variable_set(:@commands, @original_commands)
    described_class.instance_variable_set(:@aliases, @original_aliases)
    described_class.instance_variable_set(:@multiword_aliases, @original_multiword)
    described_class.instance_variable_set(:@contextual_aliases, @original_contextual)
  end

  describe '.register' do
    it 'registers command by name' do
      described_class.register(@global_command_class)
      expect(described_class.commands).to have_key('testglobal')
    end

    it 'registers global aliases' do
      described_class.register(@global_command_class)
      expect(described_class.aliases).to have_key('tg')
      expect(described_class.aliases).to have_key('globaltest')
    end

    it 'registers context-specific aliases' do
      described_class.register(@context_command_class)
      expect(described_class.contextual_aliases[:combat]).to have_key('ctx')
    end
  end

  describe '.find_command' do
    before do
      described_class.register(@global_command_class)
      described_class.register(@context_command_class)
      described_class.register(@prefix_command_class)
    end

    context 'with exact command name' do
      it 'finds command by exact name' do
        result = find_command_class('testglobal some args')
        expect(result).to eq(@global_command_class)
      end
    end

    context 'with global alias' do
      it 'finds command by global alias' do
        result = find_command_class('tg some args')
        expect(result).to eq(@global_command_class)
      end
    end

    context 'with context-specific alias' do
      it 'finds command when in correct context' do
        result = find_command_class('ctx attack', context: :combat)
        expect(result).to eq(@context_command_class)
      end

      it 'does not find command when in wrong context' do
        result = find_command_class('ctx attack', context: :exploration)
        expect(result).not_to eq(@context_command_class)
      end

      it 'does not find command with no context' do
        result = find_command_class('ctx attack')
        expect(result).not_to eq(@context_command_class)
      end
    end

    context 'with multiple contexts' do
      it 'finds command when any context matches' do
        result = find_command_class('ctx attack', context: [:exploration, :combat])
        expect(result).to eq(@context_command_class)
      end
    end

    context 'with prefix matching' do
      it 'finds command by prefix (minimum 2 chars)' do
        result = find_command_class('inven')
        expect(result).to eq(@prefix_command_class)
      end

      it 'does not match single character' do
        result = find_command_class('i something')
        expect(result).not_to eq(@prefix_command_class)
      end
    end

    context 'with empty or nil input' do
      it 'returns nil for nil input' do
        result, _words = described_class.find_command(nil)
        expect(result).to be_nil
      end

      it 'returns nil for empty input' do
        result, _words = described_class.find_command('')
        expect(result).to be_nil
      end

      it 'returns nil for whitespace-only input' do
        result, _words = described_class.find_command('   ')
        expect(result).to be_nil
      end
    end
  end

  describe '.add_alias' do
    before do
      described_class.register(@global_command_class)
    end

    it 'adds a global alias dynamically' do
      described_class.add_alias('newalias', 'testglobal')
      result = find_command_class('newalias')
      expect(result).to eq(@global_command_class)
    end

    it 'adds a contextual alias dynamically' do
      described_class.add_alias('combatalias', 'testglobal', context: :combat)
      result = find_command_class('combatalias', context: :combat)
      expect(result).to eq(@global_command_class)
    end

    it 'returns false for non-existent command' do
      result = described_class.add_alias('alias', 'nonexistent')
      expect(result).to be false
    end
  end

  describe '.remove_alias' do
    before do
      described_class.register(@global_command_class)
    end

    it 'removes a global alias' do
      described_class.remove_alias('tg')
      expect(described_class.aliases).not_to have_key('tg')
    end

    it 'removes a contextual alias' do
      described_class.register(@context_command_class)
      described_class.remove_alias('ctx', context: :combat)
      expect(described_class.contextual_aliases[:combat]).not_to have_key('ctx')
    end
  end

  describe '.commands_for_context' do
    before do
      described_class.register(@global_command_class)
      described_class.register(@context_command_class)
    end

    it 'returns commands and aliases for a context' do
      result = described_class.commands_for_context(:combat)

      expect(result[:commands]).to include('testglobal', 'testcontext')
      expect(result[:aliases]).to include('tg', 'globaltest', 'tc')
      expect(result[:context_aliases]).to include('ctx')
    end
  end

  describe 'command priority' do
    before do
      described_class.register(@global_command_class)
      described_class.register(@context_command_class)
    end

    it 'prioritizes exact command name over aliases' do
      # Register an alias with same name as another command
      described_class.add_alias('testcontext', 'testglobal')

      # Command name should win
      result = find_command_class('testcontext')
      expect(result).to eq(@context_command_class)
    end

    it 'prioritizes contextual aliases over global aliases' do
      described_class.add_alias('shared', 'testglobal')
      described_class.add_alias('shared', 'testcontext', context: :combat)

      # In combat context, contextual alias wins
      result = find_command_class('shared', context: :combat)
      expect(result).to eq(@context_command_class)

      # Without context, global alias wins
      result = find_command_class('shared')
      expect(result).to eq(@global_command_class)
    end
  end

  describe 'multi-word aliases' do
    before do
      @multiword_command_class = Class.new(Commands::Base::Command) do
        command_name 'testmulti'
        aliases 'look at', 'stare at'

        def perform_command(_parsed_input)
          success_result("Multi-word!")
        end
      end
      described_class.register(@multiword_command_class)
    end

    it 'registers multi-word aliases' do
      expect(described_class.multiword_aliases).to have_key('look at')
      expect(described_class.multiword_aliases).to have_key('stare at')
    end

    it 'finds command by multi-word alias' do
      result = find_command_class('look at something')
      expect(result).to eq(@multiword_command_class)
    end

    it 'returns correct words consumed for multi-word alias' do
      _result, words_consumed = described_class.find_command('look at something')
      expect(words_consumed).to eq(2)
    end

    it 'returns 1 word consumed for single-word command' do
      described_class.register(@global_command_class)
      _result, words_consumed = described_class.find_command('testglobal something')
      expect(words_consumed).to eq(1)
    end
  end
end
