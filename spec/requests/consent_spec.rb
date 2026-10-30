# frozen_string_literal: true

require "rails_helper"

# Conversion measurement with Google Ads only after consent (GoogleAds,
# ConsentController, docs/Consent.md). The server-side half of the check: no
# page of this service names a Google address that a browser would request on
# its own, and without a conversion ID there is neither banner nor script. The
# browser half is spec/browser/consent_check.mjs.
RSpec.describe "Consent and conversion measurement", type: :request do
  google_host = /(?:^|\.)(?:google(?:-analytics|adservices|apis|syndication|tagmanager|usercontent)?|gstatic|doubleclick)\.[a-z.]+\z/i
  let(:google_host) { google_host }
  let(:pages) { ["/", "/privacy", "/api-docs/index.html"] }

  around do |example|
    keys = %w[GOOGLE_ADS_ID GOOGLE_ADS_LABEL_GET_STARTED GOOGLE_ADS_LABEL_GITHUB GOOGLE_ADS_LABEL_NEWSLETTER]
    saved = keys.to_h { |key| [key, ENV[key]] }
    keys.each { |key| ENV.delete(key) }
    example.run
  ensure
    saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  before { AvailableServices.reset! }
  after { AvailableServices.reset! }

  def configure(id: "AW-123456789", get_started: "gsLabel_1", github: "ghLabel-2", newsletter: "nlLabel3")
    ENV["GOOGLE_ADS_ID"] = id
    ENV["GOOGLE_ADS_LABEL_GET_STARTED"] = get_started
    ENV["GOOGLE_ADS_LABEL_GITHUB"] = github
    ENV["GOOGLE_ADS_LABEL_NEWSLETTER"] = newsletter
  end

  def page
    Nokogiri::HTML(response.body.dup.force_encoding(Encoding::UTF_8))
  end

  # Every address a browser fetches without anybody clicking: scripts, style
  # sheets, images, frames, preloads, and url()/@import in inline CSS.
  def fetched_without_action(doc)
    urls = doc.css("script[src]").map { |n| n["src"] } +
           doc.css("link[href]").reject { |n| n["rel"].to_s.split.intersect?(%w[canonical alternate author license]) }.map { |n| n["href"] } +
           doc.css("img[src], iframe[src], source[src], video[src], audio[src], embed[src]").map { |n| n["src"] } +
           doc.css("object[data]").map { |n| n["data"] } +
           doc.css("style").flat_map { |n| n.text.scan(/url\(\s*['"]?([^'")\s]+)|@import\s+['"]([^'"]+)/).flatten.compact }
    urls.compact
  end

  def google?(url)
    host = URI.parse(url).host
    host.present? && host.match?(google_host)
  rescue URI::InvalidURIError
    false
  end

  describe "without a conversion ID" do
    it "embeds no script, shows no banner and no cookie settings" do
      get "/"

      expect(page.css('script[src="/consent.js"]')).to be_empty
      expect(page.css("[data-consent-settings]")).to be_empty
      expect(response.body).not_to include("googletagmanager")
    end

    it "serves an empty consent script that does nothing" do
      get "/consent.js"

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("text/javascript")
      expect(response.body).to eq("/* Conversion measurement is not configured on this instance. */\n")
    end

    it "treats a malformed ID as none" do
      ["GTM-ABC123", "G-0ELN6WZ6KT", "AW-12x", "AW-123456789'; alert(1)//", " "].each do |id|
        ENV["GOOGLE_ADS_ID"] = id
        expect(GoogleAds.enabled?).to be(false), id

        get "/consent.js"
        expect(response.body).not_to include("googletagmanager"), id
      end
    end
  end

  describe "with a conversion ID" do
    before { configure }

    it "embeds the consent script on the start page and the privacy policy, and nothing from Google" do
      %w[/ /privacy].each do |path|
        get path

        doc = page
        expect(doc.css('script[src="/consent.js"]').size).to eq(1), path
        expect(doc.css("script[src]").map { |n| n["src"] }).to eq(["/theme.js", "/consent.js"]), path
        expect(doc.css("script:not([src])")).to be_empty, path
        expect(response.body).not_to match(/googletagmanager|googleadservices|doubleclick|gtag\(/), path
      end
    end

    it "offers the cookie settings in the footer, revealed by the script" do
      %w[/ /privacy].each do |path|
        get path

        link = page.at_css("footer [data-consent-settings]")
        expect(link&.text).to eq("Cookie settings"), path
        expect(link["hidden"]).not_to be_nil
      end
    end

    it "serves the script with the configuration, the tag loaded only from the choice to accept" do
      get "/consent.js"

      body = response.body
      expect(response.media_type).to eq("text/javascript")
      expect(response.headers["Cache-Control"].split(", ")).to contain_exactly("public", "max-age=300")
      config = JSON.parse(body[/\}\)\((\{.*\})\);\s*\z/m, 1])
      expect(config).to eq("id" => "AW-123456789",
                           "conversions" => { "get_started" => "AW-123456789/gsLabel_1",
                                              "github" => "AW-123456789/ghLabel-2",
                                              "newsletter" => "AW-123456789/nlLabel3" })
      # The only Google address in the script, used in one place: loadTag.
      expect(body.scan(%r{https://[a-z.]*google[a-z.]*}).uniq).to eq(["https://www.googletagmanager.com"])
      expect(body.scan("TAG_URL").size).to eq(2)
      expect(body[/function loadTag\(\).*?\n\}/m]).to include("TAG_URL")
      # Consent Mode v2: everything denied first, then only what conversion
      # measurement needs; no analytics, no personalisation.
      expect(body).to include('gtag("consent", "update", { ad_storage: "granted", ad_user_data: "granted" });')
      expect(body).to include('gtag("set", { allow_ad_personalization_signals: false });')
      # Not configured for the ID: the tag then reports no page views and sends
      # something only for a conversion.
      expect(body).not_to include('gtag("config"')
      expect(body).not_to match(/G-[A-Z0-9]{6,}|GTM-|analytics_storage: "granted"|ad_personalization: "granted"/)
    end

    it "loads the tag only from the choice to accept, or from an earlier one" do
      get "/consent.js"

      expect(response.body.scan("loadTag();").size).to eq(2)
      expect(response.body).to match(/if \(ads\) \{\n\s*loadTag\(\);/)
      expect(response.body).to match(/if \(choice === true\) \{\n\s*loadTag\(\);/)
    end

    it "offers Decline and Accept in the same form" do
      get "/consent.js"

      buttons = response.body.scan(/<button type="button" data-choice="(\w+)">(\w+)<\/button>/)
      expect(buttons).to eq([%w[decline Decline], %w[accept Accept]])
      expect(response.body).not_to match(/data-choice="(?:accept|decline)"[^>]*class=/)
    end

    # Labels from the Google Ads account have the form of a token of letters,
    # digits, "_" and "-", which may also start with "-".
    it "builds send_to from the ID and each label, whatever character the label starts with" do
      configure(id: "AW-894120911", get_started: "Ab1_cD-2", github: "9xY_z", newsletter: "-aB_c1")

      expect(GoogleAds.conversions).to eq("get_started" => "AW-894120911/Ab1_cD-2",
                                          "github" => "AW-894120911/9xY_z",
                                          "newsletter" => "AW-894120911/-aB_c1")
    end

    it "leaves a conversion without a valid label out" do
      configure(github: "", newsletter: "bad label")

      expect(GoogleAds.conversions).to eq("get_started" => "AW-123456789/gsLabel_1")
    end

    it "keeps the configuration safe to embed in a script" do
      get "/consent.js"

      expect(response.body).not_to include("</script")
    end
  end

  # Whatever the configuration: nothing a page fetches on its own is a Google
  # address. The Swagger UI template of rswag-ui loads Google web fonts; this
  # service ships its own template without them.
  [nil, "AW-123456789"].each do |id|
    it "has no page that fetches anything from Google by itself#{' (ID configured)' if id}" do
      configure(id: id) if id

      pages.each do |path|
        get path
        expect(response).to have_http_status(:ok), path

        google = fetched_without_action(page).select { |url| google?(url) }
        expect(google).to be_empty, "#{path}: #{google.join(', ')}"
        expect(response.body).not_to include("fonts.googleapis.com"), path
      end
    end
  end
end
