# frozen_string_literal: true

require 'spec_helper'

return unless DB.table_exists?(:delve_battle_map_templates)

RSpec.describe DelveBattleMapTemplate do
  describe '.find_by_combo' do
    it 'returns nil when no template exists' do
      expect(described_class.find_by_combo('corridor:ns')).to be_nil
    end

    it 'returns the template when it exists' do
      template = described_class.create(
        combo_key: 'corridor:ns',
        hex_data: Sequel.pg_jsonb_wrap([{ hex_x: 0, hex_y: 0, hex_type: 'normal' }]),
        last_used_at: Time.now
      )

      found = described_class.find_by_combo('corridor:ns')
      expect(found).not_to be_nil
      expect(found.id).to eq(template.id)
    end
  end

  describe '.cache_hex_data!' do
    let(:hex_data) { [{ 'hex_x' => 0, 'hex_y' => 0, 'hex_type' => 'normal' }] }

    context 'when no template exists for the combo key' do
      it 'creates a new template' do
        expect {
          described_class.cache_hex_data!('l_turn:ne', hex_data: hex_data)
        }.to change { described_class.count }.by(1)
      end

      it 'stores the hex data' do
        template = described_class.cache_hex_data!('l_turn:ne', hex_data: hex_data)
        template.reload

        # Sequel wraps JSONB arrays as Sequel::Postgres::JSONBArray; treat it as array-like
        expect(template.hex_data.to_a).to be_an(Array)
        expect(template.hex_data.first['hex_type']).to eq('normal')
      end

      it 'stores optional background_url' do
        template = described_class.cache_hex_data!(
          'corridor:ns',
          hex_data: hex_data,
          background_url: 'https://example.com/bg.png'
        )

        expect(template.background_url).to eq('https://example.com/bg.png')
      end

      it 'stores background_contrast with default dark' do
        template = described_class.cache_hex_data!('corridor:ns', hex_data: hex_data)
        expect(template.background_contrast).to eq('dark')
      end

      it 'stores custom background_contrast' do
        template = described_class.cache_hex_data!(
          'corridor:ns',
          hex_data: hex_data,
          background_contrast: 'light'
        )
        expect(template.background_contrast).to eq('light')
      end

      it 'sets last_used_at' do
        template = described_class.cache_hex_data!('corridor:ns', hex_data: hex_data)
        expect(template.last_used_at).not_to be_nil
      end
    end

    context 'when a template already exists for the combo key' do
      let!(:existing) do
        described_class.create(
          combo_key: 'corridor:ns',
          hex_data: Sequel.pg_jsonb_wrap([{ 'hex_x' => 0, 'hex_y' => 0, 'hex_type' => 'wall' }]),
          last_used_at: Time.now - 3600
        )
      end

      it 'does not create a new record' do
        expect {
          described_class.cache_hex_data!('corridor:ns', hex_data: hex_data)
        }.not_to change { described_class.count }
      end

      it 'updates the hex data' do
        described_class.cache_hex_data!('corridor:ns', hex_data: hex_data)
        existing.reload

        expect(existing.hex_data.first['hex_type']).to eq('normal')
      end

      it 'updates last_used_at' do
        old_time = existing.last_used_at
        described_class.cache_hex_data!('corridor:ns', hex_data: hex_data)
        existing.reload

        expect(existing.last_used_at).to be > old_time
      end

      it 'updates background_url' do
        described_class.cache_hex_data!(
          'corridor:ns',
          hex_data: hex_data,
          background_url: 'https://example.com/new.png'
        )
        existing.reload

        expect(existing.background_url).to eq('https://example.com/new.png')
      end
    end
  end

  describe '#touch!' do
    it 'updates last_used_at to current time' do
      template = described_class.create(
        combo_key: 'crossroads:nesw',
        hex_data: Sequel.pg_jsonb_wrap([]),
        last_used_at: Time.now - 7200
      )

      old_time = template.last_used_at
      template.touch!
      template.reload

      expect(template.last_used_at).to be > old_time
    end
  end

  describe 'unique constraint on combo_key' do
    it 'prevents duplicate combo keys' do
      described_class.create(
        combo_key: 'dead_end:n',
        hex_data: Sequel.pg_jsonb_wrap([]),
        last_used_at: Time.now
      )

      expect {
        described_class.create(
          combo_key: 'dead_end:n',
          hex_data: Sequel.pg_jsonb_wrap([]),
          last_used_at: Time.now
        )
      }.to raise_error(Sequel::UniqueConstraintViolation)
    end
  end
end
