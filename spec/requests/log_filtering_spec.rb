# frozen_string_literal: true

require "rails_helper"
require_relative "../support/reading_with_access"

# What a request leaves in the log.
#
# Every request that carries a secret -- a bearer token, a write delegation in
# X-DPP-Storage, an access grant as the raw body -- and every request this
# service sends on to the custodian with one -- the delegation as assertion,
# the read grant of the protected reader, the DPoP proof, the access token the
# custodian handed out -- is made once with the whole log captured at level
# debug, so that parameters, SQL with its bind values and error messages are
# all in it. None of the secrets may appear, whole or as the signature part of
# a token.
#
# The filter in config/initializers/filter_parameter_logging.rb is what keeps
# most of them out; these examples are what notices when it stops doing so.
RSpec.describe "The log", type: :request do
  include_context "reading with access rights"

  let(:outgoing) { [] }

  before do
    # The same custodian as in the shared context, but every request this
    # service sends it is kept, so that what went over the wire can be looked
    # for in the log.
    allow(OutboundHttp).to receive(:perform) do |req, **|
      raise "no custodian for #{req.url}" unless pod.handles?(req)

      outgoing << req
      status, body = pod.call(req)
      body = body.is_a?(String) ? body : JSON.generate(body)
      outgoing << body
      OutboundHttp::Response.new(code: status.to_s, body: body, message: "stubbed", version: "2.0")
    end
  end

  def capturing_log
    io = StringIO.new
    capture = ActiveSupport::Logger.new(io)
    capture.level = Logger::DEBUG
    Rails.logger.broadcast_to(capture)
    previous = Rails.logger.level
    Rails.logger.level = Logger::DEBUG
    yield
    io.string
  ensure
    Rails.logger.level = previous if previous
    Rails.logger.stop_broadcasting_to(capture) if capture
  end

  # A token and its signature: the signature alone is enough to tell that a
  # token was there, and for a signed token it is the part nobody else can
  # produce.
  def pieces(token)
    parts = token.to_s.delete_prefix("Bearer ").delete_prefix("DPoP ").split(".")
    [token.to_s.delete_prefix("Bearer ").delete_prefix("DPoP "), parts[2]].compact.reject { |p| p.length < 16 }
  end

  # The secrets that went to the custodian: the assertion in the token
  # request, the DPoP proof and the access token of every request, and every
  # access token the custodian answered with.
  def outgoing_secrets
    outgoing.flat_map do |item|
      if item.is_a?(String)
        token = (JSON.parse(item)["access_token"] rescue nil)
        token ? [token] : []
      else
        assertion = URI.decode_www_form(item.body.to_s).to_h["assertion"] if item.path.to_s.start_with?("/oauth/token")
        [item["DPoP"], item["Authorization"], assertion].compact.flat_map { |t| pieces(t) }
      end
    end.uniq
  end

  def expect_none_of(log, secrets)
    expect(secrets).not_to be_empty
    secrets.each do |secret|
      expect(log).not_to include(secret), "the log contains a secret (#{secret[0, 12]}…)"
    end
  end

  it "keeps the bearer token, the write delegation and everything sent to the custodian out when a passport is created" do
    log = capturing_log { create_at_pod }

    expect(log).to include("INSERT INTO"), "the SQL log is part of what is checked"
    expect(outgoing_secrets).not_to be_empty
    expect_none_of(log, pieces(bearer(owner)) + pieces(mandate) + outgoing_secrets)
  end

  it "keeps the stored delegation out of the SQL bind values" do
    create_at_pod
    stored = Dpp.find(dpp_id).storage_delegation
    expect(stored).to be_present

    log = capturing_log { update_passport(brand: "Lumina Pro") }

    expect(log).to include("UPDATE")
    expect_none_of(log, pieces(stored) + pieces(bearer(owner)) + outgoing_secrets)
  end

  it "keeps an access grant sent as the raw body out" do
    create_locally
    token = grant(issuer: owner, key: owner_key, sub: li_reader, roles: ["legitimateInterest"])

    log = capturing_log { register_grant(token, as: owner) }

    expect(response).to have_http_status(:created)
    expect_none_of(log, pieces(token) + pieces(bearer(owner)))
  end

  it "keeps an access grant out when the client labels it as JSON" do
    create_locally
    token = grant(issuer: owner, key: owner_key, sub: li_reader, roles: ["legitimateInterest"])

    log = capturing_log do
      put "/dpp/v1/access-grants", params: token, headers: { "Content-Type" => "application/json",
                                                             "Authorization" => bearer(owner) }
    end

    expect(response).to have_http_status(:created)
    expect(log).to include("parsing request parameters"), "the parse error is logged, its contents are not"
    expect_none_of(log, pieces(token))
  end

  it "keeps the read grant and the read token of the reader check out when a passport is created" do
    log = capturing_log { create_at_pod }

    read_grant = outgoing.grep_v(String).find do |req|
      req.path == "/oauth/token" &&
        JWT.decode(URI.decode_www_form(req.body.to_s).to_h["assertion"], nil, false).last["typ"] == "pod-read-delegation+jwt"
    end
    expect(read_grant).not_to be_nil
    expect(log).to include("[reader] collection 60 at #{held}: reader #{reader.did} entered")
    expect_none_of(log, outgoing_secrets)
  end

  it "keeps the read grant, its DPoP proofs and the read token out when the controlled part is read" do
    create_at_pod
    grant_roles!
    outgoing.clear
    PodStorage.reset_token_cache!

    log = capturing_log do
      passport_paths.each { |path| read(path, as: li_reader) }
      read("/dpp/v1/dpps/#{enc}/elements/SerialNumber", as: li_reader)
    end

    expect(response).to have_http_status(:ok)
    expect(outgoing.grep_v(String).map(&:path)).to include("/oauth/token")
    expect_none_of(log, pieces(bearer(li_reader)) + outgoing_secrets)
  end

  it "keeps a fresh delegation out when it is handed over" do
    create_at_pod
    fresh = Delegation.sign(owner_key, typ: Delegation::TYP_DELEGATION, kid: "#{owner}#key-doc",
                                       payload: JWT.decode(mandate, nil, false).first.merge("jti" => "m2"))

    log = capturing_log do
      post "/dpp/v1/dpps/#{enc}/delegation",
           headers: json_headers(owner, "X-DPP-Storage" => { base_url: held, collection_id: "60", delegation: fresh }.to_json)
    end

    expect(response.status).to be < 500
    expect_none_of(log, pieces(fresh) + pieces(bearer(owner)))
  end

  it "keeps a token out that is refused" do
    allow(DidTokenVerifier).to receive(:call).and_call_original
    forged = Delegation.sign(Ed25519::SigningKey.generate, typ: "JWT", kid: "#{owner}#key-doc",
                                                           payload: { "iss" => owner, "sub" => owner,
                                                                      "aud" => DidTokenVerifier.audience,
                                                                      "iat" => Time.now.to_i, "exp" => Time.now.to_i + 300 })

    log = capturing_log do
      put "/dpp/v1/access-policies", params: policy_doc.to_json,
                                     headers: { "Content-Type" => "application/json", "Authorization" => "Bearer #{forged}" }
    end

    expect(response).to have_http_status(:unauthorized)
    expect(log).to include("[did-auth] rejected")
    expect_none_of(log, pieces(forged))
  end

  it "keeps a malformed X-DPP-Storage out of the error it causes" do
    secret_looking = "#{mandate}-and-something-that-is-not-json"

    log = capturing_log do
      post "/dpp/v1/dpps", params: document.to_json, headers: json_headers(owner, "X-DPP-Storage" => secret_looking)
    end

    expect(response.status).to be_between(400, 499)
    expect_none_of(log, pieces(mandate))
  end
end
