# Selling & Distributing iDownloader (GPLv3 playbook)

How to sell iDownloader for profit **without breaking the GPL**. Read [NOTICE.md](../NOTICE.md)
first. This is practical guidance, not legal advice.

## What GPLv3 allows

You may sell iDownloader, charge any price, rebrand it, run a business on it, and keep
selling forever. GPLv3 says "You may charge any price or no price for each copy" — free
software is about the buyers' freedom, not the price.

## The three obligations you can never skip

1. **License**: every buyer gets the GPLv3 rights — they may copy, modify, and even
   resell what they bought. You cannot forbid this in your terms of service or EULA.
2. **Corresponding source**: every released binary must have its complete source
   available at no charge. This repo is public and every release is tagged — point
   buyers at the matching tag. Include `LICENSE`, `NOTICE.md`, and
   `ios/THIRD-PARTY-NOTICES.md` in every download archive (the iOS app also ships them
   in-app under Settings → Licenses).
3. **No closed additions**: code you add to iDownloader (or link into it) becomes part
   of a GPLv3 work. You may sell services, updates, or hosting around it, but you cannot
   make the app itself proprietary.

## Distribution channels (iOS)

| Channel | OK? | Why |
|---|---|---|
| Direct sale of the signed IPA from your own site (Gumroad, Lemon Squeezy, Stripe, …) | ✅ | You control the terms; deliver the IPA + source link. Buyers install via Sideloadly, AltStore, or their own signing. |
| Free download + paid updates/support/subscription | ✅ | Common GPL-compatible model. The price pays for updates, support, or convenience. |
| Apple App Store | ❌ | Apple's developer terms restrict what GPL lets users do (re-distribution, modification). You cannot satisfy GPLv3 and those terms at once. |
| TestFlight | ❌ | Same Apple developer agreement as the App Store. |

Desktop (Windows/macOS/Linux) and Android builds have no such store conflict — any
channel works as long as the source link and license travel with the binary.

## Per-release checklist

1. Tag the release in git (`v5.1.1` etc.) — the tag **is** the corresponding source.
2. Build the IPA from that tag (commands in [ios/README.md](../ios/README.md)).
3. Publish: the IPA, the source link to the tag, `LICENSE` + `NOTICE.md` +
   `THIRD-PARTY-NOTICES.md`, and a statement on the sales page that the app is GPLv3.
4. Bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `ios/project.yml`.
5. Keep the repository public. A private repo breaks the source obligation for sold
   binaries.

## Sales page must say (one paragraph)

> iDownloader is free software licensed under the GNU GPL v3. You pay for the
> convenience of a ready-to-install build and for supporting development. You may
> freely copy and share it under the same license. Source code:
> https://github.com/SubhamSubhasisPatra/iDownloader

## Don'ts

- Don't distribute through the App Store/TestFlight (see table above).
- Don't remove the copyright notices in NOTICE.md or the GPLv3 license.
- Don't accept proprietary-only components into the app (e.g., a closed SDK that bans
  GPL'd distribution).
- Don't remove upstream's copyright notices or the GPLv3 license file.
