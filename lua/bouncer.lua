local M = {}

-- Configuration caches
local config_cache = {}
local registry_config = {}
local registry_version_cache = {}
local version_cache = {}
local missing_modules = {}

-- Pre-compile patterns for better performance
local patterns = {
  module_start = '^(%s*)module%s+"([^"]*)"[^{]*{%s*$',
  source_line = '^%s*source%s*=%s*"([^"]*)"',
  version_line = '^%s*version%s*=%s*"([^"]*)"',
  commented_source = '^%s*[/#]+%s*source%s*=%s*"([^"]*)"',
  commented_version = '^%s*[/#]+%s*version%s*=%s*"([^"]*)"',
  comment_line = "^%s*[/#]",
  empty_line = "^%s*$",
  closing_brace = '^%s*}%s*$',
}

-- Utility functions
local function parse_version(version_str)
  if version_cache[version_str] then
    return unpack(version_cache[version_str])
  end

  local major, minor, patch = version_str:match("^(%d+)%.(%d+)%.?(%d*)")
  major, minor = tonumber(major), tonumber(minor)
  patch = tonumber(patch) or 0

  version_cache[version_str] = { major, minor, patch }
  return major, minor, patch
end

local function is_version_greater(v1, v2)
  local major1, minor1, patch1 = parse_version(v1)
  local major2, minor2, patch2 = parse_version(v2)

  if major1 ~= major2 then
    return major1 > major2
  elseif minor1 ~= minor2 then
    return minor1 > minor2
  else
    return patch1 > patch2
  end
end

-- Configuration and registry functions
local function get_module_config()
  local cwd = vim.fn.getcwd()
  if config_cache[cwd] then
    return config_cache[cwd]
  end

  local output = vim.fn.system("basename `git rev-parse --show-toplevel`")
  if vim.v.shell_error ~= 0 then
    error("Failed to execute git command to get repository name")
  end

  local repo_name = output:gsub("%s+", "")
  local provider, module_name = repo_name:match("^terraform%-(.+)%-(.+)$")

  if not (provider and module_name) then
    error("Could not extract provider and module from repository name: " .. repo_name)
  end

  local base_path = string.format("%s/%s/%s",
    registry_config.namespace,
    module_name,
    provider)

  local config = {
    registry_source = base_path,
    module_name = module_name,
    provider = provider
  }

  config_cache[cwd] = config
  return config
end

local function get_latest_version_info(registry_source)
  if registry_version_cache[registry_source] then
    return unpack(registry_version_cache[registry_source])
  end

  local ok, plenary_http = pcall(require, "plenary.curl")
  if not ok then
    return nil, nil
  end

  local source_no_subdir = registry_source:match("^(.-)//") or registry_source
  local ns, name, provider = source_no_subdir:match("^([^/]+)/([^/]+)/([^/]+)$")

  if not (ns and name and provider) then
    return nil, nil
  end

  local registry_url = string.format(
    "https://registry.terraform.io/v1/modules/%s/%s/%s/versions",
    ns, name, provider
  )

  local result = plenary_http.get({
    url = registry_url,
    headers = { accept = "application/json" },
    timeout = 5000
  })

  if not result then
    return nil, nil
  end

  -- Handle module not found specifically
  if result.status == 404 then
    table.insert(missing_modules, registry_source)
    return nil, nil
  end

  if not (result.status == 200 and result.body) then
    return nil, nil
  end

  local ok_decode, data = pcall(vim.fn.json_decode, result.body)
  if not (ok_decode and data and data.modules and data.modules[1] and data.modules[1].versions) then
    return nil, nil
  end

  local latest_version = nil
  for _, version_info in ipairs(data.modules[1].versions) do
    if not latest_version or is_version_greater(version_info.version, latest_version) then
      latest_version = version_info.version
    end
  end

  if not latest_version then
    return nil, nil
  end

  local major_version = tonumber(latest_version:match("^(%d+)"))
  if not major_version then
    return nil, nil
  end

  registry_version_cache[registry_source] = { latest_version, major_version }
  return latest_version, major_version
end

-- Find terraform files in the current project
local function find_terraform_files()
  local commands = {
    "fd -t f main.tf",
    "find . -name main.tf"
  }

  for _, cmd in ipairs(commands) do
    local files = vim.fn.systemlist(cmd)
    if vim.v.shell_error == 0 and #files > 0 then
      return files
    end
  end

  return {}
end

-- Parse module blocks with cleaner logic
local function parse_modules(lines)
  local modules = {}
  local i = 1

  while i <= #lines do
    local line = lines[i]
    local indent, module_name = line:match(patterns.module_start)

    if indent and module_name then
      local module = {
        name = module_name,
        start_line = i,
        end_line = nil,
        indent = indent,
        source_value = nil,
        content_lines = {}
      }

      i = i + 1

      -- Parse module content with brace counting for proper nesting
      local brace_count = 1
      while i <= #lines and brace_count > 0 do
        local current_line = lines[i]

        -- Count braces to track nesting
        for char in current_line:gmatch("[{}]") do
          if char == "{" then
            brace_count = brace_count + 1
          else
            brace_count = brace_count - 1
          end
        end

        if brace_count == 0 then
          module.end_line = i
          break
        end

        -- Check for active source line
        local source = current_line:match(patterns.source_line)
        if source then
          module.source_value = source
        else
          -- Check for commented source line
          local commented_source = current_line:match(patterns.commented_source)
          if commented_source then
            module.source_value = commented_source
          end
        end

        -- Skip both active and commented source/version lines from content
        if not (current_line:match(patterns.source_line) or
              current_line:match(patterns.version_line) or
              current_line:match(patterns.commented_source) or
              current_line:match(patterns.commented_version)) then
          table.insert(module.content_lines, current_line)
        end

        i = i + 1
      end

      if module.end_line then
        table.insert(modules, module)
      end
    else
      i = i + 1
    end
  end

  return modules
end

-- Fix indentation for nested blocks
local function fix_content_indentation(content_lines, base_indent)
  local fixed_lines = {}
  local current_depth = 0

  for _, line in ipairs(content_lines) do
    if line:match(patterns.empty_line) then
      table.insert(fixed_lines, "")
    elseif line:match(patterns.comment_line) then
      -- Preserve comment lines with current depth
      local content = line:gsub("^%s*", "")
      table.insert(fixed_lines, base_indent .. string.rep("  ", current_depth) .. content)
    else
      local content = line:gsub("^%s*", "")

      -- Check if line starts with closing bracket/brace
      local starts_with_close = content:match("^[}%]]")

      -- Adjust depth before applying indentation for closing brackets/braces
      if starts_with_close then
        current_depth = math.max(0, current_depth - 1)
      end

      -- Apply indentation
      table.insert(fixed_lines, base_indent .. string.rep("  ", current_depth) .. content)

      -- Count all opening and closing brackets/braces on this line
      local net_depth_change = 0
      for char in content:gmatch("[{}%[%]]") do
        if char == "{" or char == "[" then
          net_depth_change = net_depth_change + 1
        elseif char == "}" or char == "]" then
          net_depth_change = net_depth_change - 1
        end
      end

      -- Update depth for next line (but don't double-count closing brackets we already handled)
      if starts_with_close then
        -- We already decremented for the first closing bracket, so add 1 back before applying net change
        current_depth = math.max(0, current_depth + net_depth_change + 1)
      else
        current_depth = math.max(0, current_depth + net_depth_change)
      end
    end
  end

  return fixed_lines
end

-- Generate clean module block
local function generate_module_block(module, new_source, version_constraint)
  local lines = {}
  local base_indent = module.indent .. "  "

  -- Module declaration
  table.insert(lines, module.indent .. 'module "' .. module.name .. '" {')

  -- Source line with consistent formatting (always first)
  table.insert(lines, base_indent .. 'source  = "' .. new_source .. '"')

  -- Version line (only for registry sources, always after source)
  if version_constraint then
    table.insert(lines, base_indent .. 'version = "' .. version_constraint .. '"')
  end

  -- Filter out source and version lines from content, keep everything else
  local other_content = {}
  for _, line in ipairs(module.content_lines) do
    if not (line:match(patterns.source_line) or line:match(patterns.version_line)) then
      table.insert(other_content, line)
    end
  end

  -- Remove leading empty lines from other content
  while #other_content > 0 and other_content[1]:match(patterns.empty_line) do
    table.remove(other_content, 1)
  end

  -- Add other content with proper indentation
  local fixed_content = fix_content_indentation(other_content, base_indent)
  if #fixed_content > 0 then
    table.insert(lines, "") -- Single empty line before other content
    for _, line in ipairs(fixed_content) do
      table.insert(lines, line)
    end
  end

  -- Closing brace
  table.insert(lines, module.indent .. "}")

  return lines
end

-- Generate version constraint based on latest version
local function generate_version_constraint(latest_version, latest_major)
  if not latest_version or not latest_major then
    return nil
  end

  return latest_major == 0
      and "~> 0." .. select(2, parse_version(latest_version))
      or "~> " .. latest_major .. ".0"
end

-- Process a single file with clean module replacement
local function process_file(file_path, mod_config, is_local)
  local lines = vim.fn.readfile(file_path)
  if not lines then
    return false
  end

  local modules = parse_modules(lines)
  local modified = false
  local new_lines = {}
  local current_line = 1

  for _, module in ipairs(modules) do
    local expected_source = mod_config.registry_source
    local should_process = false

    if is_local then
      -- For local bounce: process if source matches expected or is already local
      should_process = (module.source_value == expected_source or module.source_value == "../../")
    else
      -- For registry bounce: process if source matches expected, is local, or is missing/commented
      should_process = (module.source_value == expected_source or
        module.source_value == "../../" or
        not module.source_value)
    end

    -- Copy lines before this module
    while current_line < module.start_line do
      table.insert(new_lines, lines[current_line])
      current_line = current_line + 1
    end

    if should_process then
      local new_source, version_constraint

      if is_local then
        new_source = "../../"
        version_constraint = nil
      else
        new_source = mod_config.registry_source
        local latest_version, latest_major = get_latest_version_info(mod_config.registry_source)
        if latest_version then
          version_constraint = generate_version_constraint(latest_version, latest_major)
        else
          -- If we can't get version info (e.g., 404), don't modify this module
          should_process = false
        end
      end

      if should_process then
        -- Generate clean module block
        local module_lines = generate_module_block(module, new_source, version_constraint)
        for _, line in ipairs(module_lines) do
          table.insert(new_lines, line)
        end
        modified = true
      else
        -- Copy original module unchanged if version info failed
        while current_line <= module.end_line do
          table.insert(new_lines, lines[current_line])
          current_line = current_line + 1
        end
      end
    else
      -- Copy original module unchanged
      while current_line <= module.end_line do
        table.insert(new_lines, lines[current_line])
        current_line = current_line + 1
      end
    end

    current_line = module.end_line + 1
  end

  -- Copy remaining lines
  while current_line <= #lines do
    table.insert(new_lines, lines[current_line])
    current_line = current_line + 1
  end

  if modified then
    if vim.fn.writefile(new_lines, file_path) == -1 then
      return false
    end
  end

  return modified
end

-- Process all registry modules in a file
local function process_file_for_all_modules(file_path)
  local lines = vim.fn.readfile(file_path)
  if not lines then
    return false
  end

  local modules = parse_modules(lines)
  local modified = false
  local new_lines = {}
  local current_line = 1

  for _, module in ipairs(modules) do
    local is_registry_module = module.source_value and
        module.source_value:match("^" .. registry_config.namespace .. "/")

    -- Copy lines before this module
    while current_line < module.start_line do
      table.insert(new_lines, lines[current_line])
      current_line = current_line + 1
    end

    if is_registry_module then
      local latest_version, latest_major = get_latest_version_info(module.source_value)
      if latest_version then
        local version_constraint = generate_version_constraint(latest_version, latest_major)
        local module_lines = generate_module_block(module, module.source_value, version_constraint)

        for _, line in ipairs(module_lines) do
          table.insert(new_lines, line)
        end

        modified = true
      else
        -- Copy original if we can't get version info (e.g., 404 error)
        while current_line <= module.end_line do
          table.insert(new_lines, lines[current_line])
          current_line = current_line + 1
        end
      end
    else
      -- Copy non-registry modules unchanged
      while current_line <= module.end_line do
        table.insert(new_lines, lines[current_line])
        current_line = current_line + 1
      end
    end

    current_line = module.end_line + 1
  end

  -- Copy remaining lines
  while current_line <= #lines do
    table.insert(new_lines, lines[current_line])
    current_line = current_line + 1
  end

  if modified then
    if vim.fn.writefile(new_lines, file_path) == -1 then
      return false
    end
  end

  return modified
end

-- Show missing modules in a buffer
local function show_missing_modules()
  if #missing_modules == 0 then
    return
  end

  -- Create a new buffer
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = math.min(80, vim.o.columns - 4),
    height = math.min(#missing_modules + 4, vim.o.lines - 4),
    row = math.floor((vim.o.lines - (#missing_modules + 4)) / 2),
    col = math.floor((vim.o.columns - 80) / 2),
    style = 'minimal',
    border = 'rounded',
    title = ' Missing Modules ',
    title_pos = 'center'
  })

  -- Set buffer content
  local lines = {
    "The following modules were not found in the registry:",
    ""
  }
  for _, module in ipairs(missing_modules) do
    table.insert(lines, "  ✗ " .. module)
  end
  table.insert(lines, "")
  table.insert(lines, "Press 'q' to close")

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].buftype = 'nofile'

  -- Close on 'q'
  vim.api.nvim_buf_set_keymap(buf, 'n', 'q', '<cmd>close<cr>', { noremap = true, silent = true })

  -- Clear the list for next time
  missing_modules = {}
end
local function process_files(files_to_process, processor_fn, args)
  local modified_count = 0
  local errors = {}

  for _, file in ipairs(files_to_process) do
    local success, result = pcall(function()
      if args then
        return processor_fn(file, args.module_config, args.is_local)
      else
        return processor_fn(file)
      end
    end)

    if success then
      if result then
        modified_count = modified_count + 1
      end
    else
      table.insert(errors, string.format("Error processing %s: %s", file, result))
    end
  end

  -- Report errors only
  if #errors > 0 then
    for _, error_msg in ipairs(errors) do
      vim.notify(error_msg, vim.log.levels.ERROR)
    end
  end

  if modified_count > 0 then
    vim.cmd('checktime') -- Reload buffers if they've changed
  end

  show_missing_modules() -- Show any missing modules
end

-- Create user commands
local function create_commands()
  vim.api.nvim_create_user_command("BounceModuleToLocal", function()
    missing_modules = {} -- Clear previous results
    local ok, module_config = pcall(get_module_config)
    if not ok then
      vim.notify("Failed to get module config: " .. module_config, vim.log.levels.ERROR)
      return
    end

    local files = find_terraform_files()
    if #files == 0 then
      return
    end

    process_files(files, process_file, { module_config = module_config, is_local = true })
  end, { desc = "Switch module source to local (../../)" })

  vim.api.nvim_create_user_command("BounceModuleToRegistry", function()
    missing_modules = {} -- Clear previous results
    local ok, module_config = pcall(get_module_config)
    if not ok then
      vim.notify("Failed to get module config: " .. module_config, vim.log.levels.ERROR)
      return
    end

    local files = find_terraform_files()
    if #files == 0 then
      return
    end

    process_files(files, process_file, { module_config = module_config, is_local = false })
  end, { desc = "Switch module source to registry with latest version" })

  vim.api.nvim_create_user_command("BounceModulesToRegistry", function()
    missing_modules = {} -- Clear previous results
    local files = find_terraform_files()
    if #files == 0 then
      return
    end

    process_files(files, process_file_for_all_modules)
  end, { desc = "Update all registry modules to latest versions" })
end

-- Setup function
function M.setup(opts)
  opts = opts or {}

  if not opts.namespace then
    error("The 'namespace' configuration is required")
  end

  registry_config = {
    namespace = opts.namespace,
    host = opts.host or "registry.terraform.io"
  }

  create_commands()
end

return M

-- local M = {}
--
-- -- Configuration caches
-- local config_cache = {}
-- local registry_config = {}
-- local registry_version_cache = {}
-- local version_cache = {}
--
-- -- Pre-compile patterns for better performance
-- local patterns = {
--   module_start = '^(%s*)module%s+"([^"]*)"[^{]*{%s*$',
--   source_line = '^%s*source%s*=%s*"([^"]*)"',
--   version_line = '^%s*version%s*=%s*"([^"]*)"',
--   commented_source = '^%s*[/#]+%s*source%s*=%s*"([^"]*)"',
--   commented_version = '^%s*[/#]+%s*version%s*=%s*"([^"]*)"',
--   comment_line = "^%s*[/#]",
--   empty_line = "^%s*$",
--   closing_brace = '^%s*}%s*$',
-- }
--
-- -- Utility functions
-- local function parse_version(version_str)
--   if version_cache[version_str] then
--     return unpack(version_cache[version_str])
--   end
--
--   local major, minor, patch = version_str:match("^(%d+)%.(%d+)%.?(%d*)")
--   major, minor = tonumber(major), tonumber(minor)
--   patch = tonumber(patch) or 0
--
--   version_cache[version_str] = { major, minor, patch }
--   return major, minor, patch
-- end
--
-- local function is_version_greater(v1, v2)
--   local major1, minor1, patch1 = parse_version(v1)
--   local major2, minor2, patch2 = parse_version(v2)
--
--   if major1 ~= major2 then
--     return major1 > major2
--   elseif minor1 ~= minor2 then
--     return minor1 > minor2
--   else
--     return patch1 > patch2
--   end
-- end
--
-- -- Configuration and registry functions
-- local function get_module_config()
--   local cwd = vim.fn.getcwd()
--   if config_cache[cwd] then
--     return config_cache[cwd]
--   end
--
--   local output = vim.fn.system("basename `git rev-parse --show-toplevel`")
--   if vim.v.shell_error ~= 0 then
--     error("Failed to execute git command to get repository name")
--   end
--
--   local repo_name = output:gsub("%s+", "")
--   local provider, module_name = repo_name:match("^terraform%-(.+)%-(.+)$")
--
--   if not (provider and module_name) then
--     error("Could not extract provider and module from repository name: " .. repo_name)
--   end
--
--   local base_path = string.format("%s/%s/%s",
--     registry_config.namespace,
--     module_name,
--     provider)
--
--   local config = {
--     registry_source = base_path,
--     module_name = module_name,
--     provider = provider
--   }
--
--   config_cache[cwd] = config
--   return config
-- end
--
-- local function get_latest_version_info(registry_source)
--   if registry_version_cache[registry_source] then
--     return unpack(registry_version_cache[registry_source])
--   end
--
--   local ok, plenary_http = pcall(require, "plenary.curl")
--   if not ok then
--     vim.notify("plenary.curl is required but not available", vim.log.levels.ERROR)
--     return nil, nil
--   end
--
--   local source_no_subdir = registry_source:match("^(.-)//") or registry_source
--   local ns, name, provider = source_no_subdir:match("^([^/]+)/([^/]+)/([^/]+)$")
--
--   if not (ns and name and provider) then
--     vim.notify("Invalid registry source format: " .. registry_source, vim.log.levels.ERROR)
--     return nil, nil
--   end
--
--   local registry_url = string.format(
--     "https://registry.terraform.io/v1/modules/%s/%s/%s/versions",
--     ns, name, provider
--   )
--
--   local result = plenary_http.get({
--     url = registry_url,
--     headers = { accept = "application/json" },
--     timeout = 5000
--   })
--
--   if not (result and result.status == 200 and result.body) then
--     vim.notify(
--       string.format("Failed to fetch latest version for %s: %s",
--         registry_source, (result and tostring(result.status) or "No response")),
--       vim.log.levels.ERROR
--     )
--     return nil, nil
--   end
--
--   local ok_decode, data = pcall(vim.fn.json_decode, result.body)
--   if not (ok_decode and data and data.modules and data.modules[1] and data.modules[1].versions) then
--     vim.notify("Invalid response format from registry", vim.log.levels.ERROR)
--     return nil, nil
--   end
--
--   local latest_version = nil
--   for _, version_info in ipairs(data.modules[1].versions) do
--     if not latest_version or is_version_greater(version_info.version, latest_version) then
--       latest_version = version_info.version
--     end
--   end
--
--   if not latest_version then
--     vim.notify("No versions found for " .. registry_source, vim.log.levels.ERROR)
--     return nil, nil
--   end
--
--   local major_version = tonumber(latest_version:match("^(%d+)"))
--   if not major_version then
--     vim.notify("Invalid version format: " .. latest_version, vim.log.levels.ERROR)
--     return nil, nil
--   end
--
--   registry_version_cache[registry_source] = { latest_version, major_version }
--   return latest_version, major_version
-- end
--
-- -- Find terraform files in the current project
-- local function find_terraform_files()
--   local commands = {
--     "fd -t f main.tf",
--     "find . -name main.tf"
--   }
--
--   for _, cmd in ipairs(commands) do
--     local files = vim.fn.systemlist(cmd)
--     if vim.v.shell_error == 0 and #files > 0 then
--       return files
--     end
--   end
--
--   return {}
-- end
--
-- -- Parse module blocks with cleaner logic
-- local function parse_modules(lines)
--   local modules = {}
--   local i = 1
--
--   while i <= #lines do
--     local line = lines[i]
--     local indent, module_name = line:match(patterns.module_start)
--
--     if indent and module_name then
--       local module = {
--         name = module_name,
--         start_line = i,
--         end_line = nil,
--         indent = indent,
--         source_value = nil,
--         content_lines = {}
--       }
--
--       i = i + 1
--
--       -- Parse module content with brace counting for proper nesting
--       local brace_count = 1
--       while i <= #lines and brace_count > 0 do
--         local current_line = lines[i]
--
--         -- Count braces to track nesting
--         for char in current_line:gmatch("[{}]") do
--           if char == "{" then
--             brace_count = brace_count + 1
--           else
--             brace_count = brace_count - 1
--           end
--         end
--
--         if brace_count == 0 then
--           module.end_line = i
--           break
--         end
--
--         -- Check for active source line
--         local source = current_line:match(patterns.source_line)
--         if source then
--           module.source_value = source
--         else
--           -- Check for commented source line
--           local commented_source = current_line:match(patterns.commented_source)
--           if commented_source then
--             module.source_value = commented_source
--           end
--         end
--
--         -- Skip both active and commented source/version lines from content
--         if not (current_line:match(patterns.source_line) or
--               current_line:match(patterns.version_line) or
--               current_line:match(patterns.commented_source) or
--               current_line:match(patterns.commented_version)) then
--           table.insert(module.content_lines, current_line)
--         end
--
--         i = i + 1
--       end
--
--       if module.end_line then
--         table.insert(modules, module)
--       end
--     else
--       i = i + 1
--     end
--   end
--
--   return modules
-- end
--
-- local function fix_content_indentation(content_lines, base_indent)
--   local fixed_lines = {}
--   local current_depth = 0
--
--   for _, line in ipairs(content_lines) do
--     if line:match(patterns.empty_line) then
--       table.insert(fixed_lines, "")
--     elseif line:match(patterns.comment_line) then
--       -- Preserve comment lines with current depth
--       local content = line:gsub("^%s*", "")
--       table.insert(fixed_lines, base_indent .. string.rep("  ", current_depth) .. content)
--     else
--       local content = line:gsub("^%s*", "")
--
--       -- Check if line starts with closing bracket/brace
--       local starts_with_close = content:match("^[}%]]")
--
--       -- Adjust depth before applying indentation for closing brackets/braces
--       if starts_with_close then
--         current_depth = math.max(0, current_depth - 1)
--       end
--
--       -- Apply indentation
--       table.insert(fixed_lines, base_indent .. string.rep("  ", current_depth) .. content)
--
--       -- Count all opening and closing brackets/braces on this line
--       local net_depth_change = 0
--       for char in content:gmatch("[{}%[%]]") do
--         if char == "{" or char == "[" then
--           net_depth_change = net_depth_change + 1
--         elseif char == "}" or char == "]" then
--           net_depth_change = net_depth_change - 1
--         end
--       end
--
--       -- Update depth for next line (but don't double-count closing brackets we already handled)
--       if starts_with_close then
--         -- We already decremented for the first closing bracket, so add 1 back before applying net change
--         current_depth = math.max(0, current_depth + net_depth_change + 1)
--       else
--         current_depth = math.max(0, current_depth + net_depth_change)
--       end
--     end
--   end
--
--   return fixed_lines
-- end
--
-- -- Generate clean module block
-- local function generate_module_block(module, new_source, version_constraint)
--   local lines = {}
--   local base_indent = module.indent .. "  "
--
--   -- Module declaration
--   table.insert(lines, module.indent .. 'module "' .. module.name .. '" {')
--
--   -- Source line with consistent formatting (always first)
--   table.insert(lines, base_indent .. 'source  = "' .. new_source .. '"')
--
--   -- Version line (only for registry sources, always after source)
--   if version_constraint then
--     table.insert(lines, base_indent .. 'version = "' .. version_constraint .. '"')
--   end
--
--   -- Filter out source and version lines from content, keep everything else
--   local other_content = {}
--   for _, line in ipairs(module.content_lines) do
--     if not (line:match(patterns.source_line) or line:match(patterns.version_line)) then
--       table.insert(other_content, line)
--     end
--   end
--
--   -- Remove leading empty lines from other content
--   while #other_content > 0 and other_content[1]:match(patterns.empty_line) do
--     table.remove(other_content, 1)
--   end
--
--   -- Add other content with proper indentation
--   local fixed_content = fix_content_indentation(other_content, base_indent)
--   if #fixed_content > 0 then
--     table.insert(lines, "") -- Single empty line before other content
--     for _, line in ipairs(fixed_content) do
--       table.insert(lines, line)
--     end
--   end
--
--   -- Closing brace
--   table.insert(lines, module.indent .. "}")
--
--   return lines
-- end
--
-- -- Generate version constraint based on latest version
-- local function generate_version_constraint(latest_version, latest_major)
--   if not latest_version or not latest_major then
--     return nil
--   end
--
--   return latest_major == 0
--       and "~> 0." .. select(2, parse_version(latest_version))
--       or "~> " .. latest_major .. ".0"
-- end
--
-- -- Process a single file with clean module replacement
-- local function process_file(file_path, mod_config, is_local)
--   local lines = vim.fn.readfile(file_path)
--   if not lines then
--     return false
--   end
--
--   local modules = parse_modules(lines)
--   local modified = false
--   local new_lines = {}
--   local current_line = 1
--
--   for _, module in ipairs(modules) do
--     local expected_source = mod_config.registry_source
--     local should_process = false
--
--     if is_local then
--       -- For local bounce: process if source matches expected or is already local
--       should_process = (module.source_value == expected_source or module.source_value == "../../")
--     else
--       -- For registry bounce: process if source matches expected, is local, or is missing/commented
--       should_process = (module.source_value == expected_source or
--         module.source_value == "../../" or
--         not module.source_value)
--     end
--
--     -- Copy lines before this module
--     while current_line < module.start_line do
--       table.insert(new_lines, lines[current_line])
--       current_line = current_line + 1
--     end
--
--     if should_process then
--       local new_source, version_constraint
--
--       if is_local then
--         new_source = "../../"
--         version_constraint = nil
--       else
--         new_source = mod_config.registry_source
--         local latest_version, latest_major = get_latest_version_info(mod_config.registry_source)
--         if latest_version then
--           version_constraint = generate_version_constraint(latest_version, latest_major)
--         end
--       end
--
--       -- Generate clean module block
--       local module_lines = generate_module_block(module, new_source, version_constraint)
--       for _, line in ipairs(module_lines) do
--         table.insert(new_lines, line)
--       end
--
--       modified = true
--     else
--       -- Copy original module unchanged
--       while current_line <= module.end_line do
--         table.insert(new_lines, lines[current_line])
--         current_line = current_line + 1
--       end
--     end
--
--     current_line = module.end_line + 1
--   end
--
--   -- Copy remaining lines
--   while current_line <= #lines do
--     table.insert(new_lines, lines[current_line])
--     current_line = current_line + 1
--   end
--
--   if modified then
--     if vim.fn.writefile(new_lines, file_path) == -1 then
--       return false
--     end
--   end
--
--   return modified
-- end
--
-- -- Process all registry modules in a file
-- local function process_file_for_all_modules(file_path)
--   local lines = vim.fn.readfile(file_path)
--   if not lines then
--     return false
--   end
--
--   local modules = parse_modules(lines)
--   local modified = false
--   local new_lines = {}
--   local current_line = 1
--
--   for _, module in ipairs(modules) do
--     local is_registry_module = module.source_value and
--         module.source_value:match("^" .. registry_config.namespace .. "/")
--
--     -- Copy lines before this module
--     while current_line < module.start_line do
--       table.insert(new_lines, lines[current_line])
--       current_line = current_line + 1
--     end
--
--     if is_registry_module then
--       local latest_version, latest_major = get_latest_version_info(module.source_value)
--       if latest_version then
--         local version_constraint = generate_version_constraint(latest_version, latest_major)
--         local module_lines = generate_module_block(module, module.source_value, version_constraint)
--
--         for _, line in ipairs(module_lines) do
--           table.insert(new_lines, line)
--         end
--
--         modified = true
--       else
--         -- Copy original if we can't get version info
--         while current_line <= module.end_line do
--           table.insert(new_lines, lines[current_line])
--           current_line = current_line + 1
--         end
--       end
--     else
--       -- Copy non-registry modules unchanged
--       while current_line <= module.end_line do
--         table.insert(new_lines, lines[current_line])
--         current_line = current_line + 1
--       end
--     end
--
--     current_line = module.end_line + 1
--   end
--
--   -- Copy remaining lines
--   while current_line <= #lines do
--     table.insert(new_lines, lines[current_line])
--     current_line = current_line + 1
--   end
--
--   if modified then
--     if vim.fn.writefile(new_lines, file_path) == -1 then
--       return false
--     end
--   end
--
--   return modified
-- end
--
-- -- Process multiple files with better error handling
-- local function process_files(files_to_process, processor_fn, args)
--   local modified_count = 0
--   local errors = {}
--
--   for _, file in ipairs(files_to_process) do
--     local success, result = pcall(function()
--       if args then
--         return processor_fn(file, args.module_config, args.is_local)
--       else
--         return processor_fn(file)
--       end
--     end)
--
--     if success then
--       if result then
--         modified_count = modified_count + 1
--       end
--     else
--       table.insert(errors, string.format("Error processing %s: %s", file, result))
--     end
--   end
--
--   -- Report errors only
--   if #errors > 0 then
--     for _, error_msg in ipairs(errors) do
--       vim.notify(error_msg, vim.log.levels.ERROR)
--     end
--   end
--
--   if modified_count > 0 then
--     vim.cmd('checktime') -- Reload buffers if they've changed
--   end
-- end
--
-- -- Create user commands
-- local function create_commands()
--   vim.api.nvim_create_user_command("BounceModuleToLocal", function()
--     local ok, module_config = pcall(get_module_config)
--     if not ok then
--       vim.notify("Failed to get module config: " .. module_config, vim.log.levels.ERROR)
--       return
--     end
--
--     local files = find_terraform_files()
--     if #files == 0 then
--       return
--     end
--
--     process_files(files, process_file, { module_config = module_config, is_local = true })
--   end, { desc = "Switch module source to local (../../)" })
--
--   vim.api.nvim_create_user_command("BounceModuleToRegistry", function()
--     local ok, module_config = pcall(get_module_config)
--     if not ok then
--       vim.notify("Failed to get module config: " .. module_config, vim.log.levels.ERROR)
--       return
--     end
--
--     local files = find_terraform_files()
--     if #files == 0 then
--       return
--     end
--
--     process_files(files, process_file, { module_config = module_config, is_local = false })
--   end, { desc = "Switch module source to registry with latest version" })
--
--   vim.api.nvim_create_user_command("BounceModulesToRegistry", function()
--     local files = find_terraform_files()
--     if #files == 0 then
--       return
--     end
--
--     process_files(files, process_file_for_all_modules)
--   end, { desc = "Update all registry modules to latest versions" })
-- end
--
-- -- Setup function
-- function M.setup(opts)
--   opts = opts or {}
--
--   if not opts.namespace then
--     error("The 'namespace' configuration is required")
--   end
--
--   registry_config = {
--     namespace = opts.namespace,
--     host = opts.host or "registry.terraform.io"
--   }
--
--   create_commands()
-- end
--
-- return M
