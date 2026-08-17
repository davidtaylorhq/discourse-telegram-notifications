# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Telegram webhook authentication", type: :request do
  before do
    SiteSetting.telegram_notifications_enabled = true
    SiteSetting.telegram_access_token = "test-token"
    SiteSetting.telegram_secret = "correct-secret"
  end

  it "rejects a request whose key does not match the secret" do
    post "/telegram/hook/wrong-secret", params: {}, as: :json
    expect(response.status).to eq(403)
  end

  it "rejects every request while no secret is configured" do
    SiteSetting.telegram_secret = ""
    post "/telegram/hook/anything", params: {}, as: :json
    expect(response.status).to eq(403)
  end

  it "accepts a request whose key matches the secret" do
    post "/telegram/hook/correct-secret", params: {}, as: :json
    expect(response.status).to eq(200)
    expect(response.parsed_body["success"]).to eq(true)
  end
end
