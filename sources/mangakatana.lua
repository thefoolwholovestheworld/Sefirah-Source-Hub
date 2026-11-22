-- Mangakatana — générée par Sefirah Source Hub, puis corrigée à la main (v0.4 : filtres genres inclure/exclure, mode ET/OU, statut, nb de chapitres, tri ; v0.3 : noms « [Cover] », fiche, chapitres parasites, couvertures avif, recherche). À tester sur liseuse.
-- Contrat : voir extensions/mangapill.lua du plugin Sefirah.
local logger = require("logger")
local T = require("core.i18n").T
local BASE   = "https://mangakatana.com"
local SEARCH = "https://mangakatana.com/?search={q}&search_by={search_by}&page={page}"
-- fiche = /manga/<slug>.<id> ; chapitre = /manga/<slug>.<id>/c<N> (même préfixe : le lien long est le chapitre)
local LISTP  = "/manga/"
local CHAPP  = "/manga/"
local CONT   = ""
local UA = "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36"

local function get(p)
    local url = p:match("^https?://") and p or (BASE .. p)
    local headers = { ["User-Agent"] = UA, ["Referer"] = BASE .. "/", ["Accept-Language"] = "en-US,en;q=0.9" }
    local lastcode
    -- 3 essais (délai plus long à chaque fois) : un raté réseau ponctuel ne doit pas afficher « Site injoignable »
    for attempt = 1, 3 do
        local ok, body, code = pcall(function()
            return require("core.net").get(url, { headers = headers, timeout = attempt == 1 and 15 or 30 })
        end)
        if not ok then
            code = body; body = nil
        end
        if body and #body > 2 then
            local low = #body < 1500 and body:lower() or ""
            if not (low:find("just a moment", 1, true) or low:find("attention required", 1, true)) then
                return body
            end
            code = "anti-bot"
        end
        lastcode = code
        logger.warn("Mangakatana: échec", url, tostring(code), "essai " .. attempt)
        local c = tonumber(code)
        if c == 404 or c == 410 or attempt == 3 then break end -- inutile de réessayer
        pcall(function() require("ffi/util").sleep(attempt) end)
    end
    return nil, tostring(lastcode)
end

-- ===== décodage des entités HTML (&#x27; &#39; &amp; &eacute; …) en une seule passe =====
local function cp2utf8(c)
    if not c or c <= 0 or c > 0x10FFFF then return nil end
    if c < 0x80 then return string.char(c) end
    if c < 0x800 then return string.char(0xC0 + math.floor(c / 64), 0x80 + c % 64) end
    if c < 0x10000 then return string.char(0xE0 + math.floor(c / 4096), 0x80 + math.floor(c / 64) % 64, 0x80 + c % 64) end
    return string.char(0xF0 + math.floor(c / 262144), 0x80 + math.floor(c / 4096) % 64, 0x80 + math.floor(c / 64) % 64, 0x80 + c % 64)
end
local ENT = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " ",
    rsquo = "’", lsquo = "‘", ldquo = "“", rdquo = "”", hellip = "…", ndash = "–", mdash = "—", laquo = "«", raquo = "»",
    eacute = "é", egrave = "è", ecirc = "ê", euml = "ë", agrave = "à", acirc = "â", ccedil = "ç", icirc = "î", iuml = "ï",
    ocirc = "ô", ugrave = "ù", ucirc = "û", uuml = "ü", oelig = "œ", Eacute = "É", Egrave = "È", Agrave = "À", Ccedil = "Ç" }
local function dec(s)
    if not s then return s end
    return (s:gsub("&(#?%w+);", function(e)
        local n = e:match("^#[xX](%x+)$")
        if n then return cp2utf8(tonumber(n, 16)) end
        n = e:match("^#(%d+)$")
        if n then return cp2utf8(tonumber(n)) end
        return ENT[e]
    end))
end
local function txt(h)
    h = (h or ""):gsub("<[^>]+>", " ")
    h = dec(h):gsub("%s+", " ")
    return (h:match("^%s*(.-)%s*$"))
end
local NL = string.char(10)
local function para(h) -- texte avec paragraphes (descriptions)
    h = (h or ""):gsub("<script.-</script>", ""):gsub("<style.-</style>", "")
    h = h:gsub("</p>", NL .. NL):gsub("<br%s*/?>", NL):gsub("<[^>]+>", "")
    h = dec(h):gsub(string.char(13), ""):gsub(" +", " ")
    h = h:gsub(" *" .. NL .. " *", NL):gsub(NL .. NL .. "+", NL .. NL)
    return (h:match("^%s*(.-)%s*$"))
end

local function attr(tag, n)
    local k = "%f[%w_%-]" .. n:gsub("%-", "%%-") .. "%s*=%s*"
    return tag:match(k .. '"([^"]*)"') or tag:match(k .. "'([^']*)'")
end
local function abs(u) if not u then return nil end if u:sub(1,2)=="//" then return "https:"..u end if u:sub(1,1)=="/" then return BASE..u end return u end
local function enc(s) return (tostring(s):gsub("([^%w%-%._~])", function(c) return string.format("%%%02X", c:byte()) end)) end
local function rel(h) return (h:gsub("^"..BASE:gsub("%p","%%%0"), "")) end
-- clé de comparaison d'un lien : sans domaine, sans ?query, sans # ni / final, en minuscules
local function norm(h)
    h = h:gsub("^https?://[^/]+", ""):gsub("[?#].*$", ""):gsub("/+$", "")
    return h:lower()
end
-- /_next/image?url=XXX&w=… (Next.js) -> l'image d'origine XXX
local function unnext(u)
    local q = u:match("/_next/image%?url=([^&]+)")
    if not q then return u end
    return (q:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end
-- adresse d'image inutilisable (img/None, null, undefined…)
local function bad_cover(u)
    local last = (u:gsub("[?#].*$", ""):match("([^/]*)$") or ""):lower()
    return last == "" or last == "none" or last == "null" or last == "undefined" or last == "nan" or last == "false"
end
-- KOReader ne sait pas lire l'avif (et le webp pas toujours) : le site fournit toujours un .jpg
local function jpg(u)
    if not u then return u end
    return (u:gsub("%.avif$", ".jpg"):gsub("%.webp$", ".jpg"))
end
local function cover_of(img)
    if not img then return nil end
    for _, k in ipairs({ "data-src", "data-lazy-src", "data-original", "src", "srcset" }) do
        local u = attr(img, k)
        if k == "srcset" and u then u = u:match("^%s*(%S+)") end
        if u and u ~= "" and not u:match("^data:") and not u:lower():find("placeholder", 1, true) and not u:lower():find("blank", 1, true) and not bad_cover(u) then
            return jpg(abs(unnext(dec(u))))
        end
    end
    return nil
end

-- contenu (équilibré) de la balise ouverte en position "from" : gère les <div> imbriquées
local function inner(html, from, tn)
    local open, close = "<" .. tn, "</" .. tn
    local depth, p = 1, from
    while true do
        local a = html:find(open, p, true)
        local b = html:find(close, p, true)
        if not b then return nil end
        if a and a < b then
            if not html:sub(a + #open, a + #open):match("%w") then depth = depth + 1 end
            p = a + #open
        else
            if not html:sub(b + #close, b + #close):match("%w") then
                depth = depth - 1
                if depth == 0 then return html:sub(from, b - 1) end
            end
            p = b + #close
        end
    end
end
-- premier élément (div, article, section…) dont la classe contient cls ; renvoie son contenu complet
local function grab(html, cls)
    local pos = 1
    while true do
        local s, e, tn, attrs = html:find("<(%a%w*)(%s[^>]*)>", pos)
        if not s then return nil end
        local c = attr(attrs, "class")
        if c and c:find(cls, 1, true) then
            local out = inner(html, e + 1, tn)
            if out and #out > 50 then return out end
        end
        pos = e + 1
    end
end

-- liste et chapitres sous le même préfixe (ex. /read/123/ et /read/123/p4.html) : l'œuvre est le lien court, le chapitre le lien long
local function after_list(h)
    local s, e = norm(h):find(LISTP:lower(), 1, true)
    if not s then return nil end
    return norm(h):sub(e + 1)
end
local function is_work(h)
    if LISTP == "" or not h:find(LISTP, 1, true) then return false end
    if CHAPP ~= "" and h:find(CHAPP, 1, true) then
        if CHAPP ~= LISTP then return false end
        local a = after_list(h)
        return a ~= nil and a ~= "" and not a:find("/", 1, true)
    end
    return true
end
local function is_chap(h)
    if CHAPP == "" or not h:find(CHAPP, 1, true) then return false end
    if CHAPP == LISTP then
        local a = after_list(h)
        return a ~= nil and a:find("/", 1, true) ~= nil
    end
    return true
end

local function parse_list(html)
    -- on ne garde que la liste principale (#book_list) : pas les « Hot updates » ni la colonne de droite
    local bs, be = html:find('id="book_list"', 1, true)
    if bs then
        local gt = html:find(">", be, true)
        local blk = gt and inner(html, gt + 1, "div")
        if blk and #blk > 50 then html = blk end
    end
    local out, idx = {}, {}
    for tag, inner_html in html:gmatch("(<a%s[^>]->)(.-)</a>") do
        local href = attr(tag, "href")
        if href and is_work(href) then
            local k = norm(href)
            local img = inner_html:match("<img[^>]->")
            local title = attr(tag, "title")
            if title == "" then title = nil end
            -- le lien de la couverture a pour alt « [Cover] » : ce n'est pas un titre
            local alt = img and attr(img, "alt")
            if alt and (alt == "" or alt:lower():find("cover", 1, true)) then alt = nil end
            local name = title and dec(title) or txt(inner_html)
            if name == "" and alt then name = dec(alt) end
            -- un alt d'image se termine souvent par « 封面 » (couverture) : on l'enlève
            if not title then name = name:gsub("封面$", ""):gsub("%s+$", "") end
            local cover = cover_of(img)
            local it = idx[k]
            if it then -- même œuvre déjà vue (autre lien, autre forme d'URL) : on complète seulement
                if title and not it.titled then it.name = dec(title); it.titled = true end
                if it.name == "" and name ~= "" then it.name = name end
                if not it.cover and cover then it.cover = cover end
            else
                it = { name = name, path = rel(href), cover = cover, titled = title ~= nil }
                idx[k] = it
                out[#out+1] = it
            end
        end
    end
    local res = {}
    for _, it in ipairs(out) do if it.name ~= "" then res[#res+1] = it end end
    -- couvertures manquantes (liste sans image, image invalide) : og:image de la fiche, 8 au maximum pour rester rapide
    local budget = 8
    for _, it in ipairs(res) do
        if not it.cover and budget > 0 then
            budget = budget - 1
            local ok, page = pcall(get, it.path)
            if not (ok and page) then budget = 0 end -- réseau en panne : on n'enchaîne pas d'autres attentes
            if ok and page then
                local og = page:match('property="og:image"[^>]-content="([^"]*)"') or page:match('content="([^"]*)"[^>]-property="og:image"')
                if og and og ~= "" and not bad_cover(og) then it.cover = jpg(abs(dec(og))) end
            end
        end
    end
    return res
end

-- ===== FILTRES : l'adresse de la liste est construite à partir des choix de l'utilisateur =====
-- Une valeur vide ou « all » = pas de filtre : le paramètre est retiré de l'adresse.
-- liste : /manga (ou /genre/<genre>), puis /page/N ; l'adresse est construite dans browse_url
local BROWSE = "https://mangakatana.com/manga/page/{page}"
local FJOIN  = {  }

local GENRES = {
    { "4-koma", "4 koma" },
    { "action", "Action" },
    { "adult", "Adult" },
    { "adventure", "Adventure" },
    { "artbook", "Artbook" },
    { "award-winning", "Award winning" },
    { "comedy", "Comedy" },
    { "cooking", "Cooking" },
    { "doujinshi", "Doujinshi" },
    { "drama", "Drama" },
    { "ecchi", "Ecchi" },
    { "erotica", "Erotica" },
    { "fantasy", "Fantasy" },
    { "gender-bender", "Gender Bender" },
    { "gore", "Gore" },
    { "harem", "Harem" },
    { "historical", "Historical" },
    { "horror", "Horror" },
    { "isekai", "Isekai" },
    { "josei", "Josei" },
    { "loli", "Loli" },
    { "manhua", "Manhua" },
    { "manhwa", "Manhwa" },
    { "martial-arts", "Martial Arts" },
    { "mecha", "Mecha" },
    { "medical", "Medical" },
    { "music", "Music" },
    { "mystery", "Mystery" },
    { "one-shot", "One shot" },
    { "overpowered-mc", "Overpowered MC" },
    { "psychological", "Psychological" },
    { "reincarnation", "Reincarnation" },
    { "romance", "Romance" },
    { "school-life", "School Life" },
    { "sci-fi", "Sci-fi" },
    { "seinen", "Seinen" },
    { "sexual-violence", "Sexual violence" },
    { "shota", "Shota" },
    { "shoujo", "Shoujo" },
    { "shoujo-ai", "Shoujo Ai" },
    { "shounen", "Shounen" },
    { "shounen-ai", "Shounen Ai" },
    { "slice-of-life", "Slice of Life" },
    { "sports", "Sports" },
    { "super-power", "Super power" },
    { "supernatural", "Supernatural" },
    { "survival", "Survival" },
    { "time-travel", "Time Travel" },
    { "tragedy", "Tragedy" },
    { "webtoon", "Webtoon" },
    { "yaoi", "Yaoi" },
    { "yuri", "Yuri" },
}
local function genre_options()
    local o = { { id = "all", label = "Tous" } }
    for _, g in ipairs(GENRES) do o[#o + 1] = { id = g[1], label = g[2] } end
    return o
end

local POPULAR_FILTERS = {
    { key = "genre", label = "Genres (inclure)", default = "all", multi = true, options = genre_options() },
    { key = "exclude", label = "Genres (exclure)", default = "all", multi = true, options = genre_options() },
    { key = "include_mode", label = "Mode d'inclusion", default = "and", multi = false,
      options = {
        { id = "and", label = "ET (tous les genres choisis)" },
        { id = "or", label = "OU (au moins un genre)" },
      } },
    { key = "status", label = "Statut", default = "all", multi = false,
      options = {
        { id = "all", label = "Tous" },
        { id = "1", label = "En cours" },
        { id = "2", label = "Terminé" },
        { id = "0", label = "Annulé" },
      } },
    { key = "chapters", label = "Nombre de chapitres", default = "all", multi = false,
      options = {
        { id = "all", label = "Tous" },
        { id = "e1", label = "=1 (one-shot)" },
        { id = "5", label = "5+" },
        { id = "10", label = "10+" },
        { id = "20", label = "20+" },
        { id = "30", label = "30+" },
        { id = "50", label = "50+" },
        { id = "100", label = "100+" },
        { id = "150", label = "150+" },
        { id = "200", label = "200+" },
      } },
    { key = "order", label = "Trier par", default = "all", multi = false,
      options = {
        { id = "all", label = "Par défaut" },
        { id = "latest", label = "Dernière mise à jour" },
        { id = "new", label = "Nouveautés" },
        { id = "az", label = "A-Z" },
        { id = "numc", label = "Nombre de chapitres" },
      } },
}

local SEARCH_FILTERS = {
    { key = "search_by", label = "Search by", default = "m_name", multi = false,
      options = {
        { id = "all", label = "Tous" },
        { id = "m_name", label = "Manga Name" },
        { id = "author", label = "Author" },
      } },
}

local function split(s, sep)
    local t, i = {}, 1
    while true do
        local a = s:find(sep, i, true)
        if not a then t[#t + 1] = s:sub(i); break end
        t[#t + 1] = s:sub(i, a - 1)
        i = a + 1
    end
    return t
end
-- valeur choisie pour un filtre (nil si vide ou « all »)
local function fval(sel, key)
    local v = sel and sel[key]
    if v == nil or v == "" or v == "all" then return nil end
    return tostring(v)
end
-- remplace {genre}, {page}, {q}… dans une adresse ; retire ce qui dépend d'un filtre vide
local function expand(tpl, sel, term, page)
    tpl = tpl:gsub("#.*$", "")
    local origin, rest = tpl:match("^(https?://[^/?]+)(.*)$")
    if not origin then origin, rest = "", tpl end
    local path, query = rest:match("^([^?]*)%??(.*)$")
    local function sub(s)
        local ok = true
        local r = s:gsub("{([%w_%-]+)}", function(k)
            if k == "page" then return tostring(page or 1) end
            if k == "q" then return enc(term or "") end
            local v = fval(sel, k)
            if not v then ok = false; return "" end
            local t = {}
            for x in v:gmatch("[^,]+") do t[#t + 1] = enc(x) end
            return table.concat(t, ",")
        end)
        return r, ok
    end
    local segs = {}
    for _, seg in ipairs(split(path, "/")) do
        local r, ok = sub(seg)
        if ok then segs[#segs + 1] = r end
    end
    local out = origin .. table.concat(segs, "/")
    local ps = {}
    if query ~= "" then
        for _, p in ipairs(split(query, "&")) do
            local name, key = p:match("^([^=]*)={([%w_%-]+)}$")
            local v = (key and key ~= "page" and key ~= "q") and fval(sel, key) or nil
            if v and FJOIN[key] == "rep" and v:find(",", 1, true) then
                for x in v:gmatch("[^,]+") do ps[#ps + 1] = name .. "=" .. enc(x) end
            else
                local r, ok = sub(p)
                if ok then ps[#ps + 1] = r end
            end
        end
    end
    if #ps > 0 then out = out .. "?" .. table.concat(ps, "&") end
    return out
end
-- « a,b,,all » -> { "a", "b" } (sans doublons, sans « all », sans les valeurs de skip)
local function genre_list(v, skip)
    local t, seen = {}, {}
    for raw in (v or ""):gmatch("[^,]+") do
        local x = raw:match("^%s*(.-)%s*$")
        if x ~= "" and x ~= "all" and not seen[x] and not (skip and skip[x]) then
            seen[x] = true; t[#t + 1] = x
        end
    end
    return t
end
local function join_enc(t)
    local o = {}
    for i, x in ipairs(t) do o[i] = enc(x) end
    return table.concat(o, "_")
end
-- liste : /manga[/page/N][?filter=1&include=a_b&exclude=c&include_mode=or&status=1&chapters=10&order=az]
-- cas simple (0 ou 1 genre, aucun autre filtre) : /manga ou /genre/<genre>, comme avant
local function browse_url(page, options)
    local sel = (options and options.filters) or {}
    page = tonumber(page) or 1
    local inc = genre_list(fval(sel, "genre"))
    local skip = {}
    for _, x in ipairs(inc) do skip[x] = true end
    local exc = genre_list(fval(sel, "exclude"), skip)
    local status, chapters, order, mode = fval(sel, "status"), fval(sel, "chapters"), fval(sel, "order"), fval(sel, "include_mode")
    local pg = page > 1 and ("/page/" .. page) or ""
    if #exc == 0 and not status and not chapters and not order and #inc <= 1 then
        return BASE .. (#inc == 1 and ("/genre/" .. enc(inc[1])) or "/manga") .. pg
    end
    local q = { "filter=1" }
    if #inc > 0 then
        q[#q + 1] = "include=" .. join_enc(inc)
        if #inc > 1 then q[#q + 1] = "include_mode=" .. ((mode == "or") and "or" or "and") end
    end
    if #exc > 0 then q[#q + 1] = "exclude=" .. join_enc(exc) end
    if chapters then q[#q + 1] = "chapters=" .. enc(chapters) end
    if order then q[#q + 1] = "order=" .. enc(order) end
    if status then q[#q + 1] = "status=" .. enc(status) end
    return BASE .. "/manga" .. pg .. "?" .. table.concat(q, "&")
end

local ext = { id = "mangakatana", name = "Mangakatana", site = BASE, lang = "en", version = "0.5.0",
    type = "manga", review_cache_rev = 1, maxReviews = 150,
    popularFilters = POPULAR_FILTERS, searchFilters = SEARCH_FILTERS, hasReviews = true, chapterCommentsPanel = false }

-- fiche d'une œuvre (doit être défini avant searchNovels)
local function meta(html, path)
    local t = html:match("<h1[^>]*>(.-)</h1>")
    local name = t and txt(t) or ""
    if name == "" then name = dec(html:match('property="og:title"[^>]-content="([^"]*)"') or "") end
    if name == "" then name = path end
    local function ogp(p) return dec(html:match('property="' .. p .. '"[^>]-content="([^"]*)"') or html:match('content="([^"]*)"[^>]-property="' .. p .. '"') or "") end
    -- description : <div class="summary"><div class="label">Description</div><p>…</p></div>
    local summary
    local sm = html:match('<div class="summary">.-<p>(.-)</p>')
    if sm then summary = para(sm) end
    if not summary or summary == "" then
        summary = (ogp("og:description"):gsub("^Summary:%s*", ""))
    end
    -- couverture : l'og:image est en avif, on prend le <img> jpg de la fiche
    local cv = html:match('<div class="cover">.-<img[^>]-src="([^"]+)"')
    if not cv or bad_cover(cv) then cv = html:match('property="og:image"[^>]-content="([^"]*)"') end
    cv = cv and jpg(abs(dec(cv))) or nil
    if cv and bad_cover(cv) then cv = nil end
    -- auteur(s), statut, genres
    local aus = {}
    for a in html:gmatch('<a%s[^>]-class="author"[^>]*>(.-)</a>') do
        local x = txt(a)
        if x ~= "" then aus[#aus + 1] = x end
    end
    local st = html:match('class="[^"]*value status[^"]*"[^>]*>(.-)</div>')
    local gb = html:match('<div class="genres">(.-)</div>')
    local genres = {}
    if gb then for g in gb:gmatch("<a[^>]*>(.-)</a>") do local x = txt(g); if x ~= "" then genres[#genres + 1] = x end end end
    return { name = name, path = path, cover = cv, summary = summary,
        author = table.concat(aus, ", "), status = st and txt(st) or "", genres = genres }
end

function ext:popularNovels(page, options)
    local html, err = get(browse_url(page, options))
    if not html then return { novels = {}, error = T("Site injoignable (") .. tostring(err) .. ")" } end
    return { novels = parse_list(html) }
end

function ext:searchNovels(term, page, options)
    term = tostring(term or ""):match("^%s*(.-)%s*$")
    if term == "" then return ext:popularNovels(page, options) end
    page = tonumber(page) or 1
    local sb = fval(options and options.filters, "search_by")
    local url = BASE .. (page > 1 and ("/page/" .. page) or "/") .. "?search=" .. enc(term) .. (sb and ("&search_by=" .. enc(sb)) or "")
    local html, err = get(url)
    if not html then return { novels = {}, error = T("Recherche impossible (") .. tostring(err) .. ")" } end
    -- un seul résultat : le site redirige directement vers la fiche de l'œuvre
    if html:find('id="single_book"', 1, true) then
        local cu = html:match('<link rel="canonical" href="([^"]*)"') or html:match('property="og:url"[^>]-content="([^"]*)"')
        if cu and cu:find("/manga/", 1, true) then
            local p = rel(cu)
            local m = meta(html, p)
            return { novels = { { name = m.name, path = p, cover = m.cover } } }
        end
        return { novels = {} }
    end
    return { novels = parse_list(html) }
end

function ext:parseNovelMeta(path)
    local html = get(path); if not html then return nil end
    local m = meta(html, path); m.total_chapters = 0; return m
end

function ext:parseNovel(path)
    local html = get(path); if not html then return nil end
    local m, ch, seen = meta(html, path), {}, {}
    local base = norm(path)
    -- uniquement le tableau des chapitres de CETTE œuvre (pas « Similar Series », « First Chapter », « Read offline »…)
    local blk = html:match('<div class="chapters">(.-)</tbody>') or html
    for tag, inner_html in blk:gmatch("(<a%s[^>]->)(.-)</a>") do
        local href = attr(tag, "href")
        if href then
            local k = norm(href)
            if k:sub(1, #base + 2) == base .. "/c" and k:sub(#base + 3, #base + 3):match("%d") then
                local name = txt(inner_html)
                if name == "" then name = dec(attr(tag, "title") or "") end
                if not seen[k] then
                    if name == "" then name = "Chapitre " .. (#ch + 1) end
                    seen[k] = { name = name, path = rel(href) }
                    ch[#ch + 1] = seen[k]
                end
            end
        end
    end
    -- le site liste du plus récent au plus ancien : on inverse (ordre de lecture)
    for i = 1, math.floor(#ch / 2) do ch[i], ch[#ch + 1 - i] = ch[#ch + 1 - i], ch[i] end
    for i, c in ipairs(ch) do c.chapter_number = i end
    m.chapters, m.totalPages = ch, 1
    return m
end

-- pages d'un chapitre : tableau JS « var xxx=['https://i1.mangakatana.com/token/….jpg', …] » (on prend le plus long)
local IMG = { jpg = true, jpeg = true, png = true, webp = true, gif = true, avif = true }
local function collect_images(html)
    local images, seen = {}, {}
    local best, bestn = nil, 0
    for body in html:gmatch("=%s*%[(%s*['\"]https?://[^%]]-)%]") do
        local list = {}
        for _, u in body:gmatch("(['\"])(https?://[^'\"]+)%1") do
            local e = u:gsub("[?#].*$", ""):match("%.(%a+)$")
            if e and IMG[e:lower()] then list[#list + 1] = u end
        end
        if #list > bestn then best, bestn = list, #list end
    end
    if best then
        for _, u in ipairs(best) do
            if not seen[u] then seen[u] = true; images[#images + 1] = u end
        end
    end
    return images
end

function ext:parseChapterImages(path)
    local html = get(path); if not html then return nil, "chapter_unreachable" end
    local images = collect_images(html)
    -- repli : serveurs 2 et 3 du site
    if #images == 0 then
        for _, sv in ipairs({ "?sv=mk", "?sv=3" }) do
            local h = get(path .. sv)
            if h then images = collect_images(h) end
            if #images > 0 then break end
        end
    end
    if #images == 0 then return nil, "no_pages" end
    return { images = images, headers = { ["User-Agent"] = UA, ["Referer"] = BASE .. "/" } }
end

function ext:parseChapter(path) return "<p>Ce chapitre est un manga : il s'ouvre dans le lecteur d'images.</p>" end

-- ===== AVIS = commentaires de la fiche =====
-- comments.min.js : POST https://mangakatana.com/ comment_data=&page_id=<id>
-- -> JSON { comments = { <clé> = {uid,name,ava,msg,up,down,time,parent,status} } }
-- Tous les commentaires sont récupérés d'un coup : pagination locale de 10 éléments.
local REVIEWS_PER_PAGE = 10
local review_memo = { path = nil, t = 0, items = nil }

local function post_form(url, body)
    local headers = {
        ["User-Agent"] = UA,
        ["Referer"] = BASE .. "/",
        ["Accept-Language"] = "en-US,en;q=0.9",
        ["Accept"] = "application/json, text/javascript, */*; q=0.01",
        ["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8",
        ["Content-Length"] = tostring(#body),
        ["X-Requested-With"] = "XMLHttpRequest",
    }
    local ok_m, ltn12 = pcall(require, "ltn12")
    local ok_h, https = pcall(require, "ssl.https")
    if not (ok_m and ok_h) then return nil, "modules_http_indisponibles" end

    local ok_s, socketutil = pcall(require, "socketutil")
    if ok_s and socketutil then pcall(function() socketutil:set_timeout(15, 40) end) end
    local chunks = {}
    local ok, result, code = pcall(https.request, {
        url = url,
        method = "POST",
        headers = headers,
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(chunks),
    })
    if ok_s and socketutil then pcall(function() socketutil:reset_timeout() end) end
    if not ok or not result then
        return nil, tostring(ok and code or result)
    end
    if tonumber(code) and tonumber(code) ~= 200 then
        return nil, "HTTP " .. tostring(code)
    end
    return table.concat(chunks), code
end

local function jdecode(s)
    local ok_j, JSON = pcall(require, "rapidjson")
    if not ok_j then ok_j, JSON = pcall(require, "json") end
    if not ok_j or type(JSON) ~= "table" or type(JSON.decode) ~= "function" then return nil end
    local ok, data = pcall(JSON.decode, s)
    if ok and type(data) == "table" then return data end
    return nil
end

local function sstr(v)
    if type(v) == "string" and v ~= "" then return v end
    if type(v) == "number" then return tostring(v) end
    return nil
end

local function load_comments(path)
    local now = os.time()
    if review_memo.path == path and review_memo.items and now - review_memo.t < 120 then
        return review_memo.items
    end

    local clean = tostring(path or ""):gsub("[?#].*$", "")
    local id = clean:match("%.(%d+)/?$")
    if not id then
        logger.warn("Mangakatana: impossible d'extraire l'id de la fiche", tostring(path))
        return nil, "id_introuvable"
    end

    local raw, err = post_form(BASE .. "/", "comment_data=&page_id=" .. id)
    if not raw or raw:sub(1, 1) ~= "{" then
        logger.warn("Mangakatana: avis indisponibles", tostring(path), tostring(err))
        return nil, tostring(err or "reponse_invalide")
    end

    local data = jdecode(raw)
    if type(data) ~= "table" or type(data.comments) ~= "table" then
        logger.warn("Mangakatana: réponse JSON des commentaires invalide", tostring(path))
        return nil, "json_invalide"
    end

    local items, byid = {}, {}
    for key, c in pairs(data.comments) do
        -- status absent ou 1 = visible ; les autres statuts sont masqués/supprimés.
        if type(c) == "table" and (c.status == nil or tostring(c.status) == "1") then
            local up = tonumber(c.up) or 0
            local down = tonumber(c.down) or 0
            local tm = tonumber(c.time) or 0
            local uid = sstr(c.uid)
            local msg = type(c.msg) == "string" and c.msg or ""
            msg = msg:gsub("<spoiler[^>]*>", "[spoiler : "):gsub("</spoiler>", "]")
            msg = msg:gsub("<img[^>]->", " [image] ")
            local content = para(msg)
            local parent = sstr(c.parent)
            if parent == "0" then parent = nil end
            local ava = sstr(c.ava)
            if content ~= "" then
                local it = {
                    id = tostring(key),
                    parent_id = parent,
                    author = sstr(c.name) or (uid and ("User-" .. uid)) or "Anonyme",
                    content = content,
                    likes = up,
                    dislikes = down,
                    avatar = ava and ("https://i1.wp.com/i.postimg.cc/" .. ava .. "/a.png?fit=100,100") or nil,
                    date = tm > 0 and os.date("!%Y-%m-%dT%H:%M:%SZ", tm) or nil,
                    _t = tm,
                    _v = up - down,
                }
                items[#items + 1] = it
                byid[it.id] = it
            end
        end
    end

    -- Comme sur le site, une réponse dont le parent est absent n'est pas affichée.
    local kept = {}
    for _, it in ipairs(items) do
        if not it.parent_id or byid[it.parent_id] then
            kept[#kept + 1] = it
        end
    end
    review_memo = { path = path, t = now, items = kept }
    return kept
end

-- Trie les discussions racines et garde chaque réponse sous son commentaire parent.
local function flatten(items, sort)
    local roots, kids = {}, {}
    for _, it in ipairs(items) do
        if it.parent_id then
            kids[it.parent_id] = kids[it.parent_id] or {}
            table.insert(kids[it.parent_id], it)
        else
            roots[#roots + 1] = it
        end
    end

    local function cmp(a, b)
        if sort == "oldest" then
            if a._t ~= b._t then return a._t < b._t end
        elseif sort == "mostliked" then
            if a._v ~= b._v then return a._v > b._v end
            if a._t ~= b._t then return a._t > b._t end
        else
            if a._t ~= b._t then return a._t > b._t end
        end
        return a.id < b.id
    end
    table.sort(roots, cmp)

    local out, visited = {}, {}
    local function add(it)
        if visited[it.id] then return end -- protège aussi contre une boucle de réponses
        visited[it.id] = true
        out[#out + 1] = it
        local children = kids[it.id]
        if children then
            table.sort(children, function(a, b)
                if a._t ~= b._t then return a._t < b._t end
                return a.id < b.id
            end)
            for _, child in ipairs(children) do add(child) end
        end
    end
    for _, root in ipairs(roots) do add(root) end
    return out
end

function ext:parseReviews(path, page, sort)
    page = math.max(1, math.floor(tonumber(page) or 1))
    local items = load_comments(path)
    if not items then return { reviews = {}, has_more = false } end

    local flat = flatten(items, sort)
    local first = (page - 1) * REVIEWS_PER_PAGE
    local out = {}
    for i = first + 1, math.min(#flat, first + REVIEWS_PER_PAGE) do
        local it = flat[i]
        out[#out + 1] = {
            id = it.id,
            parent_id = it.parent_id,
            author = it.author,
            rating = nil,
            content = it.content,
            likes = it.likes,
            dislikes = it.dislikes,
            avatar = it.avatar,
            date = it.date,
        }
    end
    return { reviews = out, has_more = (first + REVIEWS_PER_PAGE) < #flat }
end

return ext