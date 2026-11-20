# Ginkgo

iPad-first reader for the user's own PDFs (later Word / Markdown): Apple Pencil annotations plus AI answers shown as
margin notes. Read `docs/product-brief.md` first; it records every product decision made so far and why.

## Working style

- The user writes in Chinese. Reply, and write issues and PR summaries, in Chinese. Code comments and commit messages
  stay in English.
- New ideas go in as GitHub issues first. The user asks for an evaluation before deciding, and only then says to
  implement. Don't start coding a newly recorded issue unasked.
- Per change: a branch, then "Commit and open PR", then "Merge it" (merge commit).
- In PR bodies use "Part of #N", not closing keywords, unless the issue should close.
- Outward-facing steps (publishing, App Store submission, repo visibility changes) need an explicit go-ahead each time.

## Key decisions (details in the brief)

- Reader only, no store. v1 is PDF only; no EPUB until there is demand.
- Annotation anchors sit behind a protocol, so reflowable formats can be added later.
- Custom-drawn annotations in the app; export falls back to standard PDF annotations.
- AI answers live in the margin, never in a chat window.
- AI code comes from SwipeSayKit (`../SwipeSay/Packages/SwipeSayKit`). Its App Group is hard-coded and has to
  become configurable before Ginkgo can use it.

## Assets

- App icon is drawn from source: `swift scripts/make-icon.swift <out.png>`.
- Signing team: UBS9FUBNFR.
