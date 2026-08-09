# Developer ID Provisioning

One-time procedure for provisioning the Apple signing and notarization credentials the release workflow requires, and for rehearsing a distribution build locally before tagging. Repeat the relevant section when a certificate or API key is rotated.

All credential artifacts must be written **outside the repository**. `.gitignore` covers `*.p12`, `*.p8`, `*.pem`, and `*.key`, but not `*.base64`; a base64 encoding of a private key is equivalent to the key itself. Delete every intermediate file once the secrets are stored.

## 1. Select the signing certificate

```bash
security find-identity -v -p codesigning
```

More than one `Developer ID Application` certificate for the same team may be valid at once. Map each to its expiry before choosing:

```bash
security find-certificate -a -Z -p -c "Developer ID Application: Yuhao Jiang (KAMM5N88X3)" | awk '
/^SHA-1 hash:/ { hash=$3 }
/^-----BEGIN/ { pem=$0"\n"; inpem=1; next }
inpem { pem=pem $0"\n" }
/^-----END/ { inpem=0; print hash > "/dev/stderr"; printf "%s", pem | "openssl x509 -noout -enddate"; close("openssl x509 -noout -enddate"); pem="" }'
```

Use the certificate with the latest expiry. Because duplicates share a common name, **sign by SHA-1 hash, not by name** — `codesign` and `xcodebuild` both reject an ambiguous common name.

## 2. Export the certificate

Keychain Access is the reliable path; `security export` cannot select a single identity.

1. Keychain Access → login keychain → My Certificates.
2. Select the certificate chosen above (confirm via Get Info → Expires).
3. Right-click → Export → Personal Information Exchange (`.p12`), saved outside the repository.
4. Set an export passphrase.

Verify the exported file is the intended certificate and carries its private key:

```bash
openssl pkcs12 -in "$P12" -nodes -passin pass:"$P12_PASSWORD" 2>/dev/null \
  | openssl x509 -noout -fingerprint -sha1 -enddate
```

The fingerprint must match the SHA-1 hash selected in step 1.

## 3. Issue the notarization key

App Store Connect → Users and Access → Integrations → App Store Connect API → **Team Keys** → Generate API Key. The `Developer` role is sufficient.

Individual keys are not accepted by `notarytool`; the key must be a Team Key. The `.p8` downloads once and cannot be retrieved again.

Verify the credentials authenticate before using them in a build. This call only authenticates and submits nothing:

```bash
xcrun notarytool history --key "$P8" --key-id "$KEY_ID" --issuer "$ISSUER_ID"
```

## 4. Rehearse a distribution build locally

Run this before the first release on a new certificate or key. A failure here is cheap; the same failure against a pushed tag is not, because tags are immutable and must never be replaced.

```bash
SCRATCH="$(mktemp -d)"
IDENTITY=<sha1-hash-from-step-1>
PUBLIC_ED_KEY="$(defaults read /Applications/YohakuCompanion.app/Contents/Info SUPublicEDKey)"

xcodebuild archive \
  -project YohakuCompanion.xcodeproj \
  -scheme YohakuCompanion \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$SCRATCH/YohakuCompanion.xcarchive" \
  -clonedSourcePackagesDirPath "$SCRATCH/SourcePackages" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  SPARKLE_FEED_URL="https://github.com/Innei/YohakuCompanion/releases/latest/download/appcast.xml" \
  SPARKLE_PUBLIC_ED_KEY="$PUBLIC_ED_KEY"

xcodebuild -exportArchive \
  -archivePath "$SCRATCH/YohakuCompanion.xcarchive" \
  -exportPath "$SCRATCH/export" \
  -exportOptionsPlist ExportOptions.plist

SIGNING_IDENTITY="$IDENTITY" bash scripts/prepare_arm64_app.sh "$SCRATCH/export/YohakuCompanion.app"

ditto -c -k --keepParent "$SCRATCH/export/YohakuCompanion.app" "$SCRATCH/notarize.zip"
xcrun notarytool submit "$SCRATCH/notarize.zip" \
  --key "$P8" --key-id "$KEY_ID" --issuer "$ISSUER_ID" --wait
xcrun stapler staple "$SCRATCH/export/YohakuCompanion.app"
xcrun stapler validate "$SCRATCH/export/YohakuCompanion.app"
spctl --assess --type execute --verbose=4 "$SCRATCH/export/YohakuCompanion.app"
codesign -dv --verbose=4 "$SCRATCH/export/YohakuCompanion.app"
```

`ExportOptions.plist` supplies `teamID`; `xcodebuild -exportArchive` has no command-line override for it. When rehearsing against a team the committed plist does not name, copy the plist outside the repository, edit the copy, and point `-exportOptionsPlist` at it.

The final `codesign` output must show `Authority=Developer ID Application:` and a `CodeDirectory` whose `flags` include `runtime`.

### Hardened runtime regression checks

The hardened runtime cannot be asserted from CI alone. Launch the stapled application once and confirm:

- The application starts and its menu bar item appears.
- Media capture returns data through both providers: `JXAMediaInfoProvider` (spawns `/usr/bin/osascript`) and, on hosts older than macOS 15.4, `LegacyMediaInfoProvider` (loads the MediaRemote private framework).
- Window-title capture works after Accessibility is granted.
- Credentials resolve to Keychain rather than the protected journal:
  ```bash
  security find-generic-password -s dev.innei.YohakuCompanion.credentials.v1
  ```

## 5. Store the secrets

Values are piped directly so no plaintext copy is written to disk:

```bash
base64 -i "$P12" | gh secret set BUILD_CERTIFICATE_BASE64
base64 -i "$P8"  | gh secret set NOTARY_PRIVATE_KEY_BASE64
gh secret set P12_PASSWORD      # prompts for a hidden paste
gh secret set NOTARY_KEY_ID
gh secret set NOTARY_ISSUER_ID
```

Confirm all seven release secrets are present:

```bash
gh secret list
```

`SPARKLE_PRIVATE_KEY` and `SPARKLE_PUBLIC_ED_KEY` are provisioned separately and are not Apple credentials.

## 6. Clean up

```bash
rm -rf "$SCRATCH"
rm -f "$P12" "$P8"
```

Keep an offline backup of the `.p12`, its passphrase, and the `.p8` in a password manager. The `.p8` cannot be downloaded from App Store Connect a second time.
