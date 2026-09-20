# Recovery verification

21 September 2026. Recovery base: main `c692a4b`; original presenter experiment base: `887a6e067a9f45e2e91054eb6bc2f110c77117b7`.

- Reconstructed a disposable checkout from the original base using `git archive`. `git apply --check` and application of the reference patch passed. All **33 resulting source/test files** matched the hashes in `provenance.json`.
- Ran the complete reconstructed browser test suite: **109 passed, one failed**. The failure is `Store public key matches the native host's explicit Store identity`, because the historical store public-key file was deliberately excluded from this feature recovery. That is an absent historical fixture, not a passing store-identity check. Do not infer current package identity or release readiness from this snapshot.
- Ran the two recovered capability suites independently, `bookmarks.test.js` and `profile-focus.test.js`: **36 passed**. They exercise fake Chrome APIs, including permission revocation, bounded metadata, URL validation, exact-ID opening, expiry/cancellation, focus uncertainty and stale events. They do not establish real Chrome behavior.
- Inspected the preserved diff for personal paths, credentials and live customer URLs. Included addresses are public project links or synthetic fixtures. Store artwork, signing material, personal records, historic publication assertions and the old owner's documentation were excluded.
- Inspected the recovered holding-screen illustration. It is an unchanged, generated concept with fictional content and an explicit non-shipping label; its original prompt and hash accompany it.

No native Workbench compilation, live browser, user-library migration, app install, capture permission, screen-sharing receiver or store validation was performed for this reference patch. Integrating any feature into current main requires its own focused tests and real acceptance. The old source stays recoverable even when a proposed feature is deferred.
