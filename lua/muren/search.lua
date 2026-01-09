local M = {}

local nvim_exec2 = vim.api.nvim_exec2 or vim.api.nvim_exec

local find_all_line_matches_in_current_buf = function(pattern, opts)
  local current_cursor = vim.api.nvim_win_get_cursor(0)
  -- TODO take range into account
  local range = opts.range
  if range and range.start > 1 then
    vim.cmd(string.format('%d', range.start - 1))
    vim.cmd('normal $')
  else
    vim.cmd('normal G$')
  end
  local flags = 'w'
  local lines = {}
  while true do
    local success, line = pcall(vim.fn.search, pattern, flags)
    vim.opt.hlsearch = false
    if not success or line == 0 then
      break
    end
    if range and line > range._end then
      break
    end
    table.insert(lines, line)
    flags = 'W'
  end
  vim.api.nvim_win_set_cursor(0, current_cursor)
  return lines
end

local cmd_silent = function(src)
  pcall(nvim_exec2, src, {output = true})
end

-- Count occurrences of pattern in current buffer
local function count_matches(pattern, range)
  local lines
  if range and range ~= '%' then
    local start_line, end_line = range:match('(%d+),(%d+)')
    start_line = tonumber(start_line) - 1
    end_line = tonumber(end_line)
    lines = vim.api.nvim_buf_get_lines(0, start_line, end_line, false)
  else
    lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  end
  local count = 0
  -- Escape lua pattern special chars but keep it simple for literal matching
  local lua_pattern = vim.pesc(pattern)
  for _, line in ipairs(lines) do
    local start_pos = 1
    while true do
      local match_start = line:find(lua_pattern, start_pos, true)
      if not match_start then break end
      count = count + 1
      start_pos = match_start + 1
    end
  end
  return count
end

-- Execute substitute command
local function cmd_substitute(src)
  pcall(nvim_exec2, src, {output = true})
end

local get_grep_matches = function(pattern, opts)
  local current_cwd = vim.fn.getcwd()
  vim.cmd.cd(opts.dir)
  local success = pcall(vim.cmd.vim, string.format(
    '/%s/j%s %s',
    pattern,
    opts.replace_opt_chars or '',
    opts.files or '**/*'
  ))
  vim.cmd.cd(current_cwd)
  if not success then
    return {}
  end
  return vim.fn.getqflist()
end

local get_affected_bufs = function(pattern, opts)
  local unique_bufs = {}
  for _, qitem in ipairs(get_grep_matches(pattern, opts)) do
    unique_bufs[qitem.bufnr] = true
  end
  return unique_bufs
end

local function search_replace(pattern, replacement, opts)
  local affected_bufs
  local total_count = 0
  if opts.cwd then
    affected_bufs = get_affected_bufs(pattern, opts)
    for buf, _ in pairs(affected_bufs) do
      local _, count = search_replace(pattern, replacement, {
        buf = buf,
        replace_opt_chars = opts.replace_opt_chars,
        range = opts.range,
      })
      total_count = total_count + count
    end
  else
    affected_bufs = {[opts.buf] = true}
    vim.api.nvim_buf_call(opts.buf, function()
      -- Count matches before substitution
      total_count = count_matches(pattern, opts.range)
      -- Perform substitution
      cmd_substitute(string.format(
        '%ss/%s/%s/%s',
        opts.range or '%',
        pattern,
        replacement,
        opts.replace_opt_chars or ''
      ))
    end)
  end
  vim.opt.hlsearch = false
  return affected_bufs, total_count
end

local multi_replace_recursive = function(patterns, replacements, opts)
  local affected_bufs = {}
  local total_count = 0
  for i, pattern in ipairs(patterns) do
    local replacement = replacements[i] or ''
    local bufs, count = search_replace(pattern, replacement, opts)
    affected_bufs = vim.tbl_extend('keep', affected_bufs, bufs)
    total_count = total_count + count
  end
  return affected_bufs, total_count
end

local multi_replace_non_recursive = function(patterns, replacements, opts)
  local affected_bufs = {}
  local total_count = 0
  local replacement_per_placeholder = {}
  for i, pattern in ipairs(patterns) do
    local placeholder = string.format('___MUREN___%d___', i)
    local replacement = replacements[i] or ''
    replacement_per_placeholder[placeholder] = replacement
    local bufs, count = search_replace(pattern, placeholder, opts)
    affected_bufs = vim.tbl_extend('keep', affected_bufs, bufs)
    total_count = total_count + count
  end
  -- TODO if we would have eg 'c' replace_opt_chars I guess we don't want it here?
  for placeholder, replacement in pairs(replacement_per_placeholder) do
    search_replace(placeholder, replacement, opts)
  end
  return affected_bufs, total_count
end

M.find_all_line_matches = function(pattern, opts)
  local lines_per_buf = {}
  if opts.cwd then
    for _, qitem in ipairs(get_grep_matches(pattern, opts)) do
      if not lines_per_buf[qitem.bufnr] then
        lines_per_buf[qitem.bufnr] = {}
      end
      table.insert(lines_per_buf[qitem.bufnr], qitem.lnum)
    end
  else
    vim.api.nvim_buf_call(opts.buffer, function()
      lines_per_buf[opts.buffer] = find_all_line_matches_in_current_buf(pattern, opts)
    end)
  end
  return lines_per_buf
end

M.do_replace_with_patterns = function(patterns, replacements, opts)
  local replace_opts = {
    buf = opts.buffer,
    cwd = opts.cwd,
    dir = opts.dir,
    files = opts.files,
  }
  if opts.all_on_line then
    replace_opts.replace_opt_chars = 'g'
  end
  if opts.range then
    replace_opts.range = string.format('%d,%d', opts.range.start, opts.range._end)
  else
    replace_opts.range = '%'
  end
  local affected_bufs, total_count
  if opts.two_step then
    affected_bufs, total_count = multi_replace_non_recursive(patterns, replacements, replace_opts)
  else
    affected_bufs, total_count = multi_replace_recursive(patterns, replacements, replace_opts)
  end
  -- Save affected buffers if write_on_replace is enabled
  if opts.write_on_replace then
    for buf, _ in pairs(affected_bufs) do
      if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_option(buf, 'modified') then
        vim.api.nvim_buf_call(buf, function()
          vim.cmd('silent! update')
        end)
      end
    end
  end
  -- Notify with results (skip if notify is explicitly false, e.g., during preview)
  if opts.notify ~= false then
    local file_count = vim.tbl_count(affected_bufs)
    if total_count > 0 then
      local file_word = file_count == 1 and 'file' or 'files'
      local occurrence_word = total_count == 1 and 'occurrence' or 'occurrences'
      vim.notify(
        string.format('Replaced %d %s across %d %s', total_count, occurrence_word, file_count, file_word),
        vim.log.levels.INFO
      )
    end
  end
  return affected_bufs
end

local within_range = function(loc_item, range)
  if not range then
    return true
  end
  return range.start <= loc_item.lnum and loc_item.lnum <= range._end
end

M.get_unique_last_search_matches = function(opts)
  opts = opts or {}
  cmd_silent(string.format('lvim %s %%', opts.pattern or '//'))
  vim.opt.hlsearch = false
  local loc_items = vim.fn.getloclist(0)
  local unique_matches = {}
  for _, loc_item in ipairs(loc_items) do
    if within_range(loc_item, opts.range) then
      local match_text = loc_item.text:sub(loc_item.col, loc_item.end_col - 1)
      unique_matches[match_text] = true
    end
  end
  unique_matches = vim.tbl_keys(unique_matches)
  table.sort(unique_matches)
  return unique_matches
end

return M
