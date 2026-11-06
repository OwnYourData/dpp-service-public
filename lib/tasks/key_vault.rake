# frozen_string_literal: true

# Changing the key KeyVault encrypts with (docs/KeyRotation.md). Both tasks
# print counters and passport identifiers, never values.
namespace :key_vault do
  # Per column: values set, opened with KEY_VAULT_KEK, with
  # KEY_VAULT_KEK_PREVIOUS, with neither. Reads only; exits non-zero when a
  # value opens with neither key.
  #
  #   bin/rails key_vault:status
  desc "Count the values KeyVault keeps, by the key that opens them"
  task status: :environment do
    unreadable = 0
    KeyVault.status.each do |col, n|
      puts "#{col}: set=#{n[:set]} current=#{n[:current]} previous=#{n[:previous]} unreadable=#{n[:unreadable]}"
      unreadable += n[:unreadable]
    end
    abort("#{unreadable} values open with neither key") if unreadable.positive?
  end

  # Moves every value to KEY_VAULT_KEK. A dry run unless APPLY=1: values are
  # opened, encrypted again and checked, nothing is written. Repeatable; stops
  # at the first value it cannot move and exits non-zero.
  #
  #   bin/rails key_vault:rekey
  #   bin/rails key_vault:rekey APPLY=1
  desc "Re-encrypt every KeyVault value under KEY_VAULT_KEK (dry run unless APPLY=1)"
  task rekey: :environment do
    result = KeyVault::Rekey.call(apply: ENV["APPLY"] == "1")
    puts result.summary
  rescue KeyVault::Rekey::Failed => e
    puts e.result.summary
    abort("rekey stopped: #{e.message}")
  end
end
