-- ╔══════════════════════════════════════════════════════╗
--   UNIVERSAL SPY  —  All Map Edition
--   Tidak terikat 1 game/map/PlaceId
--
--   Filosofi: Server script tidak bisa dibaca langsung.
--   Tapi server BERBICARA lewat client — dan kita
--   rekam setiap kata yang diucapkannya.
--
--   Coverage:
--   [A] Runtime hooks   — C->S + S->C (dua arah)
--   [B] Deep decompile  — semua client script
--   [C] Memory forensic — _G, shared, upvalue, closure
--   [D] Instance sweep  — getinstances + nil-parented
--   [E] Network timing  — deteksi pola & frekuensi
--   [F] Callstack trace — asal setiap panggilan
--   [G] Auto-map remote — build peta komunikasi game
--   [H] saveinstance    — dump untuk analisis offline
-- ╚══════════════════════════════════════════════════════╝

-- ══════════════════════════════════════════════════════
--  CORE SERVICES (universal, bukan hardcode PlaceId)
-- ══════════════════════════════════════════════════════
local Players  = game:GetService("Players")
local RS       = game:GetService("ReplicatedStorage")
local WS       = game:GetService("Workspace")
local LP       = Players.LocalPlayer

-- ══════════════════════════════════════════════════════
--  SERIALIZER — robust, handle semua tipe Roblox
-- ══════════════════════════════════════════════════════
local function ser(v, d)
    d = d or 0
    if d > 5 then return "…" end
    local t = typeof(v)
    if     t=="nil"      then return "nil"
    elseif t=="boolean"  then return tostring(v)
    elseif t=="number"   then
        return v==math.floor(v) and tostring(math.floor(v))
            or string.format("%.4f",v)
    elseif t=="string"   then
        local s = v:gsub("[\n\r\t]"," ")
        return #s>100 and ('"'..s:sub(1,100)..'"…') or ('"'..s..'"')
    elseif t=="Vector3"  then
        return("V3(%.2f,%.2f,%.2f)"):format(v.X,v.Y,v.Z)
    elseif t=="Vector2"  then
        return("V2(%.2f,%.2f)"):format(v.X,v.Y)
    elseif t=="CFrame"   then
        local p=v.Position
        return("CF(%.1f,%.1f,%.1f)"):format(p.X,p.Y,p.Z)
    elseif t=="Color3"   then
        return("RGB(%.2f,%.2f,%.2f)"):format(v.R,v.G,v.B)
    elseif t=="UDim2"    then
        return("UDim2(%.2f,%.0f,%.2f,%.0f)"):format(
            v.X.Scale,v.X.Offset,v.Y.Scale,v.Y.Offset)
    elseif t=="EnumItem" then return tostring(v)
    elseif t=="Instance" then
        local ok,path = pcall(function() return v:GetFullName() end)
        return "<"..v.ClassName..":"..(ok and path or v.Name)..">"
    elseif t=="table" then
        local p,n={},0
        for k,val in pairs(v) do
            n=n+1; if n>12 then p[#p+1]="…"; break end
            local ks = type(k)=="number" and ("["..k.."]")
                or ('["'..tostring(k)..'"]')
            p[#p+1]=ks.."="..ser(val,d+1)
        end
        return "{"..table.concat(p,", ").."}"
    elseif t=="function" then return "[function]"
    else return "["..t.."]" end
end

local function serArgs(args)
    local p={}
    for _,v in ipairs(args) do p[#p+1]=ser(v) end
    return table.concat(p,", ")
end

-- ══════════════════════════════════════════════════════
--  LOG ENGINE
-- ══════════════════════════════════════════════════════
local LOG        = {}   -- {dir,path,method,args,stack,ts}
local NET_MAP    = {}   -- {remotePath → {callCount,lastArgs,responses}}
local ENV_FOUND  = {}
local logCount   = {}
local MAX_PER    = 150

local function stamp() return string.format("%.3f", os.clock()) end

local function logEvent(dir, remotePath, method, args, stack)
    local key = dir..remotePath..method
    logCount[key] = (logCount[key] or 0)+1
    if logCount[key] > MAX_PER then return end

    local argStr = serArgs(args)
    local e = {
        ts=stamp(), dir=dir,
        path=remotePath, method=method,
        argStr=argStr, stack=stack or ""
    }
    LOG[#LOG+1] = e

    -- Update network map
    if not NET_MAP[remotePath] then
        NET_MAP[remotePath] = {
            callCount=0, sendArgs={}, recvArgs={},
            methods={}, firstSeen=stamp()
        }
    end
    local nm = NET_MAP[remotePath]
    nm.callCount = nm.callCount+1
    nm.methods[method] = (nm.methods[method] or 0)+1
    if dir=="C-S" then
        nm.sendArgs[argStr] = (nm.sendArgs[argStr] or 0)+1
    else
        nm.recvArgs[argStr] = (nm.recvArgs[argStr] or 0)+1
    end

    local line = string.format("[%s][%s] %s :: %s(%s)%s",
        dir, e.ts, remotePath, method, argStr,
        stack~="" and ("  <- "..stack) or "")
    cprint(line)
end

-- ══════════════════════════════════════════════════════
--  GUI CONSOLE — Terminal in-game
--  Muncul sebagai window scrollable, semua output
--  spy otomatis masuk ke sini + developer console
-- ══════════════════════════════════════════════════════
local CONSOLE_LINES = {}   -- buffer semua baris
local MAX_LINES     = 500  -- batas buffer
local consoleVisible= false
local consoleGui    = nil
local consoleFrame  = nil
local consoleScroll = nil
local consoleInner  = nil

-- Warna per tipe baris
local LINE_COLORS = {
    CS      = Color3.fromRGB(100, 200, 255),  -- C->S biru
    SC      = Color3.fromRGB(100, 255, 150),  -- S->C hijau
    STATIC  = Color3.fromRGB(255, 220,  80),  -- decompile kuning
    MEM     = Color3.fromRGB(220, 100, 255),  -- memory ungu
    INFO    = Color3.fromRGB(200, 200, 200),  -- info abu
    WARN    = Color3.fromRGB(255, 160,  60),  -- warning oranye
    ERR     = Color3.fromRGB(255,  80,  80),  -- error merah
    COPY    = Color3.fromRGB( 80, 220, 180),  -- copy teal
    SEP     = Color3.fromRGB( 80,  80,  80),  -- separator gelap
}

local function getLineColor(text)
    if text:find("^%[C->S%]") or text:find("C-S") then
        return LINE_COLORS.CS
    elseif text:find("^%[S->C%]") or text:find("S-C") then
        return LINE_COLORS.SC
    elseif text:find("^%[static%]") or text:find("L%d+ %[") then
        return LINE_COLORS.STATIC
    elseif text:find("UPVALUE") or text:find("ENV") or text:find("_G") then
        return LINE_COLORS.MEM
    elseif text:find("^%[COPY%]") or text:find("Copied") then
        return LINE_COLORS.COPY
    elseif text:find("Error") or text:find("Gagal") or text:find("[X]") then
        return LINE_COLORS.ERR
    elseif text:find("==") or text:find("--") or text:find("---") then
        return LINE_COLORS.SEP
    elseif text:find("[OK]") or text:find("NOTIFY") then
        return LINE_COLORS.WARN
    else
        return LINE_COLORS.INFO
    end
end

-- Build GUI console
local function buildConsoleGui()
    -- Hapus kalau sudah ada
    pcall(function()
        local old = LP.PlayerGui:FindFirstChild("SpyConsole")
        if old then old:Destroy() end
    end)

    local sg = Instance.new("ScreenGui")
    sg.Name            = "SpyConsole"
    sg.ResetOnSpawn    = false
    sg.DisplayOrder    = 999
    sg.ZIndexBehavior  = Enum.ZIndexBehavior.Sibling
    sg.Parent          = LP.PlayerGui

    -- Background frame utama
    local mainFrame = Instance.new("Frame")
    mainFrame.Name            = "MainFrame"
    mainFrame.Size            = UDim2.new(0, 720, 0, 420)
    mainFrame.Position        = UDim2.new(0.5, -360, 0.5, -210)
    mainFrame.BackgroundColor3= Color3.fromRGB(12, 12, 16)
    mainFrame.BorderSizePixel = 0
    mainFrame.Active          = true
    mainFrame.Draggable       = true
    mainFrame.Visible         = false
    mainFrame.Parent          = sg

    -- Corner
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 8)
    corner.Parent       = mainFrame

    -- Stroke border
    local stroke = Instance.new("UIStroke")
    stroke.Color     = Color3.fromRGB(50, 50, 70)
    stroke.Thickness = 1
    stroke.Parent    = mainFrame

    -- Header bar
    local header = Instance.new("Frame")
    header.Name             = "Header"
    header.Size             = UDim2.new(1, 0, 0, 36)
    header.BackgroundColor3 = Color3.fromRGB(20, 20, 30)
    header.BorderSizePixel  = 0
    header.Parent           = mainFrame

    local hCorner = Instance.new("UICorner")
    hCorner.CornerRadius = UDim.new(0, 8)
    hCorner.Parent       = header

    -- Fix corner bawah header (supaya tidak rounded)
    local hFix = Instance.new("Frame")
    hFix.Size             = UDim2.new(1, 0, 0, 8)
    hFix.Position         = UDim2.new(0, 0, 1, -8)
    hFix.BackgroundColor3 = Color3.fromRGB(20, 20, 30)
    hFix.BorderSizePixel  = 0
    hFix.Parent           = header

    -- Title label
    local titleLabel = Instance.new("TextLabel")
    titleLabel.Size             = UDim2.new(1, -120, 1, 0)
    titleLabel.Position         = UDim2.new(0, 12, 0, 0)
    titleLabel.BackgroundTransparency = 1
    titleLabel.Text             = "🖥  Universal Spy — Console"
    titleLabel.TextColor3       = Color3.fromRGB(180, 180, 220)
    titleLabel.TextSize         = 13
    titleLabel.Font             = Enum.Font.Code
    titleLabel.TextXAlignment   = Enum.TextXAlignment.Left
    titleLabel.Parent           = header

    -- Badge: live event count
    local badge = Instance.new("TextLabel")
    badge.Name                  = "Badge"
    badge.Size                  = UDim2.new(0, 90, 0, 20)
    badge.Position              = UDim2.new(1, -170, 0.5, -10)
    badge.BackgroundColor3      = Color3.fromRGB(40, 100, 200)
    badge.BackgroundTransparency= 0.3
    badge.BorderSizePixel       = 0
    badge.Text                  = "0 events"
    badge.TextColor3            = Color3.fromRGB(200, 220, 255)
    badge.TextSize              = 11
    badge.Font                  = Enum.Font.Code
    badge.Parent                = header
    local bCorner = Instance.new("UICorner")
    bCorner.CornerRadius = UDim.new(0, 4)
    bCorner.Parent       = badge

    -- Tombol Clear
    local btnClear = Instance.new("TextButton")
    btnClear.Size             = UDim2.new(0, 54, 0, 22)
    btnClear.Position         = UDim2.new(1, -118, 0.5, -11)
    btnClear.BackgroundColor3 = Color3.fromRGB(60, 30, 30)
    btnClear.BorderSizePixel  = 0
    btnClear.Text             = "Clear"
    btnClear.TextColor3       = Color3.fromRGB(255, 100, 100)
    btnClear.TextSize         = 11
    btnClear.Font             = Enum.Font.Code
    btnClear.Parent           = header
    local cCorner = Instance.new("UICorner")
    cCorner.CornerRadius = UDim.new(0, 4)
    cCorner.Parent       = btnClear

    -- Tombol Copy All
    local btnCopyAll = Instance.new("TextButton")
    btnCopyAll.Size             = UDim2.new(0, 70, 0, 22)
    btnCopyAll.Position         = UDim2.new(1, -188, 0.5, -11)  -- akan digeser
    btnCopyAll.BackgroundColor3 = Color3.fromRGB(20, 60, 40)
    btnCopyAll.BorderSizePixel  = 0
    btnCopyAll.Text             = "Copy All"
    btnCopyAll.TextColor3       = Color3.fromRGB(80, 220, 130)
    btnCopyAll.TextSize         = 11
    btnCopyAll.Font             = Enum.Font.Code
    btnCopyAll.Parent           = header
    local caCorner = Instance.new("UICorner")
    caCorner.CornerRadius = UDim.new(0, 4)
    caCorner.Parent       = btnCopyAll

    -- Atur posisi ulang tombol header
    btnCopyAll.Position = UDim2.new(1, -196, 0.5, -11)
    btnClear.Position   = UDim2.new(1, -126, 0.5, -11)
    badge.Position      = UDim2.new(1, -60, 0.5, -10)
    badge.Size          = UDim2.new(0, 56, 0, 20)

    -- Tombol Close (X)
    local btnClose = Instance.new("TextButton")
    btnClose.Size             = UDim2.new(0, 28, 0, 28)
    btnClose.Position         = UDim2.new(1, -32, 0.5, -14)
    btnClose.BackgroundTransparency = 1
    btnClose.Text             = "✕"
    btnClose.TextColor3       = Color3.fromRGB(150, 150, 170)
    btnClose.TextSize         = 14
    btnClose.Font             = Enum.Font.GothamBold
    btnClose.Parent           = header

    -- ScrollingFrame untuk output
    local scroll = Instance.new("ScrollingFrame")
    scroll.Name                    = "Output"
    scroll.Size                    = UDim2.new(1, -8, 1, -80)
    scroll.Position                = UDim2.new(0, 4, 0, 40)
    scroll.BackgroundTransparency  = 1
    scroll.BorderSizePixel         = 0
    scroll.ScrollBarThickness      = 4
    scroll.ScrollBarImageColor3    = Color3.fromRGB(80, 80, 120)
    scroll.CanvasSize              = UDim2.new(0, 0, 0, 0)
    scroll.AutomaticCanvasSize     = Enum.AutomaticSize.Y
    scroll.Parent                  = mainFrame

    -- Inner frame untuk list layout
    local inner = Instance.new("Frame")
    inner.Name                    = "Inner"
    inner.Size                    = UDim2.new(1, 0, 0, 0)
    inner.AutomaticSize           = Enum.AutomaticSize.Y
    inner.BackgroundTransparency  = 1
    inner.Parent                  = scroll

    local listLayout = Instance.new("UIListLayout")
    listLayout.SortOrder          = Enum.SortOrder.LayoutOrder
    listLayout.Padding            = UDim.new(0, 1)
    listLayout.Parent             = inner

    local innerPad = Instance.new("UIPadding")
    innerPad.PaddingLeft   = UDim.new(0, 6)
    innerPad.PaddingRight  = UDim.new(0, 6)
    innerPad.PaddingTop    = UDim.new(0, 4)
    innerPad.Parent        = inner

    -- Bottom bar (input command)
    local bottomBar = Instance.new("Frame")
    bottomBar.Size             = UDim2.new(1, 0, 0, 36)
    bottomBar.Position         = UDim2.new(0, 0, 1, -36)
    bottomBar.BackgroundColor3 = Color3.fromRGB(18, 18, 26)
    bottomBar.BorderSizePixel  = 0
    bottomBar.Parent           = mainFrame

    local bBarFix = Instance.new("UICorner")
    bBarFix.CornerRadius = UDim.new(0, 8)
    bBarFix.Parent       = bottomBar

    local bBarFix2 = Instance.new("Frame")
    bBarFix2.Size             = UDim2.new(1, 0, 0, 8)
    bBarFix2.BackgroundColor3 = Color3.fromRGB(18, 18, 26)
    bBarFix2.BorderSizePixel  = 0
    bBarFix2.Parent           = bottomBar

    local promptLabel = Instance.new("TextLabel")
    promptLabel.Size             = UDim2.new(0, 20, 1, 0)
    promptLabel.Position         = UDim2.new(0, 8, 0, 0)
    promptLabel.BackgroundTransparency = 1
    promptLabel.Text             = ">"
    promptLabel.TextColor3       = Color3.fromRGB(100, 200, 100)
    promptLabel.TextSize         = 13
    promptLabel.Font             = Enum.Font.Code
    promptLabel.Parent           = bottomBar

    local inputBox = Instance.new("TextBox")
    inputBox.Name                = "InputBox"
    inputBox.Size                = UDim2.new(1, -36, 0, 24)
    inputBox.Position            = UDim2.new(0, 26, 0.5, -12)
    inputBox.BackgroundColor3    = Color3.fromRGB(25, 25, 35)
    inputBox.BorderSizePixel     = 0
    inputBox.Text                = ""
    inputBox.PlaceholderText     = "Ketik command: spyDone | spyClear | spyMap | spyCopy ..."
    inputBox.PlaceholderColor3   = Color3.fromRGB(80, 80, 100)
    inputBox.TextColor3          = Color3.fromRGB(200, 220, 200)
    inputBox.TextSize            = 12
    inputBox.Font                = Enum.Font.Code
    inputBox.ClearTextOnFocus    = false
    inputBox.TextXAlignment      = Enum.TextXAlignment.Left
    inputBox.Parent              = bottomBar

    local ibCorner = Instance.new("UICorner")
    ibCorner.CornerRadius = UDim.new(0, 4)
    ibCorner.Parent       = inputBox

    -- Simpan referensi
    consoleGui    = sg
    consoleFrame  = mainFrame
    consoleScroll = scroll
    consoleInner  = inner

    -- ── EVENT HANDLERS ────────────────────────────────

    -- Close button
    btnClose.MouseButton1Click:Connect(function()
        mainFrame.Visible = false
        consoleVisible    = false
    end)

    -- Clear button
    btnClear.MouseButton1Click:Connect(function()
        for _,child in ipairs(inner:GetChildren()) do
            if child:IsA("TextLabel") then child:Destroy() end
        end
        CONSOLE_LINES = {}
    end)

    -- Copy All button — copy semua baris console
    btnCopyAll.MouseButton1Click:Connect(function()
        if not setclipboard then return end
        local lines = {}
        for _,child in ipairs(inner:GetChildren()) do
            if child:IsA("TextLabel") then
                lines[#lines+1] = child.Text
            end
        end
        if #lines > 0 then
            setclipboard(table.concat(lines, "\n"))
            -- Flash badge
            badge.Text = "Copied!"
            badge.BackgroundColor3 = Color3.fromRGB(20, 100, 60)
            task.delay(2, function()
                badge.BackgroundColor3 = Color3.fromRGB(40, 100, 200)
            end)
        end
    end)

    -- Input command handler (Enter)
    inputBox.FocusLost:Connect(function(enterPressed)
        if not enterPressed then return end
        local cmd = inputBox.Text:match("^%s*(.-)%s*$")
        inputBox.Text = ""
        if cmd == "" then return end

        -- Echo command ke console
        cprint("> "..cmd, Color3.fromRGB(120, 220, 120))

        -- Dispatch command
        local cmdMap = {
            spyDone    = function() if _G.spyDone   then _G.spyDone()   end end,
            spyReport  = function() if _G.spyReport then _G.spyReport() end end,
            spyClear   = function() if _G.spyClear  then _G.spyClear()  end end,
            spySave    = function() if _G.spySave   then _G.spySave()   end end,
            spyMap     = function() if _G.spyMap    then _G.spyMap()    end end,
            spyTime    = function() if _G.spyTime   then _G.spyTime()   end end,
            spyMem     = function() if _G.spyMem    then _G.spyMem()    end end,
            spySweep   = function() if _G.spySweep  then _G.spySweep()  end end,
            spyCopy    = function() if _G.spyCopy   then _G.spyCopy()   end end,
            clear      = function()
                for _,child in ipairs(inner:GetChildren()) do
                    if child:IsA("TextLabel") then child:Destroy() end
                end
                CONSOLE_LINES = {}
            end,
            help       = function()
                cprint("Commands:", LINE_COLORS.WARN)
                cprint("  spyDone | spyReport | spyClear | spyCopy", LINE_COLORS.INFO)
                cprint("  spySave | spyMap | spyTime | spyMem | spySweep", LINE_COLORS.INFO)
                cprint("  clear | help", LINE_COLORS.INFO)
            end,
        }

        if cmdMap[cmd] then
            cmdMap[cmd]()
        else
            cprint("Command tidak dikenal. Ketik 'help'.", LINE_COLORS.ERR)
        end
    end)

    -- Update badge event count tiap 1 detik
    task.spawn(function()
        while sg and sg.Parent do
            task.wait(1)
            pcall(function()
                badge.Text = #LOG.." evt"
            end)
        end
    end)

    return sg
end

-- Fungsi tulis 1 baris ke console GUI
-- Dipanggil dari mana saja di script
function cprint(text, color)
    text = tostring(text)
    -- Tetap print ke developer console juga
    print(text)

    -- Simpan ke buffer
    CONSOLE_LINES[#CONSOLE_LINES+1] = text
    if #CONSOLE_LINES > MAX_LINES then
        table.remove(CONSOLE_LINES, 1)
    end

    -- Render ke GUI kalau sudah tersedia
    if not consoleInner then return end

    pcall(function()
        local lc = color or getLineColor(text)

        local label = Instance.new("TextLabel")
        label.Size                    = UDim2.new(1, 0, 0, 0)
        label.AutomaticSize           = Enum.AutomaticSize.Y
        label.BackgroundTransparency  = 1
        label.Text                    = text
        label.TextColor3              = lc
        label.TextSize                = 11
        label.Font                    = Enum.Font.Code
        label.TextXAlignment          = Enum.TextXAlignment.Left
        label.TextWrapped             = true
        label.LayoutOrder             = #CONSOLE_LINES
        label.Parent                  = consoleInner

        -- Hapus baris paling lama kalau melebihi MAX_LINES
        local children = consoleInner:GetChildren()
        local labels = {}
        for _,c in ipairs(children) do
            if c:IsA("TextLabel") then labels[#labels+1]=c end
        end
        if #labels > MAX_LINES then
            labels[1]:Destroy()
        end

        -- Auto-scroll ke bawah
        task.defer(function()
            pcall(function()
                if consoleScroll then
                    consoleScroll.CanvasPosition = Vector2.new(
                        0, consoleScroll.AbsoluteCanvasSize.Y)
                end
            end)
        end)
    end)
end

-- Toggle show/hide console
local function toggleConsole()
    if not consoleFrame then
        buildConsoleGui()
        -- Replay buffer ke GUI
        task.spawn(function()
            task.wait(0.1)
            for _,line in ipairs(CONSOLE_LINES) do
                pcall(function()
                    local lc = getLineColor(line)
                    local label = Instance.new("TextLabel")
                    label.Size                   = UDim2.new(1, 0, 0, 0)
                    label.AutomaticSize          = Enum.AutomaticSize.Y
                    label.BackgroundTransparency = 1
                    label.Text                   = line
                    label.TextColor3             = lc
                    label.TextSize               = 11
                    label.Font                   = Enum.Font.Code
                    label.TextXAlignment         = Enum.TextXAlignment.Left
                    label.TextWrapped            = true
                    label.Parent                 = consoleInner
                end)
            end
            -- Scroll ke bawah setelah replay
            task.wait(0.1)
            pcall(function()
                consoleScroll.CanvasPosition = Vector2.new(
                    0, consoleScroll.AbsoluteCanvasSize.Y)
            end)
        end)
    end
    consoleVisible = not consoleVisible
    consoleFrame.Visible = consoleVisible
end

-- Build GUI langsung supaya siap sebelum scan
buildConsoleGui()

-- ══════════════════════════════════════════════════════
--  CALLSTACK — dapatkan asal panggilan
-- ══════════════════════════════════════════════════════
local function getStack()
    local result = ""
    -- getcallstack (Synapse X / Fluxus style)
    if getcallstack then
        pcall(function()
            for _,f in ipairs(getcallstack()) do
                local src = tostring(f.source or f.name or "")
                if src~="" and not src:find("UniversalSpy")
                and not src:find("@") then
                    result = src..(f.currentline and ":"..f.currentline or "")
                    break
                end
            end
        end)
    end
    -- debug.traceback fallback
    if result=="" then
        pcall(function()
            local tb = debug.traceback("",3)
            for line in tb:gmatch("[^\n]+") do
                line = line:match("^%s*(.-)%s*$") or ""
                if #line>0 and not line:find("UniversalSpy")
                and not line:find("^stack") then
                    result = line:sub(1,100); break
                end
            end
        end)
    end
    return result
end

-- ══════════════════════════════════════════════════════
--  REMOTE REGISTRY — universal, semua game
--  Tidak hardcode nama remote apapun
-- ══════════════════════════════════════════════════════
local REGISTRY   = {}  -- path → instance
local SKIP_PATHS = {   -- filter noise sistem Roblox
    "RobloxReplicatedStorage", "CoreGui",
    "RobloxGui", "StarterGui.RobloxStuff",
}

local function shouldSkip(path)
    for _,s in ipairs(SKIP_PATHS) do
        if path:find(s,1,true) then return true end
    end
    return false
end

local function registerRemote(remote)
    local path = ""
    pcall(function() path = remote:GetFullName() end)
    if path=="" or shouldSkip(path) then return false end
    if REGISTRY[path] then return false end
    REGISTRY[path] = remote
    return true
end

-- ══════════════════════════════════════════════════════
--  [A] RUNTIME HOOKS — C->S dan S->C
-- ══════════════════════════════════════════════════════
local hfHooks    = {}
local clientConns= {}
local A_HF_OK    = false
local A_NC_OK    = false
local ncData     = nil

-- Hook satu remote (FireServer + OnClientEvent)
local function hookOneRemote(remote)
    local path = ""
    pcall(function() path = remote:GetFullName() end)
    if path=="" then return end

    -- C->S: hookfunction pada FireServer/InvokeServer
    if hookfunction then
        pcall(function()
            if remote:IsA("RemoteEvent") then
                local orig = hookfunction(remote.FireServer,
                    newcclosure(function(self,a1,a2,a3,a4,a5,a6)
                        local args={}
                        if a1~=nil then args[1]=a1 end
                        if a2~=nil then args[2]=a2 end
                        if a3~=nil then args[3]=a3 end
                        if a4~=nil then args[4]=a4 end
                        if a5~=nil then args[5]=a5 end
                        if a6~=nil then args[6]=a6 end
                        logEvent("C-S",path,"FireServer",args,getStack())
                        return orig(self,a1,a2,a3,a4,a5,a6)
                    end)
                )
                hfHooks[#hfHooks+1]={remote.FireServer,orig}
                A_HF_OK = true
            elseif remote:IsA("RemoteFunction") then
                local orig = hookfunction(remote.InvokeServer,
                    newcclosure(function(self,a1,a2,a3,a4,a5)
                        local args={}
                        if a1~=nil then args[1]=a1 end
                        if a2~=nil then args[2]=a2 end
                        if a3~=nil then args[3]=a3 end
                        if a4~=nil then args[4]=a4 end
                        if a5~=nil then args[5]=a5 end
                        logEvent("C-S",path,"InvokeServer",args,getStack())
                        return orig(self,a1,a2,a3,a4,a5)
                    end)
                )
                hfHooks[#hfHooks+1]={remote.InvokeServer,orig}
                A_HF_OK = true
            end
        end)
    end

    -- S->C: OnClientEvent / OnClientInvoke
    pcall(function()
        if remote:IsA("RemoteEvent") then
            local conn = remote.OnClientEvent:Connect(function(a1,a2,a3,a4,a5,a6)
                local args={}
                if a1~=nil then args[1]=a1 end
                if a2~=nil then args[2]=a2 end
                if a3~=nil then args[3]=a3 end
                if a4~=nil then args[4]=a4 end
                if a5~=nil then args[5]=a5 end
                if a6~=nil then args[6]=a6 end
                logEvent("S-C",path,"OnClientEvent",args,"")
            end)
            clientConns[#clientConns+1] = conn
        elseif remote:IsA("RemoteFunction") then
            local origCB = remote.OnClientInvoke
            remote.OnClientInvoke = newcclosure(function(a1,a2,a3,a4,a5)
                local args={}
                if a1~=nil then args[1]=a1 end
                if a2~=nil then args[2]=a2 end
                if a3~=nil then args[3]=a3 end
                if a4~=nil then args[4]=a4 end
                if a5~=nil then args[5]=a5 end
                logEvent("S-C",path,"OnClientInvoke",args,"")
                if origCB then return origCB(a1,a2,a3,a4,a5) end
            end)
        end
    end)
end

-- __namecall global sebagai double-catch
local function startNamecall()
    local mt
    pcall(function() mt=getrawmetatable(game) end)
    if not mt then return false end

    local unlocked=false
    if make_writeable  then pcall(function() make_writeable(mt);    unlocked=true end) end
    if not unlocked and setreadonly then
        pcall(function() setreadonly(mt,false); unlocked=true end) end
    if not unlocked then
        pcall(function() mt.__metatable=nil;    unlocked=true end) end
    if not unlocked then return false end

    local origNC = mt.__namecall
    mt.__namecall = newcclosure(function(self,a1,a2,a3,a4,a5,a6)
        local method = getnamecallmethod and getnamecallmethod() or ""
        if method=="FireServer" or method=="InvokeServer" then
            pcall(function()
                if self:IsA("RemoteEvent") or self:IsA("RemoteFunction") then
                    local path=""
                    pcall(function() path=self:GetFullName() end)
                    if not shouldSkip(path) then
                        local args={}
                        if a1~=nil then args[1]=a1 end
                        if a2~=nil then args[2]=a2 end
                        if a3~=nil then args[3]=a3 end
                        if a4~=nil then args[4]=a4 end
                        if a5~=nil then args[5]=a5 end
                        if a6~=nil then args[6]=a6 end
                        logEvent("C-S",path,method,args,getStack())
                    end
                end
            end)
        end
        -- origNC dipanggil dengan explicit args, bukan ...
        if origNC then
            return origNC(self,a1,a2,a3,a4,a5,a6)
        end
    end)

    if setreadonly then pcall(function() setreadonly(mt,true) end) end
    ncData={mt=mt,orig=origNC}
    return true
end

-- Scan + hook semua remote di game (universal)
local function scanAndHookAll()
    local n=0

    -- Fungsi rekursif scan semua service
    local function deepScan(parent, depth)
        if depth>8 or not parent then return end
        pcall(function()
            for _,child in ipairs(parent:GetDescendants()) do
                pcall(function()
                    if child:IsA("RemoteEvent") or child:IsA("RemoteFunction") then
                        if registerRemote(child) then
                            hookOneRemote(child)
                            n=n+1
                        end
                    end
                end)
            end
        end)
    end

    -- Scan semua service yang accessible dari client
    local services = {
        RS,
        game:GetService("ReplicatedFirst"),
        WS,
        LP.PlayerGui,
        LP.PlayerScripts,
    }
    for _,svc in ipairs(services) do
        pcall(function() if svc then deepScan(svc,0) end end)
    end

    -- getinstances() — temukan hidden/nil-parented remotes
    if getinstances then
        pcall(function()
            for _,inst in ipairs(getinstances()) do
                pcall(function()
                    if inst:IsA("RemoteEvent") or inst:IsA("RemoteFunction") then
                        if registerRemote(inst) then
                            hookOneRemote(inst)
                            n=n+1
                            -- Cek apakah hidden
                            local isHidden=false
                            pcall(function() isHidden=(inst.Parent==nil) end)
                            if isHidden then
                                print("[HIDDEN REMOTE] "..inst.Name
                                    .." ("..inst.ClassName..")")
                            end
                        end
                    end
                end)
            end
        end)
    end

    -- Listen untuk remote baru yang muncul di masa depan
    -- (game yang spawn remote secara dinamis)
    pcall(function()
        RS.DescendantAdded:Connect(function(inst)
            pcall(function()
                if inst:IsA("RemoteEvent") or inst:IsA("RemoteFunction") then
                    task.wait(0.1) -- beri waktu parent ter-set
                    if registerRemote(inst) then
                        hookOneRemote(inst)
                        print("[NEW REMOTE] "..inst:GetFullName())
                    end
                end
            end)
        end)
    end)

    return n
end

-- ══════════════════════════════════════════════════════
--  [B] DEEP DECOMPILE — semua client script
-- ══════════════════════════════════════════════════════
local DECOMP_RESULTS = {}
local B_OK = false

local PATS = {
    -- Network
    "FireServer","InvokeServer","OnClientEvent","OnClientInvoke",
    "FireAllClients","FireClient",
    -- Remote access patterns
    "RemoteEvent","RemoteFunction","BindableEvent",
    "WaitForChild","FindFirstChild",
    -- Data patterns
    '"action"','"type"','"cmd"','"command"','"event"',
    '"data"','"payload"','"args"','"params"',
    -- Security-relevant
    "loadstring","require","getfenv","setfenv",
    "pcall","xpcall","coroutine",
    -- Storage
    "_G%.","shared%.","getgenv","getrenv",
}

local function decompAndScan(obj)
    if not decompile then return {} end
    local res={}
    pcall(function()
        local src=decompile(obj)
        if not src or #src<5 then return end
        local ln=0
        for line in src:gmatch("[^\n]+") do
            ln=ln+1
            local c=line:match("^%s*(.-)%s*$") or ""
            if #c>3 and #c<600 and not c:match("^%-%-") then
                for _,pat in ipairs(PATS) do
                    if c:find(pat) then
                        res[#res+1]={
                            script=obj.Name,
                            path=obj:GetFullName(),
                            ln=ln, code=c, pat=pat
                        }
                        break
                    end
                end
            end
        end
    end)
    return res
end

local function runDecompile()
    if not decompile then return false end
    local scanned,hits=0,0

    local containers={}
    pcall(function() containers[#containers+1]=LP.PlayerGui end)
    pcall(function() containers[#containers+1]=LP.PlayerScripts end)
    pcall(function() containers[#containers+1]=RS end)
    pcall(function()
        containers[#containers+1]=game:GetService("StarterGui")
    end)
    pcall(function()
        containers[#containers+1]=game:GetService("StarterPack")
    end)

    for _,cont in ipairs(containers) do
        pcall(function()
            for _,obj in ipairs(cont:GetDescendants()) do
                if obj:IsA("LocalScript") or obj:IsA("ModuleScript") then
                    scanned=scanned+1
                    local res=decompAndScan(obj)
                    for _,r in ipairs(res) do
                        DECOMP_RESULTS[#DECOMP_RESULTS+1]=r
                        hits=hits+1
                    end
                end
            end
        end)
    end

    cprint(string.format("[B-decompile] %d script → %d hit",scanned,hits), LINE_COLORS.WARN)

    -- Print grouped by script
    local byPath={}
    for _,r in ipairs(DECOMP_RESULTS) do
        byPath[r.path]=byPath[r.path] or {}
        table.insert(byPath[r.path],r)
    end
    for path,rows in pairs(byPath) do
        cprint("  📄 "..path.."  ("..#rows.." hit)", LINE_COLORS.STATIC)
        for _,r in ipairs(rows) do
            cprint(string.format("     L%-4d [%-16s] %s",
                r.ln,r.pat,r.code), LINE_COLORS.STATIC)
        end
    end

    return hits>0
end

-- ══════════════════════════════════════════════════════
--  [C] MEMORY FORENSIC — upvalue, closure, env
--  Rekonstruksi data tersembunyi dari memory
-- ══════════════════════════════════════════════════════
local C_OK = false

-- Scan upvalue sebuah function untuk temukan remote reference
local function scanUpvalues(fn, label)
    if not getupvalues then return end
    pcall(function()
        local ups = getupvalues(fn)
        for i, val in ipairs(ups) do
            local t = typeof(val)
            if t=="Instance" then
                local cls=val.ClassName
                if cls:find("Remote") or cls:find("Bindable") then
                    cprint(string.format(
                        "  [UPVALUE] %s[%d] = %s (%s)",
                        label, i, val:GetFullName(), cls), LINE_COLORS.MEM)
                    ENV_FOUND[#ENV_FOUND+1]={
                        src="upvalue:"..label,
                        key=tostring(i),
                        val=val:GetFullName(),
                        type=cls
                    }
                    registerRemote(val)
                    hookOneRemote(val)
                end
            end
        end
    end)
end

-- Scan environment sebuah script untuk remote
local function scanScriptEnv(envFn, label)
    if not envFn then return end
    pcall(function()
        local env=envFn()
        if type(env)~="table" then return end
        for k,v in pairs(env) do
            local t=typeof(v)
            if t=="Instance" and
            (v.ClassName:find("Remote") or v.ClassName:find("Bindable")) then
                print(string.format("  [ENV] %s.%s = %s (%s)",
                    label, tostring(k), v:GetFullName(), v.ClassName))
                ENV_FOUND[#ENV_FOUND+1]={
                    src=label, key=tostring(k),
                    val=v:GetFullName(), type=v.ClassName
                }
                registerRemote(v)
                hookOneRemote(v)
            elseif t=="table" then
                -- Satu level dalam
                pcall(function()
                    for k2,v2 in pairs(v) do
                        if typeof(v2)=="Instance" and
                        (v2.ClassName:find("Remote") or v2.ClassName:find("Bindable")) then
                            print(string.format("  [ENV] %s.%s.%s = %s",
                                label,tostring(k),tostring(k2),v2:GetFullName()))
                            ENV_FOUND[#ENV_FOUND+1]={
                                src=label.."."..tostring(k),
                                key=tostring(k2),
                                val=v2:GetFullName(),
                                type=v2.ClassName
                            }
                            registerRemote(v2)
                            hookOneRemote(v2)
                        end
                    end
                end)
            end
        end
    end)
end

local function runMemForensic()
    print("[C-memory] Forensic scan: upvalue, closure, env...")
    local found=0

    -- Scan _G
    pcall(function() scanScriptEnv(function() return _G end, "_G") end)

    -- Scan shared
    pcall(function() scanScriptEnv(function() return shared end, "shared") end)

    -- getrenv (Roblox environment)
    if getrenv then
        pcall(function() scanScriptEnv(getrenv, "getrenv") end)
    end

    -- getgenv (executor global env)
    if getgenv then
        pcall(function() scanScriptEnv(getgenv, "getgenv") end)
    end

    -- Scan upvalue semua LocalScript yang running
    if getupvalues and getscripts then
        pcall(function()
            for _,script in ipairs(getscripts()) do
                pcall(function()
                    if script:IsA("LocalScript") or script:IsA("ModuleScript") then
                        scanUpvalues(script, script:GetFullName())
                    end
                end)
            end
        end)
    end

    found = #ENV_FOUND
    print("[C-memory] "..found.." remote/data ditemukan di memory.")
    return found > 0
end

-- ══════════════════════════════════════════════════════
--  [D] INSTANCE SWEEP — universal, semua map
-- ══════════════════════════════════════════════════════
local D_OK = false

local function runInstanceSweep()
    print("[D-sweep] Full instance sweep...")

    local allRemotes = {}
    local hiddenRemotes = {}

    -- getinstances() — paling lengkap
    if getinstances then
        pcall(function()
            for _,inst in ipairs(getinstances()) do
                pcall(function()
                    if inst:IsA("RemoteEvent") or inst:IsA("RemoteFunction")
                    or inst:IsA("BindableEvent") or inst:IsA("BindableFunction") then
                        local path=""
                        pcall(function() path=inst:GetFullName() end)
                        local hidden=false
                        pcall(function() hidden=(inst.Parent==nil) end)

                        allRemotes[#allRemotes+1]={
                            inst=inst, path=path,
                            class=inst.ClassName,
                            hidden=hidden
                        }
                        if hidden then hiddenRemotes[#hiddenRemotes+1]=allRemotes[#allRemotes] end
                    end
                end)
            end
        end)
    end

    -- Scan tree secara rekursif
    local function treeWalk(parent, depth)
        if depth>6 then return end
        pcall(function()
            for _,child in ipairs(parent:GetChildren()) do
                local cls=child.ClassName
                if cls=="RemoteEvent" or cls=="RemoteFunction"
                or cls=="BindableEvent" or cls=="BindableFunction" then
                    allRemotes[#allRemotes+1]={
                        inst=child,
                        path=child:GetFullName(),
                        class=cls, hidden=false
                    }
                end
                treeWalk(child, depth+1)
            end
        end)
    end

    for _,svcName in ipairs({
        "ReplicatedStorage","ReplicatedFirst",
        "Workspace","Players",
        "ServerScriptService","ServerStorage",
    }) do
        pcall(function()
            local svc=game:GetService(svcName)
            if svc then treeWalk(svc,0) end
        end)
    end

    -- Deduplicate
    local seen,unique={},{}
    for _,r in ipairs(allRemotes) do
        local key=r.path~="" and r.path or r.class..r.inst.Name
        if not seen[key] then
            seen[key]=true
            unique[#unique+1]=r
        end
    end

    print(string.format("[D-sweep] %d remote/bindable unik ditemukan:", #unique))
    print(string.rep("--",56))
    for _,r in ipairs(unique) do
        local tag = r.hidden and " ⚠HIDDEN" or ""
        print(string.format("  [%-20s] %s%s",
            r.class, r.path~="" and r.path or r.inst.Name, tag))
    end

    if #hiddenRemotes>0 then
        print(string.format("\n  ⚠ %d HIDDEN instance (nil-parented):",
            #hiddenRemotes))
        for _,r in ipairs(hiddenRemotes) do
            print("    → "..r.inst.Name.." ("..r.class..")")
        end
    end
    print(string.rep("--",56))

    return #unique > 0
end

-- ══════════════════════════════════════════════════════
--  [E] NETWORK TIMING ANALYSIS
--  Jalankan background — catat interval antar call
--  untuk deteksi pola timing yang bisa dimanipulasi
-- ══════════════════════════════════════════════════════
local TIMING = {}  -- path → {timestamps}
local E_active = false

local function recordTiming(path)
    TIMING[path] = TIMING[path] or {}
    TIMING[path][#TIMING[path]+1] = os.clock()
end

-- Patch addLog untuk juga record timing
local _origLogEvent = logEvent
logEvent = function(dir, path, method, args, stack)
    if dir=="C-S" then recordTiming(path) end
    _origLogEvent(dir, path, method, args, stack)
end

local function analyzeTimings()
    cprint("\n[E-timing] Network timing analysis:", LINE_COLORS.WARN)
    cprint(string.rep("--",56), LINE_COLORS.SEP)
    for path, ts in pairs(TIMING) do
        if #ts >= 2 then
            local intervals={}
            for i=2,#ts do
                intervals[#intervals+1] = ts[i]-ts[i-1]
            end
            local sum=0
            for _,v in ipairs(intervals) do sum=sum+v end
            local avg = sum/#intervals
            local minI,maxI = math.huge,-math.huge
            for _,v in ipairs(intervals) do
                if v<minI then minI=v end
                if v>maxI then maxI=v end
            end
            cprint(string.format("  %-35s calls:%-4d avg:%.3fs min:%.3fs max:%.3fs",
                path:sub(-35), #ts, avg, minI, maxI), LINE_COLORS.INFO)
        end
    end
    cprint(string.rep("--",56), LINE_COLORS.SEP)
end

-- ══════════════════════════════════════════════════════
--  [G] AUTO-MAP: bangun peta komunikasi game
--  Hasil: tabel remote → {purpose, args pattern, response}
-- ══════════════════════════════════════════════════════
local function buildNetworkMap()
    print("\n[G-map] AUTO-MAP jaringan komunikasi:")
    print(string.rep("==",60))

    -- Inference sederhana berdasarkan nama & pola arg
    local function inferPurpose(path, nm)
        local name = path:lower()
        local topArgs = {}
        for argStr,cnt in pairs(nm.sendArgs) do
            topArgs[#topArgs+1]={argStr=argStr,cnt=cnt}
        end
        table.sort(topArgs,function(a,b) return a.cnt>b.cnt end)

        local purpose = "unknown"
        -- Inference dari nama remote
        if name:find("base")    then purpose="main dispatcher"
        elseif name:find("unit")    then purpose="unit control"
        elseif name:find("pet")     then purpose="pet system"
        elseif name:find("build")   then purpose="building/placement"
        elseif name:find("upgrade") then purpose="upgrade system"
        elseif name:find("purchase") or name:find("buy") then purpose="purchase"
        elseif name:find("teleport") then purpose="teleport"
        elseif name:find("command") then purpose="command dispatch"
        elseif name:find("result")  then purpose="match/wave result"
        elseif name:find("monster") then purpose="monster interaction"
        elseif name:find("notify") or name:find("notif") then purpose="notification"
        elseif name:find("audio") or name:find("sound") then purpose="audio control"
        end

        return purpose, topArgs
    end

    for path, nm in pairs(NET_MAP) do
        local purpose, topArgs = inferPurpose(path, nm)
        cprint(string.format("\n  ▶ %s", path), LINE_COLORS.CS)
        cprint(string.format("    Purpose   : %s", purpose), LINE_COLORS.INFO)
        cprint(string.format("    Calls     : %d C->S  |  responses: %d S->C",
            nm.callCount, (function()
                local n=0
                for _,_ in pairs(nm.recvArgs) do n=n+1 end
                return n
            end)()), LINE_COLORS.INFO)

        if #topArgs>0 then
            cprint("    Top args  :", LINE_COLORS.INFO)
            for i=1,math.min(3,#topArgs) do
                cprint(string.format("      [×%d] %s",
                    topArgs[i].cnt, topArgs[i].argStr), LINE_COLORS.CS)
            end
        end

        local recvList={}
        for argStr,cnt in pairs(nm.recvArgs) do
            recvList[#recvList+1]={argStr=argStr,cnt=cnt}
        end
        table.sort(recvList,function(a,b) return a.cnt>b.cnt end)
        if #recvList>0 then
            cprint("    Responses :", LINE_COLORS.INFO)
            for i=1,math.min(3,#recvList) do
                cprint(string.format("      [×%d] %s",
                    recvList[i].cnt, recvList[i].argStr), LINE_COLORS.SC)
            end
        end
    end
    cprint("\n"..string.rep("==",60), LINE_COLORS.SEP)
end

-- ══════════════════════════════════════════════════════
--  [H] saveinstance
-- ══════════════════════════════════════════════════════
local function runSaveInstance()
    if not saveinstance then print("[H] saveinstance tidak ada"); return false end
    print("[H] Dump game ke file... (~20 detik)")
    local ok=false
    pcall(function()
        saveinstance({
            SaveWorkspace=true, SaveReplicatedStorage=true,
            SaveLighting=true, ReplicatedFirst=true,
            SavePlayers=false,
            filename="AllMap_"..tostring(game.PlaceId)..".rbxlx",
        })
        ok=true
    end)
    if not ok then pcall(function() saveinstance(); ok=true end) end
    if ok then
        print("[H] ✓ AllMap_"..tostring(game.PlaceId)..".rbxlx")
    end
    return ok
end

-- ══════════════════════════════════════════════════════
--  UNHOOK ALL
-- ══════════════════════════════════════════════════════
local function unhookAll()
    for _,h in ipairs(hfHooks) do
        pcall(function() hookfunction(h[1],h[2]) end)
    end
    hfHooks={}

    for _,conn in ipairs(clientConns) do
        pcall(function() conn:Disconnect() end)
    end
    clientConns={}

    if ncData then
        pcall(function()
            ncData.mt.__namecall=ncData.orig
            if setreadonly then setreadonly(ncData.mt,true) end
        end)
        ncData=nil
    end

    print("[SPY] ✓ Semua hook dibersihkan.")
    cprint("[SPY] ✓ Semua hook dibersihkan.", LINE_COLORS.WARN)
end

-- ══════════════════════════════════════════════════════
--  FINAL REPORT
-- ══════════════════════════════════════════════════════
local function printReport()
    cprint("\n"..string.rep("==",60), LINE_COLORS.SEP)
    cprint("  UNIVERSAL SPY — FINAL REPORT", LINE_COLORS.WARN)
    cprint("  Game    : "..tostring(game.Name), LINE_COLORS.INFO)
    cprint("  PlaceId : "..tostring(game.PlaceId), LINE_COLORS.INFO)
    cprint("  Events  : "..#LOG, LINE_COLORS.INFO)
    cprint("  Remotes : "..(function()
        local n=0; for _ in pairs(REGISTRY) do n=n+1 end; return n end)(),
        LINE_COLORS.INFO)
    cprint(string.rep("==",60), LINE_COLORS.SEP)

    local cs,sc={},{}
    for _,e in ipairs(LOG) do
        if e.dir=="C-S" then cs[#cs+1]=e else sc[#sc+1]=e end
    end

    if #cs>0 then
        cprint("\n── CLIENT → SERVER ──────────────────────────────────", LINE_COLORS.CS)
        local g={}
        for _,e in ipairs(cs) do
            g[e.path]=g[e.path] or {}
            table.insert(g[e.path],e)
        end
        for path,entries in pairs(g) do
            cprint(string.format("\n  ▶ %s  (%d)",path,#entries), LINE_COLORS.CS)
            local seen={}
            for _,e in ipairs(entries) do
                local sig=e.method.."("..e.argStr..")"
                seen[sig]=(seen[sig] or 0)+1
            end
            for sig,cnt in pairs(seen) do
                cprint(string.format("    [×%d] %s",cnt,sig), LINE_COLORS.INFO)
            end
        end
    end

    if #sc>0 then
        cprint("\n── SERVER → CLIENT ──────────────────────────────────", LINE_COLORS.SC)
        local g={}
        for _,e in ipairs(sc) do
            g[e.path]=g[e.path] or {}
            table.insert(g[e.path],e)
        end
        for path,entries in pairs(g) do
            cprint(string.format("\n  ▶ %s  (%d)",path,#entries), LINE_COLORS.SC)
            local seen={}
            for _,e in ipairs(entries) do
                local sig=e.method.."("..e.argStr..")"
                seen[sig]=(seen[sig] or 0)+1
            end
            for sig,cnt in pairs(seen) do
                cprint(string.format("    [×%d] %s",cnt,sig), LINE_COLORS.INFO)
            end
        end
    end

    if #ENV_FOUND>0 then
        cprint("\n── MEMORY FORENSIC ──────────────────────────────────", LINE_COLORS.MEM)
        for _,d in ipairs(ENV_FOUND) do
            cprint(string.format("  [%s] %s = %s (%s)",
                d.src,d.key,d.val,d.type), LINE_COLORS.MEM)
        end
    end

    analyzeTimings()
    buildNetworkMap()

    -- Section copy-paste langsung di console
    cprint("\n"..string.rep("==",60), LINE_COLORS.SEP)
    cprint("  ── AUTOMATION READY (siap copy) ──", LINE_COLORS.COPY)
    cprint(string.rep("--",60), LINE_COLORS.SEP)
    local unique={}
    for _,e in ipairs(cs) do
        local key=e.path.."|"..e.argStr
        if not unique[key] then
            unique[key]=true
            local rName=e.path:match("[^.]+$") or e.path
            cprint(string.format(
                'local r=game:GetService("ReplicatedStorage"):FindFirstChild("%s",true)',
                rName), LINE_COLORS.COPY)
            cprint(string.format('if r then r:%s(%s) end',
                e.method, e.argStr), LINE_COLORS.COPY)
            cprint("", LINE_COLORS.SEP)
        end
    end
    cprint(string.rep("==",60), LINE_COLORS.SEP)

    -- Buka console otomatis saat report selesai
    if consoleFrame and not consoleVisible then
        consoleFrame.Visible = true
        consoleVisible = true
    end
    -- Scroll ke bawah
    task.defer(function()
        pcall(function()
            if consoleScroll then
                consoleScroll.CanvasPosition = Vector2.new(
                    0, consoleScroll.AbsoluteCanvasSize.Y)
            end
        end)
    end)
end

-- ══════════════════════════════════════════════════════
--  WINDUI LOAD
-- ══════════════════════════════════════════════════════
local WindUI
local uiOK = false
pcall(function()
    WindUI = loadstring(game:HttpGet(
        "https://raw.githubusercontent.com/Footagesus/WindUI/main/dist/main.lua"
    ))()
    uiOK = WindUI ~= nil
end)

if not uiOK then
    warn("[UniversalSpy] WindUI gagal load — lanjut tanpa UI.")
end

-- ══════════════════════════════════════════════════════
--  START — jalankan semua teknik
-- ══════════════════════════════════════════════════════
print("\n"..string.rep("==",60))
print("  UNIVERSAL SPY  —  All Map Edition")
print("  Game    : "..tostring(game.Name))
print("  PlaceId : "..tostring(game.PlaceId))
print(string.rep("==",60))

-- State untuk UI
local spyActive   = false
local nHooked     = 0
local autoStopJob = nil

-- Label status ringkas
local function statusLabel()
    return string.format(
        "Hooks: %d | Log: %d | C->S: %d | S->C: %d",
        nHooked,
        #LOG,
        (function() local n=0
            for _,e in ipairs(LOG) do if e.dir=="C-S" then n=n+1 end end
            return n end)(),
        (function() local n=0
            for _,e in ipairs(LOG) do if e.dir=="S-C" then n=n+1 end end
            return n end)()
    )
end

-- Notify helper (safe — tidak crash kalau UI belum siap)
local function notify(title, content, dur)
    dur = dur or 4
    if uiOK and WindUI then
        pcall(function()
            WindUI:Notify({
                Title    = title,
                Content  = content,
                Duration = dur,
                Icon     = "solar:bug-bold",
            })
        end)
    end
    print("[NOTIFY] "..title..": "..content)
end

-- ── Jalankan semua teknik saat start ─────────────────
local function startAllTechniques()
    notify("Universal Spy", "Memulai semua teknik...", 3)
    cprint(string.rep("==",60), LINE_COLORS.SEP)
    cprint("  UNIVERSAL SPY  —  All Map Edition", LINE_COLORS.WARN)
    cprint("  Game    : "..tostring(game.Name), LINE_COLORS.INFO)
    cprint("  PlaceId : "..tostring(game.PlaceId), LINE_COLORS.INFO)
    cprint(string.rep("==",60), LINE_COLORS.SEP)

    cprint("\n[▶] A — Runtime hooks (C->S + S->C)...", LINE_COLORS.WARN)
    nHooked = scanAndHookAll()
    A_NC_OK = startNamecall()
    cprint(string.format("[A] %d remote di-hook | namecall: %s",
        nHooked, A_NC_OK and "[OK]" or "[X]"), LINE_COLORS.WARN)

    cprint("\n[▶] B — Deep decompile...", LINE_COLORS.WARN)
    B_OK = runDecompile()

    cprint("\n[▶] C — Memory forensic...", LINE_COLORS.WARN)
    C_OK = runMemForensic()

    cprint("\n[▶] D — Instance sweep...", LINE_COLORS.WARN)
    D_OK = runInstanceSweep()

    spyActive = true

    cprint(string.rep("--",60), LINE_COLORS.SEP)
    cprint(string.format("  Remotes hooked : %d", nHooked), LINE_COLORS.INFO)
    cprint(string.format("  namecall hook  : %s", A_NC_OK and "[OK]" or "[X]"), LINE_COLORS.INFO)
    cprint(string.format("  Decompiler     : %s", B_OK and "[OK]" or "[X]"), LINE_COLORS.INFO)
    cprint(string.format("  Memory forensic: %s", C_OK and "[OK]" or "[X]"), LINE_COLORS.INFO)
    cprint(string.format("  Instance sweep : %s", D_OK and "[OK]" or "[X]"), LINE_COLORS.INFO)
    cprint(string.rep("==",60), LINE_COLORS.SEP)
    cprint("  ✓ Spy aktif. Main game lalu klik spyDone.", LINE_COLORS.COPY)

    notify("Spy Aktif ✓",
        string.format("%d remote di-hook | Main game lalu spyDone()", nHooked), 6)

    -- Auto-buka console setelah scan selesai
    if consoleFrame then
        consoleFrame.Visible = true
        consoleVisible = true
        -- Scroll ke bawah
        task.defer(function()
            pcall(function()
                consoleScroll.CanvasPosition = Vector2.new(
                    0, consoleScroll.AbsoluteCanvasSize.Y)
            end)
        end)
    end
end

-- ── Auto-stop 120 detik ──────────────────────────────
autoStopJob = task.delay(120, function()
    if spyActive and #LOG>0 then
        unhookAll()
        spyActive = false
        printReport()
        notify("Auto-Stop", "120 detik selesai. Lihat console untuk report.", 5)
    end
end)

-- ══════════════════════════════════════════════════════
--  WINDUI — BUILD WINDOW
-- ══════════════════════════════════════════════════════
if uiOK and WindUI then
    local Window = WindUI:CreateWindow({
        Title       = "Universal Spy",
        Author      = "All Map Edition",
        Icon        = "solar:bug-bold",
        Theme       = "Dark",
        Transparent = true,
        Acrylic     = true,
        NewElements = false,
    })

    -- ── TAB 1: CONTROL ───────────────────────────────
    local T1 = Window:Tab({ Title = "Control", Icon = "solar:bug-bold" })
    T1:Select()

    T1:Section({ Title = "Game Info" })
    T1:Paragraph({
        Title   = "Target",
        Content = tostring(game.Name).." | PlaceId: "..tostring(game.PlaceId),
    })

    T1:Section({ Title = "Spy Control" })

    -- Toggle utama: start/stop spy
    local spyToggle
    spyToggle = T1:Toggle({
        Title       = "Spy Active",
        Description = "Mulai/hentikan semua hook runtime",
        Default     = false,
        Callback    = function(val)
            if val then
                if not spyActive then
                    startAllTechniques()
                end
            else
                if spyActive then
                    unhookAll()
                    spyActive = false
                    notify("Spy Stopped", "Semua hook dilepas.", 3)
                end
            end
        end,
    })

    T1:Space({ Columns = 0.3 })

    -- Tombol: Print Report
    T1:Button({
        Title       = "Print Report",
        Description = "Cetak hasil log ke console",
        Icon        = "solar:document-text-bold",
        Callback    = function()
            printReport()
            notify("Report", "Lihat console untuk hasil lengkap.", 4)
        end,
    })

    -- Tombol: Clear Log
    T1:Button({
        Title       = "Clear Log",
        Description = "Kosongkan semua log event",
        Icon        = "solar:trash-bin-trash-bold",
        Callback    = function()
            LOG = {}
            logCount = {}
            notify("Cleared", "Log dikosongkan.", 3)
        end,
    })

    -- Tombol: Toggle Console
    T1:Button({
        Title       = "🖥 Open Console",
        Description = "Buka/tutup terminal GUI in-game",
        Icon        = "solar:monitor-bold",
        Callback    = function()
            toggleConsole()
        end,
    })

    T1:Space({ Columns = 0.3 })
    T1:Section({ Title = "Status" })

    -- Paragraph status (update tiap 2 detik)
    local statusPara = T1:Paragraph({
        Title   = "Live Status",
        Content = statusLabel(),
    })

    task.spawn(function()
        while true do
            task.wait(2)
            pcall(function()
                if statusPara and statusPara.SetContent then
                    statusPara:SetContent(statusLabel())
                elseif statusPara and statusPara.Paragraph then
                    -- fallback WindUI API lama
                    statusPara.Paragraph.Content.Text = statusLabel()
                end
            end)
        end
    end)

    -- ── TAB 2: TEKNIK ────────────────────────────────
    local T2 = Window:Tab({ Title = "Teknik", Icon = "solar:settings-bold" })

    T2:Section({ Title = "Scan Manual" })

    T2:Button({
        Title       = "Instance Sweep",
        Description = "Scan ulang semua instance + hidden remote",
        Icon        = "solar:radar-bold",
        Callback    = function()
            notify("Scanning...", "Instance sweep dimulai", 2)
            D_OK = runInstanceSweep()
            notify("Sweep Done",
                D_OK and "Remote ditemukan, cek console." or "Tidak ada temuan baru.", 4)
        end,
    })

    T2:Button({
        Title       = "Memory Forensic",
        Description = "Scan ulang _G, shared, upvalue",
        Icon        = "solar:database-bold",
        Callback    = function()
            notify("Scanning...", "Memory forensic dimulai", 2)
            C_OK = runMemForensic()
            notify("Forensic Done",
                C_OK and "Data ditemukan, cek console." or "Tidak ada temuan.", 4)
        end,
    })

    T2:Button({
        Title       = "Re-Decompile",
        Description = "Scan ulang semua client script",
        Icon        = "solar:code-bold",
        Callback    = function()
            notify("Scanning...", "Decompile dimulai", 2)
            DECOMP_RESULTS = {}
            B_OK = runDecompile()
            notify("Decompile Done",
                B_OK and "Hit ditemukan, cek console." or "Tidak ada hit.", 4)
        end,
    })

    T2:Space({ Columns = 0.3 })
    T2:Section({ Title = "Analysis" })

    T2:Button({
        Title       = "Network Map",
        Description = "Tampilkan peta komunikasi game",
        Icon        = "solar:map-bold",
        Callback    = function()
            buildNetworkMap()
            notify("Network Map", "Cek console.", 3)
        end,
    })

    T2:Button({
        Title       = "Timing Analysis",
        Description = "Analisis interval & frekuensi call",
        Icon        = "solar:clock-bold",
        Callback    = function()
            analyzeTimings()
            notify("Timing", "Cek console.", 3)
        end,
    })

    -- ── TAB 3: SAVE ──────────────────────────────────
    local T3 = Window:Tab({ Title = "Save", Icon = "solar:disk-bold" })

    T3:Section({ Title = "Dump Game" })
    T3:Paragraph({
        Title   = "Info",
        Content = "saveinstance hanya dump instance yang VISIBLE dari client.\n"
            .."Server script source TIDAK termasuk.",
    })

    T3:Button({
        Title       = "Save Instance",
        Description = "Dump game ke file .rbxlx",
        Icon        = "solar:download-bold",
        Callback    = function()
            notify("Saving...", "Proses ~20 detik, jangan keluar game.", 5)
            task.spawn(function()
                local ok = runSaveInstance()
                notify(ok and "Save Done ✓" or "Save Gagal",
                    ok and ("File: AllMap_"..tostring(game.PlaceId)..".rbxlx")
                       or "saveinstance tidak tersedia.", 5)
            end)
        end,
    })

    T3:Space({ Columns = 0.3 })
    T3:Section({ Title = "Export Log" })

    T3:Button({
        Title       = "Print Full Report",
        Description = "Cetak semua event + network map ke console",
        Icon        = "solar:document-bold",
        Callback    = function()
            printReport()
            buildNetworkMap()
            analyzeTimings()
            notify("Report", "Full report dicetak ke console.", 4)
        end,
    })

    -- ── TAB 4: LOG VIEWER ────────────────────────────
    local T4 = Window:Tab({ Title = "Log", Icon = "solar:list-bold" })

    T4:Section({ Title = "Event Log" })
    T4:Paragraph({
        Title   = "Cara Baca",
        Content = "[C->S] = kamu kirim ke server\n[S->C] = server kirim ke kamu\n"
            .."Format: RemotePath :: Method(args)",
    })

    T4:Button({
        Title       = "Show Last 10 Events",
        Description = "Print 10 event terakhir ke console",
        Icon        = "solar:eye-bold",
        Callback    = function()
            local start = math.max(1, #LOG-9)
            print("\n── Last "..math.min(10,#LOG).." Events ──")
            for i=start, #LOG do
                local e=LOG[i]
                print(string.format("[%s][%s] %s::%s(%s)",
                    e.dir, e.ts, e.path, e.method, e.argStr))
            end
            print("────────────────")
        end,
    })

    T4:Button({
        Title       = "Show C->S Only",
        Description = "Hanya tampilkan event client ke server",
        Icon        = "solar:arrow-up-bold",
        Callback    = function()
            print("\n── C->S Events ──")
            for _,e in ipairs(LOG) do
                if e.dir=="C-S" then
                    print(string.format("[%s] %s::%s(%s)",
                        e.ts, e.path, e.method, e.argStr))
                end
            end
            print("────────────────")
        end,
    })

    T4:Button({
        Title       = "Show S->C Only",
        Description = "Hanya tampilkan event server ke client",
        Icon        = "solar:arrow-down-bold",
        Callback    = function()
            print("\n── S->C Events ──")
            for _,e in ipairs(LOG) do
                if e.dir=="S-C" then
                    print(string.format("[%s] %s::%s(%s)",
                        e.ts, e.path, e.method, e.argStr))
                end
            end
            print("────────────────")
        end,
    })

    T4:Space({ Columns = 0.3 })
    T4:Section({ Title = "Copy to Clipboard" })

    -- Copy semua C->S (siap pakai untuk automation script)
    T4:Button({
        Title       = "Copy C->S (Automation)",
        Description = "Copy semua FireServer/InvokeServer siap pakai",
        Icon        = "solar:copy-bold",
        Callback    = function()
            if not setclipboard then
                notify("Error", "setclipboard tidak tersedia di executor ini.", 4)
                return
            end
            local lines = {
                "-- Universal Spy — C->S Export",
                "-- Game: "..tostring(game.Name),
                "-- PlaceId: "..tostring(game.PlaceId),
                "-- "..os.date("%Y-%m-%d"),
                "",
            }
            local unique = {}
            for _,e in ipairs(LOG) do
                if e.dir == "C-S" then
                    local key = e.path.."|"..e.argStr
                    if not unique[key] then
                        unique[key] = true
                        local fn = e.method == "FireServer"
                            and "FireServer" or "InvokeServer"
                        -- Ambil nama remote saja (bagian terakhir path)
                        local rName = e.path:match("[^.]+$") or e.path
                        lines[#lines+1] = string.format(
                            "-- [%s] %s", e.path, fn)
                        lines[#lines+1] = string.format(
                            'local remote = game:GetService("ReplicatedStorage")'
                            ..':FindFirstChild("%s", true)', rName)
                        lines[#lines+1] = string.format(
                            'if remote then remote:%s(%s) end',
                            fn, e.argStr)
                        lines[#lines+1] = ""
                    end
                end
            end
            if #lines <= 5 then
                notify("Copy", "Belum ada event C->S yang terekam.", 3)
                return
            end
            local result = table.concat(lines, "\n")
            setclipboard(result)
            notify("Copied ✓",
                string.format("%d event unik disalin ke clipboard.", #unique),
                4)
            print("[COPY] C->S automation script disalin ke clipboard.")
        end,
    })

    -- Copy raw log semua event (lengkap)
    T4:Button({
        Title       = "Copy Raw Log",
        Description = "Copy semua event mentah (C->S + S->C)",
        Icon        = "solar:copy-bold",
        Callback    = function()
            if not setclipboard then
                notify("Error", "setclipboard tidak tersedia.", 4)
                return
            end
            local lines = {
                "-- Universal Spy — Raw Log",
                "-- Game: "..tostring(game.Name),
                "-- PlaceId: "..tostring(game.PlaceId),
                "-- Total: "..#LOG.." events",
                "----------------------------------------------",
            }
            for _,e in ipairs(LOG) do
                lines[#lines+1] = string.format(
                    "[%s][%s] %s :: %s(%s)",
                    e.dir, e.ts, e.path, e.method, e.argStr)
            end
            local result = table.concat(lines, "\n")
            setclipboard(result)
            notify("Copied ✓",
                #LOG.." event disalin ke clipboard.", 4)
        end,
    })

    -- Copy S->C patterns (untuk reverse-engineer validasi server)
    T4:Button({
        Title       = "Copy S->C Patterns",
        Description = "Copy pola respons server ke clipboard",
        Icon        = "solar:copy-bold",
        Callback    = function()
            if not setclipboard then
                notify("Error", "setclipboard tidak tersedia.", 4)
                return
            end
            local lines = {
                "-- Universal Spy — Server Response Patterns",
                "-- Gunakan ini untuk reverse-engineer validasi server",
                "",
            }
            local unique = {}
            for _,e in ipairs(LOG) do
                if e.dir == "S-C" then
                    local key = e.path.."|"..e.argStr
                    if not unique[key] then
                        unique[key] = true
                        lines[#lines+1] = string.format(
                            "-- Remote: %s", e.path)
                        lines[#lines+1] = string.format(
                            "-- %s(%s)", e.method, e.argStr)
                        lines[#lines+1] = ""
                    end
                end
            end
            if #lines <= 3 then
                notify("Copy", "Belum ada event S->C.", 3)
                return
            end
            setclipboard(table.concat(lines, "\n"))
            notify("Copied ✓", "S->C patterns disalin.", 4)
        end,
    })

    -- Copy network map sebagai teks
    T4:Button({
        Title       = "Copy Network Map",
        Description = "Copy peta remote lengkap ke clipboard",
        Icon        = "solar:map-bold",
        Callback    = function()
            if not setclipboard then
                notify("Error", "setclipboard tidak tersedia.", 4)
                return
            end
            local lines = {
                "-- Universal Spy — Network Map",
                "-- Game: "..tostring(game.Name),
                "",
            }
            for path, nm in pairs(NET_MAP) do
                lines[#lines+1] = "Remote: "..path
                lines[#lines+1] = "  Calls: "..nm.callCount
                -- Top send args
                local topSend = {}
                for argStr,cnt in pairs(nm.sendArgs) do
                    topSend[#topSend+1]={argStr=argStr,cnt=cnt}
                end
                table.sort(topSend,function(a,b) return a.cnt>b.cnt end)
                for i=1,math.min(3,#topSend) do
                    lines[#lines+1] = string.format(
                        "  C->S [×%d]: %s", topSend[i].cnt, topSend[i].argStr)
                end
                -- Top recv args
                local topRecv = {}
                for argStr,cnt in pairs(nm.recvArgs) do
                    topRecv[#topRecv+1]={argStr=argStr,cnt=cnt}
                end
                table.sort(topRecv,function(a,b) return a.cnt>b.cnt end)
                for i=1,math.min(3,#topRecv) do
                    lines[#lines+1] = string.format(
                        "  S->C [×%d]: %s", topRecv[i].cnt, topRecv[i].argStr)
                end
                lines[#lines+1] = ""
            end
            setclipboard(table.concat(lines, "\n"))
            notify("Copied ✓", "Network map disalin ke clipboard.", 4)
        end,
    })

end -- end if uiOK

-- ══════════════════════════════════════════════════════
--  START OTOMATIS
-- ══════════════════════════════════════════════════════
-- Jalankan semua teknik langsung tanpa perlu toggle
startAllTechniques()

-- ══════════════════════════════════════════════════════
--  _G COMMANDS (tetap tersedia walau UI aktif)
-- ══════════════════════════════════════════════════════
_G.spyDone   = function() unhookAll(); spyActive=false; printReport() end
_G.spyReport = function() printReport() end
_G.spyClear  = function() LOG={}; logCount={}; print("[SPY] Cleared.") end
_G.spySave   = function() runSaveInstance() end
_G.spyMap    = function() buildNetworkMap() end
_G.spyTime   = function() analyzeTimings() end
_G.spyMem    = function() runMemForensic() end
_G.spySweep  = function() runInstanceSweep() end
_G.spyCopy   = function()
    if not setclipboard then
        print("[COPY] setclipboard tidak tersedia.")
        return
    end
    local lines = {
        "-- Universal Spy Export",
        "-- Game: "..tostring(game.Name),
        "-- PlaceId: "..tostring(game.PlaceId),
        "",
    }
    local unique = {}
    for _,e in ipairs(LOG) do
        if e.dir=="C-S" then
            local key = e.path.."|"..e.argStr
            if not unique[key] then
                unique[key] = true
                local rName = e.path:match("[^.]+$") or e.path
                lines[#lines+1] = string.format(
                    'local r = game:GetService("ReplicatedStorage"):FindFirstChild("%s",true)', rName)
                lines[#lines+1] = string.format(
                    'if r then r:%s(%s) end', e.method, e.argStr)
                lines[#lines+1] = ""
            end
        end
    end
    setclipboard(table.concat(lines,"\n"))
    print("[COPY] ✓ Disalin ke clipboard.")
end

print("\n[SPY] UI: "..(uiOK and "WindUI aktif ✓" or "Tidak ada UI, gunakan _G commands"))
print("Commands: spyDone | spyReport | spyClear | spySave | spyMap | spyTime | spyMem | spySweep")
