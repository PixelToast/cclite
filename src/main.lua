if _conf.enableAPI_http == true then require('http.HttpRequest') end
bit = require("bit")

require('render')
require('api')

-- Load virtual peripherals.
peripheral = {}
local tFiles = love.filesystem.getDirectoryItems("peripheral")
for k,v in pairs(tFiles) do
	require("peripheral." .. v:sub(1,-5))
end

keys = {
	["q"] = 16, ["w"] = 17, ["e"] = 18, ["r"] = 19,
	["t"] = 20, ["y"] = 21, ["u"] = 22, ["i"] = 23,
	["o"] = 24, ["p"] = 25, ["a"] = 30, ["s"] = 31,
	["d"] = 32, ["f"] = 33, ["g"] = 34, ["h"] = 35,
	["j"] = 36, ["k"] = 37, ["l"] = 38, ["z"] = 44,
	["x"] = 45, ["c"] = 46, ["v"] = 47, ["b"] = 48,
	["n"] = 49, ["m"] = 50,
	["1"] = 2, ["2"] = 3, ["3"] = 4, ["4"] = 5, ["5"] = 6,
	["6"] = 7, ["7"] = 8, ["8"] = 9, ["9"] = 10, ["0"] = 11,
	[" "] = 57,

	["'"] = 40, [","] = 51, ["-"] = 12, ["."] = 52, ["/"] = 53,
	[":"] = 146, [";"] = 39, ["="] = 13, ["@"] = 145, ["["] = 26,
	["\\"] = 43, ["]"] = 27, ["^"] = 144, ["_"] = 147, ["`"] = 41,

	["up"] = 200,
	["down"] = 208,
	["right"] = 205,
	["left"] = 203,
	["home"] = 199,
	["end"] = 207,
	["pageup"] = 201,
	["pagedown"] = 209,
	["insert"] = 210,
	["backspace"] = 14,
	["tab"] = 15,
	["return"] = 28,
	["delete"] = 211,

	["rshift"] = 54,
	["lshift"] = 42,
	["rctrl"] = 157,
	["lctrl"] = 29,
	["ralt"] = 184,
	["lalt"] = 56,
}

-- Patch love.keyboard.isDown to make ctrl checking easier
local olkiD = love.keyboard.isDown
function love.keyboard.isDown( ... )
	local keys = { ... }
	if #keys == 1 and keys[1] == "ctrl" then
		return olkiD("lctrl") or olkiD("rctrl")
	else
		return olkiD(unpack(keys))
	end
end

local function math_bind(val,lower,upper)
	return math.min(math.max(val,lower),upper)
end

Emulator = {
	running = false,
	reboot = false, -- Tells update loop to start Emulator automatically
	actions = { -- Keyboard commands i.e. ctrl + s and timers/alarms
		terminate = nil,
		shutdown = nil,
		reboot = nil,
		timers = {},
		alarms = {},
	},
	eventQueue = {},
	lastUpdateClock = os.clock(),
	minecraft = {
		time = 0,
		day = 0,
	},
	mouse = {
		isPressed = false,
		lastTermX = nil,
		lastTermY = nil,
	},
	lastFPS = love.timer.getTime(),
	FPS = love.timer.getFPS(),
}

function Emulator:start()
	self.reboot = false
	api.init()
	Screen:init()

	local fn, err = love.filesystem.load('lua/bios.lua') -- lua/bios.lua
	local tEnv = {}

	if not fn then
		print(err)
		return
	end

	setfenv( fn, api.env )

	self.proc = coroutine.create(fn)
	self.running = true
	self:resume({})
end

function Emulator:stop( reboot )
	self.proc = nil
	self.running = false
	self.reboot = reboot
	Screen.dirty = true

	-- Reset events/key shortcuts
	self.actions.terminate = nil
	self.actions.shutdown = nil
	self.actions.reboot = nil
	self.actions.timers = {}
	self.actions.alarms = {}
	self.eventQueue = {}
end

function Emulator:resume( ... )
	if not self.running then return end
	debug.sethook(self.proc,function() error("Too long without yielding",2) end,"",1e9)
	local ok, err = coroutine.resume(self.proc, ...)
	debug.sethook(self.proc)
	if not self.proc then return end -- Emulator:stop could be called within the coroutine resulting in proc being nil
	if coroutine.status(self.proc) == "dead" then -- Which could cause an error here
		Emulator:stop()
	end
	if not ok then
    	error(err,math.huge) -- Bios was unable to handle error, crash CCLite
    end
    return ok, err
end

function love.load()
	jit.off() -- Required for "Too long without yielding"
	if _conf.lockfps > 0 then 
		min_dt = 1/_conf.lockfps
		next_time = love.timer.getTime()
	end

	love.filesystem.setIdentity("ccemu")
	
	local glyphs = ""
	for i = 32,126 do
		glyphs = glyphs .. string.char(i)
	end
	font = love.graphics.newImageFont("res/minecraft.png",glyphs)
	font:setFilter("nearest","nearest")
	love.graphics.setFont(font)

	local fontPack = {131,161,163,166,170,171,172,174,186,187,188,189,191,196,197,198,199,201,209,214,215,216,220,224,225,226,228,229,230,231,232,233,234,235,236,237,238,239,241,242,243,244,246,248,249,250,251,252,255}
	ChatAllowedCharacters = {}
	for i = 32,126 do
		ChatAllowedCharacters[i] = true
	end
	for i = 1,#fontPack do
		ChatAllowedCharacters[fontPack[i]] = true
	end
	ChatAllowedCharacters[96] = nil

	if not love.filesystem.exists("data/") then
		love.filesystem.createDirectory("data/") -- Make the user data folder
	end

	love.keyboard.setKeyRepeat( true )

	Emulator:start()
end

function love.mousereleased( x, y, _button )

	if x > 0 and x < Screen.sWidth
		and y > 0 and y < Screen.sHeight then -- Within screen bounds.

		Emulator.mouse.isPressed = false
	end
end

function  love.mousepressed( x, y, _button )

	if x > 0 and x < Screen.sWidth
		and y > 0 and y < Screen.sHeight then -- Within screen bounds.

		local termMouseX = math_bind(math.floor( (x - _conf.terminal_guiScale) / Screen.pixelWidth ) + 1,1,_conf.terminal_width)
    	local termMouseY = math_bind(math.floor( (y - _conf.terminal_guiScale) / Screen.pixelHeight ) + 1,1,_conf.terminal_height)

		if not Emulator.mousePressed and _button == "r" or _button == "l" then
			Emulator.mouse.isPressed = true
			Emulator.mouse.lastTermX = termMouseX
			Emulator.mouse.lastTermY = termMouseY
			table.insert(Emulator.eventQueue, {"mouse_click", _button == "r" and 2 or 1, termMouseX, termMouseY})

		elseif _button == "wu" then -- Scroll up
			table.insert(Emulator.eventQueue, {"mouse_scroll", -1, termMouseX, termMouseX})

		elseif _button == "wd" then -- Scroll down
			table.insert(Emulator.eventQueue, {"mouse_scroll", 1, termMouseX, termMouseY})

		end
	end
end

function love.textinput(unicode)
	local byte = string.byte(unicode)
   	if ChatAllowedCharacters[byte] == true then
    	table.insert(Emulator.eventQueue, {"char", unicode})
    end
end

function love.keypressed(key, isrepeat)
	if Emulator.actions.terminate == nil    and love.keyboard.isDown("ctrl") and not isrepeat and key == "t" then
		Emulator.actions.terminate = love.timer.getTime()
	elseif Emulator.actions.shutdown == nil and love.keyboard.isDown("ctrl") and not isrepeat and key == "s" then
		Emulator.actions.shutdown =  love.timer.getTime()
	elseif Emulator.actions.reboot == nil   and love.keyboard.isDown("ctrl") and not isrepeat and key == "r" then
		Emulator.actions.reboot =    love.timer.getTime()
	else -- Ignore key shortcuts before "press any key" action. TODO: This might be slightly buggy!
		if not Emulator.running and not isrepeat then
			Emulator:start()
			return
		end
	end

	if love.keyboard.isDown("ctrl") and key == "v" then
		local cliptext = love.system.getClipboardText()
		cliptext = cliptext:gsub("\r\n","\n")
		local nloc = cliptext:find("\n") or -1
		if nloc > 0 then
			cliptext = cliptext:sub(1, nloc - (_conf.compat_faultyClip == true and 2 or 1))
		end
		cliptext = cliptext:sub(1,128)
		for i = 1,#cliptext do
			love.textinput(cliptext:sub(i,i))
		end
	elseif isrepeat and love.keyboard.isDown("ctrl") and (key == "t" or key == "s" or key == "r") then
	elseif keys[key] then
   		table.insert(Emulator.eventQueue, {"key", keys[key]})
   	end
end

function love.visible(see)
	if see then
		Screen.dirty = true
	end
end

--[[
	Not implementing:
	modem_message
	monitor_touch
	monitor_resize
]]

function updateShortcut(name, key1, key2, cb)
	if Emulator.actions[name] ~= nil then
		if love.keyboard.isDown(key1) and love.keyboard.isDown(key2) then
			if love.timer.getTime() - Emulator.actions[name] > 1 then
				Emulator.actions[name] = nil
				if cb then cb() end
			end
		else
			Emulator.actions[name] = nil
		end
	end
end

function love.update(dt)
	if _conf.lockfps > 0 then next_time = next_time + min_dt end
	local now = love.timer.getTime()
	if _conf.enableAPI_http == true then HttpRequest.checkRequests() end
	if Emulator.reboot then Emulator:start() end

	updateShortcut("terminate", "ctrl", "t", function()
			table.insert(Emulator.eventQueue, {"terminate"})
		end)
	updateShortcut("shutdown",  "ctrl", "s", function()
			Emulator:stop()
		end)
	updateShortcut("reboot",    "ctrl", "r", function()
			Emulator:stop( true )
		end)

	if api.comp.blink then
		if Screen.lastCursor == nil then
			Screen.lastCursor = now
		end
		if now - Screen.lastCursor >= 0.25 then
			Screen.showCursor = not Screen.showCursor
			Screen.lastCursor = now
			Screen.dirty = true
		end
	end
	if _conf.cclite_showFPS then
		if now - Emulator.lastFPS >= 1 then
			Emulator.FPS = love.timer.getFPS()
			Emulator.lastFPS = now
			Screen.dirty = true
		end
	end
	
	if #Emulator.actions.timers > 0 then
		for k, v in pairs(Emulator.actions.timers) do
			if now >= v.expires then
				table.insert(Emulator.eventQueue, {"timer", k})
				Emulator.actions.timers[k] = nil
			end
		end
	end

	if #Emulator.actions.alarms > 0 then
		local currentTime = api.env.os.time()

		for k, v in pairs(Emulator.actions.alarms) do
        	if currentTime >= v.time then
            	table.insert(Emulator.eventQueue, {"alarm", k})
           		Emulator.actions.alarms[k] = nil
        	end
    	end
	end

	--MOUSE
	if Emulator.mouse.isPressed then
    	local mouseX     = love.mouse.getX()
    	local mouseY     = love.mouse.getY()
    	local termMouseX = math_bind(math.floor( (mouseX - _conf.terminal_guiScale) / Screen.pixelWidth ) + 1,1,_conf.terminal_width)
    	local termMouseY = math_bind(math.floor( (mouseY - _conf.terminal_guiScale) / Screen.pixelHeight ) + 1,1,_conf.terminal_width)
    	if (termMouseX ~= Emulator.mouse.lastTermX or termMouseY ~= Emulator.mouse.lastTermY)
			and (mouseX > 0 and mouseX < Screen.sWidth and
				mouseY > 0 and mouseY < Screen.sHeight) then

        	Emulator.mouse.lastTermX = termMouseX
       		Emulator.mouse.lastTermY = termMouseY

        	table.insert (Emulator.eventQueue, { "mouse_drag", love.mouse.isDown( "r" ) and 2 or 1, termMouseX, termMouseY})
    	end
    end

    local currentClock = os.clock()

    if #Emulator.eventQueue > 0 then
		for k, v in pairs(Emulator.eventQueue) do
			Emulator:resume(unpack(v))
		end
		Emulator.eventQueue = {}
	end
end

local lastFPS,fps = love.timer.getTime(),love.timer.getFPS()
function love.draw()
	if Screen.dirty then
		Screen:draw()
		if _conf.cclite_showFPS then
			love.graphics.setColor({0,0,0})
			love.graphics.print("FPS: " .. tostring(Emulator.FPS), (Screen.sWidth) - (Screen.pixelWidth * 8), 11, 0, _conf.terminal_guiScale, _conf.terminal_guiScale)
			love.graphics.setColor({255,255,255})
			love.graphics.print("FPS: " .. tostring(Emulator.FPS), (Screen.sWidth) - (Screen.pixelWidth * 8) - 1, 10, 0, _conf.terminal_guiScale, _conf.terminal_guiScale)
		end
	end
	if _conf.lockfps > 0 then 
		local cur_time = love.timer.getTime()
		if next_time <= cur_time then
			next_time = cur_time
			return
		end
		love.timer.sleep(next_time - cur_time)
	end
end

-- Use a more assumptive and non automatic screen clearing version of love.run
function love.run()

    math.randomseed(os.time())
    math.random() math.random()

    love.load(arg)

    local dt = 0

    -- Main loop time.
    while true do
        -- Process events.
        if love.event then
            love.event.pump()
            for e,a,b,c,d in love.event.poll() do
                if e == "quit" then
                    if not love.quit or not love.quit() then
                        if love.audio then
                            love.audio.stop()
                        end
                        return
                    end
                end
                love.handlers[e](a,b,c,d)
            end
        end

        -- Update dt, as we'll be passing it to update
        love.timer.step()
        dt = love.timer.getDelta()

        -- Call update and draw
        love.update(dt) -- will pass 0 if love.timer is disabled
		if not love.window.isVisible() then Screen.dirty = false end
        love.draw()

        if love.timer then love.timer.sleep(0.001) end
		if Screen.dirty then love.graphics.present() end
		Screen.dirty = false
    end

end
