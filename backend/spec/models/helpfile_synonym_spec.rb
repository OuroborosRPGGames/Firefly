# frozen_string_literal: true

require 'spec_helper'

RSpec.describe HelpfileSynonym do
  # Clear helpfiles that may have been synced from commands to avoid conflicts
  before(:all) do
    HelpfileSynonym.dataset.delete
    Helpfile.dataset.delete
  end

  before do
    @helpfile = Helpfile.create(
      command_name: 'look',
      topic: 'look',
      plugin: 'core',
      summary: 'Look at your surroundings'
    )
  end

  describe 'validations' do
    it 'requires helpfile_id and synonym' do
      synonym = HelpfileSynonym.new
      expect(synonym.valid?).to be false
      expect(synonym.errors[:helpfile_id]).to include('is not present')
      expect(synonym.errors[:synonym]).to include('is not present')
    end

    it 'creates valid synonym' do
      synonym = HelpfileSynonym.create(helpfile_id: @helpfile.id, synonym: 'l')
      expect(synonym.valid?).to be true
      expect(synonym.id).not_to be_nil
    end

    it 'enforces unique synonym' do
      HelpfileSynonym.create(helpfile_id: @helpfile.id, synonym: 'examine')
      duplicate = HelpfileSynonym.new(helpfile_id: @helpfile.id, synonym: 'examine')
      expect(duplicate.valid?).to be false
      expect(duplicate.errors[:synonym]).to include('is already taken')
    end
  end

  describe 'before_save normalization' do
    it 'downcases synonym' do
      synonym = HelpfileSynonym.create(helpfile_id: @helpfile.id, synonym: 'LOOK')
      expect(synonym.synonym).to eq('look')
    end

    it 'strips whitespace' do
      synonym = HelpfileSynonym.create(helpfile_id: @helpfile.id, synonym: '  view  ')
      expect(synonym.synonym).to eq('view')
    end
  end

  describe '.find_helpfile' do
    before do
      HelpfileSynonym.create(helpfile_id: @helpfile.id, synonym: 'l')
      HelpfileSynonym.create(helpfile_id: @helpfile.id, synonym: 'examine')
    end

    it 'finds helpfile by synonym' do
      result = HelpfileSynonym.find_helpfile('l')
      expect(result).to eq(@helpfile)
    end

    it 'finds helpfile case-insensitively' do
      result = HelpfileSynonym.find_helpfile('EXAMINE')
      expect(result).to eq(@helpfile)
    end

    it 'returns nil for non-existent synonym' do
      result = HelpfileSynonym.find_helpfile('nonexistent')
      expect(result).to be_nil
    end

    it 'returns nil for empty string' do
      expect(HelpfileSynonym.find_helpfile('')).to be_nil
    end

    it 'returns nil for nil' do
      expect(HelpfileSynonym.find_helpfile(nil)).to be_nil
    end
  end

  describe 'association' do
    it 'belongs to helpfile' do
      synonym = HelpfileSynonym.create(helpfile_id: @helpfile.id, synonym: 'see')
      expect(synonym.helpfile).to eq(@helpfile)
    end
  end
end
