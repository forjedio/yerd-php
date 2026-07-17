# yerd-php

Builds **c-ares-free, static PHP binaries** (CLI + FPM) for
[yerd](https://github.com/forjedio/yerd) and publishes them — with a signed,
machine-readable manifest — as a single rolling GitHub Release that `yerdd`
consumes at runtime.

**Why this repo exists** and **every normative rule** live in
[`yerd-php-AGENTS.md`](./yerd-php-AGENTS.md) — the authoritative brief. This
README only maps that brief onto the files here. If the two disagree, the brief
wins.

## What runs

[`.github/workflows/release.yml`](.github/workflows/release.yml) is triggered
daily (schedule) or manually (`workflow_dispatch`). It is a thin driver that
calls the reusable
[`.github/workflows/release-channel.yml`](.github/workflows/release-channel.yml)
**once per channel** (see [Channels](#channels)), serialized against other
releases by a single `concurrency` group so revisions can't collide (§9). Each
channel run has three jobs:

1. **resolve** — fetch the channel's previously-published manifest, resolve the
   latest upstream patch per minor, and compute the build matrix + each build's
   `revision` from the *previous manifest* (§7 increment algorithm).
2. **build** (matrix, native runner per target) — build with static-php-cli,
   apply the c-ares patch, run the §5 gate, package the two single-member
   tarballs. macOS binaries are ad-hoc signed.
3. **publish** — regenerate the manifest, minisign-sign it (prehashed), upload
   assets → manifest → signature, then **prune last**; finish with a signed
   round-trip sanity check.

## Channels

Two channels publish into the **same** rolling release (tag `php`), each with
its own signed manifest, so `yerdd` can offer (or hide) the EOL tier
independently:

| Channel | Minors | Manifest | Extensions | ext partner |
|---|---|---|---|---|
| `stable` | 8.2 – 8.5 | `php.json` | full set | yerd-dump / pcov |
| `legacy` | 7.4 / 8.0 / 8.1 | `php-legacy.json` | trimmed (no `opentelemetry`, no `swoole`) | none (EOL) |

The channel is a single switch in `scripts/config.sh` (`CHANNEL=stable|legacy`)
that swaps the minors, extension set, and manifest name; every other script is
channel-agnostic. `publish.sh` prunes against the **union** of both manifests so
one channel never deletes the other's tarballs.

Legacy also runs one extra build step: `apply-legacy-cflags-patch.sh` forces
`-std=gnu17` for the php-src compile, because EOL minors bundle old K&R-style
`libbcmath` that the compiler's new C23 default rejects (stable pins its own std
and is unaffected). The `legacy` extension set otherwise stays provisional until
the first CI build confirms what spc accepts on EOL PHP — the authoritative list
is `php -m` on a shipped binary, not the requested set.

## Scripts (each maps to a brief section)

| Script | Brief | Role |
|---|---|---|
| `scripts/config.sh` | §1,§2,§3 | Single source of truth: minors, extension set, spc pin, targets, asset-naming |
| `scripts/latest-patches.sh` | §9 | Latest upstream patch per minor (php.net) |
| `scripts/targets-json.sh` | §1 | Target table → JSON |
| `scripts/resolve-builds.php` | §7 | Decide what to build + each `revision` (reads previous manifest) |
| `scripts/build-target.sh` | §4 | Clone pinned spc → patch → download → build → sign |
| `scripts/apply-curl-patch.sh` | §3 | Force `ENABLE_ARES=OFF`; **fail if it no-ops** |
| `scripts/apply-legacy-cflags-patch.sh` | legacy | Force `-std=gnu17` for EOL php-src (K&R libbcmath vs C23); **fail if it no-ops** |
| `scripts/sign-macos.sh` | §4 | Ad-hoc sign both macOS binaries (mandatory on arm64) |
| `scripts/verify-artifact.sh` | §5 | No-c-ares gate, `-m`/`-fpm -t`, real cross-repo ext load |
| `scripts/package-artifacts.sh` | §1 | The two single-member `.tar.gz` with exact names |
| `scripts/generate-manifest.php` | §7 | Merge carried-over + rebuilt entries; validate the contract |
| `scripts/sign-manifest.sh` | §6 | `minisign -H` (prehashed) with the dedicated key |
| `scripts/publish.sh` | §6 | Upload assets → manifest → sig, **prune last** |
| `scripts/sanity-check.sh` | §10.8 | Verify live signature + every asset sha256 |
| `scripts/keygen.sh` | §6 | One-time dedicated keypair generation |
| `scripts/third-party-notices.sh` | §8 | Assemble `THIRD-PARTY-NOTICES` |

## One-time setup

1. Generate this repo's **dedicated** minisign key (do **not** reuse yerd's
   app-update key):
   ```bash
   bash scripts/keygen.sh
   ```
2. Store the halves:
   - `gh secret set MINISIGN_SECRET_KEY < keys/yerd-php-minisign.key`
   - `gh secret set MINISIGN_PASSWORD` (if you set one)
   - `gh variable set MINISIGN_PUBLIC_KEY --body "$(tail -1 keys/yerd-php-minisign.pub)"`
3. Embed the public key in `yerdd` as `PHP_LISTING_PUBLIC_KEY`. Rotating it later
   is a coordinated yerd release (§6 key rotation).

The rolling release (tag `php`) is created automatically on the first publish.

## Operating it

- **Newer patch lands** → the daily schedule builds it at `revision 1`.
- **Rebuild an unchanged patch** (c-ares cutover, spc-ref bump, security) →
  `workflow_dispatch` with `force: true` (optionally `only_minor: 8.4`). This
  bumps the `-N` revision so existing installs actually receive it (auto-heal, §7).
- **Target one channel** → `workflow_dispatch` with `channel: legacy` (or
  `stable`). Default `both` (scheduled runs always do both). `only_minor` applies
  within the chosen channel(s), e.g. `channel: legacy`, `only_minor: 8.1`.
- **Bump static-php-cli** → change `SPC_REF` in `config.sh` and **re-verify the
  §3 curl.php patch still matches** (it's under upstream refactor). The build
  fails loudly if the patch no-ops.

## Local checks

The pure-logic pieces run without a build (set `CHANNEL` to pick the channel's
knobs; defaults to `stable`):
```bash
bash scripts/targets-json.sh
CHANNEL=stable bash -c 'source scripts/config.sh; echo "$SUPPORTED_MINORS -> $MANIFEST_NAME"'
CHANNEL=legacy bash -c 'source scripts/config.sh; echo "$SUPPORTED_MINORS -> $MANIFEST_NAME"'
php  scripts/resolve-builds.php --latest=latest.json --targets=targets.json --minors="8.2 8.3 8.4 8.5"
php  scripts/generate-manifest.php --built=matrix.json --assets-dir=dist --minors="7.4 8.0 8.1"
```
