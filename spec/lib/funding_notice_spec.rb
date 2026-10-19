# frozen_string_literal: true

require "rails_helper"

# The wording lives in config/funding.yml. The start page and the README carry
# copies; these specs fail when a copy has not been rewritten with
# `bin/rails funding:write`.
RSpec.describe FundingNotice do
  it "names this component, the project and the grant" do
    expect(described_class.markdown).to start_with("The DPP Service is part of [PACE-DPP](https://dpp-austria.at/) – Promoting")
    expect(described_class.markdown).to include("under grant number [917177](https://projekte.ffg.at/projekt/5128301)")
    expect(described_class.markdown).to end_with("supported by the German Research Promotion Agency (DLR-PT).")
  end

  it "turns the links into anchors for the footer and leaves out the title" do
    html = described_class.html

    expect(html).to start_with('The DPP Service is part of <a href="https://dpp-austria.at/">PACE-DPP</a>. This Lighthouse Project')
    expect(html).to include('(<a href="https://www.bmimi.gv.at/en.html">BMIMI</a>, formerly BMK)')
    expect(html).to include('<a href="https://projekte.ffg.at/projekt/5128301">917177</a>')
    expect(html).not_to include("Promoting and Accelerating")
    expect(html).not_to include("](")
  end

  it "keeps the footer of the start page as the configuration says" do
    page = Rails.root.join("app", "views", "landing", "show.html.erb").to_s

    expect(described_class.current(page)).to eq(described_class.html)
  end

  it "keeps the Funding section of the README as the configuration says, before the licence" do
    readme = described_class.readme
    content = File.read(readme, encoding: "UTF-8")

    expect(described_class.current(readme)).to eq(described_class.markdown)
    expect(content.index("## Funding")).to be < content.index("## License")
  end
end
