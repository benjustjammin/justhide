# Releasing JustHide

Two one-off setup jobs, then `./release.sh --publish` per version.

None of the secrets below should ever be pasted into a chat, a commit, or an
issue. The `.p8` key and the `.p12` password are the two that matter.

## Why signing properly is not optional here

macOS matches a permission grant against the app's *designated requirement*.
An ad-hoc signature — what `build.sh` produces by default — has a requirement
of `cdhash H"…"`, a hash of one exact build. Change a single line, rebuild, and
macOS sees an app it has never met: everyone's Accessibility permission resets.

A Developer ID signature has a requirement of `identifier "dev.justhide.app"
and certificate leaf[subject.OU] = <TeamID>`, which every future build
satisfies. Permissions survive updates, and Homebrew's quarantine stops being a
problem. Check any app you are curious about with:

```sh
codesign -d --requirements - /Applications/Something.app
```

## One-off: a Developer ID Application certificate

Xcode's Settings → Accounts → Manage Certificates is the easy route, but it
needs Xcode. This is the same thing with the command line tools only.

```sh
mkdir -p ~/.justhide-signing && cd ~/.justhide-signing
chmod 700 .

# 1. A key and a certificate request. The email should be your Apple ID.
openssl genrsa -out developer-id.key 2048
openssl req -new -key developer-id.key -out developer-id.csr \
    -subj "/emailAddress=you@example.com/CN=Your Name/C=GB"
```

2. At [developer.apple.com/account/resources/certificates](https://developer.apple.com/account/resources/certificates)
   → **+** → **Developer ID Application** → upload `developer-id.csr` → download
   `developerID_application.cer`. Creating this one needs the Account Holder
   role, and Apple limits how many you can have, so keep the key safe.

3. Put the key and the certificate in your keychain together, which is what
   makes it a usable signing identity:

```sh
openssl x509 -inform DER -in developerID_application.cer -out developer-id.pem
openssl pkcs12 -export -inkey developer-id.key -in developer-id.pem \
    -name "Developer ID Application" -out developer-id.p12
security import developer-id.p12 -k ~/Library/Keychains/login.keychain-db \
    -T /usr/bin/codesign
security find-identity -v -p codesigning     # should now list it
```

If the identity is listed but signing complains about the chain, the Apple
intermediate is missing: fetch **Developer ID – G2** from
[apple.com/certificateauthority](https://www.apple.com/certificateauthority/)
and double-click it.

Keep `developer-id.p12` — GitHub Actions needs it (below), and it is how you
move the identity to another Mac.

## One-off: notarisation credentials

An App Store Connect API key is better than an Apple ID password: it is
revocable and has no two-factor dance.

1. [appstoreconnect.apple.com](https://appstoreconnect.apple.com) → Users and
   Access → Integrations → App Store Connect API → **+**, role **Developer**.
2. Download `AuthKey_XXXXXXXX.p8`. Apple lets you download it once. Note the
   **Key ID** and the **Issuer ID** on that page.
3. Store it in your keychain so `release.sh` can use it without arguments:

```sh
xcrun notarytool store-credentials justhide \
    --key ~/.justhide-signing/AuthKey_XXXXXXXX.p8 \
    --key-id XXXXXXXX \
    --issuer xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

## Per release

```sh
# 1. Bump the version in Resources/Info.plist:
#      CFBundleShortVersionString  1.3      (what people see, and the tag)
#      CFBundleVersion             5        (increment every build)

# 2. Commit that, then:
./release.sh              # build, sign, notarise, staple, zip, print the cask
./release.sh --publish    # ...and create the release and bump the tap
```

`release.sh` reads the version from the bundle, so the tag, the zip name and
the cask always agree. It prints the designated requirement as it goes: if that
ever says `cdhash`, stop, because the release would reset every user's
permissions.

Then check it the way a stranger would:

```sh
brew update && brew install --cask benjustjammin/tap/justhide
```

## Releasing from GitHub Actions instead

`.github/workflows/release.yml` does the same thing on a pushed `v*` tag. It
needs these repository secrets (Settings → Secrets and variables → Actions):

| Secret | What it is |
| --- | --- |
| `DEVELOPER_ID_P12` | `base64 -i developer-id.p12` |
| `DEVELOPER_ID_P12_PASSWORD` | the password you set on that `.p12` |
| `AC_API_KEY_P8` | `base64 -i AuthKey_XXXXXXXX.p8` |
| `AC_API_KEY_ID` | the key's ID, e.g. `A1B2C3D4E5` |
| `AC_API_ISSUER_ID` | the issuer UUID from the same page |
| `TAP_TOKEN` | a fine-grained PAT with Contents: write on `benjustjammin/homebrew-tap` |

`base64 -i file | pbcopy` puts one on the clipboard without it going anywhere
near a terminal transcript.

Everything except `TAP_TOKEN` is the same material the local route uses; the
token only exists so the workflow can push the cask bump to the other repo.
Without it, the workflow still builds and releases, and you bump the cask
yourself.
