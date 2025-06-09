local M = {}

-- Configuration caches
local config_cache = {}
local registry_config = {}
local registry_version_cache = {}
local version_cache = {}

-- Pre-compile patterns for better performance
local patterns = {
  module_start = '^(%s*)module%s+"([^"]*)"[^{]*{%s*$',
  source_line = '^%s*source%s*=%s*"([^"]*)"',
  version_line = '^%s*version%s*=%s*"([^"]*)"',
  comment_line = "^%s*#",
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
  if config_cache[cwd] then return config_cache[cwd] end

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
    vim.notify("plenary.curl is required but not available", vim.log.levels.ERROR)
    return nil, nil
  end

  local source_no_subdir = registry_source:match("^(.-)//") or registry_source
  local ns, name, provider = source_no_subdir:match("^([^/]+)/([^/]+)/([^/]+)$")

  if not (ns and name and provider) then
    vim.notify("Invalid registry source format: " .. registry_source, vim.log.levels.ERROR)
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

  if not (result and result.status == 200 and result.body) then
    vim.notify(
      string.format("Failed to fetch latest version for %s: %s",
        registry_source, (result and tostring(result.status) or "No response")),
      vim.log.levels.ERROR
    )
    return nil, nil
  end

  local ok_decode, data = pcall(vim.fn.json_decode, result.body)
  if not (ok_decode and data and data.modules and data.modules[1] and data.modules[1].versions) then
    vim.notify("Invalid response format from registry", vim.log.levels.ERROR)
    return nil, nil
  end

  local latest_version = nil
  for _, version_info in ipairs(data.modules[1].versions) do
    if not latest_version or is_version_greater(version_info.version, latest_version) then
      latest_version = version_info.version
    end
  end

  if not latest_version then
    vim.notify("No versions found for " .. registry_source, vim.log.levels.ERROR)
    return nil, nil
  end

  local major_version = tonumber(latest_version:match("^(%d+)"))
  if not major_version then
    vim.notify("Invalid version format: " .. latest_version, vim.log.levels.ERROR)
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

  vim.notify("Failed to find Terraform files using both fd and find", vim.log.levels.ERROR)
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
        lines_before_source = {},
        lines_after_source = {},
        has_other_content = false
      }

      i = i + 1
      local found_source = false

      -- Parse module content
      while i <= #lines do
        local current_line = lines[i]

        if current_line:match(patterns.closing_brace) then
          module.end_line = i
          break
        end

        -- Check for source line
        local source = current_line:match(patterns.source_line)
        if source then
          module.source_value = source
          found_source = true
        elseif current_line:match(patterns.version_line) then
          -- Skip version lines - we'll regenerate them
        elseif not (current_line:match(patterns.empty_line) or current_line:match(patterns.comment_line)) then
          -- This is actual content we need to preserve
          if not found_source then
            table.insert(module.lines_before_source, current_line)
          else
            table.insert(module.lines_after_source, current_line)
            module.has_other_content = true
          end
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

-- Generate clean module block
local function generate_module_block(module, new_source, version_constraint)
  local lines = {}
  local base_indent = module.indent .. "  "

  -- Module declaration
  table.insert(lines, module.indent .. 'module "' .. module.name .. '" {')

  -- Lines before source (if any)
  for _, line in ipairs(module.lines_before_source) do
    table.insert(lines, line)
  end

  -- Source line with consistent formatting
  table.insert(lines, base_indent .. 'source  = "' .. new_source .. '"')

  -- Version line (only for registry sources)
  if version_constraint then
    table.insert(lines, base_indent .. 'version = "' .. version_constraint .. '"')
  end

  -- Empty line only if there's other content after
  if module.has_other_content then
    table.insert(lines, "")
  end

  -- Lines after source
  for _, line in ipairs(module.lines_after_source) do
    table.insert(lines, line)
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
    vim.notify("Failed to read file: " .. file_path, vim.log.levels.ERROR)
    return false
  end

  local modules = parse_modules(lines)
  local modified = false
  local new_lines = {}
  local current_line = 1

  for _, module in ipairs(modules) do
    local expected_source = mod_config.registry_source
    local should_process = (module.source_value == expected_source or module.source_value == "../../")

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
        end
      end

      -- Generate clean module block
      local module_lines = generate_module_block(module, new_source, version_constraint)
      for _, line in ipairs(module_lines) do
        table.insert(new_lines, line)
      end

      modified = true
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
      vim.notify("Failed to write file: " .. file_path, vim.log.levels.ERROR)
      return false
    end
  end

  return modified
end

-- Process all registry modules in a file
local function process_file_for_all_modules(file_path)
  local lines = vim.fn.readfile(file_path)
  if not lines then
    vim.notify("Failed to read file: " .. file_path, vim.log.levels.ERROR)
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
        -- Copy original if we can't get version info
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
      vim.notify("Failed to write file: " .. file_path, vim.log.levels.ERROR)
      return false
    end
  end

  return modified
end

-- Process multiple files with better error handling
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
        vim.notify("Modified " .. file, vim.log.levels.INFO)
      end
    else
      table.insert(errors, string.format("Error processing %s: %s", file, result))
    end
  end

  -- Report results
  if #errors > 0 then
    for _, error_msg in ipairs(errors) do
      vim.notify(error_msg, vim.log.levels.ERROR)
    end
  end

  if modified_count > 0 then
    vim.notify(string.format("Modified %d files", modified_count), vim.log.levels.INFO)
    vim.cmd('checktime') -- Reload buffers if they've changed
  else
    vim.notify("No files were modified", vim.log.levels.WARN)
  end
end

-- Create user commands
local function create_commands()
  vim.api.nvim_create_user_command("BounceModuleToLocal", function()
    local ok, module_config = pcall(get_module_config)
    if not ok then
      vim.notify("Failed to get module config: " .. module_config, vim.log.levels.ERROR)
      return
    end

    local files = find_terraform_files()
    if #files == 0 then
      vim.notify("No Terraform files found", vim.log.levels.WARN)
      return
    end

    process_files(files, process_file, { module_config = module_config, is_local = true })
  end, { desc = "Switch module source to local (../../)" })

  vim.api.nvim_create_user_command("BounceModuleToRegistry", function()
    local ok, module_config = pcall(get_module_config)
    if not ok then
      vim.notify("Failed to get module config: " .. module_config, vim.log.levels.ERROR)
      return
    end

    local files = find_terraform_files()
    if #files == 0 then
      vim.notify("No Terraform files found", vim.log.levels.WARN)
      return
    end

    process_files(files, process_file, { module_config = module_config, is_local = false })
  end, { desc = "Switch module source to registry with latest version" })

  vim.api.nvim_create_user_command("BounceModulesToRegistry", function()
    local files = find_terraform_files()
    if #files == 0 then
      vim.notify("No Terraform files found", vim.log.levels.WARN)
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
--   module_block = '(%s*)module%s*"([^"]*)"',
--   source_line = '%s*source%s*=%s*"([^"]*)"',
--   version_line = '%s*version%s*=%s*"([^"]*)"',
--   version_constraint = "~>%s*(%d+)%.(%d+)",
--   comment_line = "^%s*#",
--   empty_line = "^%s*$",
--   indent_capture = "^(%s*)",
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
-- local function count_braces(line)
--   local open_count, close_count = 0, 0
--   for char in line:gmatch("[{}]") do
--     if char == "{" then
--       open_count = open_count + 1
--     else
--       close_count = close_count + 1
--     end
--   end
--   return open_count, close_count
-- end
--
-- -- Configuration and registry functions
-- local function get_module_config()
--   local cwd = vim.fn.getcwd()
--   if config_cache[cwd] then return config_cache[cwd] end
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
--   -- Try fd first, fallback to find
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
--   vim.notify("Failed to find Terraform files using both fd and find", vim.log.levels.ERROR)
--   return {}
-- end
--
-- -- Common analysis function used by both processing functions
-- local function analyze_terraform_file(lines)
--   local modules = {}
--   local current_module = nil
--   local in_module_block = false
--   local brace_count = 0
--
--   for i, line in ipairs(lines) do
--     if not in_module_block then
--       local indent, module_name = line:match(patterns.module_block)
--       if indent and module_name then
--         in_module_block = true
--         current_module = {
--           name = module_name,
--           start_line = i,
--           end_line = nil,
--           indent = indent,
--           source_line = nil,
--           source_value = nil,
--           version_lines = {}
--         }
--
--         brace_count = line:match("{") and 1 or 0
--       end
--     else
--       local open_braces, close_braces = count_braces(line)
--       brace_count = brace_count + open_braces - close_braces
--
--       if brace_count > 0 and current_module and not line:match(patterns.comment_line) then
--         local source = line:match(patterns.source_line)
--         if source then
--           current_module.source_line = i
--           current_module.source_value = source
--         end
--
--         local version = line:match(patterns.version_line)
--         if version then
--           table.insert(current_module.version_lines, {
--             line_number = i,
--             value = version,
--             indent = line:match(patterns.indent_capture)
--           })
--         end
--       end
--
--       if brace_count == 0 then
--         in_module_block = false
--         if current_module then
--           current_module.end_line = i
--           table.insert(modules, current_module)
--           current_module = nil
--         end
--       end
--     end
--   end
--
--   return modules
-- end
--
-- -- Common function to mark blank lines for removal
-- local function mark_blank_lines_for_removal(module, lines, skip_lines)
--   if #module.version_lines == 0 then return skip_lines end
--
--   local min_version_line = math.huge
--   for _, ver_line in ipairs(module.version_lines) do
--     min_version_line = math.min(min_version_line, ver_line.line_number)
--   end
--
--   -- Mark empty lines between source and version
--   for i = module.source_line + 1, min_version_line - 1 do
--     if i <= #lines and lines[i]:match(patterns.empty_line) then
--       skip_lines[i] = true
--     end
--   end
--
--   -- Mark redundant empty lines after version
--   local last_line = module.source_line
--   for _, ver_line in ipairs(module.version_lines) do
--     last_line = math.max(last_line, ver_line.line_number)
--   end
--
--   -- Mark empty lines after the last version line
--   local found_next_attr = false
--   for i = last_line + 1, module.end_line or #lines do
--     if not found_next_attr then
--       if not (lines[i]:match(patterns.empty_line) or lines[i]:match(patterns.comment_line)) then
--         found_next_attr = true
--       else
--         skip_lines[i] = true
--       end
--     end
--   end
--
--   return skip_lines
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
-- -- Process a single file, focused on a specific module
-- local function process_file(file_path, mod_config, is_local)
--   local lines = vim.fn.readfile(file_path)
--   if not lines then
--     vim.notify("Failed to read file: " .. file_path, vim.log.levels.ERROR)
--     return false
--   end
--
--   local modules = analyze_terraform_file(lines)
--   local modified = false
--   local new_lines = {}
--   local skip_lines = {}
--
--   -- Prepare list of lines to modify/skip
--   for _, module in ipairs(modules) do
--     local expected_source = mod_config.registry_source
--
--     if module.source_value == expected_source or module.source_value == "../../" then
--       skip_lines[module.source_line] = true
--
--       for _, ver_line in ipairs(module.version_lines) do
--         skip_lines[ver_line.line_number] = true
--       end
--
--       skip_lines = mark_blank_lines_for_removal(module, lines, skip_lines)
--     end
--   end
--
--   local just_added_blank_line = false
--
--   for i, line in ipairs(lines) do
--     if skip_lines[i] then
--       for _, module in ipairs(modules) do
--         local expected_source = mod_config.registry_source
--
--         if (module.source_value == expected_source or module.source_value == "../../") and
--             (i == module.source_line) then
--           if is_local then
--             table.insert(new_lines, module.indent .. '  source  = "../../"')
--             table.insert(new_lines, "")
--             just_added_blank_line = true
--           else
--             table.insert(new_lines, module.indent .. '  source  = "' .. mod_config.registry_source .. '"')
--
--             local latest_version, latest_major = get_latest_version_info(mod_config.registry_source)
--             if latest_version then
--               local version_constraint = generate_version_constraint(latest_version, latest_major)
--               if version_constraint then
--                 table.insert(new_lines, module.indent .. '  version = "' .. version_constraint .. '"')
--                 table.insert(new_lines, "")
--                 just_added_blank_line = true
--               end
--             end
--           end
--
--           modified = true
--         end
--       end
--     else
--       if just_added_blank_line and line:match(patterns.empty_line) then
--         just_added_blank_line = false
--       else
--         table.insert(new_lines, line)
--         if not line:match(patterns.empty_line) then
--           just_added_blank_line = false
--         end
--       end
--     end
--   end
--
--   if modified then
--     if vim.fn.writefile(new_lines, file_path) == -1 then
--       vim.notify("Failed to write file: " .. file_path, vim.log.levels.ERROR)
--       return false
--     end
--   end
--
--   return modified
-- end
--
-- -- Process a file for all modules
-- local function process_file_for_all_modules(file_path)
--   local lines = vim.fn.readfile(file_path)
--   if not lines then
--     vim.notify("Failed to read file: " .. file_path, vim.log.levels.ERROR)
--     return false
--   end
--
--   local modules = analyze_terraform_file(lines)
--   local modified = false
--   local new_lines = {}
--   local skip_lines = {}
--
--   -- Find registry modules and mark lines for modification
--   for _, module in ipairs(modules) do
--     if module.source_value and module.source_value:match("^" .. registry_config.namespace .. "/") then
--       for _, ver_line in ipairs(module.version_lines) do
--         skip_lines[ver_line.line_number] = true
--       end
--
--       skip_lines = mark_blank_lines_for_removal(module, lines, skip_lines)
--
--       skip_lines[module.source_line] = {
--         is_source = true,
--         source_value = module.source_value,
--         indent = module.indent,
--         has_version = #module.version_lines > 0
--       }
--     end
--   end
--
--   local just_added_blank_line = false
--
--   for i, line in ipairs(lines) do
--     if type(skip_lines[i]) == "table" and skip_lines[i].is_source then
--       local source_match = line:match(patterns.source_line)
--       if source_match then
--         table.insert(new_lines, skip_lines[i].indent .. '  source  = "' .. source_match .. '"')
--       else
--         table.insert(new_lines, line)
--       end
--
--       local latest_version, latest_major = get_latest_version_info(skip_lines[i].source_value)
--       if latest_version then
--         local version_constraint = generate_version_constraint(latest_version, latest_major)
--         if version_constraint then
--           table.insert(new_lines, skip_lines[i].indent .. '  version = "' .. version_constraint .. '"')
--           table.insert(new_lines, "")
--           just_added_blank_line = true
--           modified = true
--         end
--       end
--     elseif skip_lines[i] == true then
--       modified = true
--     else
--       if just_added_blank_line and line:match(patterns.empty_line) then
--         just_added_blank_line = false
--       else
--         table.insert(new_lines, line)
--         if not line:match(patterns.empty_line) then
--           just_added_blank_line = false
--         end
--       end
--     end
--   end
--
--   if modified then
--     if vim.fn.writefile(new_lines, file_path) == -1 then
--       vim.notify("Failed to write file: " .. file_path, vim.log.levels.ERROR)
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
--         vim.notify("Modified " .. file, vim.log.levels.INFO)
--       end
--     else
--       table.insert(errors, string.format("Error processing %s: %s", file, result))
--     end
--   end
--
--   -- Report results
--   if #errors > 0 then
--     for _, error_msg in ipairs(errors) do
--       vim.notify(error_msg, vim.log.levels.ERROR)
--     end
--   end
--
--   if modified_count > 0 then
--     vim.notify(string.format("Modified %d files", modified_count), vim.log.levels.INFO)
--     vim.cmd('checktime') -- Reload buffers if they've changed
--   else
--     vim.notify("No files were modified", vim.log.levels.WARN)
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
--       vim.notify("No Terraform files found", vim.log.levels.WARN)
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
--       vim.notify("No Terraform files found", vim.log.levels.WARN)
--       return
--     end
--
--     process_files(files, process_file, { module_config = module_config, is_local = false })
--   end, { desc = "Switch module source to registry with latest version" })
--
--   vim.api.nvim_create_user_command("BounceModulesToRegistry", function()
--     local files = find_terraform_files()
--     if #files == 0 then
--       vim.notify("No Terraform files found", vim.log.levels.WARN)
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
