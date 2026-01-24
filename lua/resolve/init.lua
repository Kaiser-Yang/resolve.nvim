local M = {}

-- Default configuration
local config = {
  -- Conflict marker patterns (Lua patterns, must match from start of line)
  markers = {
    ours = "^<<<<<<<+",       -- Start of "ours" section
    theirs = "^>>>>>>>+",     -- End of "theirs" section
    ancestor = "^|||||||+",   -- Start of ancestor/base section (diff3)
    separator = "^=======+$", -- Separator between sections
  },
  -- Keymaps (set to false to disable default keymaps)
  default_keymaps = true,
  -- Callback function called when conflicts are detected
  -- Receives: { bufnr = number, conflicts = table }
  on_conflict_detected = nil,
}

--- Set up highlight groups with colours appropriate for the current background
local function setup_highlights()
  local is_dark = vim.o.background == "dark"

  -- Semantic colours: ours=green, theirs=blue, separator=grey, ancestor=amber
  local colors
  if is_dark then
    colors = {
      ours = { bg = "#3d5c3d", bold = true },      -- green tint
      theirs = { bg = "#3d4d5c", bold = true },    -- blue tint
      separator = { bg = "#4a4a4a", bold = true }, -- neutral grey
      ancestor = { bg = "#5c4d3d", bold = true },  -- amber/orange tint
    }
  else
    colors = {
      ours = { bg = "#d4e9d4", bold = true },      -- light green
      theirs = { bg = "#d4e0e9", bold = true },    -- light blue
      separator = { bg = "#e0e0e0", bold = true }, -- light grey
      ancestor = { bg = "#e9e0d4", bold = true },  -- light amber
    }
  end

  -- Set highlights with default=true so users can override
  vim.api.nvim_set_hl(0, "ResolveOursMarker", vim.tbl_extend("force", colors.ours, { default = true }))
  vim.api.nvim_set_hl(0, "ResolveTheirsMarker", vim.tbl_extend("force", colors.theirs, { default = true }))
  vim.api.nvim_set_hl(0, "ResolveSeparatorMarker", vim.tbl_extend("force", colors.separator, { default = true }))
  vim.api.nvim_set_hl(0, "ResolveAncestorMarker", vim.tbl_extend("force", colors.ancestor, { default = true }))
end

--- Define <Plug> mappings for extensibility
local function setup_plug_mappings()
  vim.keymap.set("n", "<Plug>(resolve-next)", M.next_conflict, { desc = "Next conflict (Resolve)" })
  vim.keymap.set("n", "<Plug>(resolve-prev)", M.prev_conflict, { desc = "Previous conflict (Resolve)" })
  vim.keymap.set("n", "<Plug>(resolve-ours)", M.choose_ours, { desc = "Choose ours (Resolve)" })
  vim.keymap.set("n", "<Plug>(resolve-theirs)", M.choose_theirs, { desc = "Choose theirs (Resolve)" })
  vim.keymap.set("n", "<Plug>(resolve-both)", M.choose_both, { desc = "Choose both (Resolve)" })
  vim.keymap.set("n", "<Plug>(resolve-both-reverse)", M.choose_both_reverse, { desc = "Choose both (reverse) (Resolve)" })
  vim.keymap.set("n", "<Plug>(resolve-base)", M.choose_base, { desc = "Choose base (Resolve)" })
  vim.keymap.set("n", "<Plug>(resolve-none)", M.choose_none, { desc = "Choose none (Resolve)" })
  vim.keymap.set("n", "<Plug>(resolve-diff-ours)", M.show_diff_ours, { desc = "Show diff ours (Resolve)" })
  vim.keymap.set("n", "<Plug>(resolve-diff-theirs)", M.show_diff_theirs, { desc = "Show diff theirs (Resolve)" })
  vim.keymap.set("n", "<Plug>(resolve-diff-both)", M.show_diff_both, { desc = "Show diff both (Resolve)" })
  vim.keymap.set("n", "<Plug>(resolve-list)", M.list_conflicts, { desc = "List conflicts (Resolve)" })
end

--- Set up buffer-local keymaps (only called when conflicts exist in buffer)
local function setup_buffer_keymaps(bufnr)
  -- Skip if already set up for this buffer
  if vim.b[bufnr].resolve_keymaps_set then
    return
  end

  local opts = { buffer = bufnr, silent = true }

  -- Register groups for which-key
  vim.keymap.set("n", "<leader>gc", "", vim.tbl_extend("force", opts, { desc = "+Git Conflicts" }))
  vim.keymap.set("n", "<leader>gcd", "", vim.tbl_extend("force", opts, { desc = "+Diff" }))

  vim.keymap.set("n", "]x", "<Plug>(resolve-next)",
    vim.tbl_extend("force", opts, { desc = "Next conflict", remap = true }))
  vim.keymap.set("n", "[x", "<Plug>(resolve-prev)",
    vim.tbl_extend("force", opts, { desc = "Previous conflict", remap = true }))
  vim.keymap.set("n", "<leader>gco", "<Plug>(resolve-ours)",
    vim.tbl_extend("force", opts, { desc = "Choose ours", remap = true }))
  vim.keymap.set("n", "<leader>gct", "<Plug>(resolve-theirs)",
    vim.tbl_extend("force", opts, { desc = "Choose theirs", remap = true }))
  vim.keymap.set("n", "<leader>gcb", "<Plug>(resolve-both)",
    vim.tbl_extend("force", opts, { desc = "Choose both", remap = true }))
  vim.keymap.set("n", "<leader>gcB", "<Plug>(resolve-both-reverse)",
    vim.tbl_extend("force", opts, { desc = "Choose both (reverse)", remap = true }))
  vim.keymap.set("n", "<leader>gcm", "<Plug>(resolve-base)",
    vim.tbl_extend("force", opts, { desc = "Choose base", remap = true }))
  vim.keymap.set("n", "<leader>gcn", "<Plug>(resolve-none)",
    vim.tbl_extend("force", opts, { desc = "Choose none", remap = true }))
  vim.keymap.set("n", "<leader>gcdo", "<Plug>(resolve-diff-ours)",
    vim.tbl_extend("force", opts, { desc = "Diff ours", remap = true }))
  vim.keymap.set("n", "<leader>gcdt", "<Plug>(resolve-diff-theirs)",
    vim.tbl_extend("force", opts, { desc = "Diff theirs", remap = true }))
  vim.keymap.set("n", "<leader>gcdb", "<Plug>(resolve-diff-both)",
    vim.tbl_extend("force", opts, { desc = "Diff both", remap = true }))
  vim.keymap.set("n", "<leader>gcl", "<Plug>(resolve-list)",
    vim.tbl_extend("force", opts, { desc = "List conflicts", remap = true }))

  vim.b[bufnr].resolve_keymaps_set = true
end

--- Set up matchit integration for % jumping between conflict markers
local function setup_matchit(bufnr)
  -- Add conflict markers to buffer-local matchit patterns
  local match_words = vim.b[bufnr].match_words or ""
  local conflict_pairs = "<<<<<<<:|||||||:=======:>>>>>>>"
  if not match_words:find("<<<<<<<", 1, true) then
    if match_words ~= "" then
      match_words = match_words .. ","
    end
    vim.b[bufnr].match_words = match_words .. conflict_pairs
  end
end

--- Setup function to initialize the plugin
--- @param opts table|nil User configuration options
function M.setup(opts)
  config = vim.tbl_deep_extend("force", config, opts or {})

  -- Set up highlight groups based on current background
  setup_highlights()

  -- Re-apply highlights when colour scheme changes
  vim.api.nvim_create_autocmd("ColorScheme", {
    pattern = "*",
    callback = setup_highlights,
  })

  -- Set up <Plug> mappings (always available for user remapping)
  setup_plug_mappings()

  -- Create autocommand to detect conflicts on buffer enter
  vim.api.nvim_create_autocmd({ "BufRead", "BufEnter" }, {
    pattern = "*",
    callback = function()
      M.detect_conflicts()
    end,
  })
end

--- Scan buffer and return list of all conflicts
--- @return table List of conflict tables
local function scan_conflicts()
  local bufnr = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  local conflicts = {}
  local in_conflict = false
  local current_conflict = {}

  for i, line in ipairs(lines) do
    if line:match(config.markers.ours) then
      in_conflict = true
      current_conflict = {
        start = i,
        ours_start = i,
      }
    elseif line:match(config.markers.ancestor) and in_conflict then
      current_conflict.ancestor = i
    elseif line:match(config.markers.separator) and in_conflict then
      current_conflict.separator = i
    elseif line:match(config.markers.theirs) and in_conflict then
      current_conflict.theirs_end = i
      current_conflict["end"] = i
      table.insert(conflicts, current_conflict)
      in_conflict = false
      current_conflict = {}
    end
  end

  return conflicts
end

--- Find conflict at or around the cursor position by scanning the buffer
--- @return table|nil Conflict data or nil if not in a conflict
local function get_current_conflict()
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local current_line = cursor[1]
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local line_count = #lines

  -- Search backwards for <<<<<<< marker
  local ours_start = nil
  for i = current_line, 1, -1 do
    local line = lines[i]
    if line:match(config.markers.theirs) then
      -- Hit end of a previous conflict, cursor is not in a conflict
      return nil
    elseif line:match(config.markers.ours) then
      ours_start = i
      break
    end
  end

  if not ours_start then
    return nil
  end

  -- Search forwards from ours_start for the rest of the markers
  local ancestor = nil
  local separator = nil
  local theirs_end = nil

  for i = ours_start + 1, line_count do
    local line = lines[i]
    if line:match(config.markers.ours) then
      -- Hit start of another conflict, malformed
      return nil
    elseif line:match(config.markers.ancestor) and not separator then
      ancestor = i
    elseif line:match(config.markers.separator) then
      separator = i
    elseif line:match(config.markers.theirs) then
      theirs_end = i
      break
    end
  end

  -- Validate we found a complete conflict
  if not separator or not theirs_end then
    return nil
  end

  -- Check cursor is within conflict bounds
  if current_line > theirs_end then
    return nil
  end

  return {
    start = ours_start,
    ours_start = ours_start,
    ancestor = ancestor,
    separator = separator,
    theirs_end = theirs_end,
    ["end"] = theirs_end,
  }
end

--- Detect conflicts and highlight them (for display purposes)
function M.detect_conflicts()
  local bufnr = vim.api.nvim_get_current_buf()
  local conflicts = scan_conflicts()

  if #conflicts > 0 then
    vim.notify(string.format("Found %d conflict(s)", #conflicts), vim.log.levels.INFO)
    M.highlight_conflicts(conflicts)

    -- Set up buffer-local keymaps if enabled
    if config.default_keymaps then
      setup_buffer_keymaps(bufnr)
    end

    -- Set up matchit integration
    setup_matchit(bufnr)

    -- Call user hook if defined
    if config.on_conflict_detected then
      config.on_conflict_detected({ bufnr = bufnr, conflicts = conflicts })
    end
  else
    -- Clear highlights if no conflicts
    local ns_id = vim.api.nvim_create_namespace("resolve_conflicts")
    vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
  end

  return conflicts
end

--- Highlight conflicts in the current buffer
--- @param conflicts table List of conflicts to highlight
function M.highlight_conflicts(conflicts)
  local bufnr = vim.api.nvim_get_current_buf()
  local ns_id = vim.api.nvim_create_namespace("resolve_conflicts")

  -- Clear existing highlights
  vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)

  for _, conflict in ipairs(conflicts) do
    -- Only highlight the marker lines themselves, not the content
    -- <<<<<<< marker (ours)
    vim.api.nvim_buf_set_extmark(bufnr, ns_id, conflict.ours_start - 1, 0, {
      end_col = 0,
      end_row = conflict.ours_start,
      hl_group = "ResolveOursMarker",
    })

    -- ||||||| marker (ancestor) if exists
    if conflict.ancestor then
      vim.api.nvim_buf_set_extmark(bufnr, ns_id, conflict.ancestor - 1, 0, {
        end_col = 0,
        end_row = conflict.ancestor,
        hl_group = "ResolveAncestorMarker",
      })
    end

    -- ======= marker (separator)
    vim.api.nvim_buf_set_extmark(bufnr, ns_id, conflict.separator - 1, 0, {
      end_col = 0,
      end_row = conflict.separator,
      hl_group = "ResolveSeparatorMarker",
    })

    -- >>>>>>> marker (theirs)
    vim.api.nvim_buf_set_extmark(bufnr, ns_id, conflict.theirs_end - 1, 0, {
      end_col = 0,
      end_row = conflict.theirs_end,
      hl_group = "ResolveTheirsMarker",
    })
  end
end

--- Navigate to the next conflict
function M.next_conflict()
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local current_line = cursor[1]
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  -- Search forwards for next <<<<<<< marker
  for i = current_line + 1, #lines do
    if lines[i]:match(config.markers.ours) then
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      return
    end
  end

  vim.notify("No more conflicts", vim.log.levels.INFO)
end

--- Navigate to the previous conflict
function M.prev_conflict()
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local current_line = cursor[1]
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  -- If we're inside a conflict, we need to find the start of the *previous* conflict
  -- First, skip backwards past any <<<<<<< on or before current line that we might be inside
  local search_from = current_line - 1

  -- Check if we're inside a conflict by looking for <<<<<<< before us
  for i = current_line, 1, -1 do
    local line = lines[i]
    if line:match(config.markers.ours) then
      -- We found a <<<<<<< - if this is where we are or before, start searching before it
      search_from = i - 1
      break
    elseif line:match(config.markers.theirs) then
      -- We hit end of previous conflict, we're not inside one
      break
    end
  end

  -- Now search backwards for previous <<<<<<< marker
  for i = search_from, 1, -1 do
    if lines[i]:match(config.markers.ours) then
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      return
    end
  end

  vim.notify("No previous conflicts", vim.log.levels.INFO)
end

--- Choose "ours" version of the conflict
function M.choose_ours()
  local conflict = get_current_conflict()
  if not conflict then
    vim.notify("Not in a conflict", vim.log.levels.WARN)
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  -- Note: 1-indexed positions used as 0-indexed start naturally skip the marker line
  -- End before ancestor (diff3) or separator (non-diff3)
  local end_line = conflict.ancestor and (conflict.ancestor - 1) or (conflict.separator - 1)
  local lines = vim.api.nvim_buf_get_lines(bufnr, conflict.ours_start, end_line, false)

  -- Replace the entire conflict with ours section
  vim.api.nvim_buf_set_lines(bufnr, conflict.start - 1, conflict["end"], false, lines)

  M.detect_conflicts()
end

--- Choose "theirs" version of the conflict
function M.choose_theirs()
  local conflict = get_current_conflict()
  if not conflict then
    vim.notify("Not in a conflict", vim.log.levels.WARN)
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  -- Note: 1-indexed separator used as 0-indexed start naturally skips the ======= line
  local lines = vim.api.nvim_buf_get_lines(bufnr, conflict.separator, conflict.theirs_end - 1, false)

  -- Replace the entire conflict with theirs section
  vim.api.nvim_buf_set_lines(bufnr, conflict.start - 1, conflict["end"], false, lines)

  M.detect_conflicts()
end

--- Choose both versions (ours then theirs)
function M.choose_both()
  local conflict = get_current_conflict()
  if not conflict then
    vim.notify("Not in a conflict", vim.log.levels.WARN)
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()

  -- Get ours section (end before ancestor or separator)
  local ours_end = conflict.ancestor and (conflict.ancestor - 1) or (conflict.separator - 1)
  local ours_lines = vim.api.nvim_buf_get_lines(bufnr, conflict.ours_start, ours_end, false)

  -- Get theirs section
  local theirs_lines = vim.api.nvim_buf_get_lines(bufnr, conflict.separator, conflict.theirs_end - 1, false)

  -- Combine both
  local combined = {}
  vim.list_extend(combined, ours_lines)
  vim.list_extend(combined, theirs_lines)

  -- Replace the entire conflict
  vim.api.nvim_buf_set_lines(bufnr, conflict.start - 1, conflict["end"], false, combined)

  M.detect_conflicts()
end

--- Choose both versions in reverse order (theirs then ours)
function M.choose_both_reverse()
  local conflict = get_current_conflict()
  if not conflict then
    vim.notify("Not in a conflict", vim.log.levels.WARN)
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()

  -- Get ours section (end before ancestor or separator)
  local ours_end = conflict.ancestor and (conflict.ancestor - 1) or (conflict.separator - 1)
  local ours_lines = vim.api.nvim_buf_get_lines(bufnr, conflict.ours_start, ours_end, false)

  -- Get theirs section
  local theirs_lines = vim.api.nvim_buf_get_lines(bufnr, conflict.separator, conflict.theirs_end - 1, false)

  -- Combine both in reverse order (theirs first, then ours)
  local combined = {}
  vim.list_extend(combined, theirs_lines)
  vim.list_extend(combined, ours_lines)

  -- Replace the entire conflict
  vim.api.nvim_buf_set_lines(bufnr, conflict.start - 1, conflict["end"], false, combined)

  M.detect_conflicts()
end

--- Choose neither version (delete the conflict)
function M.choose_none()
  local conflict = get_current_conflict()
  if not conflict then
    vim.notify("Not in a conflict", vim.log.levels.WARN)
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()

  -- Delete the entire conflict
  vim.api.nvim_buf_set_lines(bufnr, conflict.start - 1, conflict["end"], false, {})

  M.detect_conflicts()
end

--- Choose the base/ancestor version (diff3 style only)
function M.choose_base()
  local conflict = get_current_conflict()
  if not conflict then
    vim.notify("Not in a conflict", vim.log.levels.WARN)
    return
  end

  if not conflict.ancestor then
    vim.notify("No base version available (not a diff3-style conflict)", vim.log.levels.WARN)
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  -- Note: 1-indexed ancestor used as 0-indexed start naturally skips the ||||||| line
  local lines = vim.api.nvim_buf_get_lines(bufnr, conflict.ancestor, conflict.separator - 1, false)

  -- Replace the entire conflict with base section
  vim.api.nvim_buf_set_lines(bufnr, conflict.start - 1, conflict["end"], false, lines)

  M.detect_conflicts()
end

--- List all conflicts in a quickfix list
function M.list_conflicts()
  local conflicts = scan_conflicts()

  if #conflicts == 0 then
    vim.notify("No conflicts found", vim.log.levels.INFO)
    return
  end

  local qf_list = {}
  local bufnr = vim.api.nvim_get_current_buf()
  local filename = vim.api.nvim_buf_get_name(bufnr)

  for i, conflict in ipairs(conflicts) do
    table.insert(qf_list, {
      bufnr = bufnr,
      filename = filename,
      lnum = conflict.start,
      text = string.format("Conflict %d/%d", i, #conflicts),
    })
  end

  vim.fn.setqflist(qf_list)
  vim.cmd("copen")
end

--- Extract conflict sections to temporary files
--- @param conflict table Conflict data
--- @return table|nil Table with base_file, ours_file, theirs_file paths, or nil if not diff3
local function extract_conflict_to_files(conflict)
  if not conflict.ancestor then
    vim.notify("Not a diff3-style conflict (no base version)", vim.log.levels.WARN)
    return nil
  end

  local bufnr = vim.api.nvim_get_current_buf()

  -- Note: conflict positions are 1-indexed, nvim_buf_get_lines uses 0-indexed
  -- Extract ours section (between <<<<<<< and |||||||, excluding markers)
  local ours_lines = vim.api.nvim_buf_get_lines(bufnr, conflict.ours_start, conflict.ancestor - 1, false)

  -- Extract base section (between ||||||| and =======, excluding markers)
  local base_lines = vim.api.nvim_buf_get_lines(bufnr, conflict.ancestor, conflict.separator - 1, false)

  -- Extract theirs section (between ======= and >>>>>>>, excluding markers)
  local theirs_lines = vim.api.nvim_buf_get_lines(bufnr, conflict.separator, conflict.theirs_end - 1, false)

  -- Create temporary files
  local tmpdir = vim.fn.tempname()
  vim.fn.mkdir(tmpdir, "p")

  local base_file = tmpdir .. "/base"
  local ours_file = tmpdir .. "/ours"
  local theirs_file = tmpdir .. "/theirs"

  -- Write sections to files
  vim.fn.writefile(base_lines, base_file)
  vim.fn.writefile(ours_lines, ours_file)
  vim.fn.writefile(theirs_lines, theirs_file)

  return {
    base_file = base_file,
    ours_file = ours_file,
    theirs_file = theirs_file,
    tmpdir = tmpdir,
  }
end

--- Get the diff command to run
--- @param file1 string First file path
--- @param file2 string Second file path
--- @return string Command to run
local function get_diff_command(file1, file2)
  -- Use diff with huge context (effectively unlimited) piped through delta for nice formatting
  -- delta provides intra-line highlighting and clean output with no headers
  return string.format(
    "diff --color=always -U1000000 %s %s | delta --no-gitconfig --keep-plus-minus-markers --file-style=omit --hunk-header-style=omit",
    vim.fn.shellescape(file1),
    vim.fn.shellescape(file2)
  )
end

--- Show diffs in a floating window
--- @param show_ours boolean Whether to show base ↔ ours diff
--- @param show_theirs boolean Whether to show base ↔ theirs diff
local function show_diff_internal(show_ours, show_theirs)
  local conflict = get_current_conflict()
  if not conflict then
    vim.notify("Not in a conflict", vim.log.levels.WARN)
    return
  end

  local files = extract_conflict_to_files(conflict)
  if not files then
    return
  end

  -- Build output based on which diffs to show
  local output_parts = {}

  if show_ours then
    local base_ours_cmd = get_diff_command(files.base_file, files.ours_file)
    local base_ours_output = vim.fn.system(base_ours_cmd)
    if show_theirs then table.insert(output_parts, "━━━ Base ↔ Ours ━━━") end
    table.insert(output_parts, base_ours_output)
  end

  if show_theirs then
    local base_theirs_cmd = get_diff_command(files.base_file, files.theirs_file)
    local base_theirs_output = vim.fn.system(base_theirs_cmd)
    if show_ours then table.insert(output_parts, "━━━ Base ↔ Theirs ━━━") end
    table.insert(output_parts, base_theirs_output)
  end

  -- Clean up temp files
  vim.fn.delete(files.tmpdir, "rf")

  -- Combine output with separator if showing both
  local combined_output = table.concat(output_parts, "\n")

  -- Count newlines (gsub returns replacement count as second value)
  local _, number_of_newlines = string.gsub(combined_output, "\n", "\n")

  -- Determine title based on what's shown
  local title
  if show_ours and show_theirs then
    title = " Conflict Diff (Both) "
  elseif show_ours then
    title = " Conflict Diff (Ours) "
  else
    title = " Conflict Diff (Theirs) "
  end

  -- Calculate floating window size (80% of editor)
  local width = math.floor(vim.o.columns * 0.8)
  local height = math.min(math.floor(vim.o.lines * 0.8), number_of_newlines + 1)
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  -- Create buffer for the floating window
  local buf = vim.api.nvim_create_buf(false, true)

  -- Create floating window
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = title,
    title_pos = "center",
  })

  -- Use nvim_open_term to create a pseudo-terminal that interprets ANSI codes
  -- This gives us colours without an actual process (no "[Process exited]" message)
  local term_chan = vim.api.nvim_open_term(buf, {})
  vim.api.nvim_chan_send(term_chan, combined_output)

  -- Set up keymaps to close the floating window
  local close_keys = { "q", "<Esc>" }
  for _, key in ipairs(close_keys) do
    vim.keymap.set("n", key, function()
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
    end, { buffer = buf, nowait = true })
  end

  -- Move cursor to top
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
end

--- Show diff of our changes from base
function M.show_diff_ours()
  show_diff_internal(true, false)
end

--- Show diff of theirs changes from base
function M.show_diff_theirs()
  show_diff_internal(false, true)
end

--- Show both diffs (ours and theirs from base)
function M.show_diff_both()
  show_diff_internal(true, true)
end

return M
