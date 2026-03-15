# frozen_string_literal: true

require 'spec_helper'

RSpec.describe DescriptionCopyService do
  let(:character) { instance_double('Character', id: 1) }
  let(:instance) { instance_double('CharacterInstance', id: 100) }
  let(:body_position) { instance_double('BodyPosition', id: 10) }

  let(:default_descriptions_dataset) { double('Dataset') }

  before do
    allow(character).to receive(:default_descriptions_dataset).and_return(default_descriptions_dataset)
    allow(DB).to receive(:transaction).and_yield
  end

  describe '.sync_on_login' do
    context 'with invalid inputs' do
      it 'returns error for nil character' do
        result = described_class.sync_on_login(nil, instance)

        expect(result[:success]).to be false
        expect(result[:error]).to eq('Invalid character')
      end

      it 'returns error for nil instance' do
        result = described_class.sync_on_login(character, nil)

        expect(result[:success]).to be false
        expect(result[:error]).to eq('Invalid instance')
      end
    end

    context 'with no default descriptions' do
      before do
        allow(default_descriptions_dataset).to receive(:where).with(active: true).and_return([])
      end

      it 'returns success with zero counts' do
        result = described_class.sync_on_login(character, instance)

        expect(result[:success]).to be true
        expect(result[:copied]).to eq(0)
        expect(result[:updated]).to eq(0)
        expect(result[:skipped]).to eq(0)
        expect(result[:total]).to eq(0)
      end
    end

    context 'with descriptions to copy' do
      let(:default_desc) do
        instance_double('DefaultDescription',
          body_position_id: 10,
          content: 'A detailed description',
          image_url: 'http://example.com/image.jpg',
          concealed_by_clothing: false,
          display_order: 1,
          description_type: 'natural',
          body_positions: []
        )
      end

      let(:created_desc) do
        instance_double('CharacterDescription',
          id: 200,
          body_positions: []
        )
      end

      before do
        allow(default_descriptions_dataset).to receive(:where).with(active: true).and_return([default_desc])
      end

      context 'when no existing description' do
        before do
          allow(CharacterDescription).to receive(:first).with(
            character_instance_id: 100,
            body_position_id: 10,
            aesthetic_type: 'natural'
          ).and_return(nil)
          allow(CharacterDescription).to receive(:create).and_return(created_desc)
        end

        it 'creates new description' do
          expect(CharacterDescription).to receive(:create).with(
            character_instance_id: 100,
            body_position_id: 10,
            content: 'A detailed description',
            image_url: 'http://example.com/image.jpg',
            concealed_by_clothing: false,
            display_order: 1,
            aesthetic_type: 'natural',
            active: true
          ).and_return(created_desc)

          described_class.sync_on_login(character, instance)
        end

        it 'returns copied count of 1' do
          result = described_class.sync_on_login(character, instance)

          expect(result[:success]).to be true
          expect(result[:copied]).to eq(1)
          expect(result[:updated]).to eq(0)
          expect(result[:skipped]).to eq(0)
        end
      end

      context 'when existing description with same content' do
        let(:existing_desc) do
          instance_double('CharacterDescription',
            content: 'A detailed description',
            image_url: 'http://example.com/image.jpg',
            concealed_by_clothing: false,
            display_order: 1,
            aesthetic_type: 'natural',
            body_positions: []
          )
        end

        before do
          allow(CharacterDescription).to receive(:first).with(
            character_instance_id: 100,
            body_position_id: 10,
            aesthetic_type: 'natural'
          ).and_return(existing_desc)
        end

        it 'skips update' do
          expect(existing_desc).not_to receive(:update)

          described_class.sync_on_login(character, instance)
        end

        it 'returns skipped count of 1' do
          result = described_class.sync_on_login(character, instance)

          expect(result[:success]).to be true
          expect(result[:copied]).to eq(0)
          expect(result[:updated]).to eq(0)
          expect(result[:skipped]).to eq(1)
        end
      end

      context 'when existing description with different content' do
        let(:existing_desc) do
          instance_double('CharacterDescription',
            id: 200,
            content: 'Old description',
            image_url: 'http://example.com/old.jpg',
            concealed_by_clothing: true,
            display_order: 0,
            aesthetic_type: 'natural',
            body_positions: []
          )
        end

        before do
          allow(CharacterDescription).to receive(:first).with(
            character_instance_id: 100,
            body_position_id: 10,
            aesthetic_type: 'natural'
          ).and_return(existing_desc)
          allow(existing_desc).to receive(:update)
          # sync_positions mock
          allow(CharacterInstanceDescriptionPosition).to receive(:where).and_return(double(delete: 0))
        end

        it 'updates description' do
          expect(existing_desc).to receive(:update).with(
            content: 'A detailed description',
            image_url: 'http://example.com/image.jpg',
            concealed_by_clothing: false,
            display_order: 1,
            aesthetic_type: 'natural',
            active: true
          )

          described_class.sync_on_login(character, instance)
        end

        it 'returns updated count of 1' do
          result = described_class.sync_on_login(character, instance)

          expect(result[:success]).to be true
          expect(result[:copied]).to eq(0)
          expect(result[:updated]).to eq(1)
          expect(result[:skipped]).to eq(0)
        end
      end
    end

    context 'with multiple descriptions' do
      let(:desc1) do
        instance_double('DefaultDescription',
          body_position_id: 10,
          content: 'First desc',
          image_url: nil,
          concealed_by_clothing: false,
          display_order: 1,
          description_type: 'natural',
          body_positions: []
        )
      end

      let(:desc2) do
        instance_double('DefaultDescription',
          body_position_id: 20,
          content: 'Second desc',
          image_url: nil,
          concealed_by_clothing: true,
          display_order: 2,
          description_type: 'natural',
          body_positions: []
        )
      end

      let(:desc3) do
        instance_double('DefaultDescription',
          body_position_id: 30,
          content: 'Third desc',
          image_url: nil,
          concealed_by_clothing: false,
          display_order: 3,
          description_type: 'natural',
          body_positions: []
        )
      end

      let(:existing_desc) do
        instance_double('CharacterDescription',
          id: 300,
          content: 'Third desc',
          image_url: nil,
          concealed_by_clothing: false,
          display_order: 3,
          aesthetic_type: 'natural',
          body_positions: []
        )
      end

      let(:created_desc) do
        instance_double('CharacterDescription', id: 400, body_positions: [])
      end

      before do
        allow(default_descriptions_dataset).to receive(:where).with(active: true).and_return([desc1, desc2, desc3])
        allow(CharacterDescription).to receive(:first).with(
          character_instance_id: 100, body_position_id: 10, aesthetic_type: 'natural'
        ).and_return(nil)
        allow(CharacterDescription).to receive(:first).with(
          character_instance_id: 100, body_position_id: 20, aesthetic_type: 'natural'
        ).and_return(nil)
        allow(CharacterDescription).to receive(:first).with(
          character_instance_id: 100, body_position_id: 30, aesthetic_type: 'natural'
        ).and_return(existing_desc)
        allow(CharacterDescription).to receive(:create).and_return(created_desc)
      end

      it 'processes all descriptions' do
        result = described_class.sync_on_login(character, instance)

        expect(result[:total]).to eq(3)
        expect(result[:copied]).to eq(2)
        expect(result[:skipped]).to eq(1)
      end
    end
  end

  describe '.sync_single' do
    context 'with invalid inputs' do
      it 'returns error for nil character' do
        result = described_class.sync_single(nil, instance, 10)

        expect(result[:success]).to be false
        expect(result[:error]).to eq('Invalid character')
      end

      it 'returns error for nil instance' do
        result = described_class.sync_single(character, nil, 10)

        expect(result[:success]).to be false
        expect(result[:error]).to eq('Invalid instance')
      end
    end

    context 'when description not found' do
      before do
        allow(default_descriptions_dataset).to receive(:first).with(
          id: 10,
          active: true
        ).and_return(nil)
      end

      it 'returns error' do
        result = described_class.sync_single(character, instance, 10)

        expect(result[:success]).to be false
        expect(result[:error]).to eq('Description not found')
      end
    end

    context 'when creating new description' do
      let(:default_desc) do
        instance_double('DefaultDescription',
          body_position_id: 10,
          content: 'New content',
          image_url: 'http://example.com/new.jpg',
          concealed_by_clothing: false,
          display_order: 1,
          description_type: 'natural',
          body_positions: []
        )
      end

      let(:created_desc) do
        instance_double('CharacterDescription', id: 200, body_positions: [])
      end

      before do
        allow(default_descriptions_dataset).to receive(:first).with(
          id: 10,
          active: true
        ).and_return(default_desc)
        allow(CharacterDescription).to receive(:first).with(
          character_instance_id: 100,
          body_position_id: 10,
          aesthetic_type: 'natural'
        ).and_return(nil)
        allow(CharacterDescription).to receive(:create).and_return(created_desc)
      end

      it 'creates description' do
        expect(CharacterDescription).to receive(:create).and_return(created_desc)

        described_class.sync_single(character, instance, 10)
      end

      it 'returns created action' do
        result = described_class.sync_single(character, instance, 10)

        expect(result[:success]).to be true
        expect(result[:action]).to eq(:created)
      end
    end

    context 'when updating existing description' do
      let(:default_desc) do
        instance_double('DefaultDescription',
          body_position_id: 10,
          content: 'Updated content',
          image_url: nil,
          concealed_by_clothing: true,
          display_order: 2,
          description_type: 'natural',
          body_positions: []
        )
      end

      let(:existing_desc) do
        instance_double('CharacterDescription',
          id: 200,
          body_positions: []
        )
      end

      before do
        allow(default_descriptions_dataset).to receive(:first).with(
          id: 10,
          active: true
        ).and_return(default_desc)
        allow(CharacterDescription).to receive(:first).with(
          character_instance_id: 100,
          body_position_id: 10,
          aesthetic_type: 'natural'
        ).and_return(existing_desc)
        allow(existing_desc).to receive(:update)
        # sync_positions mock
        allow(CharacterInstanceDescriptionPosition).to receive(:where).and_return(double(delete: 0))
      end

      it 'updates description' do
        expect(existing_desc).to receive(:update).with(
          content: 'Updated content',
          image_url: nil,
          concealed_by_clothing: true,
          display_order: 2,
          aesthetic_type: 'natural',
          active: true
        )

        described_class.sync_single(character, instance, 10)
      end

      it 'returns updated action' do
        result = described_class.sync_single(character, instance, 10)

        expect(result[:success]).to be true
        expect(result[:action]).to eq(:updated)
      end
    end
  end

  describe '.cleanup_orphaned' do
    context 'with invalid inputs' do
      it 'returns 0 for nil character' do
        result = described_class.cleanup_orphaned(nil, instance)

        expect(result).to eq(0)
      end

      it 'returns 0 for nil instance' do
        result = described_class.cleanup_orphaned(character, nil)

        expect(result).to eq(0)
      end
    end

    context 'with orphaned descriptions' do
      let(:orphaned_dataset) { double('Dataset') }
      let(:orphaned_desc) { instance_double('CharacterDescription', id: 500) }

      before do
        allow(default_descriptions_dataset).to receive(:where).with(active: true).and_return(default_descriptions_dataset)
        allow(default_descriptions_dataset).to receive(:select_map).with(:id).and_return([1, 2])
        allow(default_descriptions_dataset).to receive(:exclude).with(body_position_id: nil).and_return(default_descriptions_dataset)
        allow(default_descriptions_dataset).to receive(:select_map).with(:body_position_id).and_return([10, 20])
        allow(CharacterDescription).to receive(:where).with(character_instance_id: 100).and_return(orphaned_dataset)
        allow(orphaned_dataset).to receive(:exclude).with(body_position_id: nil).and_return(orphaned_dataset)
        allow(orphaned_dataset).to receive(:exclude).with(body_position_id: [10, 20]).and_return(orphaned_dataset)
        allow(orphaned_dataset).to receive(:count).and_return(3)
        allow(orphaned_dataset).to receive(:each).and_yield(orphaned_desc).and_yield(orphaned_desc).and_yield(orphaned_desc)
        allow(CharacterInstanceDescriptionPosition).to receive(:where).with(character_description_id: 500).and_return(double(delete: 0))
        allow(orphaned_desc).to receive(:delete)
      end

      it 'deletes orphaned descriptions' do
        expect(orphaned_desc).to receive(:delete).exactly(3).times

        described_class.cleanup_orphaned(character, instance)
      end

      it 'returns count of deleted descriptions' do
        result = described_class.cleanup_orphaned(character, instance)

        expect(result).to eq(3)
      end
    end

    context 'with no orphaned descriptions' do
      let(:orphaned_dataset) { double('Dataset') }

      before do
        allow(default_descriptions_dataset).to receive(:where).with(active: true).and_return(default_descriptions_dataset)
        allow(default_descriptions_dataset).to receive(:select_map).with(:id).and_return([1, 2, 3])
        allow(default_descriptions_dataset).to receive(:exclude).with(body_position_id: nil).and_return(default_descriptions_dataset)
        allow(default_descriptions_dataset).to receive(:select_map).with(:body_position_id).and_return([10, 20, 30])
        allow(CharacterDescription).to receive(:where).with(character_instance_id: 100).and_return(orphaned_dataset)
        allow(orphaned_dataset).to receive(:exclude).with(body_position_id: nil).and_return(orphaned_dataset)
        allow(orphaned_dataset).to receive(:exclude).with(body_position_id: [10, 20, 30]).and_return(orphaned_dataset)
        allow(orphaned_dataset).to receive(:count).and_return(0)
        allow(orphaned_dataset).to receive(:each)
      end

      it 'returns 0' do
        result = described_class.cleanup_orphaned(character, instance)

        expect(result).to eq(0)
      end
    end
  end

  describe 'position syncing' do
    describe '.sync_positions (via update_description)' do
      let(:default_desc) do
        instance_double('DefaultDescription',
          body_position_id: 10,
          content: 'Updated content',
          image_url: nil,
          concealed_by_clothing: false,
          display_order: 1,
          description_type: 'natural',
          body_positions: [body_position, body_position_2]
        )
      end

      let(:body_position_2) { instance_double('BodyPosition', id: 20) }
      let(:body_position_3) { instance_double('BodyPosition', id: 30) }

      let(:existing_desc) do
        instance_double('CharacterDescription',
          id: 200,
          content: 'Old content',
          image_url: nil,
          concealed_by_clothing: false,
          display_order: 1,
          aesthetic_type: 'natural',
          body_positions: [body_position]
        )
      end

      before do
        allow(default_descriptions_dataset).to receive(:where).with(active: true).and_return([default_desc])
        allow(CharacterDescription).to receive(:first).with(
          character_instance_id: 100,
          body_position_id: 10,
          aesthetic_type: 'natural'
        ).and_return(existing_desc)
        allow(existing_desc).to receive(:update)
      end

      it 'adds new positions that are not in current' do
        # Existing has position 10, default has 10 and 20
        # Should add position 20
        # Note: sync_positions only calls where/delete when to_remove.any? is true
        # Since existing has [10] and target has [10, 20], to_remove is empty

        expect(CharacterInstanceDescriptionPosition).to receive(:create)
          .with(character_description_id: 200, body_position_id: 20)

        described_class.sync_on_login(character, instance)
      end

      it 'removes positions that are not in target' do
        # Existing has positions 10, 30 but default only has 10, 20
        existing_with_extra = instance_double('CharacterDescription',
          id: 200,
          content: 'Old content',
          image_url: nil,
          concealed_by_clothing: false,
          display_order: 1,
          aesthetic_type: 'natural',
          body_positions: [body_position, body_position_3]
        )

        allow(CharacterDescription).to receive(:first).with(
          character_instance_id: 100,
          body_position_id: 10,
          aesthetic_type: 'natural'
        ).and_return(existing_with_extra)
        allow(existing_with_extra).to receive(:update)

        # Should remove position 30 (not in target)
        expect(CharacterInstanceDescriptionPosition).to receive(:where)
          .with(character_description_id: 200, body_position_id: [30])
          .and_return(double(delete: 1))

        # Should add position 20
        expect(CharacterInstanceDescriptionPosition).to receive(:create)
          .with(character_description_id: 200, body_position_id: 20)

        described_class.sync_on_login(character, instance)
      end
    end

    describe '.copy_positions (via create_description)' do
      let(:default_desc) do
        instance_double('DefaultDescription',
          body_position_id: 10,
          content: 'New content',
          image_url: nil,
          concealed_by_clothing: false,
          display_order: 1,
          description_type: 'tattoo',
          body_positions: [body_position, body_position_2, body_position_3]
        )
      end

      let(:body_position_2) { instance_double('BodyPosition', id: 20) }
      let(:body_position_3) { instance_double('BodyPosition', id: 30) }

      let(:created_desc) do
        instance_double('CharacterDescription', id: 300, body_positions: [])
      end

      before do
        allow(default_descriptions_dataset).to receive(:where).with(active: true).and_return([default_desc])
        allow(CharacterDescription).to receive(:first).with(
          character_instance_id: 100,
          body_position_id: 10,
          aesthetic_type: 'tattoo'
        ).and_return(nil)
        allow(CharacterDescription).to receive(:create).and_return(created_desc)
      end

      it 'copies all body positions from default to instance' do
        expect(CharacterInstanceDescriptionPosition).to receive(:create)
          .with(character_description_id: 300, body_position_id: 10)
        expect(CharacterInstanceDescriptionPosition).to receive(:create)
          .with(character_description_id: 300, body_position_id: 20)
        expect(CharacterInstanceDescriptionPosition).to receive(:create)
          .with(character_description_id: 300, body_position_id: 30)

        described_class.sync_on_login(character, instance)
      end
    end

    describe '.positions_differ?' do
      let(:body_position_2) { instance_double('BodyPosition', id: 20) }

      it 'returns false when both have empty positions' do
        existing = instance_double('CharacterDescription',
          content: 'test',
          image_url: nil,
          concealed_by_clothing: false,
          display_order: 1,
          aesthetic_type: 'natural',
          body_positions: []
        )

        default_desc = instance_double('DefaultDescription',
          content: 'test',
          image_url: nil,
          concealed_by_clothing: false,
          display_order: 1,
          description_type: 'natural',
          body_positions: []
        )

        result = described_class.send(:content_differs?, existing, default_desc)
        expect(result).to be false
      end

      it 'returns true when position counts differ' do
        existing = instance_double('CharacterDescription',
          content: 'test',
          image_url: nil,
          concealed_by_clothing: false,
          display_order: 1,
          aesthetic_type: 'natural',
          body_positions: [body_position]
        )

        default_desc = instance_double('DefaultDescription',
          content: 'test',
          image_url: nil,
          concealed_by_clothing: false,
          display_order: 1,
          description_type: 'natural',
          body_positions: [body_position, body_position_2]
        )

        result = described_class.send(:content_differs?, existing, default_desc)
        expect(result).to be true
      end

      it 'returns true when position IDs differ' do
        existing = instance_double('CharacterDescription',
          content: 'test',
          image_url: nil,
          concealed_by_clothing: false,
          display_order: 1,
          aesthetic_type: 'natural',
          body_positions: [body_position]
        )

        default_desc = instance_double('DefaultDescription',
          content: 'test',
          image_url: nil,
          concealed_by_clothing: false,
          display_order: 1,
          description_type: 'natural',
          body_positions: [body_position_2]
        )

        result = described_class.send(:content_differs?, existing, default_desc)
        expect(result).to be true
      end
    end
  end

  describe 'private methods' do
    describe '#content_differs?' do
      let(:body_position_1) { instance_double('BodyPosition', id: 10) }
      let(:body_position_2) { instance_double('BodyPosition', id: 20) }

      let(:existing) do
        instance_double('CharacterDescription',
          content: 'Old content',
          image_url: 'http://example.com/old.jpg',
          concealed_by_clothing: false,
          display_order: 1,
          aesthetic_type: 'natural',
          body_positions: [body_position_1]
        )
      end

      let(:default_desc) do
        instance_double('DefaultDescription',
          content: 'Old content',
          image_url: 'http://example.com/old.jpg',
          concealed_by_clothing: false,
          display_order: 1,
          description_type: 'natural',
          body_positions: [body_position_1]
        )
      end

      it 'returns false when all fields match' do
        result = described_class.send(:content_differs?, existing, default_desc)

        expect(result).to be false
      end

      it 'returns true when content differs' do
        allow(default_desc).to receive(:content).and_return('New content')

        result = described_class.send(:content_differs?, existing, default_desc)

        expect(result).to be true
      end

      it 'returns true when image_url differs' do
        allow(default_desc).to receive(:image_url).and_return('http://example.com/new.jpg')

        result = described_class.send(:content_differs?, existing, default_desc)

        expect(result).to be true
      end

      it 'returns true when concealed_by_clothing differs' do
        allow(default_desc).to receive(:concealed_by_clothing).and_return(true)

        result = described_class.send(:content_differs?, existing, default_desc)

        expect(result).to be true
      end

      it 'returns true when display_order differs' do
        allow(default_desc).to receive(:display_order).and_return(2)

        result = described_class.send(:content_differs?, existing, default_desc)

        expect(result).to be true
      end

      it 'returns true when aesthetic_type differs' do
        allow(default_desc).to receive(:description_type).and_return('tattoo')

        result = described_class.send(:content_differs?, existing, default_desc)

        expect(result).to be true
      end

      it 'returns true when body_positions differ' do
        allow(default_desc).to receive(:body_positions).and_return([body_position_1, body_position_2])

        result = described_class.send(:content_differs?, existing, default_desc)

        expect(result).to be true
      end
    end
  end
end
