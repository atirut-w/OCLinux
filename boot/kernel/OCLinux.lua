-- OCLinux kernel by Atirut Wattanamongkol(WattanaGaming)
_G.boot_invoke = nil
_G._KERNELNAME = "OCLinux"
_G._KERNELVER = "0.3 beta"

-- These are needed to do literally anything.
local component = component or require('component')
local computer = computer or require('computer')
local unicode = unicode or require('unicode')

-- Kernel table containing built-in functions. 
kernel = {}
kernel.modules = {}
kernel.display = {
  isInitialized = false,
  resolution = {
    x = 0,
    y = 0
  },
  
  initialize = function(self)
    if (self.isInitialized) then
      return false
    end
    self.gpu = component.proxy(component.list("gpu")())
    self.resolution.x, self.resolution.y = self.gpu.getResolution()
    
    self.isInitialized = true
    return true
  end,
    
  -- A very basic and barebone system for putting texts on the screen.
  simpleBuffer = {
    lineBuffer = {},
    
    updateScreen = function(self)
      local gpu = kernel.display.gpu
      local resolution = kernel.display.resolution
      if #self.lineBuffer > resolution.y then
        table.remove(self.lineBuffer, 1)
        -- Scroll instead of redrawing the entire screen. This reduce screen flickering.
        gpu.copy(0, 1, resolution.x, resolution.y, 0, -1)
        gpu.fill(1, resolution.y, resolution.x, 1, " ")
        gpu.set(1, resolution.y, self.lineBuffer[resolution.y])
        return
      end
      gpu.set(1, #self.lineBuffer, self.lineBuffer[#self.lineBuffer])
    end,
    
    line = function(self, text)
      text = text or ""
      table.insert(self.lineBuffer, tostring(text))
      self:updateScreen()
    end
  }
}
  
kernel.threads = {
  coroutines = {},
  
  new = function(self, func, name, options)
    name = name or ""
    options = options or {}
    local id = #self.coroutines + 1

    local tData = {
      cname = name,
      -- Consider using `coroutine.wrap()`?
      co = coroutine.create(func),
    }
    tData.errHandler = options.errHandler or nil
    tData.stallProtection = options.stallProtection or false -- Temp fix for thread stall crash

    self.coroutines[id] = tData
    return id
  end,

  --[[ FIXME:
    If too many threads stall successively, a crash WILL happen when cycling threads.
    Either append `computer.pullSignal()` to the end of the loop(significant slowdown) OR
    Try to detect the "too long without yielding" result and then do `pullSignal()`
  ]]
  cycle = function(self)
    for i=1,#self.coroutines do
      local current = self.coroutines[i]
      if coroutine.status(current.co) == "dead" then
        current = nil
        return
      end

      local success, result = coroutine.resume(current.co)
      if not success and current.errHandler then
        current.errHandler(result)
      elseif not success then
        error(result)
      end
      --[[ This detection ain't working :pensive:
      if result == "too long without yielding" then
        current.errHandler("Stall detected.")
      end
      ]]
      if current.stallProtection then computer.pullSignal(0.1) end -- Temp fix for thread stall crash
    end
  end
}

kernel.essentials = {
  createSandbox = function(template, interfaces)
    template = template or _G
    local seen = {} -- DO NOT define this inside the function.
    local function copy(tbl) -- Massive thanks to Ocawesome101 for this loop!
      local ret = {}
      for k, v in pairs(tbl) do -- TODO: Make this loop function-independent.
        if type(v) == "table" and not seen[v] then
          seen[v] = true
          ret[k] = copy(v)
        else
          ret[k] = v
        end
      end
      return ret
    end
    local sandbox = copy(template)
    sandbox._G = sandbox
    if interfaces then sandbox.interfaces = interfaces end
    return sandbox
  end,
}

kernel.internal = {
  isInitialized = false,
  accessLevel = {
    kLevel = kernel,
    blank = {}
  },
  
  sandboxInterfaces = {
    display = kernel.display
  },
  
  loadfile = function(file, env)
    local addr, invoke = computer.getBootAddress(), component.invoke
    local handle = assert(invoke(addr, "open", file))
    local buffer = ""
    repeat
      local data = invoke(addr, "read", handle, math.huge)
      buffer = buffer .. (data or "")
    until not data
    invoke(addr, "close", handle)
    return load(buffer, "=" .. file, "bt", env)
  end,
  
  initialize = function(self)
    if (self.isInitialized) then -- Prevent the function from running again once initialized
      return false
    end
    self.bootAddr = computer.getBootAddress()
    
    kernel.display:initialize()
    kernel.display.simpleBuffer:line("Loading and executing /sbin/init.lua")
     -- local initSandbox = kernel.essentials.createSandbox(self.accessLevel.kLevel)
    kernel.threads:new(self.loadfile("/sbin/init.lua", _G), "init", {
      errHandler = function(err) -- Special handler.
        computer.beep(1000, 0.1)
        local print = function(a) kernel.display.simpleBuffer:line(a) end
        print("Error whilst executing init:")
        print("  "..tostring(err))
        print("")
        print("Halted.")
        while true do computer.pullSignal() end
      end
    })

    -- Stall test
    for t=1,3 do
      kernel.threads:new(function()
        for i=1,10 do
          kernel.display.simpleBuffer:line("["..t.."] ".."SPAMMER LOL(iteration "..i..")")
          coroutine.yield()
        end
        while true do i = i + 1 end -- Loop without yield.
      end, "testThread", {
        errHandler = function(err) kernel.display.simpleBuffer:line(err) end,
        stallProtection = true -- Prevent thread stall crash at the cost of performance.
      })
    end

    self.isInitialized = true
    return true
  end
}

kernel.internal:initialize()

while coroutine.status(kernel.threads.coroutines[1].co) ~= "dead" do
  kernel.threads:cycle()
end

kernel.display.simpleBuffer:line("Init has returned.")
