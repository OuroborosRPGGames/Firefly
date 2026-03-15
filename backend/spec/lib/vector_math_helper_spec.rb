# frozen_string_literal: true

require 'spec_helper'
require_relative '../../app/lib/vector_math_helper'

RSpec.describe VectorMathHelper do
  let(:klass) { Class.new { extend VectorMathHelper } }

  describe '#vector_centroid' do
    it 'returns zero vector for empty input' do
      expect(klass.vector_centroid([])).to eq(Array.new(6, 0.0))
    end

    it 'returns the single vector for one-element input' do
      expect(klass.vector_centroid([[1.0, 2.0, 3.0, 4.0, 5.0, 6.0]])).to eq([1.0, 2.0, 3.0, 4.0, 5.0, 6.0])
    end

    it 'averages two vectors' do
      result = klass.vector_centroid([[0.0, 4.0], [2.0, 0.0]])
      expect(result).to eq([1.0, 2.0])
    end
  end

  describe '#vector_distance' do
    it 'returns 0 for identical vectors' do
      expect(klass.vector_distance([1.0, 2.0], [1.0, 2.0])).to eq(0.0)
    end

    it 'calculates Euclidean distance' do
      expect(klass.vector_distance([0.0, 0.0], [3.0, 4.0])).to eq(5.0)
    end
  end
end
