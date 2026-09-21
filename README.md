# blacklinksetups.github.io

Public frontend and release feed for **Anoneurx Blacklink**.

- **`/`** — landing page (install one-liner, links to the dashboard)
- **`/bash`** — hosted bootstrap: `curl -fsSL https://blacklink.anoneurx.com/bash | sudo bash`
- **`/LATEST`** — current release tag
- **`/pubkey.pem`** — Ed25519 public key that signs every release bundle
- **`/releases/<tag>/anoneurx-connect-<os>-<arch>.tar.gz`** — signed bundles (`+ .sig .sha256`)

Served via GitHub Pages with CNAME `blacklink.anoneurx.com`.

## Cut a release

Build the agent (`cargo build --release`), then pack and sign from the
`connect` repo:

```sh
# sign with the release private key (a copy lives on the release machine;
# the public half below is what clients verify against)
openssl pkeyutl -sign -inkey release-sign.key \
  -in anoneurx-connect-linux-x86_64.tar.gz \
  -out anoneurx-connect-linux-x86_64.tar.gz.sig
```

Upload new `releases/<tag>/` files, bump `LATEST`, push `main`, and Pages
serves the new bundle.

## Verify

```sh
openssl pkeyutl -verify -pubin -inkey pubkey.pem \
  -in anoneurx-connect-linux-x86_64.tar.gz \
  -sigfile anoneurx-connect-linux-x86_64.tar.gz.sig
```