# Sefirah Source Hub

A web app to **create, test and share Lua sources** for [Sefirah](https://github.com/thefoolwholovestheworld/sefirah.koplugin), a KOReader plugin for reading web novels and manga on e-readers.

**Live site:** https://thefoolwholovestheworld.github.io/Sefirah-Source-Hub/

No build step, no terminal, no install: the whole app is one `index.html` file.

---

## Features

### Create a source from a URL
Paste the address of a site. The Hub reads the home page, a work page and a chapter page, guesses the settings, generates a `.lua` file and tests it.

Guessed settings include work links, chapter links, text or image container, chapter order, search URL and filters.

### Make generation more reliable
- **Several example pages.** Provide 1 to 3 work pages and 1 to 3 chapter pages. The Hub compares them and keeps only what repeats every time.
- **`.mhtml` import or pasted HTML.** For sites behind Cloudflare, save the page in your browser (`Ctrl+S` → "Webpage, single file") and import it.
- **Engine detection.** Recognizes common setups (Madara/WordPress, Next.js, WordPress REST API) and applies a proven template.
- **Hidden API detection.** Before parsing HTML, looks for JSON-LD, RSS/Atom feeds, WordPress REST routes, sitemaps and common JSON APIs.
- **Auto-repair.** When a test fails, the AI receives the real pages, the generated code and the error, proposes new settings, and the Hub retests. Up to 3 attempts.
- **Preview.** See how a source will look before using it.

### Browse the catalogue
Search ready-made sources and filter by language, type (novel or manga) and status (tested or unverified). Each source can be viewed, downloaded, or shared as a link.

### Send a source to your e-reader
After a successful test, the Hub shows a **4-digit code**, valid for 10 minutes and single use. On the e-reader, open Sefirah › Sources, tap the antenna icon and enter the code. No cable and no restart needed.

---

## Using a source

There are three ways to get a source into Sefirah:

1. **From the catalogue, on the e-reader.** Sefirah reads this site's `sources/manifest.json` and downloads sources on demand from its Sources tab.
2. **With a code.** Generate a source here and send it with the 4-digit code (see above).
3. **By hand.** Download the `<id>.lua` file and copy it into:
   ```
   koreader/plugins/sefirah.koplugin/extensions/
   ```
   Restart KOReader, then open Sefirah › Sources and install the source.

For manual installation, the file name must match the `id` declared inside the file (letters, digits, `_` and `-` only), otherwise the source is ignored. No other file needs editing: recent versions of Sefirah detect new files in `extensions/` automatically.

> Older plugin versions required adding an entry to the `metas` table in `core/extmgr.lua`. If a dropped source does not appear, update the plugin first.

---

## Repository layout

```
index.html             The whole app (interface and logic)
sources/manifest.json  Catalogue of available sources
sources/*.lua          Source files listed in the catalogue
proxy/worker.js        Cloudflare Worker (page proxy, AI endpoint, e-reader relay)
```

## Run it

**GitHub Pages:** Settings › Pages › Deploy from a branch › `main` / `(root)`.

**Locally:** serve the folder with a static server, for example `python -m http.server`, and open it in your browser. Opening `index.html` straight from disk will not load the catalogue.

## Disclaimer

Sefirah Source Hub **does not host, store or distribute copyrighted content.** It only generates code that reads publicly available web pages.

You are responsible for checking the terms of use and licence of every site you create a source for, and for complying with the laws that apply to you. Generated sources are provided as is and may stop working at any time. Please support authors and official publishers when you can.

## Contributing

Issues and pull requests are welcome, especially new tested sources and fixes for existing ones. When adding a source, include the site address, language, type (novel or manga) and the date you last tested it.

## Related projects

- [Sefirah](https://github.com/thefoolwholovestheworld/sefirah.koplugin): the KOReader plugin these sources are made for.
- [KOReader](https://github.com/koreader/koreader): the e-reader application.

## License

Add a `LICENSE` file to this repository and name it here. The Sefirah plugin itself is under GPL-3.0; choose the licence for the Hub separately.
