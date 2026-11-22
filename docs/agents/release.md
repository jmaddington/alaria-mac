# Releases (signing, notarization, downloads) - adapted from Murmur 2026-11-22

- **CI** (`.github/workflows/ci.yml`, every push to main and every PR): `swift run hermes-checks` (unit only), build,
  unsigned DMG smoke test, uploaded as a 7-day workflow artifact.
- **Release** (`.github/workflows/release.yml`): push a tag `vX.Y.Z`, or run it manually with a version. In order:
  1. Checks.
  2. `scripts/ci/import-certs.sh` imports the Developer ID cert (non-exportable) into a throwaway keychain and
     checks the notary API key.
  3. Refuses to continue unless both the signing identity and the notary key are present.
  4. `scripts/build.sh` with VERSION/BUILD, then `scripts/package.sh`: DMG, sign, notarize and staple, SHA256SUMS.
  5. Verify (codesign, stapler validate, spctl).
  6. `gh release` uploads `Talaria-X.Y.Z.dmg` and `SHA256SUMS.txt`.
  7. Deletes the keychain and the notary key.
- **Local:** `./scripts/build.sh && DMG_NO_FINDER=1 ./scripts/package.sh`. `DMG_NO_FINDER` skips create-dmg's Finder
  window layout, which pops Finder windows on a shared desktop. Notarization runs locally only if
  NOTARY_KEY_PATH/ID/ISSUER are set.
- **Repo secrets** (same values as jmaddington/murmur; GitHub can't copy them between repos):
  - `DEVELOPER_ID_APP_P12`: `base64 -i DeveloperIDApplication.p12`
  - `DEVELOPER_ID_APP_PASSWORD`: the .p12 password
  - `ASC_API_KEY_P8`: the App Store Connect API key .p8, as text or base64
  - `ASC_API_KEY_ID`, `ASC_API_ISSUER_ID`
- The repo is private, so release downloads need GitHub access. Make the repo, or a separate releases repo, public
  to hand out links.
- Not yet: Sparkle auto-update (Murmur has it on the `sparkle-autoupdate` branch: Updater.swift, make-appcast.sh,
  SUFeedURL pointing at releases/latest/download/appcast.xml).
