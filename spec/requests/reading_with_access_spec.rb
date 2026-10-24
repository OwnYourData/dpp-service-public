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
      expect(response).to have_http_status(:forbidden)

      read("/dpp/v1/dpps/#{enc}/elements/OnModePower", as: au_reader)
      expect(response.parsed_body).to eq(7.5)

      read("/dpp/v1/dpps/#{enc}/elements/SerialNumber")
      expect(response).to have_http_status(:unauthorized)
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

    # The custodian has not entered this service as reader of the passport's
    # collection (anymore): it answers the read grant with invalid_grant. A
    # reader with access rights then gets what a reader without them gets, the
    # public part, with 200; the answer and the access log say why, and
    # nothing is read at the custodian.
    describe "at a collection without this service's reader" do
      let(:unavailable) { "unavailable;reason=readerNotEntered" }
      let(:date) { CGI.escape(Time.now.utc.iso8601) }

      before do
        read(passport_paths.first)
        @public_body = response.parsed_body
        pod.readers.clear
        pod.withdraw_read_tokens!
        PodStorage.reset_token_cache!
        pod.log.clear
      end

      it "gives every role the public part with 200 and says the controlled part is unavailable, and why" do
        [li_reader, au_reader, owner].each do |reader|
          (passport_paths + ["/dpp/v1/dppsByIdAndDate/#{enc}?representation=full&date=#{date}"]).each do |path|
            read(path, as: reader)

            expect(response).to have_http_status(:ok)
            expect(response.parsed_body).to eq(@public_body)
            expect(response.headers["X-DPP-Controlled-Part"]).to eq(unavailable)
            expect(response.headers["X-DPP-Access-Roles"]).to be_nil
            expect(response.headers["Cache-Control"]).to eq("private, no-store")
            expect(response.body).not_to include("SN-0921", "OnModePower")
          end
        end
      end

      it "answers the fine-granular paths from the public part, and says why a controlled attribute is not there" do
        read("/dpp/v1/dpps/#{enc}/elements/BrandName", as: au_reader)
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body).to eq("Lumina")
        expect(response.headers["X-DPP-Controlled-Part"]).to eq(unavailable)

        read("/dpp/v1/dpps/#{enc}/elements/SerialNumber", as: li_reader)
        expect(response).to have_http_status(:not_found)
        expect(response.headers["X-DPP-Controlled-Part"]).to eq(unavailable)
        expect(response.parsed_body["message"].first["text"])
          .to eq("Element not found in the public part; the controlled part of this passport is unavailable")
        expect(response.body).not_to include("SN-0921")

        read("/dpp/v1/dpps/#{enc}/elements/SerialNumber")
        expect(response).to have_http_status(:unauthorized)
        expect(response.headers["X-DPP-Controlled-Part"]).to be_nil
      end

      it "reads nothing at the custodian and logs each access with its reason" do
        [li_reader, au_reader, owner].each { |reader| read(passport_paths.first, as: reader) }

        expect(pod.log.grep(%r{\AGET /(object|collection|dpp/v1/controlled)/})).to be_empty
        entries = AccessEvent.where(dpp_id: dpp_id, event: "read")
        expect(entries.count).to eq(3)
        expect(entries.map { |e| [e.reader_did, e.status, e.reason, e.roles.presence, e.custodian] })
          .to contain_exactly([li_reader, 200, "readerNotEntered", nil, nil], [au_reader, 200, "readerNotEntered", nil, nil],
                              [owner, 200, "readerNotEntered", nil, nil])
      end

      it "stays recognisable when the object id of the controlled card has to be looked up first" do
        Dpp.find(dpp_id).update_column(:storage_controlled_object_id, nil)

        read(passport_paths.first, as: au_reader)

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body).to eq(@public_body)
        expect(response.headers["X-DPP-Controlled-Part"]).to eq(unavailable)
      end

      it "answers 502 when the custodian refuses the read grant otherwise, or cannot be reached" do
        pod.readers << reader.did
        pod.read_grant_failure = [400, { "error" => "invalid_dpop_proof" }]
        read(passport_paths.first, as: li_reader)
        expect(response).to have_http_status(:bad_gateway)
        expect(response.body).not_to include("SN-0921")

        PodStorage.reset_token_cache!
        pod.read_grant_failure = :unreachable
        read(passport_paths.first, as: li_reader)
        expect(response).to have_http_status(:bad_gateway)
        expect(response.parsed_body["message"].first["text"]).to match(/unreachable/)

        read(passport_paths.first)
        expect(response).to have_http_status(:ok)
      end
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

      # The custodian serves no versions of controlled cards: a reader with
      # access rights gets the public part of the version, and the answer and
      # the access log say why the controlled part is missing.
      describe "at a custodian that serves no versions of controlled cards" do
        let(:unavailable) { "unavailable;reason=versionsNotServed" }

        before { pod.controlled_versions = false }

        it "gives every role the public part of the version, says why, and names no classes" do
          path = version_path(card_stamps(FakePod::PUBLIC).first)
          read(path)
          public_body = response.parsed_body

          [li_reader, au_reader, owner].each do |as|
            read(path, as: as)

            expect(response).to have_http_status(:ok)
            expect(response.parsed_body).to eq(public_body)
            expect(element_ids(response.parsed_body)).to eq(%w[BrandName])
            expect(response.headers["X-DPP-Controlled-Part"]).to eq(unavailable)
            expect(response.headers["X-DPP-Access-Roles"]).to be_nil
            expect(response.headers["Cache-Control"]).to eq("private, no-store")
          end

          entries = AccessEvent.where(dpp_id: dpp_id, event: "read", operation: "ReadDPPVersionByIdAndDate")
          expect(entries.map { |e| [e.reader_did, e.status, e.reason, e.roles.presence, e.controlled_digest] })
            .to contain_exactly([li_reader, 200, "versionsNotServed", nil, nil],
                                [au_reader, 200, "versionsNotServed", nil, nil],
                                [owner, 200, "versionsNotServed", nil, nil])
        end

        it "names the classes when the public version holds an attribute that is controlled today" do
          stricter = policy_doc.merge("id" => "https://dpp.example.org/access-policies/cap-020/2",
                                      "rules" => policy_doc["rules"] + [{ "path" => "BrandName",
                                                                          "accessClass" => "legitimateInterest" }])
          put "/dpp/v1/access-policies", params: stricter.to_json, headers: json_headers(owner)
          expect(response.status).to be_in([200, 201])
          update_passport({ "X-DPP-Access-Policy" => stricter["id"] })
          path = version_path(card_stamps(FakePod::PUBLIC).first)

          read(path)
          expect(element_ids(response.parsed_body)).to be_empty

          read(path, as: li_reader)
          expect(response).to have_http_status(:ok)
          expect(value_of(response.parsed_body, "BrandName")).to eq("Lumina")
          expect(value_of(response.parsed_body, "SerialNumber")).to be_nil
          expect(response.headers["X-DPP-Access-Roles"]).to eq("legitimateInterest")
          expect(response.headers["X-DPP-Controlled-Part"]).to eq(unavailable)
          expect(AccessEvent.where(event: "read", reader_did: li_reader).last.roles).to eq(["legitimateInterest"])
        end
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
