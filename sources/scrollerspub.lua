-- ScrollersPub — source Sefirah (v0.1.4), écrite à la main d'après le HTML statique du site.
-- Site : SPA React (Vite) qui sert un instantané HTML lisible sans JavaScript.
--   liste    : /novels?page=N&status=&tag=&search=      fiche : /novel/<slug>      chapitre : /read/<uuid>
--   liste API : /api/novels?tag=&status=&sort_by=&is_adult=&mtl=&domain=&limit=100&offset=N -> { total, offset, limit, items = [...] }
--   chapitres (liste complète) : /api/novel/<uuid>/chapters?offset=N&limit=N -> { total, offset, limit, items = [...] }
--     (la fiche statique ne liste que les 10 premiers chapitres ; items[].id = uuid du chapitre, items[].serial = numéro)
-- Contrat : voir extensions/mangapill.lua du plugin Sefirah.
local logger = require("logger")
local BASE   = "https://www.scrollerspub.com"
local UA = "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36"

local CHAP_LIMIT = 500 -- chapitres demandés par requête (si le serveur plafonne, la boucle s'adapte)

local function get(p, json)
    local url = p:match("^https?://") and p or (BASE .. p)
    local headers = { ["User-Agent"] = UA, ["Referer"] = BASE .. "/" }
    if json then headers["Accept"] = "application/json" end
    local body, code = require("core.net").get(url, { headers = headers, timeout = 15 })
    if body and #body > 2 then return body end
    logger.warn("ScrollersPub: échec", url, tostring(code))
    return nil, tostring(code)
end

-- ===== décodage des entités HTML =====
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
    ocirc = "ô", ugrave = "ù", ucirc = "û", uuml = "ü", oelig = "œ" }
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

local function attr(tag, n)
    local k = "%f[%w_%-]" .. n:gsub("%-", "%%-") .. "%s*=%s*"
    return tag:match(k .. '"([^"]*)"') or tag:match(k .. "'([^']*)'")
end
local function abs(u) if not u then return nil end if u:sub(1,2)=="//" then return "https:"..u end if u:sub(1,1)=="/" then return BASE..u end return u end
local function enc(s) return (tostring(s):gsub("([^%w%-%._~])", function(c) return string.format("%%%02X", c:byte()) end)) end
local function rel(h) return (h:gsub("^"..BASE:gsub("%p","%%%0"), "")) end
local function bad_cover(u)
    local last = (u:gsub("[?#].*$", ""):match("([^/]*)$") or ""):lower()
    return last == "" or last == "none" or last == "null" or last == "undefined" or last == "nan" or last == "false"
end
local function cover_of(img)
    if not img then return nil end
    for _, k in ipairs({ "data-src", "data-lazy-src", "src", "srcset" }) do
        local u = attr(img, k)
        if k == "srcset" and u then u = u:match("^%s*(%S+)") end
        if u and u ~= "" and not u:match("^data:") and not u:lower():find("placeholder", 1, true) and not bad_cover(u) then
            return abs(dec(u))
        end
    end
    return nil
end

-- contenu équilibré de la balise ouverte en position « from » (gère les <div> imbriquées)
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

local function jdecode(str)
    local ok_j, J = pcall(require, "rapidjson")
    if not ok_j then J = require("json") end
    local ok, d = pcall(J.decode, str)
    if ok and type(d) == "table" then return d end
    return nil
end
-- le JSON null devient une valeur truthy avec rapidjson : on ne garde que les vraies chaînes
local function pick(o, names)
    if type(o) ~= "table" then return nil end
    for _, n in ipairs(names) do
        local v = o[n]
        if type(v) == "string" and v ~= "" then return v end
    end
    return nil
end

-- ===== Liste (HTML) =====
-- /novel/<slug> (un seul segment) -> slug ; tout le reste (chapitres, /novels?tag=…) -> nil
local function novel_slug(href)
    if not href then return nil end
    href = href:gsub("[?#].*$", "")
    return href:match("^https?://[^/]+/novel/([^/]+)/?$") or href:match("^/novel/([^/]+)/?$")
end

local function parse_list(html)
    local out, idx = {}, {}
    for tag, body in html:gmatch("(<a%s[^>]->)(.-)</a>") do
        local slug = novel_slug(attr(tag, "href"))
        if slug then
            local img = body:match("<img[^>]->")
            local name = attr(tag, "title")
            if not name or name == "" then name = txt(body) end
            if (not name or name == "") and img then name = (attr(img, "alt") or ""):gsub("%s*[—-]*%s*cover$", ""):gsub("^Read%s+", "") end
            name = dec(name or "")
            local cover = cover_of(img)
            local it = idx[slug]
            if it then
                if it.name == "" and name ~= "" then it.name = name end
                if not it.cover and cover then it.cover = cover end
            else
                it = { name = name, path = "/novel/" .. slug, cover = cover }
                idx[slug] = it
                out[#out + 1] = it
            end
        end
    end
    local res = {}
    for _, it in ipairs(out) do if it.name ~= "" then res[#res + 1] = it end end
    return res
end

-- la liste HTML n'a pas de couvertures : og:image de la fiche (une requête par roman), mémorisée pour la session ;
-- « budget » = nombre maximum de fiches lues par appel
local COVERS = {}
local function fill_covers(res, budget)
    budget = budget or 12
    for _, it in ipairs(res) do
        if not it.cover and COVERS[it.path] then it.cover = COVERS[it.path] end
        if not it.cover and budget > 0 and COVERS[it.path] == nil then
            budget = budget - 1
            local ok, page = pcall(get, it.path)
            local og = ok and page and (page:match('property="og:image"[^>]-content="([^"]*)"') or page:match('content="([^"]*)"[^>]-property="og:image"'))
            if og and og ~= "" and not bad_cover(og) then
                it.cover = abs(dec(og))
                COVERS[it.path] = it.cover
            else
                COVERS[it.path] = false
            end
        end
    end
    return res
end

-- ===== Filtres =====
local function opts(list)
    local o = {}
    for _, p in ipairs(list) do o[#o + 1] = { id = p[1], label = p[2] } end
    return o
end
local GENRES = { "Fantasy", "Action", "Romance", "Adventure", "Comedy", "Drama", "Mystery", "Supernatural", "Slice of Life",
    "Sci-Fi", "Seinen", "Shounen", "Josei", "Shoujo", "Horror", "Historical", "Psychological", "Tragedy", "Mature",
    "Martial Arts", "Xianxia", "Xuanhuan", "Eastern", "Harem", "Academy", "Ecchi", "Mecha", "Wuxia",
    "Transmigration", "Reincarnation", "System", "Cultivation", "Magic", "Revenge", "Survival", "Apocalypse",
    "Superpowers", "Monsters", "Dragons", "Kingdom Building", "Game Elements", "Level System", "Weak to Strong",
    "Overpowered Protagonist", "Female Lead", "Male Protagonist", "Face Slapping", "Rebirth", "Dungeons", "Necromancer",
    "Alchemy", "Evolution", "Time Travel", "Isekai", "Urban Fantasy", "Virtual Reality", "Web Novel", "Korean Novel", "Chinese Novel" }
local GENRE_OPTS = { { "Any", "Tous" } }
for _, g in ipairs(GENRES) do GENRE_OPTS[#GENRE_OPTS + 1] = { g:lower(), g } end

local FILTERS = {
    { key = "sort_by", label = "Trier par", default = "views",
      options = opts({ { "views", "Popularité (vues)" }, { "rating", "Note" }, { "updated_at", "Mise à jour" },
          { "created_at", "Ajout récent" }, { "chapter_count", "Nb de chapitres" }, { "title", "Titre" } }) },
    { key = "status", label = "Statut", default = "Any",
      options = opts({ { "Any", "Tous" }, { "ongoing", "En cours" }, { "completed", "Terminé" }, { "hiatus", "En pause" } }) },
    { key = "tag", label = "Genre / Tag", default = "Any", options = opts(GENRE_OPTS) },
    { key = "is_adult", label = "Contenu adulte", default = "Any",
      options = opts({ { "Any", "Tous" }, { "false", "Masquer" }, { "true", "Uniquement" } }) },
    { key = "mtl", label = "Traduction auto (MTL)", default = "Any",
      options = opts({ { "Any", "Tous" }, { "false", "Non" }, { "true", "Oui" } }) },
    { key = "domain", label = "Source", default = "Any",
      options = opts({ { "Any", "Toutes" }, { "novelfull.net", "NovelFull" }, { "chikari.moe", "Chikari" },
          { "lightnovelpub.org", "LightNovelPub" } }) },
}

-- api = true  : paramètres de /api/novels (100 romans par page, offset)
-- api = false : paramètres de la page HTML /novels (status et tag uniquement)
local function build_query(filters, page, api)
    local q = {}
    filters = filters or {}
    local function add(k)
        local v = tostring(filters[k] or "")
        if v ~= "" and v ~= "Any" then q[#q + 1] = k .. "=" .. enc(v) end
    end
    if api then
        add("sort_by"); add("status"); add("tag"); add("is_adult"); add("mtl"); add("domain")
        q[#q + 1] = "limit=100"
        if page > 1 then q[#q + 1] = "offset=" .. ((page - 1) * 100) end
    else
        add("status"); add("tag")
        if page > 1 then q[#q + 1] = "page=" .. page end
    end
    return #q > 0 and ("?" .. table.concat(q, "&")) or ""
end

-- liste via l'API JSON (items[].slug / title / cover_file) ; nil si indisponible
local function api_list(page, filters)
    local body = get("/api/novels" .. build_query(filters, page, true), true)
    local data = body and jdecode(body)
    if not data or type(data.items) ~= "table" then return nil end
    local out = {}
    for _, n in ipairs(data.items) do
        local slug = type(n) == "table" and pick(n, { "slug" })
        if slug then
            local cover
            if n.cover_available == true and pick(n, { "cover_file" }) then
                cover = BASE .. "/static/" .. n.cover_file
            else
                cover = pick(n, { "cover_url" })
            end
            if cover and bad_cover(cover) then cover = nil end
            out[#out + 1] = { name = dec(pick(n, { "title" }) or slug), path = "/novel/" .. slug, cover = cover }
        end
    end
    return out
end

local ext = { id = "scrollerspub", name = "ScrollersPub", site = BASE, lang = "en", version = "0.1.4",
    popularFilters = FILTERS, searchFilters = FILTERS, hasReviews = false, chapterCommentsPanel = false }

local function list_page(page, options)
    local pg = math.max(tonumber(page) or 1, 1)
    local filters = options and options.filters
    local res = api_list(pg, filters)
    if res then return { novels = res } end -- l'API fournit déjà les couvertures
    local html, err = get(BASE .. "/novels" .. build_query(filters, pg))
    if not html then
        if pg > 1 then return { novels = {} } end
        return { novels = {}, error = "Site injoignable (" .. tostring(err) .. ")" }
    end
    local total = tonumber(html:match("Page %d+ of (%d+)"))
    if total and pg > total then return { novels = {} } end
    return { novels = fill_covers(parse_list(html), 12) }
end

function ext:popularNovels(page, options) return list_page(page, options) end

-- ===== Recherche =====
-- Le serveur ignore ?search= sur /novels (il renvoie la liste par défaut) : la recherche du site passe par une API JSON.
-- 1) routes SEARCH_API (essayées une seule fois par session) ; 2) sinon index local, construit page après page
-- à partir de /novels et conservé pendant la session.
local SEARCH_API = { "/api/search?q={q}", "/api/novels?search={q}&limit=100", "/api/novels/search?q={q}" }
local SEARCH_API_OK, SEARCH_API_DEAD
local MAX_SCAN = 25 -- pages de liste lues au maximum par recherche (la suite reprend au prochain appel)
local INDEX = {}    -- une entrée par combinaison de filtres : { items, page, total, done }

local function nt(s)
    local r = (" " .. tostring(s):lower():gsub("[^%w]+", " ") .. " "):gsub("%s+", " ")
    return r
end

local function api_search(term)
    if SEARCH_API_DEAD then return nil end
    local routes = SEARCH_API_OK and { SEARCH_API_OK } or SEARCH_API
    for _, tpl in ipairs(routes) do
        local body = get((tpl:gsub("{q}", function() return enc(term) end)), true)
        local data = body and jdecode(body)
        if data then
            local list = data
            for _, k in ipairs({ "novels", "results", "data", "items" }) do
                if type(data[k]) == "table" then list = data[k]; break end
            end
            local out = {}
            for _, n in ipairs(list) do
                local slug = type(n) == "table" and pick(n, { "slug" })
                if slug then
                    local cover
                    if n.cover_available == true and pick(n, { "cover_file" }) then
                        cover = BASE .. "/static/" .. n.cover_file
                    else
                        cover = abs(pick(n, { "cover_url", "cover", "coverImage", "coverUrl", "image", "thumbnail" }))
                    end
                    out[#out + 1] = { name = dec(pick(n, { "title", "name" }) or slug), path = "/novel/" .. slug, cover = cover }
                end
            end
            if #out > 0 then SEARCH_API_OK = tpl; return out end
        end
    end
    if not SEARCH_API_OK then SEARCH_API_DEAD = true end
    return nil
end

local function scan(ix, options)
    local n = 0
    while not ix.done and n < MAX_SCAN do
        local pg = ix.page + 1
        local html = get(BASE .. "/novels" .. build_query(options and options.filters, pg))
        if not html then break end
        ix.total = tonumber(html:match("Page %d+ of (%d+)")) or ix.total
        local got = 0
        for _, it in ipairs(parse_list(html)) do
            if not ix.seen[it.path] then
                ix.seen[it.path] = true
                it.key = nt(it.name)
                ix.items[#ix.items + 1] = it
                got = got + 1
            end
        end
        ix.page = pg
        n = n + 1
        if got == 0 or (ix.total and pg >= ix.total) then ix.done = true end
    end
end

local function local_search(term, page, options)
    local key = build_query(options and options.filters, 1)
    local ix = INDEX[key]
    if not ix then ix = { items = {}, seen = {}, page = 0, done = false }; INDEX[key] = ix end
    local words = {}
    for w in nt(term):gmatch("%S+") do words[#words + 1] = w end
    if #words == 0 then return {} end
    local exact = nt(term)
    local function matches()
        local hit, rest = {}, {}
        for _, it in ipairs(ix.items) do
            local ok = true
            for _, w in ipairs(words) do
                if not it.key:find(" " .. w, 1, true) then ok = false break end -- début de mot
            end
            if ok then
                if it.key == exact then table.insert(hit, 1, it)
                elseif it.key:find("^" .. exact:gsub("%p", "%%%0")) then hit[#hit + 1] = it
                else rest[#rest + 1] = it end
            end
        end
        for _, it in ipairs(rest) do hit[#hit + 1] = it end
        return hit
    end
    local need = (page or 1) * 20
    local hit = matches()
    if #hit < need and not ix.done then
        scan(ix, options)
        hit = matches()
    end
    local out = {}
    for i = (page or 1) * 20 - 19, math.min(#hit, (page or 1) * 20) do out[#out + 1] = hit[i] end
    return out
end

function ext:searchNovels(term, page, options)
    term = tostring(term or ""):match("^%s*(.-)%s*$")
    if term == "" then return list_page(page, options) end
    local pg = math.max(tonumber(page) or 1, 1)
    local res
    if pg == 1 then res = api_search(term) end
    if res then return { novels = fill_covers(res, 20) } end
    if SEARCH_API_OK and pg > 1 then return { novels = {} } end
    return { novels = fill_covers(local_search(term, pg, options), 20) }
end

-- ===== Fiche =====
local function ld_book(html)
    for blk in html:gmatch('<script type="application/ld%+json">(.-)</script>') do
        if blk:find('"Book"', 1, true) then return jdecode(blk) end
    end
    return nil
end

local function meta(html, path)
    local book = ld_book(html) or {}
    local name = pick(book, { "name" }) or txt(html:match("<h1[^>]*>(.-)</h1>") or "")
    if name == "" then name = dec(html:match('property="og:title"[^>]-content="([^"]*)"') or path) end
    local author = ""
    if type(book.author) == "table" then
        local a = book.author[1] or book.author
        author = pick(a, { "name" }) or ""
    end
    if author == "" then author = txt(html:match("<p>by%s*<strong>(.-)</strong>") or "") end
    local summary = pick(book, { "description" }) or dec(html:match('property="og:description"[^>]-content="([^"]*)"') or "")
    local cover = pick(book, { "image" }) or html:match('property="og:image"[^>]-content="([^"]*)"')
    if cover and bad_cover(cover) then cover = nil end
    local genres, seen = {}, {}
    for g in html:gmatch('href="[^"]*/novels%?tag=[^"]*"[^>]*>(.-)</a>') do
        g = txt(g)
        if g ~= "" and not seen[g] then seen[g] = true; genres[#genres + 1] = g end
    end
    local total = tonumber(book.numberOfEpisodes) or tonumber(html:match("<strong>(%d+)</strong>%s*chapters available")) or 0
    -- l'uuid du roman se lit dans l'URL de la couverture (/static/novels/<uuid>/…)
    return { name = dec(name), path = path, cover = abs(cover), summary = summary, author = author, status = "",
        genres = genres, total_chapters = total }, (cover or ""):match("/static/novels/([%w%-]+)/")
end

-- « Chapter 5: Chapter 5 Titre » -> « Chapter 5 Titre » ; numéro lu dans le titre
local function chap_name(n)
    n = dec(n or "")
    n = n:gsub("^[Cc]hapter%s+(%d+%.?%d*)%s*:%s*([Cc]hapter%s+%1)", "%2")
    return n
end
local function chap_num(n) return tonumber((n or ""):match("[Cc]hapter%s+(%d+%.?%d*)")) end

local function finish_chapters(ch)
    local sorted = #ch > 1
    local nums = {}
    for _, c in ipairs(ch) do
        if not c.num or nums[c.num] then sorted = false break end
        nums[c.num] = true
    end
    if sorted then table.sort(ch, function(a, b) return a.num < b.num end) end
    for i, c in ipairs(ch) do c.chapter_number = c.num or i; c.num = nil end
    return ch
end

local function html_chapters(html)
    local ch, seen = {}, {}
    for tag, body in html:gmatch("(<a%s[^>]->)(.-)</a>") do
        local href = attr(tag, "href")
        local id = href and href:match("/read/([%w%-]+)")
        if id and not seen[id] then
            local name = chap_name(txt(body))
            if name == "" then name = "Chapitre " .. (#ch + 1) end
            seen[id] = true
            ch[#ch + 1] = { name = name, path = "/read/" .. id, num = chap_num(name) }
        end
    end
    return ch
end

-- liste complète via /api/novel/<uuid>/chapters?offset=&limit= ; nil si l'API ne répond pas
local function api_chapters(nid)
    if not nid then return nil end
    local ch, seen = {}, {}
    local offset, total = 0, nil
    while true do
        local url = string.format("/api/novel/%s/chapters?offset=%d&limit=%d", nid, offset, CHAP_LIMIT)
        local body = get(url, true)
        local data = body and jdecode(body)
        if not data or type(data.items) ~= "table" then break end
        total = tonumber(data.total) or total
        local added = 0
        for _, c in ipairs(data.items) do
            local id = type(c) == "table" and pick(c, { "id" })
            if id and not seen[id] then
                seen[id] = true
                added = added + 1
                local name = chap_name(pick(c, { "title" }) or "")
                local n = tonumber(c.serial) or chap_num(name)
                if name == "" then name = "Chapitre " .. (n or (#ch + 1)) end
                ch[#ch + 1] = { name = name, path = "/read/" .. id, num = n }
            end
        end
        offset = offset + #data.items
        if added == 0 or #data.items == 0 or (total and offset >= total) then break end
    end
    return #ch > 0 and ch or nil
end

function ext:parseNovelMeta(path)
    local html = get(path); if not html then return nil end
    local m = meta(html, path)
    return m
end

function ext:parseNovel(path)
    local html = get(path); if not html then return nil end
    local m, nid = meta(html, path)
    local ch = html_chapters(html)
    local full = api_chapters(nid)
    if full and #full > #ch then
        ch = full
    elseif m.total_chapters > #ch then
        logger.warn("ScrollersPub: liste partielle (" .. #ch .. "/" .. m.total_chapters .. ")")
    end
    m.chapters, m.totalPages = finish_chapters(ch), 1
    return m
end

-- ===== Chapitre =====
function ext:parseChapter(path)
    local html = get(path); if not html then return "<p>Chapitre injoignable.</p>" end
    html = html:gsub("<script.-</script>", ""):gsub("<style.-</style>", "")
    -- conteneur #chapter-content ; repli : toute la page
    local scope = html
    local s, e = html:find('<div[^>]-id="chapter%-content"[^>]*>')
    if s then scope = inner(html, e + 1, "div") or html:sub(e + 1) end
    local ps, first = {}, true
    for p in scope:gmatch("<p%f[%s>][^>]*>(.-)</p>") do
        local body = p:gsub("<div[^>]*>%s*</div>", "")
        local t = txt(body)
        if t ~= "" then
            -- titre répété en tête (<h3>Chapter 1 …</h3>) : la liste des chapitres l'affiche déjà
            if first and body:find("<h3", 1, true) and t:match("^[Cc]hapter") then
                -- ignoré
            else
                ps[#ps + 1] = "<p>" .. body .. "</p>"
            end
            first = false
        end
    end
    if #ps == 0 then return "<p>Texte du chapitre introuvable (#chapter-content).</p>" end
    return table.concat(ps)
end

return ext