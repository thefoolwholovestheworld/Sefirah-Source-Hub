-- NovelFull — source générée par Sefirah Source Hub (modèle sans IA). À relire et tester.
-- Contrat : voir extensions/mangapill.lua du plugin Sefirah.
local logger = require("logger")
local BASE   = "https://novelfull.com"
local SEARCH = "https://novelfull.com/search?keyword={q}&page={page}"
local CHAPP  = "/chapter-"
local CONT   = "chapter-c"
local UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"
local ok_bp, Bypass = pcall(require, "core.dnsbypass")
if ok_bp and Bypass then Bypass.register("novelfull.com") end

-- ===== délais : assez longs pour un serveur lent, assez courts pour ne pas bloquer l'UI =====
local REQ_TIMEOUT  = 12
local REQ_DEADLINE = 25

local function headers_for(url)
    local h = {
        ["User-Agent"]                = UA,
        ["Accept"]                    = "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
        ["Accept-Language"]           = "en-US,en;q=0.9",
        ["Connection"]                = "keep-alive",
        ["Upgrade-Insecure-Requests"] = "1",
        ["Referer"]                   = BASE .. "/",
        ["Cache-Control"]             = "max-age=0",
        ["DNT"]                       = "1",
    }
    -- headers que TOUT navigateur moderne envoie : leur absence = bot = 403
    if url:find("/ajax/", 1, true) or url:find("chapter-option", 1, true) then
        h["X-Requested-With"] = "XMLHttpRequest"
        h["Sec-Fetch-Dest"]   = "empty"
        h["Sec-Fetch-Mode"]   = "cors"
        h["Sec-Fetch-Site"]   = "same-origin"
        h["Accept"]           = "text/html,*/*;q=0.9"
    else
        h["Sec-Fetch-Dest"]   = "document"
        h["Sec-Fetch-Mode"]   = "navigate"
        h["Sec-Fetch-Site"]   = "none"
        h["Sec-Fetch-User"]   = "?1"
    end
    return h
end

local function get(p)
    local url = p:match("^https?://") and p or (BASE .. p)
    local last_err
    for try = 1, 3 do
        local body, c = require("core.net").get(url, {
            headers  = headers_for(url),
            timeout  = REQ_TIMEOUT,
            deadline = REQ_DEADLINE,
        })
        if body and #body > 2 then return body end
        last_err = c

        if c == 404 or c == 410 then break end
        if c == 403 then
            -- 403 = rate-limit probable : backoff progressif mais borné
            if try >= 3 then break end
            local wait = (try == 1) and 3 or 6
            logger.info("NovelFull: 403, pause " .. wait .. "s avant réessai " .. try)
            pcall(function() require("socket").sleep(wait) end)
        else
            if try < 3 then
                logger.info("NovelFull: échec", url, tostring(c), "essai", try)
                pcall(function() require("socket").sleep(1) end)
            end
        end
    end
    logger.warn("NovelFull: abandon", url, tostring(last_err))
    return nil, tostring(last_err)
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
local function rel(h) return (h:gsub("^"..BASE:gsub("%p","%%%0"), "")) end
local function norm(h)
    h = h:gsub("^https?://[^/]+", ""):gsub("[?#].*$", ""):gsub("/+$", "")
    return h:lower()
end
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
    local imgs = {}
    for p, tag in html:gmatch("()(<img[^>]->)") do imgs[#imgs+1] = { p = p, tag = tag } end
    local res, idx, last = {}, {}, 0
    for p, h3 in html:gmatch("()(<h3[^>]-truyen%-title[^>]->.-</h3>)") do
        local atag, ain = h3:match("(<a%s[^>]->)(.-)</a>")
        local href = atag and attr(atag, "href")
        if href and not href:find(CHAPP, 1, true) then
            local cover
            for _, im in ipairs(imgs) do
                if im.p > last and im.p < p then cover = cover_of(im.tag) or cover end
            end
            local name = attr(atag, "title")
            name = (name and name ~= "") and dec(name) or txt(ain)
            local k = norm(href)
            if name ~= "" and not idx[k] then
                idx[k] = true
                res[#res+1] = { name = name, path = rel(href), cover = cover }
            end
        end
        last = p
    end
    return res
end

local FJOIN  = {  }

local POPULAR_FILTERS = {
    { key = "list", label = "Liste", default = "most-popular", multi = false,
      options = {
        { id = "most-popular", label = "Populaires" },
        { id = "latest-release-novel", label = "Dernières sorties" },
        { id = "hot-novel", label = "Hot" },
        { id = "completed-novel", label = "Terminés" },
      } },
    { key = "genre", label = "Genre", default = "all", multi = false,
      options = {
        { id = "all", label = "Tous" },
        { id = "Harem", label = "Harem" },
        { id = "Gender+Bender", label = "Gender Bender" },
        { id = "Sci-fi", label = "Sci-fi" },
        { id = "Mature", label = "Mature" },
        { id = "Drama", label = "Drama" },
        { id = "Tragedy", label = "Tragedy" },
        { id = "Shounen", label = "Shounen" },
        { id = "Horror", label = "Horror" },
        { id = "Mystery", label = "Mystery" },
        { id = "Shoujo", label = "Shoujo" },
        { id = "Psychological", label = "Psychological" },
        { id = "Adventure", label = "Adventure" },
        { id = "School+Life", label = "School Life" },
        { id = "Xuanhuan", label = "Xuanhuan" },
        { id = "Comedy", label = "Comedy" },
        { id = "Ecchi", label = "Ecchi" },
        { id = "Martial+Arts", label = "Martial Arts" },
        { id = "Action", label = "Action" },
        { id = "Fantasy", label = "Fantasy" },
        { id = "Romance", label = "Romance" },
        { id = "Supernatural", label = "Supernatural" },
        { id = "Xianxia", label = "Xianxia" },
        { id = "Wuxia", label = "Wuxia" },
        { id = "Historical", label = "Historical" },
        { id = "Slice+of+Life", label = "Slice of Life" },
        { id = "Seinen", label = "Seinen" },
        { id = "Lolicon", label = "Lolicon" },
        { id = "Adult", label = "Adult" },
        { id = "Josei", label = "Josei" },
        { id = "Sports", label = "Sports" },
        { id = "Smut", label = "Smut" },
        { id = "Mecha", label = "Mecha" },
        { id = "Yaoi", label = "Yaoi" },
        { id = "Shounen+Ai", label = "Shounen Ai" },
        { id = "History", label = "History" },
        { id = "Martial", label = "Martial" },
        { id = "Eastern", label = "Eastern" },
        { id = "Game", label = "Game" },
        { id = "Yuri", label = "Yuri" },
        { id = "Magical+Realism", label = "Magical Realism" },
        { id = "Psychologic", label = "Psychologic" },
        { id = "Reincarnation", label = "Reincarnation" },
        { id = "System", label = "System" },
        { id = "Fan-fic", label = "Fan-fic" },
      } },
}

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
local function fval(sel, key)
    local v = sel and sel[key]
    if v == nil or v == "" or v == "all" then return nil end
    return tostring(v)
end
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
local function browse_url(page, options)
    local f = options and options.filters
    local g = fval(f, "genre")
    if g then return BASE .. "/genre/" .. g .. "?page=" .. tostring(page or 1) end
    local l = fval(f, "list") or "most-popular"
    return BASE .. "/" .. l .. "?page=" .. tostring(page or 1)
end

local ext = { id = "novelfull", name = "NovelFull", site = BASE, lang = "en", version = "0.1.1",
    popularFilters = POPULAR_FILTERS, searchFilters = {}, hasReviews = false, chapterCommentsPanel = false }

function ext:popularNovels(page, options)
    local html, err = get(browse_url(page, options))
    if not html then return { novels = {}, error = "Site injoignable (" .. tostring(err) .. ")" } end
    return { novels = parse_list(html) }
end

function ext:searchNovels(term, page, options)
    term = tostring(term or ""):match("^%s*(.-)%s*$")
    if term == "" then return ext:popularNovels(page, options) end
    local url = expand(SEARCH, options and options.filters, term, page)
    local html, err = get(url)
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
    local t3 = html:match('<h3[^>]-class="title"[^>]*>(.-)</h3>')
    if t3 and txt(t3) ~= "" then name = txt(t3) end
    local d = grab(html, "desc-text")
    if d then d = para(d); if #d > 30 then summary = d end end
    local cover = abs(dec(html:match('property="og:image"[^>]-content="([^"]*)"') or ""))
    local bk = grab(html, "book")
    local bimg = bk and bk:match("<img[^>]->")
    cover = (bimg and cover_of(bimg)) or (cover ~= "" and cover or nil)
    local author = txt(html:match("Author:</h3>%s*(<a[^>]->.-</a>)") or "")
    local status = txt(html:match("Status:</h3>%s*(<a[^>]->.-</a>)") or "")
    local genres = {}
    local gb = html:match("Genre:</h3>(.-)</div>")
    if gb then for g in gb:gmatch("<a[^>]*>(.-)</a>") do genres[#genres+1] = txt(g) end end
    return { name = name, path = path, cover = cover,
        summary = summary, author = author, status = status, genres = genres }
end

function ext:parseNovelMeta(path)
    local html = get(path); if not html then return nil end
    local m = meta(html, path); m.total_chapters = 0; return m
end

local function chap_links(html, ch, seen)
    for ul in html:gmatch("<ul[^>]-list%-chapter[^>]->(.-)</ul>") do
        for tag, ain in ul:gmatch("(<a%s[^>]->)(.-)</a>") do
            local href = attr(tag, "href")
            if href and href:find(CHAPP, 1, true) and not seen[norm(href)] then
                seen[norm(href)] = true
                local name = attr(tag, "title")
                name = (name and name ~= "") and dec(name) or txt(ain)
                if name == "" then name = "Chapitre " .. (#ch + 1) end
                ch[#ch+1] = { name = name, path = rel(href) }
            end
        end
    end
end

function ext:parseNovel(path)
    local html = get(path); if not html then return nil end
    local m, ch, seen = meta(html, path), {}, {}

    -- Nombre de pages de chapitres annoncé par la pagination de la page 1
    local maxp = 1
    for n in html:gmatch("[?&]page=(%d+)") do maxp = math.max(maxp, tonumber(n)) end

    -- 1) tentative ajax : liste complète en une requête, mais peut renvoyer 403
    local id = html:match('data%-novel%-id="(%d+)"')
    local ajax_ok = false
    if id then
        local ax = get("/ajax/chapter-option?novelId=" .. id)
        if ax and #ax > 100 then
            for v, label in ax:gmatch('<option[^>]-value="([^"]+)"[^>]*>(.-)</option>') do
                if not seen[norm(v)] then
                    seen[norm(v)] = true
                    local nm = txt(label)
                    if nm == "" then nm = "Chapitre " .. (#ch + 1) end
                    ch[#ch+1] = { name = nm, path = rel(v) }
                end
            end
            ajax_ok = #ch > 0
        end
    end

    -- 2) BUG CORRIGÉ : on pagine TOUJOURS si l'ajax a échoué,
    --    ou si l'ajax a donné moins que ce que la pagination laisse attendre
    --    (chaque page HTML contient 50 chapitres ; si maxp=10, on attend ~500 chapitres).
    local ajax_suspect = ajax_ok and maxp > 1 and #ch < 50 * (maxp - 1)
    if not ajax_ok or ajax_suspect then
        chap_links(html, ch, seen)
        local limit = math.min(maxp, 80)   -- plafond raisonnable : ~4000 chapitres
        for pg = 2, limit do
            local h = get(path .. "?page=" .. pg .. "&per-page=50")
            if h then chap_links(h, ch, seen) end
        end
    end

    for i, c in ipairs(ch) do c.chapter_number = i end
    m.chapters, m.totalPages, m.total_chapters = ch, 1, #ch
    return m
end

function ext:parseChapter(path)
    local html = get(path); if not html then return "<p>Chapitre injoignable.</p>" end
    html = html:gsub("<script.-</script>", ""):gsub("<style.-</style>", ""):gsub("<iframe.-</iframe>", ""):gsub("<ins.-</ins>", "")
    local body = CONT ~= "" and grab(html, CONT) or nil
    if not body then
        local ps, n = {}, 0
        for p in html:gmatch("<p%f[%s>][^>]*>(.-)</p>") do
            local t = txt(p)
            if #t > 1 then ps[#ps+1] = "<p>" .. p .. "</p>"; n = n + #t end
        end
        if #ps >= 3 and n > 300 then body = table.concat(ps) end
    end
    if not body or #body < 50 then return "<p>Texte du chapitre introuvable (classe « " .. CONT .. " »).</p>" end
    body = body:gsub("<(%a%w*)[^>]*>%s*If you find any errors.-</%1>", "")
    body = body:gsub("If you find any errors.-as soon as possible%.?", "")
    return body
end

return ext