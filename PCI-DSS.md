# PCI DSS scoping statement — Pay Via FIS PayDirect

This document describes what data the **Pay Via FIS PayDirect** Koha plugin sends to FIS, what FIS
sends back, and what Koha retains.

It is a factual description of the plugin's behaviour at the commit named in section 9. It is not a
certification, and it does not determine any library's PCI DSS obligations — a library that accepts
card payments is a merchant and has obligations regardless of what Koha does. What this document
establishes is whether Koha itself sits inside the cardholder data environment. Your acquirer and
your assessor decide the rest.

Every code reference links to the exact line on GitHub, pinned to the reviewed commit, so any claim
here can be checked against the source it was drawn from.

---

## 1. Summary

| Assertion | Determination |
|---|---|
| Does this plugin **accept** cardholder data (PAN, CVV/CVC/CID, expiry date, track or chip data, PIN)? | **No** |
| Does this plugin **transmit** cardholder data to any system? | **No** |
| Does this plugin **store** cardholder data? | **No** |
| Does this plugin store any **card-derived** data (card brand, truncated PAN, authorisation code)? | **Yes — only in application logs, and only when debug logging is switched on. See §5.2.** |
| Does the patron ever enter card details into a page served by Koha? | **No** |
| Does any Koha-served page frame, embed, script, or otherwise affect the processor's card-entry page? | **No** |

**Determination: Koha is outside the cardholder data environment, with the caveats below.**

A patron who chooses to pay library fees online leaves the Koha catalogue entirely and is sent to a
payment page hosted and operated by FIS. Card details are typed into that page, travel to FIS, and
never reach Koha or ByWater Solutions' servers. Koha does not host, frame, or script that page — it
posts a form to it. When the payment completes, FIS tells Koha that a payment of a given amount
succeeded, and Koha marks the selected fees as paid.

### Caveats

- FIS returns a **masked card number, a card brand and an authorisation code**. Per FIS's
  integration specification, the passback sent to the return URL carries
  `MaskedPaymentAccountNumber` (documented sample: `***********1881`), `PaymentMethodCode`,
  `PaymentMethodDescription` and `AuthorizationNumber`, alongside a full billing block. The
  postback sent to the notification endpoint carries the authorisation code and payment method
  code but **not** the masked card number. See §4.
- **None of it is stored in the database, and none of it is read by the plugin.** It reaches the
  application log only when debug logging is switched on, which it is not by default. See §5.2.
- A masked card number truncated to the last four digits is not cardholder data under PCI DSS, and
  neither an authorisation code nor a card brand is cardholder data or sensitive authentication
  data. None of this places Koha inside the cardholder data environment. It is recorded here
  because a reader who greps the logs of a site with debugging enabled will find it, and should
  find it documented.
- Which fields the postback actually carries is **selected per merchant profile** by the client, so
  what any given library receives depends on their FIS configuration. See §7. At the one production
  site reviewed, the postback carried no card-derived data at all, and none appeared anywhere in
  that site's FIS log output — so row 4 above reads "No" in practice there. It is left as "Yes"
  because another profile could be configured to send the authorisation code and payment method
  code.

### Two terms that look like card data and are not

**Koha's `cardnumber` is a library card barcode, not a payment card number.** Koha stores each
patron's library card barcode in `borrowers.cardnumber`. It is the number printed on the plastic
card used to borrow books. It is not a PAN and is not cardholder data. This plugin does not transmit
or store it in any case.

**A payment type of `CREDITCARD` on an accountline is a bookkeeping label.** It records that the
patron paid by card *somewhere*. It is a category name in Koha's accounting and does not imply that
card data is stored.

---

## 2. How a payment works

1. The patron selects fees to pay in the OPAC and confirms. Koha calls the plugin's
   [`opac_online_payment_begin`][pm71] hook.
2. **Patron's browser** submits a form [directly to FIS][begin92] carrying the patron's billing
   details and the fees being paid, and the patron enters their card details on FIS's page. Koha is
   not involved in that step and receives nothing from it.
3. **FIS** returns the patron to `opac-account-pay-return.pl`, which runs
   [`opac_online_payment_end`][pm104]. The passback carries the transaction result; the plugin reads
   only the transaction id and the line items from it.
4. **Koha server** posts to FIS's `ProcessTransactionStatus` API to verify the transaction
   ([`:131-139`][pm131-139]), authenticating with the merchant code, settle code and API password.
5. **Koha server** checks the returned transaction id matches, then credits the payment via
   [`Koha::Account->pay`][pm183-189].
6. **Separately**, FIS may post a notification to `/api/v1/contrib/fis/payment`
   ([`handle_payment`][api11]), which credits the payment by the same route
   ([`:82-88`][api82-88]).

```
  Patron browser          Koha (ByWater)                    FIS
        |                       |                            |
        |--- select fees ------>|                            |
        |<-- form to POST ------|                            |
        |------------------- card details ----------------->|   Koha not involved
        |<------------------ receipt -----------------------|
        |--- return + passback ->|                           |
        |                        |--- verify transaction --->|   no card data
        |                        |<-- transaction status ----|
        |<-- confirmation -------|                           |
        |                        |<-- payment notification --|   no card data
```

### Classification legend

| Value | Meaning |
|---|---|
| `CHD` | Cardholder data: PAN, cardholder name as it appears on the card, expiry, service code |
| `SAD` | Sensitive authentication data: full track data, CVV/CVC/CID, PIN or PIN block |
| `Card-derived` | Derived from a card but not CHD: card brand, truncated PAN, authorisation code |
| `Patron PII` | Personally identifying patron data: name, address, email, telephone |
| `Patron identifier` | Internal or library identifier: `borrowernumber`, library card barcode |
| `Financial` | Amounts, fee descriptions, accountline identifiers |
| `Opaque token` | A value with no meaning outside this transaction |
| `Non-personal` | Configuration, timestamps, URLs, status codes |

---

## 3. Data sent to the payment processor

### 3.1 The hosted payment form

**Transport:** HTTPS POST, submitted by the patron's browser, to the configured FIS post URL
**Form:** [`opac_online_payment_begin.tt:92-114`][begin92-114]

| Field | Source in Koha | Classification | Code |
|---|---|---|---|
| `MerchantCode` | plugin config | Non-personal | [`:93`][begin93] |
| `SettleCode` | plugin config | Non-personal | [`:94`][begin94] |
| `PaymentMethod` | constant `CreditOrDebit` | Non-personal | [`:95`][begin95] |
| `ReturnUrl` / `CancelUrl` | OPAC base URL | Non-personal | [`:96`][begin96], [`:97`][begin97] |
| `UserPart1` / `UserPart2` | patron first name / surname | Patron PII | [`:99`][begin99], [`:100`][begin100] |
| `UserPart3` | `borrowers.borrowernumber` | Patron identifier | [`:101`][begin101] |
| `BillingAddress` | `borrowers.address` | Patron PII | [`:103`][begin103] |
| `BillingName` | patron first name + surname | Patron PII | [`:104`][begin104] |
| `BillingCountry` | constant `US` | Non-personal | [`:105`][begin105] |
| `BillingCity` / `BillingState` / `BillingPostalCode` | patron address | Patron PII | [`:106`][begin106], [`:107`][begin107], [`:108`][begin108] |
| `BillingEmail` | `borrowers.email` | Patron PII | [`:109`][begin109] |
| `LineItems` | accountline id, **description** and amount per fee | Financial | [`:113`][begin113] |

**Cardholder data in this table: none.** No PAN, CVV, expiry, track or PIN field is constructed
anywhere in this plugin.

**Fee descriptions are transmitted.** Unlike some sibling plugins, this one sends the description of
each fee, which in Koha can name the borrowed item. See §6.

### 3.2 The transaction-verification call

**Transport:** HTTPS POST, server to server, to the configured FIS API URL
([`ProcessTransactionStatus`][pm131-139])

| Field | Contents | Classification | Code |
|---|---|---|---|
| `L2GMerchantCode` | plugin config | Non-personal | [`:134`][pm134] |
| `Password` | the decrypted API password | Secret | [`:135`][pm135] |
| `SettleMerchantCode` | plugin config | Non-personal | [`:136`][pm136] |
| `OriginalTransactionId` | transaction id from the passback | Opaque token | [`:137`][pm137] |

No patron data and no card data is sent on this call.

---

## 4. Data received from the payment processor

Three inbound channels. Field lists below are from FIS's *HTTP and XML Post* integration
specification (v2007 revision, © 2010 Fidelity National Information Services) supplied by the
vendor.

### 4.1 Passback to the return URL

**Authentication of this channel:** the patron's authenticated OPAC session.

Per the specification's passback schema, this carries `TransactionId`, `ConvenienceFeeAmount`,
`MerchantAmount`, `TotalAmount`, **`AuthorizationNumber`**, `TransactionDateStamp`, the full
billing block (`BillingName`, `BillingAddress`, `BillingCity`, `BillingState`, `BillingZip`,
`BillingCountry`, `BillingEmail`, `BillingPhone`), **`MaskedPaymentAccountNumber`**,
**`PaymentMethodCode`**, **`PaymentMethodDescription`**, `UserParts` and `LineItems`.

| Field | Classification | Read by the plugin? | Persisted? |
|---|---|---|---|
| `TransactionId` | Opaque token | Yes — [`:121`][pm121] | Yes, hashed, in `accountlines.note` |
| `LineItems` | Financial | Yes — [`:159`][pm159] | Indirectly, as the fees paid |
| `MaskedPaymentAccountNumber` | **Card-derived** (truncated PAN) | No | No |
| `AuthorizationNumber` | **Card-derived** | No | No |
| `PaymentMethodCode` / `PaymentMethodDescription` | **Card-derived** (brand) | No | No |
| Billing block | Patron PII | No | No |

**Cardholder data in this table: none.** `MaskedPaymentAccountNumber` is truncated to the last four
digits, which is not a PAN. No full PAN, expiry, CVV or track data appears in the specification's
passback schema.

The plugin reads only the transaction id and line items, and does not dump the request parameters,
so the card-derived fields arrive in the POST body and are discarded.

### 4.2 `ProcessTransactionStatus` response

**Authentication of this channel:** the merchant code, settle code and API password sent on the
request.

The response is parsed into an arbitrary key/value hash ([`:145-153`][pm145-153]) and only
`TransactionID` and `TransactionAmount` are read. The vendor specification supplied does not cover
this endpoint, so the field list below comes from **observed production responses** at a live site
(Washoe County Library, logs reviewed 2026-08-18):

| Field | Classification | Observed value shape |
|---|---|---|
| `IsValid` | Non-personal | `False` |
| `Message` | Non-personal | A diagnostic string, e.g. `TransactionStatusRequest--OriginalTransactionID is null or empty` |

**No card data appears in any observed response**, and no card-related field name appears anywhere
in that site's FIS log output. Note the caveat in §7: every observed response was a *failure*, so
the field list of a successful response remains unconfirmed.

### 4.3 Payment notification endpoint

**Transport:** HTTPS POST from FIS to `/api/v1/contrib/fis/payment` ([`handle_payment`][api11])
**Authentication of this channel:** None — the endpoint accepts unauthenticated requests. It
compares the submitted `MerchantCode` and `SettleCode` against the configured values
([`:34-45`][api34-45]), but those are not secrets. See §8.

Five parameters are declared ([`openapi.json`][oa]): `FISTransactionNumber`, `LineItems`,
`BorrowerNumber`, `MerchantCode`, `SettleCode`. The handler reads
[all posted parameters, declared or not][api18].

Per the specification's postback appendix, the variables FIS sends are **selected by the client per
merchant profile** and may include Transaction ID, **Authorization Code**, Return Code, Return
Message, Transaction Date Stamp, **Payment Method Code**, Merchant Amount, Convenience Fee,
Transaction Amount, the full billing block, User Parts 1–6 and Lineitems. That is the maximum the
specification permits, not what any given site receives.

**Observed in production** at a live site (Washoe County Library, 198 postbacks reviewed
2026-08-18), the profile sends exactly the five declared parameters and nothing else:
`FISTransactionNumber`, `BorrowerNumber`, `MerchantCode`, `SettleCode`, `LineItems`. No
authorisation code, no payment method code, no billing block.

**Cardholder data in this channel: none.** The masked card number is *not* among the postback
variables — it appears only in the passback of §4.1.

---

## 5. What Koha stores, and for how long

### 5.1 Database

**This plugin creates no tables of its own.** [`install`][pm492] and [`uninstall`][pm496] are bare
stubs.

| Store | Field | Contents | Classification | Written when | Retention |
|---|---|---|---|---|---|
| `accountlines` | `note` | `FIS: <sha256 of the transaction id>` | Opaque token | Payment credited via the return leg ([`:155`][pm155]) | With the accountline |
| `accountlines` | `note` | `FIS: <transaction id>` — **not hashed** | Opaque token | Payment credited via the notification endpoint ([`API.pm:47`][api47]) | With the accountline |
| `accountlines` | `amount` | Amount from the line item | Financial | Payment credited | With the accountline |
| `plugin_data` | five configuration keys | See §5.3 | Secret / Non-personal | Configuration saved | Until changed |

The two crediting paths write the transaction reference differently — the return leg hashes it, the
notification endpoint does not. Neither is card data.

**No cardholder data and no card-derived data is written to the database.**

### 5.2 Logs

Every statement below writes to the Koha application error log (`plack-error.log`, or the Apache
error log depending on deployment). **All are off unless debug logging is switched on** from the
configuration page ([`_debugging_enabled`][pm283]), which it is not by default.

| Statement | Location | Contents | Classification |
|---|---|---|---|
| `warn "FIS: PARAMS: " . Dumper($params)` | [`API.pm:19`][api19] | **The entire inbound notification** — see §4.3, so up to the authorisation code, payment method code and full billing block | **Card-derived**, Patron PII, Financial |
| `warn "FIS: RESPONSE CONTENT ..."` | [`:144`][pm144] | The full raw `ProcessTransactionStatus` response body | Not fully determined — see §7 |
| `warn "FIS: INCOMING PARAMS ..."` | [`:151`][pm151] | The parsed `ProcessTransactionStatus` response | Not fully determined — see §7 |
| `warn "FIS: LINE ITEM ..."`, `DESC`, `AMOUNT` | [`:165`][pm165], [`:171`][pm171], [`:172`][pm172]; [`API.pm:63`][api63], [`:68`][api68], [`:69`][api69] | Accountline ids, **fee descriptions**, amounts | Financial |
| `warn "FIS: BORROWERNUMBER ..."`, `TRANSACTION ID` | [`:119`][pm119], [`:122`][pm122]; [`API.pm:31`][api31], [`:60`][api60] | Patron number, transaction id | Patron identifier, Opaque token |

Two statements are **not** gated on the debug setting, by design: they report that a credential
could not be encrypted ([`:386`][pm386], [`:416`][pm416]). They contain no patron or card data.

**This is the only place any card-derived data can come to rest**, and only on a site that has
switched debug logging on.

**Confirmed in production.** At the site reviewed, running a version that predates the debug setting
(so logging was unconditional), the log holds one entry per payment containing the patron number and
the **title and call number of the borrowed item** the fee relates to, retained for as long as the
host's rotation policy keeps it. No card-derived data was present there — see §4.3 — but the patron
borrowing detail was. This is a patron-record confidentiality exposure rather than a PCI one; see
§6.

**Log retention:** log files are rotated and removed by the host operating system's `logrotate`
configuration, not by this plugin. The plugin has no control over, and makes no guarantee about, how
long log contents persist.

### 5.3 Configuration and credentials

Stored in Koha's `plugin_data` table. Earlier versions read these from system preferences of the
same name; [`_migrate_sysprefs_to_plugin_data`][pm439] moves them and removes the preferences, so
the credential is no longer readable by anyone holding only the `parameters` permission.

| Credential | Protection at rest | Visible to | Code |
|---|---|---|---|
| `FisApiPassword` | **Encrypted** — AES-256-CBC via `Koha::Encryption` | Staff with the `plugins` permission, and only as ciphertext | [`:379`][pm379] |
| `FisMerchantCode`, `FisSettleCode`, `FisPostUrl`, `FisApiUrl` | None — cleartext, not secrets | As above | [`:45`][pm45] |

The password is encrypted by [`_set_secret`][pm379] and decrypted by [`_get_secret`][pm341], both of
which load `Koha::Encryption` at runtime rather than at compile time, because it only exists from
Koha 22.05 and this plugin still supports older versions. Encrypted values carry a
[`koha-enc-v1:` prefix][pm40] so a migrated value can be told from one that predates encryption.

**The encryption key is not held by this plugin.** It is the `encryption_key` in `koha-conf.xml`,
which Koha does not generate for a new instance — a fresh install ships the placeholder
`__ENCRYPTION_KEY__`, and Koha reports this on the About page. Where no key is configured, the
plugin keeps working on its existing cleartext credential and says so on the configuration page;
the credential is not protected at rest in that state.

**Reading a credential that will not decrypt is fatal** ([`_get_secret`][pm341]). Decrypting under
the wrong key does not raise an error, it returns an empty string, so an empty result is treated as
a failure rather than as an empty credential. Payments stop with a clear message instead of a
corrupted password being sent to FIS.

Credentials stored in cleartext by earlier versions are encrypted in place by
[`_encrypt_stored_credentials`][pm406], called from [`upgrade`][pm468] and again whenever the
configuration page is opened.

The configuration form [submits with `method="post"`][conf28] and carries a
[CSRF token][conf32]. The password is rendered as an
[empty `type="password"` field][conf56] — the stored value is never sent to the template, so it
cannot be read from the page source and cannot be re-submitted and re-encrypted by saving the form.

**No cardholder data is held in configuration.**

### 5.4 Retention and disposal

- **Scheduled purge:** None. This plugin ships no cron job, TTL, or cleanup routine.
- **Records that accumulate:** none of its own — the plugin creates no tables.
- **On plugin uninstall:** [`uninstall`][pm496] removes nothing; the `plugin_data` rows remain.
- **Cardholder data retained:** **None.** No cardholder data is stored, so there is none to retain
  or dispose of.
- **Card-derived data retained:** none in the database. In application logs only, only where debug
  logging is enabled, and only for as long as the host's log rotation policy keeps them.

---

## 6. Patron personal data (outside PCI scope)

The data below is not cardholder data and is outside PCI DSS scope. It is documented here because it
is within scope of library patron-record confidentiality obligations, and because customers ask
about it in the same breath.

| Element | Sent to FIS | Received back | Stored by this plugin | Retention |
|---|---|---|---|---|
| Patron name | Yes — §3.1 | Yes, in the billing block | Logs only, if debugging is on | Host log rotation policy |
| Postal address, city, state, zip | Yes — §3.1 | Yes | Logs only, if debugging is on | Host log rotation policy |
| Email address | Yes — §3.1 | Yes | Logs only, if debugging is on | Host log rotation policy |
| Telephone number | No | Yes, as `BillingPhone` | Logs only, if debugging is on | Host log rotation policy |
| Library card barcode | No | No | No | Not applicable |
| `borrowernumber` | Yes, as `UserPart3` | Yes | No | Not applicable |
| **Itemised fee descriptions** | **Yes** — §3.1 | Yes, in `LineItems` | Logs only, if debugging is on | Host log rotation policy |

**Fee descriptions in Koha can name the borrowed item**, which makes them sensitive under most
library confidentiality policies and under several state library-record statutes. This plugin sends
them to FIS as part of `LineItems`, and logs them when debugging is enabled.

Once transmitted, FIS's handling of this data is governed by their privacy policy and the library's
agreement with them, not by this plugin.

---

## 7. Open questions

| Question | Why the code cannot answer it | Evidence needed | Effect on §1 |
|---|---|---|---|
| What does a **successful** `ProcessTransactionStatus` response contain? | The vendor specification supplied does not cover this endpoint. Production responses have been observed (§4.2), but every one was a failure — `IsValid=False` — because the verification call is broken at the site reviewed (§8). The success-path field list is therefore still unconfirmed. | FIS's `ProcessTransactionStatus` API specification, or a log from a site where the call succeeds. | None on rows 1–3: the plugin never requests card data, and no card-related field name has been observed in any response. A card-derived field on the success path would not change row 4, which is already "Yes". |
| Which postback variables does each library actually receive? | FIS's postback appendix states the variables are selected by the client per merchant profile, so the set is a site configuration rather than a property of this code. One site has been checked (§4.3) and sends no card-derived data; others are unverified. | Each library's FIS merchant profile. | None. The maximum set is documented in §4.3 and contains no cardholder data. |

---

## 8. Known limitations

These bear on the claims made in this document. They are recorded factually; none of them involves
cardholder data.

| Item | Location | Bearing on this document | Status |
|---|---|---|---|
| The payment notification endpoint declares no `x-koha-authorization` block and verifies no shared secret or signature. It compares the submitted merchant and settle codes against the configured values, but those identify the merchant rather than authenticate the caller, and the credited amount is taken from the caller-supplied line items. | [`openapi.json`][oa], [`API.pm:18`][api18], [`:34-45`][api34-45] | Does not affect the cardholder data determination in §1 — no card data is involved. Affects the integrity of the payment record. | Open |
| The two crediting paths write different notes for the same kind of event — the return leg hashes the transaction id, the notification endpoint stores it in cleartext. | [`:155`][pm155], [`API.pm:47`][api47] | Affects §5.1. Reconciliation and duplicate detection differ between the two paths. | Open |
| **The OPAC return leg never runs.** FIS delivers its passback as an HTTP POST to the return URL, and `Koha::Middleware::CSRF` rejects any POST to the staff or OPAC interface that carries no `csrf_token`, which a third-party processor cannot supply. Every such request is answered with a 403 before the plugin is reached. Confirmed in production at the site reviewed: 65 POSTs to the return URL, **all 403**, against 26 GETs that returned 200 — and a matching `Programming error - No CSRF token passed for POST .../opac-account-pay-return.pl` in the OPAC log for each. Payments are credited by the notification endpoint instead, which is why this has gone unnoticed. | `Koha::Middleware::CSRF`, [`opac_online_payment_end`][pm104] | Does not affect any determination in §1 — no card data is involved. It does mean the passback described in §4.1, including the card-derived fields, is rejected before Koha parses it. | Open — fix submitted upstream as [Koha Bug 41197](https://bugs.koha-community.org/bugzilla3/show_bug.cgi?id=41197), Passed QA |
| **Where the return leg does run, it cannot verify the transaction.** On instances predating CSRF enforcement, the plugin read an empty `TransactionId` from the passback — FIS supplies no such form field under the profile reviewed, consistent with the specification's XML Passback mode, where all passback data arrives in a single `Xml` field. The verification call is then rejected with `OriginalTransactionID is null or empty` and the patron is shown "The transaction id  for this payment is invalid" despite a successful payment. This is the older failure, now masked by the CSRF rejection above. | [`:122`][pm122], [`:131-139`][pm131-139], [`:196-202`][pm196-202] | Does not affect any determination in §1. Explains why every observed `ProcessTransactionStatus` response in §4.2 is a failure. | Open |
| Itemised fee descriptions are sent to FIS and appear in the log when debugging is on. | [`begin.tt:113`][begin113] | Outside PCI scope; within scope of patron-record confidentiality. See §6. | Open |
| The API password was held in cleartext in `plugin_data`, and in a system preference readable with only the `parameters` permission. | [`:45`][pm45] | Credential exposure, not cardholder data. | **Remediated in v2.1.0** — encrypted at rest, migrated off system preferences. See §5.3 |
| The configuration form submitted by `GET` with the password in a plain text field. | [`configure.tt:28`][conf28], [`:56`][conf56] | Credential exposure, not cardholder data. | **Remediated in v2.1.0** — form moved to `POST` with a CSRF token, and the credential is no longer rendered into the page |
| Debug logging was hardcoded on, writing the full processor response and fee descriptions to the log on every payment. | [`_debugging_enabled`][pm283] | This is what keeps row 4 of §1 conditional rather than unconditional. | **Remediated in v2.1.0** — now a configuration setting, off by default |

---

## 9. What was reviewed

Reviewed at commit [`878c5710ad2fb79552ff67b5723799457cf01050`][commit], version `v2.1.0`, on
2026-08-18.

Every code link in this document is pinned to that commit, so the lines cited are the lines that
were read, regardless of later changes.

| File | Checked for |
|---|---|
| [`PayViaFIS.pm`][pm] | Outbound form construction, verification call, return handling, configuration, credential storage, logging |
| [`PayViaFIS/API.pm`][api] | Inbound endpoint, channel authentication, payment crediting, logging |
| [`PayViaFIS/openapi.json`][oa] | Declared inbound parameters, authorisation requirements |
| [`PayViaFIS/opac_online_payment_begin.tt`][begin] | Values rendered into pages served to patrons; how the patron reaches the hosted page |
| [`PayViaFIS/configure.tt`][conf] | Values rendered into pages served to staff; form submission method |

**Vendor documentation:** FIS *HTTP and XML Post* integration specification (v2007 revision,
© 2010 Fidelity National Information Services), supplied by the vendor. Used for the passback schema
in §4.1 and the maximum postback variable list in §4.3.

**Production evidence:** application logs from Washoe County Library, reviewed 2026-08-18 — 198
payment notifications and the available OPAC return legs, across current and rotated logs. Used for
the observed `ProcessTransactionStatus` fields in §4.2, the observed postback field set in §4.3, and
the confirmation in §5.2 that fee descriptions reach the log. Only field names, message shapes and
counts were extracted; no patron record or credential value was copied out of those logs.

**Not reviewed:** build tooling, dependency trees, and Koha core. Koha core's own handling of
`accountlines` is outside this document. FIS's own systems and PCI DSS validation status are outside
this document — confirm those directly with FIS.

**Re-review is required when any of these change:** the outbound form construction, the verification
call, the API controller, `openapi.json`, or any logging statement in a payment code path.

---

## 10. Review history

| Date | Version | Commit | Reviewer | Change |
|---|---|---|---|---|
| 2026-08-18 | v2.1.0 | [`878c571`][commit] | Kyle M Hall | Initial review, against the v2.1.0 release and the vendor integration specification |
| 2026-08-18 | v2.1.0 | [`878c571`][commit] | Kyle M Hall | Confirmed §4.2, §4.3 and §5.2 against production logs from a live site, and recorded the non-functional OPAC return leg in §8 |
| 2026-08-18 | v2.1.0 | [`878c571`][commit] | Kyle M Hall | Corrected §8: the return leg is rejected by Koha's CSRF middleware before the plugin runs. The empty-transaction-id failure recorded earlier is the older, now-masked cause. |

---

<!--
Code links are pinned to the reviewed commit, so the lines cited stay the lines
that were read.

To re-review at a new commit:
  1. Replace every occurrence of the 40-character sha (this block, plus the
     display text in §9 and the commit link in §10).
  2. Replace the short sha in the §10 review-history table.
  3. Re-derive the line numbers — they are the part that rots. Each label
     encodes its own line span: [pm144] is PayViaFIS.pm line 144,
     [api34-45] is API.pm lines 34 to 45.
     Prefixes: pm = PayViaFIS.pm, api = API.pm, oa = openapi.json,
     begin = opac_online_payment_begin.tt, conf = configure.tt.
-->
[api]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS/API.pm
[api11]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS/API.pm#L11
[api18]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS/API.pm#L18
[api19]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS/API.pm#L19
[api31]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS/API.pm#L31
[api34-45]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS/API.pm#L34-L45
[api47]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS/API.pm#L47
[api60]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS/API.pm#L60
[api63]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS/API.pm#L63
[api68]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS/API.pm#L68
[api69]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS/API.pm#L69
[api82-88]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS/API.pm#L82-L88
[begin]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS/opac_online_payment_begin.tt
[begin100]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS/opac_online_payment_begin.tt#L100
[begin101]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS/opac_online_payment_begin.tt#L101
[begin103]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS/opac_online_payment_begin.tt#L103
[begin104]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS/opac_online_payment_begin.tt#L104
[begin105]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS/opac_online_payment_begin.tt#L105
[begin106]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS/opac_online_payment_begin.tt#L106
[begin107]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS/opac_online_payment_begin.tt#L107
[begin108]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS/opac_online_payment_begin.tt#L108
[begin109]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS/opac_online_payment_begin.tt#L109
[begin113]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS/opac_online_payment_begin.tt#L113
[begin92]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS/opac_online_payment_begin.tt#L92
[begin92-114]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS/opac_online_payment_begin.tt#L92-L114
[begin93]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS/opac_online_payment_begin.tt#L93
[begin94]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS/opac_online_payment_begin.tt#L94
[begin95]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS/opac_online_payment_begin.tt#L95
[begin96]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS/opac_online_payment_begin.tt#L96
[begin97]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS/opac_online_payment_begin.tt#L97
[begin99]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS/opac_online_payment_begin.tt#L99
[commit]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/commit/878c5710ad2fb79552ff67b5723799457cf01050
[conf]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS/configure.tt
[conf28]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS/configure.tt#L28
[conf32]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS/configure.tt#L32
[conf56]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS/configure.tt#L56
[oa]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS/openapi.json
[pm]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS.pm
[pm104]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS.pm#L104
[pm119]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS.pm#L119
[pm121]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS.pm#L121
[pm122]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS.pm#L122
[pm131-139]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS.pm#L131-L139
[pm134]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS.pm#L134
[pm135]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS.pm#L135
[pm136]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS.pm#L136
[pm137]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS.pm#L137
[pm144]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS.pm#L144
[pm145-153]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS.pm#L145-L153
[pm151]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS.pm#L151
[pm155]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS.pm#L155
[pm159]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS.pm#L159
[pm165]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS.pm#L165
[pm171]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS.pm#L171
[pm172]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS.pm#L172
[pm183-189]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS.pm#L183-L189
[pm196-202]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS.pm#L196-L202
[pm283]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS.pm#L283
[pm341]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS.pm#L341
[pm379]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS.pm#L379
[pm386]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS.pm#L386
[pm40]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS.pm#L40
[pm406]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS.pm#L406
[pm416]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS.pm#L416
[pm439]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS.pm#L439
[pm45]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS.pm#L45
[pm468]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS.pm#L468
[pm492]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS.pm#L492
[pm496]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS.pm#L496
[pm71]: https://github.com/bywatersolutions/koha-plugin-pay-via-fis/blob/878c5710ad2fb79552ff67b5723799457cf01050/Koha/Plugin/Com/ByWaterSolutions/PayViaFIS.pm#L71
