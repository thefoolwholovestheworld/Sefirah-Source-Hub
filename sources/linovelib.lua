-- Linovelib (tw.linovelib.com) — light novels en chinois traditionnel. Source écrite à la main d'après les pages fournies.
-- Contrat : voir extensions/mangapill.lua du plugin Sefirah.
local logger = require("logger")
local BASE   = "https://tw.linovelib.com"
local UA = "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36"

local function get(p)
    local url = p:match("^https?://") and p or (BASE .. p)
    local body, code = require("core.net").get(url, { headers = { ["User-Agent"] = UA, ["Referer"] = BASE .. "/" }, timeout = 15 })
    if body and #body > 2 then return body end
    logger.warn("linovelib: échec", url, tostring(code))
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


-- ===== Linovelib =====
-- fiche : /novel/<id>.html   catalogue : /novel/<id>/catalog   chapitre : /novel/<id>/<cid>.html (suite : <cid>_2.html …)
local function book_id(h) return h and h:match("/novel/(%d+)%.html") end
local function is_img_ok(u) return u and u ~= "" and not u:match("^data:") and not u:find("book%-cover%-no", 1) end
local function pick_cover(img)
    if not img then return nil end
    for _, k in ipairs({ "data-src", "data-original", "data-lazy-src", "src" }) do
        local u = attr(img, k)
        if is_img_ok(u) then return abs(dec(u)) end
    end
    return nil
end

-- liste d'œuvres : n'importe quel lien /novel/<id>.html (avec ou sans image)
local function parse_list(html)
    local cut = html:find('id="searchPopup"', 1, true)
    if cut then html = html:sub(1, cut - 1) end
    local out, idx = {}, {}
    for tag, ih in html:gmatch("(<a%s[^>]->)(.-)</a>") do
        local href = attr(tag, "href")
        local id = book_id(href)
        if id then
            local img = ih:match("<img[^>]->")
            local name = attr(tag, "title") or (img and attr(img, "alt"))
            if not name or name == "" then
                name = txt(ih:match("<h%d[^>]*>(.-)</h%d>") or ih)
            else
                name = dec(name)
            end
            local cover = pick_cover(img)
            local it = idx[id]
            if it then
                if it.name == "" and name ~= "" then it.name = name end
                if not it.cover and cover then it.cover = cover end
            else
                it = { name = name or "", path = "/novel/" .. id .. ".html", cover = cover }
                idx[id] = it
                out[#out + 1] = it
            end
        end
    end
    local res = {}
    for _, it in ipairs(out) do
        if it.name ~= "" then res[#res + 1] = it end
    end
    return res
end

local POPULAR_FILTERS = {
    { key = "rank", label = "榜單 / Classement", default = "all", multi = false, options = {
        { id = "all", label = "最新發布 (dernières publications)" },
        { id = "monthvisit", label = "月點擊榜" },
        { id = "weekvisit", label = "周點擊榜" },
        { id = "monthvote", label = "月推薦榜" },
        { id = "weekvote", label = "周推薦榜" },
        { id = "monthflower", label = "月鮮花榜" },
        { id = "weekflower", label = "周鮮花榜" },
        { id = "monthegg", label = "月雞蛋榜" },
        { id = "weekegg", label = "周雞蛋榜" },
        { id = "postdate", label = "最新入庫" },
        { id = "goodnum", label = "收藏榜" },
        { id = "newhot", label = "新書榜" },
        { id = "topfull_postdate", label = "完本 · 最新" },
        { id = "topfull_weekvote", label = "完本 · 周推薦" },
    } },
    { key = "tag", label = "類型 / Genre (sans classement)", default = "all", multi = false, options = {
        { id = "all", label = "Tous" },
        { id = "15", label = "奇幻" },
        { id = "222", label = "歡樂向" },
        { id = "18", label = "戰鬥" },
        { id = "61", label = "冒險" },
        { id = "223", label = "人外" },
    } },
}

local ext = { id = "linovelib", name = "Linovelib", site = BASE, lang = "zh", version = "0.3.0",
    popularFilters = POPULAR_FILTERS, searchFilters = {}, hasReviews = false, chapterCommentsPanel = false }

-- Parcourir : liste des dernières publications du « 文庫 » (page 1, 2, …) ; repli : page d'accueil
local function list_url(p, sel)
    local rank = sel and sel.rank
    local tag = sel and sel.tag
    if rank and rank ~= "" and rank ~= "all" then
        local sub = rank:match("^topfull_(.+)$")
        if sub then return "/topfull/" .. sub .. "/" .. p .. ".html" end
        return "/top/" .. rank .. "/" .. p .. ".html"
    end
    if tag and tag ~= "" and tag ~= "all" then
        return "/wenku/lastupdate_" .. tag .. "_0_0_0_0_0_0_" .. p .. "_0.html"
    end
    return "/wenku/postdate_0_0_0_0_0_0_0_" .. p .. "_0.html"
end

function ext:popularNovels(page, options)
    local p = tonumber(page) or 1
    local sel = options and options.filters or {}
    local html = get(list_url(p, sel))
    local list = html and parse_list(html) or {}
    if #list == 0 and p == 1 and (not sel.rank or sel.rank == "all") and (not sel.tag or sel.tag == "all") then
        html = get("/")
        list = html and parse_list(html) or {}
    end
    if #list == 0 then return { novels = {}, error = "Site injoignable ou liste vide" } end
    return { novels = list }
end

-- Recherche : le site n'a que Google CSE ; on essaie les adresses de recherche connues de la famille linovelib,
-- puis, en dernier recours, on filtre les premières pages du 文庫 par titre.
local function match_all(list, term)
    local out, low = {}, term:lower()
    for _, it in ipairs(list) do
        if it.name:lower():find(low, 1, true) then out[#out + 1] = it end
    end
    return out
end
function ext:searchNovels(term, page, options)
    term = tostring(term or ""):match("^%s*(.-)%s*$")
    if term == "" then return ext:popularNovels(page, options) end
    local p = tonumber(page) or 1
    local q = enc(term)
    for _, u in ipairs({
        "/search/" .. q .. "/" .. p .. ".html",
        "/search.php?searchtype=all&searchkey=" .. q .. "&page=" .. p,
        "/modules/article/search.php?searchtype=articlename&searchkey=" .. q .. "&page=" .. p,
    }) do
        local html = get(u)
        if html then
            local list = parse_list(html)
            if #list > 0 then return { novels = list } end
        end
    end
    if p > 1 then return { novels = {} } end
    local found = {}
    for i = 1, 8 do
        local html = get("/wenku/postdate_0_0_0_0_0_0_0_" .. i .. "_0.html")
        if not html then break end
        for _, it in ipairs(match_all(parse_list(html), term)) do found[#found + 1] = it end
        if #found >= 20 then break end
    end
    return { novels = found }
end

local function meta(html, path)
    local name = txt(html:match('<h1[^>]-class="book%-title"[^>]*>(.-)</h1>') or html:match("<h1[^>]*>(.-)</h1>") or "")
    if name == "" then name = dec(html:match('property="og:title"[^>]-content="([^"]*)"') or path) end
    local author = txt(html:match('class="authorname"[^>]*>(.-)</span>') or "")
    local sm = html:match("<content>(.-)</content>")
    local summary = sm and para(sm) or dec(html:match('property="og:description"[^>]-content="([^"]*)"') or "")
    local cover = pick_cover(html:match('<img[^>]-class="book%-cover"[^>]->'))
        or abs(dec(html:match('property="og:image"[^>]-content="([^"]*)"') or ""))
    local genres = {}
    for g in (html:match('class="tag%-small%-group[^"]*"[^>]*>(.-)</span>') or ""):gmatch("<a[^>]*>(.-)</a>") do
        genres[#genres + 1] = txt(g)
    end
    local status = ""
    for blk in html:gmatch('<p class="book%-meta book%-layout%-inline">(.-)</p>') do
        if blk:find("連載", 1, true) then status = "連載" elseif blk:find("完結", 1, true) or blk:find("完本", 1, true) then status = "完結" end
    end
    return { name = name, path = path, cover = cover, summary = summary, author = author, status = status, genres = genres }
end

function ext:parseNovelMeta(path)
    local html = get(path); if not html then return nil end
    local m = meta(html, path); m.total_chapters = 0; return m
end

-- chapitres d'une page de catalogue (ou de volume) : tous les liens /novel/<id>/<cid>.html, dans l'ordre, avec le nom du volume
local function collect_chapters(html, bid, seen, ch, vol)
    for li_cls, li in html:gmatch('<li([^>]*)>(.-)</li>') do
        local c = attr(li_cls, "class") or ""
        if c:find("chapter%-bar") then
            local v = txt(li)
            if v ~= "" then vol = v end
        else
            local href = li:match('<a[^>]-href="([^"]*)"')
            local cid = href and (href:match("/novel/" .. bid .. "/(%d+)%.html") or href:match("^%.?/?(%d+)%.html$"))
            if cid and not seen[cid] then
                seen[cid] = true
                local name = txt(li)
                if name == "" then name = "Chapitre " .. (#ch + 1) end
                if vol and vol ~= "" then name = vol .. " · " .. name end
                ch[#ch + 1] = { name = name, path = "/novel/" .. bid .. "/" .. cid .. ".html" }
            end
        end
    end
    -- repli : liens simples si la page n'utilise pas de <li> (ou si un seul chapitre a été vu)
    if #ch <= 1 then
        for k in pairs(seen) do seen[k] = nil end
        for i = #ch, 1, -1 do ch[i] = nil end
        for tag, ih in html:gmatch("(<a%s[^>]->)(.-)</a>") do
            local href = attr(tag, "href")
            local cid = href and (href:match("/novel/" .. bid .. "/(%d+)%.html") or href:match("^%.?/?(%d+)%.html$"))
            if cid and not seen[cid] then
                seen[cid] = true
                local name = txt(ih)
                if name == "" then name = "Chapitre " .. (#ch + 1) end
                ch[#ch + 1] = { name = name, path = "/novel/" .. bid .. "/" .. cid .. ".html" }
            end
        end
    end
    return vol
end

function ext:parseNovel(path)
    local html = get(path); if not html then return nil end
    local bid = book_id(path) or book_id(html:match('rel="canonical"[^>]-href="([^"]*)"') or "") or ""
    local m, ch, seen = meta(html, path), {}, {}
    if bid ~= "" then
        local cat = get("/novel/" .. bid .. "/catalog")
        if cat then collect_chapters(cat, bid, seen, ch, nil) end
        if #ch == 0 then -- repli : pages de volumes (/novel/<id>/vol_<vid>.html) listées sur la fiche
            local vols = {}
            for href in html:gmatch('href="([^"]*/novel/' .. bid .. '/vol_%d+%.html)"') do vols[#vols + 1] = href end
            for i = #vols, 1, -1 do
                local vh = get(vols[i])
                if vh then collect_chapters(vh, bid, seen, ch, nil) end
            end
        end
    end
    for i, c in ipairs(ch) do c.chapter_number = i end
    m.chapters, m.totalPages = ch, 1
    return m
end

-- un chapitre est découpé en pages : <cid>.html, <cid>_2.html, <cid>_3.html … (lien « page suivante » = prerender)
local function chapter_part(html)
    local box = grab(html, 'acontent') or ""
    box = box:gsub("<script.-</script>", ""):gsub("<style.-</style>", "")
    box = box:gsub("<img[^>]->", function(tag)
        local u = attr(tag, "data-src") or attr(tag, "src")
        if is_img_ok(u) then return '<img src="' .. abs(dec(u)) .. '"/>' end
        return ""
    end)
    return box
end

function ext:parseChapter(path)
    local bid, cid = path:match("/novel/(%d+)/(%d+)")
    local texts, url, n = {}, path, 0
    while url and n < 25 do
        n = n + 1
        local html = get(url); if not html then break end
        local part = chapter_part(html)
        if #part > 20 then texts[#texts + 1] = part end
        local nxt = html:match('rel="prerender"[^>]-href="([^"]*)"') or html:match('href="([^"]*)"[^>]-rel="prerender"')
        local nb, nc, np = "", "", nil
        if nxt then nb, nc, np = nxt:match("/novel/(%d+)/(%d+)(_?%d*)%.html") end
        if nxt and nb == bid and nc == cid and np and np ~= "" then url = rel(nxt) else url = nil end
    end
    if #texts == 0 then return "<p>Impossible d'extraire le contenu du chapitre.</p>" end
    return table.concat(texts, NL)
end

return ext
