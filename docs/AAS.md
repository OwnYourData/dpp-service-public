# A passport as an Asset Administration Shell

The DPP Service hands out every passport it keeps or reaches at a custodian
also as an **Asset Administration Shell** (AAS, version 3.0, JSON
serialization). The AAS view is meant for systems that work with AAS rather
than with the passport format of EN 18223: they get the same data, under the
same access rules, with semantic identifiers from published AAS models.

The view is derived. The passport stays what EN 18222 and EN 18223 describe;
the view is computed from it each time it is read and is not stored.

```
GET /dpp/v1/dpps/{dppId}/aas
GET /dpp/v1/dppsByProductId/{productId}/aas
```

As on the other read paths, `dppId` and `productId` are percent-encoded into
one path segment. The answer is `application/json`: one AAS environment with
one shell and its submodels.

```bash
curl -s https://dpp-service.ownyourdata.eu/dpp/v1/dpps/did%3Aoyd%3AzQm.../aas
```

ReadDPPById, ReadDPPByProductId and the carrier path name the view in a
`Link` header:

```
Link: <https://dpp-service.ownyourdata.eu/dpp/v1/dpps/did%3Aoyd%3AzQm.../aas>; rel="alternate"; type="application/json"; title="Asset Administration Shell (AAS V3.0)"
```

## 1. What the view holds

### The shell

| Member | Value |
|---|---|
| `id` | the address of the view |
| `assetInformation.globalAssetId` | the `uniqueProductIdentifier` of the passport (its `digitalProductPassportId` if it has none) |
| `assetInformation.assetKind` | from `granularity`: item → `Instance`, model → `Type`, batch → `NotApplicable` (AAS 3.0 has no kind for a batch) |
| `description` | that the view is derived and not signed |
| `extensions` | `sourcePassport`, `signatureState`, `payloadHash` (section 3) |

The submodels are named after the shell: `<id>#DppMetadata`,
`<id>#PassportElements` and so on.

### DppMetadata

The header attributes of the passport (EN 18223, the attributes of the
passport class), in the submodel `DppMetadata` of the submodel template
**IDTA 02099-1** (Digital Product Passport, Part 1), with its semantic
identifiers `https://admin-shell.io/idta/cds/<attribute>/1`. The template
calls `lastUpdated` `lastUpdate`; the view follows the template.

### PassportElements

Every data element of the passport, one to one, for every passport whatever
its product type:

| EN 18223 | AAS 3.0 |
|---|---|
| DataElementCollection | SubmodelElementCollection |
| SingleValuedDataElement | Property; `valueDataType` as `valueType` where the value is valid for it, otherwise the type of the JSON value; `unitOfMeasure` as a qualifier of type `unitOfMeasure` |
| MultiValuedDataElement | SubmodelElementList, its items without idShort and with their elementId as `displayName`; a SubmodelElementCollection where the items differ in kind, type or reference |
| MultiLanguageDataElement | MultiLanguageProperty |
| RelatedResource | File: `url` as value, `contentType` (`application/octet-stream` where none is given), `resourceTitle` as description in the language of the resource |

`dictionaryReference` becomes the `semanticId`. An elementId that is not a
valid idShort (a blank, a leading digit) is rewritten, and the elementId is
kept as `displayName`. A passport stored in the compressed representation is
read by the shape of its JSON values.

### Submodels of a published model

For a passport that a published model fits, the view adds that model's
submodels, filled as far as the passport's elements fit them. So far this is
the **Battery Pass Data Model 1.2.0** of the BatteryPass project: seven
submodels (GeneralProductInformation, CarbonFootprintForBatteries,
Circularity, MaterialComposition, PerformanceAndDurability, Labeling,
SupplyChainDueDiligence) with semantic identifiers
`urn:samm:io.BatteryPass.<submodel>:<version>#<element>`.

A passport counts as a battery passport when it has the element
`BatteryIdentification/BatteryIdentifier`, which the DPP Manager writes for
its product type DppBattery. Where its elements go is a table,
`app/lib/aas_view/battery_pass_1_2_0.yml`, and the rules are strict:

- An element goes into a submodel only where meaning, data type and unit
  agree. Everything else stays in PassportElements alone.
- Members of an enumeration are translated (`EVBattery` becomes `ev`). Nothing
  else is converted: a month is not turned into a point in time, ampere-hours
  are not turned into kilowatt-hours.
- A value the model's type or value list does not admit is left out.
- An item that would hold nothing but constants is left out, and so is a
  submodel without data.

A passport of the DppBattery type fills 38 of its 52 fields into six of the
seven submodels; Labeling stays empty. The values in a battery submodel are
the same as in PassportElements, since both come from the same passport.

The identifiers of the model are taken over exactly as published, including
their spelling (`warrentyPeriod`, `batteryTechicalProperties`), so that a
client finds them.

## 2. Access

The view is read like ReadDPPById:

- without a token the public part of the passport, with a bearer token the
  attributes of the access classes the reader holds
  ([AccessClasses.md](AccessClasses.md) §8);
- the same headers: `X-DPP-Access-Roles`, `X-DPP-Controlled-Part`,
  `Cache-Control: private, no-store` for an answer with access rights;
- the same entries in the access log, under the operations
  `ReadDPPByIdAsAAS` and `ReadDPPByProductIdAsAAS`;
- for a passport at a custodian, read the same way as on the read paths.

What a reader does not get is missing in PassportElements and in the
submodels of a model alike.

The flag `representation` does not apply: the view is always derived from the
full representation, and a request that names the flag is answered with
`400`.

## 3. Integrity

The signature of the economic operator covers the passport, not the view
([Integrity.md](Integrity.md) section 10). The view is signed neither by the
economic operator nor by this service; it says so and names the passport it
comes from:

- in the shell: the `description`, and the extensions `sourcePassport` (the
  address of ReadDPPById in the full representation), `signatureState`
  (`none`, `pending`, `signed` or `stale`) and `payloadHash` (the hash the
  passport's DID commits to);
- in the headers: `Link: <...>; rel="via"` to the same address, and
  `X-DPP-Payload-Hash`, `X-DPP-Commit-State` and `X-DPP-Signature-State` as on
  the read paths.

A client that asks for the signature (`Accept: application/jose`) gets `406`
and the `Link` header. To check the data, read the passport from
`sourcePassport` and verify it as described in Integrity.md.

## 4. What the view does not offer

- No XML and no AASX package, only JSON.
- No AAS API (IDTA-01002): the view is one document per passport, not an AAS
  repository, and there is no listing of shells.
- No earlier versions; ReadDPPVersionByIdAndDate stays the way to them.
- No concept descriptions. The semantic identifiers point to their sources.

## 5. Checking it

The vectors in `spec/fixtures/aas-vectors` are the specification of the view:
the battery and lamp examples of the DPP Manager, a passport with every class
of data element, and the same in the compressed representation. The specs
compare the view with them, check the table against the model, and hand every
vector to the **AAS test engines** of the IDTA, which check the metamodel and
the constraints of AAS 3.0 (see the README, section Tests).

## 6. Sources

| | Licence | Used |
|---|---|---|
| Battery Pass Data Model 1.2.0, BatteryPass project ([GitHub](https://github.com/batterypass/BatteryPassDataModel)) | CC BY 4.0 | identifiers, structure, types, units and value lists of the seven submodels, extracted from the model's AAS files into `app/lib/aas_view/battery_pass_1_2_0.json` (`bin/rails "dpp:aas:extract_battery_pass[<checkout>]"`); the file records the commit and a digest of every file read |
| IDTA 02099-1 Digital Product Passport, Part 1, IDTA ([submodel templates](https://github.com/admin-shell-io/submodel-templates)) | CC BY 4.0 | the semantic identifiers of DppMetadata |

The attribution is in [NOTICE](../NOTICE). Another model is added the same
way: its structure extracted into a JSON file next to the Battery Pass one,
and a table saying where the elements of a passport go.
