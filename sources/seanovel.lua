-- بحر الروايات (seanovel.org) — source Sefirah, réparée à la main.
-- Contrat : voir extensions/mangapill.lua du plugin Sefirah.
-- 0.3.1 : recherche via l'API JSON en priorité (la page /search est rendue côté client, donc vide pour le parseur HTML) et résultats du serveur
-- non refiltrés par titre ; nettoyage des textes promotionnels (début « أنت تقرأ الفصل… » / fin « انتهى الفصل… ») dans les chapitres.
-- 0.3.0 : le site n'a plus de page /novels (c'était le « 404 injoignable »). La liste vient maintenant
-- de /search (« تصفح الروايات ») avec repli sur l'accueil « / » ; les chapitres sont obtenus par l'API
-- si elle répond, sinon reconstruits depuis le nombre de chapitres de la fiche (/novels/<slug>/chapters/<n>).
local logger = require("logger")
local BASE     = "https://seanovel.org"
local LIST_URL = "/search"   -- page « Parcourir » du site
local HOME_URL = "/"         -- repli : l'accueil liste aussi des romans
local LISTP    = "/novels/"
local NOVELS   = "/novels"   -- préfixe des fiches : /novels/<slug>
local CHAPP    = "/chapters/"
local CONT     = "reader-content"
local PER_PAGE = 50   -- taille d'une « page » de chapitres pour la mise à jour incrémentale
local LIMIT    = 500  -- chapitres demandés par requête (retombe à 50 si l'API refuse)

-- Noms des paramètres d'URL du site pour les filtres (à ajuster ICI si le site les appelle autrement).
local FILTER_PARAM = { genre = "genre", origin = "origin" }

-- Adresses essayées tour à tour pour la recherche ; la première qui renvoie des résultats est retenue.
local SEARCH_TRIES = {
    "/api/novels?search={q}&page={page}",
    "/api/search?q={q}&page={page}",
    "/api/novels/search?q={q}&page={page}",
    "/api/novels?q={q}&page={page}",
    "/api/search?query={q}&page={page}",
    "/api/search?search={q}&page={page}",
    "/api/novel/search?q={q}&page={page}",
    "/api/novels?keyword={q}&page={page}",
    "/search?q={q}&page={page}",
}
local search_win -- index de l'adresse qui a marché

local ok_j, JSON = pcall(require, "rapidjson")
if not ok_j then JSON = require("json") end
local function jdecode(s)
    local ok, d = pcall(JSON.decode, s)
    if ok and type(d) == "table" then return d end
    return nil
end
local UA = "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36"

local function get(p, api)
    local url = p:match("^https?://") and p or (BASE .. p)
    local headers = { ["User-Agent"] = UA, ["Referer"] = BASE .. "/" }
    if api then headers["Accept"] = "application/json" end
    local body, code = require("core.net").get(url, { headers = headers, timeout = 20 })
    if body and #body > 2 then return body end
    logger.warn("بحر الروايات: échec", url, tostring(code))
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
local function cover_of(img)
    if not img then return nil end
    for _, k in ipairs({ "data-src", "data-lazy-src", "data-original", "src", "srcset" }) do
        local u = attr(img, k)
        if k == "srcset" and u then u = u:match("^%s*(%S+)") end
        if u and u ~= "" and not u:match("^data:") and not u:lower():find("placeholder", 1, true) and not u:lower():find("blank", 1, true) then
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

local function parse_list(html)
    local out, idx = {}, {}
    for tag, inner_html in html:gmatch("(<a%s[^>]->)(.-)</a>") do
        local href = attr(tag, "href")
        if href and LISTP ~= "" and href:find(LISTP, 1, true) and not (CHAPP ~= "" and href:find(CHAPP, 1, true))
           and norm(href) ~= "/novels" then
            local k = norm(href)
            local img = inner_html:match("<img[^>]->")
            local name = attr(tag, "title") or (img and attr(img, "alt"))
            if name and name ~= "" then name = dec(name) else name = txt(inner_html) end
            local cover = cover_of(img)
            local it = idx[k]
            if it then -- même œuvre déjà vue (autre lien, autre forme d'URL) : on complète seulement
                if it.name == "" and name ~= "" then it.name = name end
                if not it.cover and cover then it.cover = cover end
            else
                it = { name = name, path = rel(href), cover = cover }
                idx[k] = it
                out[#out+1] = it
            end
        end
    end
    local res = {}
    for _, it in ipairs(out) do if it.name ~= "" then res[#res+1] = it end end
    return res
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
        for _, k in ipairs({ "synopsis", "summary", "description", "resume", "story", "desc" }) do
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
    -- bloc « عن الرواية » de la fiche (souvent plus complet que og:description)
    local blk = html:match("عن الرواية</h3>.-<p[^>]*>(.-)</p>")
    if blk then
        local d = para(blk)
        if #d > #summary then summary = d end
    end
    local status = txt(html:match(">([^<>]+)</div>%s*<div[^>]*>%s*الحالة%s*<") or "")
    local genres = {}
    for tag, inner_html in html:gmatch("(<a%s[^>]->)(.-)</a>") do
        local href = attr(tag, "href")
        if href and href:find("search?genre=", 1, true) then
            local g = txt(inner_html)
            if g ~= "" then genres[#genres + 1] = g end
        end
    end
    local cover = abs(dec(html:match('property="og:image"[^>]-content="([^"]*)"') or ""))
    if not cover or cover == "" then
        cover = BASE .. "/api/novel/" .. (path:match("/novels/([^/?#]+)") or "") .. "/cover?type=webp"
    end
    return { name = name, path = path, cover = cover,
        summary = summary, author = "", status = status, genres = genres }
end

-- ===== résultats au format JSON (API du site) =====
local function json_list(d)
    local function find(t, depth)
        if depth > 4 then return nil end
        local f = t[1]
        if type(f) == "table" and f.slug and (f.title or f.name) then return t end
        for _, v in pairs(t) do
            if type(v) == "table" then
                local r = find(v, depth + 1)
                if r then return r end
            end
        end
        return nil
    end
    local arr = find(d, 0)
    local res = {}
    for _, n in ipairs(arr or {}) do
        local cover = n.cover or n.coverUrl or n.cover_url or n.image or n.thumbnail or n.poster
        if type(cover) == "table" then cover = cover.url end
        res[#res + 1] = { name = dec(tostring(n.title or n.name)), path = NOVELS .. "/" .. tostring(n.slug),
            cover = type(cover) == "string" and abs(cover) or (BASE .. "/api/novel/" .. tostring(n.slug) .. "/cover?type=webp") }
    end
    return res
end
local function parse_any(body)
    if body:match("^%s*[%[{]") then
        local d = jdecode(body)
        return d and json_list(d) or {}
    end
    return parse_list(body)
end

-- garde les romans dont le titre contient tous les mots cherchés
local function matching(list, term)
    local words = {}
    for w in term:lower():gmatch("%S+") do words[#words + 1] = w end
    local out = {}
    for _, it in ipairs(list) do
        local n, ok = it.name:lower(), true
        for _, w in ipairs(words) do
            if not n:find(w, 1, true) then ok = false; break end
        end
        if ok then out[#out + 1] = it end
    end
    return out
end

-- ===== filtres « Parcourir » (paramètres vus dans les liens du site : ?genre=<nom arabe>, ?origin=translated) =====
local GENRES = { "أكشن", "خيال", "سحر", "كوميدى", "نظام", "إعادة ولادة", "عالم آخر", "زراعة", "رومانسي", "مغامرة", "دراما" }
local gopts = { { id = "", label = "Tous" } }
for _, g in ipairs(GENRES) do gopts[#gopts + 1] = { id = g, label = g } end
local POPULAR_FILTERS = {
    { key = "genre", label = "Genre", default = "", options = gopts },
    { key = "origin", label = "Origine", default = "", options = {
        { id = "", label = "Toutes" }, { id = "translated", label = "Traduit (مترجم)" } } },
}

local function list_url(page, f, base)
    local q = {}
    page = tonumber(page) or 1
    if page > 1 then q[#q + 1] = "page=" .. page end
    for _, key in ipairs({ "genre", "origin" }) do
        local v = f and f[key]
        if v and v ~= "" then q[#q + 1] = FILTER_PARAM[key] .. "=" .. enc(v) end
    end
    return (base or LIST_URL) .. (#q > 0 and ("?" .. table.concat(q, "&")) or "")
end

local ext = { id = "seanovel", name = "SeaNovel", site = BASE, lang = "ar", version = "0.3.2",
    popularFilters = POPULAR_FILTERS, searchFilters = {}, hasReviews = false, chapterCommentsPanel = false,
    chapters_per_page = PER_PAGE }

function ext:popularNovels(page, options)
    local f = (options and options.filters) or {}
    page = tonumber(page) or 1
    local body, err = get(list_url(page, f))
    local list = body and parse_any(body) or {}
    if #list == 0 and page == 1 then
        -- repli : l'accueil du site (sans filtres) liste aussi des romans
        local home = get(HOME_URL)
        if home then list = parse_any(home); body = body or home end
    end
    if not body then return { novels = {}, error = "Site injoignable (" .. tostring(err) .. ")" } end
    if #list == 0 and page == 1 then
        return { novels = {}, error = "Aucun roman reconnu sur " .. BASE .. LIST_URL }
    end
    return { novels = list }
end

function ext:searchNovels(term, page, options)
    term = tostring(term or ""):match("^%s*(.-)%s*$")
    if term == "" then return ext:popularNovels(page, options) end
    page = tonumber(page) or 1
    local order = {}
    if search_win then order[1] = search_win end
    for i = 1, #SEARCH_TRIES do if i ~= search_win then order[#order + 1] = i end end
    local reached = false
    for _, i in ipairs(order) do
        local url = SEARCH_TRIES[i]:gsub("{q}", function() return enc(term) end):gsub("{page}", function() return tostring(page) end)
        local body = get(url, url:find("/api/", 1, true) ~= nil)
        if body then
            reached = true
            local is_json = body:match("^%s*[%[{]") ~= nil
            local list = parse_any(body)
            if not is_json then list = matching(list, term) end -- page HTML : le serveur peut ignorer « q »
            if #list > 0 then search_win = i; return { novels = list } end
        end
    end
    -- Dernier recours : on filtre les premières pages de la liste du site.
    local found = {}
    for p = 1, 5 do
        local body = get(list_url(p, nil)) or (p == 1 and get(HOME_URL)) or nil
        if body then
            reached = true
            for _, it in ipairs(matching(parse_any(body), term)) do found[#found + 1] = it end
        end
        if #found >= 20 then break end
    end
    if #found > 0 then return { novels = found } end
    if not reached then return { novels = {}, error = "Recherche impossible : site injoignable." } end
    return { novels = {} }
end

-- ===== chapitres : API /api/novel/<slug>/chapters?offset=&limit=&sort=asc =====
local function slug_of(path)
    return tostring(path):match("/novels/([^/?#]+)") or tostring(path):gsub("/+$", ""):match("([^/]+)$")
end

local function api_page(slug, offset, limit)
    local body = get("/api/novel/" .. slug .. "/chapters?offset=" .. offset .. "&limit=" .. limit .. "&sort=asc", true)
    return body and jdecode(body) or nil
end

-- Forme des liens de chapitre du site (« /chapters/…/58 ») lue dans la page du roman.
local PAT = {}
local function chapter_pattern(slug, html)
    if PAT[slug] then return PAT[slug][1], PAT[slug][2] end
    html = html or get(NOVELS .. "/" .. slug)
    if html then
        for tag in html:gmatch("<a%s[^>]->") do
            local href = attr(tag, "href")
            if href and href:find(CHAPP, 1, true) then
                local h = rel(href):gsub("[?#].*$", "")
                local pre, suf = h:match("^(.*%D)%d+(%D*)$")
                if pre then PAT[slug] = { pre, suf }; return pre, suf end
            end
        end
    end
    logger.warn("بحر الروايات: forme des liens de chapitre inconnue, valeur par défaut pour", slug)
    PAT[slug] = { NOVELS .. "/" .. slug .. CHAPP, "" }
    return PAT[slug][1], PAT[slug][2]
end

local function map_chapter(c, pre, suf)
    local id = tonumber(c.id)
    local name = txt(tostring(c.title or ""))
    if name == "" then name = "Chapitre " .. tostring(c.id) end
    return { name = name, path = pre .. tostring(c.id) .. suf, chapter_number = id, date = c.date }
end

-- tous les chapitres à partir de l'index « from » ; 3e valeur = true si la récupération est incomplète
local function fetch_from(slug, from)
    local out, offset, total, limit = {}, from, nil, LIMIT
    for _ = 1, 400 do
        local d = api_page(slug, offset, limit)
        if (not d or type(d.chapters) ~= "table") and limit > PER_PAGE and #out == 0 then
            limit = PER_PAGE; LIMIT = PER_PAGE
            d = api_page(slug, offset, limit)
        end
        if not d or type(d.chapters) ~= "table" then
            return out, total, true
        end
        total = tonumber(d.total) or total
        for _, c in ipairs(d.chapters) do out[#out + 1] = c end
        offset = offset + #d.chapters
        if #d.chapters == 0 or d.hasMore == false or (total and offset >= total) then break end
    end
    return out, total, false
end

-- Dernier numéro de chapitre lu dans la fiche (champ « ابحث برقم الفصل » max="831", sinon « 831 فصل »).
local function last_number(html)
    if not html then return nil end
    for tag in html:gmatch("<input[^>]->") do
        if attr(tag, "min") == "1" and attr(tag, "max") then
            local n = tonumber(attr(tag, "max"))
            if n and n > 0 then return n end
        end
    end
    local n = html:match("(%d+)%s*</div>%s*<div[^>]*>%s*الفصول")
        or html:match("(%d+)%s*فصل")
    return tonumber(n)
end

local api_dead = false -- l'API /chapters a répondu une erreur : on ne la réessaie plus pendant la session

-- tous les chapitres à partir de l'index « from » (0 = tout) ; 3e valeur = true si la récupération a échoué
local function fetch_all(slug, from, html)
    from = tonumber(from) or 0
    if not api_dead then
        local list, total, failed = fetch_from(slug, from)
        if not failed and #list > 0 then
            local pre, suf = chapter_pattern(slug, html)
            local res = {}
            for _, c in ipairs(list) do res[#res + 1] = map_chapter(c, pre, suf) end
            return res, total, false
        end
        if failed then api_dead = true end
    end
    -- Repli sans API : les chapitres sont numérotés 1..N (liens /novels/<slug>/chapters/<n>)
    html = html or get(NOVELS .. "/" .. slug)
    local last = last_number(html)
    if not last then return {}, nil, true end
    local res = {}
    for n = from + 1, last do
        res[#res + 1] = { name = "الفصل " .. n, path = NOVELS .. "/" .. slug .. CHAPP .. n, chapter_number = n }
    end
    return res, last, false
end

function ext:parseNovelMeta(path)
    local html = get(path); if not html then return nil end
    local m = meta(html, path)
    m.total_chapters = last_number(html) or 0
    return m
end

function ext:parsePage(path, page)
    local slug = slug_of(path)
    local from = ((tonumber(page) or 1) - 1) * PER_PAGE
    local all, _, failed = fetch_all(slug, from)
    if failed then return { chapters = {}, failed = true } end
    local res = {}
    for i = 1, math.min(PER_PAGE, #all) do res[i] = all[i] end
    return { chapters = res }
end

-- ===== nettoyage : textes promotionnels du site (début et fin de chaque chapitre) =====
local PROMO_START = { "أنت تقرأ الفصل", "انت تقرأ الفصل", "أنت تقرا الفصل", "انتهى الفصل", "انتهي الفصل" }
local function is_promo(t)
    t = (t or ""):gsub("^[%s%p]+", "")
    if t == "" then return false end
    for _, m in ipairs(PROMO_START) do
        if t:sub(1, #m) == m then return true end
    end
    if #t < 400 and (t:find("تابع القراءة على بحر الروايات", 1, true)
        or t:find("حصراً على بحر الروايات", 1, true) or t:find("حصرياً على بحر الروايات", 1, true)) then
        return true
    end
    return false
end
local function clean_chapter(body)
    -- paragraphes <p>
    body = body:gsub("<p%f[%s>][^>]*>(.-)</p>", function(inner_html)
        if is_promo(txt(inner_html)) then return "" end
    end)
    -- <div>/<span>/<h*> ne contenant que du texte
    body = body:gsub("<(%a%w*)[^>]*>([^<]*)</%1>", function(tn, t)
        if is_promo(dec(t)) then return "" end
    end)
    -- texte brut séparé par <br> ou posé directement dans le conteneur
    local function strip_text_nodes(b)
        return (b:gsub("(>%s*)([^<]+)(<)", function(l, t, r)
            local out, changed = {}, false
            for line in (dec(t) .. NL):gmatch("([^" .. NL .. "]*)" .. NL) do
                if is_promo(line) then changed = true else out[#out + 1] = line end
            end
            if not changed then return nil end
            return l .. table.concat(out, NL) .. r
        end))
    end
    body = strip_text_nodes(body)
    return body
end

function ext:parseChaptersFrom(path, skip)
    local slug = slug_of(path)
    local res, total, failed = fetch_all(slug, tonumber(skip) or 0)
    if failed then return { chapters = {}, failed = true } end
    return { chapters = res, total = total }
end

function ext:parseNovel(path)
    local html = get(path); if not html then return nil end
    local slug = slug_of(path)
    local m = meta(html, path)
    local ch = fetch_all(slug, 0, html)
    if #ch == 0 then
        -- dernier recours : les chapitres visibles dans la page (10 environ)
        local seen = {}
        for tag, inner_html in html:gmatch("(<a%s[^>]->)(.-)</a>") do
            local href = attr(tag, "href")
            if href and href:find(CHAPP, 1, true) and not seen[norm(href)] then
                seen[norm(href)] = true
                local name = txt(inner_html)
                if name == "" then name = dec(attr(tag, "title") or "") end
                if name == "" then name = "الفصل " .. (#ch + 1) end
                ch[#ch + 1] = { name = name, path = rel(href), chapter_number = #ch + 1 }
            end
        end
    end
    m.chapters, m.totalPages, m.total_chapters = ch, 1, #ch
    return m
end

function ext:parseChapter(path)
    local html = get(path); if not html then return "<p>Chapitre injoignable.</p>" end
    html = html:gsub("<script.-</script>", ""):gsub("<style.-</style>", "")
    -- 1) le conteneur de classe CONT (balise quelconque, <div> imbriquées gérées)
    local body
    for _, c in ipairs({ CONT, "chapter-content", "chapter-text", "chapter-body", "reading-content", "reader-body" }) do
        body = grab(html, c)
        if body then break end
    end
    -- 2) repli : tous les paragraphes <p> de la page
    if not body then
        local ps, n = {}, 0
        for p in html:gmatch("<p%f[%s>][^>]*>(.-)</p>") do
            local t = txt(p)
            if #t > 1 then ps[#ps+1] = "<p>" .. p .. "</p>"; n = n + #t end
        end
        if #ps >= 3 and n > 300 then body = table.concat(ps) end
    end
    if body then body = clean_chapter(body) end
    if not body or #body < 50 then return "<p>Texte du chapitre introuvable (classe « " .. CONT .. " »).</p>" end
    return body
end

return ext
