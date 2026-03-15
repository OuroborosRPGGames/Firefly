# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ResultHandler do
  # Test class using extend (class methods)
  let(:extended_service) do
    Class.new do
      extend ResultHandler

      def self.successful_operation
        success('Operation completed', data: { id: 123 })
      end

      def self.failed_operation
        error('Something went wrong', data: { code: 'ERR001' })
      end

      def self.simple_success
        success('Done')
      end

      def self.simple_error
        error('Failed')
      end
    end
  end

  # Test class using include (instance methods)
  let(:included_service) do
    Class.new do
      include ResultHandler

      def successful_operation
        success('Operation completed', data: { id: 456 })
      end

      def failed_operation
        error('Something went wrong')
      end
    end
  end

  describe 'ResultHandler::Result' do
    subject(:result) { ResultHandler::Result.new(success: true, message: 'Test', data: { key: 'value' }) }

    describe '#success?' do
      it 'returns true when success is true' do
        expect(result.success?).to be true
      end

      it 'returns false when success is false' do
        failure = ResultHandler::Result.new(success: false, message: 'Failed')
        expect(failure.success?).to be false
      end

      it 'returns false when success is nil' do
        nil_result = ResultHandler::Result.new(success: nil, message: 'Test')
        expect(nil_result.success?).to be false
      end
    end

    describe '#failure?' do
      it 'returns false when success is true' do
        expect(result.failure?).to be false
      end

      it 'returns true when success is false' do
        failure = ResultHandler::Result.new(success: false, message: 'Failed')
        expect(failure.failure?).to be true
      end
    end

    describe '#[]' do
      it 'accesses :success key' do
        expect(result[:success]).to be true
      end

      it 'accesses :message key' do
        expect(result[:message]).to eq('Test')
      end

      it 'accesses :data key' do
        expect(result[:data]).to eq({ key: 'value' })
      end

      it 'accesses string keys' do
        expect(result['success']).to be true
        expect(result['message']).to eq('Test')
      end

      it 'returns nil for :error when success is true' do
        expect(result[:error]).to be_nil
      end

      it 'returns message for :error when success is false' do
        failure = ResultHandler::Result.new(success: false, message: 'Failed')
        expect(failure[:error]).to eq('Failed')
      end

      it 'accesses custom keys from data hash' do
        result_with_extras = ResultHandler::Result.new(
          success: true,
          message: 'Done',
          data: { delivery_id: 999, fare: 50 }
        )
        expect(result_with_extras[:delivery_id]).to eq(999)
        expect(result_with_extras[:fare]).to eq(50)
      end

      it 'returns nil for unknown keys when data is nil' do
        result_no_data = ResultHandler::Result.new(success: true, message: 'Done', data: nil)
        expect(result_no_data[:unknown]).to be_nil
      end

      it 'returns nil for unknown keys when data is not a hash' do
        result_array_data = ResultHandler::Result.new(success: true, message: 'Done', data: [1, 2, 3])
        expect(result_array_data[:unknown]).to be_nil
      end
    end

    describe '#to_h' do
      it 'returns a hash with all fields' do
        expect(result.to_h).to eq({
                                    success: true,
                                    message: 'Test',
                                    data: { key: 'value' }
                                  })
      end
    end

    describe '#to_api_hash' do
      it 'returns success and message' do
        hash = result.to_api_hash
        expect(hash[:success]).to be true
        expect(hash[:message]).to eq('Test')
      end

      it 'includes data when present' do
        hash = result.to_api_hash
        expect(hash[:data]).to eq({ key: 'value' })
      end

      it 'excludes data when nil' do
        result_no_data = ResultHandler::Result.new(success: true, message: 'Done', data: nil)
        hash = result_no_data.to_api_hash
        expect(hash.key?(:data)).to be false
      end
    end
  end

  describe '.extended' do
    it 'makes Result constant available in the class' do
      expect(extended_service.const_defined?(:Result)).to be true
      expect(extended_service::Result).to eq(ResultHandler::Result)
    end
  end

  describe '.included' do
    it 'makes Result constant available in the class' do
      expect(included_service.const_defined?(:Result)).to be true
      expect(included_service::Result).to eq(ResultHandler::Result)
    end
  end

  describe '#success (class method via extend)' do
    it 'creates a successful result' do
      result = extended_service.successful_operation
      expect(result).to be_a(ResultHandler::Result)
      expect(result.success?).to be true
    end

    it 'includes the message' do
      result = extended_service.successful_operation
      expect(result.message).to eq('Operation completed')
    end

    it 'includes the data payload' do
      result = extended_service.successful_operation
      expect(result.data).to eq({ id: 123 })
    end

    it 'works without data payload' do
      result = extended_service.simple_success
      expect(result.success?).to be true
      expect(result.data).to be_nil
    end
  end

  describe '#error (class method via extend)' do
    it 'creates a failed result' do
      result = extended_service.failed_operation
      expect(result).to be_a(ResultHandler::Result)
      expect(result.success?).to be false
      expect(result.failure?).to be true
    end

    it 'includes the error message' do
      result = extended_service.failed_operation
      expect(result.message).to eq('Something went wrong')
    end

    it 'includes the data payload' do
      result = extended_service.failed_operation
      expect(result.data).to eq({ code: 'ERR001' })
    end

    it 'works without data payload' do
      result = extended_service.simple_error
      expect(result.failure?).to be true
      expect(result.data).to be_nil
    end
  end

  describe '#success (instance method via include)' do
    it 'creates a successful result' do
      service = included_service.new
      result = service.successful_operation
      expect(result).to be_a(ResultHandler::Result)
      expect(result.success?).to be true
      expect(result.message).to eq('Operation completed')
      expect(result.data).to eq({ id: 456 })
    end
  end

  describe '#error (instance method via include)' do
    it 'creates a failed result' do
      service = included_service.new
      result = service.failed_operation
      expect(result).to be_a(ResultHandler::Result)
      expect(result.failure?).to be true
      expect(result.message).to eq('Something went wrong')
    end
  end

  describe 'backward compatibility' do
    it 'supports chained hash-like access for common patterns' do
      result = extended_service.successful_operation

      # Common usage patterns
      expect(result[:success]).to be true
      expect(result[:message]).to eq('Operation completed')
      expect(result[:data][:id]).to eq(123)
    end

    it 'supports checking success with both method and hash access' do
      result = extended_service.simple_success

      # Method access
      expect(result.success?).to be true

      # Hash access (for code that does if result[:success])
      expect(result[:success]).to be true
    end

    it 'supports error message access through :error key' do
      result = extended_service.failed_operation

      # Some code uses result[:error] instead of result[:message] for errors
      expect(result[:error]).to eq('Something went wrong')
    end
  end
end
