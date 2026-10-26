# frozen_string_literal: true

require "rails_helper"

# db/seeds.rb adds the example passport only when DPP_SEED_DEMO asks for it,
# so that `bin/rails db:prepare` on a new installation leaves the database
# empty.
RSpec.describe DemoSeed do
  let(:out) { StringIO.new }

  def example_passports = Dpp.where(product_id: described_class::PRODUCT_ID)

  it "adds nothing without the switch, and says how to get the example" do
    expect { described_class.run(nil, out: out) }.not_to change(Dpp, :count)
    expect(out.string).to include("set DPP_SEED_DEMO=1")
  end

  it "adds nothing for a value that is not 1 or true" do
    %w[0 false yes on].each do |value|
      expect { described_class.run(value, out: out) }.not_to change(Dpp, :count)
    end
  end

  it "adds the example passport with DPP_SEED_DEMO=1, once" do
    expect { described_class.run("1", out: out) }.to change { example_passports.count }.from(0).to(1)
    expect { described_class.run("1", out: out) }.not_to change(Dpp, :count)
    expect(out.string).to include("Example passport #{described_class::PRODUCT_ID}")
  end

  it "takes true in any case as well" do
    expect { described_class.run(" True ", out: out) }.to change { example_passports.count }.by(1)
  end

  it "reads the switch from the environment, in production too" do
    allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("production"))
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("DPP_SEED_DEMO").and_return(nil)
    expect { described_class.run(out: out) }.not_to change(Dpp, :count)

    allow(ENV).to receive(:[]).with("DPP_SEED_DEMO").and_return("1")
    expect { described_class.run(out: out) }.to change { example_passports.count }.by(1)
  end

  it "is what db/seeds.rb runs" do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("DPP_SEED_DEMO").and_return(nil)
    expect(described_class).to receive(:run).and_call_original
    expect { load Rails.root.join("db/seeds.rb") }.to output(/No example passport/).to_stdout
    expect(Dpp.count).to eq(0)
  end
end
