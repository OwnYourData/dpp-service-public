# frozen_string_literal: true

require "rails_helper"
require_relative "../support/reading_with_access"

# Reading per role (docs/AccessClasses.md §8, PassportAccess): every read path
# gives a reader without access rights the public part, a reader holding an
# access grant the attributes of the classes it may read, the owner the whole
# passport -- for the passport as it stands and for its earlier versions, at a
# custodian and in this service's own database.
#
# The passport mirrors the one on dpp-staging: BrandName public, SerialNumber
# legitimateInterest, OnModePower authority.
# Which attributes each reader gets: nil reads without a token, "nobody" with a
# token but no grant, "li" holds legitimateInterest, "au" authority.
expected_attributes = {
  nil => %w[BrandName],
  "nobody" => %w[BrandName],
  "li" => %w[BrandName SerialNumber],
  "au" => %w[BrandName SerialNumber OnModePower],
  "owner" => %w[BrandName SerialNumber OnModePower]
}.freeze

RSpec.describe "Reading with access rights", type: :request do
  include_context "reading with access rights"

  describe "a passport at a custodian that holds controlled cards" do
    before do
      create_at_pod
      grant_roles!
    end

    expected_attributes.each do |role, attributes|
      it "gives #{role || 'a reader without a token'} exactly #{attributes.join(', ')} on ReadDPPById and ReadDPPByProductId" do
        passport_paths.each do |path|
          read(path, as: who(role))

          expect(response).to have_http_status(:ok)
          expect(element_ids(response.parsed_body)).to contain_exactly(*attributes)
          expect(response.headers["Vary"]).to include("Authorization")
        end
      end
    end

    it "keeps the public header and ControlledData, and never hands out the salt" do
      read(passport_paths.first, as: au_reader)

      body = response.parsed_body
      expect(body["digitalProductPassportId"]).to eq(dpp_id)
      expect(PassportSplit.named_digest(body)).to eq(PassportSplit.named_digest(pod.public_payload(dpp_id)))
      expect(response.body).not_to include("ControlledDataSalt")
    end

    it "says which classes it applied, and keeps the answer from every cache" do
      read(passport_paths.first, as: li_reader)
      expect(response.headers["X-DPP-Access-Roles"]).to eq("legitimateInterest")
      expect(response.headers["Cache-Control"]).to eq("private, no-store")

      read(passport_paths.first, as: au_reader)
      expect(response.headers["X-DPP-Access-Roles"]).to eq("legitimateInterest, authority")

      read(passport_paths.first)
      expect(response.headers["X-DPP-Access-Roles"]).to be_nil
    end

    it "filters the fine-granular read paths the same way" do
      read("/dpp/v1/dpps/#{enc}/elements/SerialNumber", as: li_reader)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq("SN-0921")

      read("/dpp/v1/dpps/#{enc}/elements/OnModePower", as: li_reader)
      expect(response).to have_http_status(:not_found)

      read("/dpp/v1/dpps/#{enc}/elements/OnModePower", as: au_reader)
      expect(response.parsed_body).to eq(7.5)

      read("/dpp/v1/dpps/#{enc}/elements/SerialNumber")
      expect(response).to have_http_status(:not_found)
    end

    it "reads the controlled card under the service's own read grant" do
      pod.headers.clear
      read(passport_paths.first, as: li_reader)

      reads = pod.headers.select { |_, path, _| path.end_with?("/read") }
      expect(reads).not_to be_empty
      expect(reads.map(&:last)).to all(start_with("DPoP read-token-"))
    end

    it "does not read the controlled card for a reader without access rights" do
      pod.log.clear
      read(passport_paths.first, as: nobody)

      expect(pod.log.grep(%r{/object/})).to be_empty
    end

    it "refuses a token that does not hold with 401 instead of reading past it" do
      get passport_paths.first, headers: { "Authorization" => "Bearer not-a-token" }

      expect(response).to have_http_status(:unauthorized)
    end

    it "gives nothing more for a grant on another passport, a revoked or an expired one" do
      AccessGrant.where(subject_did: li_reader).update_all(dpp_ids: ["did:oyd:zQmOther"])
      read(passport_paths.first, as: li_reader)
      expect(element_ids(response.parsed_body)).to eq(%w[BrandName])

      AccessGrant.where(subject_did: au_reader).update_all(revoked_at: Time.now.utc)
      read(passport_paths.first, as: au_reader)
      expect(element_ids(response.parsed_body)).to eq(%w[BrandName])

      AccessGrant.where(subject_did: au_reader).update_all(revoked_at: nil, expires_at: 1.day.ago)
      read(passport_paths.first, as: au_reader)
      expect(element_ids(response.parsed_body)).to eq(%w[BrandName])
    end

    it "stops giving authority when its issuer leaves the list" do
      allow(ENV).to receive(:[]).with("DPP_AUTHORITY_ISSUERS").and_return(nil)
      read(passport_paths.first, as: au_reader)

      expect(element_ids(response.parsed_body)).to eq(%w[BrandName])
    end

    it "answers 502 and hands out nothing of a controlled part that does not match its digest" do
      card = pod.cards.values.find { |c| c.type == FakePod::CONTROLLED }
      tampered = card.payloads.last.deep_dup
      tampered["elements"].find { |e| e["elementId"] == "SerialNumber" }["value"] = "SN-FORGED"
      card.payloads << tampered
      card.stamps << card.stamps.last

      read(passport_paths.first, as: li_reader)
      expect(response).to have_http_status(:bad_gateway)
      expect(response.body).not_to include("SN-FORGED", "SN-0921")

      read(passport_paths.first)
      expect(response).to have_http_status(:ok)
    end

    describe "earlier versions" do
      before do
        update_passport(serial: "SN-NEW", power: 9.0, brand: "Lumina 2")
      end

      def at(tick) = CGI.escape(pod.time_of(tick).iso8601)

      def card_stamps(type) = pod.cards.values.find { |c| c.type == type }.stamps

      def version_path(tick) = "/dpp/v1/dppsByIdAndDate/#{enc}?representation=full&date=#{at(tick)}"

      it "gives each role exactly its attributes of the earlier version" do
        first_public = card_stamps(FakePod::PUBLIC).first

        { nil => [nil, nil], li_reader => ["SN-0921", nil], au_reader => ["SN-0921", 7.5],
          owner => ["SN-0921", 7.5] }.each do |as, (serial, power)|
          read(version_path(first_public), as: as)

          expect(response).to have_http_status(:ok)
          expect(value_of(response.parsed_body, "BrandName")).to eq("Lumina")
          expect(value_of(response.parsed_body, "SerialNumber")).to eq(serial)
          expect(value_of(response.parsed_body, "OnModePower")).to eq(power)
        end
      end

      it "finds the controlled version the public version names when the controlled card is already ahead" do
        second_controlled = card_stamps(FakePod::CONTROLLED).last
        expect(card_stamps(FakePod::PUBLIC).last).to be > second_controlled

        read(version_path(second_controlled), as: au_reader)

        expect(value_of(response.parsed_body, "BrandName")).to eq("Lumina")
        expect(value_of(response.parsed_body, "OnModePower")).to eq(7.5)
      end

      it "says the controlled part is unavailable when the custodian serves no versions of it" do
        pod.controlled_versions = false
        read(version_path(card_stamps(FakePod::PUBLIC).first), as: au_reader)

        expect(response).to have_http_status(:ok)
        expect(response.headers["X-DPP-Controlled-Part"]).to eq("unavailable")
        expect(element_ids(response.parsed_body)).to eq(%w[BrandName])
      end
    end
  end

  describe "an earlier version of a passport classified only later" do
    before do
      create_at_pod(with_policy: false)
      grant_roles!
      update_passport({ "X-DPP-Access-Policy" => policy_doc["id"] })
    end

    it "is filtered by today's policy, also for readers without access rights" do
      first = pod.cards.values.find { |c| c.type == FakePod::PUBLIC }.stamps.first
      path = "/dpp/v1/dppsByIdAndDate/#{enc}?representation=full&date=#{CGI.escape(pod.time_of(first).iso8601)}"

      read(path)
      expect(element_ids(response.parsed_body)).to eq(%w[BrandName])

      read(path, as: li_reader)
      expect(element_ids(response.parsed_body)).to contain_exactly("BrandName", "SerialNumber")
    end
  end

  describe "a passport held by this service" do
    before do
      create_locally
      grant_roles!
    end

    expected_attributes.each do |role, attributes|
      it "gives #{role || 'a reader without a token'} exactly #{attributes.join(', ')}" do
        read(passport_paths.first, as: who(role))

        expect(response).to have_http_status(:ok)
        expect(element_ids(response.parsed_body)).to contain_exactly(*attributes)
      end
    end

    it "commits to the public part, which is what a reader without access rights gets" do
      read(passport_paths.first)

      expect(JSON.generate(Dpp.find(dpp_id).published_document)).to eq(response.body)
    end

    it "gives each role its attributes of an earlier version, also after the passport is deleted" do
      update_passport(serial: "SN-NEW", power: 9.0)
      path = "/dpp/v1/dppsByIdAndDate/#{enc}?representation=full&date=#{CGI.escape(1.hour.ago.utc.iso8601)}"

      read(path, as: li_reader)
      expect(value_of(response.parsed_body, "SerialNumber")).to eq("SN-0921")
      expect(value_of(response.parsed_body, "OnModePower")).to be_nil

      delete "/dpp/v1/dpps/#{enc}", headers: { "Authorization" => bearer(owner) }
      expect(response).to have_http_status(:no_content)

      read(path)
      expect(element_ids(response.parsed_body)).to eq(%w[BrandName])

      read(path, as: au_reader)
      expect(value_of(response.parsed_body, "OnModePower")).to eq(7.5)
    end
  end

  describe "while tokens are not verified" do
    it "gives every reader the public part, the owner included" do
      create_locally
      allow(DidTokenVerifier).to receive(:enabled?).and_return(false)

      read(passport_paths.first, as: owner)

      expect(element_ids(response.parsed_body)).to eq(%w[BrandName])
    end
  end
end
