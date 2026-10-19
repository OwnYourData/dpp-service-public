# frozen_string_literal: true

require "json"
require "cgi"
require "base64"
require "uri"

# A custodian as pod-dpp behaves after F4 and V10, in memory, behind
# OutboundHttp: index cards of both types, payload versions, soft delete, the
# object list (deleted objects left out, newest first) and the public paths
# (the passport and its version at a date), which serve only cards of type
# DigitalProductPassport. The versions of a controlled card -- their list and
# the version at a date -- go to read tokens only (O12); with
# +controlled_versions+ off the custodian does not serve them at all.
#
# Every payload version carries a time: one second per tick from
# 2026-10-15T08:00:00Z on (+time_of+).
#
# Tokens come from both grants at the same token endpoint: a write delegation
# gives a token that may write and read payloads, a read grant of a protected
# reader (listed in +readers+) one that may also list objects and read index
# cards and meta. A write token asking for those gets 403 "Not authorized",
# as the custodian answers it. A read grant of a DID that is not listed --
# for the whole pod in +readers+, or in +collection_readers+ for every
# collection the grant names -- gets 400 invalid_grant. With +unreachable+ set
# every request fails as a refused connection; +read_grant_failure+ makes only
# read grants fail, with [status, body] or as a refused connection
# (:unreachable).
#
# Every request is logged as "METHOD /path" (without the query), and every
# payload write as [object id, type, payload], so the specs can check what
# reached the custodian and in which order.
class FakePod
  PUBLIC     = "DigitalProductPassport"
  CONTROLLED = "DigitalProductPassportControlled"

  Card = Struct.new(:id, :type, :dpp_id, :upi, :payloads, :stamps, :deleted, :updated_at, keyword_init: true)

  EPOCH = Time.utc(2026, 10, 15, 8)

  attr_reader :base_url, :cards, :log, :writes, :headers, :grants, :readers, :collection_readers
  # [status, body] to answer the creation of a controlled card with, or nil.
  attr_accessor :refuse_controlled
  # A proc (card) -> [status, body] or nil, consulted before a payload write.
  attr_accessor :fail_write
  # Whether the versions of controlled cards are served (O12); on by default.
  attr_accessor :controlled_versions
  # Whether the custodian cannot be reached at all.
  attr_accessor :unreachable
  # [status, body] to answer every read grant with, or :unreachable.
  attr_accessor :read_grant_failure

  def initialize(base_url)
    @base_url = base_url
    @cards    = {}
    @next_id  = 100
    @clock    = 0
    @log      = []
    @writes   = []
    @headers  = []
    @grants   = []
    @readers  = []
    @collection_readers = Hash.new { |hash, id| hash[id] = [] }
    @read_tokens = []
    @issued_read = []
    @controlled_versions = true
  end

  def time_of(tick) = EPOCH + tick

  # Takes back every read token handed out so far, as removing the reader does.
  def withdraw_read_tokens! = @read_tokens.clear

  def handles?(req) = req.url.start_with?(base_url)

  def live(type) = cards.values.reject(&:deleted).select { |c| c.type == type }

  def public_payload(dpp_id) = live(PUBLIC).select { |c| c.dpp_id == dpp_id }.last&.payloads&.last

  def controlled_payload(dpp_id) = live(CONTROLLED).select { |c| c.dpp_id == dpp_id }.last&.payloads&.last

  # A card put there by hand, as if written earlier.
  def put_card(type, dpp_id, upi, payload)
    at = tick
    card = Card.new(id: (@next_id += 1).to_s, type: type, dpp_id: dpp_id, upi: upi,
                    payloads: [payload], stamps: [at], deleted: false, updated_at: at)
    cards[card.id] = card
  end

  def call(req)
    raise OutboundHttp::ConnectionError, "Errno::ECONNREFUSED: Connection refused" if unreachable

    path, = req.path.split("?")
    log << "#{req.method.to_s.upcase} #{path}"
    headers << [req.method, path, req["Authorization"]]
    respond(req, path)
  end

  private

  def tick = (@clock += 1)

  def stamp(value) = (Time.utc(2026, 10, 15, 8) + value).iso8601

  def respond(req, path)
    method = req.method
    if method == :post && path == "/oauth/token"
      issue_token(URI.decode_www_form(req.body.to_s).to_h)
    elsif withdrawn_token?(req)
      [401, { "error" => "invalid_token" }]
    elsif method == :post && path == "/object"
      create(JSON.parse(req.body))
    elsif method == :put && (m = path.match(%r{\A/object/(\w+)/write\z}))
      write(m[1], JSON.parse(req.body))
    elsif method == :get && (m = path.match(%r{\A/object/(\w+)/read\z}))
      card = live_card(m[1])
      card ? [200, card.payloads.last] : [404, { "error" => "not found" }]
    elsif method == :get && !path.end_with?("/read") && path.match?(%r{\A/(object|collection)/}) && !read_token?(req)
      [403, { "error" => "Not authorized" }]
    elsif method == :get && (m = path.match(%r{\A/object/(\w+)/meta\z}))
      card = live_card(m[1])
      card ? [200, { "created-at" => stamp(0), "updated-at" => stamp(card.updated_at) }] : [404, {}]
    elsif method == :get && (m = path.match(%r{\A/object/(\w+)\z}))
      card = live_card(m[1])
      return [404, {}] unless card

      [200, { "type" => card.type, "digitalProductPassportId" => card.dpp_id,
              "uniqueProductIdentifier" => card.upi }]
    elsif method == :delete && (m = path.match(%r{\A/object/(\w+)\z}))
      card = live_card(m[1])
      card&.deleted = true
      card ? [200, {}] : [404, {}]
    elsif method == :get && path.match?(%r{\A/collection/\w+/objects\z})
      [200, cards.values.reject(&:deleted).sort_by { |c| -c.id.to_i }.map { |c| { "object-id" => c.id.to_i } }]
    elsif method == :get && path.start_with?("/dpp/v1/controlled/")
      controlled_version_path(req, path)
    elsif method == :get && (m = path.match(%r{\A/dpp/v1/dppsByIdAndDate/([^/]+)\z}))
      card = live(PUBLIC).select { |c| c.dpp_id == CGI.unescape(m[1]) }.last
      payload = card && version_at(card, date_param(req))
      payload ? [200, payload] : [404, { "error" => "DPP not found" }]
    elsif method == :get && (m = path.match(%r{\A/dpp/v1/dpps/([^/]+)\z}))
      payload = public_payload(CGI.unescape(m[1]))
      payload ? [200, payload] : [404, { "error" => "DPP not found" }]
    else
      raise "FakePod: unexpected #{method} #{path}"
    end
  end

  def issue_token(form)
    header, claims = form["assertion"].to_s.split(".").first(2).map do |part|
      JSON.parse(Base64.urlsafe_decode64(part + ("=" * ((4 - (part.length % 4)) % 4))))
    end
    if header && header["typ"] == "pod-read-delegation+jwt"
      grants << claims
      raise OutboundHttp::ConnectionError, "Errno::ECONNREFUSED: Connection refused" if read_grant_failure == :unreachable
      return read_grant_failure if read_grant_failure
      return [400, { "error" => "invalid_grant" }] unless reader?(claims["iss"], Array(claims["collections"]))

      token = "read-token-#{tick}"
      @read_tokens << token
      @issued_read << token
      return [200, { "access_token" => token, "token_type" => "DPoP", "expires_in" => 600,
                     "scope" => "collection:#{claims['collections'].join(',')} act:read" }]
    end
    [200, { "access_token" => "token-#{tick}", "token_type" => "DPoP", "expires_in" => 600 }]
  end

  def reader?(did, collections)
    readers.include?(did) ||
      (collections.any? && collections.all? { |id| collection_readers.fetch(id.to_s, []).include?(did) })
  end

  def presented(req) = req["Authorization"].to_s.delete_prefix("DPoP ")

  def withdrawn_token?(req) = @issued_read.include?(presented(req)) && !@read_tokens.include?(presented(req))

  def read_token?(req) = @read_tokens.include?(req["Authorization"].to_s.delete_prefix("DPoP "))

  def create(body)
    return refuse_controlled if body["type"] == CONTROLLED && refuse_controlled

    card = Card.new(id: (@next_id += 1).to_s, type: body["type"], dpp_id: body["digitalProductPassportId"],
                    upi: body["uniqueProductIdentifier"], payloads: [], stamps: [], deleted: false,
                    updated_at: tick)
    cards[card.id] = card
    [200, { "object-id" => card.id.to_i }]
  end

  def write(id, payload)
    card = live_card(id)
    return [404, {}] unless card

    refusal = fail_write&.call(card)
    return refusal if refusal

    card.payloads << payload
    card.updated_at = tick
    card.stamps << card.updated_at
    writes << [card.id, card.type, payload]
    [200, {}]
  end

  def date_param(req)
    Time.iso8601(URI.decode_www_form(URI(req.url).query.to_s).to_h.fetch("date"))
  end

  # The last payload written at or before +time+.
  def version_at(card, time)
    index = card.stamps.rindex { |at| time_of(at) <= time }
    index && card.payloads[index]
  end

  def controlled_version_path(req, path)
    return [404, { "error" => "not found" }] unless controlled_versions
    return [403, { "error" => "Not authorized" }] unless read_token?(req)

    if (m = path.match(%r{\A/dpp/v1/controlled/dpps/([^/]+)/versions\z}))
      card = live(CONTROLLED).select { |c| c.dpp_id == CGI.unescape(m[1]) }.last
      return [404, { "error" => "not found" }] unless card

      versions = card.stamps.each_with_index.map do |at, i|
        { "version" => i + 1, "timestamp" => time_of(at).iso8601, "dri" => "dri-#{card.id}-#{i + 1}" }
      end
      [200, { "digitalProductPassportId" => card.dpp_id, "versions" => versions.reverse }]
    elsif (m = path.match(%r{\A/dpp/v1/controlled/dppsByIdAndDate/([^/]+)\z}))
      card = live(CONTROLLED).select { |c| c.dpp_id == CGI.unescape(m[1]) }.last
      payload = card && version_at(card, date_param(req))
      payload ? [200, payload] : [404, { "error" => "not found" }]
    else
      raise "FakePod: unexpected GET #{path}"
    end
  end

  def live_card(id)
    card = cards[id]
    card unless card.nil? || card.deleted
  end
end
