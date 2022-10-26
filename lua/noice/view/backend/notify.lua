local require = require("noice.util.lazy")

local Util = require("noice.util")
local View = require("noice.view")
local Manager = require("noice.message.manager")

---@class NoiceNotifyOptions
---@field title string
---@field level? string|number Message log level
---@field merge boolean Merge messages into one Notification or create separate notifications
---@field replace boolean Replace existing notification or create a new one
local defaults = {
  title = "Notification",
  merge = false,
  level = nil, -- vim.log.levels.INFO,
  replace = false,
}

---@class NotifyInstance
---@field notify fun(msg:string?, level?:string|number, opts?:table): notify.Record}

---@alias notify.RenderFun fun(buf:buffer, notif: Notification, hl: NotifyBufHighlights, config: notify.Config)

---@class NotifyView: NoiceView
---@field win? number
---@field buf? number
---@field notif table<NotifyInstance, notify.Record>
---@field super NoiceView
---@diagnostic disable-next-line: undefined-field
local NotifyView = View:extend("NotifyView")

---@return NotifyInstance
function NotifyView.instance()
  if Util.is_blocking() then
    if not NotifyView._instant_notify then
      NotifyView._instant_notify = require("notify").instance({
        stages = "static",
      }, true)
    end
    return NotifyView._instant_notify
  end
  return require("notify")
end

function NotifyView.dismiss()
  require("notify").dismiss({ pending = true, silent = true })
  if NotifyView._instant_notify then
    NotifyView._instant_notify.dismiss({ pending = true, silent = true })
  end
end

function NotifyView:init(opts)
  NotifyView.super.init(self, opts)
  self.notif = {}
end

function NotifyView:is_available()
  return pcall(_G.require, "notify") == true
end

function NotifyView:update_options()
  self._opts = vim.tbl_deep_extend("force", defaults, self._opts)
end

function NotifyView:plain()
  return function(bufnr, notif)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, notif.message)
  end
end

---@param config notify.Config
---@param render? notify.RenderFun
---@return notify.RenderFun
function NotifyView:get_render(config, render)
  ---@type string|notify.RenderFun
  local ret = render or config.render()
  if type(ret) == "string" then
    if ret == "plain" then
      ret = self:plain()
    else
      ---@type notify.RenderFun
      ret = require("notify.render")[ret]
    end
  end
  return ret
end

---@param messages NoiceMessage[]
---@param render? notify.RenderFun
function NotifyView:notify_render(messages, render)
  ---@param config notify.Config
  return function(buf, notif, hl, config)
    -- run notify view
    self:get_render(config, render)(buf, notif, hl, config)

    Util.tag(buf, "notify")

    ---@type string[]
    local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local offset = #buf_lines - self:height(messages) + 1

    -- do our rendering
    self:render(buf, { offset = offset, highlight = true, messages = messages })

    -- resize notification
    local win = vim.fn.bufwinid(buf)
    if win ~= -1 then
      ---@type number
      local width = config.minimum_width()
      for _, line in pairs(buf_lines) do
        width = math.max(width, vim.str_utfindex(line))
      end
      width = math.min(config.max_width() or 1000, width)
      local height = math.min(config.max_height() or 1000, #buf_lines)
      Util.win_apply_config(win, { width = width, height = height })
    end
  end
end

---@alias NotifyMsg {content:string, messages:NoiceMessage[], title?:string, level?:string, opts?: table}

---@param msg NotifyMsg
function NotifyView:_notify(msg)
  local level = self._opts.level or msg.level

  local instance = NotifyView.instance()

  local opts = {
    title = msg.title or self._opts.title,
    replace = self._opts.replace and self.notif[instance],
    keep = function()
      return Util.is_blocking()
    end,
    on_open = function(win)
      self:set_win_options(win)
      if self._opts.merge then
        self.win = win
      end
    end,
    on_close = function()
      self.notif[instance] = nil
      for _, m in ipairs(msg.messages) do
        m.opts.notify_id = nil
      end
      self.win = nil
    end,
    render = Util.protect(self:notify_render(msg.messages, self._opts.render)),
  }

  if msg.opts then
    opts = vim.tbl_deep_extend("force", opts, msg.opts)
    if type(msg.opts.replace) == "table" then
      local m = Manager.get_by_id(msg.opts.replace.id)
      opts.replace = m and m.opts.notify_id or nil
    end
  end

  ---@type string?
  local content = msg.content

  if msg.opts and msg.opts.is_nil then
    content = nil
  end

  local id = instance.notify(content, level, opts)
  self.notif[instance] = id
  for _, m in ipairs(msg.messages) do
    m.opts.notify_id = id
  end
end

function NotifyView:show()
  ---@type NotifyMsg[]
  local todo = {}

  if self._opts.merge then
    table.insert(todo, {
      content = self:content(),
      messages = self._messages,
    })
  else
    for _, m in ipairs(self._messages) do
      table.insert(todo, {
        content = m:content(),
        messages = { m },
        title = m.opts.title,
        level = m.level,
        opts = m.opts,
      })
    end
  end

  for _, msg in ipairs(todo) do
    self:_notify(msg)
  end
end

function NotifyView:hide()
  if self.win and vim.api.nvim_win_is_valid(self.win) then
    vim.api.nvim_win_close(self.win, true)
    self.win = nil
  end
end

return NotifyView
