# frozen_string_literal: true

require "rails_helper"
require_relative "../support/reading_with_access"

# The signature of the economic operator (docs/Integrity.md section 10,
# OperatorSignature): a JWS over the public part of a passport in the full
# representation, submitted by the owner, discarded by every write, checked
# again on reads, and handed out with Accept: application/jose only where it
# covers exactly the JSON the same request would get.
RSpec.describe "Signature of the economic operator", type: :request do
  include_context "reading with access rights"
  include ActiveSupport::Testing::TimeHelpers

  let(:other_key) { Ed25519::SigningKey.new(Digest::SHA256.digest("signature/other")) }
  let(:jose)      { { "Accept" => "application/jose" } }

  def b64u(bytes) = Base64.urlsafe_encode64(bytes, padding: false)
  def b64u_decode(str) = Base64.urlsafe_decode64(str + ("=" * ((4 - (str.length % 4)) % 4)))

  def jws_for(payload, key: owner_key, kid: "#{owner}#key-doc", header: {})
    head = b64u(JSON.generate({ "alg" => "EdDSA", "kid" => kid }.merge(header)))
    body = b64u(payload.is_a?(String) ? payload : JSON.generate(payload))
    "#{head}.#{body}.#{b64u(key.sign("#{head}.#{body}"))}"
  end

  def full_path = "/dpp/v1/dpps/#{enc}?representation=full"

  # The passport as a reader without access rights gets it, in the full
  # representation: what has to be signed.
  def public_full
    get full_path
    expect(response).to have_http_status(:ok)
    response.body
  end

  def submit(compact, as: owner)
    put "/dpp/v1/dpps/#{enc}/signature", params: compact,
                                          headers: { "Content-Type" => "application/jose",
                                                     "Authorization" => bearer(as) }
  end

  def sign!
    submit(jws_for(public_full))
    expect(response).to have_http_status(:ok)
  end

  def create_plain(economic_operator: owner)
    post "/dpp/v1/dpps", params: document.merge("economicOperatorId" => economic_operator).to_json,
                         headers: json_headers(owner)
    expect(response).to have_http_status(:created)
  end

  def state = response.headers["X-DPP-Signature-State"]
  def messages = response.parsed_body["message"]

  describe "a passport this service holds, without an access policy" do
    before { create_plain }

    it "is unsigned to begin with" do
      get full_path

      expect(state).to eq("none")
    end

    it "accepts the owner's signature over the public part in the full representation" do
      submit(jws_for(public_full))

      expect(response).to have_http_status(:ok)
      expect(state).to eq("signed")
      expect(messages.map { |m| m["messageType"] }).to eq(["Info"])
    end

    it "hands out the JWS on both read paths with Accept: application/jose and representation=full" do
      compact = jws_for(public_full)
      submit(compact)

      passport_paths.each do |path|
        get path, headers: jose

        expect(response).to have_http_status(:ok)
        expect(response.media_type).to eq("application/jose")
        expect(response.body).to eq(compact)
        expect(state).to eq("signed")
        expect(response.headers["Vary"]).to include("Accept")
      end
    end

    it "answers with the JSON the same request gets without a signature that covers it" do
      sign!

      get "/dpp/v1/dpps/#{enc}", headers: jose            # compressed: not what was signed
      expect(response.media_type).to eq("application/json")
      expect(response.parsed_body).to include("BrandName" => "Lumina")
      expect(state).to eq("signed")

      get full_path, headers: { "Accept" => "*/*" }       # no preference for JOSE
      expect(response.media_type).to eq("application/json")

      get full_path, headers: { "Accept" => "application/json, application/jose;q=0.5" }
      expect(response.media_type).to eq("application/json")

      get full_path, headers: { "Accept" => "application/vc+jwt, application/jwt;q=0.9, application/jose;q=0.8" }
      expect(response.media_type).to eq("application/jose")
    end

    it "lets a verifier compare the JWS with the JSON answer to the same request" do
      sign!

      get full_path
      delivered = response.parsed_body
      get full_path, headers: jose
      payload = JSON.parse(b64u_decode(response.body.split(".")[1]))

      expect(payload).to eq(delivered)
    end

    it "refuses a signature by another key under the owner's kid" do
      submit(jws_for(public_full, key: other_key))

      expect(response).to have_http_status(:bad_request)
      expect(messages.first["text"]).to include("does not verify")
      expect(state).to eq("none")
      get full_path, headers: jose
      expect(response.media_type).to eq("application/json")
    end

    it "refuses a kid of another DID, and a token of another DID" do
      submit(jws_for(public_full, kid: "#{nobody}#key-doc"))
      expect(response).to have_http_status(:forbidden)

      submit(jws_for(public_full), as: nobody)
      expect(response).to have_http_status(:forbidden)
    end

    it "refuses a kid that is not the document key" do
      submit(jws_for(public_full, kid: "#{owner}#key-rev"))

      expect(response).to have_http_status(:bad_request)
      expect(messages.first["text"]).to include("#key-doc")
    end

    it "refuses a payload that is not the passport as delivered now" do
      get "/dpp/v1/dpps/#{enc}"
      submit(jws_for(response.body))                       # the compressed representation
      expect(response).to have_http_status(:bad_request)
      expect(messages.first["text"]).to include("not the passport as it is delivered now")

      submit(jws_for(JSON.parse(public_full).merge("dppStatus" => "Archived")))
      expect(response).to have_http_status(:bad_request)
    end

    it "takes content, not bytes: another order of keys signs the same passport" do
      reordered = JSON.parse(public_full).to_a.reverse.to_h

      submit(jws_for(reordered))

      expect(response).to have_http_status(:ok)
    end

    it "refuses what is not a compact JWS with the expected header" do
      submit("")
      expect(response).to have_http_status(:bad_request)

      submit("not.a jws")
      expect(response).to have_http_status(:bad_request)

      submit(jws_for(public_full, header: { "alg" => "ES256" }))
      expect(response).to have_http_status(:bad_request)
      expect(messages.first["text"]).to include("EdDSA")

      submit(jws_for(public_full, header: { "b64" => false }))
      expect(response).to have_http_status(:bad_request)
    end

    it "needs the owner's bearer token" do
      put "/dpp/v1/dpps/#{enc}/signature", params: jws_for(public_full),
                                            headers: { "Content-Type" => "application/jose" }

      expect(response).to have_http_status(:unauthorized)
    end

    it "answers 404 for a passport it does not hold" do
      put "/dpp/v1/dpps/#{CGI.escape('did:oyd:zQmUnknown')}/signature", params: jws_for(public_full),
                                                                       headers: { "Authorization" => bearer(owner) }

      expect(response).to have_http_status(:not_found)
    end

    it "takes the body as it is, whatever Content-Type it is sent with" do
      put "/dpp/v1/dpps/#{enc}/signature", params: jws_for(public_full), headers: json_headers(owner)

      expect(response).to have_http_status(:ok)
    end

    it "is not accepted while bearer tokens are not verified" do
      compact = jws_for(public_full)
      allow(DidTokenVerifier).to receive(:enabled?).and_return(false)

      submit(compact)

      expect(response).to have_http_status(:forbidden)
    end

    describe "earlier versions" do
      def version_path(time, full: true)
        "/dpp/v1/dppsByIdAndDate/#{enc}?date=#{CGI.escape(time.utc.iso8601)}#{full ? '&representation=full' : ''}"
      end

      it "keep the signature they were signed with, and hand it out for exactly that version" do
        compact = jws_for(public_full)
        submit(compact)
        signed_at = Time.now.utc
        travel 2.seconds
        update_passport(brand: "Lumina Pro")

        get version_path(signed_at), headers: jose
        expect(response.media_type).to eq("application/jose")
        expect(response.body).to eq(compact)
        expect(state).to eq("signed")

        get version_path(signed_at)
        expect(response.media_type).to eq("application/json")
        expect(state).to eq("signed")

        get version_path(signed_at, full: false), headers: jose
        expect(response.media_type).to eq("application/json")
        expect(state).to eq("none")
      end

      it "keep no signature where the version was not signed, nor for the current one that waits for one" do
        update_passport(brand: "Lumina Pro")
        travel 2.seconds

        get version_path(1.second.ago), headers: jose
        expect(response.media_type).to eq("application/json")
        expect(state).to eq("none")

        sign!
        get version_path(Time.now.utc + 60), headers: jose
        expect(response.media_type).to eq("application/jose")
      end

      it "keep it after the passport is deleted, with its final version" do
        compact = jws_for(public_full)
        submit(compact)
        signed_at = Time.now.utc
        travel 2.seconds
        update_passport(brand: "Lumina Pro")
        travel 2.seconds
        delete "/dpp/v1/dpps/#{enc}", headers: json_headers(owner)
        expect(response).to have_http_status(:no_content)

        get version_path(signed_at), headers: jose
        expect(response.body).to eq(compact)
      end
    end

    describe "after a write" do
      it "discards the signature, and the passport waits for a new one" do
        sign!

        update_passport(brand: "Lumina Pro")

        expect(state).to eq("pending")
        expect(Dpp.find(dpp_id).signature_jws).to be_nil
        get full_path, headers: jose
        expect(response.media_type).to eq("application/json")
        expect(state).to eq("pending")
      end

      it "refuses the old signature and accepts one over the new passport" do
        old = jws_for(public_full)
        submit(old)
        update_passport(brand: "Lumina Pro")

        submit(old)
        expect(response).to have_http_status(:bad_request)

        sign!
        get full_path, headers: jose
        expect(response.media_type).to eq("application/jose")
      end

      it "discards it on the fine-granular writes as well" do
        sign!

        patch "/dpp/v1/dpps/#{enc}/elements/BrandName", params: { "value" => "Lumina Pro" }.to_json,
                                                         headers: json_headers(owner, "Content-Type" => "application/merge-patch+json")

        expect(response).to have_http_status(:ok)
        expect(state).to eq("pending")
      end

      it "never hands out a signature the passport no longer matches, whichever path changed it" do
        sign!
        dpp = Dpp.find(dpp_id)
        dpp.update_columns(content: dpp.content.merge("dppStatus" => "Archived"), dpp_status: "Archived")

        get full_path, headers: jose

        expect(response.media_type).to eq("application/json")
        expect(state).to eq("pending")
      end
    end

    describe "when the key is checked again" do
      it "stops handing out a signature that no longer verifies, and resumes once it does" do
        compact = jws_for(public_full)
        submit(compact)

        travel(OperatorSignature::RECHECK_INTERVAL + 1)
        allow(DidTokenVerifier).to receive(:public_key_for).with(owner).and_return(other_key.verify_key)
        get full_path, headers: jose
        expect(response.media_type).to eq("application/json")
        expect(state).to eq("stale")

        travel(OperatorSignature::RECHECK_INTERVAL + 1)
        allow(DidTokenVerifier).to receive(:public_key_for).with(owner).and_return(owner_key.verify_key)
        get full_path, headers: jose
        expect(response.body).to eq(compact)
        expect(state).to eq("signed")
      end

      it "is stale when the DID cannot be resolved" do
        sign!

        travel(OperatorSignature::RECHECK_INTERVAL + 1)
        allow(DidTokenVerifier).to receive(:public_key_for).with(owner).and_return(nil)
        get full_path, headers: jose

        expect(response.media_type).to eq("application/json")
        expect(state).to eq("stale")
      end

      it "does not resolve again within the interval" do
        sign!
        resolved = 0
        allow(DidTokenVerifier).to receive(:public_key_for) { (resolved += 1) && owner_key.verify_key }

        get full_path, headers: jose
        travel(OperatorSignature::RECHECK_INTERVAL - 10)
        get full_path, headers: jose

        expect(resolved).to eq(0)
        expect(state).to eq("signed")
      end
    end
  end

  describe "a signer that is not the economicOperatorId" do
    before { create_plain(economic_operator: "did:oyd:zQmManufacturer") }

    it "is accepted as an authorised representative, and the answer says so" do
      submit(jws_for(public_full))

      expect(response).to have_http_status(:ok)
      expect(state).to eq("signed")
      expect(messages.first["messageType"]).to eq("Warning")
      expect(messages.first["text"]).to include("not the economicOperatorId did:oyd:zQmManufacturer")
    end
  end

  describe "a passport this service holds with a controlled part" do
    before do
      create_locally
      grant_roles!
    end

    it "is signed over the public part, which names the controlled part and carries none of it" do
      compact = jws_for(public_full)
      submit(compact)
      expect(response).to have_http_status(:ok)

      get full_path, headers: jose
      expect(response.body).to eq(compact)
      payload = JSON.parse(b64u_decode(compact.split(".")[1]))
      ids = payload["elements"].map { |element| element["elementId"] }
      expect(ids).to contain_exactly("BrandName", "ControlledData")
      expect(JSON.generate(payload)).not_to include("SN-0921", "OnModePower", "ControlledDataSalt")
    end

    it "hands no archived signature out when the public part of the version reads differently today" do
      compact = jws_for(public_full)
      submit(compact)
      signed_at = Time.now.utc
      travel 2.seconds
      update_passport(brand: "Lumina Pro")
      version_path = "/dpp/v1/dppsByIdAndDate/#{enc}?date=#{CGI.escape(signed_at.iso8601)}&representation=full"

      get version_path, headers: jose
      expect(response.body).to eq(compact)

      looser = policy_doc.merge("id" => "https://dpp.example.org/access-policies/cap-020/2",
                                "rules" => [{ "path" => "OnModePower", "accessClass" => "authority" }])
      put "/dpp/v1/access-policies", params: looser.to_json, headers: json_headers(owner)
      expect(response).to have_http_status(:created)
      update_passport({ "X-DPP-Access-Policy" => looser["id"] }, brand: "Lumina Pro")

      get version_path, headers: jose
      expect(response.media_type).to eq("application/json")
      expect(element_ids(response.parsed_body)).to include("SerialNumber")
      expect(state).to eq("none")
    end

    it "hands no signature to a reader with access rights, whose passport has more than was signed" do
      sign!

      { "li" => %w[BrandName SerialNumber], "au" => %w[BrandName SerialNumber OnModePower],
        "owner" => %w[BrandName SerialNumber OnModePower] }.each do |role, attributes|
        get full_path, headers: jose.merge("Authorization" => bearer(who(role)))

        expect(response.media_type).to eq("application/json")
        expect(element_ids(response.parsed_body)).to include(*attributes)
        expect(state).to eq("signed")
      end
    end

    it "hands it to a reader with a token but without access rights, who gets the public part" do
      compact = jws_for(public_full)
      submit(compact)

      get full_path, headers: jose.merge("Authorization" => bearer(nobody))

      expect(response.body).to eq(compact)
    end

    it "refuses a signature over the owner's view, which is more than the public part" do
      get full_path, headers: { "Authorization" => bearer(owner) }
      whole = response.body

      submit(jws_for(whole))

      expect(response).to have_http_status(:bad_request)
    end

    it "is discarded when the controlled part changes" do
      sign!

      update_passport(serial: "SN-0922")

      expect(state).to eq("pending")
    end
  end

  describe "a passport held by a custodian" do
    before { create_at_pod(with_policy: false) }

    it "is refused: the custodian serves it, not this service" do
      submit(jws_for(public_full))

      expect(response).to have_http_status(:bad_request)
      expect(messages.first["text"]).to include("held by a custodian")
      expect(state).to eq("none")
    end
  end
end
