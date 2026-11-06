# frozen_string_literal: true

# In production KeyVault needs a key of its own (KEY_VAULT_KEK). Without one the
# service, its rake tasks and the database preparation refuse to start, with a
# message that names the variable and docs/KeyRotation.md; no value is logged.
Rails.application.config.after_initialize do
  KeyVault.boot_check! if Rails.env.production?
end
