# frozen_string_literal: true

require "rails_helper"

RSpec.describe RelatedResourceCheck do
  def resource(id, type = nil)
    { "elementId" => id, "objectType" => "RelatedResource", "url" => "https://example.org/#{id}" }
      .merge(type.nil? ? {} : { "contentType" => type })
  end

  it "names every related resource without a media type by its path, nested ones included" do
    document = {
      "elements" => [
        resource("DeclarationOfConformity"),
        resource("Manual", "application/pdf"),
        { "elementId" => "Compliance", "objectType" => "DataElementCollection",
          "elements" => [resource("Certificate", " "), resource("Report", "text/html")] }
      ]
    }

    expect(described_class.missing_content_type(document))
      .to eq(["$.DeclarationOfConformity", "$.Compliance.Certificate"])
  end

  it "writes names that are no plain identifiers and missing ids as brackets" do
    document = { "elements" => [resource("Safety sheet"), resource(nil)] }

    expect(described_class.missing_content_type(document)).to eq(['$["Safety sheet"]', "$[1]"])
  end

  it "finds nothing in a compressed document or in something that is not one" do
    expect(described_class.missing_content_type({ "DeclarationOfConformity" => "https://example.org/a" })).to eq([])
    expect(described_class.missing_content_type(nil)).to eq([])
  end

  it "gives paths that ElementIdPath resolves to the same element" do
    document = {
      "elements" => [
        { "elementId" => "Compliance", "objectType" => "DataElementCollection",
          "elements" => [resource("Safety sheet")] }
      ]
    }
    path = described_class.missing_content_type(document).first

    expect(ElementIdPath.parse(path).resolve(document)["elementId"]).to eq("Safety sheet")
  end
end
