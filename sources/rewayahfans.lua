-- rewayahfans.net — source Sefirah (réparée à la main d'après les vraies pages du site).
-- Contrat : voir extensions/mangapill.lua du plugin Sefirah.
local logger = require("logger")
local BASE   = "https://rewayahfans.net"
local SEARCH = "https://rewayahfans.net/wp-json/wp/v2/search?search={q}&per_page=20&page={page}"
local LISTP  = ""
local CHAPP  = ""
local CONT   = ""
local UA = "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36"

local function get(p)
    local url = p:match("^https?://") and p or (BASE .. p)
    local body, code = require("core.net").get(url, { headers = { ["User-Agent"] = UA, ["Referer"] = BASE .. "/" }, timeout = 15 })
    if body and #body > 2 then return body end
    logger.warn("rewayahfans.net: échec", url, tostring(code))
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

-- ===== adresses du site : pas de préfixe commun, on reconnaît la forme du lien =====
local PAGES = {
    list      = "/%d9%82%d8%a7%d8%a6%d9%85%d8%a9-%d8%a7%d9%84%d8%b1%d9%88%d8%a7%d9%8a%d8%a7%d8%aa/",
    completed = "/%d8%a7%d9%84%d8%b1%d9%88%d8%a7%d9%8a%d8%a7%d8%aa-%d8%a7%d9%84%d9%85%d9%83%d8%aa%d9%85%d9%84%d8%a9/",
}
local NOT_NOVEL = {
    [norm(PAGES.list)] = true, [norm(PAGES.completed)] = true,
    [norm("/%d8%b3%d9%8a%d8%a7%d8%b3%d8%a9-%d8%a7%d9%84%d8%ae%d8%b5%d9%88%d8%b5%d9%8a%d8%a9/")] = true, -- politique de confidentialité
    [norm("/%d8%a7%d8%aa%d8%b5%d9%84-%d8%a8%d9%86%d8%a7/")] = true,                                       -- contact
}
-- roman : un seul segment, en arabe encodé (%d8… / %d9…)
local function is_novel(href)
    local p = norm(href or "")
    return p:match("^/%%d[89a-f]") ~= nil and not p:find("/", 2, true) and not NOT_NOVEL[p]
end
-- chapitre : un seul segment latin qui se termine (ou commence) par un numéro
local function is_chapter(href)
    local p = norm(href or "")
    if not p:match("^/[%a%d_%-]+$") then return false end
    return (p:match("%-%d+$") or p:match("^/%d+%-")) and true or false
end

local function parse_list(html)
    local out, idx = {}, {}
    for tag, inner_html in html:gmatch("(<a%s[^>]->)(.-)</a>") do
        local href = attr(tag, "href")
        if href and is_novel(href) then
            local k = norm(href)
            local img = inner_html:match("<img[^>]->")
            -- nom : texte du lien (vrai titre) > attribut title > alt de l'image (souvent faux : nom de fichier, titre arabe…)
            local name, rank = txt(inner_html), 0
            if name ~= "" then rank = 3 end
            if name == "" then
                local t = attr(tag, "title")
                if t and t ~= "" then name, rank = dec(t), 2
                else
                    local al = img and attr(img, "alt")
                    if al and al ~= "" and not al:match("^IMG[_%-]") and not al:lower():match("%.%a%a%a%a?$") then name, rank = dec(al), 1 end
                end
            end
            local cover = cover_of(img)
            local it = idx[k]
            if it then -- même œuvre déjà vue (image + titre) : on complète seulement
                if name ~= "" and rank > it.rank then it.name, it.rank = name, rank end
                if not it.cover and cover then it.cover = cover end
            else
                it = { name = name, rank = rank, path = rel(href), cover = cover }
                idx[k] = it
                out[#out+1] = it
            end
        end
    end
    local res = {}
    for _, it in ipairs(out) do if it.name ~= "" then res[#res+1] = { name = it.name, path = it.path, cover = it.cover } end end
    return res
end

local ext = { id = "rewayahfans", name = "Rewayahfans", site = BASE, lang = "ar", version = "0.2.0",
    popularFilters = {
        { key = "list", label = "القائمة", default = "all", multi = false,
          options = { { id = "all", label = "كل الروايات" }, { id = "completed", label = "الروايات المكتملة" } } },
    },
    searchFilters = {}, hasReviews = false, chapterCommentsPanel = false }

function ext:popularNovels(page, options)
    if (tonumber(page) or 1) > 1 then return { novels = {} } end -- la liste du site tient sur une seule page
    local f = options and options.filters and options.filters.list
    local html, err = get(f == "completed" and PAGES.completed or PAGES.list)
    if not html then return { novels = {}, error = "Site injoignable (" .. tostring(err) .. ")" } end
    return { novels = parse_list(html) }
end

-- ===== WORDPRESS REST : recherche JSON (repli) =====
local function wp_json(s)
    local ok_j, J = pcall(require, "rapidjson")
    if not ok_j then J = require("json") end
    local ok, d = pcall(J.decode, s)
    if ok then return d end
    return nil
end

function ext:searchNovels(term, page, options)
    term = tostring(term or ""):match("^%s*(.-)%s*$")
    if term == "" then return ext:popularNovels(page, options) end
    if (tonumber(page) or 1) > 1 then return { novels = {} } end
    -- 1) recherche locale dans les deux listes du site (titres anglais, avec couvertures)
    local q, out, seen = term:lower(), {}, {}
    for _, pg in ipairs({ PAGES.list, PAGES.completed }) do
        local html = get(pg)
        if html then
            for _, it in ipairs(parse_list(html)) do
                local k = norm(it.path)
                if not seen[k] and it.name:lower():find(q, 1, true) then seen[k] = true; out[#out + 1] = it end
            end
        end
    end
    if #out > 0 then return { novels = out } end
    -- 2) repli : API REST de WordPress (garde seulement les adresses de romans)
    local body, err = get(BASE .. "/wp-json/wp/v2/search?search=" .. enc(term) .. "&per_page=20&_fields=id,title,url")
    local data = body and wp_json(body)
    if type(data) ~= "table" then return { novels = {}, error = "Recherche impossible (" .. tostring(err) .. ")" } end
    for _, n in ipairs(data) do
        if type(n) == "table" and type(n.url) == "string" and is_novel(n.url) and not seen[norm(n.url)] then
            seen[norm(n.url)] = true
            out[#out + 1] = { name = dec(tostring(n.title or n.url)), path = rel(n.url) }
        end
    end
    return { novels = out }
end

-- zone de contenu de l'article (WordPress « block theme »), sinon toute la page
local function content_of(html)
    return grab(html, "wp-block-post-content") or grab(html, "entry-content") or html
end

local SUFFIX = " - الصفحة الرئيسية"
local function strip_suffix(n)
    if #n > #SUFFIX and n:sub(-#SUFFIX) == SUFFIX then return n:sub(1, #n - #SUFFIX) end
    return n
end
local function field(d, label)
    return d:match(label .. "%s*:%s*([^" .. NL .. "]+)")
end

local function meta(html, path)
    local clean = html:gsub("<script.-</script>", ""):gsub("<style.-</style>", "")
    -- titre : le lien du roman vers sa propre page (titre anglais, comme dans la liste), sinon og:title
    local name = ""
    local me = norm(path)
    for tag, inner_html in clean:gmatch("(<a%s[^>]->)(.-)</a>") do
        local href = attr(tag, "href")
        if href and norm(href) == me then
            local t = txt(inner_html)
            if t ~= "" and t ~= "الصفحة الرئيسية" then name = t; break end
        end
    end
    if name == "" then name = strip_suffix(dec(clean:match('property="og:title"[^>]-content="([^"]*)"') or "")) end
    if name == "" then name = path end

    local c = content_of(clean):gsub("</li>", "</p>"):gsub("</h%d>", "</p>")
    local d = para(c)
    local summary = ""
    local a, b = d:find("القصة", 1, true)
    if a then
        local rest = d:sub(b + 1):gsub("^%s*:%s*", "")
        local e = rest:find("الفصول", 1, true)
        if e then rest = rest:sub(1, e - 1) end
        rest = (rest:gsub("أضغط هنا", ""):gsub("اضغط هنا", ""))
        summary = (rest:gsub(NL .. NL .. "+", NL .. NL):match("^%s*(.-)%s*$"))
    end
    if summary == "" then summary = dec(clean:match('property="og:description"[^>]-content="([^"]*)"') or "") end

    local genres = {}
    local g = field(d, "التصنيفات")
    if g then for x in (g .. "؛"):gmatch("(.-)؛") do x = x:match("^%s*(.-)%s*$"); if x ~= "" and x ~= "تحديث" then genres[#genres + 1] = x end end end
    local author = field(d, "المؤلف"); if author == "تحديث" then author = nil end
    local status = field(d, "الحالة")
    return { name = name, path = path,
        cover = abs(dec(clean:match('property="og:image"[^>]-content="([^"]*)"') or "")),
        summary = summary, author = author or "", status = status or "", genres = genres }
end

function ext:parseNovelMeta(path)
    local html = get(path); if not html then return nil end
    local m = meta(html, path); m.total_chapters = 0; return m
end

function ext:parseNovel(path)
    local html = get(path); if not html then return nil end
    local m, ch, seen = meta(html, path), {}, {}
    local me = norm(path)
    local page = html:gsub("<script.-</script>", ""):gsub("<style.-</style>", "")
    for tag, inner_html in page:gmatch("(<a%s[^>]->)(.-)</a>") do
        local href = attr(tag, "href")
        if href then
            local k = norm(href)
            local label = txt(inner_html)
            local ok = is_chapter(href)
            if not ok and k ~= me and k:match("^/[^/]+$") and not NOT_NOVEL[k] then
                -- adresse inhabituelle : on se fie au libellé (« 12 », « 12.5 », « الفصل 12 »)
                ok = label:match("^%d+[%.%-]?%d*$") ~= nil or label:find("الفصل", 1, true) == 1
            end
            if ok and not seen[k] then
                seen[k] = true
                local name = label
                if name == "" then name = dec(attr(tag, "title") or "") end
                if name == "" then name = tostring(#ch + 1) end
                if name:match("^%d+[%.%-]?%d*$") then name = "الفصل " .. name end
                ch[#ch + 1] = { name = name, path = rel(href) }
            end
        end
    end
    -- le site liste déjà du premier au dernier chapitre : pas d'inversion
    for i, c in ipairs(ch) do c.chapter_number = i end
    m.chapters, m.totalPages = ch, 1
    return m
end

function ext:parseChapter(path)
    local html = get(path); if not html then return "<p>Chapitre injoignable.</p>" end
    html = html:gsub("<script.-</script>", ""):gsub("<style.-</style>", "")
    html = html:gsub("<a[^>]-omg10%.com.-</a>", "") -- lien publicitaire
    local ps, n = {}, 0
    local zone = content_of(html)
    for p in zone:gmatch("<p%f[%s>][^>]*>(.-)</p>") do
        local t = txt(p)
        if #t > 1 and t ~= "الصفحة الرئيسية" and t ~= "إعجاب" and not t:find("جاري التحميل", 1, true) then ps[#ps + 1] = "<p>" .. p .. "</p>"; n = n + #t end
    end
    if #ps < 3 and zone ~= html then -- zone mal détectée : toutes les balises <p> de la page
        ps, n = {}, 0
        for p in html:gmatch("<p%f[%s>][^>]*>(.-)</p>") do
            local t = txt(p)
            if #t > 1 then ps[#ps + 1] = "<p>" .. p .. "</p>"; n = n + #t end
        end
    end
    if #ps >= 2 and n > 200 then return table.concat(ps) end
    return "<p>Texte du chapitre introuvable.</p>"
end

return ext
