# frozen_string_literal: true

require "rails_helper"

# Every change bound to its author (docs/Integrity.md section 11): the token
# of a write names the request in its rqh claim (RequestBinding), and the
# write log keeps that token with what it binds before anything changes
# (WriteLog). DidTokenVerifier is stubbed; its own spec covers signatures.
RSpec.describe "Every change bound to its author", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:owner)      { "did:oyd:zQmWriteEvidenceOwner" }
  let(:stranger)   { "did:oyd:zQmWriteEvidenceStranger" }
  let(:dpp_id)     { "https://dpp.lumina.example/01/09520123456788/21/7001" }
  let(:product_id) { "https://id.lumina.example/01/09520123456788/21/7001" }
  let(:enc)        { CGI.escape(dpp_id) }

  def document(brand: "Lumina")
    { "digitalProductPassportId" => dpp_id, "uniqueProductIdentifier" => product_id, "granularity" => "item",
      "dppSchemaVersion" => "EN 18223:2026", "economicOperatorId" => owner,
      "elements" => [{ "elementId" => "BrandName", "objectType" => "SingleValuedDataElement", "value" => brand }] }
  end

  def token(did, claims = {})
    JWT.encode({ "iss" => did, "sub" => did, "jti" => SecureRandom.hex(8) }.merge(claims), nil, "none")
  end

  # A write with a token bound to exactly this request, unless +bind+ names
  # another one or is false.
  def write(method, path, body = nil, as: owner, bind: true, headers: {})
    raw = body.nil? || body.is_a?(String) ? body.to_s : JSON.generate(body)
    claims = bind ? { "rqh" => RequestBinding.digest(*(bind == true ? [method.to_s.upcase, path, raw] : bind)) } : {}
    @token = token(as, claims)
    send(method, path, params: raw,
                       headers: { "Content-Type" => "application/json", "Authorization" => "Bearer #{@token}" }
                                  .merge(headers))
  end

  def create!
    write(:post, "/dpp/v1/dpps", document)
    expect(response).to have_http_status(:created)
  end

  def entries(phase) = WriteEvent.where(phase: phase).order(:id)

  before do
    allow(DidTokenVerifier).to receive(:enabled?).and_return(true)
    allow(DidTokenVerifier).to receive(:call) do |raw|
      claims = begin
        JWT.decode(raw.to_s, nil, false).first
      rescue JWT::DecodeError
        nil
      end
      claims if claims && claims["iss"].to_s.start_with?("did:")
    end
  end

  describe "a write bound to its request" do
    it "is made, and the evidence is kept before the change and its outcome after" do
      create!

      expect(response.headers[RequestBinding::HEADER]).to be_nil
      request_entry = entries("request").sole
      expect(request_entry).to have_attributes(
        operation: "CreateDPP", issuer: owner, bound: true, http_method: "POST", target: "/dpp/v1/dpps",
        body_digest: RequestBinding.body_digest(JSON.generate(document)), token: @token
      )
      expect(request_entry.request_hash).to eq(JWT.decode(@token, nil, false).first["rqh"])
      expect(entries("outcome").sole).to have_attributes(request_id: request_entry.request_id, status: 201,
                                                        dpp_id: dpp_id, version_number: 1)
    end

    it "names the version every change produces, and the archived final one on delete" do
      create!
      write(:patch, "/dpp/v1/dpps/#{enc}", { "elements" => document(brand: "Lumina Nova")["elements"] },
            headers: { "Content-Type" => "application/merge-patch+json" })
      expect(response).to have_http_status(:ok)
      write(:patch, "/dpp/v1/dpps/#{enc}/elements/BrandName", { "value" => "Lumina Prime" },
            headers: { "Content-Type" => "application/merge-patch+json" })
      expect(response).to have_http_status(:ok)
      write(:delete, "/dpp/v1/dpps/#{enc}")
      expect(response).to have_http_status(:no_content)

      expect(entries("outcome").pluck(:operation, :status, :version_number)).to eq(
        [["CreateDPP", 201, 1], ["UpdateDPPById", 200, 2], ["UpdateDataElement", 200, 3],
         ["DeleteDPPById", 204, 3]]
      )
      expect(DppVersion.where(dpp_id: dpp_id).maximum(:version_number)).to eq(3)
    end

    it "binds the query too: a token over the path alone does not hold for the path with a query" do
      write(:post, "/dpp/v1/dpps?representation=full", document, bind: ["POST", "/dpp/v1/dpps", JSON.generate(document)])

      expect(response).to have_http_status(:unauthorized)
      expect(Dpp.count).to eq(0)
    end

    it "is refused when the token names another body, another target or another method, and nothing changes" do
      raw = JSON.generate(document)
      [["POST", "/dpp/v1/dpps", JSON.generate(document(brand: "Other"))],
       ["POST", "/dpp/v1/dppsByProductIds", raw],
       ["PUT", "/dpp/v1/dpps", raw]].each do |other|
        write(:post, "/dpp/v1/dpps", document, bind: other)

        expect(response).to have_http_status(:unauthorized), other.inspect
        expect(response.headers["WWW-Authenticate"]).to eq('Bearer error="invalid_token"')
        expect(response.parsed_body.dig("message", 0, "text")).to include("does not match method, target and body")
      end
      expect(Dpp.count).to eq(0)
      expect(WriteEvent.count).to eq(0)
    end

    it "records the attempt of a DID that may not write, with its outcome" do
      create!
      write(:patch, "/dpp/v1/dpps/#{enc}", { "elements" => [] }, as: stranger,
                                                                 headers: { "Content-Type" => "application/merge-patch+json" })

      expect(response).to have_http_status(:forbidden)
      expect(entries("request").last).to have_attributes(issuer: stranger, operation: "UpdateDPPById")
      expect(entries("outcome").last).to have_attributes(status: 403, version_number: 1)
    end
  end

  describe "a write without rqh" do
    before { allow(RequestBinding).to receive(:required_from).and_return(Date.new(2026, 12, 1)) }

    it "is taken until the day binding becomes required, says so, and is recorded as unbound" do
      travel_to(Time.utc(2026, 11, 30, 23, 59)) do
        write(:post, "/dpp/v1/dpps", document, bind: false)

        expect(response).to have_http_status(:created)
        expect(response.headers[RequestBinding::HEADER]).to eq('missing;until="2026-12-01"')
        expect(entries("request").sole).to have_attributes(bound: false, request_hash: nil)
      end
    end

    it "is refused from that day on, like a token that does not hold, and nothing changes" do
      travel_to(Time.utc(2026, 12, 1, 0, 0)) do
        write(:post, "/dpp/v1/dpps", document, bind: false)

        expect(response).to have_http_status(:unauthorized)
        expect(response.headers["WWW-Authenticate"]).to eq('Bearer error="invalid_token"')
        expect(response.parsed_body.dig("message", 0, "text")).to include("needs a bearer token bound to the request")
        expect(Dpp.count).to eq(0)
      end
    end

    it "is not asked of a read" do
      create!
      travel_to(Time.utc(2026, 12, 2)) do
        get "/dpp/v1/dpps/#{enc}", headers: { "Authorization" => "Bearer #{token(owner)}" }

        expect(response).to have_http_status(:ok)
        expect(response.headers[RequestBinding::HEADER]).to be_nil
      end
    end
  end

  describe "the write log" do
    it "refuses the write and changes nothing when its evidence cannot be kept" do
      allow(WriteLog).to receive(:request!).and_raise(ActiveRecord::StatementInvalid, "database gone")

      write(:post, "/dpp/v1/dpps", document)

      expect(response).to have_http_status(:internal_server_error)
      expect(response.parsed_body.dig("message", 0, "text")).to eq("The write could not be recorded, so it was not made")
      expect(Dpp.count).to eq(0)
    end

    it "keeps no content, and its entries cannot be changed or destroyed" do
      create!

      expect(WriteEvent.column_names).not_to include("content", "body", "document")
      entry = entries("request").sole
      expect { entry.update!(status: 200) }.to raise_error(ActiveRecord::ReadOnlyRecord)
      expect { entry.destroy }.to raise_error(WriteEvent::AppendOnly)
    end

    it "exports the entries of a passport for its owner, oldest first" do
      create!
      write(:delete, "/dpp/v1/dpps/#{enc}")

      exported = WriteLog.export(dpp_id: dpp_id).map(&:export)
      expect(exported.map { |e| [e["phase"], e["operation"]] }).to eq(
        [%w[request CreateDPP], %w[outcome CreateDPP], %w[request DeleteDPPById], %w[outcome DeleteDPPById]]
      )
      expect(exported.first.keys).to include("token", "rqh", "method", "target", "bodyDigest")
    end

    it "is not pruned while the passport or one of its versions exists, and only after the retention period" do
      create!
      write(:put, "/dpp/v1/access-policies", "{}")
      later = Time.now.utc + (WriteLog::RETENTION_DAYS + 1).days

      WriteLog.prune!(now: later)

      expect(WriteLog.export(dpp_id: dpp_id).count).to eq(2)
      expect(WriteEvent.where(operation: "registerAccessPolicy")).to be_empty
    end

    it "keeps nothing while tokens are not verified, and asks no binding" do
      allow(DidTokenVerifier).to receive(:enabled?).and_return(false)
      allow(RequestBinding).to receive(:required_from).and_return(Date.new(2000, 1, 1))

      write(:post, "/dpp/v1/dpps", document, bind: false)

      expect(response).to have_http_status(:created)
      expect(WriteEvent.count).to eq(0)
    end
  end
end
