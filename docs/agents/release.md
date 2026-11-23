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
  6. `gh release` uploads `Alaria-X.Y.Z.dmg` and `SHA256SUMS.txt`.
  7. Deletes the keychain and the notary key.
- **Local:** `./scripts/build.sh && DMG_NO_FINDER=1 ./scripts/package.sh`. `DMG_NO_FINDER` skips create-dmg's Finder
  window layout, which pops Finder windows on a shared desktop. Notarization runs locally only if
  NOTARY_KEY_PATH/ID/ISSUER are set.
- **Repo secrets** (same values as jmaddington/murmur; GitHub can't copy them between repos). Set them with
  `scripts/ci/set-release-secrets.sh <DeveloperID.p12> <AuthKey_ID.p8>` (prompts for the password and issuer ID):
  - `DEVELOPER_ID_APP_P12`: `base64 -i DeveloperIDApplication.p12`
  - `DEVELOPER_ID_APP_PASSWORD`: the .p12 password
  - `ASC_API_KEY_P8`: the App Store Connect API key .p8, as text or base64
  - `ASC_API_KEY_ID`, `ASC_API_ISSUER_ID`
  - `SPARKLE_ED_PRIVATE_KEY`: EdDSA key that signs updates (set 2026-11-23; see Auto-update).
- The repo is public (2026-11-23) so Sparkle and download links work without GitHub auth.

## Auto-update (Sparkle 2, hermes-mac-d3k; ported from Murmur's sparkle-autoupdate branch)

- App: `App/Updater.swift` (starts only inside a .app with SUFeedURL), "Check for Updates…" in the app menu,
  Settings > Updates (auto-check / auto-install toggles, Check Now). Checks daily.
- Feed: `SUFeedURL` = `releases/latest/download/appcast.xml`. The release job runs `scripts/make-appcast.sh` on the
  notarized DMG and uploads `appcast.xml` with it. Each appcast holds only its own release.
- Signing: DMG EdDSA-signed with `SPARKLE_ED_PRIVATE_KEY`; the app accepts only updates matching `SUPublicEDKey` in
  Resources/Info.plist. **Key backup is in the maintainer's login keychain, account `sparkle-alaria`. If it is lost,
  installed copies cannot verify future updates.** Export: `$(scripts/ci/sparkle-tools.sh)/generate_keys --account
  sparkle-alaria -x alaria-sparkle.key`.
- Versioning: Sparkle compares CFBundleVersion = the release workflow run number, so it always increases.
- Build: `scripts/build.sh` embeds Sparkle.framework from `.build/artifacts` and signs it inside-out before the app.
- Upgrading Sparkle: bump `Package.swift` and `SPARKLE_VERSION`/`SPARKLE_SHA256` in `scripts/ci/sparkle-tools.sh`.
- Local dry run: `SPARKLE_KEYCHAIN_ACCOUNT=sparkle-alaria VERSION=… BUILD=… scripts/make-appcast.sh build/dist/Alaria-….dmg`.
- Builds without Sparkle (anything before the first release) must install the first release by hand.
