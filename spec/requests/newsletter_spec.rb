# frozen_string_literal: true

require "rails_helper"

# Notifications about new Delegated Acts (NewsletterController,
# NewsletterSubscription, GraphMail, docs/Newsletter.md). Mail is stubbed:
# GraphMail.deliver is checked for what it would send.
RSpec.describe "Newsletter", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  MAIL_ENV = {
    "MS_GRAPH_TENANT_ID" => "00000000-0000-0000-0000-000000000001",
    "MS_GRAPH_CLIENT_ID" => "00000000-0000-0000-0000-000000000002",
    "MS_GRAPH_CLIENT_SECRET" => "test-secret",
    "NEWSLETTER_FROM" => "newsletter@example.org"
  }.freeze

  around do |example|
    saved = MAIL_ENV.keys.to_h { |key| [key, ENV[key]] }
    MAIL_ENV.each_key { |key| ENV.delete(key) }
    example.run
  ensure
    saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  before { AvailableServices.reset! }
  after { AvailableServices.reset! }

  let(:sent) { [] }

  def configure_mail
    ENV.update(MAIL_ENV)
    allow(GraphMail).to receive(:deliver) { |**mail| sent << mail; true }
  end

  def link_from(body, path)
    body[%r{https?://\S+#{Regexp.escape(path)}\?token=\S+}]
  end

  def token_from(link) = CGI.unescape(link[/token=(\S+)/, 1])

  describe "without mail configuration" do
    it "shows no form and answers every newsletter path with 404" do
      get "/"
      expect(response.body).not_to include('action="/newsletter"')

      post "/newsletter", params: { email: "a@example.org", locale: "en" }
      expect(response).to have_http_status(:not_found)
      get "/newsletter/confirm", params: { token: "x" }
      expect(response).to have_http_status(:not_found)
      post "/newsletter/unsubscribe", params: { token: "x" }
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "with mail configuration" do
    before { configure_mail }

    it "offers the form on the start page, with language, a hidden trap and a link to the privacy policy" do
      get "/"

      form = Nokogiri::HTML(response.body).at_css('form[action="/newsletter"][method="post"]')
      expect(form).not_to be_nil
      expect(form.css("select[name=locale] option").map { |o| o["value"] }).to eq(%w[en de])
      expect(form.at_css("input[name=website]")["tabindex"]).to eq("-1")
      expect(response.body).to include("Get notified about new Delegated Acts")
      expect(response.body).to include('href="/privacy#newsletter"')
    end

    it "stores address, language and time, and sends a confirmation mail in that language" do
      post "/newsletter", params: { email: "  Person@Example.org ", locale: "de", website: "" }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Please check your inbox")
      subscription = NewsletterSubscription.sole
      expect(subscription.attributes.keys).to contain_exactly("id", "email", "locale", "requested_at", "confirmed_at")
      expect(subscription.email).to eq("person@example.org")
      expect(subscription.locale).to eq("de")
      expect(subscription.confirmed_at).to be_nil
      expect(sent.size).to eq(1)
      expect(sent.first[:to]).to eq("person@example.org")
      expect(sent.first[:subject]).to start_with("Bitte bestätigen")
      expect(link_from(sent.first[:body], "/newsletter/confirm")).to be_present
      expect(sent.first[:body]).to include("Michael Scherz-Straße 14, 2540 Bad Vöslau")
    end

    it "confirms only with the button, not by opening the link, and names the conversion once" do
      post "/newsletter", params: { email: "a@example.org", locale: "en" }
      token = token_from(link_from(sent.first[:body], "/newsletter/confirm"))

      get "/newsletter/confirm", params: { token: token }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('<form method="post" action="/newsletter/confirm">')
      expect(NewsletterSubscription.sole.confirmed_at).to be_nil

      post "/newsletter/confirm", params: { token: token }
      expect(response.body).to include("Subscription confirmed")
      expect(response.body).to include('<meta name="oyd-conversion" content="newsletter">')
      expect(NewsletterSubscription.sole.confirmed_at).to be_present

      post "/newsletter/confirm", params: { token: token }
      expect(response.body).to include("Subscription confirmed")
      expect(response.body).not_to include("oyd-conversion")
    end

    it "does not accept a confirmation link after seven days" do
      post "/newsletter", params: { email: "a@example.org", locale: "en" }
      token = token_from(link_from(sent.first[:body], "/newsletter/confirm"))

      travel 7.days + 1.minute do
        post "/newsletter/confirm", params: { token: token }
        expect(response).to have_http_status(:not_found)
        expect(response.body).to include("This link is no longer valid")
      end
    end

    it "answers alike for a new, a waiting and a confirmed address, and sends no new mail within ten minutes" do
      post "/newsletter", params: { email: "a@example.org", locale: "en" }
      first = response.body
      post "/newsletter", params: { email: "a@example.org", locale: "en" }
      expect(response.body).to eq(first)
      expect(sent.size).to eq(1)

      travel 11.minutes do
        post "/newsletter", params: { email: "a@example.org", locale: "en" }
        expect(sent.size).to eq(2)
      end

      NewsletterSubscription.sole.confirm!
      travel 1.hour do
        post "/newsletter", params: { email: "a@example.org", locale: "en" }
        expect(response.body).to eq(first)
        expect(sent.size).to eq(2)
      end
    end

    it "stores nothing and sends nothing when the hidden field is filled" do
      post "/newsletter", params: { email: "a@example.org", locale: "en", website: "http://spam.example" }

      expect(response.body).to include("Please check your inbox")
      expect(NewsletterSubscription.count).to eq(0)
      expect(sent).to be_empty
    end

    it "refuses an address that is no address, and takes English for an unknown language" do
      post "/newsletter", params: { email: "not an address", locale: "en" }
      expect(response).to have_http_status(:unprocessable_content)
      expect(NewsletterSubscription.count).to eq(0)

      post "/newsletter", params: { email: "b@example.org", locale: "fr" }
      expect(NewsletterSubscription.sole.locale).to eq("en")
    end

    it "limits sign-ups per network and hour" do
      6.times { |i| post "/newsletter", params: { email: "p#{i}@example.org", locale: "en" } }

      expect(response).to have_http_status(:too_many_requests)
      expect(NewsletterSubscription.count).to eq(5)
    end

    it "stores nothing when the confirmation mail cannot be sent" do
      allow(GraphMail).to receive(:deliver).and_raise(GraphMail::Error, "Graph sendMail answered 403 (ErrorAccessDenied)")

      post "/newsletter", params: { email: "a@example.org", locale: "en" }

      expect(response).to have_http_status(:service_unavailable)
      expect(response.body).to include("Nothing has been stored")
      expect(NewsletterSubscription.count).to eq(0)
    end

    it "deletes unconfirmed subscriptions after seven days" do
      post "/newsletter", params: { email: "old@example.org", locale: "en" }

      travel 7.days + 1.minute do
        post "/newsletter", params: { email: "new@example.org", locale: "en" }
        expect(NewsletterSubscription.pluck(:email)).to eq(["new@example.org"])
      end
    end

    it "unsubscribes only with the button and deletes the address at once" do
      subscription = NewsletterSubscription.create!(email: "a@example.org", locale: "en", requested_at: Time.current,
                                                    confirmed_at: Time.current)
      mail = NewsletterMail.notification(subscription, subject: "New act", text: "Text", base: "https://dpp.example.org")
      token = token_from(link_from(mail[:body], "/newsletter/unsubscribe"))

      get "/newsletter/unsubscribe", params: { token: token }
      expect(response.body).to include('<form method="post" action="/newsletter/unsubscribe">')
      expect(NewsletterSubscription.count).to eq(1)

      post "/newsletter/unsubscribe", params: { token: token }
      expect(response.body).to include("You are unsubscribed")
      expect(NewsletterSubscription.count).to eq(0)

      post "/newsletter/unsubscribe", params: { token: token }
      expect(response.body).to include("You are unsubscribed")
    end

    it "unsubscribes with one click from the mail program, at the address in List-Unsubscribe (RFC 8058)" do
      subscription = NewsletterSubscription.create!(email: "a@example.org", locale: "en", requested_at: Time.current,
                                                    confirmed_at: Time.current)
      mail = NewsletterMail.notification(subscription, subject: "New act", text: "Text", base: "https://dpp.example.org")
      address = mail[:headers]["List-Unsubscribe"][/\A<(.+)>\z/, 1]
      expect(mail[:headers]["List-Unsubscribe-Post"]).to eq("List-Unsubscribe=One-Click")
      expect(address).to eq(link_from(mail[:body], "/newsletter/unsubscribe"))

      uri = URI.parse(address)
      get "#{uri.path}?#{uri.query}"
      expect(NewsletterSubscription.count).to eq(1)

      post "#{uri.path}?#{uri.query}", params: "List-Unsubscribe=One-Click",
                                        headers: { "Content-Type" => "application/x-www-form-urlencoded" }
      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("text/plain")
      expect(response.body).to eq("Unsubscribed.\n")
      expect(NewsletterSubscription.count).to eq(0)

      post "#{uri.path}?#{uri.query}", params: "List-Unsubscribe=One-Click",
                                        headers: { "Content-Type" => "application/x-www-form-urlencoded" }
      expect(response).to have_http_status(:ok)
    end

    it "keeps the address out of the log" do
      io = StringIO.new
      logger = ActiveSupport::Logger.new(io)
      allow(Rails).to receive(:logger).and_return(logger)
      ActionController::Base.logger = logger

      post "/newsletter", params: { email: "secret-person@example.org", locale: "en" }

      expect(io.string).not_to include("secret-person")
    ensure
      ActionController::Base.logger = Rails.logger
    end
  end
end

RSpec.describe NewsletterMail do
  let(:subscription) do
    NewsletterSubscription.create!(email: "a@example.org", locale: "en", requested_at: Time.current, confirmed_at: Time.current)
  end

  it "ends every notification with the link to unsubscribe and the sender" do
    mail = described_class.notification(subscription, subject: "New act", text: "A new Delegated Act.\n",
                                                      base: "https://dpp.example.org")

    expect(mail[:subject]).to eq("New act")
    expect(mail[:body]).to start_with("A new Delegated Act.\n\n-- \n")
    expect(mail[:body]).to match(%r{Unsubscribe: https://dpp\.example\.org/newsletter/unsubscribe\?token=\S+})
    expect(mail[:body]).to include("OwnYourData.eu – Verein zur Förderung der selbstständigen Nutzung von Daten")
  end

  it "takes the first line as the subject and the rest as the text" do
    expect(described_class.split_issue("﻿# New act on batteries\n\nThe text.\n")).to eq(["New act on batteries", "The text."])
  end
end

RSpec.describe GraphMail do
  around do |example|
    keys = %w[MS_GRAPH_TENANT_ID MS_GRAPH_CLIENT_ID MS_GRAPH_CLIENT_SECRET NEWSLETTER_FROM]
    saved = keys.to_h { |key| [key, ENV[key]] }
    ENV.update("MS_GRAPH_TENANT_ID" => "tenant-1", "MS_GRAPH_CLIENT_ID" => "client-1",
               "MS_GRAPH_CLIENT_SECRET" => "secret-1", "NEWSLETTER_FROM" => "newsletter@example.org")
    described_class.forget_token
    example.run
  ensure
    described_class.forget_token
    saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def response(code, body) = OutboundHttp::Response.new(code: code, body: body, message: "", version: "2.0")

  it "fetches an app-only token once and sends plain text as the newsletter mailbox, without a copy in Sent Items" do
    calls = []
    allow(OutboundHttp).to receive(:request) do |method, url, **opts|
      calls << [method, url, opts]
      url.include?("/oauth2/") ? response("200", '{"access_token":"tok","expires_in":3599}') : response("202", "")
    end

    2.times { described_class.deliver(to: "a@example.org", subject: "S", body: "B") }

    token_calls = calls.select { |_, url, _| url.include?("/oauth2/") }
    send_calls = calls.reject { |_, url, _| url.include?("/oauth2/") }
    expect(token_calls.size).to eq(1)
    expect(token_calls.first[1]).to eq("https://login.microsoftonline.com/tenant-1/oauth2/v2.0/token")
    expect(URI.decode_www_form(token_calls.first[2][:body]).to_h)
      .to include("grant_type" => "client_credentials", "scope" => "https://graph.microsoft.com/.default", "client_id" => "client-1")
    expect(send_calls.size).to eq(2)
    expect(send_calls.first[1]).to eq("https://graph.microsoft.com/v1.0/users/newsletter%40example.org/sendMail")
    payload = JSON.parse(send_calls.first[2][:body])
    expect(payload["saveToSentItems"]).to be(false)
    expect(payload.dig("message", "body", "contentType")).to eq("Text")
    expect(payload.dig("message", "toRecipients", 0, "emailAddress", "address")).to eq("a@example.org")
  end

  it "sends a message with headers of its own as MIME, with the headers and the text intact" do
    calls = []
    allow(OutboundHttp).to receive(:request) do |method, url, **opts|
      calls << [method, url, opts]
      url.include?("/oauth2/") ? response("200", '{"access_token":"tok","expires_in":3599}') : response("202", "")
    end
    headers = { "List-Unsubscribe" => "<https://dpp.example.org/newsletter/unsubscribe?token=a%3D%3D--b>",
                "List-Unsubscribe-Post" => "List-Unsubscribe=One-Click" }

    described_class.deliver(to: "a@example.org", subject: "Neue Rechtsakte über Batterien",
                            body: "Grüße\n\n-- \nAbmelden: https://dpp.example.org/x\n", headers: headers)

    send_call = calls.find { |_, url, _| url.end_with?("/sendMail") }
    expect(send_call[2][:headers]["Content-Type"]).to eq("text/plain")
    mime = Mail.new(Base64.strict_decode64(send_call[2][:body]))
    expect(mime.from).to eq(["newsletter@example.org"])
    expect(mime.to).to eq(["a@example.org"])
    expect(mime.subject).to eq("Neue Rechtsakte über Batterien")
    expect(mime["List-Unsubscribe"].value.delete("\r\n ")).to eq(headers["List-Unsubscribe"])
    expect(mime["List-Unsubscribe-Post"].value).to eq("List-Unsubscribe=One-Click")
    expect(mime.body.decoded.force_encoding("UTF-8").gsub("\r\n", "\n")).to eq("Grüße\n\n-- \nAbmelden: https://dpp.example.org/x\n")
  end

  it "reports a refusal by its code only, and never the secret" do
    allow(OutboundHttp).to receive(:request) do |_method, url, **|
      url.include?("/oauth2/") ? response("200", '{"access_token":"tok","expires_in":3599}') : response("403", '{"error":{"code":"ErrorAccessDenied","message":"secret-1 tok details"}}')
    end

    expect { described_class.deliver(to: "a@example.org", subject: "S", body: "B") }
      .to raise_error(GraphMail::Error, "Graph sendMail answered 403 (ErrorAccessDenied)")
  end

  it "says so when the token request fails, without the answer" do
    allow(OutboundHttp).to receive(:request).and_return(response("401", '{"error":"invalid_client","error_description":"secret-1"}'))

    expect { described_class.deliver(to: "a@example.org", subject: "S", body: "B") }
      .to raise_error(GraphMail::Error, "token request answered 401 (invalid_client)")
  end
end
