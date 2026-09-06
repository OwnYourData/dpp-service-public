# The DPP Manager, screen by screen

[`DPP-Service-Demo.md`](DPP-Service-Demo.md) asks *who owns the product
passport?* and answers it on the command line, with `curl`, a signing script and
a shell that knows what a DID is.

This one asks what is left of that answer when the economic operator is a lamp
manufacturer who will never open a terminal. The claim under test:

> Holding your own identifier, your own keys and your own data must not require
> a person who can operate a terminal. One application, one folder, one
> passphrase.

Everything below is a real run against the production deployment. The
identifiers in the screenshots existed; they were minted, submitted, corrected,
read back and revoked in the twelve minutes it took to record them.

| | |
|---|---|
| DPP Manager | an application on the operator's own computer, `http://localhost:3000` |
| DPP Service | `https://dpp-service.ownyourdata.eu` |
| VDR / registrar for `did:oyd` | `https://oydid.ownyourdata.eu` |
| SOyA repository | `https://soya.ownyourdata.eu`, and a copy inside the application |

**Where things are.** Three places, and the whole demo is about which of them
holds what:

```
┌─ THIS COMPUTER ─────────────── one file in a folder you chose ─┐
│ Passphrase  ·  Identity key  ·  Passport keys                  │
│ Answers, drafts, the event log, the product types              │
└────────────────────────────────────────────────────────────────┘
        │  a token it issues to itself, per request
        ▼
┌─ DPP SERVICE ─────────────────── dpp-service.ownyourdata.eu ───┐
│ The passport as EN 18223 sees it  ·  its history               │
└────────────────────────────────────────────────────────────────┘
        │  the passport's DID, its log and its document
        ▼
┌─ REGISTRY (VDR) ──────────────────── oydid.ownyourdata.eu ─────┐
│ Public identifiers. No keys, ever                              │
└────────────────────────────────────────────────────────────────┘
```

---

## 0 — Getting it, and starting it

The DPP Manager runs on the operator's own computer. It is published as a
container image, which is how an application is shipped together with everything
it needs — here a database engine, a Ruby runtime and the SOyA toolchain, none
of which anybody should have to install by hand.

**Once:** install [Docker Desktop](https://www.docker.com/products/docker-desktop),
free, for macOS, Windows or Linux. Start it once and leave it be.

**Then:** make a folder, put one file in it, and run one command.

```yaml
# docker-compose.yml
services:
  dpp-manager:
    image: oydeu/dpp-manager:latest
    container_name: dpp-manager
    volumes:
      - ./data:/data
    ports:
      - "3000:3000"
    restart: unless-stopped
```

```bash
mkdir "DPP Manager" && cd "DPP Manager"
# put the file above in here, then:
docker compose up -d
```

Then open **http://localhost:3000**.

That is the whole installation. The first `up` downloads the image, which takes
a minute or two; every later start is instant. `restart: unless-stopped` means
the application is simply there after the computer is switched on again — there
is nothing to start each morning.

| | |
|---|---|
| stop it | `docker compose down` — the folder is untouched |
| start it again | `docker compose up -d` |
| a newer version | `docker compose pull && docker compose up -d` |

After the first start, Docker Desktop's own window is enough for the rest:
the container appears under *Containers* with a stop button, a start button and
its log. Nobody has to type a second command.

**The folder is the point.** `./data` is a folder on the computer, next to the
compose file, and after the first start there is exactly one thing in it:

```
DPP Manager/
├── docker-compose.yml
└── data/
    └── dpp.db      everything: passports, keys, settings, the event log
```

That file is encrypted with the passphrase from the next section, and it is the
whole state of the application. Copying the folder is a backup. Copying it to
another computer and starting there is a move. Losing it with no copy is losing
the passports — which is the price of nobody else having them.

> A named volume would be the tidier Docker default and the wrong choice here.
> It puts the file somewhere the operator cannot see, and "back up your
> passports" would become a command to look up rather than a folder to copy.
>
> On Linux the folder has to belong to user id 1000, the user inside the
> container: `mkdir -p data && sudo chown 1000:1000 data`. macOS and Windows
> handle this themselves. The application says so plainly if it cannot write
> there.

---

## 1 — First start: one file, one passphrase

![First start](images/dpp-manager-demo/01-first-start.png)

There is no account, no e-mail address and no recovery. The passphrase is not a
login — it is the key the file is encrypted with, and the screen says so before
anything exists to lose.

![Overview](images/dpp-manager-demo/02-overview.png)

Creating the file also fills it: the product types the application ships with
are installed at that moment, which is why the button takes a second. From here
on it works with the network unplugged, up to the point where something has to
leave the computer.

---

## 2 — Setup: the service, an identity, and two keys

Three steps and one that can be skipped. Step one: which DPP Service this
installation talks to.

![Setup, step 1](images/dpp-manager-demo/03-setup-service.png)

The address is probed rather than believed, and what comes back is the service's
own `/.well-known/dpp-service`:

![The service answered](images/dpp-manager-demo/04-setup-service-done.png)

> The DID shown there is the service's. It is not needed to submit a passport —
> it is needed later, to name in a mandate the service can redeem at a
> custodian. The application reads it here so that nobody ever types it by hand.

Step two mints the operator's identity. It happens **on this computer**: the
registrar publishes the document and the log, and the two keys exist here and
nowhere else.

![The keys, once](images/dpp-manager-demo/05-identity-keys.png)

> This is the one screen in the application that shows secrets, and it shows
> them once. That is not a UX flourish: the registrar cannot send them again,
> and neither can we. The revocation key is kept apart from the document key
> because it is the only way to end an identity cleanly.

Step three is a custodian, and it is skipped here — this demo keeps the
passports in the service's own database. The screen is worth one look anyway,
because of what it asks for:

![Setup, step 4](images/dpp-manager-demo/06-setup-custodian.png)

> A base URL and a collection. No password, no client secret, no registration —
> the custodian is told the operator's DID once, and every later write is
> authorised by a statement this application signs. That is milestone 5, and it
> is implemented; what is missing for a live demo is a provisioned collection,
> not code.

---

## 3 — What the application already knows

![Product types](images/dpp-manager-demo/07-product-types.png)

A product type is a SOyA structure: which fields a passport of that kind has,
what they mean, what counts as a valid answer, and how the answers become the
element model of EN 18223. The LED lamp is shipped with the application —
structure, form, transformation and the transformation for reading one back — so
a fresh installation with no network still has a working type. "Fetch again"
asks the repository and falls back to the copy that was shipped, in that order.

---

## 4 — A passport

![No passports yet](images/dpp-manager-demo/08-passports-empty.png)

The form has two halves, and they have two different authors.

![A new passport](images/dpp-manager-demo/09-passport-new.png)

The upper half is the envelope of EN 18223 Table 1 — the part the operator
supplies. The product identifier counts its characters as you type, because the
EU registry allows fifty and the count is invisible until a carrier cannot be
printed. The granularity fills itself in from the identifier's path and refuses
to contradict it.

The lower half is **not this application's**: it is soya-form, rendering the
structure the operator imported. Tabs, labels, help texts and validation all
come from the SOyA overlays. Nothing about lamps is written in the DPP Manager.

![Saved](images/dpp-manager-demo/10-passport-saved.png)

A draft saves whether or not it validates, and what is missing is said rather
than enforced. The check runs through soya-web-cli — the same code as the `soya`
command line tool — because a validation written here would be a second opinion
about a structure that already has one.

---

## 5 — The identifier

![Before minting](images/dpp-manager-demo/11-passport-before-minting.png)

This is the step that leaves the computer, and the warning is exact about what
becomes irreversible: the identifier is published, and the address inside it —
where this passport will be readable — is frozen with it.

![The passport's keys](images/dpp-manager-demo/12-passport-keys.png)

> Every passport gets **its own** DID and its own two keys, minted here. That is
> variant B, and it is the difference the service demo builds up to: the service
> can serve a passport it holds no key for, and it can stop serving it, but it
> can never revoke that identifier. Only this computer can.

---

## 6 — Submitting

![Before submitting](images/dpp-manager-demo/13-passport-before-submitting.png)

The document is assembled here: the envelope from the settings and the identity,
the elements from the product type's transformation. The bearer token is issued
by this application to itself and signed with the identity key — there is no
registration and no password anywhere in this exchange.

![Submitted](images/dpp-manager-demo/14-passport-submitted.png)

![The list](images/dpp-manager-demo/15-passports-list.png)

---

## 7 — Correcting

A saved answer stays here. Sending it is a separate act, and the page only
offers it when the two actually differ:

![It differs](images/dpp-manager-demo/16-passport-differs.png)

> The comparison is a fingerprint over the answers and the facility — not a flag
> somebody has to remember to set, and not a question asked of the service. A
> passport that says the same thing as the copy at the service offers no button
> at all, because an update that changes nothing would still be archived there
> as a new version.

![Corrected](images/dpp-manager-demo/17-passport-corrected.png)

---

## 8 — Reading, with no identity at all

![Read a passport](images/dpp-manager-demo/18-lookup-empty.png)

Reading needs no token and no permission — whoever holds the product holds its
identifier, and that is the whole point of a passport being public. Two kinds of
identifier are accepted, and they take different routes to the same document.

The product identifier from the data carrier is looked up at the configured
service:

![Read by product identifier](images/dpp-manager-demo/19-lookup-by-product.png)

The passport's own identifier is resolved at the registry first, and the
passport is then read **wherever its own document says it lives**:

![Read by passport identifier](images/dpp-manager-demo/21-lookup-by-did.png)

> Nothing in this application decides where a foreign passport is. The DID says
> it, its holder published that statement, and the address in it is where the
> read goes. That is what makes the identifier worth minting.

Both show the document as it stands — including a passport no product type here
can read. Below it, when a type carries the transformation for the reading
direction, the same passport in the shape of that type's form:

![As a form](images/dpp-manager-demo/20-lookup-as-a-form.png)

> This is the round trip: answers → EN 18223 elements → answers, both directions
> published as SOyA transformations and both run by soya-web-cli. Note the
> warranty of five years — the correction from step 7, read back out of the
> service. "Start a draft from this" makes a local passport with these answers
> and deliberately **without** the product identifier: it names somebody else's
> product.

---

## 9 — The log and the file

![Event log](images/dpp-manager-demo/22-events.png)

Every action is in the log, and each entry carries a seal over the entry before
it. That does not make the log tamper-proof — whoever has the passphrase can
recompute the chain — but it makes it tamper-**evident** against the realistic
case, which is an edit after the fact. The page says the chain is intact and
names the entry where it is not.

![The data file](images/dpp-manager-demo/23-vault.png)

One file, in the folder from section 0. Changing the passphrase re-encrypts it;
a backup is a copy of it. No `-wal`, no `-shm`, nothing beside it — which is why
"make a backup" is one button and not a procedure.

---

## 10 — Ending it, and what the difference is

![Before ending](images/dpp-manager-demo/24-passport-before-ending.png)

Ending a passport is two acts against two systems, and the order is not
arbitrary: the service withdraws the passport first — keeping the final state as
history — and only then does this application revoke the identifier with the
keys it holds. The other way round, the world would read a document whose
identifier no longer resolves, and no reader could tell a retired product from a
forgery.

![Ended](images/dpp-manager-demo/25-passport-ended.png)

> The service cannot do the second half. It holds no key for this DID, and that
> is the property the whole construction is for: **the architecture can compel
> departure, not forgetting.**

![Nothing served](images/dpp-manager-demo/26-lookup-after-ending.png)

The passport is now a record in the local file, and the row may go. The
identifier resolves nowhere, for good.

---

## 11 — The same application, in German

![In German](images/dpp-manager-demo/27-german.png)

The language is a setting in the file, it applies to every explanation, and the
form follows it: soya-form renders the German overlay of the same structure.

---

## Appendix — what deliberately does not appear

| | |
|---|---|
| a login, an account, a password reset | there is no server that could hold one |
| a `client_secret` anywhere | the operator signs; nobody is issued a secret |
| a "connect your data" step | the data was never anywhere else |
| a spinner while a form loads from the internet | the structure is in the file |
| a passport this application could read but the operator could not | the file is the operator's, and the passphrase is theirs |

**What is shipped:** Rails 8 on Ruby 3.3, SQLCipher built from source,
soya-web-cli and soya-form from the SOyA repository, and the LED lamp structure
with both transformations — as `oydeu/dpp-manager:latest`, for amd64 and arm64.
One compose file, one folder.

**What is implemented but not shown here:** custody at a data intermediary — the
mandate the operator signs (`Delegation.md` §5), its renewal, the comparison
with what the service holds, and handing a passport to a different custodian,
identifier and all. All of it is in the application and under test; the live
demo needs a collection at a pod whose controller is this installation's
identity DID.

**What is not possible yet:** graduated read rights for restricted data
(authorities, recyclers) are specified and not deployed — everything above is
the public layer.

---

*Recorded against `https://dpp-service.ownyourdata.eu` and
`https://oydid.ownyourdata.eu`. Every identifier in these screenshots has since
been revoked.*
