-- WoopRead — source générée par Sefirah Source Hub, puis réparée à la main (v0.1.1) : mode HTML (validé par le Hub) + recherche et avis par API.
-- Contrat : voir extensions/mangapill.lua du plugin Sefirah.
local logger = require("logger")
local BASE   = "https://woopread.com"
local LISTP  = "/series/"
local CHAPP  = "chapter-"
local CONT   = "space-y-4"
local UA = "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36"

local function get(p)
    local url = p:match("^https?://") and p or (BASE .. p)
    local body, code = require("core.net").get(url, { headers = { ["User-Agent"] = UA, ["Referer"] = BASE .. "/" }, timeout = 15 })
    if body and #body > 2 then return body end
    logger.warn("WoopRead: échec", url, tostring(code))
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
-- Couverture : Sefirah accepte plusieurs adresses séparées par une tabulation et essaie la suivante si la précédente échoue.
-- 1) l'optimiseur d'images du site lui-même (même domaine que le Referer, ~384 px donc léger ; sans « Accept: image/webp »
--    Next.js renvoie du JPEG, lisible partout) ; 2) l'image d'origine (WebP) sur le CDN.
local function cover_set(u)
    if not u or u == "" then return nil end
    if u:find("/_next/image", 1, true) then return u end
    return BASE .. "/_next/image?url=" .. enc(u) .. "&w=384&q=75" .. "\t" .. u
end
-- adresse d'image inutilisable (img/None, null, undefined…)
local function bad_cover(u)
    local last = (u:gsub("[?#].*$", ""):match("([^/]*)$") or ""):lower()
    return last == "" or last == "none" or last == "null" or last == "undefined" or last == "nan" or last == "false"
end
local function cover_of(img)
    if not img then return nil end
    for _, k in ipairs({ "data-src", "data-lazy-src", "data-original", "src", "srcset" }) do
        local u = attr(img, k)
        if k == "srcset" and u then u = u:match("^%s*(%S+)") end
        if u and u ~= "" and not u:match("^data:") and not u:lower():find("placeholder", 1, true) and not u:lower():find("blank", 1, true) and not bad_cover(u) then
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

-- conteneur du texte : parmi les éléments dont la classe contient cls, le plus interne qui garde presque tous les <p>
-- (une classe utilitaire comme « space-y-4 » sert aussi à la navigation et à la mise en page)
local function count_p(h) return select(2, h:gsub("<p[%s>]", "")) end
local function grab_text(html, cls)
    local cands, pos, best = {}, 1, 0
    while true do
        local s, e, tn, attrs = html:find("<(%a%w*)(%s[^>]*)>", pos)
        if not s then break end
        local c = attr(attrs, "class")
        if c and c:find(cls, 1, true) then
            local out = inner(html, e + 1, tn)
            if out and #out > 50 then
                local n = count_p(out)
                cands[#cands + 1] = { out = out, n = n }
                if n > best then best = n end
            end
        end
        pos = e + 1
    end
    if #cands == 0 then return nil end
    if best < 3 then return cands[1].out end
    local chosen
    for _, c in ipairs(cands) do
        if c.n >= best * 0.8 and (not chosen or #c.out < #chosen.out) then chosen = c end
    end
    return chosen.out
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
            local cover = cover_set(cover_of(img))
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
                if og and og ~= "" and not bad_cover(og) then it.cover = cover_set(abs(dec(og))) end
            end
        end
    end
    return res
end


-- ===== Filtres (page /browse du site : paramètres language, status, genres, page — lus dans initialFilters) =====
local function opts(list)
    local o = {}
    for _, p in ipairs(list) do o[#o + 1] = { id = p[1], label = p[2] } end
    return o
end
-- genres du site (allGenres), sans « Adult » ni « Smut »
local GENRE_NAMES = { "Action", "Adventure", "Comedy", "Drama", "Ecchi", "Fantasy", "Gender Bender", "Harem", "Historical",
    "Horror", "Josei", "Martial Arts", "Mature", "Mecha", "Mystery", "Psychological", "Romance", "School Life", "Sci-fi",
    "Seinen", "Shoujo", "Shoujo Ai", "Shounen", "Shounen Ai", "Slice of Life", "Sports", "Supernatural", "Tragedy",
    "Wuxia", "Xianxia", "Xuanhuan", "Yaoi", "Yuri" }
local GENRE_OPTS = { { "Any", "Tous" } }
for _, g in ipairs(GENRE_NAMES) do GENRE_OPTS[#GENRE_OPTS + 1] = { g, g } end

local FILTERS = {
    { key = "language", label = "Langue", default = "Any",
      options = opts({ { "Any", "Toutes" }, { "Korean", "Coréen" }, { "Chinese", "Chinois" }, { "Original", "Original" } }) },
    { key = "status", label = "Statut", default = "Any",
      options = opts({ { "Any", "Tous" }, { "Ongoing", "En cours" }, { "Completed", "Terminé" }, { "Dropped", "Abandonné" } }) },
    { key = "genre", label = "Genre", default = "Any", options = opts(GENRE_OPTS) },
}

local function build_query(filters, page)
    local q = {}
    filters = filters or {}
    for _, k in ipairs({ "language", "status" }) do
        local v = tostring(filters[k] or "")
        if v ~= "" and v ~= "Any" then q[#q + 1] = k .. "=" .. enc(v) end
    end
    local g = tostring(filters.genre or "")
    if g ~= "" and g ~= "Any" then q[#q + 1] = "genres=" .. enc(g) end
    if page > 1 then q[#q + 1] = "page=" .. page end
    return #q > 0 and ("?" .. table.concat(q, "&")) or ""
end

local ext = { id = "woopread", name = "WoopRead", site = BASE, lang = "en", version = "0.2.0",
    popularFilters = FILTERS, searchFilters = FILTERS, hasReviews = true, maxReviews = 150, chapterCommentsPanel = false }

-- liste : /browse (20 romans par page, « Page 1 of 5 » dans le HTML)
function ext:popularNovels(page, options)
    local pg = math.max(tonumber(page) or 1, 1)
    local html, err = get(BASE .. "/browse" .. build_query(options and options.filters, pg))
    if not html then
        if pg > 1 then return { novels = {} } end
        return { novels = {}, error = "Site injoignable (" .. tostring(err) .. ")" }
    end
    local cur, total = html:match("Page <!%-%- %-%->(%d+)<!%-%- %-%-> of <!%-%- %-%->(%d+)")
    -- au-delà de la dernière page, le site peut renvoyer la dernière page : on s'arrête
    if (cur and tonumber(cur) < pg) or (total and pg > tonumber(total)) then return { novels = {} } end
    return { novels = parse_list(html) }
end

local BS = string.char(92)
-- le flux Next.js (self.__next_f.push) échappe les guillemets : on les rétablit pour lire le JSON embarqué
local function rsc_text(html) return (html:gsub(BS .. '"', '"')) end

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
    cv = cover_set(cv)
    -- og:description est mutilée par le site (« pFrom … strongTitre:/strong/ppSuite…/p », chevrons perdus) :
    -- on lit plutôt le bloc de description affiché dans la page
    local ds, de = html:find('<div[^>]-id="novel%-description%-content"[^>]*>')
    local full = ds and inner(html, de + 1, "div")
    if full then
        local d = para(full)
        if #d > 10 then summary = d end
    elseif summary:match("^p%u") and summary:sub(-2) == "/p" then -- repli : réparer la version mutilée
        summary = summary:sub(2, -3):gsub("/pp(%u)", "\n\n%1"):gsub("/strong", ""):gsub("strong(%u)", "%1")
    end
    local function labelled(label, tag)
        return html:match(label .. "<!%-%- %-%->:</span>%s*<" .. tag .. "[^>]*>([^<]+)</" .. tag .. ">")
    end
    local author = labelled("Author", "a") or ogp("og:novel:author")
    local status = labelled("Status", "span") or ogp("og:novel:status")
    -- genres (liens /browse?genres=) puis tags complets (liste JSON du flux Next.js)
    local genres, seen_g = {}, {}
    local function add_g(g) g = dec(g); if g ~= "" and not seen_g[g] then seen_g[g] = true; genres[#genres + 1] = g end end
    for g in html:gmatch('href="/browse%?genres=[^"]*"><div[^>]*>([^<]+)</div>') do add_g(g) end
    local tl = rsc_text(html):match('"tags":%[(.-)%],"initialVisibleTags"')
    if tl then for t in tl:gmatch('"([^"]+)"') do add_g(t) end end
    return { name = name, path = path, cover = cv, summary = summary, author = author or "", status = status or "", genres = genres }
end

function ext:parseNovelMeta(path)
    local html = get(path); if not html then return nil end
    local m = meta(html, path); m.total_chapters = 0; return m
end

function ext:parseNovel(path)
    local html = get(path); if not html then return nil end
    local m, ch, seen = meta(html, path), {}, {}
    -- liste complète des chapitres dans le JSON embarqué (le HTML peut n'en afficher qu'un groupe)
    do
        local base, got = (path:gsub("/+$", "")), {}
        for title, num, slug in rsc_text(html):gmatch('{"id":"[^"]*","title":"(.-)","number":([%d%.]+),"slug":"([^"]+)"') do
            local n = tonumber(num)
            if n and not got[slug] then
                got[slug] = true
                ch[#ch + 1] = { name = dec(title), path = base .. "/" .. slug, chapter_number = n }
            end
        end
        if #ch > 0 then
            table.sort(ch, function(a, b) return a.chapter_number < b.chapter_number end)
            m.chapters, m.totalPages = ch, 1
            return m
        end
    end
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
    local body = CONT ~= "" and grab_text(html, CONT) or nil
    -- 2) repli : tous les paragraphes <p> de la page
    if not body then
        local ps, n = {}, 0
        for p in html:gmatch("<p%f[%s>][^>]*>(.-)</p>") do
            local t = txt(p)
            if #t > 1 then ps[#ps+1] = "<p>" .. p .. "</p>"; n = n + #t end
        end
        if #ps >= 3 and n > 300 then body = table.concat(ps) end
    end
    if body then -- titre doublé en tête (Chapter 5: Chapter 5 Titre) : on retire le premier, sur les 700 premiers caractères seulement
        local head, tail = body:sub(1, 700), body:sub(701)
        head = head:gsub("[Cc]hapter%s+(%d+[%.%-]?%d*)%s*:%s*(<?[^<]-[Cc]hapter%s+%1)", "%2", 1)
        body = head .. tail
    end
    if not body or #body < 50 then return "<p>Texte du chapitre introuvable (classe « " .. CONT .. " »).</p>" end
    return body
end

-- ===== Recherche par API JSON (validée par le Hub : /api/search?q={q}) =====
-- Le mode Next.js généré a été retiré : ses clés étaient vides, il écrasait les fonctions HTML qui, elles, fonctionnent.
local API_SEARCH = "/api/search?q={q}"
local function jdecode(str)
    local ok_j, J = pcall(require, "rapidjson")
    if not ok_j then J = require("json") end
    local ok, d = pcall(J.decode, str)
    if ok then return d end
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

function ext:searchNovels(term, page, options)
    term = tostring(term or ""):match("^%s*(.-)%s*$")
    if term == "" then return ext:popularNovels(page, options) end -- sans texte : liste filtrée
    if page and page > 1 then return { novels = {} } end -- la recherche par API tient en une page (filtres ignorés)
    local body = get((API_SEARCH:gsub("{q}", function() return enc(term) end)))
    local data = body and jdecode(body)
    if type(data) ~= "table" then return { novels = {}, error = "Recherche impossible" } end
    if not data[1] then
        local inner_list = data.novels or data.results or data.items
        if type(inner_list) == "table" then data = inner_list end
    end
    local out, seen = {}, {}
    for _, n in ipairs(data) do
        local slug = pick(n, { "slug" })
        if slug and not seen[slug] then
            seen[slug] = true
            out[#out + 1] = { name = dec(pick(n, { "title", "name" }) or slug),
                path = (LISTP:gsub("/+$", "")) .. "/" .. slug,
                cover = cover_set(abs(pick(n, { "coverImage", "cover", "coverUrl", "image", "thumbnail" }))) }
        end
    end
    return { novels = out }
end

-- ===== Avis (commentaires des lecteurs), détectés par le Hub : mode json =====
local RV_MODE = "json"
local RV_URL  = "/api/novels/{id}/reviews"
local RV_CLS  = ""
local RV_IDM  = "novelId"
local function rv_json(s)
    local ok, J = pcall(require, "rapidjson")
    if not ok then J = require("json") end
    local ok2, v = pcall(J.decode, s)
    if ok2 and type(v) == "table" then return v end
    return nil
end
local function rv_s(v)
    if type(v) == "table" and v.rendered then v = v.rendered end
    if type(v) == "string" or type(v) == "number" then
        local t = tostring(v)
        if t:match("%S") then return t end
    end
    return nil
end
local function rv_pick(o, keys)
    if type(o) ~= "table" then return nil end
    for _, k in ipairs(keys) do
        local t = rv_s(o[k])
        if t then return t end
    end
    return nil
end
local function rv_item(c)
    if type(c) ~= "table" then return nil end
    local body = rv_pick(c, { "content", "body", "text", "comment", "message" })
    body = body and para(body)
    if not body or #body < 2 then return nil end
    local a = c.author
    local name = type(a) == "table" and rv_pick(a, { "username", "name", "display_name" }) or rv_s(a)
    name = name or rv_pick(c, { "author_name", "username", "user_name", "name" }) or rv_pick(c.user, { "username", "name" })
    local av = type(a) == "table" and rv_pick(a, { "avatar", "avatar_url" }) or nil
    if not av and type(c.author_avatar_urls) == "table" then av = rv_s(c.author_avatar_urls["96"]) or rv_s(c.author_avatar_urls["48"]) end
    local re = type(c.reactions) == "table" and c.reactions or {}
    return { id = rv_pick(c, { "id" }), author = name or "Anonyme", content = body,
        avatar = av and abs(av) or nil, date = rv_pick(c, { "date", "createdAt", "created_at", "publishedAt" }),
        rating = tonumber(c.rating), likes = tonumber(re.like or c.likes or c.upvotes) or 0,
        dislikes = tonumber(re.dislike or c.dislikes or c.downvotes) or 0 }
end
-- mode page : chaque élément dont la classe contient RV_CLS est un avis
local function rv_page(html)
    local out, pos = {}, 1
    while #out < 150 do
        local s, e, tn, attrs = html:find("<(%a%w*)(%s[^>]*)>", pos)
        if not s then break end
        local cl = attr(attrs, "class")
        local blk = cl and cl:find(RV_CLS, 1, true) and inner(html, e + 1, tn) or nil
        if blk and #blk > 25 then
            local who = blk:match('class="[^"]*author[^"]*"[^>]*>(.-)</') or blk:match('class="[^"]*user[^"]*"[^>]*>(.-)</') or blk:match('class="[^"]*name[^"]*"[^>]*>(.-)</')
            local what = blk:match('class="[^"]*content[^"]*"[^>]*>(.-)</div>') or blk:match('class="[^"]*text[^"]*"[^>]*>(.-)</div>') or blk
            what = para(what)
            local nm = who and txt(who) or ""
            if #what > 2 then
                out[#out + 1] = { author = nm ~= "" and nm or "Anonyme", content = what,
                    date = blk:match('<time[^>]-datetime="([^"]*)"'), likes = 0, dislikes = 0 }
            end
            pos = e + #blk + 1
        else
            pos = e + 1
        end
    end
    return out
end

-- id interne de l'œuvre lu dans la fiche (même règle que le Hub : 8 à 40 caractères alphanumériques)
local function rv_find_id(fiche)
    if RV_IDM == "next" then
        local from = fiche:find("initialNovel", 1, true)
        if not from then return nil end
        for cand in fiche:sub(from):gmatch("[^%w]id[^%w]+(%w+)") do
            if #cand >= 8 and #cand <= 40 then return cand end
        end
    elseif RV_IDM == "novelId" then
        for cand in fiche:gmatch("novelId[^%w]+(%w+)") do
            if #cand >= 8 and #cand <= 40 then return cand end
        end
    end
    return nil
end

function ext:parseReviews(path, page, sort)
    local pg = page or 1
    if pg > 1 and not RV_URL:find("{page}", 1, true) then return { reviews = {}, has_more = false } end
    local p = path:gsub("/+$", "")
    local items = {}
    local more = false
    if RV_MODE == "page" then
        local html = get((RV_URL:gsub("{path}", function() return p end)))
        if not html then return { reviews = {}, has_more = false, error = true } end
        items = rv_page(html)
    else
        local u
        if RV_MODE == "wp" then
            local fiche = get(p)
            local id = fiche and (fiche:match("[?&]p=(%d+)%f[^%d]") or fiche:match("postid%-(%d+)") or fiche:match("data%-post%-id=.(%d+)") or fiche:match("wp%-json/wp/v2/[%w_%-]+/(%d+)"))
            if not id then return { reviews = {}, has_more = false } end
            u = (RV_URL:gsub("{id}", id))
        else
            local slug = p:match("([^/]+)$") or ""
            u = RV_URL
            if u:find("{id}", 1, true) then
                local fiche = get(p)
                local nid = fiche and rv_find_id(fiche)
                if not nid then return { reviews = {}, has_more = false } end
                u = (u:gsub("{id}", function() return nid end))
            end
            u = (u:gsub("{slug}", function() return slug end))
            u = (u:gsub("{page}", function() return tostring(pg) end))
        end
        local body = get(u)
        local data = body and rv_json(body)
        if not data then return { reviews = {}, has_more = false, error = true } end
        local list = data
        if data.hasMore == true then more = true end
        for _, k in ipairs({ "comments", "reviews", "results", "data", "items" }) do
            if type(data[k]) == "table" then list = data[k]; break end
        end
        for _, c in ipairs(list) do
            local ok, it = pcall(rv_item, c)
            if ok and it then items[#items + 1] = it end
        end
        table.sort(items, function(a, b)
            if sort == "mostliked" and a.likes ~= b.likes then return a.likes > b.likes end
            local x, y = a.date or "", b.date or ""
            if x ~= y then
                if sort == "oldest" then return x < y end
                return x > y
            end
            return false
        end)
    end
    return { reviews = items, has_more = more }
end

return ext
