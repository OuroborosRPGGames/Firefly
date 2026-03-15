# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Command DSL helpfile completeness' do
  Commands::Base::Registry.commands.each do |cmd_name, cmd_class|
    describe "#{cmd_name} (#{cmd_class.name})" do
      it 'has a non-placeholder help_text' do
        help = cmd_class.help_text
        expect(help).not_to be_nil, "#{cmd_name} has no help_text"
        expect(help).not_to match(/^No help available for /),
          "#{cmd_name} has default placeholder help_text: '#{help}'"
        expect(help.length).to be > 5,
          "#{cmd_name} has suspiciously short help_text: '#{help}'"
      end

      it 'has a usage string' do
        usage = cmd_class.usage
        expect(usage).not_to be_nil, "#{cmd_name} has no usage"
        expect(usage.to_s.length).to be > 0, "#{cmd_name} has empty usage"
      end

      it 'has at least one example' do
        ex = cmd_class.examples
        expect(ex).not_to be_empty, "#{cmd_name} has no examples"
      end

      it 'has a non-default category' do
        category = cmd_class.category
        expect(category).not_to be_nil, "#{cmd_name} has no category"
        expect(category).not_to eq(:general),
          "#{cmd_name} has default :general category — should be specific"
      end
    end
  end
end
