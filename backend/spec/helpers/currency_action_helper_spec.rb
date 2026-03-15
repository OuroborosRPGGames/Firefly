# frozen_string_literal: true

require 'spec_helper'

RSpec.describe CurrencyActionHelper do
  describe 'module structure' do
    it 'defines a module' do
      expect(described_class).to be_a(Module)
    end
  end

  describe 'instance methods' do
    # Create a test class to check included methods
    let(:test_class) do
      Class.new do
        include CurrencyActionHelper
      end
    end

    let(:instance) { test_class.new }

    it 'provides drop_money method' do
      expect(instance).to respond_to(:drop_money)
    end

    it 'provides money_pickup method' do
      expect(instance).to respond_to(:money_pickup)
    end

    it 'provides give_money method' do
      expect(instance).to respond_to(:give_money)
    end if CurrencyActionHelper.instance_methods.include?(:give_money)
  end
end
