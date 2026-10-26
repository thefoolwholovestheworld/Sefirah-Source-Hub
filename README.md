# Sefirah Source Hub

A web app (plain HTML/JS, no build step, no terminal) to find, import, convert, create and test Lua sources for the **Sefirah** KOReader plugin.

## Put it online for free (no terminal)
1. Create a GitHub account, then a public repository named `sefirah-source-hub`.
2. "Add file › Upload files": drag in the whole content of this folder (including `.github`) and commit.
3. Repository › Settings › Pages › Source: **GitHub Actions**. Your site will be at `https://<your-account>.github.io/sefirah-source-hub/`.
   Free GitHub Pages limits: public repository, ~1 GB site size, ~100 GB/month bandwidth (check the GitHub docs).
4. (To read other sites) Cloudflare › Workers & Pages › Create Worker › paste `proxy/worker.js` › Deploy. Free plan: ~100,000 requests/day (check Cloudflare's docs). Paste the Worker address in **Test › Proxy** (tab "Tester").

## What really works
- **Start**: a guided 4-step overview (choose the site, check the settings, test, install).
- **Catalogue**: 22 real Lua sources from your plugin (manifest `sources/manifest.json`), search/filters, view the code, download, copy the link. Status is "unverified" everywhere: no real test has been recorded yet.
- **Import**: a public GitHub repository, folder or file through the GitHub API (60 requests/hour without a token); language, license and duplicate detection; multi-import.
- **Convert**: Lua → checks the Sefirah contract, incompatible modules and the `metas` line; JS/Kotlin/Dart → partial analysis and pre-filling of "Create".
- **Create**: detection of link prefixes and the search form, manual mode, Lua generation (novel or manga), no AI. Each field has a hint, and a checklist (test, copy the file, add the `metas` line, restart KOReader) appears after generation.
- **Test**: 10 real checks (home page, search, details page, chapter order, reading, images, accents, empty pages, anti-bot blocking).

## To configure
- Cloudflare proxy (otherwise most sites fail because of CORS).

## Still to develop
- Automatic conversion of JS (LNReader) / Kotlin (Keiyoushi) sources: impossible in general, only information extraction exists.
- "Browse" filters, author/genres/status in generated sources.
- Community catalogue via Pull Request: add `sources/<id>.lua` + an entry in `manifest.json`.
- Optional AI analysis (not implemented; an API key would have to stay on the proxy side, never in the frontend).

## Licenses
Sources derived from Mythos (unitreign) remain under **GPL-3.0**; keep the headers.
