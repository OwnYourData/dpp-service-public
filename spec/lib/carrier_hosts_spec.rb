# frozen_string_literal: true

require "rails_helper"

RSpec.describe CarrierHosts do
  def with_hosts(value)
    previous = ENV.fetch(described_class::VARIABLE, nil)
    ENV[described_class::VARIABLE] = value
    yield
  ensure
    previous.nil? ? ENV.delete(described_class::VARIABLE) : ENV[described_class::VARIABLE] = previous
  end

  it "reads the hosts from DPP_CARRIER_HOSTS, lower-cased, without blanks or repeats" do
    with_hosts(" ID.example.org, ,id.example.org,p.lumina.example ") do
      expect(described_class.list).to eq(%w[id.example.org p.lumina.example])
    end
  end

  it "is empty without the variable" do
    with_hosts(nil) { expect(described_class.list).to eq([]) }
  end

  it "serves a host regardless of case, and no other" do
    with_hosts("id.example.org") do
      expect(described_class.serves?("ID.Example.ORG")).to be(true)
      expect(described_class.serves?("dpp-service.example.org")).to be(false)
      expect(described_class.serves?(nil)).to be(false)
    end
  end
end
