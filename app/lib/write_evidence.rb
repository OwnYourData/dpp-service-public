# frozen_string_literal: true

require "digest"
require "json"
require "time"
require_relative "compact_jws"
require_relative "request_binding"

# Checks an export of the write log (WriteLog, docs/Integrity.md section 11)
# the way the owner of a passport can: with nothing but the entries and the
# public keys of the DIDs that signed the tokens. Plain Ruby, no Rails, for
# bin/verify_writes.
#
# For every write it checks that the token is a JWS that verifies with the
# key of its issuer, that it names the issuer, the jti and the request hash
# the entry records, that the request hash is the one of the method,
# request-target and body digest recorded, and that the write happened while
# the token was valid. Across the writes it checks that no jti comes twice,
# that every write has an outcome, and that the versions the writes produced
# follow one another without a gap. Writes the service took without a request
# hash (before DPP_REQUEST_BINDING_FROM) are reported as unbound, not as failed.
class WriteEvidence
  SKEW = 60

  Finding = Struct.new(:request_id, :operation, :at, :level, :text, keyword_init: true)

  attr_reader :findings, :writes

  # +resolve+ takes a kid ("<did>#key-doc") and returns an Ed25519::VerifyKey
  # or nil.
  def initialize(entries, resolve:)
    @requests = entries.select { |e| e["phase"] == "request" }
    @outcomes = entries.select { |e| e["phase"] == "outcome" }.to_h { |e| [e["requestId"], e] }
    @resolve  = resolve
    @findings = []
    @writes   = []
  end

  def self.parse_lines(text)
    text.each_line.map(&:strip).reject(&:empty?).map { |line| JSON.parse(line) }
  end

  def check
    seen = {}
    @requests.each do |entry|
      outcome = @outcomes[entry["requestId"]]
      level = check_request(entry, outcome, seen)
      @writes << { entry: entry, outcome: outcome, level: level }
    end
    check_versions
    self
  end

  def failed? = findings.any? { |f| f.level == :fail }
  def count(level) = writes.count { |w| w[:level] == level }

  private

  def check_request(entry, outcome, seen)
    jws = CompactJws.parse(entry["token"].to_s)
    claims = jws.payload.is_a?(Hash) ? jws.payload : {}
    problems = []

    key = @resolve.call(jws.kid)
    if key.nil?
      problems << "the key #{jws.kid} cannot be resolved"
    elsif !CompactJws.valid?(jws, key)
      problems << "the token does not verify with the key of #{jws.signer}"
    end
    problems << "the token is issued by #{claims['iss']}, the entry names #{entry['issuer']}" if claims["iss"] != entry["issuer"]
    problems << "the token's jti is not the one recorded" if claims["jti"] != entry["jti"]
    problems << "the jti #{claims['jti']} of #{claims['iss']} comes twice" if seen[[claims["iss"], claims["jti"]]]
    seen[[claims["iss"], claims["jti"]]] = true

    at = Time.iso8601(entry["at"]).to_i
    if claims["exp"].to_i.positive? && (at > claims["exp"].to_i + SKEW || (claims["iat"] && at < claims["iat"].to_i - SKEW))
      problems << "the write lies outside the lifetime of its token"
    end

    expected = rqh_from(entry)
    if claims["rqh"]
      problems << "the token's rqh is not the one recorded" if claims["rqh"] != entry["rqh"]
      problems << "the rqh does not match the method, target and body recorded" if claims["rqh"] != expected
    end
    problems << "no outcome is recorded for this write" if outcome.nil?

    if problems.any?
      problems.each { |p| note(entry, :fail, p) }
      :fail
    elsif claims["rqh"].nil?
      note(entry, :open, "unbound: the token names no request (taken before binding was required)")
      :unbound
    else
      :bound
    end
  rescue CompactJws::Malformed, ArgumentError => e
    note(entry, :fail, "the token is not a JWS (#{e.message})")
    :fail
  end

  # The request hash of the method, request-target and recorded body digest.
  def rqh_from(entry)
    input = [entry["method"].to_s.upcase, entry["target"].to_s, entry["bodyDigest"].to_s].join("\n")
    RequestBinding.b64(Digest::SHA256.digest(input.b))
  end

  def check_versions
    last = nil
    @writes.each do |write|
      outcome = write[:outcome]
      next unless outcome && outcome["status"].to_i.between?(200, 299) && outcome["version"]

      version = outcome["version"].to_i
      if last && version > last + 1
        missing = last + 1 == version - 1 ? "version #{last + 1} has" : "versions #{last + 1} to #{version - 1} have"
        note(write[:entry], :fail, "#{missing} no recorded write")
      end
      last = [last.to_i, version].max
    end
  end

  def note(entry, level, text)
    @findings << Finding.new(request_id: entry["requestId"], operation: entry["operation"], at: entry["at"],
                             level: level, text: text)
  end
end
