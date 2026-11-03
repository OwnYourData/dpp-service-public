# frozen_string_literal: true

require "rails_helper"

# DPP_EXAMPLE_PASSPORT_URL: the passport behind "Example passport" on the start
# page (ExamplePassport).
RSpec.describe "Example passport on the start page", type: :request do
  def with_example(value)
    previous = ENV.fetch(ExamplePassport::VARIABLE, nil)
    value.nil? ? ENV.delete(ExamplePassport::VARIABLE) : ENV[ExamplePassport::VARIABLE] = value
    yield
  ensure
    previous.nil? ? ENV.delete(ExamplePassport::VARIABLE) : ENV[ExamplePassport::VARIABLE] = previous
  end

  def button
    Nokogiri::HTML(response.body.dup.force_encoding(Encoding::UTF_8))
            .css("section.hero .actions a").find { |a| a.text.start_with?("Example passport") }
  end

  before { AvailableServices.reset! }
  after { AvailableServices.reset! }

  it "links the reference passport of the public instance without the variable" do
    with_example(nil) { get "/" }

    expect(button["href"]).to eq("https://dpp.oydapp.eu/01/09520123456788/21/000001")
  end

  it "links the passport the variable names" do
    url = "https://pace-dpp.example.org/01/09520123456788/21/TEST-PARTNER-0001"
    with_example(url) { get "/" }

    expect(button["href"]).to eq(url)
  end

  it "keeps the reference passport for anything but an absolute http(s) address" do
    ["   ", "javascript:alert(1)", "/01/09520123456788/21/1", "not a url at all", "https://"].each do |value|
      with_example(value) { get "/" }

      expect(button["href"]).to eq(ExamplePassport::DEFAULT)
    end
  end
end
