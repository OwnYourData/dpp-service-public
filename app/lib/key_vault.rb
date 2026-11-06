# frozen_string_literal: true

require "openssl"
require "base64"

# Symmetric encryption for the secrets this service keeps at rest: the private
# keys of the passports whose DID it minted itself (variant A). AES-256-GCM.
#
# Format of an encrypted value (Base64 of): iv(12) || auth_tag(16) || ciphertext.
# Authenticated encryption: a value opened with the wrong key fails at the tag
# instead of yielding garbage, which is what lets two keys be tried in turn.
#
# Keys (docs/KeyRotation.md):
#
#   KEY_VAULT_KEK           the key everything is encrypted with. Mandatory in
#                           production; the service does not start without it.
#   KEY_VAULT_KEK_PREVIOUS  set only while changing keys: values still under the
#                           previous key are read with it, until
#                           `bin/rails key_vault:rekey APPLY=1` has moved them.
#
# Both are secrets of any length; the 32-byte key is derived from them with
# SHA-256. In development and test, without KEY_VAULT_KEK, the key is derived
# from secret_key_base the same way, so a local start needs no extra secret.
module KeyVault
  module_function

  CIPHER   = "aes-256-gcm"
  IV_LEN   = 12
  TAG_LEN  = 16
  PREFIX   = "dpp-service:key-vault:"

  # The values KeyVault keeps, all on dpps (Dpp#did_doc_key and friends).
  COLUMNS = %w[did_doc_key_enc did_rev_key_enc did_rev_log_enc].freeze

  class ConfigError < StandardError; end

  MISSING = "KEY_VAULT_KEK is not set. It is mandatory in production: it encrypts the " \
            "keys of the passports whose DID this service minted. See docs/KeyRotation.md; " \
            "an instance that ran without it sets KEY_VAULT_KEK_PREVIOUS to its " \
            "SECRET_KEY_BASE and runs bin/rails key_vault:rekey"

  SAME_AS_SECRET_KEY_BASE = "KEY_VAULT_KEK equals SECRET_KEY_BASE. The two have to be " \
                            "independent secrets, or rotating one breaks the other " \
                            "(docs/KeyRotation.md)"

  # 32-byte key from a secret, nil for a blank one.
  def derive(secret)
    return nil if secret.to_s.empty?

    OpenSSL::Digest::SHA256.digest(PREFIX + secret.to_s)
  end

  # The key values are encrypted with.
  def current_key(env = ENV)
    explicit = env["KEY_VAULT_KEK"].presence
    return derive(explicit) if explicit
    raise ConfigError, MISSING if production?

    derive(Rails.application.secret_key_base)
  end

  # The key of the previous generation, nil when none is set.
  def previous_key(env = ENV)
    derive(env["KEY_VAULT_KEK_PREVIOUS"].presence)
  end

  def encrypt(plaintext)
    return nil if plaintext.nil?

    cipher = OpenSSL::Cipher.new(CIPHER)
    cipher.encrypt
    cipher.key = current_key
    iv = cipher.random_iv # 12 bytes for GCM
    ciphertext = cipher.update(plaintext.to_s) + cipher.final
    Base64.strict_encode64(iv + cipher.auth_tag + ciphertext)
  end

  def decrypt(blob)
    unlock(blob)&.first
  end

  # [plaintext, :current | :previous]. Raises OpenSSL::Cipher::CipherError when
  # neither key opens the value.
  def unlock(blob)
    return nil if blob.nil?

    current = current_key
    begin
      return [decrypt_with(blob, current), :current]
    rescue OpenSSL::Cipher::CipherError
      previous = previous_key
      raise if previous.nil? || previous == current
    end
    [decrypt_with(blob, previous), :previous]
  end

  # Opens a value with exactly this key.
  def decrypt_with(blob, key)
    raw = Base64.strict_decode64(blob)
    iv  = raw[0, IV_LEN]
    tag = raw[IV_LEN, TAG_LEN]
    raise OpenSSL::Cipher::CipherError, "value too short" if tag.nil? || tag.bytesize != TAG_LEN

    ciphertext = raw[(IV_LEN + TAG_LEN)..] || ""

    cipher = OpenSSL::Cipher.new(CIPHER)
    cipher.decrypt
    cipher.key = key
    cipher.iv = iv
    cipher.auth_tag = tag
    cipher.update(ciphertext) + cipher.final
  rescue ArgumentError => e
    raise OpenSSL::Cipher::CipherError, "not a KeyVault value (#{e.class})"
  end

  # Refuses to start without a key of its own (config/initializers/key_vault.rb).
  # Messages name variables, never values.
  def boot_check!(env = ENV, logger = Rails.logger)
    kek = env["KEY_VAULT_KEK"].presence
    raise ConfigError, MISSING if kek.nil?

    skb = env["SECRET_KEY_BASE"].presence || Rails.application.secret_key_base
    raise ConfigError, SAME_AS_SECRET_KEY_BASE if skb && ActiveSupport::SecurityUtils.secure_compare(kek, skb)

    previous = env["KEY_VAULT_KEK_PREVIOUS"].presence
    if previous && ActiveSupport::SecurityUtils.secure_compare(previous, kek)
      logger.warn("[key-vault] KEY_VAULT_KEK_PREVIOUS equals KEY_VAULT_KEK and has no effect")
    elsif previous
      logger.info("[key-vault] KEY_VAULT_KEK_PREVIOUS is set: values under the previous key " \
                  "are read until bin/rails key_vault:rekey APPLY=1 has run")
    end
    true
  end

  # Per column: values set, opened with the current key, with the previous key,
  # by neither. Reads only.
  def status
    COLUMNS.to_h do |col|
      counts = { set: 0, current: 0, previous: 0, unreadable: 0 }
      Dpp.where.not(col => nil).pluck(col).each do |blob|
        counts[:set] += 1
        counts[unlock(blob).last] += 1
      rescue OpenSSL::Cipher::CipherError
        counts[:unreadable] += 1
      end
      [col, counts]
    end
  end

  def production?
    defined?(Rails) && Rails.env.production?
  end
end
