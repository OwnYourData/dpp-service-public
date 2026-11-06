# frozen_string_literal: true

module KeyVault
  # Moves every value KeyVault keeps to the current key (docs/KeyRotation.md).
  #
  # One passport at a time, each in a transaction of its own with the row
  # locked: read it again, open each value with whichever key opens it, encrypt
  # it again under the current key and check at once that the new value opens
  # with the current key alone. Only then is it written, with update_columns: no
  # callbacks, no updated_at, no last_update, no new version, because nothing
  # about the passport changes. After writing, the row is read back and checked
  # once more; a mismatch rolls back that passport.
  #
  # Why not one transaction for everything: while KEY_VAULT_KEK_PREVIOUS is set,
  # every intermediate state is readable, so stopping halfway leaves nothing
  # broken and a second run carries on where the first stopped. One big
  # transaction would lock every passport for the length of the run and buy
  # nothing.
  #
  # Without apply nothing is written: every value is opened, encrypted again and
  # checked in memory, which is the dry run. Values already under the current key
  # are counted and left alone, so running it twice changes nothing.
  #
  # Stops at the first value it cannot open or check, and raises Failed with
  # the counters so far. Prints identifiers of passports, never values.
  class Rekey
    Result = Struct.new(:apply, :passports, :values, :current, :rekeyed, keyword_init: true) do
      def summary
        verb = apply ? "re-encrypted" : "to re-encrypt (dry run, nothing written)"
        "passports=#{passports} values=#{values} already_current=#{current} #{verb}=#{rekeyed}"
      end
    end

    class Failed < StandardError
      attr_reader :result

      def initialize(message, result)
        super(message)
        @result = result
      end
    end

    def self.call(apply: false)
      new(apply: apply).call
    end

    def initialize(apply:)
      @apply = apply
      @result = Result.new(apply: apply, passports: 0, values: 0, current: 0, rekeyed: 0)
    end

    def call
      key = KeyVault.current_key
      ids.each do |dpp_id|
        rekey_one(dpp_id, key)
        @result.passports += 1
      end
      @result
    end

    private

    def ids
      condition = KeyVault::COLUMNS.map { |col| "#{col} IS NOT NULL" }.join(" OR ")
      Dpp.where(condition).order(:dpp_id).pluck(:dpp_id)
    end

    def rekey_one(dpp_id, key)
      # requires_new: a savepoint when called inside a transaction, so a
      # failure rolls back this passport and nothing else.
      Dpp.transaction(requires_new: true) do
        dpp = Dpp.lock.find(dpp_id)
        plain = {}
        fresh = {}
        KeyVault::COLUMNS.each do |col|
          blob = dpp[col]
          next if blob.nil?

          text, which = KeyVault.unlock(blob)
          if which == :current
            @result.current += 1
            @result.values += 1
            next
          end

          value = KeyVault.encrypt(text)
          raise Failed.new("#{dpp_id} #{col}: re-encrypted value does not open with the current key", @result) \
            unless KeyVault.decrypt_with(value, key) == text

          plain[col] = text
          fresh[col] = value
        end
        next if fresh.empty?

        if @apply
          dpp.update_columns(fresh)
          stored = Dpp.find(dpp_id)
          fresh.each_key do |col|
            next if KeyVault.decrypt_with(stored[col], key) == plain[col]

            raise Failed.new("#{dpp_id} #{col}: value read back does not match", @result)
          end
        end
        @result.values += fresh.size
        @result.rekeyed += fresh.size
      end
    rescue Failed
      raise
    rescue OpenSSL::Cipher::CipherError => e
      raise Failed.new("#{dpp_id}: a value opens with neither key (#{e.message})", @result)
    rescue StandardError => e
      # The class only: the message of a database error can quote the statement,
      # and with it a value.
      raise Failed.new("#{dpp_id}: #{e.class}, this passport was rolled back", @result)
    end
  end
end
