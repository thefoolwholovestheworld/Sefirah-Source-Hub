-- Knoxt.space — source Sefirah (thème WordPress "Lightnovel" de Themesia)
local logger = require("logger")
local BASE   = "https://knoxt.space"
local SEARCH = "/?s={q}&paged={page}"
local UA = "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36"

local function get(p)
    local url = p:match("^https?://") and p or (BASE .. p)
    local body, code = require("core.net").get(url, {
        headers = {
            ["User-Agent"] = UA,
            ["Referer"] = BASE .. "/",
            ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        },
        timeout = 15,
    })
    if body and #body > 2 then return body end
    logger.warn("Knoxt.space: échec", url, tostring(code))
    return nil, tostring(code)
end

-- ===== entités HTML =====
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
local function para(h) -- texte avec paragraphes
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
-- URL absolue + encodage des espaces / caractères non ASCII (ex. 第十三案刑侦)
local function abs(u)
    if not u then return nil end
    u = u:gsub("^%s+", ""):gsub("%s+$", "")
    if u:sub(1, 2) == "//" then u = "https:" .. u
    elseif u:sub(1, 1) == "/" then u = BASE .. u end
    u = u:gsub("[^%w%-%._~:/?#%[%]@!$&'()*+,;=%%]", function(c) return string.format("%%%02X", c:byte()) end)
    return u
end
local function enc(s) return (tostring(s):gsub("([^%w%-%._~])", function(c) return string.format("%%%02X", c:byte()) end)) end
-- idem, mais garde les %XX déjà présents (certaines valeurs de filtre du site sont déjà encodées)
local function encv(s) return (tostring(s):gsub("([^%w%-%._~%%])", function(c) return string.format("%%%02X", c:byte()) end)) end
local function rel(h) return (h:gsub("^" .. BASE:gsub("%p", "%%%0"), "")) end
-- chemin normalisé : sans domaine, ?query, # ni / final, en minuscules
local function norm(h)
    h = h:gsub("^https?://[^/]+", ""):gsub("[?#].*$", ""):gsub("/+$", "")
    return h:lower()
end
local function bad_cover(u)
    local last = (u:gsub("[?#].*$", ""):match("([^/]*)$") or ""):lower()
    return last == "" or last == "none" or last == "null" or last == "undefined" or last == "nan" or last == "false"
        or last:find("noimg", 1, true) ~= nil
end
local function cover_of(img)
    if not img then return nil end
    for _, k in ipairs({ "data-src", "data-lazy-src", "data-original", "src", "srcset" }) do
        local u = attr(img, k)
        if k == "srcset" and u then u = u:match("^%s*(%S+)") end
        if u and u ~= "" and not u:match("^data:") and not u:lower():find("placeholder", 1, true) and not u:lower():find("blank", 1, true) and not bad_cover(u) then
            return abs(dec(u))
        end
    end
    return nil
end

-- contenu équilibré de la balise ouverte (gère les <div> imbriquées)
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
-- premier élément dont la classe contient cls ; renvoie son contenu complet
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

-- ===== reconnaissance des liens =====
-- Knoxt : œuvre = /slug/ ; chapitre = /slug-chapter-N/ (tout à la racine, un seul segment)
local SKIP = { ["/series"] = 1, ["/faq"] = 1, ["/bookmarks"] = 1, ["/recruitment"] = 1,
    ["/advertise-with-us"] = 1, ["/genre"] = 1, ["/type"] = 1, ["/page"] = 1 }
local function internal(h)
    if h:match("^https?://") and not h:find("knoxt.space", 1, true) then return false end
    return true
end
local function is_work(h)
    if not internal(h) then return false end
    local p = norm(h)
    if not p:match("^/[^/]+$") then return false end
    if p:find("-chapter-", 1, true) then return false end
    return not SKIP[p]
end
local function is_chap(h)
    if not internal(h) then return false end
    return norm(h):match("^/[^/]+$") ~= nil
end

local function parse_list(html)
    local region = grab(html, "listupd") or html -- évite la barre latérale (populaires, commentaires)
    local out, idx = {}, {}
    for tag, inner_html in region:gmatch("(<a%s[^>]->)(.-)</a>") do
        local href = attr(tag, "href")
        if href and is_work(href) then
            local k = norm(href)
            local img = inner_html:match("<img[^>]->")
            local title = attr(tag, "title")
            if title == "" then title = nil end
            local name = title or (img and attr(img, "alt"))
            if name and name ~= "" then name = dec(name) else name = txt(inner_html) end
            local cover = cover_of(img)
            if cover then cover = cover:gsub("resize=151,215", "resize=300,430") end
            local it = idx[k]
            if it then
                if title and not it.titled then it.name = dec(title); it.titled = true end
                if it.name == "" and name ~= "" then it.name = name end
                if not it.cover and cover then it.cover = cover end
            else
                it = { name = name, path = rel(href), cover = cover, titled = title ~= nil }
                idx[k] = it
                out[#out + 1] = it
            end
        end
    end
    local res = {}
    for _, it in ipairs(out) do if it.name ~= "" then res[#res + 1] = it end end
    -- couvertures manquantes : og:image de la fiche (4 max pour rester rapide)
    local budget = 4
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

-- ===== filtres (formulaire /series/ du thème : genre[], type[], status, order) =====
local function opts(list) local o = {} for _, p in ipairs(list) do o[#o + 1] = { id = p[1], label = p[2] } end return o end
local ORDER_F = { key = "order", label = "Tri", default = "popular", options = opts({
    { "popular", "Populaires" }, { "update", "Dernière mise à jour" }, { "latest", "Derniers ajouts" },
    { "rating", "Note" }, { "title", "A → Z" }, { "titlereverse", "Z → A" } }) }
local STATUS_F = { key = "status", label = "Statut", default = "all", options = opts({
    { "all", "Tous" }, { "ongoing", "En cours" }, { "hiatus", "En pause" }, { "completed", "Terminé" } }) }

-- listes de secours (remplacées par celles du site dans loadFilters)
local FALLBACK_GENRES = {
    { "action", "Action" }, { "adventure", "Adventure" }, { "bl", "BL" }, { "comedy", "Comedy" }, { "drama", "Drama" },
    { "fantasy", "Fantasy" }, { "gl", "GL" }, { "historical", "Historical" }, { "horror", "Horror" },
    { "isekai", "Isekai" }, { "josei", "Josei" }, { "mature", "Mature" }, { "mystery", "Mystery" },
    { "omegaverse", "Omegaverse" }, { "psychological", "Psychological" }, { "reincarnation", "Reincarnation" },
    { "romance", "Romance" }, { "school-life", "School Life" }, { "sci-fi", "Sci-fi" }, { "seinen", "Seinen" },
    { "shounen-ai", "Shounen ai" }, { "slice-of-life", "Slice of Life" }, { "smut", "Smut" },
    { "supernatural", "Supernatural" }, { "tragedy", "Tragedy" }, { "transmigration", "Transmigration" },
    { "wuxia", "Wuxia" }, { "xianxia", "Xianxia" }, { "yaoi", "Yaoi" }, { "yuri", "Yuri" } }
local FALLBACK_TYPES = {
    { "light-novel-jp", "Light Novel (JP)" }, { "light-novel-cn", "Light Novel (CN)" }, { "web-novel", "Web Novel" },
    { "chinese-novel", "Chinese Novel" }, { "japanese-novel", "Japanese Novel" }, { "korean-novel", "Korean Novel" },
    { "original-novel", "Original Novel" }, { "published-novel", "Published Novel" },
    { "published-novel-kr", "Published Novel (KR)" }, { "short-story", "Short Story" } }

-- sélection multiple : id "" = « Tous » (rien de coché)
local function multi_opts(list)
    local o = { { id = "", label = "Tous" } }
    for _, g in ipairs(list) do o[#o + 1] = { id = g[1] or g.id, label = g[2] or g.label } end
    return o
end
local GENRE_F = { key = "genre", label = "Genres", default = "", multi = true, options = multi_opts(FALLBACK_GENRES) }
local TYPE_F  = { key = "type",  label = "Type",   default = "", multi = true, options = multi_opts(FALLBACK_TYPES) }
local FILTERS = { GENRE_F, TYPE_F, STATUS_F, ORDER_F }

local function fval(f, k)
    local v = f and f[k]
    if v == nil or v == "" or v == "all" then return nil end
    return tostring(v)
end
local function list_url(page, f)
    local q = { "page=" .. tostring(page or 1) }
    q[#q + 1] = "order=" .. enc(fval(f, "order") or ORDER_F.default)
    local st = fval(f, "status"); if st then q[#q + 1] = "status=" .. enc(st) end
    local g = fval(f, "genre")
    if g then for x in g:gmatch("[^,]+") do q[#q + 1] = "genre%5B%5D=" .. encv(x) end end
    local t = fval(f, "type")
    if t then for x in t:gmatch("[^,]+") do q[#q + 1] = "type%5B%5D=" .. encv(x) end end
    return "/series/?" .. table.concat(q, "&")
end

local ext = { id = "knoxt", name = "Knoxt.space", site = BASE, lang = "en", version = "0.2.0",
    popularFilters = FILTERS, searchFilters = {}, hasReviews = false, chapterCommentsPanel = false }

-- genres et types relus sur le site (les listes intégrées servent de secours)
local function read_group(html, name)
    local list, seen = {}, {}
    for tag, rest in html:gmatch('(<input[^>]-name="' .. name .. '%[%]"[^>]->)(.-)</li>') do
        local v = attr(tag, "value")
        local label = rest:match("<label[^>]*>(.-)</label>")
        label = label and txt(label) or ""
        label = label:gsub("^|%s*", "")
        if v and v ~= "" and not seen[v] and not label:find("^Remove term") then
            seen[v] = true
            list[#list + 1] = { v, label ~= "" and label or v }
        end
    end
    return list
end
function ext:loadFilters()
    local html = get("/series/")
    if html then
        local g = read_group(html, "genre")
        if #g >= 5 then GENRE_F.options = multi_opts(g) end
        local t = read_group(html, "type")
        if #t >= 3 then TYPE_F.options = multi_opts(t) end
    end
    self.filters_ready = true
end

function ext:popularNovels(page, options)
    page = tonumber(page) or 1
    local html, err = get(list_url(page, options and options.filters))
    if not html then
        if page > 1 then return { novels = {} } end -- fin de la liste
        return { novels = {}, error = "Site injoignable (" .. tostring(err) .. ")" }
    end
    return { novels = parse_list(html) }
end

function ext:searchNovels(term, page)
    term = tostring(term or ""):match("^%s*(.-)%s*$")
    if term == "" then return ext:popularNovels(page) end
    local url = SEARCH:gsub("{q}", function() return enc(term) end):gsub("{page}", function() return tostring(page or 1) end)
    local html, err = get(url)
    if not html then return { novels = {}, error = "Recherche impossible (" .. tostring(err) .. ")" } end
    return { novels = parse_list(html) }
end

-- ===== fiche d'une œuvre =====
local function ogp(html, p)
    return dec(html:match('property="' .. p .. '"[^>]-content="([^"]*)"')
        or html:match('content="([^"]*)"[^>]-property="' .. p .. '"') or "")
end

local function meta(html, path)
    local name = txt(html:match("<h1[^>]*entry%-title[^>]*>(.-)</h1>") or "")
    if name == "" then name = ogp(html, "og:title") end
    if name == "" then name = path end

    -- résumé : <div class="entry-content" itemprop="description">
    local summary = ""
    local s, e = html:find('itemprop="description"[^>]*>')
    if s then
        local b = inner(html, e + 1, "div")
        if b then
            local cut = b:match('^(.-)<p style="text%-align: center"') -- retire le bloc Ko-fi/Patreon
            if cut and #txt(cut) > 40 then b = cut end
            summary = para(b)
        end
    end
    if summary == "" then summary = ogp(html, "og:description") end

    local cover = cover_of(html:match('<div class="thumb"[^>]*>%s*<img[^>]->'))
    if not cover then
        local og = ogp(html, "og:image")
        if og ~= "" and not bad_cover(og) then cover = abs(og) end
    end

    local author = txt(html:match("<b>Author:</b>%s*<a[^>]*>([^<]*)</a>") or "")
    local status = txt(html:match("<b>Status:</b>%s*([^<]*)") or "")
    local genres = {}
    local gx = html:match('<div class="genxed">(.-)</div>') or ""
    for g in gx:gmatch("<a[^>]*>(.-)</a>") do
        local t = txt(g)
        if t ~= "" then genres[#genres + 1] = t end
    end

    return { name = name, path = path, cover = cover, summary = summary,
        author = author, status = status, genres = genres }
end

function ext:parseNovelMeta(path)
    local html = get(path); if not html then return nil end
    local m = meta(html, path); m.total_chapters = 0; return m
end

function ext:parseNovel(path)
    local html = get(path); if not html then return nil end
    local m = meta(html, path)
    local block = grab(html, "eplister") or html -- uniquement la liste des chapitres
    local ch, seen = {}, {}
    for tag, inner_html in block:gmatch("(<a%s[^>]->)(.-)</a>") do
        local href = attr(tag, "href")
        if href and is_chap(href) then
            local k = norm(href)
            if not seen[k] then
                local num = txt(inner_html:match('class="epl%-num"[^>]*>(.-)</div>') or "")
                local ttl = txt(inner_html:match('class="epl%-title"[^>]*>(.-)</div>') or "")
                local name
                if ttl ~= "" and ttl:lower():find("chapter", 1, true) then name = ttl
                elseif num ~= "" and ttl ~= "" then name = num .. " – " .. ttl
                elseif ttl ~= "" then name = ttl
                elseif num ~= "" then name = num
                else name = txt(inner_html) end
                if name == "" then name = "Chapter " .. (#ch + 1) end
                seen[k] = true
                ch[#ch + 1] = { name = name, path = rel(href) }
            end
        end
    end
    -- le site liste du plus récent au plus ancien : on inverse
    local rev = {}
    for i = #ch, 1, -1 do rev[#rev + 1] = ch[i] end
    for i, c in ipairs(rev) do c.chapter_number = i end
    m.chapters, m.totalPages = rev, 1
    return m
end

-- ===== texte d'un chapitre =====
function ext:parseChapter(path)
    local html = get(path); if not html then return "<p>Chapter unreachable.</p>" end
    html = html:gsub("<script.-</script>", ""):gsub("<style.-</style>", "")
    local body = grab(html, "epcontent")
    if not body then return "<p>Chapter text not found (class « epcontent »).</p>" end

    body = body:gsub("<hr%s*/?>", "<p>* * *</p>")
    local ps = {}
    for p in body:gmatch("<p%f[%s>][^>]*>(.-)</p>") do
        local t = txt(p)
        local low = t:lower()
        local promo = #t < 400 and (low:find("ko%-fi") or low:find("patreon") or low:find("paypal"))
        if not promo and (t ~= "" or p:find("<img", 1, true)) then
            ps[#ps + 1] = "<p>" .. p .. "</p>"
        end
    end
    -- retire les séparateurs « * * * » restés en fin de chapitre (avant le bloc promo)
    while #ps > 0 and txt(ps[#ps]) == "* * *" do ps[#ps] = nil end

    if #ps == 0 then
        local plain = body:gsub("<div.-</div>", "")
        if #txt(plain) < 50 then return "<p>Empty chapter.</p>" end
        return plain
    end
    return table.concat(ps)
end

return ext