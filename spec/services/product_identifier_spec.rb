# frozen_string_literal: true

require "rails_helper"

# prEN 18219 §3.22 / §4.5.2 (1): the unique product identifier is one string
# that identifies the product *and* is retrievable from the data carrier.
# ProductIdentifier is the only place that decides whether a given string can
# be that — the custodian reconstructs the lookup key from the request path and
# does no parsing of its own, so exactly one spelling may ever be written.
RSpec.describe ProductIdentifier do
  let(:item)  { "https://dpp.oydapp.eu/01/09520123456791/21/000123" }
  let(:batch) { "https://dpp.oydapp.eu/01/09520123456791/10/LOT42" }
  let(:model) { "https://dpp.oydapp.eu/01/09520123456791" }

  describe "the host-independent lookup key" do
    it "is the path, so one store can serve any number of operator hostnames" do
      a = described_class.parse!(item)
      b = described_class.parse!("https://p.other.eu/01/09520123456791/21/000123")

      expect(a.product_key).to eq("/01/09520123456791/21/000123")
      expect(b.product_key).to eq(a.product_key)
      expect(b.host).not_to eq(a.host)
    end
  end

  describe "granularity derived from the path (prEN 18223 Table 1)" do
    it { expect(described_class.parse!(item).granularity).to eq("item") }
    it { expect(described_class.parse!(batch).granularity).to eq("batch") }
    it { expect(described_class.parse!(model).granularity).to eq("model") }

    it "is checked against the declared value rather than trusted" do
      expect { described_class.parse!(item).assert_granularity!("model") }
        .to raise_error(described_class::InvalidError, /contradicts the ProductID path/)
    end

    it "accepts a declaration that agrees" do
      expect(described_class.parse!(item).assert_granularity!("item")).to be_a(described_class)
    end
  end

  describe "the carrier budget (DPP Registry User Guide: https, at most 50 characters)" do
    it "accepts an item-level identifier that fits" do
      expect(described_class.parse!(item).length).to eq(49)
    end

    it "says how many characters are over, not merely that it is invalid" do
      long = "https://dpp.a-rather-long-operator-domain.example/01/09520123456791/21/000123"
      expect { described_class.parse!(long) }
        .to raise_error(described_class::InvalidError, /#{long.length - 50} over the 50-character limit/)
    end

    it "refuses plain http" do
      expect { described_class.parse!("http://dpp.oydapp.eu/01/09520123456791") }
        .to raise_error(described_class::InvalidError, /https/)
    end
  end

  # prEN 18219 §5.2 / EN IEC 61406-1: a self-issuing scheme. The operator needs
  # a domain it controls and no membership anywhere, which is what keeps the
  # architecture's anti-lock-in argument from stopping at the domain name.
  describe "identification links (prEN 18219 §5.2)" do
    let(:link) { "https://dpp.oydapp.eu/ABC-4711" }

    it "accepts a self-issued path under the operator's own domain" do
      pi = described_class.parse!(link)
      expect(pi.scheme).to eq(described_class::IDENTIFICATION_LINK)
      expect(pi.product_key).to eq("/ABC-4711")
    end

    it "derives no granularity, because the path is opaque by design" do
      expect(described_class.parse!(link).granularity).to be_nil
    end

    it "requires Granularity to be declared, since it cannot be checked" do
      expect { described_class.parse!(link).assert_granularity!("") }
        .to raise_error(described_class::InvalidError, /Granularity is required/)
      expect(described_class.parse!(link).assert_granularity!("item")).to be_a(described_class)
    end

    it "is host-independent like a Digital Link" do
      a = described_class.parse!(link)
      b = described_class.parse!("https://p.other.eu/ABC-4711")
      expect(b.product_key).to eq(a.product_key)
    end

    it "refuses characters that would have to be percent-encoded" do
      expect(described_class).not_to be_valid("https://dpp.oydapp.eu/ABC 4711")
    end
  end

  describe "which scheme applies" do
    it "is decided by the path, so a broken GTIN cannot pass as free text" do
      expect { described_class.parse!("https://dpp.oydapp.eu/01/952012345679") }
        .to raise_error(described_class::InvalidError, /Digital Link/)
    end

    it "reads a leading application identifier as a Digital Link" do
      expect(described_class.parse!(item).scheme).to eq(described_class::DIGITAL_LINK)
    end
  end

  describe "what is not a Digital Link" do
    # An opaque path under the custodian's own domain is, shape-wise, a
    # perfectly good identification link. What would make it non-conformant is
    # *whose* domain it is, and that is not visible in the string: §4.6.2 (3) is
    # discharged by pointing an operator-owned name at the custodian, not by
    # anything checkable here. Worth pinning, so the boundary of what this class
    # can promise stays explicit.
    it "cannot tell whose domain an identification link uses" do
      pi = described_class.parse!("https://dpp.go-data.at/k7QvR2nXeTdM")
      expect(pi.scheme).to eq(described_class::IDENTIFICATION_LINK)
    end

    it "refuses a GTIN that is not in the 14-digit canonical form" do
      expect(described_class).not_to be_valid("https://dpp.oydapp.eu/01/952012345679")
    end

    it "refuses a DID, which no carrier may bear (§3.16 note 1, §4.6.2 (2))" do
      expect(described_class)
        .not_to be_valid("did:oyd:zQmWVzyTPZ19ebpw2Dm9doEDP4qw9rVcs6M4v3iQMo7vpVS")
    end

    it "refuses an application identifier outside the accepted set" do
      expect(described_class).not_to be_valid("https://dpp.oydapp.eu/01/09520123456791/99/x")
    end

    it "refuses the same qualifier twice" do
      expect(described_class).not_to be_valid("https://dpp.oydapp.eu/01/09520123456791/21/a/21/b")
    end

    it "refuses a query string, which would let two identifiers share one key" do
      expect { described_class.parse!("#{model}?17=271231") }
        .to raise_error(described_class::InvalidError, /query string/)
    end
  end
end
