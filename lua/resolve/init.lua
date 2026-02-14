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
  -- Labels for diff view window titles
  diff_view_labels = {
    ours = "Ours",
    theirs = "Theirs",
    base = "Base",
  },
  -- Enable automatic conflict detection (controls whether detection autocmd is created)
  auto_detect_enabled = true,
  -- Patterns for buffers to skip conflict detection (Lua patterns)
  skip_patterns = {
    buftype = { "." },  -- Skip any buffer with non-empty buftype (terminals, help, etc)
    filetype = {},      -- No filetype skips by default
  },
  -- Custom function to determine if a buffer should be skipped
  -- Receives: bufnr (number)
  -- Returns: boolean (true to skip, false to detect)
  -- Default checks for readonly and unlisted buffers
  should_skip = nil,
  -- Callback function called when conflicts are detected
  -- Receives: { bufnr = number, conflicts = table }
  on_conflict_detected = nil,
  -- Callback function called when all conflicts are resolved
  -- Receives: { bufnr = number }
  on_conflicts_resolved = nil,
}

-- Store augroup to use in toggle function
local resolve_augroup = nil

-- Cache for git availability check (nil = not checked yet, true/false = cached result)
-- Note: This cache persists for the entire editor session. If git is installed/uninstalled
-- during the session, restart Neovim to refresh the cache.
local git_available_cache = nil

--- Check if git command is available
--- @return boolean True if git is available
local function is_git_available()
  if git_available_cache ~= nil then
    return git_available_cache
  end
  
  -- Check if git command exists
  local result = vim.fn.executable("git")
  git_available_cache = result == 1
  return git_available_cache
end

--- Check if current buffer file has merge conflicts according to git
--- This provides a fast pre-check to avoid scanning large buffers unnecessarily
--- @param filepath string File path
--- @param callback function Callback function(has_conflicts: boolean)
local function check_git_conflicts_async(filepath, callback)
  -- Handle different failure scenarios
  if not is_git_available() then
    -- Git not available - fall back to buffer scan
    callback(false)
    return
  end
  
  if filepath == "" then
    -- New buffer without file - fall back to buffer scan
    callback(false)
    return
  end
  
  if vim.fn.filereadable(filepath) == 0 then
    -- File doesn't exist yet - fall back to buffer scan
    callback(false)
    return
  end
  
  local dir = vim.fn.fnamemodify(filepath, ":h")
  
  -- First check if we're in a git repo
  vim.system(
    { "git", "-C", dir, "rev-parse", "--git-dir" },
    { text = true },
    vim.schedule_wrap(function(repo_result)
      if repo_result.code ~= 0 then
        callback(false)
        return
      end
      
      -- Check if file has conflict markers using git diff --check
      vim.system(
        { "git", "diff", "--check", filepath },
        { text = true, cwd = dir },
        vim.schedule_wrap(function(result)
          -- git diff --check returns non-zero for both whitespace errors and conflict markers
          -- Check the output specifically for conflict marker messages
          if result.code == 0 then
            callback(false)
            return
          end
          
          -- Parse output to check for conflict markers specifically
          -- git diff --check reports "leftover conflict marker" for conflicts
          -- Use a more specific pattern to avoid false positives from unrelated messages
          local stderr = result.stderr or ""
          local has_conflicts = stderr:match("leftover conflict marker") ~= nil
          if not has_conflicts then
            local stdout = result.stdout or ""
            has_conflicts = stdout:match("leftover conflict marker") ~= nil
          end
          callback(has_conflicts)
        end)
      )
    end)
  )
end

--- Scan buffer line-by-line for conflicts (synchronous)
--- @param bufnr number Buffer number
--- @return table List of conflict tables
local function scan_conflicts_buffer(bufnr)
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

--- Scan buffer line-by-line for conflicts (asynchronous using vim.uv thread pool)
--- This function offloads the scanning work to a thread pool to keep UI responsive.
--- The work function runs in a separate Lua state, so data must be serialized/deserialized.
--- @param bufnr number Buffer number
--- @param callback function Callback function(conflicts: table)
local function scan_conflicts_buffer_async(bufnr, callback)
  -- Validate buffer exists
  if not vim.api.nvim_buf_is_valid(bufnr) then
    callback({})
    return
  end
  
  -- Get buffer lines in main thread
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  
  -- Prepare data for thread: lines as newline-separated string
  local lines_str = table.concat(lines, "\n")
  
  -- Prepare markers as a simple format: ours|theirs|ancestor|separator
  local markers_str = string.format("%s|%s|%s|%s",
    config.markers.ours,
    config.markers.theirs,
    config.markers.ancestor,
    config.markers.separator
  )
  
  -- Create work item to run in thread pool
  local work = vim.uv.new_work(
    function(lines_data, markers_data)
      -- This runs in a separate thread with its own Lua state
      -- Parse markers
      local markers = {}
      local idx = 1
      for marker in markers_data:gmatch("([^|]+)") do
        if idx == 1 then markers.ours = marker
        elseif idx == 2 then markers.theirs = marker
        elseif idx == 3 then markers.ancestor = marker
        elseif idx == 4 then markers.separator = marker
        end
        idx = idx + 1
      end
      
      -- Split lines (handle case where lines_data might be empty or not end with newline)
      local lines_list = {}
      if lines_data ~= "" then
        for line in (lines_data .. "\n"):gmatch("([^\n]*)\n") do
          table.insert(lines_list, line)
        end
        -- Remove the last empty element that might be added due to trailing newline
        if #lines_list > 0 and lines_list[#lines_list] == "" and lines_data:sub(-1) == "\n" then
          table.remove(lines_list)
        end
      end
      
      -- Scan for conflicts (markers are Lua patterns like "^<<<<<<<+")
      local conflicts = {}
      local in_conflict = false
      local current_conflict = {}
      
      for i, line in ipairs(lines_list) do
        if line:match(markers.ours) then
          in_conflict = true
          current_conflict = {
            start = i,
            ours_start = i,
          }
        elseif line:match(markers.ancestor) and in_conflict then
          current_conflict.ancestor = i
        elseif line:match(markers.separator) and in_conflict then
          current_conflict.separator = i
        elseif line:match(markers.theirs) and in_conflict then
          current_conflict.theirs_end = i
          current_conflict["end"] = i
          table.insert(conflicts, current_conflict)
          in_conflict = false
          current_conflict = {}
        end
      end
      
      -- Serialize conflicts to a simple format
      -- Format: start,ours_start,ancestor,separator,theirs_end,end;start,ours_start,...
      -- Use -1 for nil ancestor values
      local result_parts = {}
      for _, conflict in ipairs(conflicts) do
        local parts = {
          tostring(conflict.start),
          tostring(conflict.ours_start),
          tostring(conflict.ancestor or -1),
          tostring(conflict.separator),
          tostring(conflict.theirs_end),
          tostring(conflict["end"])
        }
        table.insert(result_parts, table.concat(parts, ","))
      end
      
      return table.concat(result_parts, ";")
    end,
    function(result_str)
      -- This runs in the main loop after work completes
      vim.schedule(function()
        -- Validate buffer still exists
        if not vim.api.nvim_buf_is_valid(bufnr) then
          callback({})
          return
        end
        
        -- Deserialize conflicts
        local conflicts = {}
        if result_str ~= "" then
          for conflict_str in result_str:gmatch("([^;]+)") do
            local parts = {}
            for part in conflict_str:gmatch("([^,]+)") do
              table.insert(parts, tonumber(part))
            end
            
            if #parts == 6 then
              local conflict = {
                start = parts[1],
                ours_start = parts[2],
                separator = parts[4],
                theirs_end = parts[5],
                ["end"] = parts[6],
              }
              -- Add ancestor only if it's not -1
              if parts[3] ~= -1 then
                conflict.ancestor = parts[3]
              end
              table.insert(conflicts, conflict)
            end
          end
        end
        
        callback(conflicts)
      end)
    end
  )
  
  -- Queue the work
  work:queue(lines_str, markers_str)
end

--- Set up highlight groups with colours appropriate for the current background
local function setup_highlights()
  local is_dark = vim.o.background == "dark"

  -- Semantic colours: ours=green, theirs=blue, separator=grey, ancestor=amber
  local colors
  if is_dark then
    colors = {
      -- Marker highlights (bold with stronger colour)
      ours_marker = { bg = "#3d5c3d", bold = true },      -- green tint
      theirs_marker = { bg = "#3d4d5c", bold = true },    -- blue tint
      separator_marker = { bg = "#4a4a4a", bold = true }, -- neutral grey
      ancestor_marker = { bg = "#5c4d3d", bold = true },  -- amber/orange tint
      -- Section highlights (subtle background tint)
      ours_section = { bg = "#2a3a2a" },                  -- subtle green
      theirs_section = { bg = "#2a2f3a" },                -- subtle blue
      ancestor_section = { bg = "#3a322a" },              -- subtle amber
    }
  else
    colors = {
      -- Marker highlights (bold with stronger colour)
      ours_marker = { bg = "#a0d0a0", bold = true },      -- saturated green
      theirs_marker = { bg = "#a0c0e0", bold = true },    -- saturated blue
      separator_marker = { bg = "#c0c0c0", bold = true }, -- medium grey
      ancestor_marker = { bg = "#e0c898", bold = true },  -- saturated amber
      -- Section highlights (subtle background tint)
      ours_section = { bg = "#e8f4e8" },                  -- very light green
      theirs_section = { bg = "#e8ecf4" },                -- very light blue
      ancestor_section = { bg = "#f4ece8" },              -- very light amber
    }
  end

  -- Set marker highlights with default=true so users can override
  vim.api.nvim_set_hl(0, "ResolveOursMarker", vim.tbl_extend("force", colors.ours_marker, { default = true }))
  vim.api.nvim_set_hl(0, "ResolveTheirsMarker", vim.tbl_extend("force", colors.theirs_marker, { default = true }))
  vim.api.nvim_set_hl(0, "ResolveSeparatorMarker", vim.tbl_extend("force", colors.separator_marker, { default = true }))
  vim.api.nvim_set_hl(0, "ResolveAncestorMarker", vim.tbl_extend("force", colors.ancestor_marker, { default = true }))

  -- Set section highlights with default=true so users can override
  vim.api.nvim_set_hl(0, "ResolveOursSection", vim.tbl_extend("force", colors.ours_section, { default = true }))
  vim.api.nvim_set_hl(0, "ResolveTheirsSection", vim.tbl_extend("force", colors.theirs_section, { default = true }))
  vim.api.nvim_set_hl(0, "ResolveAncestorSection", vim.tbl_extend("force", colors.ancestor_section, { default = true }))
end

--- Helper function to check if buffer should be skipped
--- @param bufnr number Buffer number to check
--- @return boolean True if buffer should be skipped
local function should_skip_buffer(bufnr)
  -- Check buftype patterns
  local buftype = vim.bo[bufnr].buftype
  for _, pattern in ipairs(config.skip_patterns.buftype) do
    if buftype:match(pattern) then
      return true
    end
  end
  
  -- Check filetype patterns
  local filetype = vim.bo[bufnr].filetype
  for _, pattern in ipairs(config.skip_patterns.filetype) do
    if filetype:match(pattern) then
      return true
    end
  end
  
  -- Use custom should_skip function if provided
  if config.should_skip then
    return config.should_skip(bufnr)
  end
  
  -- Default checks: readonly and unlisted buffers
  if vim.bo[bufnr].readonly then
    return true
  end
  
  if not vim.api.nvim_buf_is_loaded(bufnr) or not vim.fn.buflisted(bufnr) then
    return true
  end
  
  return false
end

--- Helper function to setup all autocmds (conflict detection and highlights)
--- @param augroup number The augroup ID
--- @return number The autocmd ID
local function setup_autocmd(augroup)
  -- Re-apply highlights when colour scheme changes
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = augroup,
    pattern = "*",
    callback = setup_highlights,
  })
  
  -- Build event list - always include TextChanged if auto-detect is enabled
  local events = { "BufRead", "BufEnter", "FileChangedShellPost", "TextChanged" }
  
  -- Create a single autocmd for all conflict detection events
  return vim.api.nvim_create_autocmd(events, {
    group = augroup,
    pattern = "*",
    callback = function(ev)
      local bufnr = vim.api.nvim_get_current_buf()
      
      -- Skip buffers based on configuration
      if should_skip_buffer(bufnr) then
        return
      end
      
      -- Detect conflicts
      M.detect_conflicts()
    end,
  })
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
  vim.keymap.set("n", "<Plug>(resolve-diff-vs)", M.show_diff_ours_vs_theirs,
    { desc = "Show diff ours vs theirs (Resolve)" })
  vim.keymap.set("n", "<Plug>(resolve-diff-vs-reverse)", M.show_diff_theirs_vs_ours,
    { desc = "Show diff theirs vs ours (Resolve)" })
  vim.keymap.set("n", "<Plug>(resolve-list)", M.list_conflicts, { desc = "List conflicts (Resolve)" })
  vim.keymap.set("n", "<Plug>(resolve-toggle-auto-detect)", M.toggle_auto_detect, 
    { desc = "Toggle auto-detect (Resolve)" })
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
  vim.keymap.set("n", "<leader>gcdv", "<Plug>(resolve-diff-vs)",
    vim.tbl_extend("force", opts, { desc = "Diff ours vs theirs", remap = true }))
  vim.keymap.set("n", "<leader>gcdV", "<Plug>(resolve-diff-vs-reverse)",
    vim.tbl_extend("force", opts, { desc = "Diff theirs vs ours", remap = true }))
  vim.keymap.set("n", "<leader>gcl", "<Plug>(resolve-list)",
    vim.tbl_extend("force", opts, { desc = "List conflicts", remap = true }))

  vim.b[bufnr].resolve_keymaps_set = true
end

--- Remove buffer-local keymaps (called when no conflicts remain)
local function remove_buffer_keymaps(bufnr)
  -- Skip if keymaps weren't set
  if not vim.b[bufnr].resolve_keymaps_set then
    return
  end

  -- List of all keys we set
  local keys = {
    "]x",
    "[x",
    "<leader>gc",
    "<leader>gcd",
    "<leader>gco",
    "<leader>gct",
    "<leader>gcb",
    "<leader>gcB",
    "<leader>gcm",
    "<leader>gcn",
    "<leader>gcdo",
    "<leader>gcdt",
    "<leader>gcdb",
    "<leader>gcdv",
    "<leader>gcdV",
    "<leader>gcl",
  }

  -- Delete each keymap
  for _, key in ipairs(keys) do
    pcall(vim.keymap.del, "n", key, { buffer = bufnr })
  end

  vim.b[bufnr].resolve_keymaps_set = nil
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
    vim.b[bufnr].resolve_matchit_set = true
  end
end

--- Remove matchit integration (called when no conflicts remain)
local function remove_matchit(bufnr)
  -- Skip if matchit wasn't set up
  if not vim.b[bufnr].resolve_matchit_set then
    return
  end

  -- Remove conflict patterns from match_words
  local match_words = vim.b[bufnr].match_words or ""
  local conflict_pairs = "<<<<<<<:|||||||:=======:>>>>>>>"

  -- Remove the conflict patterns (with or without comma)
  match_words = match_words:gsub("," .. vim.pesc(conflict_pairs), "")
  match_words = match_words:gsub(vim.pesc(conflict_pairs) .. ",?", "")

  if match_words == "" then
    vim.b[bufnr].match_words = nil
  else
    vim.b[bufnr].match_words = match_words
  end

  vim.b[bufnr].resolve_matchit_set = nil
end

--- Setup function to initialize the plugin
--- @param opts table|nil User configuration options
function M.setup(opts)
  config = vim.tbl_deep_extend("force", config, opts or {})

  -- Set up highlight groups based on current background
  setup_highlights()

  -- Set up <Plug> mappings (always available for user remapping)
  setup_plug_mappings()

  -- Only create detection autocmds if auto-detect is enabled
  if config.auto_detect_enabled then
    -- Create augroup for plugin autocmds (clear to handle multiple setup() calls)
    resolve_augroup = vim.api.nvim_create_augroup("ResolveConflicts", { clear = true })
    
    -- Create autocmds for conflict detection and color scheme changes
    setup_autocmd(resolve_augroup)
    
    -- Immediately detect conflicts in the current buffer for aggressive lazy loading
    M.detect_conflicts()  -- show notification on startup
  end
end

--- Scan buffer and return list of all conflicts (async when callback provided)
--- Uses git diff --check for fast pre-screening when available.
--- Buffer scanning is done asynchronously in a thread pool via vim.uv to keep UI responsive.
--- @param callback function|nil Callback function(conflicts: table) - if nil, runs synchronously
local function scan_conflicts(callback)
  local bufnr = vim.api.nvim_get_current_buf()
  
  -- Synchronous mode - for compatibility with existing code
  if callback == nil then
    return scan_conflicts_buffer(bufnr)
  end
  
  -- Async mode - try git first for performance optimization
  local filepath = vim.api.nvim_buf_get_name(bufnr)
  
  check_git_conflicts_async(filepath, function(has_conflicts)
    -- Validate buffer still exists (user might have closed it during async operation)
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    
    -- Check if buffer has been modified since git checked the file on disk
    -- Modified buffers must be scanned because their content differs from disk,
    -- so git's assessment of the file on disk may not match the buffer content
    local is_modified = vim.bo[bufnr].modified
    
    if not has_conflicts and not is_modified then
      -- Git confirms no conflicts and buffer matches file - no need to scan
      callback({})
      return
    end
    
    -- Either git detected conflicts, buffer is modified, or git is unavailable
    -- Scan buffer to get exact positions using async thread-based scanning
    scan_conflicts_buffer_async(bufnr, callback)
  end)
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
--- NOTE: This function is now asynchronous and does not return conflicts.
--- For synchronous access to the conflict list, use M.list_conflicts() which populates
--- the quickfix list with all conflicts found in the buffer.
function M.detect_conflicts()
  local bufnr = vim.api.nvim_get_current_buf()
  
  -- Use async scanning with git for better performance on large buffers
  scan_conflicts(function(conflicts)
    if #conflicts > 0 then
      vim.notify(string.format("Found %d conflict(s)", #conflicts), vim.log.levels.INFO)
      M.highlight_conflicts(conflicts)

      -- Set up buffer-local keymaps if enabled
      if config.default_keymaps then
        setup_buffer_keymaps(bufnr)
      end

      -- Set up matchit integration
      setup_matchit(bufnr)

      -- Call user hook if defined (protected to prevent errors from breaking plugin)
      if config.on_conflict_detected then
        local ok, err = pcall(config.on_conflict_detected, { bufnr = bufnr, conflicts = conflicts })
        if not ok then
          vim.notify("Error in on_conflict_detected hook: " .. tostring(err), vim.log.levels.ERROR)
        end
      end
    else
      -- Clear highlights if no conflicts
      local ns_id = vim.api.nvim_create_namespace("resolve_conflicts")
      vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)

      -- Remove buffer-local keymaps and matchit integration
      if config.default_keymaps then
        remove_buffer_keymaps(bufnr)
      end
      remove_matchit(bufnr)

      -- Call user hook if defined (protected to prevent errors from breaking plugin)
      if config.on_conflicts_resolved then
        local ok, err = pcall(config.on_conflicts_resolved, { bufnr = bufnr })
        if not ok then
          vim.notify("Error in on_conflicts_resolved hook: " .. tostring(err), vim.log.levels.ERROR)
        end
      end
    end
  end)
end

--- Toggle automatic conflict detection on text changes
--- @param enable boolean|nil Enable (true), disable (false), or toggle (nil)
--- @param silent boolean|nil If true, suppress notification
function M.toggle_auto_detect(enable, silent)
  local new_state
  
  if enable == nil then
    -- No parameter provided, toggle current state
    new_state = not config.auto_detect_enabled
  else
    new_state = enable
  end
  
  -- If state hasn't changed, nothing to do
  if new_state == config.auto_detect_enabled then
    if not silent then
      vim.notify("Auto-detect is already " .. (new_state and "enabled" or "disabled"), vim.log.levels.INFO)
    end
    return
  end
  
  config.auto_detect_enabled = new_state
  
  if new_state then
    -- Enable: Create augroup and setup autocmd
    resolve_augroup = vim.api.nvim_create_augroup("ResolveConflicts", { clear = true })
    setup_autocmd(resolve_augroup)
    
    -- Immediately check for conflicts
    M.detect_conflicts()
  else
    -- Disable: Clear the entire augroup
    if resolve_augroup then
      vim.api.nvim_clear_autocmds({ group = "ResolveConflicts" })
      resolve_augroup = nil
    end
  end
  
  if not silent then
    vim.notify("Auto-detect " .. (new_state and "enabled" or "disabled"), vim.log.levels.INFO)
  end
end

--- Highlight conflicts in the current buffer
--- @param conflicts table List of conflicts to highlight
function M.highlight_conflicts(conflicts)
  local bufnr = vim.api.nvim_get_current_buf()
  local ns_id = vim.api.nvim_create_namespace("resolve_conflicts")

  -- Clear existing highlights
  vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)

  for _, conflict in ipairs(conflicts) do
    -- Highlight marker lines
    -- <<<<<<< marker (ours)
    vim.api.nvim_buf_set_extmark(bufnr, ns_id, conflict.ours_start - 1, 0, {
      end_col = 0,
      end_row = conflict.ours_start,
      hl_group = "ResolveOursMarker",
      hl_eol = true,
    })

    -- ||||||| marker (ancestor) if exists
    if conflict.ancestor then
      vim.api.nvim_buf_set_extmark(bufnr, ns_id, conflict.ancestor - 1, 0, {
        end_col = 0,
        end_row = conflict.ancestor,
        hl_group = "ResolveAncestorMarker",
        hl_eol = true,
      })
    end

    -- ======= marker (separator)
    vim.api.nvim_buf_set_extmark(bufnr, ns_id, conflict.separator - 1, 0, {
      end_col = 0,
      end_row = conflict.separator,
      hl_group = "ResolveSeparatorMarker",
      hl_eol = true,
    })

    -- >>>>>>> marker (theirs)
    vim.api.nvim_buf_set_extmark(bufnr, ns_id, conflict.theirs_end - 1, 0, {
      end_col = 0,
      end_row = conflict.theirs_end,
      hl_group = "ResolveTheirsMarker",
      hl_eol = true,
    })

    -- Highlight content sections
    -- Ours section (between <<<<<<< and ||||||| or =======)
    local ours_end = conflict.ancestor and (conflict.ancestor - 1) or (conflict.separator - 1)
    if ours_end > conflict.ours_start then
      vim.api.nvim_buf_set_extmark(bufnr, ns_id, conflict.ours_start, 0, {
        end_row = ours_end,
        end_col = 0,
        hl_group = "ResolveOursSection",
        hl_eol = true,
      })
    end

    -- Ancestor section (between ||||||| and =======) if exists
    if conflict.ancestor and conflict.separator - 1 > conflict.ancestor then
      vim.api.nvim_buf_set_extmark(bufnr, ns_id, conflict.ancestor, 0, {
        end_row = conflict.separator - 1,
        end_col = 0,
        hl_group = "ResolveAncestorSection",
        hl_eol = true,
      })
    end

    -- Theirs section (between ======= and >>>>>>>)
    if conflict.theirs_end - 1 > conflict.separator then
      vim.api.nvim_buf_set_extmark(bufnr, ns_id, conflict.separator, 0, {
        end_row = conflict.theirs_end - 1,
        end_col = 0,
        hl_group = "ResolveTheirsSection",
        hl_eol = true,
      })
    end
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

--- Display diff output in a floating window
--- @param output string The diff output to display
--- @param title string The window title
local function display_diff_window(output, title)
  -- Count newlines (gsub returns replacement count as second value)
  local _, number_of_newlines = string.gsub(output, "\n", "\n")

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
  vim.api.nvim_chan_send(term_chan, output)

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

-- Helper function to generate a single diff and update output
--- @param file1 string First file path
--- @param file2 string Second file path
--- @param label string Label for this diff (e.g., "Base ↔ Ours")
--- @param output_parts table Table to append output to
--- @param multiple boolean Whether multiple diffs are being shown
--- @param current_title string|nil Current title (nil indicates there has been an error)
--- @return string|nil New title, or nil on error
local function generate_and_add_diff(file1, file2, label, output_parts, multiple, current_title)
  if current_title then
    local cmd = get_diff_command(file1, file2)
    local output = vim.fn.system(cmd)
    if vim.v.shell_error ~= 0 then
      vim.notify("Failed to generate diff (" .. label .. "): command exited with status " .. vim.v.shell_error,
        vim.log.levels.ERROR)
      return nil
    end

    if multiple then
      table.insert(output_parts, "━━━ " .. label .. " ━━━")
    else
      current_title = " Conflict Diff (" .. label .. ") "
    end
    table.insert(output_parts, output)
  end

  return current_title
end

--- Show diffs in a floating window
--- @param show_base_ours boolean Whether to show base → ours diff
--- @param show_base_theirs boolean Whether to show base → theirs diff
--- @param show_ours_theirs boolean Whether to show ours → theirs diff
--- @param show_theirs_ours boolean Whether to show theirs → ours diff
local function show_diff_internal(show_base_ours, show_base_theirs, show_ours_theirs, show_theirs_ours)
  local conflict = get_current_conflict()
  if not conflict then
    vim.notify("Not in a conflict", vim.log.levels.WARN)
    return
  end

  -- Check if we need diff3 (base comparisons require ancestor)
  if (show_base_ours or show_base_theirs) and not conflict.ancestor then
    vim.notify("Not a diff3-style conflict (no base version)", vim.log.levels.WARN)
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()

  -- Determine which sections we need to extract
  local need_ours = show_base_ours or show_ours_theirs or show_theirs_ours
  local need_base = show_base_ours or show_base_theirs
  local need_theirs = show_base_theirs or show_ours_theirs or show_theirs_ours

  -- Create temporary directory for files
  local tmpdir = vim.fn.tempname()
  vim.fn.mkdir(tmpdir, "p")

  -- Extract sections to temporary files as needed
  local ours_file, base_file, theirs_file

  if need_ours then
    local ours_end = conflict.ancestor and (conflict.ancestor - 1) or (conflict.separator - 1)
    local ours_lines = vim.api.nvim_buf_get_lines(bufnr, conflict.ours_start, ours_end, false)
    ours_file = tmpdir .. "/ours"
    vim.fn.writefile(ours_lines, ours_file)
  end

  if need_base then
    local base_lines = vim.api.nvim_buf_get_lines(bufnr, conflict.ancestor, conflict.separator - 1, false)
    base_file = tmpdir .. "/base"
    vim.fn.writefile(base_lines, base_file)
  end

  if need_theirs then
    local theirs_lines = vim.api.nvim_buf_get_lines(bufnr, conflict.separator, conflict.theirs_end - 1, false)
    theirs_file = tmpdir .. "/theirs"
    vim.fn.writefile(theirs_lines, theirs_file)
  end

  -- Determine if we're showing multiple diffs (omit headers if only one)
  local multiple = (show_base_ours and 1 or 0) + (show_base_theirs and 1 or 0) + (show_ours_theirs and 1 or 0) + (show_theirs_ours and 1 or 0) > 1

  -- Build output based on which diffs to show
  local output_parts = {}

  ---@type string|nil
  local title = " Conflict Diff " -- nil indicates we have encountered an error

  -- Use configured labels for diff titles
  local base_label = config.diff_view_labels.base
  local ours_label = config.diff_view_labels.ours
  local theirs_label = config.diff_view_labels.theirs

  if show_base_ours then
    title = generate_and_add_diff(base_file, ours_file, base_label .. " → " .. ours_label, output_parts, multiple, title)
  end

  if show_base_theirs then
    title = generate_and_add_diff(base_file, theirs_file, base_label .. " → " .. theirs_label, output_parts, multiple, title)
  end

  if show_ours_theirs then
    title = generate_and_add_diff(ours_file, theirs_file, ours_label .. " → " .. theirs_label, output_parts, multiple, title)
  end

  if show_theirs_ours then
    title = generate_and_add_diff(theirs_file, ours_file, theirs_label .. " → " .. ours_label, output_parts, multiple, title)
  end

  -- Clean up temp files
  vim.fn.delete(tmpdir, "rf")

  -- Early return if any diff failed
  if not title then
    return
  end

  -- Combine output
  local combined_output = table.concat(output_parts, "\n")

  display_diff_window(combined_output, title)
end

--- Show diff of our changes from base
function M.show_diff_ours()
  show_diff_internal(true, false, false, false)
end

--- Show diff of theirs changes from base
function M.show_diff_theirs()
  show_diff_internal(false, true, false, false)
end

--- Show both diffs (ours and theirs from base)
function M.show_diff_both()
  show_diff_internal(true, true, false, false)
end

--- Show direct diff between ours and theirs (no base required)
function M.show_diff_ours_vs_theirs()
  show_diff_internal(false, false, true, false)
end

--- Show direct diff between theirs and ours (no base required)
function M.show_diff_theirs_vs_ours()
  show_diff_internal(false, false, false, true)
end

return M
