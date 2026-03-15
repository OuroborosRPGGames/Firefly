# frozen_string_literal: true

require 'spec_helper'

RSpec.describe HelpSystem, 'SYSTEM_DEFINITIONS command coverage' do
  # Gather all registered command names and their aliases
  let(:all_registered_commands) do
    Commands::Base::Registry.commands.keys
  end

  let(:all_aliases) do
    Commands::Base::Registry.aliases.keys +
      Commands::Base::Registry.multiword_aliases.keys
  end

  let(:all_known_names) { (all_registered_commands + all_aliases).uniq }

  let(:all_system_command_names) do
    HelpSystem::SYSTEM_DEFINITIONS.flat_map { |d| d[:command_names] }.uniq
  end

  # UI-only prefixes (client-side commands) that appear in SYSTEM_DEFINITIONS
  # but aren't registered as server-side commands - this is expected
  let(:known_ui_only_prefixes) do
    %w[asleft asright sticky stickymode onleft onright]
  end

  # Subcommand references listed in SYSTEM_DEFINITIONS for documentation
  # but handled as arguments to a parent command (e.g., "customize roomtitle")
  let(:known_subcommand_refs) do
    %w[]
  end

  describe 'every command_name in SYSTEM_DEFINITIONS' do
    it 'references an actual registered command, alias, or known UI prefix' do
      missing = all_system_command_names.reject do |name|
        all_known_names.include?(name) || known_ui_only_prefixes.include?(name) || known_subcommand_refs.include?(name)
      end

      expect(missing).to be_empty,
        "SYSTEM_DEFINITIONS references #{missing.size} unknown commands:\n" \
        "#{missing.sort.map { |m| "  - #{m}" }.join("\n")}"
    end
  end
end
