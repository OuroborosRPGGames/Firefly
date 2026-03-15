# frozen_string_literal: true

require_relative '../app'

# Helper script for manually documenting commands
class CommandDocumenter
  def self.list_all
    commands = Commands::Base::Registry.commands.values.sort_by(&:command_name)

    puts "\n=== ALL COMMANDS (#{commands.length} total) ==="
    puts "=" * 80

    commands.each do |cmd_class|
      name = cmd_class.command_name
      helpfile = Helpfile.first(command_name: name)

      has_desc = helpfile&.description && !helpfile.description.strip.empty?
      status = has_desc ? "✓" : "○"

      plugin = cmd_class.respond_to?(:plugin_name) ? cmd_class.plugin_name : 'core'
      category = cmd_class.respond_to?(:category) ? cmd_class.category : 'unknown'

      printf("%-3s %-20s %-15s %s\n", status, name, category, plugin)
    end

    documented = commands.count { |c|
      h = Helpfile.first(command_name: c.command_name)
      h&.description && !h.description.strip.empty?
    }

    puts "\n#{documented}/#{commands.length} commands documented (#{((documented.to_f / commands.length) * 100).round(1)}%)"
  end

  def self.show_command(name)
    cmd_class = Commands::Base::Registry.commands[name]
    unless cmd_class
      puts "Command '#{name}' not found."
      return
    end

    helpfile = Helpfile.first(command_name: name)
    unless helpfile
      puts "No helpfile found for '#{name}'. Run sync first."
      return
    end

    puts "\n=== #{name.upcase} ==="
    puts "Plugin: #{cmd_class.respond_to?(:plugin_name) ? cmd_class.plugin_name : 'core'}"
    puts "Category: #{cmd_class.respond_to?(:category) ? cmd_class.category : 'unknown'}"
    puts "File: #{helpfile.source_file}:#{helpfile.source_line}"
    puts "\nCurrent Summary:"
    puts helpfile.summary
    puts "\nCurrent Description:"
    puts helpfile.description || "(none)"
    puts "\nAliases: #{cmd_class.respond_to?(:alias_names) ? cmd_class.alias_names.join(', ') : 'none'}"
    puts "=" * 80
  end

  def self.update_description(name, description)
    helpfile = Helpfile.first(command_name: name)
    unless helpfile
      puts "No helpfile found for '#{name}'."
      return
    end

    helpfile.update(description: description.strip)
    puts "✓ Updated description for '#{name}'"
  end

  def self.list_category(category)
    commands = Commands::Base::Registry.commands.values
      .select { |c| c.respond_to?(:category) && c.category.to_s == category.to_s }
      .sort_by(&:command_name)

    puts "\n=== #{category.upcase} COMMANDS (#{commands.length} total) ==="
    commands.each do |cmd_class|
      name = cmd_class.command_name
      helpfile = Helpfile.first(command_name: name)
      has_desc = helpfile&.description && !helpfile.description.strip.empty?
      status = has_desc ? "✓" : "○"
      printf("%-3s %-20s %s\n", status, name, helpfile&.summary || '')
    end
  end

  def self.list_undocumented
    commands = Commands::Base::Registry.commands.values.sort_by(&:command_name)
    undocumented = commands.select do |cmd_class|
      helpfile = Helpfile.first(command_name: cmd_class.command_name)
      !helpfile || !helpfile.description || helpfile.description.strip.empty?
    end

    puts "\n=== UNDOCUMENTED COMMANDS (#{undocumented.length} remaining) ==="
    undocumented.each do |cmd_class|
      name = cmd_class.command_name
      category = cmd_class.respond_to?(:category) ? cmd_class.category : 'unknown'
      printf("%-20s %-15s\n", name, category)
    end
  end
end

# CLI interface
command = ARGV[0]
case command
when 'list'
  CommandDocumenter.list_all
when 'category'
  CommandDocumenter.list_category(ARGV[1]) if ARGV[1]
when 'show'
  CommandDocumenter.show_command(ARGV[1]) if ARGV[1]
when 'undocumented', 'todo'
  CommandDocumenter.list_undocumented
else
  puts "Usage:"
  puts "  ruby scripts/document_commands.rb list              - List all commands with status"
  puts "  ruby scripts/document_commands.rb undocumented      - List commands needing documentation"
  puts "  ruby scripts/document_commands.rb category <name>   - List commands in a category"
  puts "  ruby scripts/document_commands.rb show <command>    - Show command details"
end
