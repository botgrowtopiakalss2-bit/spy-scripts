-- ╔══════════════════════════════════════════════════════╗
--   SPY AI CHAT  —  Gemini Edition (GRATIS)
--   Jalankan SETELAH UniversalSpy_AllMap
--
--   Cara dapat API Key GRATIS:
--   1. Buka https://aistudio.google.com/apikey
--   2. Login dengan akun Google
--   3. Klik "Create API Key"
--   4. Copy key dan paste di bawah
--
--   Limit gratis: 60 request/menit, 1500 request/hari
-- ╚══════════════════════════════════════════════════════╝

-- ══════════════════════════════════════════════════════
--  CONFIG — GANTI INI DENGAN KEY KAMU
-- ══════════════════════════════════════════════════════
local API_KEY = "GANTI_DENGAN_GEMINI_API_KEY"
local MODEL   = "gemini-2.0-flash"   -- model terbaru, gratis, cepat

-- ══════════════════════════════════════════════════════
--  SERVICES
-- ══════════════════════════════════════════════════════
local Players = game:GetService("Players")
local LP      = Players.LocalPlayer
local HS      = game:GetService("HttpService")

-- ══════════════════════════════════════════════════════
--  STATE
-- ══════════════════════════════════════════════════════
-- Gemini pakai format: {role="user"/"model", parts={{text="..."}}}
local chatHistory = {}
local isThinking  = false

-- ══════════════════════════════════════════════════════
--  CONTEXT BUILDER
--  Ambil data spy dari _G UniversalSpy
-- ══════════════════════════════════════════════════════
local function buildGameContext()
    local lines = {}
    lines[#lines+1] = "=== DATA SPY GAME ==="
    lines[#lines+1] = "Nama Game : "..tostring(game.Name)
    lines[#lines+1] = "PlaceId   : "..tostring(game.PlaceId)
    lines[#lines+1] = ""

    -- LOG dari UniversalSpy
    local log = rawget(_G, "LOG")
    if log and #log > 0 then
        lines[#lines+1] = "--- REMOTE LOG (30 terbaru dari "..#log..") ---"
        local s = math.max(1, #log - 29)
        for i = s, #log do
            local e = log[i]
            if e and e.dir and e.path then
                lines[#lines+1] = string.format("[%s] %s :: %s(%s)",
                    e.dir, e.path, e.method or "?", e.argStr or "")
            end
        end
        lines[#lines+1] = ""
    else
        lines[#lines+1] = "--- Remote log kosong. Jalankan UniversalSpy dulu. ---"
        lines[#lines+1] = ""
    end

    -- NET_MAP
    local netmap = rawget(_G, "NET_MAP")
    if netmap then
        local n = 0
        for _ in pairs(netmap) do n = n + 1 end
        if n > 0 then
            lines[#lines+1] = "--- NETWORK MAP ("..n.." remote) ---"
            local i = 0
            for path, nm in pairs(netmap) do
                i = i + 1
                if i > 20 then
                    lines[#lines+1] = "...dan "..(n-20).." lainnya"
                    break
                end
                local topArg = "?"
                local maxCnt = 0
                for argStr, cnt in pairs(nm.sendArgs or {}) do
                    if cnt > maxCnt then maxCnt=cnt; topArg=argStr end
                end
                lines[#lines+1] = string.format(
                    "  %-45s  calls:%d  topArg:[%s]",
                    path, nm.callCount or 0, topArg)
            end
            lines[#lines+1] = ""
        end
    end

    -- DECOMP — hanya FireServer/InvokeServer/OnClientEvent
    local decomp = rawget(_G, "DECOMP_RESULTS")
    if decomp and #decomp > 0 then
        lines[#lines+1] = "--- DECOMPILE HITS (remote related) ---"
        local shown = 0
        for _, r in ipairs(decomp) do
            if r.pat and (
                r.pat:find("FireServer") or
                r.pat:find("InvokeServer") or
                r.pat:find("OnClientEvent") or
                r.pat:find("WaitForChild")
            ) then
                lines[#lines+1] = string.format(
                    "  [%s] L%d: %s",
                    r.script or "?", r.ln or 0, r.code or "")
                shown = shown + 1
                if shown >= 25 then
                    lines[#lines+1] = "...dan lebih banyak lagi"
                    break
                end
            end
        end
        lines[#lines+1] = ""
    end

    return table.concat(lines, "\n")
end

-- ══════════════════════════════════════════════════════
--  SYSTEM INSTRUCTION (Gemini pakai systemInstruction)
-- ══════════════════════════════════════════════════════
local SYSTEM_INSTRUCTION = [[
Kamu adalah AI assistant expert dalam analisis Roblox game, reverse engineering, dan Lua scripting.
Kamu punya akses ke data live spy dari game Roblox yang sedang berjalan.

Data yang kamu punya:
- Remote events log (C->S = client kirim ke server, S->C = server kirim ke client)
- Network map (semua remote beserta frekuensi call dan argumen)
- Hasil decompile LocalScript/ModuleScript

Tugasmu:
1. Analisis pola komunikasi game dari data spy
2. Identifikasi remote mana yang berguna untuk automation/exploit
3. Bantu buat script Lua automation berdasarkan data yang ada
4. Jawab pertanyaan Lua/Roblox scripting
5. Jelaskan apa yang kamu lihat di data dengan bahasa mudah

Aturan jawaban:
- Bahasa Indonesia
- Singkat, padat, langsung ke poin
- Kode Lua dalam code block (```lua)
- Sebutkan path remote lengkap kalau ada (misal: game.ReplicatedStorage["E&F"].State.ChangeStateRE)
- Kalau ada saran automation, berikan contoh kode siap pakai
]]

-- ══════════════════════════════════════════════════════
--  GEMINI API CALL
--  Endpoint: generativelanguage.googleapis.com
-- ══════════════════════════════════════════════════════
local function callGemini(userMessage, callback)
    -- Cek request() tersedia
    local reqFn = request or (syn and syn.request) or http_request or http.request
    if not reqFn then
        callback(nil, "HTTP request tidak tersedia di executor ini.")
        return
    end

    -- Inject context kalau history kosong atau user minta refresh
    local msgText = userMessage
    if #chatHistory == 0
    or userMessage:lower():find("refresh")
    or userMessage:lower():find("update")
    or userMessage:lower():find("data terbaru") then
        msgText = buildGameContext().."\n\n=== PERTANYAAN ===\n"..userMessage
    end

    -- Tambah ke history (Gemini format)
    chatHistory[#chatHistory+1] = {
        role  = "user",
        parts = {{text = msgText}}
    }

    -- Batasi 12 turn terakhir
    local histSend = chatHistory
    if #chatHistory > 12 then
        histSend = {}
        for i = #chatHistory-11, #chatHistory do
            histSend[#histSend+1] = chatHistory[i]
        end
    end

    task.spawn(function()
        local ok, result = pcall(function()
            -- System instruction sebagai turn pertama (kompatibel semua versi)
            local contentsToSend = {
                {role="user",  parts={{text="SYSTEM:\n"..SYSTEM_INSTRUCTION}}},
                {role="model", parts={{text="Mengerti, siap membantu."}}}
            }
            for _, h in ipairs(histSend) do
                contentsToSend[#contentsToSend+1] = h
            end

            local body = HS:JSONEncode({
                contents         = contentsToSend,
                generationConfig = {
                    temperature     = 0.7,
                    maxOutputTokens = 1024,
                },
            })

            local url = string.format(
                "https://generativelanguage.googleapis.com/v1beta/models/%s:generateContent?key=%s",
                MODEL, API_KEY)

            local response = reqFn({
                Url     = url,
                Method  = "POST",
                Headers = {["Content-Type"] = "application/json"},
                Body    = body,
            })

            if not response then
                error("request() tidak return apapun")
            end
            if not response.Body or response.Body == "" then
                error("Body kosong. Status: "..tostring(response.StatusCode))
            end

            print("[SpyAI] Raw ("..#response.Body.." bytes): "
                ..response.Body:sub(1, 300))

            local data = HS:JSONDecode(response.Body)

            if data.error then
                error("Gemini Error ["..tostring(data.error.code or "?")
                    .."]: "..tostring(data.error.message or "?"))
            end

            if not data.candidates or #data.candidates == 0 then
                local reason = "candidates kosong"
                if data.promptFeedback and data.promptFeedback.blockReason then
                    reason = "BLOCKED: "..data.promptFeedback.blockReason
                end
                error(reason)
            end

            local cand = data.candidates[1]

            if cand.finishReason and cand.finishReason ~= "STOP"
            and cand.finishReason ~= "MAX_TOKENS" then
                error("Finish reason: "..tostring(cand.finishReason))
            end

            local reply = nil
            if cand.content and cand.content.parts then
                local parts = {}
                for _, p in ipairs(cand.content.parts) do
                    if p.text and p.text ~= "" then
                        parts[#parts+1] = p.text
                    end
                end
                if #parts > 0 then reply = table.concat(parts, "\n") end
            end

            if not reply or reply == "" then
                error("Teks kosong. Raw: "..response.Body:sub(1, 400))
            end

            chatHistory[#chatHistory+1] = {
                role  = "model",
                parts = {{text = reply}}
            }

            return reply
        end)

        if ok then
            callback(result, nil)
        else
            print("[SpyAI] ERROR: "..tostring(result))
            callback(nil, tostring(result))
        end
    end)
end


-- ══════════════════════════════════════════════════════
--  GUI BUILDER
-- ══════════════════════════════════════════════════════
local function buildChatGui()
    pcall(function()
        local old = LP.PlayerGui:FindFirstChild("SpyAIChat")
        if old then old:Destroy() end
    end)

    local sg = Instance.new("ScreenGui")
    sg.Name           = "SpyAIChat"
    sg.ResetOnSpawn   = false
    sg.DisplayOrder   = 1000
    sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    sg.Parent         = LP.PlayerGui

    -- ── Main Frame ─────────────────────────────────────
    local main = Instance.new("Frame", sg)
    main.Name             = "Main"
    main.Size             = UDim2.new(0, 700, 0, 520)
    main.Position         = UDim2.new(0.5, -350, 0.5, -260)
    main.BackgroundColor3 = Color3.fromRGB(10, 12, 18)
    main.BorderSizePixel  = 0
    main.Active           = true
    main.Draggable        = true

    Instance.new("UICorner", main).CornerRadius = UDim.new(0, 10)
    local mStroke = Instance.new("UIStroke", main)
    mStroke.Color     = Color3.fromRGB(40, 160, 90)
    mStroke.Thickness = 1.5

    -- ── Header ─────────────────────────────────────────
    local header = Instance.new("Frame", main)
    header.Size             = UDim2.new(1, 0, 0, 46)
    header.BackgroundColor3 = Color3.fromRGB(12, 18, 14)
    header.BorderSizePixel  = 0
    Instance.new("UICorner", header).CornerRadius = UDim.new(0, 10)
    -- Fix rounded bawah
    local hfix = Instance.new("Frame", header)
    hfix.Size             = UDim2.new(1, 0, 0, 10)
    hfix.Position         = UDim2.new(0, 0, 1, -10)
    hfix.BackgroundColor3 = Color3.fromRGB(12, 18, 14)
    hfix.BorderSizePixel  = 0

    local titleLbl = Instance.new("TextLabel", header)
    titleLbl.Size             = UDim2.new(1, -220, 1, 0)
    titleLbl.Position         = UDim2.new(0, 14, 0, 0)
    titleLbl.BackgroundTransparency = 1
    titleLbl.Text             = "🤖  Spy AI  —  Gemini 2.0 Flash"
    titleLbl.TextColor3       = Color3.fromRGB(120, 220, 150)
    titleLbl.TextSize         = 13
    titleLbl.Font             = Enum.Font.GothamBold
    titleLbl.TextXAlignment   = Enum.TextXAlignment.Left

    -- Badge gratis
    local freeBadge = Instance.new("TextLabel", header)
    freeBadge.Size             = UDim2.new(0, 54, 0, 20)
    freeBadge.Position         = UDim2.new(1, -220, 0.5, -10)
    freeBadge.BackgroundColor3 = Color3.fromRGB(20, 80, 30)
    freeBadge.BorderSizePixel  = 0
    freeBadge.Text             = "GRATIS"
    freeBadge.TextColor3       = Color3.fromRGB(80, 220, 100)
    freeBadge.TextSize         = 10
    freeBadge.Font             = Enum.Font.GothamBold
    Instance.new("UICorner", freeBadge).CornerRadius = UDim.new(0, 4)

    -- Tombol Refresh context
    local btnRefresh = Instance.new("TextButton", header)
    btnRefresh.Size             = UDim2.new(0, 70, 0, 24)
    btnRefresh.Position         = UDim2.new(1, -164, 0.5, -12)
    btnRefresh.BackgroundColor3 = Color3.fromRGB(20, 50, 30)
    btnRefresh.BorderSizePixel  = 0
    btnRefresh.Text             = "Refresh"
    btnRefresh.TextColor3       = Color3.fromRGB(80, 220, 130)
    btnRefresh.TextSize         = 11
    btnRefresh.Font             = Enum.Font.GothamBold
    Instance.new("UICorner", btnRefresh).CornerRadius = UDim.new(0, 4)

    -- Tombol Clear
    local btnClear = Instance.new("TextButton", header)
    btnClear.Size             = UDim2.new(0, 54, 0, 24)
    btnClear.Position         = UDim2.new(1, -88, 0.5, -12)
    btnClear.BackgroundColor3 = Color3.fromRGB(50, 20, 20)
    btnClear.BorderSizePixel  = 0
    btnClear.Text             = "Clear"
    btnClear.TextColor3       = Color3.fromRGB(255, 100, 100)
    btnClear.TextSize         = 11
    btnClear.Font             = Enum.Font.GothamBold
    Instance.new("UICorner", btnClear).CornerRadius = UDim.new(0, 4)

    -- Tombol Close
    local btnClose = Instance.new("TextButton", header)
    btnClose.Size             = UDim2.new(0, 30, 0, 30)
    btnClose.Position         = UDim2.new(1, -38, 0.5, -15)
    btnClose.BackgroundTransparency = 1
    btnClose.Text             = "✕"
    btnClose.TextColor3       = Color3.fromRGB(160, 160, 180)
    btnClose.TextSize         = 15
    btnClose.Font             = Enum.Font.GothamBold

    -- ── Chat scroll ────────────────────────────────────
    local scroll = Instance.new("ScrollingFrame", main)
    scroll.Name                  = "ChatScroll"
    scroll.Size                  = UDim2.new(1, -12, 1, -108)
    scroll.Position              = UDim2.new(0, 6, 0, 50)
    scroll.BackgroundTransparency= 1
    scroll.BorderSizePixel       = 0
    scroll.ScrollBarThickness    = 3
    scroll.ScrollBarImageColor3  = Color3.fromRGB(60, 180, 100)
    scroll.AutomaticCanvasSize   = Enum.AutomaticSize.Y
    scroll.CanvasSize            = UDim2.new(0, 0, 0, 0)

    local inner = Instance.new("Frame", scroll)
    inner.Size            = UDim2.new(1, 0, 0, 0)
    inner.AutomaticSize   = Enum.AutomaticSize.Y
    inner.BackgroundTransparency = 1

    local ll = Instance.new("UIListLayout", inner)
    ll.SortOrder = Enum.SortOrder.LayoutOrder
    ll.Padding   = UDim.new(0, 8)

    local innerPad = Instance.new("UIPadding", inner)
    innerPad.PaddingLeft   = UDim.new(0, 6)
    innerPad.PaddingRight  = UDim.new(0, 6)
    innerPad.PaddingTop    = UDim.new(0, 6)
    innerPad.PaddingBottom = UDim.new(0, 6)

    -- ── Input bar ──────────────────────────────────────
    local inputBar = Instance.new("Frame", main)
    inputBar.Size             = UDim2.new(1, -12, 0, 50)
    inputBar.Position         = UDim2.new(0, 6, 1, -56)
    inputBar.BackgroundColor3 = Color3.fromRGB(14, 20, 16)
    inputBar.BorderSizePixel  = 0
    Instance.new("UICorner", inputBar).CornerRadius = UDim.new(0, 8)

    local iStroke = Instance.new("UIStroke", inputBar)
    iStroke.Color     = Color3.fromRGB(40, 120, 60)
    iStroke.Thickness = 1

    local inputBox = Instance.new("TextBox", inputBar)
    inputBox.Size              = UDim2.new(1, -62, 1, -14)
    inputBox.Position          = UDim2.new(0, 12, 0, 7)
    inputBox.BackgroundTransparency = 1
    inputBox.Text              = ""
    inputBox.PlaceholderText   = "Tanya tentang game ini... (Enter kirim)"
    inputBox.PlaceholderColor3 = Color3.fromRGB(60, 90, 65)
    inputBox.TextColor3        = Color3.fromRGB(200, 240, 210)
    inputBox.TextSize          = 12
    inputBox.Font              = Enum.Font.Code
    inputBox.ClearTextOnFocus  = false
    inputBox.TextXAlignment    = Enum.TextXAlignment.Left
    inputBox.MultiLine         = false

    local btnSend = Instance.new("TextButton", inputBar)
    btnSend.Size             = UDim2.new(0, 44, 0, 36)
    btnSend.Position         = UDim2.new(1, -52, 0.5, -18)
    btnSend.BackgroundColor3 = Color3.fromRGB(20, 140, 60)
    btnSend.BorderSizePixel  = 0
    btnSend.Text             = "▶"
    btnSend.TextColor3       = Color3.fromRGB(200, 255, 210)
    btnSend.TextSize         = 18
    btnSend.Font             = Enum.Font.GothamBold
    Instance.new("UICorner", btnSend).CornerRadius = UDim.new(0, 6)

    -- ── Add bubble helper ──────────────────────────────
    local msgCount = 0

    local function addBubble(text, isUser)
        msgCount = msgCount + 1

        local wrap = Instance.new("Frame", inner)
        wrap.Size            = UDim2.new(1, 0, 0, 0)
        wrap.AutomaticSize   = Enum.AutomaticSize.Y
        wrap.BackgroundTransparency = 1
        wrap.LayoutOrder     = msgCount

        local bubble = Instance.new("Frame", wrap)
        bubble.AutomaticSize   = Enum.AutomaticSize.Y
        bubble.BackgroundColor3= isUser
            and Color3.fromRGB(18, 55, 30)
            or  Color3.fromRGB(16, 22, 32)
        bubble.BorderSizePixel = 0

        local bS = Instance.new("UIStroke", bubble)
        bS.Color     = isUser
            and Color3.fromRGB(40, 160, 80)
            or  Color3.fromRGB(40, 80, 140)
        bS.Thickness = 0.8
        Instance.new("UICorner", bubble).CornerRadius = UDim.new(0, 8)

        if isUser then
            bubble.Size     = UDim2.new(0.82, 0, 0, 0)
            bubble.Position = UDim2.new(0.18, 0, 0, 0)
        else
            bubble.Size     = UDim2.new(0.94, 0, 0, 0)
            bubble.Position = UDim2.new(0, 0, 0, 0)
        end

        -- Role label
        local role = Instance.new("TextLabel", bubble)
        role.Size             = UDim2.new(1, -12, 0, 16)
        role.Position         = UDim2.new(0, 8, 0, 5)
        role.BackgroundTransparency = 1
        role.Text             = isUser and "Kamu" or "Gemini AI"
        role.TextColor3       = isUser
            and Color3.fromRGB(80, 220, 120)
            or  Color3.fromRGB(100, 160, 255)
        role.TextSize         = 10
        role.Font             = Enum.Font.GothamBold
        role.TextXAlignment   = Enum.TextXAlignment.Left

        -- Message text
        local msg = Instance.new("TextLabel", bubble)
        msg.Size              = UDim2.new(1, -16, 0, 0)
        msg.Position          = UDim2.new(0, 8, 0, 23)
        msg.AutomaticSize     = Enum.AutomaticSize.Y
        msg.BackgroundTransparency = 1
        msg.Text              = text
        msg.TextColor3        = Color3.fromRGB(210, 230, 215)
        msg.TextSize          = 12
        msg.Font              = Enum.Font.Code
        msg.TextXAlignment    = Enum.TextXAlignment.Left
        msg.TextWrapped       = true

        local bPad = Instance.new("UIPadding", bubble)
        bPad.PaddingBottom = UDim.new(0, 8)

        -- Auto scroll ke bawah
        task.defer(function()
            pcall(function()
                scroll.CanvasPosition = Vector2.new(
                    0, scroll.AbsoluteCanvasSize.Y)
            end)
        end)

        return msg
    end

    -- ── Thinking indicator ─────────────────────────────
    local thinkLabel = nil

    local function showThinking()
        thinkLabel = addBubble("Sedang berpikir...", false)
        isThinking = true
        task.spawn(function()
            local frames = {"Sedang berpikir.", "Sedang berpikir..", "Sedang berpikir..."}
            local i = 1
            while isThinking and thinkLabel do
                pcall(function() thinkLabel.Text = frames[i] end)
                i = i % 3 + 1
                task.wait(0.35)
            end
        end)
    end

    local function hideThinking()
        isThinking = false
        if thinkLabel then
            pcall(function() thinkLabel.Parent.Parent:Destroy() end)
            thinkLabel = nil
        end
    end

    -- ── Send logic ─────────────────────────────────────
    local function sendMessage()
        if isThinking then return end
        local text = inputBox.Text:match("^%s*(.-)%s*$")
        if text == "" then return end
        inputBox.Text = ""
        addBubble(text, true)
        showThinking()
        callGemini(text, function(reply, err)
            hideThinking()
            if reply then
                addBubble(reply, false)
            else
                addBubble("[ERROR] "..(err or "Unknown"), false)
            end
        end)
    end

    -- ── Events ─────────────────────────────────────────
    btnSend.MouseButton1Click:Connect(sendMessage)
    inputBox.FocusLost:Connect(function(enter)
        if enter then sendMessage() end
    end)

    btnClose.MouseButton1Click:Connect(function()
        main.Visible = false
    end)

    btnClear.MouseButton1Click:Connect(function()
        chatHistory = {}
        for _, c in ipairs(inner:GetChildren()) do
            if c:IsA("Frame") then c:Destroy() end
        end
        msgCount = 0
        addBubble("Chat di-reset. Context akan di-refresh saat pesan berikutnya.", false)
    end)

    btnRefresh.MouseButton1Click:Connect(function()
        addBubble("Refresh data spy...", true)
        showThinking()
        callGemini(
            "Analisis ulang data spy terbaru dari game ini. "..
            "Berikan ringkasan: (1) Remote aktif yang menarik, "..
            "(2) Pola yang terlihat, (3) Saran automation.",
            function(reply, err)
                hideThinking()
                addBubble(reply or ("[ERROR] "..(err or "?")), false)
            end)
    end)

    -- ── Sambutan otomatis ──────────────────────────────
    task.spawn(function()
        task.wait(0.6)
        showThinking()
        callGemini(
            "Halo! Saya baru mulai spy game ini. "..
            "Tolong lihat data yang tersedia dan jawab singkat:\n"..
            "1. Game ini tentang apa?\n"..
            "2. Remote mana yang paling menarik?\n"..
            "3. Ada automation yang bisa dibuat?",
            function(reply, err)
                hideThinking()
                if reply then
                    addBubble(reply, false)
                else
                    addBubble(
                        "Gagal connect ke Gemini API.\n\n"..
                        "Pastikan:\n"..
                        "1. API_KEY sudah diisi (baris ke-17)\n"..
                        "2. Key dari https://aistudio.google.com/apikey\n"..
                        "3. Executor support request()\n\n"..
                        "Error: "..(err or "?"),
                        false)
                end
            end)
    end)

    -- ── Toggle button ──────────────────────────────────
    local toggleBtn = Instance.new("TextButton", sg)
    toggleBtn.Size             = UDim2.new(0, 46, 0, 46)
    toggleBtn.Position         = UDim2.new(0, 8, 0.5, -23)
    toggleBtn.BackgroundColor3 = Color3.fromRGB(12, 60, 24)
    toggleBtn.BorderSizePixel  = 0
    toggleBtn.Text             = "🤖"
    toggleBtn.TextSize         = 22
    toggleBtn.Font             = Enum.Font.GothamBold
    Instance.new("UICorner", toggleBtn).CornerRadius = UDim.new(1, 0)

    local tS = Instance.new("UIStroke", toggleBtn)
    tS.Color     = Color3.fromRGB(40, 200, 80)
    tS.Thickness = 1.5

    toggleBtn.MouseButton1Click:Connect(function()
        main.Visible = not main.Visible
    end)

    print("[SpyAI Gemini] GUI siap. Klik tombol 🤖 di kiri layar.")
end

-- ══════════════════════════════════════════════════════
--  LAUNCH
-- ══════════════════════════════════════════════════════
if API_KEY == "GANTI_DENGAN_GEMINI_API_KEY" then
    warn("[SpyAI] !! API_KEY belum diisi !!")
    warn("[SpyAI] Dapatkan key GRATIS di: https://aistudio.google.com/apikey")
    warn("[SpyAI] Edit baris ke-17 script ini lalu jalankan ulang.")
else
    buildChatGui()
    print("[SpyAI Gemini] Loaded. Jalankan UniversalSpy dulu untuk data lengkap.")
    print("[SpyAI Gemini] Toggle: _G.spyAI()")
end

_G.spyAI = function()
    local gui = LP.PlayerGui:FindFirstChild("SpyAIChat")
    if gui then
        local m = gui:FindFirstChild("Main")
        if m then m.Visible = not m.Visible end
    else
        buildChatGui()
    end
end
