# frozen_string_literal: true

require 'spec_helper'
require_relative '../../app/lib/time_format_helper'

RSpec.describe TimeFormatHelper do
  let(:klass) { Class.new { extend TimeFormatHelper } }

  describe '#format_duration' do
    context 'style: :full (default)' do
      it 'formats seconds' do
        expect(klass.format_duration(45)).to eq('45 seconds')
      end

      it 'formats 1 second without plural' do
        expect(klass.format_duration(1)).to eq('1 second')
      end

      it 'formats minutes' do
        expect(klass.format_duration(90)).to eq('2 minutes')
      end

      it 'formats hours' do
        expect(klass.format_duration(3600)).to eq('1 hour')
      end

      it 'formats fractional hours' do
        expect(klass.format_duration(5400)).to include('hour')
      end
    end

    context 'style: :abbreviated' do
      it 'formats seconds' do
        expect(klass.format_duration(45, style: :abbreviated)).to eq('45s')
      end

      it 'formats minutes' do
        expect(klass.format_duration(90, style: :abbreviated)).to eq('2min')
      end

      it 'formats hours' do
        expect(klass.format_duration(3600, style: :abbreviated)).to eq('1h')
      end
    end
  end

  describe '#format_duration_gap' do
    it 'returns nil for small gaps' do
      t = Time.now
      expect(klass.format_duration_gap(t - 60, t)).to be_nil
    end

    it 'formats minute gaps' do
      t = Time.now
      result = klass.format_duration_gap(t - 300, t)
      expect(result).to eq('(5 minutes later)')
    end

    it 'formats hour gaps' do
      t = Time.now
      result = klass.format_duration_gap(t - 3600, t)
      expect(result).to eq('(An hour later)')
    end
  end
end
