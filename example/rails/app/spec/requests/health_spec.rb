require "rails_helper"
require "json"

RSpec.describe "health", type: :request do
  it "serves a Rails request against PostgreSQL state" do
    Widget.create!(name: "request")

    get "/health"

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)).to include("ok" => true, "widget_count" => 1)
  end
end
