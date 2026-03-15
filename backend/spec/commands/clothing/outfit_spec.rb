# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Clothing::Outfit, type: :command do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area) }
  let(:room) { create(:room, location: location) }
  let(:reality) { create(:reality) }
  let(:character) { create(:character, forename: 'Alice') }
  let(:character_instance) { create(:character_instance, character: character, current_room: room, reality: reality, online: true) }

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    describe 'outfit list (or just outfit)' do
      context 'with no saved outfits' do
        it 'shows empty message' do
          result = command.execute('outfit')

          expect(result[:success]).to be true
          expect(result[:message]).to match(/no saved outfits/i)
        end

        it 'shows empty message with list subcommand' do
          result = command.execute('outfit list')

          expect(result[:success]).to be true
          expect(result[:message]).to match(/no saved outfits/i)
        end
      end

      context 'with saved outfits' do
        before do
          Outfit.create(
            character_instance: character_instance,
            name: 'Casual',
            description: 'Everyday wear'
          )
          Outfit.create(
            character_instance: character_instance,
            name: 'Formal',
            description: 'For special occasions'
          )
        end

        it 'lists all outfits' do
          result = command.execute('outfit list')

          expect(result[:success]).to be true
          expect(result[:message]).to include('Casual')
          expect(result[:message]).to include('Formal')
        end

        it 'returns outfit data' do
          result = command.execute('outfit')

          expect(result[:data][:action]).to eq('list')
          expect(result[:data][:outfits].length).to eq(2)
        end
      end
    end

    describe 'outfit save <name>' do
      context 'with worn items' do
        let!(:shirt) do
          Item.create(
            name: 'Blue Shirt',
            character_instance: character_instance,
            quantity: 1,
            condition: 'good',
            is_clothing: true,
            worn: true
          )
        end

        let!(:pants) do
          Item.create(
            name: 'Black Pants',
            character_instance: character_instance,
            quantity: 1,
            condition: 'good',
            is_clothing: true,
            worn: true
          )
        end

        it 'saves current worn items as outfit' do
          result = command.execute('outfit save Work Clothes')

          expect(result[:success]).to be true
          expect(result[:message]).to include('Work Clothes')
          expect(result[:message]).to include('saved')

          outfit = Outfit.first(name: 'Work Clothes')
          expect(outfit).not_to be_nil
          expect(outfit.character_instance_id).to eq(character_instance.id)
        end

        it 'returns save data' do
          result = command.execute('outfit save My Style')

          expect(result[:data][:action]).to eq('save')
          expect(result[:data][:outfit_name]).to eq('My Style')
          expect(result[:data][:item_count]).to eq(2)
        end
      end

      context 'with no worn items' do
        it 'returns error' do
          result = command.execute('outfit save Empty')

          expect(result[:success]).to be false
          expect(result[:error]).to match(/aren't wearing anything/i)
        end
      end

      context 'with no name provided' do
        it 'returns error' do
          result = command.execute('outfit save')

          expect(result[:success]).to be false
          expect(result[:error]).to match(/name/i)
        end
      end

      context 'with duplicate name' do
        before do
          Outfit.create(
            character_instance: character_instance,
            name: 'Existing',
            description: 'Already exists'
          )
        end

        let!(:shirt) do
          Item.create(
            name: 'Shirt',
            character_instance: character_instance,
            quantity: 1,
            condition: 'good',
            is_clothing: true,
            worn: true
          )
        end

        it 'overwrites existing outfit' do
          result = command.execute('outfit save Existing')

          expect(result[:success]).to be true
          expect(result[:message]).to include('updated')
        end
      end
    end

    describe 'outfit wear <name>' do
      let!(:casual_outfit) do
        Outfit.create(
          character_instance: character_instance,
          name: 'Casual',
          description: 'Everyday wear'
        )
      end

      context 'with valid outfit name' do
        it 'applies the outfit' do
          result = command.execute('outfit wear Casual')

          expect(result[:success]).to be true
          expect(result[:message]).to include('Casual')
        end

        it 'returns wear data' do
          result = command.execute('outfit wear Casual')

          expect(result[:data][:action]).to eq('wear')
          expect(result[:data][:outfit_name]).to eq('Casual')
        end
      end

      context 'with non-existent outfit' do
        it 'returns error' do
          result = command.execute('outfit wear NonExistent')

          expect(result[:success]).to be false
          expect(result[:error]).to match(/don't have.*outfit/i)
        end
      end

      context 'with no name provided' do
        it 'returns error' do
          result = command.execute('outfit wear')

          expect(result[:success]).to be false
          expect(result[:error]).to match(/which outfit/i)
        end
      end

      context 'with a piercing item in the outfit' do
        let!(:piercing_uot) { create(:unified_object_type, category: 'Piercing') }
        let!(:piercing_pattern) { create(:pattern, unified_object_type: piercing_uot, description: 'Silver Stud') }
        let!(:piercing_outfit) do
          Outfit.create(
            character_instance: character_instance,
            name: 'PiercingSet',
            outfit_class: 'jewelry'
          )
        end

        before do
          OutfitItem.create(outfit: piercing_outfit, pattern: piercing_pattern, display_order: 0)
        end

        it 'returns an error when no pierced positions exist' do
          result = command.execute('outfit wear PiercingSet')

          expect(result[:success]).to be false
          expect(result[:error]).to include('piercing holes')
          expect(character_instance.objects_dataset.where(is_piercing: true, worn: true).count).to eq(0)
        end

        it 'auto-wears the piercing when exactly one pierced position exists' do
          character_instance.add_piercing_position!('left ear')

          result = command.execute('outfit wear PiercingSet')

          expect(result[:success]).to be true
          piercing = character_instance.objects_dataset.where(is_piercing: true, worn: true).first
          expect(piercing).not_to be_nil
          expect(piercing.piercing_position).to eq('left ear')
        end
      end
    end

    describe 'outfit delete <name>' do
      let!(:outfit_to_delete) do
        Outfit.create(
          character_instance: character_instance,
          name: 'ToDelete',
          description: 'Will be deleted'
        )
      end

      context 'with valid outfit name' do
        it 'deletes the outfit' do
          result = command.execute('outfit delete ToDelete')

          expect(result[:success]).to be true
          expect(result[:message]).to include('deleted')

          expect(Outfit.first(name: 'ToDelete')).to be_nil
        end

        it 'returns delete data' do
          result = command.execute('outfit delete ToDelete')

          expect(result[:data][:action]).to eq('delete')
          expect(result[:data][:outfit_name]).to eq('ToDelete')
        end
      end

      context 'with non-existent outfit' do
        it 'returns error' do
          result = command.execute('outfit delete NonExistent')

          expect(result[:success]).to be false
          expect(result[:error]).to match(/don't have.*outfit/i)
        end
      end

      context 'with no name provided' do
        it 'returns error' do
          result = command.execute('outfit delete')

          expect(result[:success]).to be false
          expect(result[:error]).to match(/which outfit/i)
        end
      end
    end

    describe 'with aliases' do
      it 'works with outfits alias' do
        result = command.execute('outfits')

        expect(result[:success]).to be true
      end
    end

    describe 'outfit class functionality' do
      let!(:shirt) do
        Item.create(
          name: 'Blue Shirt',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good',
          is_clothing: true,
          worn: true
        )
      end

      let!(:pants) do
        Item.create(
          name: 'Black Pants',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good',
          is_clothing: true,
          worn: true
        )
      end

      let!(:ring) do
        Item.create(
          name: 'Gold Ring',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good',
          is_jewelry: true,
          worn: true
        )
      end

      describe 'outfit save with class' do
        it 'saves outfit with default full class' do
          result = command.execute('outfit save Work Clothes')

          expect(result[:success]).to be true
          outfit = Outfit.first(name: 'Work Clothes')
          expect(outfit.outfit_class).to eq('full')
        end

        it 'saves outfit with specified class' do
          result = command.execute('outfit save Tops top')

          expect(result[:success]).to be true
          expect(result[:data][:outfit_class]).to eq('top')
          outfit = Outfit.first(name: 'Tops')
          expect(outfit.outfit_class).to eq('top')
        end

        it 'saves outfit with jewelry class' do
          result = command.execute('outfit save Jewels jewelry')

          expect(result[:success]).to be true
          outfit = Outfit.first(name: 'Jewels')
          expect(outfit.outfit_class).to eq('jewelry')
        end

        it 'updates existing outfit with new class' do
          command.execute('outfit save Style full')
          result = command.execute('outfit save Style top')

          expect(result[:success]).to be true
          expect(result[:message]).to include('updated')
          outfit = Outfit.first(name: 'Style')
          expect(outfit.outfit_class).to eq('top')
        end
      end

      describe 'outfit list with classes' do
        before do
          Outfit.create(
            character_instance: character_instance,
            name: 'FullOutfit',
            outfit_class: 'full'
          )
          Outfit.create(
            character_instance: character_instance,
            name: 'TopOnly',
            outfit_class: 'top'
          )
        end

        it 'shows class for non-full outfits' do
          result = command.execute('outfit list')

          expect(result[:success]).to be true
          expect(result[:message]).to include('[top]')
        end

        it 'returns outfit_class in data' do
          result = command.execute('outfit list')

          outfit_data = result[:data][:outfits]
          top_outfit = outfit_data.find { |o| o[:name] == 'TopOnly' }
          expect(top_outfit[:outfit_class]).to eq('top')
        end
      end

      describe 'outfit wear with classes' do
        let!(:existing_shirt) do
          Item.create(
            name: 'Old Shirt',
            character_instance: character_instance,
            quantity: 1,
            condition: 'good',
            is_clothing: true,
            worn: true
          )
        end

        let!(:existing_hat) do
          Item.create(
            name: 'Red Hat',
            character_instance: character_instance,
            quantity: 1,
            condition: 'good',
            is_clothing: true,
            worn: true
          )
        end

        context 'with full class outfit' do
          before do
            Outfit.create(
              character_instance: character_instance,
              name: 'FullOutfit',
              outfit_class: 'full'
            )
          end

          it 'removes all worn items' do
            result = command.execute('outfit wear FullOutfit')

            expect(result[:success]).to be true
            expect(existing_shirt.reload.worn).to be false
            expect(existing_hat.reload.worn).to be false
          end
        end

        context 'with top class outfit' do
          let!(:top_outfit) do
            Outfit.create(
              character_instance: character_instance,
              name: 'TopOutfit',
              outfit_class: 'top'
            )
          end

          let!(:top_pattern) { create(:pattern, description: 'New Shirt') }

          before do
            OutfitItem.create(outfit: top_outfit, pattern: top_pattern, display_order: 0)
          end

          it 'removes only top items' do
            result = command.execute('outfit wear TopOutfit')

            expect(result[:success]).to be true
            # Shirt should be removed (it's a top)
            expect(existing_shirt.reload.worn).to be false
            # Hat should remain (it's an accessory, not a top)
            expect(existing_hat.reload.worn).to be true
          end

          it 'shows replacing message' do
            result = command.execute('outfit wear TopOutfit')

            expect(result[:message]).to include('replacing top items')
          end
        end

        context 'with other class outfit (additive)' do
          let!(:additive_outfit) do
            Outfit.create(
              character_instance: character_instance,
              name: 'AdditiveOutfit',
              outfit_class: 'other'
            )
          end

          let!(:other_pattern) { create(:pattern, description: 'Accessory') }

          before do
            OutfitItem.create(outfit: additive_outfit, pattern: other_pattern, display_order: 0)
          end

          it 'keeps all worn items' do
            result = command.execute('outfit wear AdditiveOutfit')

            expect(result[:success]).to be true
            expect(existing_shirt.reload.worn).to be true
            expect(existing_hat.reload.worn).to be true
          end

          it 'shows keeping message' do
            result = command.execute('outfit wear AdditiveOutfit')

            expect(result[:message]).to include('keeping existing items')
          end
        end

        context 'with jewelry class outfit' do
          let!(:existing_ring) do
            Item.create(
              name: 'Old Ring',
              character_instance: character_instance,
              quantity: 1,
              condition: 'good',
              is_jewelry: true,
              worn: true
            )
          end

          before do
            Outfit.create(
              character_instance: character_instance,
              name: 'JewelryOutfit',
              outfit_class: 'jewelry'
            )
          end

          it 'removes only jewelry items' do
            result = command.execute('outfit wear JewelryOutfit')

            expect(result[:success]).to be true
            # Ring should be removed (it's jewelry)
            expect(existing_ring.reload.worn).to be false
            # Clothing should remain
            expect(existing_shirt.reload.worn).to be true
            expect(existing_hat.reload.worn).to be true
          end
        end
      end
    end
  end
end
