local api, fn = vim.api, vim.fn
local window = require('lspsaga.window')
local libs = require('lspsaga.libs')
local diag = require('lspsaga.diagnostic')
local config = require('lspsaga').config
local ui = config.ui
local diag_conf = config.diagnostic
local nvim_buf_set_keymap = api.nvim_buf_set_keymap
local ns = api.nvim_create_namespace('SagaDiagnostic')
local nvim_buf_set_extmark = api.nvim_buf_set_extmark
local nvim_buf_add_highlight = api.nvim_buf_add_highlight
local ctx = {}
local sd = {}
sd.__index = sd

function sd.__newindex(t, k, v)
  rawset(t, k, v)
end

--- clean ctx
local function clean_ctx()
  for i, _ in pairs(ctx) do
    ctx[i] = nil
  end
end

---get the line or cursor diagnostics
---@param opt table
function sd:get_diagnostic(opt)
  local cur_buf = api.nvim_get_current_buf()
  if opt.buffer then
    return vim.diagnostic.get(cur_buf)
  end

  local line, col = unpack(api.nvim_win_get_cursor(0))
  local entrys = vim.diagnostic.get(cur_buf, { lnum = line - 1 })

  if opt.line then
    return entrys
  end

  if opt.cursor then
    local res = {}
    for _, v in pairs(entrys) do
      if v.col <= col and v.end_col >= col then
        res[#res + 1] = v
      end
    end
    return res
  end

  return vim.diagnostic.get()
end

---@private sort table by diagnsotic severity
local function sort_by_severity(entrys)
  table.sort(entrys, function(k1, k2)
    return k1.severity < k2.severity
  end)
end

function sd:create_win(opt, content)
  local curbuf = api.nvim_get_current_buf()
  local increase = window.win_height_increase(content)
  local max_len = window.get_max_content_length(content)
  local max_height = math.floor(vim.o.lines * diag_conf.max_show_height)
  local max_width = math.floor(vim.o.columns * diag_conf.max_show_width)
  local float_opt = {
    width = max_len < max_width and max_len or max_width,
    height = #content > max_height and max_height or #content,
    no_size_override = true,
  }

  if fn.has('nvim-0.9') == 1 and config.ui.title then
    if opt.buffer then
      float_opt.title = 'Buffer'
    elseif opt.line then
      float_opt.title = 'Line'
    elseif opt.cursor then
      float_opt.title = 'Cursor'
    else
      float_opt.title = 'Workspace'
    end
    float_opt.title_pos = 'center'
  end

  local content_opt = {
    contents = {},
    filetype = 'markdown',
    enter = true,
    bufnr = self.bufnr,
    wrap = true,
    highlight = {
      normal = 'DiagnosticShowNormal',
      border = 'DiagnosticShowBorder',
    },
  }

  local close_autocmds =
    { 'CursorMoved', 'CursorMovedI', 'InsertEnter', 'BufDelete', 'WinScrolled' }
  if opt.arg and opt.arg == '++unfocus' then
    opt.focusable = false
    close_autocmds[#close_autocmds] = 'BufLeave'
    content_opt.enter = false
  else
    opt.focusable = true
    api.nvim_create_autocmd('BufEnter', {
      callback = function(args)
        if not self.winid or not api.nvim_win_is_valid(self.winid) then
          pcall(api.nvim_del_autocmd, args.id)
        end
        local cur_buf = api.nvim_get_current_buf()
        if cur_buf ~= self.bufnr and self.winid and api.nvim_win_is_valid(self.winid) then
          api.nvim_win_close(self.winid, true)
          clean_ctx()
          pcall(api.nvim_del_autocmd, args.id)
        end
      end,
    })
  end

  _, self.winid = window.create_win_with_border(content_opt, float_opt)
  vim.wo[self.winid].conceallevel = 2
  vim.wo[self.winid].concealcursor = 'niv'
  vim.wo[self.winid].showbreak = ui.lines[3]
  vim.wo[self.winid].breakindent = true
  vim.wo[self.winid].breakindentopt = 'shift:2,sbr'
  vim.wo[self.winid].linebreak = true

  api.nvim_win_set_cursor(self.winid, { 1, 1 })
  for _, key in ipairs(diag_conf.keys.quit_in_show) do
    nvim_buf_set_keymap(self.bufnr, 'n', key, '', {
      noremap = true,
      nowait = true,
      callback = function()
        local curwin = api.nvim_get_current_win()
        if curwin ~= self.winid then
          return
        end
        if api.nvim_win_is_valid(curwin) then
          api.nvim_win_close(curwin, true)
          clean_ctx()
        end
      end,
    })
  end

  vim.defer_fn(function()
    libs.close_preview_autocmd(curbuf, self.winid, close_autocmds)
  end, 0)
end

local function find_node_by_lnum(lnum, entrys)
  for _, items in pairs(entrys) do
    for _, item in ipairs(items.diags) do
      if item.winline == lnum then
        return item
      end
    end
  end
end

local function change_winline(cond, direction, entrys)
  for _, items in pairs(entrys) do
    for _, item in ipairs(items.diags) do
      if cond(item) then
        item.winline = item.winline + direction
      end
    end
  end
end

function sd:show(opt)
  local indent = '   '
  local line_count = 0
  local content = {}
  local curbuf = api.nvim_get_current_buf()
  -- local icon_data = libs.icon_from_devicon(vim.bo[curbuf].filetype)
  self.bufnr = api.nvim_create_buf(false, false)
  vim.bo[self.bufnr].buftype = 'nofile'

  local titlehi = {}
  for bufnr, items in pairs(opt.entrys) do
    items.expand = true
    for i, item in ipairs(items.diags) do
      if item.message:find('\n') then
        item.message = item.message:gsub('\n', ' '):gsub('%s+', ' '):gsub(' $', '')
      end
      sign = ui.signs[item.severity] or ui.signs[4]
      orig_text = sign .. " " .. item.message
      text = orig_text
      if item.code then
        text = text .. " " .. item.code
      end
      if item.source then
        text = text .. " (" .. item.source .. ")"
      end
      api.nvim_buf_set_lines(self.bufnr, line_count, line_count + 1, false, { text })
      line_count = line_count + 1
      nvim_buf_add_highlight(
        self.bufnr,
        0,
        diag_conf.text_hl_follow and 'Diagnostic' .. diag:get_diag_type(item.severity)
          or 'DiagnosticText',
        line_count - 1,
        0,
        #orig_text
      )
      nvim_buf_add_highlight(
        self.bufnr,
        0,
        'Comment',
        line_count - 1,
        #orig_text,
        -1
      )
      item.winline = line_count
      content[#content + 1] = text
    end
    -- api.nvim_buf_set_lines(self.bufnr, line_count, line_count + 1, false, { '' })
    -- line_count = line_count + 1
  end

  vim.bo[self.bufnr].modifiable = false

  local nontext = api.nvim_get_hl_by_name('NonText', true)
  api.nvim_set_hl(ns, 'NonText', {
    link = 'FinderLines',
  })

  nvim_buf_set_keymap(self.bufnr, 'n', diag_conf.keys.expand_or_jump, '', {
    nowait = true,
    silent = true,
    callback = function()
      local text = api.nvim_get_current_line()
      if text:find(ui.expand) or text:find(ui.collapse) then
        expand_or_collapse(text)
        return
      end
      local winline = api.nvim_win_get_cursor(self.winid)[1]
      api.nvim_set_hl(0, 'NonText', {
        foreground = nontext.foreground,
        background = nontext.background,
      })

      local entry = find_node_by_lnum(winline, opt.entrys)

      if entry then
        api.nvim_win_close(self.winid, true)
        clean_ctx()
        local winid = fn.bufwinid(entry.bufnr)
        if winid == -1 then
          winid = api.nvim_get_current_win()
        end
        api.nvim_set_current_win(winid)
        api.nvim_win_set_cursor(winid, { entry.lnum + 1, entry.col })
        local width = #api.nvim_get_current_line()
        libs.jump_beacon({ entry.lnum, entry.col }, width)
      end
    end,
  })

  self:create_win(opt, content)
end

---migreate diagnostic to a table that
---use in show function
local function migrate_diagnostics(entrys)
  local tbl = {}
  for _, item in ipairs(entrys) do
    local key = tostring(item.bufnr)
    if not tbl[key] then
      tbl[key] = {
        diags = {},
      }
    end
    tbl[key].diags[#tbl[key].diags + 1] = item
  end
  return tbl
end

function sd:show_diagnostics(opt)
  local entrys = self:get_diagnostic(opt)
  if next(entrys) == nil then
    return
  end
  sort_by_severity(entrys)
  opt.entrys = migrate_diagnostics(entrys)
  self:show(opt)
end

return setmetatable(ctx, sd)
