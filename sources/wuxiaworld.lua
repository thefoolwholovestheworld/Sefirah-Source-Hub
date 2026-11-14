-- wuxiaworld.site — source générée par Sefirah Source Hub (modèle sans IA). À relire et tester.
-- Contrat : voir extensions/mangapill.lua du plugin Sefirah.
local logger = require("logger")
local BASE   = "https://wuxiaworld.site"
local SEARCH = "https://wuxiaworld.site/?s={q}&post_type=wp-manga"
local LISTP  = "/novel/"
local CHAPP  = "/chapter-"
local CONT   = "reading-content"
local UA = "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36"

local function get(p)
    local url = p:match("^https?://") and p or (BASE .. p)
    local body, code = require("core.net").get(url, { headers = { ["User-Agent"] = UA, ["Referer"] = BASE .. "/" }, timeout = 15 })
    if body and #body > 2 then return body end
    logger.warn("wuxiaworld.site: échec", url, tostring(code))
    return nil, tostring(code)
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
    return last == "" or last:sub(-1) == "." or last == "none" or last == "null" or last == "undefined" or last == "nan" or last == "false"
end
local function cover_of(img)
    if not img then return nil end
    for _, k in ipairs({ "data-src", "data-lazy-src", "data-original", "src", "srcset" }) do
        local u = attr(img, k)
        if k == "srcset" and u then u = u:match("^%s*(%S+)") end
        if u and u ~= "" and not u:match("^data:") and not u:lower():find("placeholder", 1, true) and not u:lower():find("dflazy", 1, true) and not u:lower():find("blank", 1, true) and not bad_cover(u) then
            return abs(unnext(dec(u)))
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
-- Madara : œuvre = /novel/<slug>/ ; tout ce qui est plus profond (/chapter-12/, /3865/) est un chapitre
local function is_work(h)
    return norm(h):match("^/novel/[^/]+$") ~= nil
end
local function is_chap(h)
    return norm(h):match("^/novel/[^/]+/.+") ~= nil
end

local function parse_list(html)
    local out, idx = {}, {}
    for tag, inner_html in html:gmatch("(<a%s[^>]->)(.-)</a>") do
        local href = attr(tag, "href")
        if href and is_work(href) then
            local k = norm(href)
            local img = inner_html:match("<img[^>]->")
            local title = attr(tag, "title")
            if title == "" then title = nil end
            local name = title or (img and attr(img, "alt"))
            if name and name ~= "" then name = dec(name) else name = txt(inner_html) end
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
            if ok and page then
                local og = page:match('property="og:image"[^>]-content="([^"]*)"') or page:match('content="([^"]*)"[^>]-property="og:image"')
                if og and og ~= "" and not bad_cover(og) then it.cover = abs(dec(og)) end
            end
        end
    end
    return res
end

-- v0.3.0 : réglé d'après le vrai HTML du site (liens /novel/<slug>/ sans faux « œuvres », chapitres en AJAX, texte dans .text-left).
-- ===== FILTRES : l'adresse de la liste est construite à partir des choix de l'utilisateur =====
-- Une valeur vide ou « all » = pas de filtre : le paramètre est retiré de l'adresse.
local BROWSE = ""
local FJOIN  = {  }

local POPULAR_FILTERS = {
    { key = "orderby", label = "Tri", default = "latest", multi = false,
      options = {
        { id = "latest", label = "Dernières sorties" },
        { id = "views", label = "Les plus lus" },
        { id = "trending", label = "Tendance" },
        { id = "rating", label = "Mieux notés" },
        { id = "new-manga", label = "Nouveautés" },
        { id = "alphabet", label = "A → Z" },
      } },
    { key = "tag", label = "Type", default = "all", multi = false,
      options = {
        { id = "all", label = "Tous" },
        { id = "chinese", label = "Chinois" },
        { id = "japanese", label = "Japonais" },
        { id = "korean-novels", label = "Coréen" },
        { id = "completed", label = "Terminés" },
      } },
    { key = "genre", label = "Genre", default = "all", multi = false,
      options = {
        { id = "all", label = "Tous" },
        { id = "action", label = "Action" },
        { id = "adventure", label = "Adventure" },
        { id = "comedy", label = "Comedy" },
        { id = "drama", label = "Drama" },
        { id = "ecchi", label = "Ecchi" },
        { id = "fantasy", label = "Fantasy" },
        { id = "harems-novel", label = "Harem" },
        { id = "josei", label = "Josei" },
        { id = "martial-arts-genre", label = "Martial Arts" },
        { id = "gender-bender", label = "Gender Bender" },
        { id = "historical", label = "Historical" },
        { id = "horror", label = "Horror" },
        { id = "mature", label = "Mature" },
        { id = "mecha", label = "Mecha" },
        { id = "mystery", label = "Mystery" },
        { id = "psychological", label = "Psychological" },
        { id = "romance", label = "Romance" },
        { id = "school-life", label = "School Life" },
        { id = "sci-fi", label = "Sci-fi" },
        { id = "seinen", label = "Seinen" },
        { id = "shoujo", label = "Shoujo" },
        { id = "shounen", label = "Shounen" },
        { id = "slice-of-life", label = "Slice of Life" },
        { id = "sports", label = "Sports" },
        { id = "supernatural", label = "Supernatural" },
        { id = "tragedy", label = "Tragedy" },
        { id = "video-games", label = "Video Games" },
        { id = "wuxia", label = "Wuxia" },
        { id = "xianxia", label = "Xianxia" },
        { id = "xuanhuan", label = "Xuanhuan" },
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
local function browse_url(page, options)
    if BROWSE == "" then return BASE .. "/" end
    local sel = {}
    for k, v in pairs((options and options.filters) or {}) do sel[k] = v end
    -- aucun choix de l'utilisateur : valeurs par défaut des filtres (sinon /sort/{genre}/ perdrait son genre)
    for _, f in ipairs(POPULAR_FILTERS) do
        if sel[f.key] == nil or sel[f.key] == "" then sel[f.key] = f.default end
    end
    return expand(BROWSE, sel, "", page)
end

local ext = { id = "wuxiaworld", name = "WuxiaWorld.site", site = BASE, lang = "en", version = "0.4.0",
    popularFilters = POPULAR_FILTERS, searchFilters = {}, hasReviews = true, maxReviews = 150, chapterCommentsPanel = false }

function ext:popularNovels(page, options)
    local html, err = get(browse_url(page, options))
    if not html then return { novels = {}, error = "Site injoignable (" .. tostring(err) .. ")" } end
    return { novels = parse_list(html) }
end

function ext:searchNovels(term, page, options)
    term = tostring(term or ""):match("^%s*(.-)%s*$")
    if term == "" then return ext:popularNovels(page, options) end
    local url = expand(SEARCH, options and options.filters, term, page)
    local html, err = get(url)
    if not html then return { novels = {}, error = "Recherche impossible (" .. tostring(err) .. ")" } end
    return { novels = parse_list(html) }
end

local function meta(html, path)
    local t = html:match("<h1[^>]*>(.-)</h1>")
    local name = t and txt(t) or ""
    if name == "" then name = dec(html:match('property="og:title"[^>]-content="([^"]*)"') or "") end
    if name == "" then name = path end
    local og = html:match('property="og:description"[^>]-content="([^"]*)"')
        or html:match('content="([^"]*)"[^>]-property="og:description"')
        or html:match('name="description"[^>]-content="([^"]*)"') or ""
    og = dec(og)
    local summary = og
    -- description souvent tronquée (« … ») dans og:description : on cherche la version complète dans la page
    if og == "" or og:sub(-3) == "..." or og:sub(-3) == "…" or #og < 200 then
        local head = (og:gsub("%s+", " ")):sub(1, 25)
        for _, k in ipairs({ "synopsis", "summary", "description", "resume", "intro", "story", "desc" }) do
            local b = grab(html, k)
            if b and select(2, b:gsub("<a%s", "")) <= 3 then
                local d = para(b)
                if #d > #og and #d > 60 and #d < 4000 and (head == "" or (d:gsub("%s+", " ")):find(head, 1, true)) then
                    summary = d
                    break
                end
            end
        end
    end
    local function ogp(p) return dec(html:match('property="' .. p .. '"[^>]-content="([^"]*)"') or html:match('content="([^"]*)"[^>]-property="' .. p .. '"') or "") end
    local cv = abs(dec(html:match('property="og:image"[^>]-content="([^"]*)"')))
    if cv and bad_cover(cv) then cv = nil end
    local cat = ogp("og:novel:category")
    return { name = name, path = path, cover = cv,
        summary = summary, author = ogp("og:novel:author"), status = ogp("og:novel:status"), genres = cat ~= "" and { cat } or {} }
end

function ext:parseNovelMeta(path)
    local html = get(path); if not html then return nil end
    local m = meta(html, path); m.total_chapters = 0; return m
end

function ext:parseNovel(path)
    local html = get(path); if not html then return nil end
    local m, ch, seen = meta(html, path), {}, {}
    for tag, inner_html in html:gmatch("(<a%s[^>]->)(.-)</a>") do
        local href = attr(tag, "href")
        if href and is_chap(href) then
            local k = norm(href)
            local name = txt(inner_html)
            if name == "" then name = dec(attr(tag, "title") or "") end
            if seen[k] then -- même chapitre vu plusieurs fois (derniers chapitres + sommaire, bouton « Lire ») : on garde le titre le plus long
                if #name > #seen[k].name then seen[k].name = name end
            else
                if name == "" then name = "Chapitre " .. (#ch + 1) end
                seen[k] = { name = name, path = rel(href) }
                ch[#ch+1] = seen[k]
            end
        end
    end
    -- si chaque adresse finit par un numéro unique (p12.html, chapter-12), on trie dessus : plus de liste mélangée
    local sorted = #ch > 1
    local nums = {}
    for _, c in ipairs(ch) do
        local n = tonumber(norm(c.path):match("(%d+)[^%d]*$"))
        if not n or nums[n] then sorted = false break end
        nums[n] = true; c.n = n
    end
    if sorted then table.sort(ch, function(a, b) return a.n < b.n end) end
    for i, c in ipairs(ch) do c.chapter_number = i end
    m.chapters, m.totalPages = ch, 1
    return m
end

function ext:parseChapter(path)
    local html = get(path); if not html then return "<p>Chapitre injoignable.</p>" end
    html = html:gsub("<script.-</script>", ""):gsub("<style.-</style>", "")
    -- 1) le conteneur de classe CONT (balise quelconque, <div> imbriquées gérées)
    local body = grab(html, "text-left") or (CONT ~= "" and grab(html, CONT)) or nil
    -- 2) repli : tous les paragraphes <p> de la page
    if not body then
        local ps, n = {}, 0
        for p in html:gmatch("<p%f[%s>][^>]*>(.-)</p>") do
            local t = txt(p)
            if #t > 1 then ps[#ps+1] = "<p>" .. p .. "</p>"; n = n + #t end
        end
        if #ps >= 3 and n > 300 then body = table.concat(ps) end
    end
    if body then -- lignes de pub du site
        body = body:gsub("<p[^>]*>([^<]-)</p>", function(t)
            if #t < 220 and t:lower():find("wuxiaworld", 1, true) then return "" end
        end)
    end
    if body then -- titre doublé en tête de chapitre : « Chapter 434: Chapter 434 Modern Archaeologist » -> « Chapter 434 Modern Archaeologist »
        local head, tail = body:sub(1, 700), body:sub(701)
        local n = 0
        head, n = head:gsub("[Cc]hapter%s+(%d+[%.%-]?%d*)%s*:%s*(<?[^<]-[Cc]hapter%s+%1)", "%2", 1)
        if n == 0 then
            head = head:gsub("([Cc]hapter%s+%d+[%.%-]?%d*)%s*:%s*(%f[%a]%1)", "%2", 1)
        end
        body = head .. tail
    end
    if not body or #body < 50 then return "<p>Texte du chapitre introuvable (classe « " .. CONT .. " »).</p>" end
    return body
end

-- ===== MOTEUR MADARA (WordPress) : modèle éprouvé =====
local MROOT = ((LISTP ~= "" and LISTP or "/manga/"):gsub("/+$", ""))
local function m_list_url(page, order)
    local p = tonumber(page) or 1
    return BASE .. MROOT .. (p > 1 and ("/page/" .. p) or "") .. "/?m_orderby=" .. order
end
function ext:popularNovels(page, options)
    local f = (options and options.filters) or {}
    local p = tonumber(page) or 1
    local order = fval(f, "orderby") or "latest"
    local g, tg = fval(f, "genre"), fval(f, "tag")
    local pg = p > 1 and ("page/" .. p .. "/") or ""
    local q = order ~= "latest" and ("?m_orderby=" .. order) or ""
    local urls
    if g then urls = { BASE .. "/genre/" .. g .. "/" .. pg .. q }
    elseif tg then urls = { BASE .. "/tag/" .. tg .. "/" .. pg .. q }
    elseif order == "latest" then urls = { BASE .. "/" .. pg }
    else -- « novels-list » est la page que le site utilise lui-même pour ses classements
        urls = { BASE .. "/novels-list/" .. pg .. q,
                 BASE .. "/" .. pg .. "?s=&post_type=wp-manga&m_orderby=" .. order }
    end
    local novels, err = {}, nil
    for _, u in ipairs(urls) do
        local html, e = get(u)
        if html then novels = parse_list(html); if #novels > 0 then break end else err = e end
    end
    if #novels == 0 and err then return { novels = {}, error = "Site injoignable (" .. tostring(err) .. ")" } end
    return { novels = novels }
end
function ext:searchNovels(term, page, options)
    term = tostring(term or ""):match("^%s*(.-)%s*$")
    if term == "" then return ext:popularNovels(page, options) end
    local p = tonumber(page) or 1
    local html, err = get(BASE .. (p > 1 and ("/page/" .. p) or "") .. "/?s=" .. enc(term) .. "&post_type=wp-manga")
    if not html then return { novels = {}, error = "Recherche impossible (" .. tostring(err) .. ")" } end
    return { novels = parse_list(html) }
end
local function m_meta(html, path)
    local m = meta(html, path)
    local sm = grab(html, "summary__content") or grab(html, "description-summary")
    if sm then local d = para(sm); if #d > 40 then m.summary = d end end
    local a = html:match('class="author%-content"[^>]*>(.-)</div>')
    if a then m.author = txt(a) end
    local s = html:match('Status%s*</h5>.-summary%-content[^>]*>(.-)</div>')
    if s then m.status = txt(s) end
    if m.summary then -- 1re ligne de pub du site
        m.summary = m.summary:gsub("^[^\n]*WuxiaWorld%.Site[^\n]*\n+", "")
    end
    local g = html:match('class="genres%-content"[^>]*>(.-)</div>')
    if g then for x in g:gmatch("<a[^>]*>(.-)</a>") do m.genres[#m.genres + 1] = txt(x) end end
    return m
end
function ext:parseNovelMeta(path)
    local html = get(path); if not html then return nil end
    local m = m_meta(html, path); m.total_chapters = 0; return m
end
-- ===== chapitres : la fiche n'en contient qu'un (Premier/Dernier) ; la liste vient d'un POST AJAX =====
local function post(url, body)
    local ok, res = pcall(function()
        local req = url:match("^https") and require("ssl.https") or require("socket.http")
        local ltn12 = require("ltn12")
        local chunks = {}
        local _, code = req.request {
            url = url, method = "POST", sink = ltn12.sink.table(chunks), source = ltn12.source.string(body),
            headers = { ["User-Agent"] = UA, ["Referer"] = BASE .. "/", ["X-Requested-With"] = "XMLHttpRequest",
                ["Content-Type"] = "application/x-www-form-urlencoded", ["Content-Length"] = tostring(#body) },
            timeout = 20,
        }
        if code == 200 then return table.concat(chunks) end
    end)
    if ok and type(res) == "string" and #res > 20 then return res end
    return nil
end
local function cnum(path)
    local p = norm(path)
    local n, d = p:match("/chapter%-(%d+)%-(%d+)/?$")
    if n then return tonumber(n .. "." .. d) end
    return tonumber(p:match("/chapter%-(%d+)") or p:match("/(%d+)/?$") or p:match("(%d+)[^%d]*$"))
end
local function m_collect(html, path, seen, ch)
    local pk = norm(path) .. "/"
    for tag, ih in html:gmatch("(<a%s[^>]->)(.-)</a>") do
        local href = attr(tag, "href")
        if href then
            local k = norm(href)
            if not seen[k] and #k > #pk and k:sub(1, #pk) == pk and k:find("%d") then
                seen[k] = true
                local name = txt(ih)
                if name == "" then name = dec(attr(tag, "title") or "") end
                ch[#ch + 1] = { name = name, path = rel(href) }
            end
        end
    end
end
function ext:parseNovelMeta(path)
    local html = get(path); if not html then return nil end
    local m = m_meta(html, path); m.total_chapters = 0; return m
end
function ext:parseNovel(path)
    local html = get(path); if not html then return nil end
    local m, ch, seen = m_meta(html, path), {}, {}
    local rp = path:gsub("^https?://[^/]+", ""):gsub("/+$", "")
    local id = html:match('id="manga%-chapters%-holder"[^>]-data%-id="(%d+)"') or html:match("postid%-(%d+)")
    -- 1) POST <fiche>/ajax/chapters/ (Madara récent), 2) admin-ajax.php (ancien)
    local aj = post(BASE .. rp .. "/ajax/chapters/", "")
    if not (aj and aj:find("<a%s")) and id then aj = post(BASE .. "/wp-admin/admin-ajax.php", "action=manga_get_chapters&manga=" .. id) end
    if aj then m_collect(aj, path, seen, ch) end
    m_collect(html, path, seen, ch) -- boutons Premier / Dernier chapitre
    -- 3) repli : AJAX indisponible -> on reconstruit 1..N d'après les boutons Premier/Dernier
    if #ch <= 2 and #ch >= 1 then
        local lo, hi, pre
        for _, c in ipairs(ch) do
            local pr, n = c.path:match("^(.-/chapter%-)(%d+)/?$")
            if pr then n = tonumber(n); pre = pre or pr; lo = (not lo or n < lo) and n or lo; hi = (not hi or n > hi) and n or hi end
        end
        if pre and hi and hi > lo and hi - lo < 8000 then
            ch = {}
            for n = lo, hi do ch[#ch + 1] = { name = "Chapter " .. n, path = pre .. n .. "/" } end
        end
    end
    -- tri par numéro (chapter-12, chapter-12-5, /3865/) ; à égalité l'ordre de la page est gardé
    local all = #ch > 1
    for i, x in ipairs(ch) do x.i = i; x.n = cnum(x.path); if not x.n then all = false end end
    if all then
        table.sort(ch, function(p, q) if p.n ~= q.n then return p.n < q.n end return p.i < q.i end)
    end
    for i, x in ipairs(ch) do if x.name == "" or x.name:match("^Read ") then x.name = "Chapter " .. (x.n or i) end; x.chapter_number = i end
    m.chapters, m.totalPages = ch, 1
    return m
end

-- ===== Avis : commentaires wpDiscuz de la fiche (chargés en AJAX par le site) =====
local MONTHS = { january = 1, february = 2, march = 3, april = 4, may = 5, june = 6, july = 7, august = 8,
    september = 9, october = 10, november = 11, december = 12 }
local function rv_date(t)
    if not t then return nil end
    local mo, d, y = t:match("^%s*(%a+)%s+(%d+),?%s+(%d%d%d%d)")
    local m = mo and MONTHS[mo:lower()]
    if m then return string.format("%04d-%02d-%02d", tonumber(y), m, tonumber(d)) end
    return t:match("^(%d%d%d%d%-%d%d%-%d%d)")
end
local function rv_json(s)
    local ok, J = pcall(require, "rapidjson")
    if not ok then ok, J = pcall(require, "json") end
    if not ok then return nil end
    local ok2, v = pcall(J.decode, s)
    if ok2 and type(v) == "table" then return v end
    return nil
end
-- bloc HTML dont la classe contient cls, à l'intérieur de blk
local function rv_in(blk, cls)
    local pos = 1
    while true do
        local s2, e2, tn, attrs = blk:find("<(%a%w*)(%s[^>]*)>", pos)
        if not s2 then return nil end
        local c = attr(attrs, "class")
        if c and (" " .. c .. " "):find(" " .. cls .. " ", 1, true) then
            return inner(blk, e2 + 1, tn), attrs
        end
        pos = e2 + 1
    end
end
-- commentaires de premier niveau d'une réponse wpDiscuz (les réponses imbriquées sont ignorées)
local function rv_parse(html)
    local out, pos = {}, 1
    while true do
        local s2, e2, tn, attrs = html:find("<(%a%w*)(%s[^>]*)>", pos)
        if not s2 then break end
        local id = attr(attrs, "id")
        local cl = attr(attrs, "class")
        if id and id:match("^wpd%-comm%-%d+_%d+$") and cl and (" " .. cl .. " "):find(" wpd-comment ", 1, true) then
            local blk = inner(html, e2 + 1, tn) or ""
            pos = e2 + #blk + 1
            if not (" " .. cl .. " "):find(" wpd-reply ", 1, true) then
                local top = blk:gsub('<div[^>]-id="wpd%-comm%-.*$', "") -- coupe avant les réponses imbriquées
                local who = rv_in(top, "wpd-comment-author")
                local what = rv_in(top, "wpd-comment-text")
                local _, dattrs = rv_in(top, "wpd-comment-date")
                local votes = rv_in(top, "wpd-vote-result")
                local av = top:match('<div[^>]-class="wpd%-avatar[^"]*"[^>]*>.-<img[^>]-src=["\']([^"\']+)')
                what = what and para(what) or ""
                if #what > 1 then
                    out[#out + 1] = { id = id:match("(%d+)_"), author = (who and txt(who) ~= "") and txt(who) or "Anonyme",
                        content = what, avatar = av and abs(dec(av)) or nil,
                        date = rv_date(dattrs and attr(dattrs, "title")), likes = tonumber(votes and txt(votes)) or 0, dislikes = 0 }
                end
            end
        else
            pos = e2 + 1
        end
    end
    return out
end
local RV_CUR = {} -- curseur wpDiscuz de la page suivante, par fiche et par tri
local function rv_fetch(path, page, sort)
    local fiche = get(path)
    if not fiche then return nil end
    local id = fiche:match('"wc_post_id":"(%d+)"') or fiche:match("postid%-(%d+)") or fiche:match("[?&]p=(%d+)")
    if not id then return {} , false end
    local wsort = sort == "mostliked" and "by_vote" or (sort == "oldest" and "oldest" or "newest")
    local key = path .. "|" .. wsort
    local cur = (page > 1 and RV_CUR[key .. "|" .. page]) or { last = "0", offset = 0 }
    if page > 1 and not RV_CUR[key .. "|" .. page] then return {}, false end
    local body = "action=wpdLoadMoreComments&sorting=" .. wsort .. "&offset=" .. tostring(cur.offset)
        .. "&lastParentId=" .. tostring(cur.last) .. "&isFirstLoad=" .. (page == 1 and "1" or "0")
        .. "&wpdType=&postId=" .. id
    local raw = post(BASE .. "/wp-admin/admin-ajax.php", body)
    if not raw then return nil end
    local data = rv_json(raw)
    local d = data and (data.data or data) or nil
    local html = type(d) == "table" and (d.comment_list or d.message or d.comments) or raw
    if type(html) ~= "string" then return nil end
    local items = rv_parse(html)
    local more = type(d) == "table" and (tostring(d.is_show_load_more) == "1" or d.is_show_load_more == true) or false
    if more and #items > 0 then
        local last = type(d) == "table" and (d.last_parent_id or d.loadLastCommentId) or nil
        RV_CUR[key .. "|" .. (page + 1)] = { last = tostring(last or items[#items].id or "0"), offset = cur.offset + #items }
    else
        more = false
    end
    return items, more
end

function ext:parseReviews(path, page, sort)
    local pg = tonumber(page) or 1
    local p = path:gsub("^https?://[^/]+", ""):gsub("/+$", "")
    local ok, items, more = pcall(rv_fetch, p, pg, sort)
    if not ok or items == nil then
        logger.warn("wuxiaworld.site: avis indisponibles", tostring(items))
        return { reviews = {}, has_more = false, error = true }
    end
    return { reviews = items, has_more = more and true or false }
end

return ext
