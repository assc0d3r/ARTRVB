# 0015 — Builds are mirrored to a permanent archive repo

**Status:** accepted (2026-10-23)
**Affects:** `build.yml` publish chain, `generate_release_notes.py`,
`build_notify_telegram.sh`, `push_archive_manifest.sh`, the external repository
`nullcpy/archive` and its `website` branch, and the link targets in the release
note / Telegram / Discord messages.

## Context

rvb prunes its numbered releases to the newest 98 and its archive release assets
to two versions per app+arch. The release-note download links — the same body
rendered into the Telegram and Discord notices — pointed at the *numbered*
release, so any build older than ~98 links 404. Users wanted a durable home for
the files so an old announcement keeps resolving, and eventually a site built
from that home.

## Decision

After the numbered upload, mirror the exact `./build/*` set into
`nullcpy/archive` under the identical build-number tag, using a repo-scoped PAT
(`ARCHIVE_REPO_TOKEN`) and an opt-in variable (`ARCHIVE_REPO`). Generate a second
note, `build.archive.md`, whose **only** difference from `build.md` is the
per-file download base, and use it as the archive release body and the source
for Telegram + Discord; rvb's own numbered release keeps the rvb-linked
`build.md`. Publish each build's immutable `manifests/<tag>.json` to
`nullcpy/archive`'s `website` branch so a site can be generated from the mirror.

- The mirror is **numbered-only**: no rolling `stable`/`beta` there, no cleanup
  workflow in phase 1; retention is a later coarse time/count cap, applied as
  whole-build deletion, which never changes the link format.
- The whole feature is gated on `vars.ARCHIVE_REPO`; unset leaves every run
  byte-identical to before (a field nobody named is not written).
- The mirror and manifest steps are `continue-on-error`, and the manifest
  publisher fails soft: a mirror or metadata-push miss never loses the rvb
  release or reddens a run whose files already shipped.

## Rejected alternatives

- **Point links at rvb's rolling archive release instead.** It is pruned to two
  versions per app+arch too, and its assets already carry the module `updateJson`
  coupling — moving the note links there does not make them permanent.
- **Per-app package-name tags (like `nullcpy/apks`).** Dissolves the single
  build-wide release note, needs a second tag grammar for module zips (which have
  no Android package), and pays for a retention mechanism now for a size problem
  that has not arrived.
- **Stop hosting files in rvb.** A far larger change to the current site and
  update flow; rvb stays the recent-builds face and the mirror is the durable
  store, with files stored twice as the price.
- **Ship a monolithic `data.json` for the mirror's site.** At up to ~1000 builds
  that is a multi-MB blob plus a live Releases-API existence/size fan-out on every
  rebuild. The frontend is therefore deferred; when built it must shard by
  app/brand, cache size into the manifest at publish, and lazy-load counts.

## Consequences

- `nullcpy/archive` grows unbounded until the coarse cap is added — storage
  tracks the whole history, not live demand.
- The two notes must stay identical apart from the download base. This is
  enforced by the normalise-and-compare block in `test_archive_mirror.sh`, not by
  discipline.
- A future archive site must import `naming.py` the same way rvb's does
  ([0006](0006-filename-parsing-is-imported-not-mirrored.md)); the schema-fork
  question is deliberately left to the day the site is built.

## Verification

`bash .github/traces/test_archive_mirror.sh` — blocks (a)–(d): the two-note split
with a negative control for the unset variable, the uploader targeting the mirror
repo, the manifest publisher's create/update/fail-soft, and the `NOTES_FILE`
override and fallback. Plus a Manual CI dispatch with `ARCHIVE_REPO` set.
