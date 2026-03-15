# frozen_string_literal: true

require 'spec_helper'

RSpec.describe GameCleanupService do
  let(:fight_result) { { cleaned: 2, stale: 1, ended: 1, very_stale: 0, errors: [] } }
  let(:activity_result) { { cleaned: 1, expired: 0, stuck: 1 } }
  let(:auto_gm_result) { { cleaned: 0, stale: 0, errors: [] } }

  before do
    allow(FightCleanupService).to receive(:cleanup_all!).and_return(fight_result)
    allow(ActivityCleanupService).to receive(:cleanup_all!).and_return(activity_result)
    allow(AutoGm::AutoGmCleanupService).to receive(:cleanup_all!).and_return(auto_gm_result)
  end

  describe '.sweep!' do
    it 'calls all three cleanup services' do
      described_class.sweep!

      expect(FightCleanupService).to have_received(:cleanup_all!)
      expect(ActivityCleanupService).to have_received(:cleanup_all!)
      expect(AutoGm::AutoGmCleanupService).to have_received(:cleanup_all!)
    end

    it 'returns combined results from all services' do
      results = described_class.sweep!

      expect(results[:fights]).to eq(fight_result)
      expect(results[:activities]).to eq(activity_result)
      expect(results[:auto_gm]).to eq(auto_gm_result)
    end

    context 'when FightCleanupService raises' do
      before do
        allow(FightCleanupService).to receive(:cleanup_all!).and_raise(StandardError.new('fight db timeout'))
      end

      it 'captures the error and still runs the other services' do
        results = described_class.sweep!

        expect(results[:fights]).to eq({ error: 'fight db timeout' })
        expect(results[:activities]).to eq(activity_result)
        expect(results[:auto_gm]).to eq(auto_gm_result)
        expect(ActivityCleanupService).to have_received(:cleanup_all!)
        expect(AutoGm::AutoGmCleanupService).to have_received(:cleanup_all!)
      end
    end

    context 'when ActivityCleanupService raises' do
      before do
        allow(ActivityCleanupService).to receive(:cleanup_all!).and_raise(StandardError.new('activity error'))
      end

      it 'captures the error and still runs the other services' do
        results = described_class.sweep!

        expect(results[:fights]).to eq(fight_result)
        expect(results[:activities]).to eq({ error: 'activity error' })
        expect(results[:auto_gm]).to eq(auto_gm_result)
        expect(FightCleanupService).to have_received(:cleanup_all!)
        expect(AutoGm::AutoGmCleanupService).to have_received(:cleanup_all!)
      end
    end

    context 'when AutoGm::AutoGmCleanupService raises' do
      before do
        allow(AutoGm::AutoGmCleanupService).to receive(:cleanup_all!).and_raise(StandardError.new('auto gm broken'))
      end

      it 'captures the error and still runs the other services' do
        results = described_class.sweep!

        expect(results[:fights]).to eq(fight_result)
        expect(results[:activities]).to eq(activity_result)
        expect(results[:auto_gm]).to eq({ error: 'auto gm broken' })
        expect(FightCleanupService).to have_received(:cleanup_all!)
        expect(ActivityCleanupService).to have_received(:cleanup_all!)
      end
    end

    context 'when all services raise' do
      before do
        allow(FightCleanupService).to receive(:cleanup_all!).and_raise(StandardError.new('fight boom'))
        allow(ActivityCleanupService).to receive(:cleanup_all!).and_raise(StandardError.new('activity boom'))
        allow(AutoGm::AutoGmCleanupService).to receive(:cleanup_all!).and_raise(StandardError.new('gm boom'))
      end

      it 'captures all errors and returns them' do
        results = described_class.sweep!

        expect(results[:fights]).to eq({ error: 'fight boom' })
        expect(results[:activities]).to eq({ error: 'activity boom' })
        expect(results[:auto_gm]).to eq({ error: 'gm boom' })
      end
    end
  end

  describe 'log output' do
    it 'logs when cleanups happen' do
      expect { described_class.sweep! }.to output(/\[GameCleanup\] Sweep complete: fights=2/).to_stderr
    end

    it 'does not log when nothing was cleaned' do
      allow(FightCleanupService).to receive(:cleanup_all!).and_return({ cleaned: 0 })
      allow(ActivityCleanupService).to receive(:cleanup_all!).and_return({ cleaned: 0 })
      allow(AutoGm::AutoGmCleanupService).to receive(:cleanup_all!).and_return({ cleaned: 0 })

      expect { described_class.sweep! }.not_to output.to_stdout
    end

    it 'does not log when all services errored' do
      allow(FightCleanupService).to receive(:cleanup_all!).and_raise(StandardError.new('err'))
      allow(ActivityCleanupService).to receive(:cleanup_all!).and_raise(StandardError.new('err'))
      allow(AutoGm::AutoGmCleanupService).to receive(:cleanup_all!).and_raise(StandardError.new('err'))

      # stderr gets the warn messages, stdout should be silent
      expect { described_class.sweep! }.not_to output.to_stdout
    end
  end
end
