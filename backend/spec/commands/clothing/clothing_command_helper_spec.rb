# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Clothing::ClothingCommandHelper do
  let(:helper_host) do
    Class.new do
      include Commands::Clothing::ClothingCommandHelper

      public :toggle_worn_items
      public :format_failure_notes
    end.new
  end

  FakeItem = Struct.new(:name, :concealed, :zipped, keyword_init: true) do
    def update(attrs)
      attrs.each { |k, v| public_send("#{k}=", v) }
      true
    end
  end

  describe '#toggle_worn_items' do
    let(:jacket) { FakeItem.new(name: 'Jacket', concealed: false, zipped: false) }
    let(:boots) { FakeItem.new(name: 'Boots', concealed: true, zipped: false) }
    let(:worn_items) { [jacket, boots] }

    it 'updates resolved items not already in the target state' do
      allow(TargetResolverService).to receive(:resolve)
        .with(query: 'jacket', candidates: worn_items, name_field: :name)
        .and_return(jacket)

      result = helper_host.toggle_worn_items(
        item_names: ['jacket'],
        worn_items: worn_items,
        attribute: :concealed,
        target_value: true,
        already_msg: 'already concealed'
      )

      expect(jacket.concealed).to be true
      expect(result[:successes]).to eq([jacket])
      expect(result[:failures]).to eq([])
    end

    it 'returns failure when resolver cannot find a worn item' do
      allow(TargetResolverService).to receive(:resolve).and_return(nil)

      result = helper_host.toggle_worn_items(
        item_names: ['hat'],
        worn_items: worn_items,
        attribute: :concealed,
        target_value: true,
        already_msg: 'already concealed'
      )

      expect(result[:successes]).to eq([])
      expect(result[:failures]).to eq([{ name: 'hat', reason: "not wearing 'hat'" }])
    end

    it 'returns failure when item is already in target state' do
      allow(TargetResolverService).to receive(:resolve).and_return(boots)

      result = helper_host.toggle_worn_items(
        item_names: ['boots'],
        worn_items: worn_items,
        attribute: :concealed,
        target_value: true,
        already_msg: 'already concealed'
      )

      expect(result[:successes]).to eq([])
      expect(result[:failures]).to eq([{ name: 'Boots', reason: 'already concealed' }])
    end

    it 'accumulates mixed successes and failures across multiple names' do
      allow(TargetResolverService).to receive(:resolve)
        .with(query: 'jacket', candidates: worn_items, name_field: :name)
        .and_return(jacket)
      allow(TargetResolverService).to receive(:resolve)
        .with(query: 'boots', candidates: worn_items, name_field: :name)
        .and_return(boots)
      allow(TargetResolverService).to receive(:resolve)
        .with(query: 'cape', candidates: worn_items, name_field: :name)
        .and_return(nil)

      result = helper_host.toggle_worn_items(
        item_names: %w[jacket boots cape],
        worn_items: worn_items,
        attribute: :concealed,
        target_value: true,
        already_msg: 'already concealed'
      )

      expect(result[:successes]).to eq([jacket])
      expect(result[:failures]).to eq([
                                       { name: 'Boots', reason: 'already concealed' },
                                       { name: 'cape', reason: "not wearing 'cape'" }
                                     ])
    end
  end

  describe '#format_failure_notes' do
    it 'returns empty string when there are no failures' do
      expect(helper_host.format_failure_notes([], prefix: 'Skipped')).to eq('')
    end

    it 'formats a human-readable failure notes suffix' do
      notes = helper_host.format_failure_notes(
        [{ name: 'Boots', reason: 'already concealed' }, { name: 'cape', reason: "not wearing 'cape'" }],
        prefix: 'Skipped'
      )

      expect(notes).to eq("\n(Skipped: Boots: already concealed; cape: not wearing 'cape')")
    end
  end
end
