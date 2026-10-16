# frozen_string_literal: true

require "rails_helper"
require "rake"
require_relative "../support/reading_with_access"

# The access log and revoking access grants (docs/AccessClasses.md §7, §10;
# AccessLog, AccessEvent): every read of the controlled part is logged with
# reader, classes, grants, passport and time; a reader without a valid access
# right is refused and logged; a revoked grant counts no more from the moment
# it is revoked; every read under the service's read grant has exactly one
# entry; owner, reader and issuer each see their entries, the operator all.
RSpec.describe "Access log and revoking access grants", type: :request do
  include_context "reading with access rights"

  let(:path)  { "/dpp/v1/dpps/#{enc}?representation=full" }
  let(:li_jti) { "li-1" }
  let(:au_jti) { "au-1" }

  before(:all) do
    Rails.application.load_tasks if Rake::Task.tasks.none? { |t| t.name == "dpp:access:revoke" }
  end

  def grant_named_roles!
    register_grant(grant(issuer: owner, key: owner_key, sub: li_reader, roles: ["legitimateInterest"], jti: li_jti),
                   as: owner)
    expect(response).to have_http_status(:created)
    register_grant(grant(issuer: au_issuer, key: issuer_key, sub: au_reader, roles: ["authority"], jti: au_jti),
                   as: au_issuer)
    expect(response).to have_http_status(:created)
  end

  def revoke(jti, as:)
    delete "/dpp/v1/access-grants/#{jti}", headers: { "Authorization" => bearer(as) }
  end

  def access_log(as:, **query)
    get "/dpp/v1/access-log", params: query, headers: as ? { "Authorization" => bearer(as) } : {}
  end

  def entries(event = nil) = AccessEvent.order(:id).then { |s| event ? s.where(event: event) : s }.to_a

  def controlled_reads = pod.log.grep(%r{\AGET /object/\d+/read\z})

  describe "reading a passport with an access policy at a custodian" do
    before do
      create_at_pod
      grant_named_roles!
    end

    it "logs a read with access rights with reader, classes, grant, passport, operation, status and time" do
      read(path, as: li_reader)
      expect(response).to have_http_status(:ok)

      entry = entries("read").last
      expect(entry).to have_attributes(dpp_id: dpp_id, owner_did: owner, reader_did: li_reader,
                                       roles: ["legitimateInterest"], basis: "grant",
                                       grants: [{ "iss" => owner, "jti" => li_jti }],
                                       operation: "ReadDPPById", status: 200, custodian: held)
      expect(entry.occurred_at).to be_within(5.seconds).of(Time.now.utc)
      expect(entry.request_id).to eq(response.headers["X-Request-Id"])
      expect(entry.controlled_digest).to eq(PassportSplit.named_digest(pod.public_payload(dpp_id)))
      expect(entry.pod_object_id).to eq(Dpp.find(dpp_id).storage_controlled_object_id)
    end

    it "logs each role, the owner included, and names the operation" do
      read(path, as: au_reader)
      read(path, as: owner)
      read("/dpp/v1/dpps/#{enc}/elements/SerialNumber", as: li_reader)
      read("/dpp/v1/dppsByProductId/#{CGI.escape(product_id)}", as: li_reader)

      reads = entries("read")
      expect(reads.map { |e| [e.reader_did, e.basis, e.roles, e.operation] }).to eq(
        [[au_reader, "grant", %w[legitimateInterest authority], "ReadDPPById"],
         [owner, "owner", %w[legitimateInterest authority], "ReadDPPById"],
         [li_reader, "grant", ["legitimateInterest"], "ReadDataElement"],
         [li_reader, "grant", ["legitimateInterest"], "ReadDPPByProductId"]]
      )
      expect(reads.first.grants).to eq([{ "iss" => au_issuer, "jti" => au_jti }])
      expect(reads.second.grants).to be_nil
    end

    it "logs the 404 of an element the reader may not read" do
      read("/dpp/v1/dpps/#{enc}/elements/OnModePower", as: li_reader)

      expect(response).to have_http_status(:not_found)
      expect(entries("read").last.status).to eq(404)
    end

    it "does not log a reader without a token" do
      read(path)
      read("/dpp/v1/dpps/#{enc}/elements/BrandName")

      expect(AccessEvent.where.not(event: "grantRegistered")).to be_empty
    end

    it "refuses a reader with a token and no access right, and logs it" do
      read(path, as: nobody)

      expect(element_ids(response.parsed_body)).to eq(%w[BrandName])
      expect(entries("refused").last).to have_attributes(reader_did: nobody, owner_did: owner, dpp_id: dpp_id,
                                                         reason: "noGrant", status: 200,
                                                         operation: "ReadDPPById")
      expect(controlled_reads).to be_empty
    end

    it "logs an integrity error as such, with 502, and the extra read as a retry" do
      card = pod.cards.values.find { |c| c.type == FakePod::CONTROLLED }
      tampered = card.payloads.last.deep_dup
      tampered["elements"].find { |e| e["elementId"] == "SerialNumber" }["value"] = "SN-FORGED"
      card.payloads << tampered
      pod.log.clear

      read(path, as: li_reader)

      expect(response).to have_http_status(:bad_gateway)
      expect(entries("integrityError").last).to have_attributes(reader_did: li_reader, status: 502)
      expect(entries("serviceRead").map(&:reason)).to eq(["retry"])
    end

    it "has exactly one entry for every read under the read grant, lookups included" do
      Dpp.find(dpp_id).update_column(:storage_controlled_object_id, nil)
      pod.log.clear

      read(path, as: li_reader)
      read(path, as: au_reader)
      read(path, as: nobody)

      grant_reads = pod.headers.select { |method, _, auth| method == :get && auth.to_s.start_with?("DPoP read-token-") }
      logged = AccessEvent.where.not(pod_path: nil)
      expect(logged.count).to eq(grant_reads.size)
      expect(entries("serviceRead").map(&:reason)).to all(eq("lookup"))
      expect(entries("read").map(&:pod_path)).to all(match(%r{\A/object/\d+/read\z}))
      expect(entries("serviceRead").map(&:owner_did)).to all(eq(owner))
    end

    it "logs the version date of ReadDPPVersionByIdAndDate" do
      first = pod.cards.values.find { |c| c.type == FakePod::PUBLIC }.stamps.first
      date = pod.time_of(first)
      read("/dpp/v1/dppsByIdAndDate/#{enc}?representation=full&date=#{CGI.escape(date.iso8601)}", as: au_reader)

      expect(entries("read").last).to have_attributes(operation: "ReadDPPVersionByIdAndDate", version_date: date)
    end

    it "does not send the controlled part when its entry cannot be written" do
      allow(AccessEvent).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, "disk full")

      read(path, as: li_reader)

      expect(response).to have_http_status(:internal_server_error)
      expect(response.body).not_to include("SN-0921")
      expect(response.headers["X-DPP-Access-Roles"]).to be_nil
    end

    it "still answers a reader without a token when the log cannot be written" do
      allow(AccessEvent).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, "disk full")

      read(path)

      expect(response).to have_http_status(:ok)
    end
  end

  describe "a passport without an access policy" do
    it "logs nothing, with or without a token" do
      create_at_pod(with_policy: false)

      read(path, as: nobody)
      read(path, as: owner)

      expect(AccessEvent.count).to eq(0)
    end
  end

  describe "a passport held by this service" do
    it "logs reads and refusals the same way, without a custodian" do
      create_locally
      grant_named_roles!

      read(path, as: li_reader)
      read(path, as: nobody)

      expect(entries("read").last).to have_attributes(reader_did: li_reader, custodian: nil)
      expect(entries("refused").last.reason).to eq("noGrant")
    end
  end

  describe "revoking" do
    before do
      create_at_pod
      grant_named_roles!
    end

    it "lets the issuer revoke its grant, with effect on the next read, and logs both" do
      read(path, as: li_reader)
      expect(value_of(response.parsed_body, "SerialNumber")).to eq("SN-0921")

      revoke(li_jti, as: owner)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("jti" => li_jti, "revoked" => true, "revokedBy" => owner)

      read(path, as: li_reader)
      expect(element_ids(response.parsed_body)).to eq(%w[BrandName])

      expect(entries("grantRevoked").last.details).to include("issuer" => owner, "revokedBy" => owner)
      expect(entries("refused").last).to have_attributes(
        reader_did: li_reader, reason: "revoked", grants: [{ "iss" => owner, "jti" => li_jti }]
      )
    end

    it "answers a second revocation with the same result and logs it once" do
      revoke(li_jti, as: owner)
      revoked_at = response.parsed_body["revokedAt"]
      revoke(li_jti, as: owner)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["revokedAt"]).to eq(revoked_at)
      expect(entries("grantRevoked").size).to eq(1)
    end

    it "does not bring a revoked grant back when it is registered again" do
      token = grant(issuer: owner, key: owner_key, sub: li_reader, roles: ["legitimateInterest"], jti: "again")
      register_grant(token, as: owner)
      revoke("again", as: owner)
      register_grant(token, as: owner)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["revoked"]).to be(true)
    end

    it "lets nobody but the issuer revoke: the owner cannot revoke an authority grant" do
      revoke(au_jti, as: owner)
      expect(response).to have_http_status(:not_found)

      revoke(au_jti, as: nil)
      expect(response).to have_http_status(:unauthorized)

      read(path, as: au_reader)
      expect(value_of(response.parsed_body, "OnModePower")).to eq(7.5)
    end

    it "names an expired grant as the reason of a refusal" do
      AccessGrant.find_by(jti: li_jti).update_columns(expires_at: 1.day.ago)

      read(path, as: li_reader)

      expect(entries("refused").last).to have_attributes(reason: "expired",
                                                         grants: [{ "iss" => owner, "jti" => li_jti }])
    end
  end

  describe "GET /dpp/v1/access-log" do
    before do
      create_at_pod
      grant_named_roles!
      read(path, as: li_reader)
      read(path, as: au_reader)
      read(path, as: nobody)
      read(path, as: owner)
    end

    def listed = response.parsed_body["entries"]

    it "gives the owner every entry of its passports, newest first" do
      access_log(as: owner)

      expect(response).to have_http_status(:ok)
      expect(listed.map { |e| [e["event"], e["reader"]] }).to eq(
        [["read", owner], ["refused", nobody], ["read", au_reader], ["read", li_reader],
         ["grantRegistered", nil]]
      )
      expect(listed.first).to include("dppId" => dpp_id, "roles" => %w[legitimateInterest authority],
                                      "basis" => "owner", "operation" => "ReadDPPById", "status" => 200)
      expect(listed.first["custodian"]).to include("host" => held)
    end

    it "gives a reader its own entries and nothing about other readers" do
      access_log(as: li_reader)

      expect(listed.map { |e| [e["event"], e["reader"]] }).to eq([["read", li_reader]])
      expect(listed.first["grants"]).to eq([{ "iss" => owner, "jti" => li_jti }])

      access_log(as: nobody)
      expect(listed.map { |e| e["event"] }).to eq(["refused"])
    end

    it "gives an issuer its grants and the reads made under them" do
      access_log(as: au_issuer)

      expect(listed.map { |e| [e["event"], e["reader"]] }).to eq([["read", au_reader], ["grantRegistered", nil]])
      expect(listed.last).to include("issuer" => au_issuer, "grant" => include("jti" => au_jti, "sub" => au_reader))
    end

    it "never gives out tokens or content" do
      access_log(as: owner)

      expect(response.body).not_to include("SN-0921", "eyJ", "read-token-", "ControlledDataSalt")
    end

    it "filters by event, passport and time, and pages with a cursor" do
      access_log(as: owner, event: "read", limit: 2)
      expect(listed.map { |e| e["reader"] }).to eq([owner, au_reader])
      cursor = response.parsed_body["next"]
      expect(cursor).to be_present

      access_log(as: owner, event: "read", limit: 2, after: cursor)
      expect(listed.map { |e| e["reader"] }).to eq([li_reader])
      expect(response.parsed_body).not_to have_key("next")

      access_log(as: owner, dppId: "did:oyd:zQmOther")
      expect(listed).to be_empty

      access_log(as: owner, since: 1.minute.from_now.utc.iso8601)
      expect(listed).to be_empty
    end

    it "refuses an unknown event, a malformed time or cursor, and a request without token" do
      access_log(as: owner, event: "everything")
      expect(response).to have_http_status(:bad_request)

      access_log(as: owner, since: "yesterday")
      expect(response).to have_http_status(:bad_request)

      access_log(as: owner, after: "x")
      expect(response).to have_http_status(:bad_request)

      access_log(as: nil)
      expect(response).to have_http_status(:unauthorized)
    end

    it "is not available while tokens are not verified" do
      allow(DidTokenVerifier).to receive(:enabled?).and_return(false)

      access_log(as: owner)

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "the operator's tasks" do
    def run(task, env = {})
      env.each { |k, v| ENV[k] = v }
      output = StringIO.new
      $stdout = output
      $stderr = StringIO.new
      Rake::Task[task].reenable
      Rake::Task[task].invoke
      output.string
    ensure
      $stdout = STDOUT
      $stderr = STDERR
      env.each_key { |k| ENV.delete(k) }
    end

    before do
      create_at_pod
      grant_named_roles!
    end

    it "revokes on order, with a reason, and the issuer sees it" do
      expect { run("dpp:access:revoke", "ISSUER" => owner, "JTI" => li_jti) }.to raise_error(SystemExit)

      out = run("dpp:access:revoke", "ISSUER" => owner, "JTI" => li_jti, "REASON" => "order 2026-17")
      expect(out).to start_with("revoked:")

      grant = AccessGrant.find_by(jti: li_jti)
      expect(grant).to have_attributes(revoked_by: "operator", revocation_reason: "order 2026-17")

      read(path, as: li_reader)
      expect(entries("refused").last.reason).to eq("revoked")

      access_log(as: owner, event: "grantRevoked")
      expect(response.parsed_body["entries"].first).to include("revokedBy" => "operator",
                                                                "revocationReason" => "order 2026-17")
    end

    it "prints the whole log as JSON lines" do
      read(path, as: li_reader)
      read(path, as: nobody)

      lines = run("dpp:access:log", "LIMIT" => "10").lines.map { |line| JSON.parse(line) }
      expect(lines.map { |e| e["event"] }).to eq(%w[refused read grantRegistered grantRegistered])

      lines = run("dpp:access:log", "EVENT" => "read").lines.map { |line| JSON.parse(line) }
      expect(lines.map { |e| e["reader"] }).to eq([li_reader])
    end

    it "prunes only entries older than the retention period" do
      read(path, as: li_reader)
      old = AccessEvent.order(:id).first
      AccessEvent.where(id: old.id).update_all(occurred_at: (AccessLog::RETENTION_DAYS + 1).days.ago)

      out = run("dpp:access:prune")

      expect(out).to start_with("1 entries")
      expect(AccessEvent.exists?(old.id)).to be(false)
      expect(AccessEventParty.where(access_event_id: old.id)).to be_empty
      expect(entries("read").size).to eq(1)
    end
  end

  describe "entries" do
    it "cannot be changed or destroyed" do
      create_at_pod
      read(path, as: owner)
      entry = AccessEvent.last

      expect { entry.update!(reader_did: "did:oyd:zQmSomeoneElse") }.to raise_error(ActiveRecord::ReadOnlyRecord)
      expect { AccessEvent.find(entry.id).destroy }.to raise_error(AccessEvent::AppendOnly)
      expect { entry.parties.first.update!(did: "x") }.to raise_error(ActiveRecord::ReadOnlyRecord)
    end
  end
end
