# frozen_string_literal: true

require "rails_helper"

# DPP_INSTANCE_NOTICE: a line at the top of the start page (InstanceNotice).
RSpec.describe "Instance notice", type: :request do
  def with_notice(value)
    previous = ENV.fetch("DPP_INSTANCE_NOTICE", nil)
    value.nil? ? ENV.delete("DPP_INSTANCE_NOTICE") : ENV["DPP_INSTANCE_NOTICE"] = value
    yield
  ensure
    previous.nil? ? ENV.delete("DPP_INSTANCE_NOTICE") : ENV["DPP_INSTANCE_NOTICE"] = previous
  end

  def page = Nokogiri::HTML(response.body.dup.force_encoding(Encoding::UTF_8))

  before { AvailableServices.reset! }
  after { AvailableServices.reset! }

  it "shows the notice at the top of the start page, escaped" do
    with_notice("Test instance – no production data, will be deleted on 31 January 2027 <b>") do
      get "/"
    end

    notice = page.at_css("main p.instance-notice")
    expect(notice).to be_present
    expect(notice["role"]).to eq("note")
    expect(notice.text).to eq("Test instance – no production data, will be deleted on 31 January 2027 <b>")
    expect(response.body).not_to include("2027 <b>")
    expect(notice.next_element.matches?("section.hero")).to be(true)
  end

  it "shows no notice without the variable or with blanks only" do
    [nil, "   "].each do |value|
      with_notice(value) { get "/" }

      expect(page.at_css(".instance-notice")).to be_nil
    end
  end

  it "cuts an overlong notice" do
    with_notice("x" * 400) { get "/" }

    expect(page.at_css(".instance-notice").text.length).to eq(InstanceNotice::MAX_LENGTH)
  end
end
