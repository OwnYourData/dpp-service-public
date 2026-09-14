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

    it "passes the options oydid requires" do
      allow(oydid).to receive(:create).and_return([result, ""])

      DidOyd.mint("https://id.example/01/1")

      expect(oydid).to have_received(:create) do |content, options|
        # :key_type is mandatory — without it oydid raises NoMethodError
        # (nil + "-priv") deep inside generate_base.
        expect(options[:key_type]).to eq("ed25519")
        # :location lands in the identifier, :doc_location selects the
        # repository; oydid reads them as two independent options.
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

  # Appending the payload commitment. The examples pin down what oydid is
  # handed, because an update fails in confusing ways when an option is missing:
  # without :old_rev_enc it complains about the *document* key.
  describe ".update" do
    let(:published) do
      { "error" => 0,
        "doc" => { "key" => "zPub:zRev",
                   "doc" => { "service" => [{
                     "type" => "DigitalProductPassport",
                     "serviceEndpoint" => "https://pod.example/dpp/v1/dppsByProductId/x"
                   }] } } }
    end

    let(:updated) do
      { "did" => "did:oyd:zHEAD@https://oydid.ownyourdata.eu",
        "private_key" => "z1S5doc", "revocation_key" => "z1S5rev",
        "revocation_log" => { "op" => 1, "ts" => 2 } }
    end

    before { allow(oydid).to receive(:read).and_return([published, ""]) }

    it "hands oydid both old keys and keeps the current pair" do
      allow(oydid).to receive(:update).and_return([updated, ""])

      DidOyd.update("did:oyd:zABC", payload_hash: "zPAY",
                                    doc_key: "z1S5doc", rev_key: "z1S5rev")

      expect(oydid).to have_received(:update) do |_content, did, options|
        expect(did).to eq("did:oyd:zABC")
        # An update rebuilds the revocation record of the previous document and
        # signs it with the old revocation key, so both old keys are required.
        expect(options[:old_doc_enc]).to eq("z1S5doc")
        expect(options[:old_rev_enc]).to eq("z1S5rev")
        # Setting the new pair to the current one stops oydid from generating
        # fresh material, which would leave the stored keys behind.
        expect(options[:doc_enc]).to eq("z1S5doc")
        expect(options[:rev_enc]).to eq("z1S5rev")
        expect(options[:key_type]).to eq("ed25519")
        expect(options[:doc_location]).to eq(DidOyd::DEFAULT_LOCATION)
        expect(options[:return_secrets]).to be(true)
      end
    end

    it "adds the commitment to the existing entry and leaves the endpoint alone" do
      allow(oydid).to receive(:update).and_return([updated, ""])

      DidOyd.update("did:oyd:zABC", payload_hash: "zPAY",
                                    doc_key: "a", rev_key: "b")

      expect(oydid).to have_received(:update) do |content, _did, _options|
        entry = content["service"].first
        expect(entry["payloadHash"]).to eq("zPAY")
        expect(entry["serviceEndpoint"])
          .to eq("https://pod.example/dpp/v1/dppsByProductId/x")
        # oydid rebuilds "key" on every write; feeding the old one back in would
        # be published as part of the document content.
        expect(content).not_to have_key("key")
      end
    end

    # The identifier that comes back is the hash over the new document. It is
    # the head of the log; the passport keeps the identifier it was created
    # with, which is what the carrier and the registry entry name.
    it "returns the new head and the revocation log of the new document" do
      allow(oydid).to receive(:update).and_return([updated, ""])

      result = DidOyd.update("did:oyd:zABC", payload_hash: "zPAY",
                                             doc_key: "a", rev_key: "b")

      expect(result[:head]).to eq("did:oyd:zHEAD")   # default location stripped
      expect(result[:rev_log]).to eq("op" => 1, "ts" => 2)
    end

    it "writes nothing when the document already commits to this hash" do
      published["doc"]["doc"]["service"].first["payloadHash"] = "zPAY"
      allow(oydid).to receive(:update)

      result = DidOyd.update("did:oyd:zABC", payload_hash: "zPAY",
                                             doc_key: "a", rev_key: "b")

      expect(result).to be_nil
      expect(oydid).not_to have_received(:update)
    end

    it "refuses a document without a passport service entry" do
      published["doc"]["doc"] = { "service" => [{ "type" => "SomethingElse" }] }

      expect { DidOyd.update("did:oyd:zABC", payload_hash: "zPAY",
                                             doc_key: "a", rev_key: "b") }
        .to raise_error(DidOyd::DidError, /no DigitalProductPassport service entry/)
    end

    it "raises DidError when oydid reports a problem" do
      allow(oydid).to receive(:update).and_return([nil, "cannot resolve DID (on updating DID)"])

      expect { DidOyd.update("did:oyd:zABC", payload_hash: "zPAY",
                                             doc_key: "a", rev_key: "b") }
        .to raise_error(DidOyd::DidError, /on updating DID/)
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

  # Checking an identifier the client minted itself. The service holds no key
  # for such a DID, so a wrong service endpoint can never be corrected here --
  # creation is the only moment at which it is cheap to refuse.
  describe ".service_endpoint" do
    def read_returns(payload)
      allow(oydid).to receive(:read).and_return([payload, ""])
    end

    it "reads the endpoint out of the document oydid publishes" do
      read_returns("error" => 0, "doc" => { "key" => "zPub:zRev", "doc" => {
        "service" => [{ "type" => "DigitalProductPassport",
                        "serviceEndpoint" => "https://pod.example/dpp/v1/dppsByProductId/x" }]
      } })

      expect(DidOyd.service_endpoint("did:oyd:zABC"))
        .to eq("https://pod.example/dpp/v1/dppsByProductId/x")
    end

    it "also accepts a document with the service array at the top level" do
      read_returns("error" => 0, "doc" => {
        "service" => [{ "type" => "DigitalProductPassport",
                        "serviceEndpoint" => "https://pod.example/x" }]
      })

      expect(DidOyd.service_endpoint("did:oyd:zABC")).to eq("https://pod.example/x")
    end

    it "raises when the DID does not resolve" do
      read_returns("error" => 1, "message" => "not found")

      expect { DidOyd.service_endpoint("did:oyd:zGONE") }
        .to raise_error(DidOyd::DidError, /does not resolve/)
    end

    it "raises when oydid answers with nothing at all" do
      allow(oydid).to receive(:read).and_return([nil, "boom"])

      expect { DidOyd.service_endpoint("did:oyd:zGONE") }
        .to raise_error(DidOyd::DidError, /does not resolve/)
    end

    it "returns nil when the document carries no service entry" do
      read_returns("error" => 0, "doc" => { "doc" => {} })

      expect(DidOyd.service_endpoint("did:oyd:zABC")).to be_nil
    end
  end

  describe ".assert_endpoint_host!" do
    def endpoint(value)
      allow(DidOyd).to receive(:service_endpoint).and_return(value)
    end

    it "accepts an endpoint on the host that will serve the passport" do
      endpoint("https://pod.example/dpp/v1/dppsByProductId/x")

      expect(DidOyd.assert_endpoint_host!("did:oyd:zABC", "https://pod.example")).to be(true)
    end

    it "ignores case in the host, since DNS does" do
      endpoint("https://POD.example/x")

      expect(DidOyd.assert_endpoint_host!("did:oyd:zABC", "https://pod.example")).to be(true)
    end

    # The path may legitimately differ -- it carries the uniqueProductIdentifier, and the
    # check is about where a reader is sent, not about what they ask for.
    it "does not compare the path" do
      endpoint("https://pod.example/somewhere/else")

      expect(DidOyd.assert_endpoint_host!("did:oyd:zABC", "https://pod.example/dpp/v1")).to be(true)
    end

    it "names both hosts when they differ" do
      endpoint("https://other.example/x")

      expect { DidOyd.assert_endpoint_host!("did:oyd:zABC", "https://pod.example") }
        .to raise_error(DidOyd::DidError, /other\.example.*pod\.example/)
    end

    it "refuses a DID whose document points nowhere" do
      endpoint(nil)

      expect { DidOyd.assert_endpoint_host!("did:oyd:zABC", "https://pod.example") }
        .to raise_error(DidOyd::DidError, /no DigitalProductPassport service endpoint/)
    end

    it "refuses an endpoint that is not a URL rather than guessing" do
      endpoint("not a url")

      expect { DidOyd.assert_endpoint_host!("did:oyd:zABC", "https://pod.example") }
        .to raise_error(DidOyd::DidError, /no host/)
    end
  end
end
