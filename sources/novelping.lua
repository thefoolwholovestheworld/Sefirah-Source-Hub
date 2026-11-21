-- NovelPing — source générée par Sefirah Source Hub (modèle sans IA), puis corrigée à la main (v0.4.0).
-- v0.4.1 : avis lus via /api-web/novels/{slug}/comments (portée all, tris latest / most-liked / oldest).
-- v0.4.0 : filtres avancés (genres, tags, statut, langue, chapitres, années, exclusions, tri) + avis réparés.
-- Contrat : voir extensions/mangapill.lua du plugin Sefirah.
local logger = require("logger")
local BASE   = "https://novelping.com"
local LISTP  = "/book/"
local CHAPP  = "/book/"
local CONT   = "chapter"
local UA = "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36"

local function get(p)
    local url = p:match("^https?://") and p or (BASE .. p)
    local body, code = require("core.net").get(url, { headers = { ["User-Agent"] = UA, ["Referer"] = BASE .. "/", ["X-Requested-With"] = "XMLHttpRequest", ["Accept"] = "application/json, text/html, */*" }, timeout = 15 })
    if body and #body > 2 then return body end
    logger.warn("NovelPing: échec", url, tostring(code))
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
    -- la barre latérale (« Genres », « Hot Novel ») vient après la vraie liste : on la coupe
    local cut = html:find("<h%d[^>]*>%s*Genres%s*</h%d>")
    if cut and cut > 1500 then html = html:sub(1, cut - 1) end
    -- couvertures indexées par nom de fichier (= slug de l'œuvre) : l'<img> n'est pas toujours dans le lien du titre
    -- (v0.4.0 : on retire d'abord ?v=… sinon les couvertures versionnées n'étaient jamais retrouvées)
    local covers = {}
    for img in html:gmatch("<img[^>]->") do
        local c = cover_of(img)
        local fname = c and (c:gsub("[?#].*$", "")):match("/novel[^/]*/([^/]+)%.%w+$")
        if fname then covers[fname:lower()] = c end
    end
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
            local cover = cover_of(img) or covers[((k:match("([^/]+)$")) or ""):lower()]
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

-- ===== FILTRES =====
-- Sans filtre avancé : liste /sort/{liste}. Dès qu'un filtre avancé est choisi : /search?genres=…&tags=…&status=…
-- (mêmes paramètres que le formulaire « Advanced Search » du site).
local BROWSE = "https://novelping.com/sort/{sort}?sort={order}&page={page}"
local FJOIN  = {  }

local function title_case(s) return (s:lower():gsub("^%l", string.upper)) end
local function mk(list, all)
    local t = {}
    if all then t[1] = { id = "all", label = "Tous" } end
    for _, v in ipairs(list) do t[#t + 1] = { id = v, label = title_case(v) } end
    return t
end
local function mk_num(list, none_label)
    local t = { { id = "all", label = none_label } }
    for _, v in ipairs(list) do t[#t + 1] = { id = tostring(v), label = tostring(v) } end
    return t
end
local function years()
    local t = {}
    for y = 2026, 2008, -1 do t[#t + 1] = y end
    return t
end

local GENRES = { "ACTION", "ADULT", "ADVENTURE", "ANIME & COMICS", "COMEDY", "DRAMA", "EASTERN", "ECCHI", "FAN-FIC",
    "FAN-FICTION", "FANTASY", "GAME", "GENDER BENDER", "GENERAL", "HAREM", "HISTORICAL", "HORROR", "ISEKAI", "JOSEI",
    "LGBT+", "LITRPG", "MAGIC", "MAGICAL REALISM", "MARTIAL ARTS", "MATURE", "MECHA", "MILITARY", "MODERN LIFE",
    "MYSTERY", "PSYCHOLOGICAL", "REALISTIC", "REINCARNATION", "ROMANCE", "SCHOOL LIFE", "SCI-FI", "SEINEN", "SHOUJO",
    "SHOUJO AI", "SHOUNEN", "SHOUNEN AI", "SLICE OF LIFE", "SMUT", "SPORTS", "SUPERNATURAL", "SYSTEM", "THRILLER",
    "TRAGEDY", "URBAN", "VIDEO GAMES", "WAR", "WUXIA", "XIANXIA", "XUANHUAN", "YAOI", "YURI" }
-- Sélection de tags courants (le site en compte plus de 900 : ajoutez-en ici si besoin, en MAJUSCULES comme sur le site)
local TAGS = { "ABILITY STEAL", "ACADEMY", "ADOPTED PROTAGONIST", "ALCHEMY", "ALTERNATE WORLD", "ANCIENT CHINA",
    "ANTIHERO PROTAGONIST", "APOCALYPSE", "ARRANGED MARRIAGE", "ARTIFACTS", "ASSASSINS", "BASED ON A VIDEO GAME",
    "BEAST TAMING", "BETRAYAL", "BILLIONAIRE", "BODY CULTIVATION", "BUSINESS MANAGEMENT", "CALM PROTAGONIST", "CHEATS",
    "CLEVER PROTAGONIST", "COLD PROTAGONIST", "COMEDIC UNDERTONE", "COMING OF AGE", "CULTIVATION", "DARK FANTASY",
    "DEMON LORD", "DEMONS", "DRAGONS", "DUNGEON CRAWLING", "DUNGEONS", "ELVES", "ENEMIES BECOME LOVERS", "EVOLUTION",
    "FAMILY", "FANFICTION", "FANTASY WORLD", "FEMALE PROTAGONIST", "FIRST LOVE", "FORCED MARRIAGE", "FRIENDSHIP",
    "GAME ELEMENTS", "GENIUS PROTAGONIST", "GODS", "GOLDEN FINGER", "GUILDS", "HAREM", "HIDDEN IDENTITY", "HISTORY",
    "ISEKAI", "KINGDOM BUILDING", "LEVEL SYSTEM", "LITRPG", "LOVE TRIANGLES", "MAGIC", "MAGIC ACADEMY",
    "MALE PROTAGONIST", "MEDIEVAL", "MODERN DAY", "MONSTERS", "MULTIPLE REALMS", "MURIM", "NOBLES",
    "OVERPOWERED PROTAGONIST", "PILL CONCOCTING", "POLITICS", "POWER COUPLE", "PROGRESSION", "REBIRTH", "REGRESSION",
    "REINCARNATION", "REVENGE", "ROMANCE SUBPLOT", "RUTHLESS PROTAGONIST", "SCHEMING PROTAGONIST", "SECRET IDENTITY",
    "SLOW BURN", "STRONG TO STRONGER", "SURVIVAL", "SWORD AND MAGIC", "SYSTEM", "TIME TRAVEL", "TOWER CLIMBING",
    "TRAGIC PAST", "TRANSMIGRATION", "UNDERESTIMATED PROTAGONIST", "URBAN FANTASY", "VAMPIRES", "VILLAINESS",
    "WAR AND MILITARY", "WEAK TO STRONG", "WIZARDS", "WORLD HOPPING", "ZERO TO HERO" }
local TAGS_EXCLUDE = { "HAREM", "REVERSE HAREM", "R-18", "SEXUAL CONTENT", "INCEST", "RAPE", "NETORARE", "GORE", "TORTURE",
    "CHEATING", "SLAVES" }

local MODE_OPTS = { { id = "AND", label = "Tous à la fois (ET)" }, { id = "OR", label = "Au moins un (OU)" } }

local ALL_FILTERS = {
    { key = "sort", label = "Liste", default = "updates", multi = false,
      options = {
        { id = "updates", label = "Latest Release" },
        { id = "hot", label = "Hot Novel" },
        { id = "complete", label = "Completed Novel" },
        { id = "popular", label = "Most Popular" },
      } },
    { key = "order", label = "Tri", default = "all", multi = false,
      options = {
        { id = "all", label = "Dernière mise à jour" },
        { id = "NEW", label = "Récemment ajoutés" },
        { id = "ALL_TIME", label = "Plus vus" },
        { id = "POPULAR", label = "Populaires cette semaine" },
        { id = "RATING", label = "Mieux notés" },
        { id = "CHAPTERS", label = "Plus de chapitres" },
      } },
    { key = "genres", label = "Genres", default = "", multi = true, options = mk(GENRES) },
    { key = "genre_mode", label = "Genres : combinaison", default = "AND", multi = false, options = MODE_OPTS },
    { key = "tags", label = "Tags", default = "", multi = true, options = mk(TAGS) },
    { key = "tag_mode", label = "Tags : combinaison", default = "AND", multi = false, options = MODE_OPTS },
    { key = "genres_exclude", label = "Genres exclus", default = "", multi = true, options = mk(GENRES) },
    { key = "tags_exclude", label = "Tags exclus", default = "", multi = true, options = mk(TAGS_EXCLUDE) },
    { key = "status", label = "Statut", default = "all", multi = false,
      options = { { id = "all", label = "Tous" }, { id = "ongoing", label = "En cours" }, { id = "completed", label = "Terminés" } } },
    { key = "language", label = "Langue", default = "all", multi = false,
      options = { { id = "all", label = "Toutes" }, { id = "EN", label = "Anglais" }, { id = "CN", label = "Chinois" },
                  { id = "JP", label = "Japonais" }, { id = "KR", label = "Coréen" } } },
    { key = "min_chapters", label = "Chapitres minimum", default = "all", multi = false,
      options = mk_num({ 50, 100, 200, 300, 500, 1000, 2000, 3000 }, "Aucun") },
    { key = "max_chapters", label = "Chapitres maximum", default = "all", multi = false,
      options = mk_num({ 100, 200, 300, 500, 1000, 2000, 3000 }, "Aucun") },
    { key = "start_year", label = "Année de début", default = "all", multi = false, options = mk_num(years(), "Aucune") },
    { key = "end_year", label = "Année de fin", default = "all", multi = false, options = mk_num(years(), "Aucune") },
}
local POPULAR_FILTERS = ALL_FILTERS
local SEARCH_FILTERS = {}
for _, f in ipairs(ALL_FILTERS) do if f.key ~= "sort" then SEARCH_FILTERS[#SEARCH_FILTERS + 1] = f end end

local ADV_KEYS = { "genres", "tags", "genres_exclude", "tags_exclude", "status", "language",
    "min_chapters", "max_chapters", "start_year", "end_year" }

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
    if type(v) == "table" then v = table.concat(v, ",") end
    if v == nil or v == "" or v == "all" then return nil end
    return tostring(v)
end
local function list_of(v)
    local t = {}
    if not v then return t end
    for x in v:gmatch("[^,]+") do t[#t + 1] = x end
    return t
end
local function has_adv(sel)
    for _, k in ipairs(ADV_KEYS) do if fval(sel, k) then return true end end
    return false
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

-- adresse de la recherche avancée du site (paramètres répétés : genres=A&genres=B, comme le formulaire)
local function adv_url(page, sel, term, is_search)
    local ps = {}
    local function add(k, v) ps[#ps + 1] = k .. "=" .. enc(v) end
    if term and term ~= "" then add("keyword", term) end
    local g = list_of(fval(sel, "genres"))
    for _, x in ipairs(g) do add("genres", x) end
    if #g > 1 then add("genre_mode", fval(sel, "genre_mode") or "AND") end
    local t = list_of(fval(sel, "tags"))
    for _, x in ipairs(t) do add("tags", x) end
    if #t > 1 then add("tag_mode", fval(sel, "tag_mode") or "AND") end
    for _, x in ipairs(list_of(fval(sel, "genres_exclude"))) do add("genres_exclude", x) end
    for _, x in ipairs(list_of(fval(sel, "tags_exclude"))) do add("tags_exclude", x) end
    for _, k in ipairs({ "min_chapters", "max_chapters", "start_year", "end_year" }) do
        local v = fval(sel, k)
        if v then add(k, v) end
    end
    local st = fval(sel, "status")
    if st then add("status", st) end
    local lg = fval(sel, "language")
    if lg then add("language", lg:upper()) end
    local o = fval(sel, "order")
    if o == nil then
        if not is_search then o = "LASTEST" end
    elseif o == "POPULAR" then
        o = nil -- « Popular this week » = pas de paramètre sort
    end
    if o then add("sort", o) end
    if page and page > 1 then add("page", tostring(page)) end
    return BASE .. "/search" .. (#ps > 0 and ("?" .. table.concat(ps, "&")) or "")
end

local function browse_url(page, options)
    local sel = {}
    for k, v in pairs((options and options.filters) or {}) do sel[k] = v end
    -- aucun choix de l'utilisateur : valeurs par défaut des filtres
    for _, f in ipairs(POPULAR_FILTERS) do
        if sel[f.key] == nil or sel[f.key] == "" then sel[f.key] = f.default end
    end
    if has_adv(sel) then return adv_url(page, sel, "", false) end
    return expand(BROWSE, sel, "", page)
end

local ext = { id = "novelping", name = "NovelPing", site = BASE, lang = "en", version = "0.4.1",
    popularFilters = POPULAR_FILTERS, searchFilters = SEARCH_FILTERS, hasReviews = true, maxReviews = 150, chapterCommentsPanel = false }

function ext:popularNovels(page, options)
    local html, err = get(browse_url(page, options))
    if not html then return { novels = {}, error = "Site injoignable (" .. tostring(err) .. ")" } end
    return { novels = parse_list(html) }
end

function ext:searchNovels(term, page, options)
    term = tostring(term or ""):match("^%s*(.-)%s*$")
    if term == "" then return ext:popularNovels(page, options) end
    local sel = (options and options.filters) or {}
    local html, err = get(adv_url(page, sel, term, true))
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
        for _, k in ipairs({ "synopsis", "summary", "description", "desc-text", "novel-intro", "book-intro", "book-desc", "resume", "intro", "story", "desc" }) do
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
    -- retire le bouton « See more » / « See less » capturé avec la description
    summary = summary:gsub("%s*See more[^%w]*$", ""):gsub("%s*See less[^%w]*$", ""):gsub("%s+$", "")
    local function ogp(p) return dec(html:match('property="' .. p .. '"[^>]-content="([^"]*)"') or html:match('content="([^"]*)"[^>]-property="' .. p .. '"') or "") end
    local cv = abs(dec(html:match('property="og:image"[^>]-content="([^"]*)"')))
    if cv and bad_cover(cv) then cv = nil end
    local cat = ogp("og:novel:genre")
    local gl = {}
    for g in cat:gmatch("[^,]+") do gl[#gl + 1] = (g:lower():gsub("^%l", string.upper)) end
    return { name = name, path = path, cover = cv,
        summary = summary, author = ogp("og:novel:author"), status = ogp("og:novel:status"), genres = gl }
end

function ext:parseNovelMeta(path)
    local html = get(path); if not html then return nil end
    local m = meta(html, path); m.total_chapters = 0; return m
end

-- ajoute à "ch" les liens de chapitres de CETTE œuvre (les autres œuvres citées en barre latérale sont ignorées)
local function add_chapters(html, ch, seen, slug)
    for tag, inner_html in html:gmatch("(<a%s[^>]->)(.-)</a>") do
        local href = attr(tag, "href")
        href = href and dec(href)
        local hk = href and norm(href) or ""
        local is_listlink = hk:match("/chapters?$") or hk:match("/chapter%-?list$") or hk:match("/toc$") or hk:match("/reviews?$") or hk:match("/comments?$")
        if href and not is_listlink and is_chap(href) and (not slug or hk:find("/book/" .. slug .. "/", 1, true)) then
            local k = norm(href)
            local name = txt(inner_html)
            if name == "" then name = dec(attr(tag, "title") or "") end
            if seen[k] then -- même chapitre vu plusieurs fois : on garde le titre le plus long
                if #name > #seen[k].name then seen[k].name = name end
            else
                if name == "" then name = "Chapitre " .. (#ch + 1) end
                seen[k] = { name = name, path = rel(href) }
                ch[#ch+1] = seen[k]
            end
        end
    end
end

-- parcourt une page de liste de chapitres et ses pages suivantes (?page=N), 40 pages au maximum
local function crawl_list(url, ch, seen, slug)
    url = url:gsub("[?&]page=%d+", "")
    local first = get(url)
    if not first then return end
    add_chapters(first, ch, seen, slug)
    local maxp = 1
    for n in first:gmatch("[?&]page=(%d+)") do
        local v = tonumber(n)
        if v and v > maxp then maxp = v end
    end
    if maxp > 40 then maxp = 40 end
    for pg = 2, maxp do
        local u = url .. (url:find("?", 1, true) and "&" or "?") .. "page=" .. pg
        local h = get(u)
        if not h then break end
        local before = #ch
        add_chapters(h, ch, seen, slug)
        if #ch == before then break end
    end
end

-- numéro d'un chapitre d'après son adresse : chapter-662-479-titre -> 662 ; 532-7-70-titre -> 532
local function chap_num(p)
    local k = norm(p):match("/book/[^/]+/(.+)$") or ""
    return tonumber(k:match("^chapter[%-_]?(%d+)") or k:match("^(%d+)") or k:match("chapter[%-_]?(%d+)"))
end

function ext:parseNovel(path)
    local html = get(path); if not html then return nil end
    local m, ch, seen = meta(html, path), {}, {}
    local slug = norm(path):match("/book/([^/]+)")
    add_chapters(html, ch, seen, slug)
    -- la fiche ne montre que quelques chapitres : on cherche la vraie liste (lien « chapters », « all chapters »…)
    local listurl
    if slug then
        for tag in html:gmatch("<a%s[^>]->") do
            local href = attr(tag, "href")
            href = href and dec(href)
            if href then
                local k = norm(href)
                if k:match("/book/" .. slug .. "/chapters?$") or k:match("/book/" .. slug .. "/chapter%-?list$") or k:match("/book/" .. slug .. "/toc$") then
                    listurl = abs(href); break
                end
            end
        end
    end
    -- la fiche n'affiche que les 30 premiers chapitres : le reste est chargé par le site via /ajax/chapter-archive
    local got_ajax = false
    if slug then
        for _, u in ipairs({ BASE .. "/ajax/chapter-archive?novelId=" .. slug, BASE .. "/ajax/chapter-list?novelId=" .. slug }) do
            local okA, h = pcall(get, u)
            if okA and h then
                local before = #ch
                add_chapters(h, ch, seen, slug)
                if #ch > before + 5 then got_ajax = true; break end
            end
        end
    end
    if got_ajax then
        -- liste complète obtenue
    elseif listurl then
        crawl_list(listurl, ch, seen, slug)
    elseif #ch < 6 and slug then -- repli : adresse la plus courante pour la liste complète
        pcall(crawl_list, BASE .. "/book/" .. slug .. "/chapters", ch, seen, slug)
    end
    -- tri : numéro lu dans l'adresse quand il est unique pour chaque chapitre, sinon ordre de la page
    local sorted = #ch > 1
    local nums = {}
    for _, c in ipairs(ch) do
        local n = chap_num(c.path)
        if not n or nums[n] then sorted = false break end
        nums[n] = true; c.n = n
    end
    if sorted then
        table.sort(ch, function(a, b) return a.n < b.n end)
    elseif #ch > 1 then
        -- numéros non uniques : on inverse seulement si la page liste du plus récent au plus ancien
        local a, b = chap_num(ch[1].path), chap_num(ch[#ch].path)
        if a and b and a > b then
            for i = 1, math.floor(#ch/2) do ch[i], ch[#ch+1-i] = ch[#ch+1-i], ch[i] end
        end
    end
    for i, c in ipairs(ch) do c.chapter_number = i end
    m.chapters, m.totalPages = ch, 1
    return m
end

function ext:parseChapter(path)
    local html = get(path); if not html then return "<p>Chapitre injoignable.</p>" end
    html = html:gsub("<script.-</script>", ""):gsub("<style.-</style>", "")
    -- 1) le conteneur de classe CONT (balise quelconque, <div> imbriquées gérées)
    local body
    for _, k in ipairs({ "chapter-content", "chapter_content", "chapter-text", "reading-content", "chr-c", CONT }) do
        if k ~= "" then body = grab(html, k); if body then break end end
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
    if body then -- titre doublé en tête (Chapter 5: Chapter 5 Titre) : on retire le premier, sur les 700 premiers caractères seulement
        local head, tail = body:sub(1, 700), body:sub(701)
        head = head:gsub("[Cc]hapter%s+(%d+[%.%-]?%d*)%s*:%s*(<?[^<]-[Cc]hapter%s+%1)", "%2", 1)
        body = head .. tail
    end
    if not body or #body < 50 then return "<p>Texte du chapitre introuvable (classe « " .. CONT .. " »).</p>" end
    return body
end

-- ===== Avis (commentaires des lecteurs) =====
local RV_MODE = "novelping"
local RV_URL  = "{path}"
local RV_CLS  = "comment-editor"
local RV_IDM  = ""
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

-- NovelPing : les commentaires sont chargés en JSON {html, pagination} puis affichés en cartes « comment-card »
local function np_tag(html, cls)
    local pos = 1
    while true do
        local s, e, tn, attrs = html:find("<(%a%w*)(%s[^>]*)>", pos)
        if not s then return nil end
        local c = attr(attrs, "class")
        if c and (" " .. c .. " "):find(" " .. cls .. " ", 1, true) then return inner(html, e + 1, tn) end
        pos = e + 1
    end
end
local function np_cards(html)
    local out, pos, seen = {}, 1, {}
    while #out < 150 do
        local s, e, tn, attrs = html:find("<(%a%w*)(%s[^>]*)>", pos)
        if not s then break end
        local c = attr(attrs, "class")
        if c and (" " .. c .. " "):find(" comment-card ", 1, true) and (" " .. c .. " "):find(" main-comment ", 1, true) then
            local cid = attr(attrs, "data-id") or attr(attrs, "data-comment-id")
            if not (cid and seen[cid]) then
                if cid then seen[cid] = true end
                local blk = inner(html, e + 1, tn) or ""
                local body = np_tag(blk, "comment-content")
                local who = np_tag(blk, "username")
                if body then
                    body = para(body)
                    if #body > 1 then
                        out[#out + 1] = { id = cid, author = who and txt(who) or "Anonyme", content = body,
                            date = blk:match('<time[^>]-datetime="([^"]*)"'), likes = tonumber(blk:match('like%-count[^>]*>(%d+)')) or 0,
                            dislikes = tonumber(blk:match('dislike%-count[^>]*>(%d+)')) or 0 }
                    end
                end
            end
        end
        pos = e + 1
    end
    return out
end
-- repli : les 4 commentaires « Hot » affichés sur la fiche
local function np_hot(fiche)
    local out = {}
    for blk in fiche:gmatch('<li class="comment%-hot__card">(.-)</li>') do
        local body = blk:match('class="comment%-hot__text"[^>]*>(.-)</a>')
        if body then
            out[#out + 1] = { author = txt(blk:match('comment%-hot__name">(.-)</span>') or "Anonyme"), content = para(body),
                date = blk:match('datetime="([^"]*)"'), likes = tonumber(blk:match('thumbs%-up[^>]*></span>%s*(%d+)')) or 0, dislikes = 0 }
        end
    end
    return out
end

-- élément JSON de l'API /api-web (auteur = user.account ou disqusUser.name, uniquement les commentaires racines)
local function np_item(c)
    if type(c) ~= "table" then return nil end
    local body = type(c.content) == "string" and para(c.content) or nil
    if not body or #body < 1 then return nil end
    local who = (type(c.user) == "table" and rv_s(c.user.account)) or (type(c.disqusUser) == "table" and rv_s(c.disqusUser.name)) or nil
    local av = (type(c.user) == "table" and rv_s(c.user.avatar)) or (type(c.disqusUser) == "table" and rv_s(c.disqusUser.avatar)) or nil
    return { id = rv_s(c._id), author = who or "Anonyme", content = body, avatar = av and abs(av) or nil,
        date = rv_s(c.created_date), likes = tonumber(c.likes) or 0, dislikes = tonumber(c.dislikes) or 0 }
end

-- essaie une adresse : renvoie items, totalPages (ou nil si l'adresse ne répond pas du JSON de commentaires)
local function np_try(u)
    local body = get(u)
    local data = body and rv_json(body)
    if type(data) ~= "table" then return nil end
    local items
    if type(data.items) == "table" then
        items = {}
        for _, c in ipairs(data.items) do
            local ok, it = pcall(np_item, c)
            if ok and it then items[#items + 1] = it end
        end
    elseif type(data.html) == "string" then
        items = np_cards(data.html)
    else
        local list
        for _, k in ipairs({ "comments", "reviews", "results", "items", "data" }) do
            if type(data[k]) == "table" then list = data[k]; break end
        end
        if not list and #data > 0 then list = data end
        if not list then return nil end
        items = {}
        for _, c in ipairs(list) do
            local ok, it = pcall(rv_item, c)
            if ok and it then items[#items + 1] = it end
        end
    end
    local pg = type(data.pagination) == "table" and data.pagination or {}
    local tp = tonumber(pg.totalPages or pg.total_pages or data.totalPages) or 0
    return items, tp
end

local function np_reviews(path, page, sort)
    local pg = page or 1
    local slug = norm(path):match("/book/([^/]+)")
    if not slug then return { reviews = {}, has_more = false } end
    local so = sort == "mostliked" and "most-liked" or (sort == "oldest" and "oldest" or "latest")
    -- même requête que le site : /api-web/novels/{slug}/comments?scope=all&sort=…&page=…&limit=10
    local u = BASE .. "/api-web/novels/" .. slug .. "/comments?scope=all&sort=" .. so .. "&page=" .. pg .. "&limit=10"
    local items, tp = np_try(u)
    if items and #items > 0 then
        return { reviews = items, has_more = (tp > 0 and pg < tp) or (tp == 0 and #items >= 10) }
    end
    if items and pg > 1 then return { reviews = {}, has_more = false } end
    -- repli : les commentaires « Hot » de la fiche (seulement si l'API ne répond pas)
    if pg == 1 then
        logger.warn("NovelPing avis : API /api-web injoignable ou vide, repli sur les commentaires Hot de la fiche")
        local fiche = get(path)
        if fiche then
            local hot = np_hot(fiche)
            if #hot > 0 then return { reviews = hot, has_more = false } end
        end
    end
    return { reviews = {}, has_more = false, error = items == nil }
end

function ext:parseReviews(path, page, sort)
    if RV_MODE == "novelping" then return np_reviews(path, page, sort) end
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