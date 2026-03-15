# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../app/services/concerns/pathfinding_helper'

RSpec.describe PathfindingHelper do
  let(:klass) { Class.new { include PathfindingHelper } }
  subject { klass.new }

  describe '#reconstruct_path' do
    let(:came_from) { { 'b' => 'a', 'c' => 'b', 'd' => 'c' } }

    it 'returns full path from start to end' do
      expect(subject.reconstruct_path(came_from, 'd')).to eq(%w[a b c d])
    end

    it 'returns just the current node when no came_from entry' do
      expect(subject.reconstruct_path({}, 'z')).to eq(['z'])
    end

    it 'skips the starting node when skip_start: true' do
      expect(subject.reconstruct_path(came_from, 'd', skip_start: true)).to eq(%w[b c d])
    end
  end
end
