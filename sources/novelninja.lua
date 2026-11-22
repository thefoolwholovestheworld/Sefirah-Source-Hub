-- Sefirah fork of Mythos (GPL-3.0). novelninja.lua v0.3.2
local logger = require("logger")
local T = require("core.i18n").T

local BASE  = "https://novelninja.xyz"
local MROOT = "/novel"
local CHAPP = "/chapter-"
local CONT  = "reading-content"
local UA = "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36"

local function write_debug(text)
    pcall(function()
        local DataStorage = require("datastorage")
        local dir = DataStorage:getSettingsDir() .. "/sefirah"
        local lfs = require("libs/libkoreader-lfs")
        if lfs.attributes(dir, "mode") ~= "directory" then lfs.mkdir(dir) end
        local f = io.open(dir .. "/novelninja_last_error.txt", "w")
        if f then f:write(text); f:close() end
    end)
end

local function get(p)
    local url = p:match("^https?://") and p or (BASE .. p)
    local body, code = require("core.net").get(url, {
        headers = { ["User-Agent"] = UA, ["Referer"] = BASE .. "/" }, timeout = 15,
    })
    if body and #body > 2 then return body end
    logger.warn("NovelNinja: échec", url, tostring(code))
    return nil, tostring(code)
end

local function http_post(url, body, referer)
    local ok_l, ltn12 = pcall(require, "ltn12"); if not ok_l then return nil end
    local ok_r, req = pcall(require, url:match("^https") and "ssl.https" or "socket.http"); if not ok_r then return nil end
    body = body or ""
    local sink = {}
    local okc, ok, code = pcall(req.request, {
        url = url, method = "POST",
        headers = {
            ["User-Agent"] = UA,
            ["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8",
            ["Content-Length"] = tostring(#body),
            ["X-Requested-With"] = "XMLHttpRequest",
            ["Origin"] = BASE, ["Referer"] = referer or (BASE .. "/"), ["Accept"] = "*/*",
        },
        source = ltn12.source.string(body), sink = ltn12.sink.table(sink), timeout = 15,
    })
    local resp = table.concat(sink)
    if okc and ok and code == 200 and #resp > 20 then return resp end
    return nil
end

local function cp2utf8(c)
    if not c or c <= 0 or c > 0x10FFFF then return nil end
    if c < 0x80 then return string.char(c) end
    if c < 0x800 then return string.char(0xC0 + math.floor(c / 64), 0x80 + c % 64) end
    if c < 0x10000 then return string.char(0xE0 + math.floor(c / 4096), 0x80 + math.floor(c / 64) % 64, 0x80 + c % 64) end
    return string.char(0xF0 + math.floor(c / 262144), 0x80 + math.floor(c / 4096) % 64, 0x80 + math.floor(c / 64) % 64, 0x80 + c % 64)
end
local ENT = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " ",
    rsquo = "’", lsquo = "‘", ldquo = "“", rdquo = "”", hellip = "…", ndash = "–", mdash = "—", laquo = "«", raquo = "»" }
local function dec(s)
    if not s then return s end
    return (s:gsub("&(#?%w+);", function(e)
        local n = e:match("^#[xX](%x+)$"); if n then return cp2utf8(tonumber(n, 16)) end
        n = e:match("^#(%d+)$"); if n then return cp2utf8(tonumber(n)) end
        return ENT[e]
    end))
end
local function txt(h)
    h = (h or ""):gsub("<[^>]+>", " ")
    h = dec(h):gsub("%s+", " ")
    return (h:match("^%s*(.-)%s*$"))
end
local NL = string.char(10)
local function para(h)
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
local function rel(h) return (h:gsub("^" .. BASE:gsub("%p", "%%%0"), "")) end
local function norm(h) return (h:gsub("^https?://[^/]+", ""):gsub("[?#].*$", ""):gsub("/+$", ""):lower()) end

local function cover_of(img)
    if not img then return nil end
    for _, k in ipairs({ "data-src", "data-lazy-src", "data-original", "src", "srcset" }) do
        local u = attr(img, k)
        if k == "srcset" and u then u = u:match("^%s*(%S+)") end
        if u and u ~= "" and not u:match("^data:") and not u:lower():find("placeholder", 1, true)
           and not u:lower():find("blank", 1, true) then
            return abs(dec(u))
        end
    end
    return nil
end

local function inner(html, from, tn)
    local open, close = "<" .. tn, "</" .. tn
    local depth, p = 1, from
    while true do
        local a = html:find(open, p, true); local b = html:find(close, p, true)
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

-- ─── parse_list ROBUSTE (Madara = <h3><a> pour le titre du roman) ─────────────
-- Cette version utilise le standard Madara : tout roman est dans un <h3><a href="/...">Titre</a></h3>
-- On accepte tous les liens qui ne sont ni chapitre, ni pagination, ni feed, ni recherche.
local function parse_list(html)
    local out, idx = {}, {}
    -- Étape 1 : collecter tous les <img> de la page avec leur position (pour les couvertures)
    local imgs = {}
    for p, tag in html:gmatch("()(<img[^>]->)") do imgs[#imgs+1] = { p = p, tag = tag } end
    -- Étape 2 : parcourir tous les <h3><a href="...">Titre</a></h3>
    local last_pos = 0
    for pos, block in html:gmatch("()<h3[^>]*>(.-)</h3>") do
        local href = block:match('<a[^>]-href="([^"]+)"') or block:match("<a[^>]-href='([^']+)'")
        if href then
            local k = norm(href)
            if k ~= "" and k ~= MROOT
               and not k:find(CHAPP, 1, true)
               and not k:find("/page/", 1, true)
               and not k:find("/feed", 1, true)
               and not k:find("/search", 1, true)
               and not k:find("?s=", 1, true)
               and not idx[k] then
                -- titre : préférer l'attribut title, sinon le texte du lien
                local title = block:match('<a[^>]-title="([^"]+)"')
                if not title then title = txt(block:match(">([^<]+)</a>") or "") end
                title = txt(title or "")
                if title ~= "" then
                    -- couverture : dernier <img> AVANT ce <h3>
                    local cover
                    for i = #imgs, 1, -1 do
                        if imgs[i].p > last_pos and imgs[i].p < pos then
                            cover = cover_of(imgs[i].tag) or cover
                        end
                        if imgs[i].p < pos - 3000 then break end
                    end
                    idx[k] = true
                    out[#out+1] = { name = title, path = rel(href), cover = cover }
                    last_pos = pos
                end
            end
        end
    end
    return out
end

local function list_url(page, order)
    local p = tonumber(page) or 1
    return BASE .. MROOT .. (p > 1 and ("/page/" .. p) or "") .. "/?m_orderby=" .. order
end

local function parse_meta(html, path)
    local t = html:match("<h1[^>]*>(.-)</h1>")
    if t then t = t:gsub("<span[^>]-badges[^>]*>.-</span>", "") end
    local name = t and txt(t) or ""
    if name == "" then name = dec(html:match('property="og:title"[^>]-content="([^"]*)"') or "") end
    if name == "" then name = path end
    local og = html:match('property="og:description"[^>]-content="([^"]*)"')
        or html:match('content="([^"]*)"[^>]-property="og:description"') or ""
    local summary = dec(og)
    local sm = grab(html, "summary__content", 20) or grab(html, "description-summary", 20)
    if sm then local d = para(sm); if #d > 40 then summary = d end end
    local author = html:match('class="author%-content"[^>]*>(.-)</div>')
    local status = html:match("<h5>%s*Status%s*</h5>.-summary%-content[^>]*>(.-)</div>")
        or html:match("post%-status.-summary%-content[^>]*>(.-)</div>")
    local genres = {}
    local g = html:match('class="genres%-content"[^>]*>(.-)</div>')
    if g then for x in g:gmatch("<a[^>]*>(.-)</a>") do genres[#genres + 1] = txt(x) end end
    return {
        name = name, path = path,
        cover = abs(dec(html:match('property="og:image"[^>]-content="([^"]*)"'))),
        summary = summary, author = author and txt(author) or "",
        status = status and txt(status) or "", genres = genres,
    }
end

local function collect(html, path, seen, ch)
    local pk = norm(path)
    for tag, ih in html:gmatch("(<a%s[^>]->)(.-)</a>") do
        local href = attr(tag, "href")
        if href then
            local k = norm(href)
            if not seen[k] and k ~= pk and k:find(pk, 1, true) and k:find(CHAPP, 1, true) then
                seen[k] = true
                local name = txt(ih)
                if name == "" then name = dec(attr(tag, "title") or "") end
                if name == "" then name = T("Chapitre ") .. (#ch + 1) end
                ch[#ch + 1] = { name = name, path = rel(href) }
            end
        end
    end
end

local function chapnum(c)
    local a, b = c.path:lower():match("chapter%-(%d+)%-?(%d*)")
    if not a then return nil end
    return tonumber(a) + ((b ~= "" and #b <= 2) and tonumber(b) / (10 ^ #b) or 0)
end

local function sort_chapters(ch)
    local all = #ch > 0
    for _, c in ipairs(ch) do
        c._n = chapnum(c); if not c._n then all = false end
    end
    if all then
        table.sort(ch, function(x, y)
            if x._n ~= y._n then return x._n < y._n end
            return x.path < y.path
        end)
    end
    for i, c in ipairs(ch) do
        if c.name:match("^[Rr]ead%s") and c._n then c.name = T("Chapitre ") .. c._n end
        c._n = nil; c.chapter_number = i
    end
    return ch
end

local function find_post_id(html)
    return html:match('id="manga%-chapters%-holder"[^>]-data%-id="(%d+)"')
        or html:match('data%-id="(%d+)"[^>]-id="manga%-chapters%-holder"')
        or html:match('class="rating%-post%-id"[^>]-value="(%d+)"')
        or html:match("postid%-(%d+)")
end

local function fetch_chapters(html, path)
    local page_ch = {}
    collect(html, path, {}, page_ch)
    if #page_ch > 2 and not html:find("manga-chapters-holder", 1, true) then
        return sort_chapters(page_ch)
    end
    local ch, seen = {}, {}
    local rp = path:gsub("^https?://[^/]+", ""):gsub("/+$", "")
    local r1 = http_post(BASE .. rp .. "/ajax/chapters/", "", BASE .. rp .. "/")
    if r1 then collect(r1, path, seen, ch) end
    if #ch == 0 then
        local r1b = get(rp .. "?style=list")
        if r1b then collect(r1b, path, seen, ch) end
    end
    if #ch == 0 then
        local id = find_post_id(html)
        if id then
            local r2 = http_post(BASE .. "/wp-admin/admin-ajax.php",
                "action=manga_get_chapters&manga=" .. id, BASE .. rp .. "/")
            if r2 then collect(r2, path, seen, ch) end
        end
    end
    if #ch == 0 then ch = page_ch end
    return sort_chapters(ch)
end

-- ── Filtres ──
local function filter_defs(sort_default)
    return {
        { key = "sort", label = T("Tri"), default = sort_default, options = {
            { id = "", label = T("Pertinence") },
            { id = "latest", label = T("Dernières mises à jour") },
            { id = "views", label = T("Populaires") },
            { id = "trending", label = T("Tendance") },
            { id = "rating", label = T("Mieux notés") },
            { id = "alphabet", label = T("A-Z") },
            { id = "new-manga", label = T("Nouveautés") },
        } },
        { key = "genre", label = T("Genre"), default = "", multi = true, options = {
        { id = "action", label = "Action" }, { id = "adventure", label = "Adventure" },
        { id = "comedy", label = "Comedy" }, { id = "drama", label = "Drama" },
        { id = "fantasy", label = "Fantasy" }, { id = "harem", label = "Harem" },
        { id = "isekai", label = "Isekai" }, { id = "reincarnation", label = "Reincarnation" },
        { id = "romance", label = "Romance" }, { id = "school-life", label = "School Life" },
        { id = "sci-fi", label = "Sci-Fi" }, { id = "slice-of-life", label = "Slice of Life" },
        } },
        { key = "genre_op", label = T("Genres combinés"), default = "", options = {
            { id = "", label = T("Au moins un (OU)") }, { id = "1", label = T("Tous (ET)") },
        } },
        { key = "status", label = T("Statut"), default = "", options = {
            { id = "", label = T("Tous") }, { id = "on-going", label = T("En cours") },
            { id = "end", label = T("Terminé") }, { id = "canceled", label = T("Annulé") },
            { id = "on-hold", label = T("En pause") }, { id = "upcoming", label = T("À venir") },
        } },
    }
end

local function search_url(page, term, f)
    local p = tonumber(page) or 1
    local u = BASE .. (p > 1 and ("/page/" .. p .. "/") or "/") .. "?s=" .. enc(term or "") .. "&post_type=wp-manga"
    for g in tostring(f.genre or ""):gmatch("[^,]+") do u = u .. "&genre%5B%5D=" .. enc(g) end
    if (f.genre or "") ~= "" and (f.genre_op or "") ~= "" then u = u .. "&op=" .. enc(f.genre_op) end
    if (f.status or "") ~= "" then u = u .. "&status%5B%5D=" .. enc(f.status) end
    if (f.sort or "") ~= "" then u = u .. "&m_orderby=" .. enc(f.sort) end
    return u
end

local function has_filters(f)
    return f and (((f.genre or "") ~= "") or ((f.status or "") ~= ""))
end

local ext = { id = "novelninja", name = "NovelNinja", site = BASE, lang = "en", version = "0.3.2",
    hasReviews = false, chapterCommentsPanel = false }

ext.popularFilters = filter_defs("views")
ext.searchFilters  = filter_defs("")

function ext:popularNovels(page, options)
    local f = options and options.filters
    local p = tonumber(page) or 1
    -- URL avec filtres si présents, sinon URL catalogue
    local url = list_url(p, (f and f.sort and f.sort ~= "" and f.sort) or "views")
    if has_filters(f) then url = search_url(p, "", f) end
    local html, err = get(url)
    if not html then
        if p > 1 then return { novels = {} } end
        return { novels = {}, error = T("Site injoignable (") .. tostring(err) .. ")" }
    end
    local list = parse_list(html)
    -- ★ REPLI : si les filtres ne donnent rien, on retente le catalogue brut (sans filtres)
    if #list == 0 and has_filters(f) and p == 1 then
        local h2 = get(list_url(1, "views"))
        if h2 then list = parse_list(h2) end
    end
    if #list == 0 and p == 1 then
        local sample = {}
        for tag in html:gmatch("<a%s[^>]->") do
            local h = tag:match('href="([^"]+)"')
            if h and #sample < 15 then sample[#sample+1] = h end
        end
        write_debug("popularNovels VIDE\nURL : " .. url
            .. "\nTaille : " .. #html
            .. "\n<h3> trouvés : " .. select(2, html:gsub("<h3", ""))
            .. "\n15 href :\n" .. table.concat(sample, "\n"))
    end
    return { novels = list }
end

function ext:searchNovels(term, page, options)
    term = tostring(term or ""):match("^%s*(.-)%s*$")
    local f = options and options.filters or {}
    if term == "" and not has_filters(f) then return ext:popularNovels(page) end
    local p = tonumber(page) or 1
    local url = search_url(p, term, f)
    local html, err = get(url)
    if not html then
        if p > 1 then return { novels = {} } end
        return { novels = {}, error = T("Recherche impossible (") .. tostring(err) .. ")" }
    end
    local list = parse_list(html)
    if #list == 0 and p == 1 then
        write_debug("searchNovels VIDE\nURL : " .. url .. "\nTaille : " .. #html)
    end
    return { novels = list }
end

function ext:parseNovelMeta(path)
    local html = get(path); if not html then return nil end
    local m = parse_meta(html, path); m.total_chapters = 0; return m
end

function ext:parseNovel(path)
    local html = get(path); if not html then return nil end
    local m = parse_meta(html, path)
    m.chapters, m.totalPages = fetch_chapters(html, path), 1
    return m
end

local JUNK = { "breadcrumb", "chapter-nav", "nav-", "navigation", "wp-manga-nav", "select", "btn",
    "button", "comment", "respond", "related", "editor", "widget", "sidebar", "reading-options",
    "entry-header", "adsbygoogle", "code-block", "share", "social", "popular", "rating", "bookmark" }
local STOPS = { 'id="comments"', "id='comments'", "comments-area", "comment-respond", 'id="respond"',
    "comments for chapter", "manga discussion", "leave a reply", "wp-manga-chapter-comments",
    "editor choices", "you may also like", "related novels" }

local function junk_key(key)
    for _, j in ipairs(JUNK) do if key:find(j, 1, true) then return true end end
    return false
end
local function strip_junk(html)
    local out, pos = {}, 1
    while true do
        local s, e, tn, attrs = html:find("<(%a%w*)(%s[^>]*)>", pos)
        if not s then break end
        local key = ((attr(attrs, "class") or "") .. " " .. (attr(attrs, "id") or "")):lower()
        local body = junk_key(key) and inner(html, e + 1, tn) or nil
        if body then
            out[#out+1] = html:sub(pos, s - 1)
            local gt = html:find(">", e + 1 + #body, true)
            pos = (gt or (e + #body)) + 1
        else
            out[#out+1] = html:sub(pos, e); pos = e + 1
        end
    end
    out[#out+1] = html:sub(pos)
    return table.concat(out)
end
local function cut_after(html)
    local low, cut = html:lower(), nil
    for _, m in ipairs(STOPS) do
        local i = low:find(m, 1, true); if i and (not cut or i < cut) then cut = i end
    end
    if not cut then return html end
    local head = html:sub(1, cut - 1)
    return head:match("^(.*)<[^<]*$") or head
end
local JUNK_TXT = { "leave a reply", "cancel reply", "required fields", "your email address" }
local function clean_chapter(h, strict)
    h = cut_after(h)
    local tl = grab(h, "text-left", 100)
    if tl and select(2, tl:gsub("<p[%s>]", "")) >= 2 then h = tl end
    h = strip_junk(h)
    local ps, n = {}, 0
    for p in h:gmatch("<p%f[%s>][^>]*>(.-)</p>") do
        local t = txt(p)
        local low, bad = t:lower(), false
        for _, j in ipairs(JUNK_TXT) do if low:find(j, 1, true) then bad = true end end
        if #t > 0 and not bad then ps[#ps+1] = "<p>" .. p .. "</p>"; n = n + #t end
    end
    if strict then
        if #ps >= 3 and n > 300 then return table.concat(ps) end
        return nil
    end
    if #ps >= 1 then return table.concat(ps) end
    return nil
end

function ext:parseChapter(path)
    local html = get(path)
    if not html then return "<p>" .. T("Chapitre injoignable.") .. "</p>" end
    html = html:gsub("<script.-</script>", ""):gsub("<style.-</style>", "")
    local box = grab(html, CONT)
    local body = box and clean_chapter(box, false)
    if not body then body = clean_chapter(html, true) end
    if not body or #body < 50 then
        return "<p>" .. T("Texte du chapitre introuvable.") .. "</p>"
    end
    return body
end

return ext