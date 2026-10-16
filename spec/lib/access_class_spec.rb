# frozen_string_literal: true

require "rails_helper"

# The vocabulary is a published file; these specs hold the code to it.
RSpec.describe AccessClass do
  let(:graph) { JSON.parse(File.read(described_class::FILE)).fetch("@graph") }

  it "has exactly the three classes, ordered from public to authority" do
    expect(described_class.notations).to eq(%w[public legitimateInterest authority])
    expect(described_class.all.map(&:level)).to eq([0, 1, 2])
  end

  it "names every class by an IRI in the scheme" do
    described_class.all.each do |concept|
      expect(concept.iri).to eq("#{described_class::SCHEME}##{concept.notation}")
    end
  end

  it "publishes the scheme with each class as a top concept" do
    scheme = graph.find { |node| node["@id"] == described_class::SCHEME }

    expect(scheme["@type"]).to eq("skos:ConceptScheme")
    expect(scheme["hasTopConcept"]).to match_array(described_class.all.map(&:iri))
  end

  it "labels and defines every class in English and German" do
    graph.select { |node| node["@type"] == "skos:Concept" }.each do |node|
      %w[skos:prefLabel skos:definition].each do |property|
        expect(node[property].map { |l| l["@language"] }).to match_array(%w[en de]), node["@id"]
      end
    end
  end

  it "resolves a class by notation and by IRI to the same concept" do
    expect(described_class.resolve("legitimateInterest"))
      .to equal(described_class.resolve("#{described_class::SCHEME}#legitimateInterest"))
  end

  it "refuses anything else, other spellings included" do
    %w[Public PUBLIC restricted confidential].each do |value|
      expect { described_class.resolve(value) }.to raise_error(described_class::UnknownError)
    end
  end

  it "orders the classes, so that a higher one can be compared with a lower one" do
    expect(described_class.resolve("authority")).to be > described_class.resolve("legitimateInterest")
    expect(described_class.most_restrictive.notation).to eq("authority")
    expect(described_class.public_class.notation).to eq("public")
  end

  it "lists the same classes in the schema of an access policy" do
    schema = JSON.parse(File.read(Rails.root.join("config/vocab/access-policy.schema.json")))
    allowed = schema.dig("$defs", "accessClass", "enum")

    expect(allowed).to match_array(described_class.notations + described_class.all.map(&:iri))
    expect(schema.dig("properties", "scheme", "const")).to eq(described_class::SCHEME)
  end
end
