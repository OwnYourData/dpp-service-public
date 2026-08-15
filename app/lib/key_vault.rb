# frozen_string_literal: true

require "openssl"
require "base64"

# Symmetric encryption for secrets stored at rest (the DID's private keys in
# Variante A). AES-256-GCM with a key derived from the app's secret_key_base.
#
# Format of an encrypted blob (Base64 of): iv(12) || auth_tag(16) || ciphertext.
# Authenticated encryption -> tampering is detected on decrypt.
module KeyVault
  module_function

  CIPHER   = "aes-256-gcm"
  IV_LEN   = 12
  TAG_LEN  = 16

  # 32-byte key encryption key.
  #
  # Preferably from KEY_VAULT_KEK, a dedicated secret. The fallback derives it
  # from secret_key_base, which couples two unrelated lifecycles: rotating
  # secret_key_base would then make every stored DID key and every stored pod
  # credential undecryptable. Set KEY_VAULT_KEK in production.
  def kek
    explicit = ENV["KEY_VAULT_KEK"].presence
    return OpenSSL::Digest::SHA256.digest("dpp-service:key-vault:#{explicit}") if explicit

    if defined?(Rails) && Rails.env.production?
      Rails.logger.warn("[key-vault] KEY_VAULT_KEK is not set - falling back to " \
                        "secret_key_base; rotating it will make stored keys unreadable")
    end
    OpenSSL::Digest::SHA256.digest("dpp-service:key-vault:#{Rails.application.secret_key_base}")
  end

  def encrypt(plaintext)
    return nil if plaintext.nil?

    cipher = OpenSSL::Cipher.new(CIPHER)
    cipher.encrypt
    cipher.key = kek
    iv = cipher.random_iv # 12 bytes for GCM
    ciphertext = cipher.update(plaintext.to_s) + cipher.final
    Base64.strict_encode64(iv + cipher.auth_tag + ciphertext)
  end

  def decrypt(blob)
    return nil if blob.nil?

    raw = Base64.strict_decode64(blob)
    iv  = raw[0, IV_LEN]
    tag = raw[IV_LEN, TAG_LEN]
    ciphertext = raw[(IV_LEN + TAG_LEN)..] || ""

    cipher = OpenSSL::Cipher.new(CIPHER)
    cipher.decrypt
    cipher.key = kek
    cipher.iv = iv
    cipher.auth_tag = tag
    cipher.update(ciphertext) + cipher.final
  end
end
