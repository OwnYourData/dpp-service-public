# frozen_string_literal: true

require "rails_helper"

# The privacy policy at /privacy (PrivacyController): one page for the start
# page, the API, the Knowledge Base and the DPP Linter.
RSpec.describe "Privacy policy", type: :request do
  def text
    Nokogiri::HTML(response.body.dup.force_encoding(Encoding::UTF_8)).css("body").text.tr("\u00a0", " ").gsub(/\s+/, " ")
  end

  it "serves the privacy policy as HTML" do
    get "/privacy"

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("text/html")
    expect(response.body).to include("<title>Privacy policy · DPP Service · OwnYourData</title>")
  end

  it "names the association as controller, with register number, address and contact" do
    get "/privacy"

    expect(text).to include("OwnYourData.eu – Verein zur Förderung der selbstständigen Nutzung von Daten")
    expect(text).to include("ZVR): 789007092")
    expect(text).to include("2540 Bad Vöslau, Austria")
    expect(response.body).to include('href="mailto:office@ownyourdata.eu"')
    expect(response.body).to include('href="https://www.ownyourdata.eu/en/imprint/"')
  end

  it "has the sections the banner and the footers link to" do
    get "/privacy"

    ids = Nokogiri::HTML(response.body).css("h2[id]").map { |h| h["id"] }
    expect(ids).to eq(%w[controller scope hosting api linter knowledge-base conversion-tracking rights])
  end

  it "states legal basis, recipient, transfer and withdrawal of the conversion tracking" do
    get "/privacy"

    section = text[/7\. Conversion tracking with Google Ads.*?8\. Your rights/]
    expect(section).to include("Art. 6(1)(a) GDPR")
    expect(section).to include("§ 165(3) of the Austrian Telecommunications Act 2021")
    expect(section).to include("Google Ireland Limited, Gordon House, Barrow Street, Dublin 4, Ireland")
    expect(section).to include("EU-U.S. Data Privacy Framework")
    expect(section).to include("“Cookie settings”")
    expect(section).to include("no Google Analytics, no remarketing")
  end

  it "names the rights of data subjects and the Austrian Data Protection Authority" do
    get "/privacy"

    %w[15 16 17 18 20 21].each { |article| expect(text).to match(/\(Art\. #{article}[ )]/) }
    expect(text).to include("Österreichische Datenschutzbehörde")
    expect(text).to include("Barichgasse 40–42, 1030 Vienna")
  end

  it "names the hosting provider and where the data centre is" do
    get "/privacy"

    expect(text).to include("netcup GmbH, Emmy-Noether-Straße 10, 76131 Karlsruhe, Germany, in its data centre in Vienna, Austria")
    expect(text).to include("the companies of the Anexia group that work for it")
  end

  # The periods the configuration sets (k8s: DPP_ACCESS_LOG_RETENTION_DAYS,
  # DPP_WRITE_LOG_RETENTION_DAYS) and the archive that is never pruned.
  it "says where the server logs are kept and when they are deleted" do
    get "/privacy"

    expect(text).to include("in a central log system that we run on the same servers; they are not passed on to anyone")
    expect(text).to include("They are deleted after six weeks at the latest.")
  end

  it "says how long passports, write evidence and access log are kept" do
    get "/privacy"

    expect(text).to include("remain archived; this service does not delete them")
    expect(text).to include("Write evidence is kept as long as the passport or one of its archived versions is kept")
    expect(text).to include("is deleted after two years")
    expect(text).to include("Access log entries are deleted two years after the access")
  end

  it "informs the persons named in passports, and says who can see what" do
    get "/privacy"

    expect(text).to include("This section is our information under Art. 14 GDPR to the persons concerned")
    expect(text).to include("The public part of a passport: anyone, without an account.")
    expect(text).to include("The restricted part: only readers to whom the economic operator has granted access")
  end

  it "rules out automated decisions and limits data portability to where it applies" do
    get "/privacy"

    expect(text).to include("within the meaning of Art. 22 GDPR")
    expect(text).to include("where applicable to data portability (Art. 20)")
  end

  # The newsletter comes with its own release; until then the policy does not
  # describe it.
  it "does not describe a newsletter that does not exist yet" do
    get "/privacy"

    expect(text).not_to match(/newsletter/i)
  end

  it "says that the Knowledge Base search runs in the browser" do
    get "/privacy"

    expect(text).to include("Its search runs entirely in your browser")
  end

  it "loads nothing from another host" do
    get "/privacy"

    doc = Nokogiri::HTML(response.body)
    fetched = doc.css("script[src], link[href], img[src]").map { |n| n["src"] || n["href"] }
    expect(fetched).to all(start_with("/"))
  end

  it "has no gaps left in the text" do
    get "/privacy"

    expect(response.body).not_to include("[[")
    expect(response.body).not_to include('class="gap"')
  end
end
