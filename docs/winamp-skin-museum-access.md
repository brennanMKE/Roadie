# Getting Skins from the Winamp Skin Museum (skins.webamp.org)

Companion to `winamp-skin-player-brief.md`. Replaces the Internet Archive `ia download` approach in that brief's Tooling section with the Museum's own API as the primary source. Internet Archive stays as a fallback.

Everything below was verified against the Museum's source in the Webamp monorepo (`packages/skin-database`: `api/graphql/schema.graphql`, `api/graphql/resolvers/BulkDownloadConnection.ts`, `data/skins.ts`, `app/bulk-download/page.tsx`). It was **not** tested against the live API from here (network blocked), so run the smoke test in step 1 before anything else.

## The three ways in

| Option | Effort | Best for |
|---|---|---|
| **A. Museum bulk download page** `https://skins.webamp.org/bulk-download` | None | One-time grab of everything into a folder. Chrome or Edge only (uses the File System Access API). |
| **B. GraphQL API + our own downloader** | Small script | Repeatable, resumable sync with metadata (NSFW flag, readme text, screenshots) written to a manifest for the app's library. **Use this.** |
| **C. Internet Archive** `collection:winampskins` | Small script | Fallback if the Museum is down. No NSFW flags, more duplicates. |

Option A is worth knowing about, but B gives us the metadata the library needs, so build B.

## Endpoints and URL patterns

- GraphQL: `https://skins.webamp.org/graphql` (the Museum's own client uses this). Older posts cite `https://api.webamp.org/graphql`; either may work, test both. GET with `?query=` returns "Must provide query string", so use **POST JSON** `{"query": ..., "variables": ...}`.
- Skin files (Cloudflare R2 CDN), keyed by md5:
  - Classic: `https://r2.webampskins.org/skins/{md5}.wsz`
  - Modern: `https://r2.webampskins.org/skins/{md5}.wal`
  - Screenshot: `https://r2.webampskins.org/screenshots/{md5}.png`
- Always prefer the `download_url` / `screenshot_url` the API returns over building URLs; the CDN host has changed before (`cdn.webampskins.org` is commented out in the source).

## Schema facts that matter

### `bulkDownload(first: Int = 1000, offset: Int = 0): BulkDownloadConnection`
- Purpose-built for this. Page size max **10,000** (server throws above that). The Museum's own page uses 1,000 per page.
- Returns `totalCount`, `estimatedSizeBytes` (just `count * 56 KB`, a rough estimate), and `nodes: [Skin!]`.
- Ordered by internal skin id ascending, so offset paging is stable as long as nothing is inserted mid-run. New uploads get higher ids, so re-runs pick them up at the end.
- **Includes both classic and modern skins.** Use `__typename` (`ClassicSkin` vs `ModernSkin`) to tell them apart. No server-side NSFW filter here, so filter client-side.

### `Skin` fields (interface; `ClassicSkin` adds a few)
- `md5`, `download_url`, `screenshot_url`, `museum_url`, `webamp_url`
- `filename(normalize_extension: Boolean, include_museum_id: Boolean)`: pass both `true` to get a correct extension and a globally unique name like `Foo_[S12345].wsz`.
- `nsfw: Boolean` (nullable; null means never flagged)
- `readme_text: String`
- `average_color: String`
- `archive_files { filename size date file_md5 is_directory text_content url }`: the per-file listing inside the zip. `url` goes through an on-the-fly Cloudflare extractor and "may not work for all files", so don't depend on it.
- `reviews { rating reviewer }` with `rating` in `APPROVED | NSFW | REJECTED`
- `internet_archive_item { identifier url metadata_url }`: link back to the IA copy, useful for fallback.
- ClassicSkin only: `has_media_library: Boolean`, `transparent_pixels: Int`.

### Other queries
- `statistics { unique_classic_skins_count nsfw_skins_count approved_skins_count ... }`: sanity-check totals before a run.
- `skins(filter: APPROVED|NSFW|REJECTED|TWEETED, first, offset)`: classic only, filterable. Useful if we ever want "curated only".
- `search_classic_skins(query, first, offset)` / `search_skins(...)`: SQLite FTS search. Handy for a live "search the Museum" feature in the app later.
- `fetch_skin_by_md5(md5)`: look up one skin, e.g. to enrich a local file we already have.

## Step 1: Smoke test

```bash
curl -sS -X POST https://skins.webamp.org/graphql \
  -H 'Content-Type: application/json' \
  -d '{"query":"{ statistics { unique_classic_skins_count nsfw_skins_count } bulkDownload(first: 2) { totalCount estimatedSizeBytes nodes { __typename md5 filename(normalize_extension: true, include_museum_id: true) download_url nsfw } } }"}'
```

If that fails, retry against `https://api.webamp.org/graphql`. If the field names differ, run an introspection query and update this doc before writing code.

## Step 2: The sync query

```graphql
query BulkDownload($offset: Int!, $first: Int!) {
  bulkDownload(offset: $offset, first: $first) {
    totalCount
    nodes {
      __typename
      md5
      filename(normalize_extension: true, include_museum_id: true)
      download_url
      screenshot_url
      museum_url
      nsfw
      readme_text
      average_color
      ... on ClassicSkin { has_media_library transparent_pixels }
    }
  }
}
```

Start with `first: 1000`. Don't request `archive_files` or `reviews` in bulk; they multiply response size and server work. Fetch those per skin later only if needed.

## Step 3: Downloader requirements (`scripts/sync-museum.py` or a `skintool sync` subcommand)

1. Page through `bulkDownload` until `offset >= totalCount`, sleeping ~1 s between pages.
2. Write every node to `manifest.jsonl` (one JSON object per line) as soon as a page arrives, so metadata survives even if file downloads fail.
3. Filter: default **classic only** (`__typename == "ClassicSkin"`) and **skip `nsfw == true`**. Flags: `--include-modern`, `--include-nsfw`, `--screenshots`.
4. Download `download_url` to `skins/{shard}/{filename}`. Shard like the Museum's page does: first two lowercase chars if alphanumeric, `{c}x` if the second char isn't, `0-9` for non-letters. Keeps directories small.
5. **Resumable:** skip files that already exist with the right md5. Write to `*.part` then rename.
6. **Verify:** compute md5 of each download and compare to `md5`. Mismatch = delete and log.
7. **Concurrency 6** (matches the Museum's own page), exponential backoff on 429/5xx, give up on a skin after 3 tries and log it to `failures.jsonl`.
8. Optional screenshots to `screenshots/{md5}.png` for library thumbnails. Still render our own thumbnails too; comparing ours to theirs is a free parser regression test.
9. Set a descriptive `User-Agent` with a contact email.
10. Print a summary: total, downloaded, skipped existing, filtered (modern/nsfw), failed, bytes.

Rough size: ~56 KB average per skin, so the full set is on the order of a few GB, plus screenshots if enabled.

## Step 4: Feed the app's library

The skin library indexer in the main brief should read `manifest.jsonl` when present instead of re-deriving metadata:
- Key by `md5` (already deduplicated by the Museum).
- `filename`, `readme_text`, `average_color`, `nsfw`, `museum_url` go straight into the SQLite index. `average_color` is a nice cheap sort/filter for the grid browser.
- Local parse status/warnings still come from our own `SkinKit` parse.
- Files with no manifest entry (user dropped in their own skins) fall back to the existing local-only indexing. Optionally enrich them via `fetch_skin_by_md5`.

## Etiquette and risks

- This is one person's hobby infrastructure. The API's own default query says it's "mostly intended for exploring the data set." Be gentle: sequential page fetches, modest download concurrency, cache everything, never re-download what we have.
- For a full mirror, consider emailing Jordan Eldredge first (contact listed in the API's default query); he has offered the raw sqlite DB to people who ask, which would avoid paging the API at all.
- Don't redistribute downloaded skins or commit them to the repo (same rule as the main brief).
- The NSFW flag only covers skins someone reviewed. Unreviewed skins (`nsfw == null`) can still be NSFW. If the app will ever be shown publicly, default the library to hide unreviewed skins too, or at least make that a setting.
- Schema may change. Treat the field list above as a snapshot and re-run the smoke test if anything breaks.

## Fallback: Internet Archive

If the Museum is unavailable, the Tooling section of the main brief still applies:

```bash
pip install internetarchive
ia download --search 'collection:winampskins' --glob '*.wsz' --destdir "$DEST" --checksum
```

Expect more duplicates, no NSFW flags, and no readme/metadata extraction; the indexer has to derive everything locally.
