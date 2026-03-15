# frozen_string_literal: true

require 'spec_helper'

RSpec.describe UserPermission do
  describe 'associations' do
    it 'belongs to user' do
      expect(described_class.association_reflections[:user]).not_to be_nil
    end

    it 'belongs to target_user' do
      expect(described_class.association_reflections[:target_user]).not_to be_nil
    end

    it 'belongs to display_character' do
      expect(described_class.association_reflections[:display_character]).not_to be_nil
    end
  end

  describe 'constants' do
    it 'defines VISIBILITY_VALUES' do
      expect(described_class::VISIBILITY_VALUES).to include('generic', 'default', 'never', 'favorite', 'always')
    end

    it 'defines OOC_VALUES' do
      expect(described_class::OOC_VALUES).to include('generic', 'yes', 'no', 'ask')
    end

    it 'defines IC_VALUES' do
      expect(described_class::IC_VALUES).to include('generic', 'yes', 'no')
    end

    it 'defines LEAD_FOLLOW_VALUES' do
      expect(described_class::LEAD_FOLLOW_VALUES).to include('generic', 'yes', 'no')
    end

    it 'defines DRESS_STYLE_VALUES' do
      expect(described_class::DRESS_STYLE_VALUES).to include('generic', 'yes', 'no')
    end

    it 'defines CHANNEL_VALUES' do
      expect(described_class::CHANNEL_VALUES).to include('generic', 'yes', 'muted')
    end

    it 'defines GROUP_VALUES' do
      expect(described_class::GROUP_VALUES).to include('generic', 'favored', 'neutral', 'disfavored')
    end
  end

  describe 'instance methods' do
    it 'defines generic?' do
      expect(described_class.instance_methods).to include(:generic?)
    end

    it 'defines content_consent_for' do
      expect(described_class.instance_methods).to include(:content_consent_for)
    end

    it 'defines set_content_consent!' do
      expect(described_class.instance_methods).to include(:set_content_consent!)
    end
  end

  describe 'class methods' do
    it 'defines effective_value' do
      expect(described_class).to respond_to(:effective_value)
    end

    it 'defines generic_for' do
      expect(described_class).to respond_to(:generic_for)
    end

    it 'defines specific_for' do
      expect(described_class).to respond_to(:specific_for)
    end

    it 'defines for_users' do
      expect(described_class).to respond_to(:for_users)
    end

    it 'defines can_see_in_where?' do
      expect(described_class).to respond_to(:can_see_in_where?)
    end

    it 'defines ooc_permission' do
      expect(described_class).to respond_to(:ooc_permission)
    end

    it 'defines ic_allowed?' do
      expect(described_class).to respond_to(:ic_allowed?)
    end

    it 'defines lead_follow_allowed?' do
      expect(described_class).to respond_to(:lead_follow_allowed?)
    end

    it 'defines dress_style_allowed?' do
      expect(described_class).to respond_to(:dress_style_allowed?)
    end

    it 'defines channel_visible?' do
      expect(described_class).to respond_to(:channel_visible?)
    end

    it 'defines mutual_content_consents' do
      expect(described_class).to respond_to(:mutual_content_consents)
    end

    it 'defines all_specific_for' do
      expect(described_class).to respond_to(:all_specific_for)
    end
  end

  describe '#generic? behavior' do
    it 'returns true when target_user_id is nil' do
      permission = described_class.new
      permission.values[:target_user_id] = nil
      expect(permission.generic?).to be true
    end

    it 'returns false when target_user_id is set' do
      permission = described_class.new
      permission.values[:target_user_id] = 123
      expect(permission.generic?).to be false
    end
  end

  describe 'content consent resolution' do
    let(:user) { create(:user) }
    let(:target_user) { create(:user) }

    it 'defaults generic row consent to no' do
      perm = described_class.generic_for(user)
      expect(perm.content_consent_for('VIOLENCE')).to eq('no')
    end

    it 'defaults specific row consent to generic' do
      perm = described_class.specific_for(user, target_user)
      expect(perm.content_consent_for('VIOLENCE')).to eq('generic')
    end

    it 'prefers specific consent over generic fallback' do
      generic = described_class.generic_for(user)
      generic.set_content_consent!('VIOLENCE', 'no')

      specific = described_class.specific_for(user, target_user)
      specific.set_content_consent!('VIOLENCE', 'yes')

      expect(described_class.effective_content_consent(user, target_user, 'VIOLENCE')).to eq('yes')
    end
  end
end
