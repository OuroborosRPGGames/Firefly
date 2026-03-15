# frozen_string_literal: true

require 'spec_helper'
require 'sidekiq/testing'

RSpec.describe MaskGenerationJob do
  before do
    Sidekiq::Testing.fake!
  end

  after do
    Sidekiq::Worker.clear_all
  end

  describe '#perform' do
    let(:room) { create(:room) }

    it 'runs mask generation for existing room' do
      allow(MaskGenerationService).to receive(:generate).and_return({ success: true, mask_url: '/masks/test.png' })

      described_class.new.perform(room.id)

      expect(MaskGenerationService).to have_received(:generate).with(room)
    end

    it 'skips missing room ids' do
      allow(MaskGenerationService).to receive(:generate)

      described_class.new.perform(999_999_999)

      expect(MaskGenerationService).not_to have_received(:generate)
    end

    it 'does not raise when generation reports failure' do
      allow(MaskGenerationService).to receive(:generate).and_return({ success: false, error: 'segmentation failed' })

      expect { described_class.new.perform(room.id) }.not_to raise_error
    end
  end

  describe 'enqueuing' do
    it 'enqueues to the llm queue' do
      described_class.perform_async(123)
      expect(described_class.jobs.first['queue']).to eq('llm')
    end
  end
end
