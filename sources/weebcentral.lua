-- WeebCentral (weebcentral.com) — manga en anglais.
-- Point de départ : modèle généré par Sefirah Source Hub, corrigé à la main. Le site charge ses listes par HTMX
-- (morceaux de HTML à part), donc la page d'une fiche ne contient que les derniers chapitres et la page d'un chapitre
-- ne contient aucune image. Trois adresses « partielles » sont utilisées :
--   recherche / liste : /search/data?text=…&sort=…&order=…&official=Any&display_mode=Full Display&limit=32&offset=N
--   tous les chapitres : /series/<id>/full-chapter-list      (le plus récent en premier)
--   images d'un chapitre : /chapters/<id>/images?is_prev=False&current_page=1&reading_style=long_strip
-- Ces adresses viennent de projets tiers qui lisent le même site ; elles n'ont pas été testées sur une liseuse.
local logger = require("logger")
local T = require("core.i18n").T
local BASE   = "https://weebcentral.com"
local LISTP  = "/series/"
local CHAPP  = "/chapters/"
local PAGE   = 32 -- résultats par page demandés au site
local UA = "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36"

local function get(p)
    local url = p:match("^https?://") and p or (BASE .. p)
    local body, code = require("core.net").get(url, { headers = { ["User-Agent"] = UA, ["Referer"] = BASE .. "/" }, timeout = 15 })
    if body and #body > 2 then return body end
    logger.warn("WeebCentral: échec", url, tostring(code))
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

-- ===== liens =====
local function series_id(p) return p and p:match("/series/([^/?#]+)") end
local function chapter_id(p) return p and p:match("/chapters/([^/?#]+)") end
local function is_work(h) return series_id(h) ~= nil and not h:find(CHAPP, 1, true) end
local function is_chap(h) return chapter_id(h) ~= nil end

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
            -- l'alt de l'image est « <Titre> cover » : on enlève le mot final
            if not title then name = name:gsub("%s+[Cc]over$", ""):gsub("%s+$", "") end
            local cover = cover_of(img)
            local it = idx[k]
            if it then -- même œuvre déjà vue (lien de l'image + lien du titre) : on complète seulement
                if it.name == "" and name ~= "" then it.name = name end
                if not it.cover and cover then it.cover = cover end
            else
                it = { name = name, path = rel(dec(href)), cover = cover }
                idx[k] = it
                out[#out+1] = it
            end
        end
    end
    local res = {}
    for _, it in ipairs(out) do if it.name ~= "" then res[#res+1] = it end end
    -- couvertures manquantes : og:image de la fiche, 8 au maximum pour rester rapide
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

-- ===== filtres : ceux de la page « Advanced Search » du site (https://weebcentral.com/search) =====
-- Tri, ordre, statut, type, traduction officielle, adaptation animée, contenu adulte, genres inclus / exclus.
-- (Le champ « author » du formulaire est caché sur le site : il n'est donc pas proposé ici.)
local function opts(list) local o = {} for _, p in ipairs(list) do o[#o + 1] = { id = p[1], label = p[2] } end return o end
local TAGS = { "Action", "Adult", "Adventure", "Comedy", "Doujinshi", "Drama", "Ecchi", "Fantasy", "Gender Bender", "Harem",
    "Hentai", "Historical", "Horror", "Isekai", "Josei", "Lolicon", "Martial Arts", "Mature", "Mecha", "Mystery", "Psychological",
    "Romance", "School Life", "Sci-fi", "Seinen", "Shotacon", "Shoujo", "Shoujo Ai", "Shounen", "Shounen Ai", "Slice of Life",
    "Smut", "Sports", "Supernatural", "Tragedy", "Yaoi", "Yuri", "Other" }
local function tag_opts() local o = { { id = "", label = "Tous" } } for _, t in ipairs(TAGS) do o[#o + 1] = { id = t, label = t } end return o end
local function multi(list) local o = { { id = "", label = "Tous" } } for _, p in ipairs(list) do o[#o + 1] = { id = p[1], label = p[2] } end return o end
local function tri(label, key) -- Indifférent / Oui / Non
    return { key = key, label = label, default = "Any", options = opts({ { "Any", "Indifférent" }, { "True", "Oui" }, { "False", "Non" } }) }
end
local function make_filters(default_sort)
    return {
        { key = "sort", label = "Tri", default = default_sort, options = opts({
            { "Best Match", "Meilleure correspondance" }, { "Alphabet", "Alphabétique" }, { "Popularity", "Popularité" },
            { "Subscribers", "Abonnés" }, { "Recently Added", "Derniers ajouts" }, { "Latest Updates", "Dernières mises à jour" } }) },
        { key = "order", label = "Ordre", default = "Descending", options = opts({ { "Descending", "Décroissant" }, { "Ascending", "Croissant" } }) },
        { key = "status", label = "Statut", multi = true, default = "", options = multi({
            { "Ongoing", "En cours" }, { "Complete", "Terminé" }, { "Hiatus", "En pause" }, { "Canceled", "Annulé" } }) },
        { key = "type", label = "Type", multi = true, default = "", options = multi({
            { "Manga", "Manga" }, { "Manhwa", "Manhwa" }, { "Manhua", "Manhua" }, { "OEL", "OEL" } }) },
        tri("Traduction officielle", "official"),
        tri("Adaptation animée", "anime"),
        tri("Contenu adulte", "adult"),
        { key = "tag", label = "Genres inclus", multi = true, default = "", options = tag_opts() },
        { key = "xtag", label = "Genres exclus", multi = true, default = "", options = tag_opts() },
    }
end

local ext = { id = "weebcentral", name = "WeebCentral", site = BASE, lang = "en", version = "1.1.1",
    type = "manga",
    popularFilters = make_filters("Popularity"), searchFilters = make_filters("Best Match"),
    hasReviews = false, chapterCommentsPanel = false }

local function pick(v, dflt) if v == nil or v == "" then return dflt end return tostring(v) end

-- Adresse de /search/data pour un terme, une page et les filtres choisis (valeurs vides = non envoyées).
-- Page 1, 2, 3… -> offset 0, 32, 64… ; une page vide marque la fin de la liste.
local function search_url(term, page, f, default_sort)
    f = type(f) == "table" and f or {}
    local q = {
        "text=" .. enc(term or ""),
        "sort=" .. enc(pick(f.sort, default_sort)),
        "order=" .. enc(pick(f.order, "Descending")),
        "official=" .. enc(pick(f.official, "Any")),
        "display_mode=Full%20Display",
    }
    local an = pick(f.anime, "Any"); if an ~= "Any" then q[#q + 1] = "anime=" .. enc(an) end
    local ad = pick(f.adult, "Any"); if ad ~= "Any" then q[#q + 1] = "adult=" .. enc(ad) end
    for _, m in ipairs({ { "status", "included_status" }, { "type", "included_type" }, { "tag", "included_tag" }, { "xtag", "excluded_tag" } }) do
        local v = f[m[1]]
        if type(v) == "string" and v ~= "" then
            for x in v:gmatch("[^,]+") do q[#q + 1] = m[2] .. "=" .. enc(x) end
        end
    end
    q[#q + 1] = "limit=" .. PAGE
    q[#q + 1] = "offset=" .. ((page - 1) * PAGE)
    return BASE .. "/search/data?" .. table.concat(q, "&")
end

function ext:popularNovels(page, options)
    page = tonumber(page) or 1
    local html, err = get(search_url("", page, options and options.filters, "Popularity"))
    if not html then
        if page > 1 then return { novels = {} } end
        return { novels = {}, error = T("Site injoignable (") .. tostring(err) .. ")" }
    end
    return { novels = parse_list(html) }
end

function ext:searchNovels(term, page, options)
    page = tonumber(page) or 1
    term = tostring(term or ""):match("^%s*(.-)%s*$")
    local html, err = get(search_url(term, page, options and options.filters, term == "" and "Popularity" or "Best Match"))
    if not html then
        if page > 1 then return { novels = {} } end
        return { novels = {}, error = T("Recherche impossible (") .. tostring(err) .. ")" }
    end
    return { novels = parse_list(html) }
end

-- La fiche liste ses infos en lignes <li><strong>Author(s) / Tags / Type / Status / Description</strong>…</li>.
-- (og:description n'est qu'une phrase marketing « Read X Manga online for free at Weeb Central » : on ne l'affiche pas.)
-- statuts du site -> textes français (clés de traduction de Sefirah) ; un statut inconnu reste tel quel
local STATUS = { ongoing = "En cours", complete = "Terminé", completed = "Terminé", hiatus = "En pause", canceled = "Annulé", cancelled = "Annulé" }
local function li_block(html, label)
    local s = html:find("<strong[^>]*>%s*" .. label)
    if not s then return nil end
    local e = html:find("</li>", s, true)
    return html:sub(s, e and e - 1 or s + 4000)
end
local function anchors(b)
    local out = {}
    for a in (b or ""):gmatch("<a[^>]*>(.-)</a>") do
        local x = txt(a)
        if x ~= "" then out[#out+1] = x end
    end
    return out
end

local function meta(html, path)
    local t = html:match("<h1[^>]*>(.-)</h1>")
    local name = t and txt(t) or ""
    if name == "" then name = dec(html:match('property="og:title"[^>]-content="([^"]*)"') or "") end
    if name == "" then name = path end
    local cv = abs(dec(html:match('property="og:image"[^>]-content="([^"]*)"') or ""))
    if cv and bad_cover(cv) then cv = nil end
    local summary = ""
    local d = li_block(html, "Description")
    if d then
        local p = d:match("<p[^>]*>(.-)</p>")
        summary = para(p or (d:gsub("^<strong.-</strong>", "")))
    end
    if summary == "" then -- repli : og:description, sauf la phrase marketing du site
        local og = dec(html:match('property="og:description"[^>]-content="([^"]*)"')
            or html:match('content="([^"]*)"[^>]-property="og:description"') or "")
        if not og:lower():find("online for free", 1, true) then summary = og end
    end
    local status = anchors(li_block(html, "Status"))[1] or ""
    if STATUS[status:lower()] then status = T(STATUS[status:lower()]) end
    local genres = {}
    for _, g in ipairs(anchors(li_block(html, "Type"))) do genres[#genres+1] = g end
    for _, g in ipairs(anchors(li_block(html, "Tag"))) do genres[#genres+1] = g end
    return { name = name, path = path, cover = cv, summary = summary,
        author = table.concat(anchors(li_block(html, "Author")), ", "), status = status, genres = genres }
end

function ext:parseNovelMeta(path)
    local html = get(path); if not html then return nil end
    local m = meta(html, path); m.total_chapters = 0; return m
end

-- libellé d'un chapitre : le premier <span> dans <span class="grow …"> (« Chapter 107 »), sinon tout le texte du lien
local function chap_label(inner_html, tag)
    local g = inner_html:match('<span[^>]-class="[^"]-grow[^"]*"[^>]*>%s*<span[^>]*>(.-)</span>')
    local name = g and txt(g) or ""
    if name == "" then name = txt(inner_html) end
    if name == "" then name = dec(attr(tag, "title") or "") end
    return name
end

function ext:parseNovel(path)
    local html = get(path); if not html then return nil end
    local m = meta(html, path)
    local id = series_id(path)
    -- la fiche ne montre que les derniers chapitres : la liste complète est un morceau de page à part
    local full = id and get("/series/" .. id .. "/full-chapter-list")
    if not full then logger.warn("WeebCentral: liste complète des chapitres indisponible, repli sur la fiche", path) end
    local ch, seen = {}, {}
    for tag, inner_html in (full or html):gmatch("(<a%s[^>]->)(.-)</a>") do
        local href = attr(tag, "href")
        if href and is_chap(href) then
            local k = chapter_id(href)
            if not seen[k] then
                local name = chap_label(inner_html, tag)
                if name == "" then name = "Chapter " .. (#ch + 1) end
                seen[k] = { name = name, path = rel(dec(href)) }
                ch[#ch+1] = seen[k]
            end
        end
    end
    -- le site liste le plus récent en premier ; le plugin veut le plus ancien d'abord.
    -- (Pas de tri sur les chiffres de l'adresse : les identifiants de chapitre sont des codes aléatoires.)
    local function first_num(c) return tonumber((c.name or ""):match("(%d+%.?%d*)")) end
    local a1, b1 = first_num(ch[1] or {}), first_num(ch[#ch] or {})
    if not (a1 and b1 and a1 < b1) then
        for i = 1, math.floor(#ch / 2) do ch[i], ch[#ch + 1 - i] = ch[#ch + 1 - i], ch[i] end
    end
    for i, c in ipairs(ch) do c.chapter_number = i end
    m.chapters, m.totalPages = ch, 1
    return m
end

function ext:parseChapterImages(path)
    local id = chapter_id(path)
    if not id then return nil, "chapter_unreachable" end
    local html = get("/chapters/" .. id .. "/images?is_prev=False&current_page=1&reading_style=long_strip")
    if not html then return nil, "chapter_unreachable" end
    local images, seen = {}, {}
    -- 1er passage : les <img alt="Page N"> visibles (le site cache les autres modes de lecture avec x-show) ;
    -- 2e passage seulement s'il n'y en a aucune : toute image qui n'est ni le logo ni un fichier du site.
    for pass = 1, 2 do
        if #images == 0 then
            for tag in html:gmatch("<img[^>]->") do
                local alt = attr(tag, "alt") or ""
                local want = pass == 2 or (alt:find("Page", 1, true) and not tag:find("x-show", 1, true))
                if want then
                    local raw = attr(tag, "src") or attr(tag, "data-src")
                    local u = raw and abs(dec(raw:match("^%s*(.-)%s*$")))
                    if u and u:match("^https?://") and not seen[u] and not u:find("/static/", 1, true)
                        and not u:find("logo", 1, true) and not u:find("brand", 1, true) then
                        seen[u] = true; images[#images+1] = u
                    end
                end
            end
        end
    end
    if #images == 0 then return nil, "no_pages" end
    return { images = images, headers = { ["User-Agent"] = UA, ["Referer"] = BASE .. "/" } }
end

function ext:parseChapter(path) return "<p>Ce chapitre est un manga : il s'ouvre dans le lecteur d'images.</p>" end

return ext
