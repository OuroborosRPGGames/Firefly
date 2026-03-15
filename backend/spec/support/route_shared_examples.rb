# frozen_string_literal: true

# Shared examples for route testing

RSpec.shared_examples 'requires authentication' do |path, method: :get|
  it 'redirects when not authenticated' do
    case method
    when :get then get path
    when :post then post path
    when :put then put path
    when :delete then delete path
    end
    expect(last_response).to be_redirect
    expect(last_response.location).to include('/login')
  end
end

RSpec.shared_examples 'requires admin' do |path, method: :get|
  let(:regular_user) { create(:user) }

  it 'returns 403 for non-admin' do
    env 'rack.session', { 'user_id' => regular_user.id }

    case method
    when :get then get path
    when :post then post path
    when :put then put path
    when :delete then delete path
    end

    # Either redirect or forbidden
    expect([302, 403]).to include(last_response.status)
  end
end

RSpec.shared_examples 'returns json' do |path|
  it 'returns JSON content type' do
    get path
    expect(last_response.content_type).to include('application/json')
  end
end

RSpec.shared_examples 'API endpoint' do |path|
  it 'returns success with valid auth' do
    get path, {}, auth_headers
    expect(last_response.status).to eq(200)
    expect(json_response['success']).to be true
  end

  it 'returns 401 without auth' do
    get path
    expect(last_response.status).to eq(401)
  end
end
