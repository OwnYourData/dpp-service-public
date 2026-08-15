# frozen_string_literal: true

require "rails_helper"

# Every other spec stubs DidOyd wholesale, so nothing checked what this wrapper
# actually hands to the oydid gem. That gap hid a real defect: revoke passed the
# private keys as :doc_key / :rev_key, which oydid interprets as *file names*,
# so every revocation failed with "invalid or missing old private document key".
#
# These examples pin the option names down. They stub Oydid (and the lazy
# require), so they need neither libsodium nor network access.
RSpec.describe DidOyd do
  let(:oydid) { class_double("Oydid") }

  before do
    allow(DidOyd).to receive(:require).with("oydid").and_return(true)
    stub_const("Oydid", oydid)
  end

  describe ".mint" do
    let(:result) do
      { "did" => "did:oyd:zABC@https://oydid.ownyourdata.eu",
        "private_key" => "z1S5doc", "revocation_key" => "z1S5rev",
        "revocation_log" => { "op" => 1 } }
    end

    it "passes the options oydid >= 0.6 requires" do
      allow(oydid).to receive(:create).and_return([result, ""])

      DidOyd.mint("https://id.example/01/1")

      expect(oydid).to have_received(:create) do |content, options|
        # :key_type is mandatory since 0.5 — without it oydid raises
        # NoMethodError (nil + "-priv") deep inside generate_base.
        expect(options[:key_type]).to eq("ed25519")
        # :location lands in the identifier, :doc_location selects the
        # repository. Before 0.5 a single :doc_location did both.
        expect(options[:location]).to eq(DidOyd::DEFAULT_LOCATION)
        expect(options[:doc_location]).to eq(DidOyd::DEFAULT_LOCATION)
        expect(options[:return_secrets]).to be(true)
        expect(content["service"].first["type"]).to eq("DigitalProductPassport")
      end
    end

    it "points the serviceEndpoint at the given base and returns the secrets" do
      allow(oydid).to receive(:create).and_return([result, ""])

      minted = DidOyd.mint("https://id.example/01/1", endpoint_base: "https://dpp.go-data.at")

      expect(oydid).to have_received(:create) do |content, _options|
        expect(content["service"].first["serviceEndpoint"])
          .to eq("https://dpp.go-data.at/dpp/v1/dppsByProductId/https%3A%2F%2Fid.example%2F01%2F1")
      end
      expect(minted[:did]).to eq("did:oyd:zABC")   # default location stripped
      expect(minted[:doc_key]).to eq("z1S5doc")
      expect(minted[:rev_key]).to eq("z1S5rev")
    end

    it "raises DidError when oydid returns no result" do
      allow(oydid).to receive(:create).and_return([nil, "VDR unreachable"])

      expect { DidOyd.mint("https://id.example/01/1") }
        .to raise_error(DidOyd::DidError, "VDR unreachable")
    end
  end

  describe ".revoke" do
    it "hands the key material to oydid under the names it actually reads" do
      allow(oydid).to receive(:revoke).and_return(["did:oyd:zABC", ""])

      DidOyd.revoke("did:oyd:zABC", doc_key: "z1S5doc", rev_key: "z1S5rev")

      expect(oydid).to have_received(:revoke) do |did, options|
        expect(did).to eq("did:oyd:zABC")
        # oydid picks the branch by :doc_enc / :rev_enc but reads the key from
        # :old_doc_enc / :old_rev_enc, so both have to carry the same value.
        expect(options[:doc_enc]).to eq("z1S5doc")
        expect(options[:old_doc_enc]).to eq("z1S5doc")
        expect(options[:rev_enc]).to eq("z1S5rev")
        expect(options[:old_rev_enc]).to eq("z1S5rev")
        expect(options[:key_type]).to eq("ed25519")
        expect(options[:doc_location]).to eq(DidOyd::DEFAULT_LOCATION)
        # :doc_key / :rev_key would make oydid look for files on disk.
        expect(options).not_to have_key(:doc_key)
        expect(options).not_to have_key(:rev_key)
      end
    end

    it "raises DidError when oydid reports a problem" do
      allow(oydid).to receive(:revoke).and_return([nil, "invalid revocation information"])

      expect { DidOyd.revoke("did:oyd:zABC", doc_key: "a", rev_key: "b") }
        .to raise_error(DidOyd::DidError, "invalid revocation information")
    end
  end

  describe ".normalize_did" do
    it "keeps a non-default location, because resolution needs it" do
      allow(DidOyd).to receive(:location).and_return("https://oydid.example")
      expect(DidOyd.normalize_did("did:oyd:zABC@https://oydid.example"))
        .to eq("did:oyd:zABC@https://oydid.example")
    end
  end
end
