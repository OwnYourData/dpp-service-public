# frozen_string_literal: true

require "rails_helper"

# The list of available DPP services on the start page: where it comes from,
# how long it is kept, what is shown when the source fails, and how its entries
# are ordered and worded.
RSpec.describe AvailableServices do
  let(:source) { "https://validator.example.org/available-services.json" }
  let(:now) { [1000.0] }
  let(:clock) { -> { now.first } }
  let(:seed_names) { JSON.parse(File.read(described_class::SEED))["services"].map { |s| s["name"] } }

  def service(name, **fields)
    { "name" => name, "url" => "https://#{name.downcase.delete(' ')}.example.org/" }.merge(fields.transform_keys(&:to_s))
  end

  def list_body(*services, notice: "Results of automated checks only.")
    JSON.generate("generated_at" => "2026-10-18T08:00:00Z", "notice" => notice, "services" => services)
  end

  def answer(code: "200", body: list_body(service("Fetched")))
    OutboundHttp::Response.new(code: code, body: body, message: "", version: "2.0")
  end

  def advance(seconds)
    now[0] += seconds
  end

  def names(store)
    store.entries.map(&:name)
  end

  describe "the shipped list" do
    it "is a valid list and is shown while no source is configured" do
      allow(OutboundHttp).to receive(:request)
      store = described_class.new(url: nil, clock: clock)

      expect(names(store)).to match_array(seed_names)
      advance(described_class::TTL * 2)
      store.entries
      expect(OutboundHttp).not_to have_received(:request)
    end

    # The JSON says each count in two ways, as numbers and as a sentence; the
    # page shows the numbers, and they must say what the sentence says.
    it "gives the counts the summaries of the source give" do
      described_class.new(url: nil).entries.each do |entry|
        raw = JSON.parse(File.read(described_class::SEED))["services"].find { |s| s["name"] == entry.name }
        Array(raw.dig("linter", "passports")).zip(entry.passports).each do |given, shown|
          expect(given["summary_text"]).to start_with("#{shown.count.text} ")
        end
        expect(raw.dig("validator", "summary_text")).to start_with("#{entry.validator_count.text} ") if entry.validator_checked?
      end
    end

    it "names no person and no internal host" do
      text = File.read(described_class::SEED)

      expect(text).not_to match(/localhost|staging|\.svc\b|cluster\.local|\.internal\b/)
    end
  end

  describe "fetching, keeping and falling back" do
    it "fetches the configured source and shows what it lists" do
      allow(OutboundHttp).to receive(:request).and_return(answer)
      store = described_class.new(url: source, clock: clock)

      expect(names(store)).to eq(["Fetched"])
      expect(OutboundHttp).to have_received(:request)
        .with(:get, source, headers: { "Accept" => "application/json" },
                            open_timeout: described_class::OPEN_TIMEOUT, read_timeout: described_class::READ_TIMEOUT)
    end

    it "keeps a fetched list for an hour, then fetches it again" do
      allow(OutboundHttp).to receive(:request).and_return(answer)
      store = described_class.new(url: source, clock: clock)
      store.entries

      advance(described_class::TTL - 1)
      store.entries
      expect(OutboundHttp).to have_received(:request).once

      allow(OutboundHttp).to receive(:request).and_return(answer(body: list_body(service("Newer"))))
      advance(1)
      expect(names(store)).to eq(["Newer"])
    end

    it "shows the shipped list when the first fetch fails" do
      allow(OutboundHttp).to receive(:request).and_raise(OutboundHttp::TimeoutError, "read timeout")
      store = described_class.new(url: source, clock: clock)

      expect(names(store)).to match_array(seed_names)
    end

    it "shows the last good list when a later fetch fails, and tries again after a few minutes" do
      allow(OutboundHttp).to receive(:request).and_return(answer)
      store = described_class.new(url: source, clock: clock)
      store.entries

      allow(OutboundHttp).to receive(:request).and_raise(OutboundHttp::ConnectionError, "refused")
      advance(described_class::TTL)
      expect(names(store)).to eq(["Fetched"])

      advance(described_class::RETRY_AFTER - 1)
      store.entries
      expect(OutboundHttp).to have_received(:request).twice

      advance(1)
      store.entries
      expect(OutboundHttp).to have_received(:request).exactly(3).times
    end

    {
      "an error status" => { code: "404", body: "not found" },
      "a list without a notice" => { body: JSON.generate("services" => [{ "name" => "Fetched" }]) },
      "a list with an empty notice" => { body: JSON.generate("notice" => " ", "services" => [{ "name" => "Fetched" }]) },
      "a body that is not JSON" => { body: "<html>maintenance</html>" },
      "JSON without a list of services" => { body: '{"services":"none"}' },
      "an empty list" => { body: '{"notice":"n","services":[]}' },
      "an entry without a name" => { body: '{"notice":"n","services":[{"url":"https://x.example.org/"}]}' },
      "a body that is far too large" => { body: JSON.generate("notice" => "n", "services" => [{ "name" => "x" * (AvailableServices::MAX_BYTES + 1) }]) }
    }.each do |what, reply|
      it "does not take #{what} for a list" do
        allow(OutboundHttp).to receive(:request).and_return(answer(**reply))
        store = described_class.new(url: source, clock: clock)

        expect(names(store)).to match_array(seed_names)
      end
    end

    it "says in the log that it keeps the last good list, without anything of the body" do
      allow(OutboundHttp).to receive(:request).and_return(answer(body: "<!doctype html>secret-looking body"))
      allow(Rails.logger).to receive(:warn)

      described_class.new(url: source, clock: clock).entries

      expect(Rails.logger).to have_received(:warn).with(/keeping the last good list \(AvailableServices::InvalidList: not JSON\)/)
      expect(Rails.logger).not_to have_received(:warn).with(/doctype|secret-looking/)
    end

    it "names the status in the log when the source answers with an error" do
      allow(OutboundHttp).to receive(:request).and_return(answer(code: "500", body: "secret-looking body"))
      allow(Rails.logger).to receive(:warn)

      described_class.new(url: source, clock: clock).entries

      expect(Rails.logger).to have_received(:warn).with(/keeping the last good list \(AvailableServices::InvalidList: HTTP 500\)/)
      expect(Rails.logger).not_to have_received(:warn).with(/secret-looking/)
    end

    it "fetches nothing from a source that is not an https URL" do
      allow(OutboundHttp).to receive(:request)

      ["http://validator.example.org/list.json", "file:///etc/passwd", "not a url"].each do |value|
        store = described_class.new(url: value, clock: clock)
        expect(store.url).to be_nil
        expect(names(store)).to match_array(seed_names)
      end
      expect(OutboundHttp).not_to have_received(:request)
    end

    it "reads the source from DPP_AVAILABLE_SERVICES_URL" do
      described_class.reset!
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("DPP_AVAILABLE_SERVICES_URL").and_return(source)

      expect(described_class.default.url).to eq(source)
    ensure
      described_class.reset!
    end
  end

  describe "the notice" do
    it "is the notice of the shipped list while no source is configured" do
      expect(described_class.new(url: nil).notice).to eq(JSON.parse(File.read(described_class::SEED))["notice"].strip)
    end

    it "is the notice of the fetched list, and stays with the list it came with" do
      allow(OutboundHttp).to receive(:request).and_return(answer(body: list_body(service("Fetched"), notice: "Fetched notice.")))
      store = described_class.new(url: source, clock: clock)

      expect(store.notice).to eq("Fetched notice.")

      allow(OutboundHttp).to receive(:request).and_return(answer(body: JSON.generate("services" => [{ "name" => "Newer" }])))
      advance(described_class::TTL)
      expect([store.notice, names(store)]).to eq(["Fetched notice.", ["Fetched"]])
    end
  end

  describe "order" do
    it "puts this service first, then the operators' entries, then our research, each by name" do
      list = list_body(
        service("Zeta", entry: { "source" => "research" }),
        service("beta", entry: { "source" => "operator" }),
        service("Alpha", entry: { "source" => "research" }),
        service("Ours", this_service: true, entry: { "source" => "operator" }),
        service("Gamma", entry: { "source" => "operator" }),
        service("Unsaid")
      )
      allow(OutboundHttp).to receive(:request).and_return(answer(body: list))

      expect(names(described_class.new(url: source, clock: clock))).to eq(%w[Ours beta Gamma Alpha Unsaid Zeta])
    end

    it "orders the shipped list the same way" do
      expect(names(described_class.new(url: nil))).to eq(
        ["OwnYourData DPP Service", "Eclipse BaSyx DPP API", "freeDPP", "OPC UA Cloud Library", "open-dpp", "OpenDPP", "PassportLab"]
      )
    end
  end

  describe AvailableServices::Entry do
    def entry(**fields)
      described_class.new(service("Some service", **fields))
    end

    it "words each status of the validator" do
      {
        "pending" => "first run pending",
        "needs_credentials" => "needs credentials",
        "no_public_instance" => "no public instance",
        "no_en18222_paths" => "no EN 18222 paths yet",
        "something_new" => "not checked"
      }.each do |status, text|
        expect(entry(validator: { "status" => status }).validator_status_text).to eq(text)
      end
      expect(entry.validator_status_text).to eq("not checked")
    end

    it "says under the status how the service is checked, or the note of the entry" do
      expect(entry(validator: { "status" => "pending", "mode" => "read-only", "cadence" => "weekly" }).validator_detail)
        .to eq("read paths only · weekly")
      expect(entry(validator: { "status" => "no_public_instance", "note" => "planned: own test instance, weekly" }).validator_detail)
        .to eq("planned: own test instance, weekly")
      expect(entry(validator: { "status" => "needs_credentials" }).validator_detail).to be_nil
    end

    it "says under a result of a read-only check that only the read paths are checked, and how often" do
      checked = { "status" => "checked", "mode" => "read-only", "cadence" => "weekly", "passed" => 7, "total" => 11, "proposed_failed" => 0 }

      expect(entry(validator: checked).validator_count.text).to eq("7 of 11")
      expect(entry(validator: checked).validator_detail).to eq("read paths only · weekly")
      expect(entry(validator: checked.merge("proposed_failed" => 1)).validator_detail).to eq("1 proposed criterion failed · read paths only · weekly")
    end

    it "names the software and version of our own test instance, and where its release is" do
      release = "https://github.com/example/software/releases/tag/v1.1.2"
      own = { "status" => "checked", "mode" => "test-instance", "cadence" => "weekly", "passed" => 10, "total" => 10,
              "test_instance" => { "software" => "Some service", "version" => "1.1.2", "release" => release } }

      instance = entry(validator: own).validator_test_instance
      expect([instance.label, instance.release_url]).to eq(["version\u00A01.1.2", release])
      expect(entry(validator: own).validator_detail).to eq("weekly")
      expect(entry(validator: own.merge("proposed_failed" => 1)).validator_detail).to eq("1 proposed criterion failed · weekly")

      other = own.merge("test_instance" => { "software" => "Other software", "version" => "2.0" })
      expect(entry(validator: other).validator_test_instance.to_h).to eq(label: "Other software\u00A02.0", release_url: nil)
      expect(entry(validator: own.merge("test_instance" => { "software" => "Other software" })).validator_test_instance.label).to eq("Other software")
      expect(entry(validator: own.merge("test_instance" => { "release" => "data:text/html,x" })).validator_test_instance.to_h)
        .to eq(label: nil, release_url: nil)
      expect(entry(validator: own.merge("status" => "pending")).validator_test_instance.label).to eq("version\u00A01.1.2")
      expect(entry(validator: own.merge("mode" => "read-only")).validator_test_instance).to be_nil
    end

    it "names the validator's warnings beside its count, which includes them" do
      checked = { "status" => "checked", "passed" => 7, "total" => 11, "failed" => 4 }

      expect(entry(validator: checked.merge("warnings" => 2)).validator_warnings_text).to eq("2 warnings")
      expect(entry(validator: checked.merge("warnings" => 1)).validator_warnings_text).to eq("1 warning")
      expect(entry(validator: checked.merge("warnings" => 0)).validator_warnings_text).to be_nil
      expect(entry(validator: checked).validator_warnings_text).to be_nil
      expect(entry(validator: checked.merge("warnings" => 2)).validator_count.text).to eq("7 of 11")
    end

    it "says under a result how many proposed criteria failed and how often it runs" do
      checked = { "status" => "checked", "mode" => "full", "cadence" => "daily", "passed" => 15, "total" => 15 }

      expect(entry(validator: checked.merge("proposed_failed" => 1)).validator_detail).to eq("1 proposed criterion failed · daily")
      expect(entry(validator: checked.merge("proposed_failed" => 2)).validator_detail).to eq("2 proposed criteria failed · daily")
      expect(entry(validator: checked.merge("proposed_failed" => 0)).validator_detail).to eq("daily")
    end

    it "colours a count green when all passed, in the warning colour from 75 %, red below" do
      count = AvailableServices::Entry::Count

      expect(count.new(15, 15).tone).to eq(:pass)
      expect(count.new(3, 4).tone).to eq(:warn)
      expect(count.new(74, 100).tone).to eq(:fail)
      expect(count.new(1, 4).tone).to eq(:fail)
      expect(count.new(0, 0).tone).to eq(:neutral)
    end

    # passed includes the checks that ended in a warning, total is passed plus
    # failed: the page shows both as they are and names the warnings beside them.
    it "shows the linter's counts as the list gives them, with the warnings beside them" do
      passport = entry(linter: { "passports" => [{ "label" => "demo battery cell", "lint_url" => "https://dpplint.example.org/?productId=x",
                                                   "passed" => 4, "total" => 5, "failed" => 1, "warnings" => 2, "note" => nil }] }).passports.first

      expect(passport.count.text).to eq("4 of 5")
      expect(passport.count.tone).to eq(:warn)
      expect(passport.details).to eq(["2 warnings"])
    end

    it "shows no count the list cannot mean" do
      passport = entry(linter: { "passports" => [{ "label" => "x", "passed" => 6, "total" => 5 }] }).passports.first

      expect(passport.count).to be_nil
    end

    it "makes links of web addresses only" do
      e = entry(url: "javascript:alert(1)", linter: { "passports" => [{ "label" => "x", "lint_url" => "data:text/html,x" }] })

      expect(e.url).to be_nil
      expect(e.passports.first.lint_url).to be_nil
    end

    it "tolerates an entry that has nothing but a name" do
      e = described_class.new("name" => "Bare")

      expect([e.url, e.source, e.licence, e.linter_note, e.validator_count, e.validator_detail, e.validator_test_instance]).to all(be_nil)
      expect(e.provider).to eq("")
      expect(e.passports).to eq([])
    end
  end
end
