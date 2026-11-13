-- Ar Novel (ar-no.com) — moteur Madara, romans arabes. Œuvre = /novel/<slug>/ ; chapitre = /novel/<slug>/[<volume>/]<chapitre>/
local logger = require("logger")
local BASE   = "https://ar-no.com"
local SEARCH = "https://ar-no.com/?s={q}&post_type=wp-manga"
local LISTP  = "/novel/"
local UA = "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36"

-- encode les octets non-ASCII et les espaces d'une URL (les liens arabes bruts faisaient échouer l'écriture de la requête)
local function safe_url(u)
    return (u:gsub("[^%w%-%._~:/%?#%[%]@!$&'()*+,;=%%]", function(c) return string.format("%%%02X", c:byte()) end))
end

local function get(p)
    local url = safe_url(p:match("^https?://") and p or (BASE .. p))
    local body, code = require("core.net").get(url, { headers = { ["User-Agent"] = UA, ["Referer"] = BASE .. "/" }, timeout = 20, retries = 3 })
    if body and #body > 2 then return body end
    logger.warn("Ar Novel: échec", url, tostring(code))
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
    h = h:gsub("%%(%x%x)", function(x) return string.char(tonumber(x, 16)) end)   -- liens arabes : encodés ou bruts, même clé
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
local function grab(html, cls, minlen)
    local pos = 1
    while true do
        local s, e, tn, attrs = html:find("<(%a%w*)(%s[^>]*)>", pos)
        if not s then return nil end
        local c = attr(attrs, "class")
        if c and c:find(cls, 1, true) then
            local out = inner(html, e + 1, tn)
            if out and #out > (minlen or 50) then return out end
        end
        pos = e + 1
    end
end


-- ===== détection œuvre / chapitre =====
local function local_path(h)
    if h:match("^https?://") then
        if h:sub(1, #BASE) ~= BASE then return nil end
        h = h:sub(#BASE + 1)
    end
    h = h:gsub("[?#].*$", "")
    return h
end
-- segments après /novel/ (liste vide si ce n'est pas une page de roman)
local function segs(h)
    local p = local_path(h)
    if not p then return nil end
    local a = p:match("^/novel/(.+)$")
    if not a then return nil end
    local t = {}
    for s in a:gmatch("[^/]+") do t[#t + 1] = s end
    return t
end
local function is_work(h) local t = segs(h); return t ~= nil and #t == 1 end

local function parse_list(html)
    local out, idx = {}, {}
    for tag, inner_html in html:gmatch("(<a%s[^>]->)(.-)</a>") do
        local href = attr(tag, "href")
        if href and is_work(href) then
            local k = norm(href)
            local img = inner_html:match("<img[^>]->")
            local title = attr(tag, "title")
            if title == "" then title = nil end
            local name = title and dec(title) or txt(inner_html)
            local cover = cover_of(img)
            local it = idx[k]
            if it then
                if title and not it.titled then it.name = name; it.titled = true end
                if it.name == "" and name ~= "" then it.name = name end
                if not it.cover and cover then it.cover = cover end
            else
                it = { name = name, path = rel(local_path(href)), cover = cover, titled = title ~= nil }
                idx[k] = it
                out[#out + 1] = it
            end
        end
    end
    local res = {}
    for _, it in ipairs(out) do if it.name ~= "" then res[#res + 1] = it end end
    local budget = 8
    for _, it in ipairs(res) do
        if not it.cover and budget > 0 then
            budget = budget - 1
            local ok, page = pcall(get, it.path)
            if ok and page then
                local og = page:match('property="og:image"[^>]-content="([^"]*)"')
                if og and og ~= "" and not bad_cover(og) then it.cover = abs(dec(og)) end
            end
        end
    end
    return res
end

local T = require("core.i18n").T

-- ===== Filtres (Parcourir / Recherche) — moteur Madara =====
-- Contrat : ui/browse.lua (ext.popularFilters / ext.searchFilters / ext:loadFilters).
-- tri  -> m_orderby ; statut -> status[] ; genres (sélection multiple « slug1,slug2 ») -> genre[]
local SORT_FILTER = { key = "sort", label = T("Tri"), default = "views", options = {
    { id = "views",     label = T("Plus lus") },
    { id = "trending",  label = T("Tendance") },
    { id = "latest",    label = T("Dernières mises à jour") },
    { id = "new-manga", label = T("Nouveautés") },
    { id = "rating",    label = T("Mieux notés") },
    { id = "alphabet",  label = "A-Z" },
} }
local SEARCH_SORT_FILTER = { key = "sort", label = T("Tri"), default = "", options = {
    { id = "",          label = T("Pertinence") },
    { id = "views",     label = T("Plus lus") },
    { id = "trending",  label = T("Tendance") },
    { id = "latest",    label = T("Dernières mises à jour") },
    { id = "new-manga", label = T("Nouveautés") },
    { id = "rating",    label = T("Mieux notés") },
    { id = "alphabet",  label = "A-Z" },
} }
local STATUS_FILTER = { key = "status", label = T("Statut"), default = "", options = {
    { id = "",        label = T("Tous") },
    { id = "on-going", label = T("En cours") },
    { id = "end",     label = T("Terminé") },
    { id = "on-hold", label = T("En pause") },
    { id = "canceled", label = T("Annulé") },
} }
-- les genres sont lus sur le site à la 1re ouverture du panneau (ext:loadFilters)
local GENRE_FILTER = { key = "genre", label = T("Genre"), default = "", multi = true, options = { { id = "", label = T("Tous") } } }


-- ===== Genres : le site les sert en arabe -> traduits via T() (clés françaises, locales/*.lua) =====
local function norm_ar(x)
    x = tostring(x or "")
    x = x:gsub("\xD9[\x8B-\x9F]", ""):gsub("\xD9\x80", ""):gsub("\xD9\xB0", "")   -- tashkeel, tatweel
    x = x:gsub("\xD8[\xA2\xA3\xA5]", "\xD8\xA7")                                    -- أ إ آ -> ا
    x = x:gsub("\xD9\x89", "\xD9\x8A"):gsub("\xD8\xA9", "\xD9\x87")              -- ى -> ي ; ة -> ه
    x = x:gsub("%s*%(%s*%d+%s*%)%s*$", ""):gsub("%s+", " ")
    return (x:match("^%s*(.-)%s*$"))
end
local GENRE_FR_RAW = {
    ["أكشن"] = "Action",
    ["مغامرات"] = "Aventure",
    ["خيال"] = "Fantastique",
    ["فنون قتال"] = "Arts martiaux",
    ["رومنسي"] = "Romance",
    ["كوميديا"] = "Comédie",
    ["حريم"] = "Harem",
    ["شونين"] = "Shōnen",
    ["دراما"] = "Drame",
    ["تاريخي"] = "Historique",
    ["خيال علمي"] = "Science-fiction",
    ["شوجو"] = "Shōjo",
    ["سينين"] = "Seinen",
    ["جوسي"] = "Josei",
    ["مدرسي"] = "Vie scolaire",
    ["ماورائي"] = "Surnaturel",
    ["غموض"] = "Mystère",
    ["رعب"] = "Horreur",
    ["نفسي"] = "Psychologique",
    ["مأساة"] = "Tragédie",
    ["شريحة من الحياة"] = "Tranche de vie",
    ["رياضة"] = "Sport",
    ["ميكا"] = "Mecha",
    ["سحر"] = "Magie",
    ["إثارة"] = "Thriller",
    ["بالغين"] = "Adulte",
    ["ناضج"] = "Mature",
    ["شيانشيا"] = "Xianxia",
    ["ووشيا"] = "Wuxia",
    ["شيوانهوان"] = "Xuanhuan",
    ["العاب"] = "Jeux",
    ["نظام"] = "Système",
    ["تناسخ"] = "Réincarnation",
    ["جريمة"] = "Crime",
    ["حرب"] = "Guerre",
    ["طبخ"] = "Cuisine",
    ["موسيقى"] = "Musique",
    ["بقاء"] = "Survie",
    ["زراعة"] = "Cultivation",
    ["خارق للطبيعة"] = "Surnaturel",
    ["ايسيكاي"] = "Isekai",
    ["اكشن"] = "Action",
    ["فانتازيا"] = "Fantastique",
    ["كوميدي"] = "Comédie",
    ["رومانسي"] = "Romance",
    ["مغامرة"] = "Aventure",
    ["شياطين"] = "Démons",
    ["فنتازيا"] = "Fantastique",
    ["تشويق"] = "Suspense",
    ["مصاصي دماء"] = "Vampires",
    ["علمي"] = "Science-fiction",
}
local GENRE_FR = {}
for ar, fr in pairs(GENRE_FR_RAW) do GENRE_FR[norm_ar(ar)] = fr end
local function genre_label(ar)
    local fr = GENRE_FR[norm_ar(ar)]
    if fr then return T(fr), true end
    return ar, false
end

local ext = { id = "arno", name = "Ar Novel", site = BASE, lang = "ar", version = "0.3.0",
    popularFilters = { SORT_FILTER, STATUS_FILTER, GENRE_FILTER },
    searchFilters  = { SEARCH_SORT_FILTER, STATUS_FILTER, GENRE_FILTER },
    hasReviews = false }

local function write_debug(msg, name)
    pcall(function()
        local dir = require("datastorage"):getSettingsDir() .. "/sefirah"
        require("libs/libkoreader-lfs").mkdir(dir)
        local f = io.open(dir .. "/" .. (name or "arno_last_error.txt"), "w")
        if f then f:write(msg); f:close() end
    end)
end

-- paramètres de filtre -> parties de requête Madara
local function filter_parts(f)
    local q = {}
    f = f or {}
    local n = 0
    for id in tostring(f.genre or ""):gmatch("[^,]+") do
        q[#q + 1] = "genre%5B%5D=" .. enc(id); n = n + 1
    end
    if n > 1 then q[#q + 1] = "op=1" end   -- plusieurs genres : tous requis
    if f.status and f.status ~= "" then q[#q + 1] = "status%5B%5D=" .. enc(f.status) end
    if f.sort and f.sort ~= "" then q[#q + 1] = "m_orderby=" .. enc(f.sort) end
    return q, n
end

local function list_url(page, filters)
    local p = tonumber(page) or 1
    local f = filters or {}
    local sort = (f.sort and f.sort ~= "") and f.sort or "views"
    if (f.genre or "") == "" and (f.status or "") == "" then
        return BASE .. "/novels" .. (p > 1 and ("/page/" .. p) or "") .. "/?m_orderby=" .. enc(sort)
    end
    -- genre / statut : la recherche avancée Madara (s vide) les gère
    local q = filter_parts({ genre = f.genre, status = f.status, sort = sort })
    return BASE .. (p > 1 and ("/page/" .. p) or "") .. "/?s=&post_type=wp-manga&" .. table.concat(q, "&")
end
function ext:popularNovels(page, options)
    local html, err = get(list_url(page, options and options.filters))
    if not html then return { novels = {}, error = "Site injoignable (" .. tostring(err) .. ")" } end
    return { novels = parse_list(html) }
end
function ext:searchNovels(term, page, options)
    term = tostring(term or ""):match("^%s*(.-)%s*$")
    local f = (options and options.filters) or {}
    if term == "" and (f.genre or "") == "" and (f.status or "") == "" and (f.sort or "") == "" then return ext:popularNovels(page, options) end
    local p = tonumber(page) or 1
    local q = filter_parts(f)
    local url = BASE .. (p > 1 and ("/page/" .. p) or "") .. "/?s=" .. enc(term) .. "&post_type=wp-manga" .. (#q > 0 and ("&" .. table.concat(q, "&")) or "")
    local html, err = get(url)
    if not html then return { novels = {}, error = "Recherche impossible (" .. tostring(err) .. ")" } end
    return { novels = parse_list(html) }
end

-- Relit la liste des genres sur le site (formulaire de recherche avancée Madara) ; échec = liste vide « Tous ».
function ext:loadFilters()
    local list, seen, unknown = {}, {}, {}
    local function add(slug, label)
        slug = (slug or ""):match("^%s*(.-)%s*$")
        label = txt(label or "")
        if slug ~= "" and not seen[slug] then
            seen[slug] = true
            local lbl, known = genre_label(label ~= "" and label or slug)
            if not known then unknown[#unknown + 1] = label ~= "" and label or slug end
            list[#list + 1] = { id = slug, label = lbl }
        end
    end
    for _, u in ipairs({ "/?s=&post_type=wp-manga", "/novels/" }) do
        local ok, html = pcall(get, u)
        if ok and html then
            for tag in html:gmatch("<input[^>]-name=[\"']genre%[%][\"'][^>]->") do
                local v, id = attr(tag, "value"), attr(tag, "id")
                local lbl = id and html:match("<label[^>]-for=[\"']" .. id:gsub("%p", "%%%0") .. "[\"'][^>]*>(.-)</label>")
                add(v, lbl)
            end
            if #list == 0 then   -- repli : liens /novel-genre/<slug>/
                for href, ih in html:gmatch("<a[^>]-href=[\"']([^\"']-/novel%-genre/[^\"']+)[\"'][^>]*>(.-)</a>") do
                    add(href:match("/novel%-genre/([^/?#]+)"), ih)
                end
            end
        end
        if #list > 0 then break end
    end
    if #list == 0 then
        write_debug("Ar Novel : aucun genre trouvé (ni genre[] ni /novel-genre/) sur " .. BASE)
    else
        local o = { { id = "", label = T("Tous") } }
        for _, g in ipairs(list) do o[#o + 1] = g end
        GENRE_FILTER.options = o
        if #unknown > 0 then write_debug("Genres non traduits : " .. table.concat(unknown, " | "), "arno_genres.txt") end
    end
    self.filters_ready = true
end

local function ogp(html, p)
    return dec(html:match('property="' .. p .. '"[^>]-content="([^"]*)"') or html:match('content="([^"]*)"[^>]-property="' .. p .. '"') or "")
end
local function meta(html, path)
    local t = html:match("<h1[^>]*>(.-)</h1>")
    local name = t and txt(t) or ""
    if name == "" then name = ogp(html, "og:title"):gsub("%s*~.*$", "") end
    if name == "" then name = path end
    local summary = ogp(html, "og:description")
    local sm = grab(html, "summary__content") or grab(html, "description-summary")
    if sm then local d = para(sm); if #d > 40 then summary = d end end
    local cover
    local si = grab(html, "summary_image")
    if si then cover = cover_of(si:match("<img[^>]->")) end
    if not cover then local og = ogp(html, "og:image"); if og ~= "" and not bad_cover(og) then cover = abs(og) end end
    local author = html:match('class="author%-content"[^>]*>(.-)</div>')
    local status = html:match("<h5>%s*الحالة%s*</h5>.-class=\"summary%-content\"[^>]*>(.-)</div>")
        or html:match("<h5>%s*Status%s*</h5>.-class=\"summary%-content\"[^>]*>(.-)</div>")
    local genres = {}
    local g = html:match('class="genres%-content"[^>]*>(.-)</div>')
    if g then for x in g:gmatch("<a[^>]*>(.-)</a>") do genres[#genres + 1] = txt(x) end end
    return { name = name, path = path, cover = cover, summary = summary,
        author = author and txt(author) or "", status = status and txt(status) or "", genres = genres }
end

function ext:parseNovelMeta(path)
    local html = get(path); if not html then return nil end
    local m = meta(html, path); m.total_chapters = 0; return m
end

-- POST (core.net n'a que get) ; renvoie le corps ou nil. 3 essais : les erreurs « write/wantwrite » sont passagères.
local function post(url, body)
    url = safe_url(url)
    for try = 1, 3 do
        local ok, res = pcall(function()
            local ltn12 = require("ltn12")
            local req = url:match("^https") and require("ssl.https") or require("socket.http")
            local chunks = {}
            local r, code = req.request {
                url = url, method = "POST", source = ltn12.source.string(body), sink = ltn12.sink.table(chunks), timeout = 20,
                headers = { ["User-Agent"] = UA, ["Referer"] = BASE .. "/", ["X-Requested-With"] = "XMLHttpRequest",
                    ["Content-Type"] = "application/x-www-form-urlencoded", ["Content-Length"] = tostring(#body),
                    ["Accept"] = "*/*", ["Origin"] = BASE },
            }
            if r and code == 200 then return table.concat(chunks) end
            logger.warn("Ar Novel: POST échec", url, tostring(code))
            return nil
        end)
        if ok and type(res) == "string" and #res > 20 then return res end
        pcall(function() require("socket").sleep(0.7 * try) end)
    end
    return nil
end

local function collect(html, path, seen, ch)
    local pk = norm(path)
    local vol = nil   -- nom du volume courant (lien javascript:void(0) qui précède ses chapitres)
    for tag, ih in html:gmatch("(<a%s[^>]->)(.-)</a>") do
        local href = attr(tag, "href")
        if href and href:match("^javascript") then
            local v = txt(ih)
            if v ~= "" then vol = v end
        end
        if href and href:sub(1, 1) ~= "#" and not href:match("^javascript") then
            local k = norm(href)
            if not seen[k] and #k > #pk + 1 and k:sub(1, #pk + 1) == pk .. "/" then
                seen[k] = true
                ih = ih:gsub("<span[^>]-release%-date.-</span>", ""):gsub("<img[^>]->", "")
                local name = txt(ih)
                if name == "" then name = dec(attr(tag, "title") or "") end
                if name == "" then name = "Chapitre " .. (#ch + 1) end
                -- certains romans (ex. Reverend Insanity) n'ont que « 1 », « 2 »… comme titre : on ajoute le volume
                if vol and name:match("^%d+$") then name = name .. " — " .. vol end
                ch[#ch + 1] = { name = name, path = rel(local_path(href) or href) }
            end
        end
    end
end

function ext:parseNovel(path)
    local html = get(path); if not html then return nil end
    local m, ch, seen = meta(html, path), {}, {}
    -- La page ne contient que « premier » et « dernier » chapitre : la vraie liste est chargée en AJAX (Madara).
    local id = html:match('id="manga%-chapters%-holder"[^>]-data%-id="(%d+)"') or html:match('data%-id="(%d+)"[^>]-id="manga%-chapters%-holder"')
        or html:match('"manga_id":"(%d+)"') or html:match("postid%-(%d+)")
    local rp = (local_path(path) or path):gsub("/+$", "")
    local aj = post(BASE .. rp .. "/ajax/chapters/", "action=manga_get_chapters&manga=" .. (id or ""))
    if aj then collect(aj, path, seen, ch) end
    if #ch <= 2 and id then
        aj = post(BASE .. "/wp-admin/admin-ajax.php", "action=manga_get_chapters&manga=" .. id)
        if aj then collect(aj, path, seen, ch) end
    end
    if #ch == 0 then collect(html, path, seen, ch) end   -- dernier recours : au moins les 2 liens de la page
    -- ordre croissant attendu : on inverse si le site liste du plus récent au plus ancien
    local function num(x) return tonumber((norm(x.path):match("([^/]+)$") or ""):match("^(%d+)") or (x.name or ""):match("^%s*(%d+)")) end
    local a, b = ch[1] and num(ch[1]), ch[#ch] and num(ch[#ch])
    if a and b and a > b then
        for i = 1, math.floor(#ch / 2) do ch[i], ch[#ch + 1 - i] = ch[#ch + 1 - i], ch[i] end
    end
    for i, c in ipairs(ch) do c.chapter_number = i end
    m.chapters, m.totalPages = ch, 1
    return m
end

function ext:parseChapter(path)
    local html = get(path); if not html then return "<p>Chapitre injoignable.</p>" end
    html = html:gsub("<script.-</script>", ""):gsub("<style.-</style>", "")
    local body = grab(html, "text-left")
    if not body then
        body = grab(html, "reading-content")
        if body then body = body:gsub("<input[^>]->", ""):gsub('<div id="text%-chapter%-toolbar".-</div>', "") end
    end
    if not body or #body < 30 then
        local ps = {}
        for p in html:gmatch("<p%f[%s>][^>]*>(.-)</p>") do
            if #txt(p) > 1 then ps[#ps + 1] = "<p>" .. p .. "</p>" end
        end
        if #ps >= 3 then body = table.concat(ps) end
    end
    if not body or #body < 30 then return "<p>Texte du chapitre introuvable.</p>" end
    return body
end

return ext
