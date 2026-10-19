# frozen_string_literal: true

require "rails_helper"

# The root of the hosted instance is the start page (LandingController). It
# points visitors to the API documentation, the tools and the source code, and
# lists the available DPP services with what the automated checks found.
RSpec.describe "Landing page", type: :request do
  # The list shipped with the service, unless an example says otherwise.
  before { AvailableServices.reset! }
  after { AvailableServices.reset! }

  def page_text
    response.body.dup.force_encoding(Encoding::UTF_8)
  end

  def services_table
    page_text[/<table class="services-table".*?<\/table>/m]
  end

  it "serves the start page at /" do
    get "/"

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("text/html")
    body = response.body.dup.force_encoding(Encoding::UTF_8)
    expect(body).to be_valid_encoding
    expect(body).to include("<title>DPP Service · OwnYourData</title>")
  end

  it "links to the API documentation that exists" do
    get "/"

    expect(response.body).to include('href="/api-docs/index.html"')
  end

  it "points to the DPP Linter and its source" do
    get "/"

    expect(response.body).to include('href="https://dpplint.ownyourdata.eu"')
    expect(response.body).to include('href="https://github.com/OwnYourData/dpplint"')
  end

  it "points to the validator results, its criteria and its source" do
    get "/"

    body = response.body.dup.force_encoding(Encoding::UTF_8)
    expect(body).to include('href="https://ownyourdata.github.io/dpp-validator/"')
    expect(body).to include('href="https://github.com/OwnYourData/dpp-criteria"')
    expect(body).to include('href="https://github.com/OwnYourData/dpp-validator"')
    expect(body).not_to include("In progress")
  end

  # The title of each of the four tools is itself the way to it; the links
  # under the text stay as they are.
  it "links the title of each tool to the tool, and keeps the links under the text" do
    get "/"

    page = Nokogiri::HTML(page_text)
    tools = page.xpath("//h2[text()='Tools']/following-sibling::div[1]//article")
    titles = tools.css("h3 a").map { |a| [a.text.delete("→").strip, a["href"]] }
    expect(titles).to eq([["DPP Knowledge Base", "/kb/"],
                          ["DPP Manager", "https://hub.docker.com/r/oydeu/dpp-manager"],
                          ["DPP Linter", "https://dpplint.ownyourdata.eu/"],
                          ["DPP Service Validator", "https://ownyourdata.github.io/dpp-validator/"]])
    expect(tools.css("h3 a .go").map { |s| s["aria-hidden"] }).to all(eq("true"))
    expect(tools.css(".links a").map { |a| a.text.strip })
      .to eq(["All articles", "Laws and standards", "Roadmap", "Explained", "Walkthrough", "Source",
              "Explained", "dpplint.ownyourdata.eu", "Source", "Explained", "Results", "Criteria", "Source"])
  end

  it "lets operators add or correct their service" do
    get "/"

    expect(page_text).to include(
      '<a class="btn secondary" href="https://github.com/OwnYourData/dpp-criteria/blob/main/services/README.md">' \
      "Add or correct your service</a>"
    )
  end

  it "introduces the available DPP services" do
    get "/"

    expect(page_text).to include("<h2 id=\"available-services\">Available DPP services</h2>")
    expect(page_text).to include("Services that implement EN&nbsp;18222:2026, including this one.")
    expect(page_text).not_to include("Other DPP services")
  end

  # What the results are and are not is said once, in the notice of the list
  # (kept in dpp-criteria); the page has no wording of its own for it.
  it "shows the notice of the list under the table, and only there" do
    get "/"

    notice = JSON.parse(File.read(AvailableServices::SEED))["notice"]
    expect(page_text).to include(%(<p class="services-notice">#{ERB::Util.html_escape(notice)}</p>))
    expect(page_text.index('<p class="services-notice">')).to be > page_text.index("</table>")
    expect(page_text).not_to include("Results show automated checks only, no certification.")
    expect(page_text.scan("no certification").size).to eq(1)
  end

  # Projects, initiatives and standards are described in the Knowledge Base,
  # not in the list: one line after legend and notice points there.
  it "points from the list to the research projects and initiatives in the Knowledge Base" do
    get "/"

    line = '<p class="services-more">Beyond services: research projects, initiatives and standards around the DPP – ' \
           '<a href="/kb/research-and-initiatives/">Knowledge Base</a></p>'
    expect(page_text).to include(line)
    expect(page_text.scan("kb/research-and-initiatives").size).to eq(1)
    expect(page_text.index(line)).to be > page_text.index('<p class="services-notice">')
    expect(page_text.index(line)).to be > page_text.index('<ul class="legend">')
    expect(services_table).not_to include("research-and-initiatives")
  end

  it "shows the notice of the list it shows, when that comes from the source" do
    list = { "notice" => "Fetched notice <with> & marks.", "services" => [{ "name" => "Fetched" }] }
    allow(OutboundHttp).to receive(:request)
      .and_return(OutboundHttp::Response.new(code: "200", body: JSON.generate(list), message: "OK", version: "2.0"))
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("DPP_AVAILABLE_SERVICES_URL").and_return("https://validator.example.org/list.json")

    get "/"

    expect(page_text).to include('<p class="services-notice">Fetched notice &lt;with&gt; &amp; marks.</p>')
  end

  it "lists the services with this service first and marked, then the rest by name" do
    get "/"

    rows = services_table.scan(/<tr[^>]*>.*?<\/tr>/m).drop(1)
    names = rows.map { |row| row[/class="name"[^>]*>([^<]+)</, 1] }
    expect(names).to eq(["OwnYourData DPP Service", "Eclipse BaSyx DPP API", "freeDPP", "OPC UA Cloud Library", "open-dpp", "OpenDPP", "PassportLab"])
    expect(rows.first).to start_with('<tr class="this">')
    expect(rows.first).to include('<span class="badge live">this service</span>')
    expect(rows.drop(1).join).not_to include("this service")
  end

  it "says where each entry comes from, with the legend under the table" do
    get "/"

    expect(services_table).to include('<span class="src operator" aria-hidden="true"></span>entry maintained by the operator')
    expect(services_table).to include('<span class="src research" aria-hidden="true"></span>our research · 2026-10-18')
    legend = page_text[/<ul class="legend">.*?<\/ul>/m]
    expect(legend).to include("Entry maintained by the operator (pull request to dpp-criteria)")
    expect(legend).to include("Entry from our research – public information, may be incomplete; the operator can confirm or correct it")
  end

  # The counts are those of the list: passed includes the checks that ended in
  # a warning, total is passed plus failed.
  it "links each example passport to its live check in the DPP Linter, with the counts of the list in their colour" do
    get "/"

    expect(services_table).to include(
      '<a href="https://dpplint.ownyourdata.eu/?productId=https%3A%2F%2Fdpp.oydapp.eu%2F01%2F09520123456788%2F21%2F000001">reference passport</a>'
    )
    expect(services_table).to include('<span class="tone-pass">5 of 5 passed</span> · 1 warning')
    expect(services_table).to include('<span class="tone-warn">3 of 4 passed</span> · 1 warning')
    expect(services_table).to include('<span class="tone-warn">4 of 5 passed</span> · 2 warnings')
    expect(services_table).to include('<span class="tone-fail">2 of 4 passed</span>')
    expect(services_table).to include('<span class="tone-neutral">no public example passport</span>')
  end

  it "shows the validator's result with its details, and a neutral word for every other status" do
    get "/"

    expect(services_table).to include(
      '<span class="tone-pass">15 of 15</span> · ' \
      '<a href="https://ownyourdata.github.io/dpp-validator/services/ownyourdata-dpp-service.html">details</a>'
    )
    expect(services_table).to include('<span class="sub">1 proposed criterion failed · daily</span>')
    ["needs credentials", "no EN 18222 paths yet"].each do |text|
      expect(services_table).to include(%(<span class="tone-neutral">#{text}</span>))
    end
  end

  # Entries from our research are checked on their read paths only, once a week.
  it "names the validator's warnings beside its count, and nothing where there are none" do
    get "/"

    rows = services_table.scan(/<tr[^>]*>.*?<\/tr>/m)
    opc = rows.find { |r| r.include?(">OPC UA Cloud Library</a>") }
    own = rows.find { |r| r.include?('class="this"') }
    expect(opc).to include('<span class="tone-pass">2 of 2</span> · 1 warning · <a href=')
    expect(own).to include('<span class="tone-pass">15 of 15</span> · <a href=')
  end

  it "says under a read-only result that only the read paths are checked" do
    get "/"

    row = services_table.scan(/<tr[^>]*>.*?<\/tr>/m).find { |r| r.include?(">freeDPP</a>") }
    expect(row).to include(
      '<span class="tone-fail">7 of 11</span> · 2 warnings · ' \
      '<a href="https://ownyourdata.github.io/dpp-validator/services/freedpp.html">details</a>'
    )
    expect(row).to include('<span class="sub">read paths only · weekly</span>')
  end

  # Software without a public instance is checked on an instance we run
  # ourselves; the line under the result says so and links the release.
  it "says under a result on our own test instance which release was checked" do
    get "/"

    row = services_table.scan(/<tr[^>]*>.*?<\/tr>/m).find { |r| r.include?(">Eclipse BaSyx DPP API</a>") }
    expect(row).to include(
      '<span class="tone-pass">10 of 10</span> · 2 warnings · ' \
      '<a href="https://ownyourdata.github.io/dpp-validator/services/eclipse-basyx-dpp-api.html">details</a>'
    )
    expect(row).to include(
      '<span class="sub">on our own test instance ' \
      "(<a href=\"https://github.com/eclipse-basyx/basyx-go-components/releases/tag/v1.1.2\">version\u00A01.1.2</a>) · weekly</span>"
    )
    expect(row).to include('<span class="tone-neutral">no public example passport</span>')
  end

  it "names the test instance before its first run, and links no release that is not a web address" do
    services = [{ "name" => "Waiting", "validator" => { "status" => "pending", "mode" => "test-instance", "cadence" => "weekly",
                                                         "test_instance" => { "software" => "Other <software>", "version" => "2.0",
                                                                              "release" => "javascript:alert(1)" } } }]
    allow(OutboundHttp).to receive(:request)
      .and_return(OutboundHttp::Response.new(code: "200", body: JSON.generate("notice" => "n", "services" => services), message: "OK", version: "2.0"))
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("DPP_AVAILABLE_SERVICES_URL").and_return("https://validator.example.org/list.json")

    get "/"

    expect(services_table).to include('<span class="tone-neutral">first run pending</span>')
    expect(services_table).to include("<span class=\"sub\">on our own test instance (Other &lt;software&gt;\u00A02.0) · weekly</span>")
    expect(services_table).not_to include("javascript:")
  end

  it "words every status of the validator the same way in the page" do
    statuses = %w[checked pending needs_credentials no_public_instance no_en18222_paths]
    services = statuses.map do |status|
      { "name" => "Service #{status}", "validator" => { "status" => status, "mode" => "read-only", "cadence" => "weekly", "passed" => 2, "total" => 2 } }
    end
    allow(OutboundHttp).to receive(:request)
      .and_return(OutboundHttp::Response.new(code: "200", body: JSON.generate("notice" => "n", "services" => services), message: "OK", version: "2.0"))
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("DPP_AVAILABLE_SERVICES_URL").and_return("https://validator.example.org/list.json")

    get "/"

    expect(services_table).to include('<span class="tone-pass">2 of 2</span>')
    ["first run pending", "needs credentials", "no public instance", "no EN 18222 paths yet"].each do |text|
      expect(services_table).to include(%(<span class="tone-neutral">#{text}</span>))
    end
    expect(services_table.scan('<span class="sub">read paths only · weekly</span>').size).to eq(5)
  end

  it "labels every cell for narrow screens, without a script" do
    get "/"

    cells = services_table.scan(/<td data-label="([^"]+)">/).flatten
    expect(cells.uniq).to eq(["Service", "Licence", "Example passports · DPP Linter", "Service checks · Validator"])
    expect(cells.size).to eq(7 * 4)
    expect(page_text).to include("@media (max-width: 639px)")
    expect(page_text).not_to include("<script")
  end

  it "keeps showing the shipped list when the configured source fails" do
    allow(OutboundHttp).to receive(:request).and_raise(OutboundHttp::ConnectionError, "refused")
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("DPP_AVAILABLE_SERVICES_URL").and_return("https://validator.example.org/list.json")

    get "/"

    expect(response).to have_http_status(:ok)
    expect(OutboundHttp).to have_received(:request).once
    expect(services_table).to include(">PassportLab</a>")
  end

  it "shows what the source lists, escaped, and links only web addresses" do
    list = { "notice" => "n", "services" => [{ "name" => "<b>Bold</b> & Co", "url" => "javascript:alert(1)",
                              "entry" => { "source" => "operator" }, "validator" => { "status" => "pending" } }] }
    allow(OutboundHttp).to receive(:request)
      .and_return(OutboundHttp::Response.new(code: "200", body: JSON.generate(list), message: "OK", version: "2.0"))
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("DPP_AVAILABLE_SERVICES_URL").and_return("https://validator.example.org/list.json")

    get "/"

    expect(services_table).to include('<span class="name">&lt;b&gt;Bold&lt;/b&gt; &amp; Co</span>')
    expect(services_table).not_to include("javascript:")
    expect(services_table).not_to include("PassportLab")
  end

  # Results change every day: counts appear only in the list of services, where
  # they come from the checks, and the page calls no service conformant,
  # compliant or certified.
  it "states results only in the list of services and claims no conformity" do
    get "/"

    expect(page_text.sub(services_table, "")).not_to match(/\d+ of \d+/)
    expect(page_text).not_to match(/conformant|compliant|certified/i)
  end

  it "shows the OwnYourData mark beside the title and uses it as the icon" do
    get "/"

    expect(response.body).to include('<link rel="icon" href="/oyd-mark.svg" type="image/svg+xml">')
    expect(response.body).to include('<img class="mark" src="/oyd-mark.svg" alt=""')

    get "/oyd-mark.svg"

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("image/svg+xml")
  end

  it "names the funding of PACE-DPP once, in the footer" do
    get "/"

    body = response.body.dup.force_encoding(Encoding::UTF_8)
    expect(body.scan("917177").size).to eq(1)
    expect(body[body.index("<footer>")..]).to include(FundingNotice.html)
  end

  it "leaves the API untouched" do
    get "/up"

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("application/json")
  end
end
