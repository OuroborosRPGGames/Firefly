# frozen_string_literal: true

# =============================================================================
# Command Registration Test Suite
# =============================================================================
#
# Tests to catch command registration issues:
# 1. All command classes inherit from Commands::Base::Command
# 2. All command classes call Registry.register() at file end
# 3. Registered commands are findable by name
# 4. Registered commands work through both direct and Registry execution
#
# Run with: bundle exec rspec spec/commands/command_registration_spec.rb
#

RSpec.describe "Command Registration System" do
  describe "file-level validation" do
    it "all command files call Registry.register" do
      command_files = Dir.glob('plugins/**/commands/**/*.rb')
      expect(command_files).not_to be_empty, "No command files found"

      unregistered_files = []

      command_files.each do |file|
        content = File.read(file)

        # Skip files that don't define a command class
        # (some may be helper utilities)
        next unless content =~ /class\s+\w+\s*<\s*Commands::Base::Command/

        # Check if the file explicitly registers the command
        unless content.include?("Commands::Base::Registry.register(")
          unregistered_files << file
        end
      end

      expect(unregistered_files).to be_empty,
        "Found command files without Registry.register calls:\n  #{unregistered_files.join("\n  ")}"
    end

    it "all command files have valid class names" do
      command_files = Dir.glob('plugins/**/commands/**/*.rb')

      command_files.each do |file|
        content = File.read(file)

        # Find class definitions
        class_matches = content.scan(/class\s+(\w+)\s*<\s*Commands::Base::Command/)
        next if class_matches.empty?

        class_matches.each do |match|
          class_name = match[0]

          # Verify CamelCase
          expect(class_name).to match(/^[A-Z][a-zA-Z0-9]*$/),
            "Class name '#{class_name}' in #{file} is not CamelCase"

          # Verify it's registered
          expect(content).to include("Commands::Base::Registry.register("),
            "Class '#{class_name}' in #{file} is not registered"
        end
      end
    end

    it "all registration calls use correct constant path" do
      command_files = Dir.glob('backend/plugins/**/commands/**/*.rb')

      command_files.each do |file|
        content = File.read(file)

        # Extract class name
        class_match = content.match(/class\s+(\w+)\s*<\s*Commands::Base::Command/)
        next unless class_match

        class_name = class_match[1]

        # Extract module path (everything before the class definition)
        module_matches = content.scan(/module\s+(\w+)/)
        next if module_matches.empty?

        # Build expected path: Commands::<PluginName>::<ClassName>
        # where PluginName is extracted from the module hierarchy
        plugin_name = module_matches.last[0]  # Last module before class

        # Check that the registration matches the class
        expected_pattern = "Commands::#{plugin_name}::#{class_name}"
        expect(content).to include(expected_pattern),
          "File #{file}: Expected '#{expected_pattern}' in Registry.register call"
      end
    end
  end

  describe "registry integration" do
    it "core commands are all registered" do
      expected_core_commands = [
        # Communication
        'say', 'emote', 'whisper', 'knock', 'attempt',
        # Navigation
        'look', 'north', 'south', 'east', 'west',
        'up', 'down', 'follow', 'lead', 'stop',
        # Inventory
        'inventory', 'get', 'give', 'drop', 'show',
        # Posture
        'stand', 'sit', 'lie',
        # Info/Social
        'who', 'profile', 'score', 'observe',
        # System
        'help', 'quit', 'commands'
      ]

      expected_core_commands.each do |cmd_name|
        cmd_class = Commands::Base::Registry.commands[cmd_name]
        expect(cmd_class).not_to be_nil,
          "Core command '#{cmd_name}' is not registered"
      end
    end

    it "all registered commands have the correct command_name" do
      Commands::Base::Registry.commands.each do |name, cmd_class|
        expect(cmd_class.command_name).to eq(name),
          "Command class #{cmd_class} has name '#{cmd_class.command_name}' but registered as '#{name}'"
      end
    end

    it "all registered commands can be found by find_command" do
      Commands::Base::Registry.commands.each do |name, expected_class|
        found_class, words = Commands::Base::Registry.find_command(name)

        expect(found_class).to eq(expected_class),
          "find_command('#{name}') returned wrong class"
        expect(words).to be > 0,
          "find_command('#{name}') returned 0 words consumed"
      end
    end

    it "aliases resolve to correct command classes" do
      test_cases = [
        # [input, expected_command_class]
        ['"Hello', Commands::Communication::Say],
        ["'Hello", Commands::Communication::Say],
        ['n', Commands::Navigation::North],
        ['i', Commands::Inventory::InventoryCmd],
      ]

      test_cases.each do |input, expected_class|
        found_class, _words = Commands::Base::Registry.find_command(input)
        expect(found_class).to eq(expected_class),
          "Alias '#{input}' should resolve to #{expected_class.command_name}, got #{found_class&.command_name}"
      end
    end

    it "unregistered commands return nil" do
      found_class, _words = Commands::Base::Registry.find_command('notarealcommand12345xyz')
      expect(found_class).to be_nil,
        "Unregistered command should not be found"
    end
  end

  describe "execution paths" do
    let(:character_instance) do
      # Create a test character instance with necessary setup
      char = create(:character_instance)
      char
    end

    # Test a few key commands through both execution paths
    context "say command" do
      let(:command) { Commands::Communication::Say.new(character_instance) }

      it "works when called directly" do
        result = command.execute('say Hello')
        expect(result[:success]).to be true
        expect(result[:message]).not_to be_nil
      end

      it "works when called through Registry" do
        result = Commands::Base::Registry.execute_command(
          character_instance,
          'say Hello'
        )
        expect(result[:success]).to be true
      end

      it "works with alias (double quote)" do
        result = Commands::Base::Registry.execute_command(
          character_instance,
          '"Hello'
        )
        expect(result[:success]).to be true
      end

      it "works with alias (single quote)" do
        result = Commands::Base::Registry.execute_command(
          character_instance,
          "'Hello"
        )
        expect(result[:success]).to be true
      end

      it "is registered in the registry" do
        expect(Commands::Base::Registry.commands['say'])
          .to eq(Commands::Communication::Say)
      end
    end

    context "look command" do
      let(:command) { Commands::Navigation::Look.new(character_instance) }

      it "works when called directly" do
        result = command.execute('look')
        expect(result[:success]).to be true
      end

      it "works when called through Registry" do
        result = Commands::Base::Registry.execute_command(
          character_instance,
          'look'
        )
        expect(result[:success]).to be true
      end

      it "is registered in the registry" do
        expect(Commands::Base::Registry.commands['look'])
          .to eq(Commands::Navigation::Look)
      end
    end

    context "inventory command" do
      let(:command) { Commands::Inventory::InventoryCmd.new(character_instance) }

      it "works when called directly" do
        result = command.execute('inventory')
        expect(result[:success]).to be true
      end

      it "works when called through Registry" do
        result = Commands::Base::Registry.execute_command(
          character_instance,
          'inventory'
        )
        expect(result[:success]).to be true
      end

      it "works with alias 'i'" do
        result = Commands::Base::Registry.execute_command(
          character_instance,
          'i'
        )
        expect(result[:success]).to be true
      end

      it "is registered in the registry" do
        expect(Commands::Base::Registry.commands['inventory'])
          .to eq(Commands::Inventory::InventoryCmd)
      end
    end
  end

  describe "command metadata validation" do
    it "all registered commands have help_text" do
      Commands::Base::Registry.commands.each do |name, cmd_class|
        help = cmd_class.help_text
        expect(help).not_to be_nil,
          "Command '#{name}' missing help_text"
        expect(help).not_to be_empty,
          "Command '#{name}' has empty help_text"
      end
    end

    it "all registered commands have category" do
      Commands::Base::Registry.commands.each do |name, cmd_class|
        category = cmd_class.category
        expect(category).not_to be_nil,
          "Command '#{name}' missing category"
      end
    end

    it "all registered commands have usage" do
      # Directional commands don't need detailed usage since they're self-explanatory
      skip_commands = %w[north south east west northeast northwest southeast southwest up down in out]

      Commands::Base::Registry.commands.each do |name, cmd_class|
        next if skip_commands.include?(name)

        usage = cmd_class.usage
        expect(usage).not_to be_nil,
          "Command '#{name}' missing usage"
      end
    end

    it "all registered commands have examples" do
      # Directional commands don't need detailed examples since they're self-explanatory
      skip_commands = %w[north south east west northeast northwest southeast southwest up down in out]

      Commands::Base::Registry.commands.each do |name, cmd_class|
        next if skip_commands.include?(name)

        examples = cmd_class.examples
        expect(examples).not_to be_nil,
          "Command '#{name}' missing examples"
        expect(examples).not_to be_empty,
          "Command '#{name}' has empty examples"
      end
    end
  end

  describe "command discovery" do
    it "discovers all commands in the Commands module" do
      # This is more of a sanity check
      all_commands = Commands::Base::Registry.commands

      expect(all_commands).not_to be_empty,
        "Registry has no commands registered"

      # Verify some core commands exist
      core_commands = ['say', 'look', 'inventory', 'help']
      core_commands.each do |cmd|
        expect(all_commands).to include(cmd),
          "Core command '#{cmd}' is missing from registry"
      end
    end

    it "does not have duplicate command names" do
      command_names = Commands::Base::Registry.commands.keys
      duplicates = command_names.select { |cmd| command_names.count(cmd) > 1 }.uniq

      expect(duplicates).to be_empty,
        "Found duplicate command names: #{duplicates.join(', ')}"
    end

    it "resolves all aliases to registered commands" do
      all_aliases = Commands::Base::Registry.aliases

      all_aliases.each do |alias_name, cmd_class|
        registered_class = Commands::Base::Registry.commands[cmd_class.command_name]
        expect(registered_class).to eq(cmd_class),
          "Alias '#{alias_name}' points to #{cmd_class}, but that's not registered"
      end
    end
  end

  describe "error handling" do
    let(:character_instance) { create(:character_instance) }

    it "returns helpful error for unregistered commands" do
      result = Commands::Base::Registry.execute_command(
        character_instance,
        'notarealcommand xyz'
      )

      expect(result[:success]).to be false
      expect(result[:error]).to include("not a valid command")
    end

    it "suggests similar commands when available" do
      result = Commands::Base::Registry.execute_command(
        character_instance,
        'syy Hello'  # Typo of 'say'
      )

      expect(result[:success]).to be false
      expect(result[:suggestions]).not_to be_empty,
        "Should suggest 'say' for 'syy'"
    end

    it "handles empty input gracefully" do
      result = Commands::Base::Registry.execute_command(
        character_instance,
        ''
      )

      expect(result[:success]).to be false
    end

    it "handles nil input gracefully" do
      result = Commands::Base::Registry.execute_command(
        character_instance,
        nil
      )

      expect(result[:success]).to be false
    end
  end
end
