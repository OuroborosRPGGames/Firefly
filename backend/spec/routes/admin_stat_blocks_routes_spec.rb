# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Admin Stat Blocks Routes', type: :request do
  let(:admin) { create(:user, :admin) }
  let(:stat_block) { create(:stat_block) }

  before do
    env 'rack.session', { 'user_id' => admin.id }
  end

  describe 'GET /admin/stat_blocks' do
    it_behaves_like 'requires admin', '/admin/stat_blocks'

    it 'lists stat blocks' do
      stat_block # create
      get '/admin/stat_blocks'
      expect(last_response).to be_ok
    end
  end

  describe 'GET /admin/stat_blocks/new' do
    it 'renders new stat block form' do
      get '/admin/stat_blocks/new'
      expect(last_response).to be_ok
    end
  end

  describe 'GET /admin/stat_blocks/:id' do
    it 'renders edit form for existing stat block' do
      get "/admin/stat_blocks/#{stat_block.id}"
      expect(last_response).to be_ok
    end

    it 'redirects for non-existent stat block' do
      get '/admin/stat_blocks/999999'
      expect(last_response).to be_redirect
      expect(last_response.location).to include('/admin/stat_blocks')
    end
  end

  describe 'POST /admin/stat_blocks/:id' do
    it 'updates stat block' do
      post "/admin/stat_blocks/#{stat_block.id}", {
        name: 'Updated Name',
        description: 'Updated description',
        block_type: stat_block.block_type, # Keep valid block type
        total_points: 100,
        secondary_points: 50,
        min_stat_value: 1,
        max_stat_value: 10,
        cost_formula: stat_block.cost_formula, # Keep valid formula
        primary_label: 'Attributes',
        secondary_label: 'Skills',
        is_active: 'on'
      }

      expect(last_response).to be_redirect
      expect(stat_block.reload.name).to eq('Updated Name')
    end
  end

  describe 'POST /admin/stat_blocks/:id/set_default' do
    it 'sets stat block as default' do
      post "/admin/stat_blocks/#{stat_block.id}/set_default"
      expect(last_response).to be_redirect
      expect(stat_block.reload.is_default).to be true
    end
  end

  describe 'POST /admin/stat_blocks/:id/delete' do
    it 'deletes stat block' do
      stat_block_id = stat_block.id
      post "/admin/stat_blocks/#{stat_block_id}/delete"
      expect(last_response).to be_redirect
      expect(StatBlock[stat_block_id]).to be_nil
    end
  end
end
