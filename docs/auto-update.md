# In-app updates

Crater checks GitHub for a newer published release, downloads the
installer for the current platform, verifies its SHA-256, and hands it to
the OS. This document is the whole design: what it does, what it refuses to
do, and which parts have actually been exercised against a live release.

---

## 1. The shape of the feature, and the one rule behind it

Crater drives a projection screen in front of a room full of people. That
single fact decides almost every trade-off here.

**Nothing installs itself.** The check runs in the background. The download
runs on request. The step that closes Crater and runs an installer happens
on an explicit operator press, behind a confirm dialog, and never on a
timer. An updater that restarts the app halfway through a service is worse
than one that never runs at all.

The rest follows from the same rule:

- The only ambient behaviour is a version check, at most once a day, about
  twenty seconds after launch so it is clear of startup I/O.
- A background check that fails is silent. Being offline is the resting
  state of a lot of church A/V machines, and a red banner every Sunday
  morning trains the operator to ignore the one that matters. Only an
  operator-initiated check surfaces its errors.
- The "an update exists" affordance is a 7 px dot on the settings gear, not
  a toast, a modal, or a badge count. It is on the gear because that is
  where the Updates section lives, so the dot and its destination are the
  same click.
- An operator can skip a version. The check still runs and still records
  its timestamp; it just stays quiet until a release supersedes the skip.

## 2. Where the code lives

| Piece | File | Why there |
|---|---|---|
| The service | `app/src/UpdateService.{h,cpp}` | Needs `QNetworkAccessManager` and `QProcess`. `crater-core` links neither, exactly as documented on `LogReportService`. |
| Version ordering | `core/src/Version.cpp` | Pure text in, ordering out. Belongs where the headless test suite can reach it. |
| Checksum lookup | `core/src/Checksums.cpp` | Same reasoning. |
| Operator UI | `app/qml/dialogs/settings/UpdatesSection.qml` | Holds no update logic; it chooses which service state to render. |
| The dot | `app/qml/panels/TopBar.qml` | Bound to `UpdateService.state`. |
| Checksum generation | `.github/workflows/release.yml` (publish job) | Only that job has all four artifacts in one place. |
| Relaunch after install | `packaging/crater.iss` (`LaunchRequested`) | Inno needs to know an in-app update wants the app back. |

`architecture.md` §4 lists `UpdateService` in the service catalog. It is
still one service owning one concern; it just sits app-side for the same
dependency reason as `NdiService` and `BrowserCastService`.

## 3. Version ordering

`crater::compareVersions` is semver-lite and deliberately not a full semver
implementation, because the only versions that reach it are the ones our own
release workflow mints.

- A leading `v` is ignored, so the git tag `v0.6.1` and CMake's `0.6.1`
  compare equal. Without this every user sits one phantom update behind
  forever.
- The numeric core compares component-wise **as integers**. This is the
  reason the function exists at all: a string compare puts `0.10.0` below
  `0.9.0`, which silently freezes an updater the first time a component
  reaches double digits.
- A missing component reads as `0`, so `1.2` equals `1.2.0`.
- A pre-release suffix ranks below the same core, so `1.0.0-rc1 < 1.0.0`.
  Build metadata (`+build7`) is folded into the same slot rather than
  ignored, so it can never sort above the release it annotates.
- **Anything unparseable sorts low.** This is a security property, not
  laziness. These strings arrive over the network, so a garbled one must
  neither crash the updater nor be mistakable for an upgrade.

Covered by `core/tests/test_version_compare.cpp`.

## 4. The release feed and the trust chain

The feed is
`https://api.github.com/repos/vygr-labs/crater-v2/releases?per_page=50`,
pinned as a compile-time constant so nothing in a downloaded payload can
redirect the check itself.

**Why the list and not `/releases/latest`.** That endpoint means
most-recently-*created*, not highest-version, and this repository publishes
more than app builds — there is already a published `data-v1` release
holding the bundled Bible and Strong's databases. Publish a `data-v2` some
day and it becomes "latest"; the updater would read a version out of it, get
junk, sort the junk low, and report "up to date" from then on. Every
installation would silently stop updating, caused by a routine action with
no visible connection to the updater.

So the check asks for the list and picks the **highest** release whose tag
actually names an app build, per `crater::isVersionTag` — one or more
dot-separated digit runs after an optional `v`, so `v0.6.1` passes and
`data-v1` does not. Highest rather than first, because the list is ordered
by creation date and a patch cut after a later minor would otherwise win.

Drafts and pre-releases are filtered out, which preserves the property that
matters: `release.yml` publishes a **draft**, so "an update exists" means a
human pressed Publish, not merely that CI went green. (Unauthenticated
callers never see drafts anyway; the check is belt and braces.)

A response holding no app release at all is treated as "we learned nothing"
— `Idle`, or an error on a manual check — never as "you are up to date".

The repository is public, so the request is unauthenticated and no token
ships in the binary. GitHub's unauthenticated limit is 60 requests per hour
per IP; a once-a-day check is not close.

Three guards sit between the feed and running an executable:

1. **Host allow-list.** Every URL — the pinned one, every URL lifted out of
   the release payload, and every redirect hop — must be `https` on
   `api.github.com`, `github.com`, or `*.githubusercontent.com`. Asset
   downloads legitimately redirect to `release-assets.githubusercontent.com`;
   the hop being guarded against is one that leaves GitHub. Qt follows
   redirects for us, so the veto is a `QNetworkReply::redirected` handler
   that aborts.
2. **Exact asset name.** The installer is matched by the exact name
   `release.yml` produces (`Crater-Setup-<version>.exe` /
   `Crater-<version>-macos.dmg`), never by scanning for something
   `.exe`-shaped. The name is the one part of a release payload we can
   predict, so pinning it means an unexpected extra asset can never be
   picked up and run.
3. **No checksum, no install.** The download is verified against the
   release's `SHA256SUMS.txt`, falling back to the asset's own
   API-reported `digest`. When a release publishes neither, the service
   refuses and sends the operator to the release page rather than silently
   trusting the bytes. A mismatch deletes the file.

`SHA256SUMS.txt` is preferred over the API digest because it is computed
from the artifacts inside our own release job — a shorter chain of custody
than trusting the API's bookkeeping — and one fetch covers every platform.
Its parser lives in `crater::sha256ForName` and is covered by
`core/tests/test_checksums.cpp`, whose first fixture is byte-for-byte what
the workflow emits.

**Be honest about what this is.** Crater ships unsigned. The hash chain plus
TLS proves the bytes that arrived are the bytes the release job built, and
nothing more. It does not defend against a compromised GitHub account or a
malicious release. Signing the artifacts needs a code-signing certificate we
do not have yet; until then the Updates section says plainly what is
checked, so the operator is not discovering it from a SmartScreen prompt.

This sits alongside `architecture.md` §5.4 — a local attacker with code
execution on the operator machine remains out of scope, and such an attacker
does not need the updater.

### Is the check telemetry?

No, and the distinction matters given §11's "no telemetry without explicit
opt-in". The request is an unauthenticated `GET` of a public release feed.
It sends no identifier, no schedule, no library contents — only what any
HTTPS request unavoidably reveals (an IP address, and a `User-Agent` of
`Crater/<version>`). It can be turned off in Settings. Nothing about the
operator's service-prep behaviour goes anywhere.

## 5. States

```
Idle ──check──> Checking ──┬──> UpToDate
                           └──> UpdateAvailable ──download──> Downloading
                                                                  │
                                        ┌─────────────────────────┤
                                        ▼                         ▼
                                  ReadyToInstall              Failed
                                        │
                                     install ──> (app quits, installer runs)
```

- A cancel returns to `UpdateAvailable` with no error. A guard that aborted
  the transfer on purpose (oversize, untrusted redirect) leaves its reason
  in `m_pendingError` and surfaces as `Failed`, so the two are never
  confused.
- `availableVersion` deliberately survives a skip, so the section can say
  *which* version was skipped and offer to undo it. The UI keys the offer
  off `state`, not off `availableVersion` being set.
- A release with no artifact for this platform is still `UpdateAvailable` —
  it is; we simply cannot fetch it here. `downloadUpdate()` says so and the
  section offers the release page.

## 6. Downloading

Streamed to `<CacheLocation>/updates/` rather than buffered: the installer
is ~95 MB and `QNetworkReply` would otherwise hold all of it in memory.
Hashing the same chunks on the way past means verification costs one pass,
not a second read of the finished file.

- The size cap (512 MB) is enforced against bytes actually received, not
  against the declared content-length, so a server that lies about its size
  still stops at the cap rather than at "disk full".
- Anything in the updates directory that is not the current asset is swept
  before a download starts, so the cache never accumulates installers
  nobody will run again.
- A **verified** copy from an earlier session is reused. Reopening Crater
  should not re-download 95 MB the operator already has; a cached file whose
  hash no longer matches is deleted and fetched again.

## 7. Installing

`installMode` tells the QML what this platform can honestly promise:

- **`run`** (Windows) — `QProcess::startDetached` on the installer with
  `/SILENT /CLOSEAPPLICATIONS /NORESTART /LAUNCH=1`, then quit on the next
  event-loop tick. `/SILENT` rather than `/VERYSILENT` so the operator still
  sees a progress window, which is the difference between "the update is
  running" and "nothing happened". Quitting first means Inno's Restart
  Manager pass has far less to do.

  `/LAUNCH=1` is Crater's own parameter. `crater.iss`'s existing "Launch
  Crater" entry is `skipifsilent` and so will not fire on a silent run; a
  second `[Run]` entry gated on `LaunchRequested` covers exactly that case.
  It carries `runasoriginaluser` because setup is elevated, and a plain
  child process would inherit admin and leave Crater writing its AppData as
  the wrong user from then on.

  Elevation itself needs no special handling: Inno's `setup.exe` is
  manifested `asInvoker` and re-launches itself elevated per
  `PrivilegesRequired=admin`, so `CreateProcess` (which does not trigger
  UAC) is fine.

- **`reveal`** (macOS) — opens the `.dmg` and lets the operator drag Crater
  across. A running `.app` cannot replace itself without a separate helper
  binary, and shipping one to save a drag is not a trade worth making.

- **`unsupported`** — no installer artifact is published for this platform.

## 8. Settings and persistence

`QSettings{"Voyager Labs", "Crater"}`, the same store as `SettingsService`
and `OutputService`, under an `Update/` prefix:

| Key | Meaning |
|---|---|
| `Update/autoCheck` | Check once a day after launch. Default true. |
| `Update/lastChecked` | UTC timestamp of the last attempt, successful or not. |
| `Update/skippedVersion` | The version the operator turned down. |

`autoCheck` lives on `UpdateService` rather than in `SettingsService`
because it is the updater's own policy knob and nothing else reads it. The
Settings dialog binds straight to it, the same way it binds to
`BrowserCastService.listening` and `NdiService`.

`lastChecked` is written whether or not the check succeeded, so a machine
that is offline every Sunday still backs off to one attempt a day instead of
retrying on every launch. A stored timestamp in the *future* is treated as
due rather than trusted, or a single bad clock reading could suppress every
future check on that machine.

## 9. What has been verified, and what has not

Verified against the live `v0.6.1` release:

- Check, parse, and version comparison — `0.5.0` correctly sees `0.6.1`,
  and the scan skips the repository's published `data-v1` release.
- Asset selection by exact name, and the `github.com` →
  `release-assets.githubusercontent.com` redirect passing the allow-list.
- A full 97,980,388-byte download with SHA-256 verification, confirmed
  byte-identical to the published artifact by an independent hash.
- The cached-copy fast path (a second run resolves in ~1.4 s instead of
  re-downloading).
- Tamper rejection: two bytes flipped in the cached installer, which was
  detected, deleted, and re-fetched.
- Every UI state — up to date, available, downloading, ready, skipped,
  un-skipped — and the install confirm dialog.
- The startup auto-check firing on its own and recording its timestamp.

**Not** verified end to end:

- `fetchChecksums()`. No published release carries a `SHA256SUMS.txt` yet,
  so the live path exercises the API-`digest` fallback instead. The parser
  it feeds is unit-tested against the workflow's exact output, and the fetch
  uses the same guarded `get()` as the verified paths, but the wiring
  between them first runs for real on the next release.
- `installUpdate()` actually running the installer, which would have
  replaced the developer's installed Crater. The `/LAUNCH=1` relaunch can
  be exercised without the app: build an installer with
  `scripts/release.ps1` and run it by hand with the flags from §7.
- The macOS `reveal` path.
- A `data-v2`-shaped release actually being the newest one. The skip is
  order-independent — the loop takes the maximum over version tags, so a
  non-version tag is ignored wherever it sits — and `isVersionTag("data-v2")`
  is unit-tested, but no live release has that shape to reproduce against.

## 10. Known benign noise

Every request leaves one `QIODevice::read (QSslSocket): device not open`
warning in the log, exactly `kRequestTimeoutMs` (30 s) after that request
finishes. It is Qt's own transfer-timeout timer firing against a socket its
connection pool has already released — no Crater code touches a
`QSslSocket`. During a download the warning therefore appears mid-transfer,
30 s after the *check* that preceded it, which makes it look related to the
download when it is not.

Harmless: the check parses and the download verifies either way. Kept
rather than worked around because `setTransferTimeout` is what stops a
half-open connection hanging the updater forever, and one WARN line per
check is a cheaper price than hand-rolling that timer. If it ever becomes
confusing in a support log, the fix is an explicit `QTimer` that aborts the
reply instead of the built-in timeout.
