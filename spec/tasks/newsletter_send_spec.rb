# frozen_string_literal: true

require "rails_helper"
require "rake"

# bin/rails newsletter:send -- the text on standard input goes to the confirmed
# subscribers of one language, only with SEND=1, and no address is printed.
RSpec.describe "newsletter:send" do
  before(:all) do
    Rails.application.load_tasks if Rake::Task.tasks.none? { |t| t.name == "newsletter:send" }
  end

  around do |example|
    keys = %w[MS_GRAPH_TENANT_ID MS_GRAPH_CLIENT_ID MS_GRAPH_CLIENT_SECRET NEWSLETTER_FROM LOCALE SEND DPP_SERVICE_ENDPOINT_BASE]
    saved = keys.to_h { |key| [key, ENV[key]] }
    ENV.update("MS_GRAPH_TENANT_ID" => "t", "MS_GRAPH_CLIENT_ID" => "c", "MS_GRAPH_CLIENT_SECRET" => "s",
               "NEWSLETTER_FROM" => "newsletter@example.org", "DPP_SERVICE_ENDPOINT_BASE" => "https://dpp.example.org")
    example.run
  ensure
    saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    Rake::Task["newsletter:send"].reenable
  end

  let(:sent) { [] }

  before do
    allow(GraphMail).to receive(:deliver) { |**mail| sent << mail; true }
    now = Time.current
    NewsletterSubscription.create!(email: "en1@example.org", locale: "en", requested_at: now, confirmed_at: now)
    NewsletterSubscription.create!(email: "en2@example.org", locale: "en", requested_at: now, confirmed_at: now)
    NewsletterSubscription.create!(email: "waiting@example.org", locale: "en", requested_at: now)
    NewsletterSubscription.create!(email: "de1@example.org", locale: "de", requested_at: now, confirmed_at: now)
  end

  def run(locale:, send: false, input: "# New act on batteries\n\nThe Commission adopted it.\n")
    ENV["LOCALE"] = locale
    send ? ENV["SEND"] = "1" : ENV.delete("SEND")
    allow($stdin).to receive(:read).and_return(input)
    output = StringIO.new
    original = $stdout
    $stdout = output
    Rake::Task["newsletter:send"].invoke
    output.string
  ensure
    $stdout = original
  end

  it "only shows the mail and the number of recipients without SEND=1" do
    out = run(locale: "en")

    expect(sent).to be_empty
    expect(out).to include("Subject: New act on batteries")
    expect(out).to include("Recipients (en, confirmed): 2")
    expect(out).to include("Unsubscribe: https://dpp.example.org/newsletter/unsubscribe?token=")
    expect(out).to include("Dry run: nothing sent.")
    expect(out).not_to include("@example.org")
  end

  it "sends to the confirmed subscribers of the language, each with an own unsubscribe link" do
    out = run(locale: "en", send: true)

    expect(sent.map { |m| m[:to] }).to contain_exactly("en1@example.org", "en2@example.org")
    expect(sent.map { |m| m[:subject] }.uniq).to eq(["New act on batteries"])
    links = sent.map { |m| m[:body][/unsubscribe\?token=\S+/] }
    expect(links.uniq.size).to eq(2)
    expect(sent.map { |m| m[:headers]["List-Unsubscribe"] }).to eq(sent.map { |m| "<#{m[:body][%r{https://\S+/newsletter/unsubscribe\?token=\S+}]}>" })
    expect(sent.map { |m| m[:headers]["List-Unsubscribe-Post"] }.uniq).to eq(["List-Unsubscribe=One-Click"])
    expect(out).to include("2 sent, 0 failed")
    expect(out).not_to include("@example.org")
  end
end
