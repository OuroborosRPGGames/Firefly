# frozen_string_literal: true

require 'spec_helper'

RSpec.describe PlaceLookupHelper do
  describe 'module structure' do
    it 'is a module' do
      expect(described_class).to be_a(Module)
    end
  end

  describe 'instance methods' do
    it 'defines find_place' do
      expect(described_class.instance_methods).to include(:find_place)
    end

    it 'defines find_furniture' do
      expect(described_class.instance_methods).to include(:find_furniture)
    end
  end

  # Create a test class that includes the helper with required dependencies
  let(:test_class) do
    Class.new do
      include PlaceLookupHelper

      attr_accessor :location

      def blank?(val)
        val.nil? || val.to_s.strip.empty?
      end
    end
  end

  let(:room) { double(id: 100) }
  let(:instance) do
    obj = test_class.new
    obj.location = room
    obj
  end

  describe '#find_place' do
    let(:couch) { double(id: 1, name: 'Leather Couch', is_furniture: true, invisible: false) }
    let(:table) { double(id: 2, name: 'Oak Table', is_furniture: true, invisible: false) }
    let(:sign) { double(id: 3, name: 'Welcome Sign', is_furniture: false, invisible: false) }

    before do
      dataset = double('Dataset')
      allow(Place).to receive(:where).with(room_id: room.id).and_return(dataset)
      allow(dataset).to receive(:where).with(is_furniture: true).and_return(dataset)
      allow(dataset).to receive(:all).and_return([couch, table])
    end

    it 'returns nil for blank name' do
      expect(instance.find_place('')).to be_nil
      expect(instance.find_place(nil)).to be_nil
    end

    it 'returns nil when room is nil' do
      instance.location = nil
      expect(instance.find_place('couch')).to be_nil
    end

    it 'finds place by exact name match' do
      dataset = double('Dataset')
      allow(Place).to receive(:where).with(room_id: room.id).and_return(dataset)
      allow(dataset).to receive(:all).and_return([couch, table, sign])

      expect(instance.find_place('Leather Couch')).to eq(couch)
    end

    it 'finds place by case-insensitive match' do
      dataset = double('Dataset')
      allow(Place).to receive(:where).with(room_id: room.id).and_return(dataset)
      allow(dataset).to receive(:all).and_return([couch, table, sign])

      expect(instance.find_place('leather couch')).to eq(couch)
    end

    it 'strips leading articles for matching' do
      dataset = double('Dataset')
      allow(Place).to receive(:where).with(room_id: room.id).and_return(dataset)
      allow(dataset).to receive(:all).and_return([couch, table, sign])

      expect(instance.find_place('the leather couch')).to eq(couch)
    end

    it 'finds place by prefix match' do
      dataset = double('Dataset')
      allow(Place).to receive(:where).with(room_id: room.id).and_return(dataset)
      allow(dataset).to receive(:all).and_return([couch, table, sign])

      expect(instance.find_place('leather')).to eq(couch)
    end

    it 'filters by furniture_only when specified' do
      dataset = double('Dataset')
      filtered = double('FilteredDataset')
      allow(Place).to receive(:where).with(room_id: room.id).and_return(dataset)
      allow(dataset).to receive(:where).with(is_furniture: true).and_return(filtered)
      allow(filtered).to receive(:all).and_return([couch, table])

      instance.find_place('couch', furniture_only: true)
      expect(dataset).to have_received(:where).with(is_furniture: true)
    end

    it 'returns nil when no places found' do
      dataset = double('Dataset')
      allow(Place).to receive(:where).with(room_id: room.id).and_return(dataset)
      allow(dataset).to receive(:all).and_return([])

      expect(instance.find_place('nonexistent')).to be_nil
    end
  end

  describe '#find_furniture' do
    let(:chair) { double(id: 1, name: 'Wooden Chair', is_furniture: true, invisible: false) }

    before do
      dataset = double('Dataset')
      filtered = double('FilteredDataset')
      allow(Place).to receive(:where).with(room_id: room.id).and_return(dataset)
      allow(dataset).to receive(:where).with(is_furniture: true).and_return(filtered)
      allow(filtered).to receive(:all).and_return([chair])
    end

    it 'calls find_place with furniture_only: true' do
      expect(instance).to receive(:find_place).with('chair', furniture_only: true, room: nil)
      instance.find_furniture('chair')
    end

    it 'passes room parameter to find_place' do
      other_room = double(id: 200)
      expect(instance).to receive(:find_place).with('chair', furniture_only: true, room: other_room)
      instance.find_furniture('chair', room: other_room)
    end
  end

  describe 'article stripping' do
    let(:bench) { double(id: 1, name: 'A Stone Bench', is_furniture: true, invisible: false) }

    before do
      dataset = double('Dataset')
      allow(Place).to receive(:where).with(room_id: room.id).and_return(dataset)
      allow(dataset).to receive(:all).and_return([bench])
    end

    it 'matches places with article in name' do
      result = instance.find_place('stone bench')
      expect(result).to eq(bench)
    end

    it 'matches when both input and name have articles' do
      result = instance.find_place('a stone bench')
      expect(result).to eq(bench)
    end
  end
end
