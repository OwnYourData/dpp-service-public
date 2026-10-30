# frozen_string_literal: true

require "rails_helper"

# The light/dark switch in the header of the start page and the privacy
# policy (public/theme.js). It shares its choice with the Knowledge Base on
# the same host, which uses the same key in localStorage.
RSpec.describe "Theme toggle", type: :request do
  before { AvailableServices.reset! }
  after { AvailableServices.reset! }

  %w[/ /privacy].each do |path|
    it "offers the switch in the header of #{path}, hidden until the script shows it" do
      get path

      doc = Nokogiri::HTML(response.body)
      button = doc.at_css("header nav button#theme-toggle.theme-toggle")
      expect(button).not_to be_nil
      expect(button["type"]).to eq("button")
      expect(button["hidden"]).not_to be_nil
      expect(button.css("svg").map { |svg| svg["class"] }).to eq(%w[icon-moon icon-sun])
    end

    it "loads the theme before the page is drawn on #{path}, without an inline script" do
      get path

      doc = Nokogiri::HTML(response.body)
      script = doc.at_css('head script[src="/theme.js"]')
      expect(script).not_to be_nil
      expect(script["defer"]).to be_nil
      expect(script["async"]).to be_nil
      expect(doc.at_css('meta[name="color-scheme"]')["content"]).to eq("light dark")
      expect(doc.css("script:not([src])")).to be_empty
    end

    it "follows the system unless a theme was picked on #{path}" do
      get path

      css = Nokogiri::HTML(response.body).css("style").text
      expect(css).to include(%(@media (prefers-color-scheme: dark) {\n    :root:not([data-theme="light"]) {))
      expect(css).to include(%(:root[data-theme="dark"] {\n    color-scheme: dark;))
    end
  end

  it "keeps the choice under the key of the Knowledge Base" do
    script = Rails.public_path.join("theme.js").read

    expect(script.scan('"kb-theme"').size).to eq(1)
    expect(script).to include('root.setAttribute("data-theme", stored)')
    expect(script).to include("window.localStorage.removeItem(KEY)")
  end
end
