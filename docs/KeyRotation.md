# Keys of the service and how to change them

The service keeps two secrets of its own. They protect different things and
are changed independently of each other.

| Variable | What it protects | What changing it costs |
|---|---|---|
| `KEY_VAULT_KEK` | the private keys of every passport whose DID the service minted itself: the document key, the revocation key and the revocation record, stored encrypted in the database | nothing, if the stored values are moved to the new key with `bin/rails key_vault:rekey` (below). Lost, the passports concerned can never again be changed or ended, by anybody |
| `SECRET_KEY_BASE` | what Rails signs: among other things the confirmation and unsubscribe links in newsletter mails | links in mails already sent stop working. Nothing stored in the database depends on it |

Both are random strings of any length; generate them once, keep them in a
password store, never in the repository:

```
openssl rand -hex 64      for SECRET_KEY_BASE
openssl rand -hex 32      for KEY_VAULT_KEK
```

## `KEY_VAULT_KEK` is mandatory

In production the service does not start without `KEY_VAULT_KEK`, and it
refuses a `KEY_VAULT_KEK` equal to `SECRET_KEY_BASE`. This applies to every
process of the image: the web server, the database preparation and every
`bin/rails` task. The message names the variable and this document, never a
value.

The key itself is derived from the variable with SHA-256, so its length and
encoding are free. Each value is encrypted with AES-256-GCM; a value opened
with the wrong key fails its authentication tag rather than producing garbage.

## The two tasks

| Task | What it does |
|---|---|
| `bin/rails key_vault:status` | per stored column: how many values are set, how many open with `KEY_VAULT_KEK`, how many with `KEY_VAULT_KEK_PREVIOUS`, how many with neither. Reads only; exits non-zero when a value opens with neither |
| `bin/rails key_vault:rekey` | a dry run: opens every value, encrypts it again under `KEY_VAULT_KEK`, checks that the result opens with that key, and writes nothing |
| `bin/rails key_vault:rekey APPLY=1` | the same, and writes |

`rekey` works one passport at a time, each in a transaction of its own with the
row locked. A value is written only after the new one has been checked, and
read back after writing; a mismatch rolls that passport back. The passport
itself does not change: no new version, no new modification time. Values
already under `KEY_VAULT_KEK` are counted and left alone, so a second run
changes nothing, and a run that stopped halfway can simply be repeated. It stops
at the first value it cannot move, exits non-zero and prints its counters. Both
tasks print counters and passport identifiers, never values.

## Changing `KEY_VAULT_KEK`

While keys are changed the service reads with two keys:
`KEY_VAULT_KEK_PREVIOUS` holds the old secret, `KEY_VAULT_KEK` the new one.
Everything new is encrypted under `KEY_VAULT_KEK`; values still under the old
key remain readable until `rekey` has moved them. No downtime is needed.

1. **Back up** the table `dpps`, for example `pg_dump -Fc -t dpps`, and keep
   the dump encrypted, next to the secrets, not in the repository. Use a
   `pg_dump` at least as new as the database server; an older one refuses.
   The dump holds the values under the old key, so keep the old secret as
   long as you keep the dump.
2. **Set the variables:** `KEY_VAULT_KEK_PREVIOUS` to the current value of
   `KEY_VAULT_KEK`, `KEY_VAULT_KEK` to the new one.
3. **Restart every process** of the service, so that all of them read with both
   keys. Until then, a process still running with the old settings keeps
   encrypting under the old key; that is harmless, the next step catches it.
4. `bin/rails key_vault:status`: nothing `unreadable`.
5. `bin/rails key_vault:rekey`: the dry run, no errors.
6. `bin/rails key_vault:rekey APPLY=1`.
7. `bin/rails key_vault:status`: every value `current`, none `previous`, none
   `unreadable`.
8. **Check** that a passport with a minted DID can still be changed.
9. **Remove** `KEY_VAULT_KEK_PREVIOUS`, restart, and `key_vault:status` once more.

### An instance that ran without `KEY_VAULT_KEK`

Earlier versions derived the key from `SECRET_KEY_BASE` when `KEY_VAULT_KEK`
was not set. The derivation is the same, so such an instance changes over by
the same steps, with `KEY_VAULT_KEK_PREVIOUS` set to the value of
`SECRET_KEY_BASE` in step 2. Set both variables before the first start of a
version that requires `KEY_VAULT_KEK`. Once step 9 is done, `SECRET_KEY_BASE`
can be changed on its own.

### Going back

- **Before `APPLY=1`** nothing stored has changed: restore the previous
  settings and restart.
- **After `APPLY=1`**, while `KEY_VAULT_KEK_PREVIOUS` is still set: swap the
  values of `KEY_VAULT_KEK` and `KEY_VAULT_KEK_PREVIOUS`, restart, run
  `rekey APPLY=1`. The values are then back under the old key.
- **If values were damaged**, restore the dump into a separate table and write
  back only the three columns `did_doc_key_enc`, `did_rev_key_enc` and
  `did_rev_log_enc`, matched by `dpp_id`. Restoring the whole table would undo
  every change made to passports since the backup.

## Changing `SECRET_KEY_BASE`

Possible at any time once `key_vault:status` shows every value `current` with
`KEY_VAULT_KEK_PREVIOUS` unset: set the new value and restart every process.
Confirmation links not yet used and unsubscribe links in newsletter mails
already sent stop working; subscribers can unsubscribe through the next mail.
The database is not touched.
