# frozen_string_literal: true

require "rails_helper"
require "rake"

# Changing the key of KeyVault (docs/KeyRotation.md): the key ring, the start
# check in production, and key_vault:rekey and key_vault:status.
RSpec.describe KeyVault do
  let(:skb)     { Rails.application.secret_key_base }
  let(:old_kek) { "old-kek-#{'a' * 56}" }
  let(:new_kek) { "new-kek-#{'b' * 56}" }

  def with_env(vars)
    saved = vars.keys.to_h { |k| [k, ENV[k]] }
    vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  def encrypt_under(secret, text)
    with_env("KEY_VAULT_KEK" => secret, "KEY_VAULT_KEK_PREVIOUS" => nil) { described_class.encrypt(text) }
  end

  def opens_with?(secret, blob)
    described_class.decrypt_with(blob, described_class.derive(secret))
    true
  rescue OpenSSL::Cipher::CipherError
    false
  end

  # A passport with a minted DID whose three values lie under +secret+.
  # Written with update_columns, as the values of a running instance would be.
  def passport(serial, secret)
    dpp = Dpp.create!(
      dpp_id:               "did:oyd:zRekey#{serial}",
      product_id:           "https://dpp.oydapp.eu/01/09520123456788/21/#{serial}",
      granularity:          "item",
      dpp_schema_version:   "EN 18223:2026",
      dpp_status:           "Active",
      economic_operator_id: "did:web:lumina.example",
      last_update:          Time.utc(2026, 10, 1),
      did_managed:          true,
      content:              { "elements" => [] }
    )
    dpp.update_columns(
      did_doc_key_enc: encrypt_under(secret, "doc-#{serial}"),
      did_rev_key_enc: encrypt_under(secret, "rev-#{serial}"),
      did_rev_log_enc: encrypt_under(secret, %({"log":"#{serial}"}))
    )
    dpp.reload
  end

  def snapshot
    Dpp.order(:dpp_id).pluck(:dpp_id, *KeyVault::COLUMNS, :updated_at, :last_update)
  end

  def plaintexts
    Dpp.order(:dpp_id).map { |d| [d.did_doc_key, d.did_rev_key, d.did_rev_log] }
  end

  describe "the key ring" do
    it "encrypts with KEY_VAULT_KEK and reads values under KEY_VAULT_KEK_PREVIOUS" do
      blob = encrypt_under(old_kek, "secret")
      with_env("KEY_VAULT_KEK" => new_kek, "KEY_VAULT_KEK_PREVIOUS" => old_kek) do
        expect(described_class.unlock(blob)).to eq(["secret", :previous])
        fresh = described_class.encrypt("secret")
        expect(described_class.unlock(fresh)).to eq(["secret", :current])
        expect(opens_with?(old_kek, fresh)).to be(false)
      end
    end

    it "does not read a value under another key without KEY_VAULT_KEK_PREVIOUS" do
      blob = encrypt_under(old_kek, "secret")
      with_env("KEY_VAULT_KEK" => new_kek, "KEY_VAULT_KEK_PREVIOUS" => nil) do
        expect { described_class.decrypt(blob) }.to raise_error(OpenSSL::Cipher::CipherError)
      end
    end

    it "derives the key from secret_key_base outside production when KEY_VAULT_KEK is not set" do
      with_env("KEY_VAULT_KEK" => nil) do
        expect(described_class.current_key).to eq(described_class.derive(skb))
      end
    end

    it "has no key in production without KEY_VAULT_KEK" do
      allow(Rails.env).to receive(:production?).and_return(true)
      with_env("KEY_VAULT_KEK" => nil) do
        expect { described_class.encrypt("x") }.to raise_error(KeyVault::ConfigError, /KEY_VAULT_KEK is not set/)
      end
    end

    it "keeps the format, so values written before stay readable" do
      blob = with_env("KEY_VAULT_KEK" => old_kek) { described_class.encrypt("secret") }
      raw = Base64.strict_decode64(blob)
      expect(raw.bytesize).to eq(KeyVault::IV_LEN + KeyVault::TAG_LEN + "secret".bytesize)
      expect(described_class.decrypt_with(blob, OpenSSL::Digest::SHA256.digest("dpp-service:key-vault:#{old_kek}")))
        .to eq("secret")
    end
  end

  describe ".boot_check!" do
    let(:logger) { instance_double(Logger, info: nil, warn: nil) }

    it "refuses to start without KEY_VAULT_KEK" do
      expect { described_class.boot_check!({ "SECRET_KEY_BASE" => skb }, logger) }
        .to raise_error(KeyVault::ConfigError, /KEY_VAULT_KEK is not set/)
    end

    it "refuses KEY_VAULT_KEK equal to SECRET_KEY_BASE" do
      expect { described_class.boot_check!({ "SECRET_KEY_BASE" => skb, "KEY_VAULT_KEK" => skb }, logger) }
        .to raise_error(KeyVault::ConfigError, /equals SECRET_KEY_BASE/)
    end

    it "starts with a key of its own and names no value in the log" do
      env = { "SECRET_KEY_BASE" => skb, "KEY_VAULT_KEK" => new_kek, "KEY_VAULT_KEK_PREVIOUS" => old_kek }
      expect(described_class.boot_check!(env, logger)).to be(true)
      expect(logger).to have_received(:info) do |message|
        expect(message).to include("KEY_VAULT_KEK_PREVIOUS is set")
        expect(message).not_to include(old_kek)
      end
    end

    it "never puts a value into its message" do
      described_class.boot_check!({ "SECRET_KEY_BASE" => skb, "KEY_VAULT_KEK" => skb }, logger)
    rescue KeyVault::ConfigError => e
      expect(e.message).not_to include(skb)
    end
  end

  describe "key_vault:rekey and key_vault:status" do
    before(:all) do
      Rails.application.load_tasks if Rake::Task.tasks.none? { |t| t.name == "key_vault:rekey" }
    end

    before do
      Rake::Task["key_vault:rekey"].reenable
      Rake::Task["key_vault:status"].reenable
    end

    # The changeover of an instance that ran on the fallback: values under the
    # key derived from secret_key_base, KEY_VAULT_KEK_PREVIOUS set to it.
    let(:changeover) { { "KEY_VAULT_KEK" => new_kek, "KEY_VAULT_KEK_PREVIOUS" => skb } }

    before do
      passport("000001", skb)
      passport("000002", skb)
      passport("000003", skb)
    end

    it "moves every value to the new key, and back again" do
      before = with_env("KEY_VAULT_KEK" => nil, "KEY_VAULT_KEK_PREVIOUS" => nil) { plaintexts }

      with_env(changeover) do
        result = KeyVault::Rekey.call(apply: true)
        expect(result.to_h).to include(passports: 3, values: 9, current: 0, rekeyed: 9)
        expect(Dpp.pluck(*KeyVault::COLUMNS).flatten).to all(satisfy { |b| opens_with?(new_kek, b) })
        expect(KeyVault.status.values).to all(include(set: 3, current: 3, previous: 0, unreadable: 0))
      end
      with_env("KEY_VAULT_KEK" => new_kek, "KEY_VAULT_KEK_PREVIOUS" => nil) do
        expect(plaintexts).to eq(before)
      end

      with_env("KEY_VAULT_KEK" => skb, "KEY_VAULT_KEK_PREVIOUS" => new_kek) do
        expect(KeyVault::Rekey.call(apply: true).rekeyed).to eq(9)
      end
      with_env("KEY_VAULT_KEK" => nil, "KEY_VAULT_KEK_PREVIOUS" => nil) do
        expect(Dpp.pluck(*KeyVault::COLUMNS).flatten).to all(satisfy { |b| opens_with?(skb, b) })
        expect(plaintexts).to eq(before)
      end
    end

    it "rotates from one KEY_VAULT_KEK to the next" do
      Dpp.delete_all
      passport("000004", old_kek)
      with_env("KEY_VAULT_KEK" => new_kek, "KEY_VAULT_KEK_PREVIOUS" => old_kek) do
        expect(KeyVault::Rekey.call(apply: true).rekeyed).to eq(3)
        expect(Dpp.find("did:oyd:zRekey000004").did_doc_key).to eq("doc-000004")
      end
    end

    it "changes nothing in a dry run" do
      with_env(changeover) do
        expect { KeyVault::Rekey.call(apply: false) }.not_to(change { snapshot })
        expect(KeyVault::Rekey.call(apply: false).rekeyed).to eq(9)
        expect(KeyVault.status.values).to all(include(previous: 3))
      end
    end

    it "touches neither updated_at nor last_update, and leaves no version behind" do
      with_env(changeover) do
        expect { KeyVault::Rekey.call(apply: true) }
          .not_to(change { [Dpp.order(:dpp_id).pluck(:updated_at, :last_update), DppVersion.count] })
      end
    end

    it "changes nothing when run again" do
      with_env(changeover) do
        KeyVault::Rekey.call(apply: true)
        after_first = snapshot
        result = KeyVault::Rekey.call(apply: true)
        expect(result.to_h).to include(values: 9, current: 9, rekeyed: 0)
        expect(snapshot).to eq(after_first)
      end
    end

    it "leaves a readable state when it stops at a broken value halfway" do
      Dpp.find("did:oyd:zRekey000002").update_columns(did_rev_key_enc: encrypt_under("unknown", "rev-000002"))

      with_env(changeover) do
        expect { KeyVault::Rekey.call(apply: true) }
          .to raise_error(KeyVault::Rekey::Failed, /zRekey000002: a value opens with neither key/) { |e|
            expect(e.result.passports).to eq(1)
          }

        first, second, third = Dpp.order(:dpp_id).to_a
        expect(KeyVault::COLUMNS.map { |c| KeyVault.unlock(first[c]).last }).to all(eq(:current))
        expect(KeyVault.unlock(second.did_doc_key_enc).last).to eq(:previous)
        expect(KeyVault::COLUMNS.map { |c| KeyVault.unlock(third[c]).last }).to all(eq(:previous))
        expect([first.did_doc_key, second.did_doc_key, third.did_doc_key])
          .to eq(%w[doc-000001 doc-000002 doc-000003])

        Dpp.find("did:oyd:zRekey000002").update_columns(did_rev_key_enc: encrypt_under(skb, "rev-000002"))
        expect(KeyVault::Rekey.call(apply: true).to_h).to include(current: 3, rekeyed: 6)
        expect(KeyVault.status.values).to all(include(current: 3, previous: 0, unreadable: 0))
      end
    end

    it "rolls back the passport whose write fails, and keeps the others" do
      with_env(changeover) do
        calls = 0
        allow_any_instance_of(Dpp).to receive(:update_columns).and_wrap_original do |original, *args|
          calls += 1
          result = original.call(*args)
          raise ActiveRecord::StatementInvalid, "connection lost" if calls == 2

          result
        end

        expect { KeyVault::Rekey.call(apply: true) }
          .to raise_error(KeyVault::Rekey::Failed, /zRekey000002: ActiveRecord::StatementInvalid, this passport was rolled back/)
        states = Dpp.order(:dpp_id).map { |d| KeyVault.unlock(d.did_doc_key_enc).last }
        expect(states).to eq(%i[current previous previous])
        expect(Dpp.find("did:oyd:zRekey000002").did_rev_key).to eq("rev-000002")
      end
    end

    it "prints counters and identifiers, never values" do
      with_env(changeover) do
        dry = capture_stdout { Rake::Task["key_vault:rekey"].invoke }
        expect(dry).to include("passports=3 values=9 already_current=0 to re-encrypt (dry run, nothing written)=9")

        status = capture_stdout { Rake::Task["key_vault:status"].invoke }
        expect(status).to include("did_doc_key_enc: set=3 current=0 previous=3 unreadable=0")

        [dry, status].each do |out|
          expect(out).not_to include("doc-0000", "rev-0000", new_kek, skb)
        end
      end
    end

    it "exits non-zero from status when a value opens with neither key" do
      Dpp.find("did:oyd:zRekey000003").update_columns(did_doc_key_enc: encrypt_under("unknown", "x"))
      with_env(changeover) do
        expect { capture_stdout { Rake::Task["key_vault:status"].invoke } }
          .to raise_error(SystemExit).and output(/1 values open with neither key/).to_stderr
      end
    end

    def capture_stdout
      original = $stdout
      $stdout = StringIO.new
      yield
      $stdout.string
    ensure
      $stdout = original
    end
  end
end
