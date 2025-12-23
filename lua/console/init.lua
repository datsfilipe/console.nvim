local M = {}

local api = vim.api
local split = vim.split
local tbl_insert = table.insert

local config = {
  command_name = 'ConsoleRun',
  grep_command_name = 'LiveGrep',
  hijack_bang = true,
  close_key = ';q',
  window = {
    height_ratio = 0.45,
    min_height = 6,
  },
}

local state = {
  buf = nil,
  win = nil,
  input_buf = nil,
  input_win = nil,
  origin_win = nil,
  job = nil,
  queue = {},
  remainder = '',
  keep_alive = false,
  timer = nil,
  last_command = nil,
  ns_id = api.nvim_create_namespace 'ConsoleHighlights',
}

local augroup = api.nvim_create_augroup('ConsoleRun', { clear = true })

local function strip_ansi(text)
  return text:gsub('\27%[[0-9;?]*[a-zA-Z]', '')
end

local function apply_static_syntax()
  vim.cmd 'syntax clear'

  vim.cmd [[syntax match ConsolePrompt /^\$ .*/]]
  vim.cmd [[syntax match ConsoleExit /^\[exit \d\+\]/]]
  vim.cmd [[highlight default link ConsolePrompt Statement]]
  vim.cmd [[highlight default link ConsoleExit Comment]]

  vim.cmd [[syntax match ConsoleLine /:\d\+:\d\+:/]]
  vim.cmd [[syntax match ConsoleLine /:\d\+:/]]
  vim.cmd [[highlight default link ConsoleLine Constant]]
end

local function highlight_query(query)
  ---@diagnostic disable-next-line: param-type-mismatch
  pcall(vim.cmd, 'syntax clear ConsoleMatch')
  if not query or query == '' then
    return
  end

  local clean_query = vim.fn.escape(query, '\\/.*$^~[]')
  local regex = '\\c' .. clean_query
  vim.cmd(string.format('syntax match ConsoleMatch /%s/', regex))
  vim.cmd 'highlight default link ConsoleMatch Search'
end

local function resolve_valid_path(text)
  if text == '.' or text == '..' then
    return nil
  end

  if #text < 2 then
    return nil
  end

  if vim.loop.fs_stat(text) then
    return text
  end

  local found_file = vim.fn.findfile(text)
  if found_file and found_file ~= '' then
    return found_file
  end

  local found_dir = vim.fn.finddir(text)
  if found_dir and found_dir ~= '' then
    return found_dir
  end

  return nil
end

local function apply_highlights(start_line, end_line)
  if not (state.buf and api.nvim_buf_is_valid(state.buf)) then
    return
  end

  api.nvim_buf_call(state.buf, function()
    local lines = api.nvim_buf_get_lines(state.buf, start_line, end_line, false)

    for i, line in ipairs(lines) do
      local line_idx = start_line + i - 1

      local s, _, grep_file = line:find '^([^: ]+):%d+:'
      if s and grep_file then
        if resolve_valid_path(grep_file) then
          api.nvim_buf_add_highlight(
            state.buf,
            state.ns_id,
            'Directory',
            line_idx,
            s - 1,
            #grep_file
          )

          goto continue
        end
      end

      local init = 1
      while true do
        local ws, we = line:find('%S+', init)
        if not ws then
          break
        end

        local word = line:sub(ws, we)
        local clean_word = word:gsub('[\'",:;]$', '')
        local clean_len = #clean_word

        if clean_len > 0 then
          if resolve_valid_path(clean_word) then
            api.nvim_buf_add_highlight(
              state.buf,
              state.ns_id,
              'Directory',
              line_idx,
              ws - 1,
              ws - 1 + clean_len
            )
          end
        end

        init = we + 1
      end

      ::continue::
    end
  end)
end

local function open_file(file, row, col)
  M.close()

  local target_win = state.origin_win
  if not (target_win and api.nvim_win_is_valid(target_win)) then
    target_win = api.nvim_get_current_win()
  end

  api.nvim_set_current_win(target_win)

  local safe_file = vim.fn.fnameescape(file)
  local ok = pcall(vim.cmd, 'edit ' .. safe_file)

  if ok and row then
    local r, c = tonumber(row), tonumber(col or 0)
    if c > 0 then
      c = c - 1
    end
    pcall(api.nvim_win_set_cursor, 0, { r, c })
    vim.cmd 'normal! zz'
  end
end

local function jump_to_result()
  local line = api.nvim_get_current_line()

  local file, row, col = line:match '^([^: ]+):(%d+):(%d+):'
  if not file then
    file, row = line:match '^([^: ]+):(%d+):'
  end

  if file then
    local path = resolve_valid_path(file)
    if path then
      open_file(path, row, col)
      return
    end
  end

  local cfile = vim.fn.expand '<cfile>'
  if cfile and cfile ~= '' then
    local path = resolve_valid_path(cfile)
    if path then
      open_file(path)
      return
    end
  end

  for word in line:gmatch '%S+' do
    local clean = word:gsub('[\'",:;]$', '')
    local path = resolve_valid_path(clean)
    if path then
      open_file(path)
      return
    end
  end
end

local function inject_command_context()
  if not state.last_command then
    return
  end
  for part in state.last_command:gmatch '%S+' do
    if part:match '/' or part == '..' then
      local clean_path = part:gsub('^[\'"]', ''):gsub('[\'"]$', '')
      if vim.loop.fs_stat(clean_path) then
        vim.opt_local.path:append(clean_path)
      end
    end
  end
  vim.opt_local.path:append '..'
  vim.opt_local.path:append '**'
end

local function reset_buffer()
  if not (state.buf and api.nvim_buf_is_valid(state.buf)) then
    state.buf = api.nvim_create_buf(false, true)
  end

  local bo = vim.bo[state.buf]
  bo.modifiable = true
  bo.buftype = 'nofile'
  bo.swapfile = false
  bo.bufhidden = 'hide'
  bo.filetype = 'console'

  api.nvim_buf_set_lines(state.buf, 0, -1, false, {})
  api.nvim_buf_clear_namespace(state.buf, state.ns_id, 0, -1)
  bo.modifiable = false

  api.nvim_buf_call(state.buf, function()
    apply_static_syntax()
    inject_command_context()
  end)

  vim.keymap.set(
    'n',
    '<CR>',
    jump_to_result,
    { buffer = state.buf, silent = true }
  )
end

local function ensure_window()
  local cur = api.nvim_get_current_win()
  if cur ~= state.win and cur ~= state.input_win then
    state.origin_win = cur
  end

  reset_buffer()

  local total_lines = vim.o.lines
  local height = math.max(
    config.window.min_height,
    math.floor(total_lines * config.window.height_ratio)
  )

  if state.win and api.nvim_win_is_valid(state.win) then
    api.nvim_win_set_buf(state.win, state.buf)
    pcall(api.nvim_win_set_height, state.win, height)
    return
  end

  vim.cmd(string.format('botright %dsplit', height))
  state.win = api.nvim_get_current_win()
  api.nvim_win_set_buf(state.win, state.buf)

  local wo = vim.wo[state.win]
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = 'no'
  wo.wrap = false
  wo.cursorline = true
  wo.winfixheight = true
  wo.statusline = ' '
  wo.fillchars = 'eob: '

  vim.keymap.set(
    'n',
    'q',
    M.close,
    { buffer = state.buf, silent = true, nowait = true }
  )
  if config.close_key then
    vim.keymap.set(
      'n',
      config.close_key,
      M.close,
      { buffer = state.buf, silent = true, nowait = true }
    )
  end
end

local function flush_queue()
  local queue_len = #state.queue
  if queue_len == 0 then
    return
  end

  if not (state.buf and api.nvim_buf_is_valid(state.buf)) then
    state.queue = {}
    state.remainder = ''
    return
  end

  local bo = vim.bo[state.buf]
  bo.modifiable = true

  local start_line = api.nvim_buf_line_count(state.buf)

  api.nvim_buf_set_lines(state.buf, -1, -1, false, state.queue)

  local end_line = api.nvim_buf_line_count(state.buf)

  apply_highlights(start_line, end_line)

  if end_line > 10000 then
    api.nvim_buf_set_lines(state.buf, 0, end_line - 9000, false, {})
  end

  bo.modifiable = false

  if state.win and api.nvim_win_is_valid(state.win) then
    local new_count = api.nvim_buf_line_count(state.buf)
    api.nvim_win_set_cursor(state.win, { new_count, 0 })
    vim.cmd 'redraw'
  end

  state.queue = {}
end

local function schedule_flush()
  vim.schedule(flush_queue)
end

local function append_stream(data)
  if not data or data == '' then
    return
  end
  data = data:gsub('\r', '')
  data = strip_ansi(data)

  local text = state.remainder .. data
  if not text:find('\n', 1, true) then
    state.remainder = text
    return
  end

  local lines = split(text, '\n', { plain = true })
  state.remainder = lines[#lines]
  lines[#lines] = nil

  for _, line in ipairs(lines) do
    tbl_insert(state.queue, line)
  end
  schedule_flush()
end

local function stop_job()
  if state.job then
    pcall(vim.fn.jobstop, state.job)
    state.job = nil
  end
end

function M.close()
  stop_job()
  api.nvim_clear_autocmds { group = augroup }
  state.keep_alive = false

  if state.win and api.nvim_win_is_valid(state.win) then
    api.nvim_win_close(state.win, true)
    state.win = nil
  end

  if state.input_win and api.nvim_win_is_valid(state.input_win) then
    api.nvim_win_close(state.input_win, true)
    state.input_win = nil
  end
end

local function send_input(input)
  if state.job then
    vim.fn.chansend(state.job, input .. '\r')
  else
    vim.notify('No active job', vim.log.levels.WARN)
  end
end

local function append_direct(lines)
  for _, line in ipairs(lines) do
    tbl_insert(state.queue, line)
  end
  schedule_flush()
end

function M.run(cmdline)
  if not cmdline or cmdline == '' then
    return
  end

  state.last_command = cmdline
  ensure_window()
  stop_job()
  api.nvim_clear_autocmds { group = augroup }
  state.queue = {}
  state.remainder = ''

  append_direct { '$ ' .. cmdline }

  state.job = vim.fn.jobstart(cmdline, {
    pty = true,
    on_stdout = function(_, data)
      if data then
        append_stream(table.concat(data, '\n'))
      end
    end,
    on_stderr = function(_, data)
      if data then
        append_stream(table.concat(data, '\n'))
      end
    end,
    on_exit = function(_, code)
      state.job = nil
      state.keep_alive = false
      if state.remainder ~= '' then
        tbl_insert(state.queue, state.remainder)
        state.remainder = ''
      end
      tbl_insert(state.queue, string.format('[exit %d]', code or -1))
      schedule_flush()
    end,
  })

  if state.job <= 0 then
    append_direct { '[job failed to start]' }
    state.job = nil
  end

  api.nvim_create_autocmd('CmdlineLeave', {
    group = augroup,
    callback = function()
      vim.schedule(function()
        if state.job and not state.keep_alive then
          M.close()
        end
      end)
    end,
  })
end

local function spawn_grep(query)
  stop_job()
  state.last_command = nil

  if state.buf and api.nvim_buf_is_valid(state.buf) then
    local bo = vim.bo[state.buf]
    bo.modifiable = true
    api.nvim_buf_set_lines(state.buf, 0, -1, false, {})
    api.nvim_buf_clear_namespace(state.buf, state.ns_id, 0, -1)
    bo.modifiable = false

    api.nvim_buf_call(state.buf, function()
      highlight_query(query)
    end)
  end

  state.queue = {}
  state.remainder = ''
  if query == '' then
    return
  end

  local cmd = string.format(
    'rg --vimgrep --smart-case --color=never "%s" .',
    query:gsub('"', '\\"')
  )

  state.job = vim.fn.jobstart(cmd, {
    pty = false,
    stdout_buffered = false,
    on_stdout = function(_, data)
      if data then
        append_stream(table.concat(data, '\n'))
      end
    end,
    on_stderr = function(_, data)
      if data then
        append_stream(table.concat(data, '\n'))
      end
    end,
  })
end

function M.live_grep()
  ensure_window()

  state.input_buf = api.nvim_create_buf(false, true)
  vim.bo[state.input_buf].buftype = 'nofile'
  vim.bo[state.input_buf].bufhidden = 'wipe'

  vim.cmd 'botright 1split'
  state.input_win = api.nvim_get_current_win()
  api.nvim_win_set_buf(state.input_win, state.input_buf)

  vim.wo[state.input_win].winfixheight = true
  vim.wo[state.input_win].number = false
  vim.wo[state.input_win].signcolumn = 'no'

  api.nvim_create_autocmd('TextChangedI', {
    buffer = state.input_buf,
    callback = function()
      if state.timer then
        state.timer:stop()
      end
      state.timer = vim.loop.new_timer()

      state.timer:start(
        150,
        0,
        vim.schedule_wrap(function()
          local lines = api.nvim_buf_get_lines(state.input_buf, 0, 1, false)
          if lines and lines[1] then
            spawn_grep(lines[1])
          end
        end)
      )
    end,
  })

  vim.keymap.set('i', '<Esc>', M.close, { buffer = state.input_buf })
  vim.keymap.set('n', 'q', M.close, { buffer = state.input_buf })

  vim.keymap.set('i', '<CR>', function()
    vim.cmd 'stopinsert'
    if state.win and api.nvim_win_is_valid(state.win) then
      api.nvim_set_current_win(state.win)
    end
  end, { buffer = state.input_buf })

  vim.cmd 'startinsert'
end

function M.setup(opts)
  config = vim.tbl_deep_extend('force', config, opts or {})

  api.nvim_create_user_command(config.command_name, function(cmd_opts)
    M.run(cmd_opts.args)
  end, { nargs = '+', complete = 'shellcmd' })
  api.nvim_create_user_command(config.grep_command_name, function()
    M.live_grep()
  end, {})

  if config.close_key then
    vim.keymap.set('n', config.close_key, M.close, { silent = true })
  end

  if config.hijack_bang then
    vim.keymap.set('c', '<CR>', function()
      local cmdtype = vim.fn.getcmdtype()
      local cmdline = vim.fn.getcmdline()
      if cmdtype == ':' and cmdline:match '^!' then
        vim.fn.histadd('cmd', cmdline)
        api.nvim_feedkeys(
          api.nvim_replace_termcodes('<C-c>', true, false, true),
          'n',
          false
        )
        state.keep_alive = true
        local command = cmdline:sub(2)
        vim.schedule(function()
          M.run(command)
          vim.schedule(function()
            state.keep_alive = false
          end)
        end)
        return ''
      end
      return '<CR>'
    end, { expr = true })
  end
end

return M
