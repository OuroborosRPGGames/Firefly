# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Helpfile sync accuracy' do
  before(:all) do
    Helpfile.sync_all_commands!
  end

  after(:all) do
    Helpfile.where(auto_generated: true).delete
    HelpfileSynonym.dataset.delete
  end

  Commands::Base::Registry.commands.each do |cmd_name, cmd_class|
    describe "helpfile for '#{cmd_name}'" do
      let(:helpfile) { Helpfile.first(command_name: cmd_name) }

      it 'exists in the database' do
        expect(helpfile).not_to be_nil,
          "No helpfile generated for registered command '#{cmd_name}'"
      end

      it 'has summary matching help_text' do
        next unless helpfile

        expected = cmd_class.help_text
        expect(helpfile.summary).to eq(expected) if expected
      end

      it 'has syntax matching usage' do
        next unless helpfile

        expected = cmd_class.usage
        expect(helpfile.syntax).to eq(expected) if expected
      end

      it 'has a source_file set' do
        next unless helpfile

        expect(helpfile.source_file).not_to be_nil,
          "Helpfile for '#{cmd_name}' has no source_file"
      end
    end
  end
end
