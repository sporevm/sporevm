require "rails_helper"

RSpec.describe Widget, type: :model do
  it "persists valid rows in the warm PostgreSQL database" do
    widget = Widget.create!(name: "forked")

    expect(Widget.find(widget.id).name).to eq("forked")
  end

  it "keeps validation behavior loaded after resume" do
    expect(Widget.new).not_to be_valid
  end
end
