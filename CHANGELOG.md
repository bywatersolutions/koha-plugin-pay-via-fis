# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- **The configuration page now actually configures the plugin.** All five settings were written to
  plugin storage by the configuration page, but the payment path read them from system preferences
  of the same name, so saving the configuration had no effect on payments. Plugin storage is now the
  only source of truth.
- The FIS API password is no longer passed into the OPAC template. It was never rendered, but a
  credential had no business being in a patron-facing template's scope.
- `FisApiPassword` was read in the payment-notification endpoint and never used. That read is gone —
  FIS does not send the password back, so it played no part in verifying the notification.

### Security

- The FIS API password is now encrypted at rest with `Koha::Encryption` (AES-256-CBC) instead of
  being stored in cleartext. Existing passwords are migrated automatically on upgrade.
- The password is no longer held in `systempreferences`, where it was readable by anyone with the
  `parameters` permission — a wider audience than the `plugins` permission that guards plugin
  storage.
- The configuration form now submits via `POST` with a CSRF token, so a newly entered password no
  longer appears in staff browser URLs, browser history, or the web server access log.
- The configuration page no longer renders the stored password back into the form. The field is a
  password input and is left blank; leave it blank to keep the existing password.

### Added

- **An "Enable debug logging" checkbox on the configuration page.** Debug logging was hardcoded on
  and could only be turned off by editing the plugin source. It is now a setting, and it defaults to
  **off**.
- `upgrade()`, which migrates the five settings out of system preferences and then encrypts the
  password. It is idempotent, and never throws — an instance with no encryption key keeps working on
  its existing cleartext password rather than dropping out of Koha's plugin list.
- `t/db_dependent/PayViaFIS.t`, covering the system-preference migration, its precedence and
  idempotency, the cleartext fallback, the fail-closed paths, and the debug-logging setting.

### Changed

- The `FIS Post URL`, `Merchant Code`, `Settle Code` and `API URL` fields are now HTML-escaped in the
  configuration form.
- CI now runs `prove` recursively, so tests under `t/db_dependent/` are actually collected.

### Notes

- Upgrading removes the `FisPostUrl`, `FisMerchantCode`, `FisSettleCode`, `FisApiUrl` and
  `FisApiPassword` system preferences. Downgrading afterwards will leave the older release with no
  configuration until those preferences are recreated by hand.
- Where a system preference and plugin storage disagreed, the system preference wins — it is the
  value FIS was actually being sent.
- **Debug logging is now off after upgrading**, where previously it was always on. Sites that want
  it keep it with one checkbox on the configuration page. One previously ungated `warn` (the
  transaction id, `PayViaFIS.pm`) is now gated along with the rest.
- Encryption needs an `encryption_key` in `koha-conf.xml`; Koha does not generate one. Without it the
  plugin behaves as before and the configuration page shows a warning. See the README.
- Encryption requires Koha 22.05 or newer. On older versions the plugin runs unchanged.
