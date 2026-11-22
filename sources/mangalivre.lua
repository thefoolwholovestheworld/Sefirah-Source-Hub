-- Mangalivre — source générée par Sefirah Source Hub (modèle sans IA). À relire et tester.
-- Contrat : voir extensions/mangapill.lua du plugin Sefirah.
local logger = require("logger")
local T = require("core.i18n").T
local BASE   = "https://mangalivre.to"
local SEARCH = "https://mangalivre.to/?s={q}&post_type=wp-manga"
local LISTP  = "/manga/"
local CHAPP  = "/capitulo-"
local CONT   = "reading-content"
local UA = "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36"

local function get(p)
    local url = p:match("^https?://") and p or (BASE .. p)
    local body, code = require("core.net").get(url, { headers = { ["User-Agent"] = UA, ["Referer"] = BASE .. "/" }, timeout = 15 })
    if body and #body > 2 then return body end
    logger.warn("Mangalivre: échec", url, tostring(code))
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
local function para(h)
    h = (h or ""):gsub("<script.-</script>", ""):gsub("<style.-</style>", "")
    h = h:gsub("</p>", NL .. NL):gsub("<br%s*/?>", NL):gsub("<[^>]+>", "")
    h = dec(h):gsub(string.char(13), ""):gsub(" +", " ")
    h = h:gsub(" *" .. NL .. " *", NL):gsub(NL .. NL .. "+", NL .. NL)
    return (h:match("^%s*(.-)%s*$"))
end

-- ===== nettoyage de la description : retire les paragraphes publicitaires du site =====
local SPAM = { "manga livre", "mangalivre", "melhor op", "melhores mang", "nosso time",
    "outras formas", "entretenimento", "divertir", "mangás online", "mangas online" }
local function clean_summary(s)
    if not s or s == "" then return s end
    -- coupe tout ce qui suit "Por que ler..." / "Leitura recomendada" / "Mostrar mais"
    local low, cut = s:lower(), nil
    for _, k in ipairs({ "por que ler", "leitura recomendada", "mostrar mais", "mostrar menos" }) do
        local p = low:find(k, 1, true)
        if p and (not cut or p < cut) then cut = p end
    end
    if cut and cut > 1 then s = (s:sub(1, cut - 1):gsub("%s+$", "")) end
    local out = {}
    for p in (s .. NL .. NL):gmatch("(.-)" .. NL .. NL) do
        local low = p:lower()
        local bad = false
        for _, w in ipairs(SPAM) do
            if low:find(w, 1, true) then bad = true; break end
        end
        if not bad and p:match("%S") then out[#out + 1] = p end
    end
    if #out == 0 then return s end
    return table.concat(out, NL .. NL)
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
            return (abs(unnext(dec(u))):gsub("%-%d+x%d+(%.%w+)$", "%1"))
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

local function after_list(h)
    local s, e = norm(h):find(LISTP:lower(), 1, true)
    if not s then return nil end
    return norm(h):sub(e + 1)
end
local function is_work(h)
    if LISTP == "" or not h:find(LISTP, 1, true) then return false end
    local a = after_list(h)
    return a ~= nil and a ~= "" and not a:find("/", 1, true) and a ~= "page"
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
            if not title then name = name:gsub("封面$", ""):gsub("%s+$", "") end
            local cover = cover_of(img)
            local it = idx[k]
            if it then
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

-- ===== Filtres (contrat Sefirah : key / label / default / multi / options{id,label}) =====
local function opts(list)
    local o = { { id = "all", label = "Tous" } }
    for _, p in ipairs(list) do o[#o + 1] = { id = p[1], label = p[2] } end
    return o
end

local ORDER_OPTS = {
    { id = "views",     label = "Mais lidos" },
    { id = "latest",    label = "Mais recentes" },
    { id = "rating",    label = "Melhor avaliados" },
    { id = "trending",  label = "Em alta" },
    { id = "alphabet",  label = "A-Z" },
    { id = "new-manga", label = "Novos" },
}
local GENRES = {
    { "acao", "Ação" }, { "adulto", "Adulto" }, { "artes-marciais", "Artes Marciais" },
    { "aventura", "Aventura" }, { "comedia", "Comédia" }, { "drama", "Drama" },
    { "ecchi", "Ecchi" }, { "fantasia", "Fantasia" }, { "harem", "Harém" },
    { "historico", "Histórico" }, { "horror", "Horror" }, { "isekai", "Isekai" },
    { "josei", "Josei" }, { "manhwa", "Manhwa" }, { "mecha", "Mecha" },
    { "misterio", "Mistério" }, { "musica", "Música" }, { "psicologico", "Psicológico" },
    { "romance", "Romance" }, { "sci-fi", "Sci-Fi" }, { "seinen", "Seinen" },
    { "shoujo", "Shoujo" }, { "shounen", "Shounen" }, { "slice-of-life", "Slice of Life" },
    { "sobrenatural", "Sobrenatural" }, { "esportes", "Esportes" }, { "suspense", "Suspense" },
    { "terror", "Terror" }, { "vida-escolar", "Vida Escolar" },
}
local STATUS_LIST = { { "on-going", "Em andamento" }, { "end", "Completo" } }

local function make_filters(default_order)
    return {
        { key = "order",  label = "Ordenar por", default = default_order, multi = false, options = ORDER_OPTS },
        { key = "genre",  label = "Gênero",      default = "all", multi = true,  options = opts(GENRES) },
        { key = "status", label = "Status",      default = "all", multi = false, options = opts(STATUS_LIST) },
    }
end

-- valeur choisie (nil si vide ou « all »)
local function fval(sel, key)
    local v = type(sel) == "table" and sel[key]
    if v == nil or v == "" or v == "all" then return nil end
    return tostring(v)
end

-- Construit les paramètres Madara à partir de la sélection : « m_orderby=…&genre[]=a&genre[]=b&status[]=… ».
-- Renvoie la chaîne de paramètres et un booléen « filtre de recherche avancée » (genre/statut).
local function filter_query(sel)
    local q, adv = {}, false
    local o = fval(sel, "order")
    if o then q[#q + 1] = "m_orderby=" .. enc(o) end
    local g = fval(sel, "genre")
    if g then
        for x in g:gmatch("[^,]+") do
            if x ~= "all" then q[#q + 1] = "genre[]=" .. enc(x); adv = true end
        end
    end
    local st = fval(sel, "status")
    if st then q[#q + 1] = "status[]=" .. enc(st); adv = true end
    return table.concat(q, "&"), adv
end

local ext = { id = "mangalivre", name = "Mangalivre", site = BASE, lang = "pt", version = "0.4.0",
    type = "manga",
    popularFilters = make_filters("views"),
    searchFilters = make_filters("latest"),
    hasReviews = false, chapterCommentsPanel = false }

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
    local cat = ogp("og:novel:category")
    return { name = name, path = path, cover = cv,
        summary = summary, author = ogp("og:novel:author"), status = ogp("og:novel:status"), genres = cat ~= "" and { cat } or {} }
end

-- ===== MOTEUR MADARA (WordPress) =====
local MROOT = ((LISTP ~= "" and LISTP or "/manga/"):gsub("/+$", ""))

function ext:popularNovels(page, options)
    local p = tonumber(page) or 1
    local sel = (type(options) == "table" and options.filters) or {}
    local qs, adv = filter_query(sel)
    local url
    if adv then
        -- genre / statut : la recherche avancée Madara les gère, pas l'archive /manga/
        url = BASE .. (p > 1 and ("/page/" .. p) or "") .. "/?s=&post_type=wp-manga"
        if qs ~= "" then url = url .. "&" .. qs end
    else
        url = BASE .. MROOT .. (p > 1 and ("/page/" .. p) or "") .. "/"
        url = url .. "?" .. (qs ~= "" and qs or "m_orderby=views")
    end
    local html, err = get(url)
    if not html then return { novels = {}, error = T("Site injoignable (") .. tostring(err) .. ")" } end
    return { novels = parse_list(html) }
end

function ext:searchNovels(term, page, options)
    term = tostring(term or ""):match("^%s*(.-)%s*$")
    if term == "" then return ext:popularNovels(page, options) end
    local p = tonumber(page) or 1
    local sel = (type(options) == "table" and options.filters) or {}
    local qs = filter_query(sel)
    local url = BASE .. (p > 1 and ("/page/" .. p) or "") .. "/?s=" .. enc(term) .. "&post_type=wp-manga"
    if qs ~= "" then url = url .. "&" .. qs end
    local html, err = get(url)
    if not html then return { novels = {}, error = T("Recherche impossible (") .. tostring(err) .. ")" } end
    return { novels = parse_list(html) }
end

local function m_meta(html, path)
    local m = meta(html, path)
    local sm = grab(html, "description-summary") or grab(html, "summary__content")
    if sm then
        local d = para(sm)
        if #d > 40 then m.summary = d end
    end
    if not m.summary or #m.summary < 60 then
        for _, cls in ipairs({ "summary-content", "manga-excerpt", "manga-summary", "entry-content" }) do
            local b = grab(html, cls)
            if b then
                local d = para(b)
                if #d > 80 and #d < 5000 then m.summary = d; break end
            end
        end
    end
    local a = grab(html, "author-content")
    if a then local s = txt(a); if s ~= "" then m.author = s end end
    local s = html:match('property="og:novel:status"[^>]-content="([^"]*)"')
    if s and s ~= "" then m.status = dec(s) end
    local g = grab(html, "genres-content") or grab(html, "genres__collapse") or grab(html, "manga-genres")
    if g then
        local list = {}
        for x in g:gmatch("<a[^>]*>(.-)</a>") do
            local tag = txt(x)
            if tag ~= "" then list[#list+1] = tag end
        end
        if #list > 0 then m.genres = list end
    end
    m.summary = clean_summary(m.summary)
    return m
end

function ext:parseNovelMeta(path)
    local html = get(path); if not html then return nil end
    local m = m_meta(html, path); m.total_chapters = 0; return m
end

local MCH = (CHAPP ~= "" and CHAPP or "/chapter-"):lower()
local function m_collect(html, path, seen, ch)
    local pk = norm(path)
    for tag, ih in html:gmatch("(<a%s[^>]->)(.-)</a>") do
        local href = attr(tag, "href")
        if href then
            local k = norm(href)
            if k ~= pk and k:sub(1, #pk + 1) == pk .. "/" and k:find(MCH, 1, true) then
                local name = txt(ih)
                if name == "" then name = dec(attr(tag, "title") or "") end
                if seen[k] then
                    if not seen[k].name:find("%d") and name:find("%d") then seen[k].name = name end
                else
                    if name == "" then name = "Capítulo " .. (#ch + 1) end
                    seen[k] = { name = name, path = rel(href) }
                    ch[#ch + 1] = seen[k]
                end
            end
        end
    end
end

local function post(url, body)
    for try = 1, 3 do
        local ok, res = pcall(function()
            local ltn12 = require("ltn12")
            local req = url:match("^https") and require("ssl.https") or require("socket.http")
            local chunks = {}
            local r, code = req.request {
                url = url, method = "POST", source = ltn12.source.string(body), sink = ltn12.sink.table(chunks), timeout = 20,
                headers = { ["User-Agent"] = UA, ["Referer"] = BASE .. "/", ["X-Requested-With"] = "XMLHttpRequest",
                    ["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8", ["Content-Length"] = tostring(#body),
                    ["Accept"] = "*/*", ["Origin"] = BASE },
            }
            if r and code == 200 then return table.concat(chunks) end
            logger.warn("Mangalivre: POST échec", url, tostring(code))
            return nil
        end)
        if ok and type(res) == "string" and #res > 20 then return res end
        pcall(function() require("socket").sleep(0.7 * try) end)
    end
    return nil
end

local function m_ajax(html, path)
    local id = html:match('id="manga%-chapters%-holder"[^>]-data%-id="(%d+)"') or html:match('data%-id="(%d+)"[^>]-id="manga%-chapters%-holder"')
        or html:match('"manga_id"%s*:%s*"?(%d+)') or html:match("postid%-(%d+)") or html:match("[?&]p=(%d+)")
    local rp = path:gsub("^https?://[^/]+", ""):gsub("/+$", "")
    local aj = post(BASE .. rp .. "/ajax/chapters/", "action=manga_get_chapters&manga=" .. (id or ""))
    if not aj and id then aj = post(BASE .. "/wp-admin/admin-ajax.php", "action=manga_get_chapters&manga=" .. id) end
    return aj
end

function ext:parseNovel(path)
    local html = get(path); if not html then return nil end
    local m, ch, seen = m_meta(html, path), {}, {}
    m_collect(html, path, seen, ch)
    if #ch <= 12 then
        local aj = m_ajax(html, path)
        if aj then m_collect(aj, path, seen, ch) end
    end
    local function num(x)
        local p = norm(x.path):match("capitulo%-([%d%-]+)$") or norm(x.path):match("(%d+)[^%d]*$")
        if p then p = p:gsub("%-", ".", 1):gsub("%-", "") end
        return tonumber(p) or tonumber((x.name or ""):match("(%d+%.?%d*)%s*$"))
    end
    local all = #ch > 1
    for i, x in ipairs(ch) do x.n = num(x); x.i = i; if not x.n then all = false end end
    if all then
        table.sort(ch, function(p, q) if p.n ~= q.n then return p.n < q.n end return p.i < q.i end)
    else
        local a, b = ch[1] and ch[1].n, ch[#ch] and ch[#ch].n
        if a and b and a > b then
            for i = 1, math.floor(#ch / 2) do ch[i], ch[#ch + 1 - i] = ch[#ch + 1 - i], ch[i] end
        end
    end
    for i, x in ipairs(ch) do x.chapter_number = i end
    m.chapters, m.totalPages = ch, 1
    return m
end

function ext:parseChapterImages(path)
    local html, err = get(path); if not html then return nil, "chapter_unreachable" end
    local images, seen = {}, {}
    for tag in html:gmatch("<img[^>]->") do
        local cls = attr(tag, "class") or ""
        local raw = attr(tag, "data-src") or attr(tag, "data-lazy-src") or attr(tag, "data-original") or attr(tag, "src")
        if cls:find("wp-manga-chapter-img", 1, true) or (raw and raw:find("/WP-manga/data/", 1, true)) then
            local u = raw and abs(dec(raw:match("^%s*(.-)%s*$")))
            if u and not seen[u] and not u:match("^data:") and not u:find("logo", 1, true) then seen[u] = true; images[#images+1] = u end
        end
    end
    if #images == 0 then return nil, "no_pages" end
    return { images = images, headers = { ["User-Agent"] = UA, ["Referer"] = BASE .. "/" } }
end

function ext:parseChapter(path) return "<p>Ce chapitre est un manga : il s'ouvre dans le lecteur d'images.</p>" end

return ext