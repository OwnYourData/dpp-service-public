# frozen_string_literal: true

require "json"
require "uri"

# Sends plain-text mail through Microsoft Graph (sendMail) as the newsletter
# mailbox, with an app-only token (OAuth 2.0 client credentials). The app may
# send as that one mailbox only; Exchange Online enforces this (RBAC for
# Applications), see docs/Newsletter.md.
#
#   MS_GRAPH_TENANT_ID      directory (tenant) ID
#   MS_GRAPH_CLIENT_ID      application (client) ID
#   MS_GRAPH_CLIENT_SECRET  client secret (Kubernetes secret dpp-service-mail)
#   NEWSLETTER_FROM         sending mailbox, e.g. newsletter@ownyourdata.eu
#
# Without all four, the newsletter is off: no form, no mail.
module GraphMail
  class Error < StandardError; end

  TOKEN_URL = "https://login.microsoftonline.com/%<tenant>s/oauth2/v2.0/token"
  SEND_URL = "https://graph.microsoft.com/v1.0/users/%<from>s/sendMail"
  SCOPE = "https://graph.microsoft.com/.default"
  OPEN_TIMEOUT = 5
  READ_TIMEOUT = 15

  @token = nil
  @token_expires_at = Time.at(0)
  @lock = Mutex.new

  module_function

  def configured?
    %w[MS_GRAPH_TENANT_ID MS_GRAPH_CLIENT_ID MS_GRAPH_CLIENT_SECRET NEWSLETTER_FROM].all? { |key| ENV[key].present? }
  end

  def from = ENV.fetch("NEWSLETTER_FROM")

  # Sends one message to one recipient. Raises GraphMail::Error when Graph does
  # not accept it; the message never contains the token or the secret.
  def deliver(to:, subject:, body:)
    raise Error, "mail is not configured" unless configured?

    payload = {
      message: {
        subject: subject,
        body: { contentType: "Text", content: body },
        toRecipients: [{ emailAddress: { address: to } }]
      },
      saveToSentItems: false
    }
    response = OutboundHttp.request(:post, format(SEND_URL, from: URI.encode_www_form_component(from)),
                                    headers: { "Authorization" => "Bearer #{token}",
                                               "Content-Type" => "application/json" },
                                    body: JSON.generate(payload),
                                    open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT)
    return true if response.code == "202"

    forget_token if response.code == "401"
    raise Error, "Graph sendMail answered #{response.code}#{graph_error(response.body)}"
  rescue OutboundHttp::TimeoutError, OutboundHttp::ConnectionError => e
    raise Error, "Graph could not be reached: #{e.class.name.demodulize}"
  end

  # An app-only token, kept until shortly before it expires.
  def token
    @lock.synchronize do
      return @token if @token && Time.now < @token_expires_at

      response = OutboundHttp.request(:post, format(TOKEN_URL, tenant: ENV.fetch("MS_GRAPH_TENANT_ID")),
                                      headers: { "Content-Type" => "application/x-www-form-urlencoded" },
                                      body: URI.encode_www_form(client_id: ENV.fetch("MS_GRAPH_CLIENT_ID"),
                                                                client_secret: ENV.fetch("MS_GRAPH_CLIENT_SECRET"),
                                                                scope: SCOPE, grant_type: "client_credentials"),
                                      open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT)
      data = JSON.parse(response.body) rescue {}
      raise Error, "token request answered #{response.code}#{" (#{data['error']})" if data['error']}" unless data["access_token"]

      @token_expires_at = Time.now + [data["expires_in"].to_i - 300, 60].max
      @token = data["access_token"]
    end
  end

  def forget_token
    @lock.synchronize do
      @token = nil
      @token_expires_at = Time.at(0)
    end
  end

  # Only the error code of Graph's answer, never the body as a whole.
  def graph_error(body)
    code = JSON.parse(body.to_s).dig("error", "code")
    code ? " (#{code})" : ""
  rescue JSON::ParserError
    ""
  end
end
