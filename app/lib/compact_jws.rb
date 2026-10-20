# frozen_string_literal: true

require "base64"
require "ed25519"
require "json"

# A JWS in the compact serialization (RFC 7515) with an EdDSA signature
# (Ed25519, RFC 8037): the form in which the economic operator signs a passport
# (docs/Integrity.md section 10).
#
# Plain Ruby, no Rails: the service checks signatures with it
# (OperatorSignature), and bin/sign_dpp and bin/verify_dpp create and check
# them outside the application. One implementation on both sides, so a
# signature the tools make is one the service takes.
module CompactJws
  ALGORITHM = "EdDSA"

  class Malformed < StandardError; end

  # +payload_bytes+ as they were signed, +payload+ parsed (nil if not JSON).
  Parsed = Struct.new(:compact, :header, :payload_bytes, :payload, :signature, :signing_input,
                      keyword_init: true) do
    def kid = header["kid"].to_s

    # The DID the verification method in kid belongs to.
    def signer = kid.split("#", 2).first.to_s
  end

  module_function

  # Signs +payload_bytes+ as they are, with the protected header
  # { "alg": "EdDSA", "kid": kid }. +signing_key+ is an Ed25519::SigningKey.
  def sign(payload_bytes, signing_key, kid:)
    head = encode(JSON.generate({ "alg" => ALGORITHM, "kid" => kid }))
    body = encode(payload_bytes.to_s.b)
    "#{head}.#{body}.#{encode(signing_key.sign("#{head}.#{body}"))}"
  end

  # Takes +text+ apart. Raises Malformed when it is not three base64url parts
  # with a JSON object as protected header.
  def parse(text)
    compact = text.to_s.strip
    parts = compact.split(".", -1)
    unless parts.size == 3 && parts.all? { |part| part.match?(/\A[A-Za-z0-9_-]*\z/) } && !parts[0].empty?
      raise Malformed, "not a JWS in the compact serialization (three base64url parts)"
    end

    header = begin
      JSON.parse(decode(parts[0]))
    rescue JSON::ParserError, ArgumentError
      raise Malformed, "the JWS header is not base64url-encoded JSON"
    end
    raise Malformed, "the JWS header is not a JSON object" unless header.is_a?(Hash)

    bytes = begin
      decode(parts[1])
    rescue ArgumentError
      raise Malformed, "the JWS payload is not base64url-encoded"
    end
    payload = begin
      JSON.parse(bytes.dup.force_encoding(Encoding::UTF_8))
    rescue JSON::ParserError
      nil
    end
    signature = begin
      decode(parts[2])
    rescue ArgumentError
      raise Malformed, "the JWS signature is not base64url-encoded"
    end

    Parsed.new(compact: compact, header: header, payload_bytes: bytes, payload: payload,
               signature: signature, signing_input: "#{parts[0]}.#{parts[1]}")
  end

  # Whether +jws+ carries an EdDSA signature that verifies with +verify_key+
  # (an Ed25519::VerifyKey).
  def valid?(jws, verify_key)
    return false unless jws.header["alg"] == ALGORITHM && verify_key

    verify_key.verify(jws.signature, jws.signing_input)
    true
  rescue Ed25519::VerifyError, ArgumentError
    false
  end

  def encode(bytes) = Base64.urlsafe_encode64(bytes, padding: false)

  def decode(str) = Base64.urlsafe_decode64(str + ("=" * ((4 - (str.length % 4)) % 4)))
end
