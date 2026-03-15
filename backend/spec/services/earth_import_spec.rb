# frozen_string_literal: true

require 'spec_helper'

RSpec.describe EarthImport do
  describe 'error hierarchy' do
    it 'defines base EarthImport error class' do
      expect(described_class::Error).to be < StandardError
    end

    it 'defines DownloadError as an EarthImport::Error' do
      expect(described_class::DownloadError).to be < described_class::Error
    end

    it 'defines ParseError as an EarthImport::Error' do
      expect(described_class::ParseError).to be < described_class::Error
    end
  end

  describe 'module loading' do
    it 'loads pipeline service constants from earth_import directory' do
      expect(defined?(EarthImport::PipelineService)).to eq('constant')
      expect(defined?(EarthImport::DataDownloader)).to eq('constant')
      expect(defined?(EarthImport::TerrainClassifier)).to eq('constant')
    end
  end
end
