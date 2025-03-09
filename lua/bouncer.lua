local M = {}

-- Cache for module configurations to avoid repeated git commands
local config_cache = {}
local registry_config = {}
local registry_version_cache = {}

-- Pre-compile patterns for better performance
local patterns = {
  module_block = '(%s*)module%s*"([^"]*)"',
  closing_brace = '^%s*}',
  source_line = '%s*source%s*=%s*"([^"]*)"',
  version_line = '%s*version%s*=%s*"([^"]*)"',
  version_constraint = "~>%s*(%d+)%.(%d+)",
}

-- Version parsing and caching
local version_cache = {}
local function parse_version(version_str)
  if version_cache[version_str] then
    return unpack(version_cache[version_str])
  end

  local major, minor, patch = version_str:match("^(%d+)%.(%d+)%.?(%d*)")
  major = tonumber(major)
  minor = tonumber(minor)
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

  local base_path
  if registry_config.is_private then
    base_path = string.format("%s/%s/%s/%s",
      registry_config.host,
      registry_config.organization,
      module_name,
      provider)
  else
    base_path = string.format("%s/%s/%s",
      registry_config.namespace,
      module_name,
      provider)
  end

  local config = {
    registry_source = base_path,
    module_name = module_name,
    provider = provider,
    is_private = registry_config.is_private
  }

  config_cache[cwd] = config
  return config
end

local function get_registry_token()
  -- Try environment variable first
  local token = os.getenv(registry_config.token_env)
  if token then return token end

  -- Try .terraformrc file
  local home = os.getenv("HOME")
  local f = io.open(home .. "/.terraformrc", "r")
  if not f then return nil end

  local content = f:read("*all")
  f:close()

  -- Match the multi-line credentials block format
  local pattern = 'credentials%s*"' .. registry_config.host .. '"%s*{[^}]*token%s*=%s*"([^"]+)"'
  local token_match = content:match(pattern)

  return token_match
end

local function get_latest_version_info(registry_source)
  if registry_version_cache[registry_source] then
    return unpack(registry_version_cache[registry_source])
  end

  local plenary_http = require("plenary.curl")
  local source_no_subdir = registry_source:match("^(.-)//") or registry_source

  local registry_url
  local headers = { accept = "application/json" }

  if registry_config.is_private then
    local org, name, provider = source_no_subdir:match(string.format("^%s/([^/]+)/([^/]+)/([^/]+)$", registry_config
    .host))
    if not (org and name and provider) then
      vim.notify("Invalid private registry source format: " .. registry_source, vim.log.levels.ERROR)
      return nil, nil
    end

    registry_url = string.format(
      "https://%s/api/registry/v1/modules/%s/%s/%s/versions",
      registry_config.host, org, name, provider
    )

    local token = get_registry_token()
    if token then
      headers.Authorization = "Bearer " .. token
    else
      vim.notify("No authentication token found for private registry", vim.log.levels.ERROR)
      return nil, nil
    end
  else
    local ns, name, provider = source_no_subdir:match("^([^/]+)/([^/]+)/([^/]+)$")
    if not (ns and name and provider) then
      vim.notify("Invalid public registry source format: " .. registry_source, vim.log.levels.ERROR)
      return nil, nil
    end

    registry_url = string.format(
      "https://registry.terraform.io/v1/modules/%s/%s/%s/versions",
      ns, name, provider
    )
  end

  local result = plenary_http.get({
    url = registry_url,
    headers = headers,
    timeout = 5000
  })

  if result and result.status == 200 and result.body then
    local ok, data = pcall(vim.fn.json_decode, result.body)
    if ok and data and data.modules and data.modules[1] and data.modules[1].versions then
      local latest_version = nil
      for _, version_info in ipairs(data.modules[1].versions) do
        if not latest_version or is_version_greater(version_info.version, latest_version) then
          latest_version = version_info.version
        end
      end

      if latest_version then
        local major_version = tonumber(latest_version:match("^(%d+)"))
        if major_version then
          registry_version_cache[registry_source] = { latest_version, major_version }
          return latest_version, major_version
        end
      end
    end
  end

  vim.notify(
    string.format("Failed to fetch latest version for %s: %s",
      registry_source, (result and tostring(result.status) or "No response")),
    vim.log.levels.ERROR
  )
  return nil, nil
end

local function find_terraform_files()
  local fd_cmd = "fd -t f main.tf"
  local files = vim.fn.systemlist(fd_cmd)

  if vim.v.shell_error ~= 0 then
    local find_cmd = "find . -name main.tf"
    files = vim.fn.systemlist(find_cmd)

    if vim.v.shell_error ~= 0 then
      vim.notify("Failed to find Terraform files using both fd and find", vim.log.levels.ERROR)
      return {}
    end
  end

  return files
end

-- Modified process_file that properly handles indentation issues
local function process_file(file_path, mod_config, is_local)
  local lines = vim.fn.readfile(file_path)
  if not lines then
    vim.notify("Failed to read file: " .. file_path, vim.log.levels.ERROR)
    return false
  end

  -- First pass: analyze the file and track modules
  local modules = {}
  local current_module = nil
  local in_module_block = false
  local brace_count = 0

  for i, line in ipairs(lines) do
    -- Check for module block start
    if not in_module_block then
      local indent, module_name = line:match(patterns.module_block)
      if indent and module_name then
        in_module_block = true
        current_module = {
          name = module_name,
          start_line = i,
          end_line = nil,
          indent = indent,
          source_line = nil,
          source_value = nil,
          version_lines = {}
        }

        -- Count opening brace if on the same line as the module declaration
        if line:match("{") then
          brace_count = brace_count + 1
        end
      end
    else
      -- Count braces to determine module block boundaries
      local open_braces = line:gsub("[^{]", ""):len()
      local close_braces = line:gsub("[^}]", ""):len()
      brace_count = brace_count + open_braces - close_braces

      -- Check for source and version lines
      if brace_count > 0 and current_module ~= nil then
        -- Don't process commented lines
        if not line:match("^%s*#") then
          -- Check for source line
          local source = line:match(patterns.source_line)
          if source then
            current_module.source_line = i
            current_module.source_value = source
          end

          -- Check for version line
          local version = line:match(patterns.version_line)
          if version then
            table.insert(current_module.version_lines, {
              line_number = i,
              value = version,
              indent = line:match("^(%s*)") -- Capture the line's indentation
            })
          end
        end
      end

      -- If we're leaving the module block
      if brace_count == 0 then
        in_module_block = false
        if current_module then
          current_module.end_line = i
          table.insert(modules, current_module)
          current_module = nil
        end
      end
    end
  end

  -- Second pass: modify the file based on the module analysis
  local modified = false
  local new_lines = {}
  local skip_lines = {} -- Lines to skip

  -- Prepare list of lines to modify/skip
  for _, module in ipairs(modules) do
    local expected_source = mod_config.registry_source

    -- Only process modules with matching source or local source
    if module.source_value == expected_source or module.source_value == "../../" then
      -- Mark source line for replacement
      skip_lines[module.source_line] = true

      -- Mark all version lines for removal
      for _, ver_line in ipairs(module.version_lines) do
        skip_lines[ver_line.line_number] = true
      end

      -- Mark all lines between source and the next attribute for removal (empty lines)
      if module.source_line then
        -- Find the next attribute after source and mark empty lines for skipping
        for i = module.source_line + 1, module.end_line do
          if not lines[i]:match("^%s*$") and not lines[i]:match("^%s*#") then
            break
          else
            -- Mark empty lines to skip
            skip_lines[i] = true
          end
        end
      end
    end
  end

  -- Variables to track blank line state
  local just_added_blank_line = false

  -- Process lines
  for i, line in ipairs(lines) do
    if skip_lines[i] then
      -- Find which module this line belongs to
      for _, module in ipairs(modules) do
        local expected_source = mod_config.registry_source

        if (module.source_value == expected_source or module.source_value == "../../") and
            (i == module.source_line) then
          -- This is a source line we need to modify
          if is_local then
            table.insert(new_lines, module.indent .. '  source  = "../../"')

            -- Add a single blank line after source when switching to local
            table.insert(new_lines, "")
            just_added_blank_line = true
          else
            table.insert(new_lines, module.indent .. '  source  = "' .. mod_config.registry_source .. '"')

            -- Add version line immediately after source when switching to registry
            local latest_version, latest_major = get_latest_version_info(mod_config.registry_source)
            if latest_version then
              local new_version_constraint = latest_major == 0
                  and "~> 0." .. select(2, parse_version(latest_version))
                  or "~> " .. latest_major .. ".0"
              table.insert(new_lines, module.indent .. '  version = "' .. new_version_constraint .. '"')

              -- Always add exactly one blank line after version
              table.insert(new_lines, "")
              just_added_blank_line = true
            end
          end

          modified = true
        end
      end
    else
      -- This is a regular line we should keep

      -- If we just added a blank line and this line is also blank, skip it
      if just_added_blank_line and line:match("^%s*$") then
        just_added_blank_line = false
      else
        table.insert(new_lines, line)
        -- Reset the flag if we hit a non-empty line
        if not line:match("^%s*$") then
          just_added_blank_line = false
        end
      end
    end
  end

  if modified then
    if vim.fn.writefile(new_lines, file_path) == -1 then
      vim.notify("Failed to write file: " .. file_path, vim.log.levels.ERROR)
      return false
    end
    return true
  end

  return false
end

-- Improved process_file_for_all_modules function
local function process_file_for_all_modules(file_path)
  local lines = vim.fn.readfile(file_path)
  if not lines then
    vim.notify("Failed to read file: " .. file_path, vim.log.levels.ERROR)
    return false
  end

  -- First pass: analyze the file and track all modules
  local modules = {}
  local current_module = nil
  local in_module_block = false
  local brace_count = 0

  for i, line in ipairs(lines) do
    -- Check for module block start
    if not in_module_block then
      local indent, module_name = line:match(patterns.module_block)
      if indent and module_name then
        in_module_block = true
        current_module = {
          name = module_name,
          start_line = i,
          end_line = nil,
          indent = indent,
          source_line = nil,
          source_value = nil,
          version_lines = {}
        }

        -- Count opening brace if on the same line as the module declaration
        if line:match("{") then
          brace_count = brace_count + 1
        end
      end
    else
      -- Count braces to determine module block boundaries
      local open_braces = line:gsub("[^{]", ""):len()
      local close_braces = line:gsub("[^}]", ""):len()
      brace_count = brace_count + open_braces - close_braces

      -- Check for source and version lines
      if brace_count > 0 and current_module ~= nil then
        -- Don't process commented lines
        if not line:match("^%s*#") then
          -- Check for source line
          local source = line:match(patterns.source_line)
          if source then
            current_module.source_line = i
            current_module.source_value = source
          end

          -- Check for version line
          local version = line:match(patterns.version_line)
          if version then
            table.insert(current_module.version_lines, {
              line_number = i,
              value = version,
              indent = line:match("^(%s*)")
            })
          end
        end
      end

      -- If we're leaving the module block
      if brace_count == 0 then
        in_module_block = false
        if current_module then
          current_module.end_line = i
          table.insert(modules, current_module)
          current_module = nil
        end
      end
    end
  end

  -- Second pass: update version lines for registry modules
  local modified = false
  local new_lines = {}
  local skip_lines = {}

  -- Find registry modules and mark lines for modification
  for _, module in ipairs(modules) do
    if module.source_value then
      local source_pattern
      if registry_config.is_private then
        source_pattern = "^" .. registry_config.host .. "/" .. registry_config.organization .. "/"
      else
        source_pattern = "^" .. registry_config.namespace .. "/"
      end

      -- Check if this is a registry module
      if module.source_value:match(source_pattern) then
        -- Mark all existing version lines for removal
        for _, ver_line in ipairs(module.version_lines) do
          skip_lines[ver_line.line_number] = true
        end

        -- Mark empty lines after version lines and between source and version for removal
        if #module.version_lines > 0 then
          local min_version_line = math.huge
          for _, ver_line in ipairs(module.version_lines) do
            min_version_line = math.min(min_version_line, ver_line.line_number)
          end

          -- Mark empty lines between source and version for removal
          for i = module.source_line + 1, min_version_line - 1 do
            skip_lines[i] = true
          end

          -- Mark empty lines after the last version line
          local end_line = module.end_line or #lines
          for i = module.version_lines[#module.version_lines].line_number + 1, end_line do
            if not lines[i]:match("^%s*$") and not lines[i]:match("^%s*#") then
              break
            else
              skip_lines[i] = true
            end
          end
        end

        -- Mark empty lines after source if there are no version lines
        if #module.version_lines == 0 and module.source_line then
          for i = module.source_line + 1, module.end_line or #lines do
            if not lines[i]:match("^%s*$") and not lines[i]:match("^%s*#") then
              break
            else
              skip_lines[i] = true
            end
          end
        end

        -- Mark the source line for adding a version after it
        skip_lines[module.source_line] = {
          is_source = true,
          source_value = module.source_value,
          indent = module.indent,
          has_version = #module.version_lines > 0
        }
      end
    end
  end

  -- Variables to track blank line state
  local just_added_blank_line = false

  -- Process each line to build the new file content
  for i, line in ipairs(lines) do
    if type(skip_lines[i]) == "table" and skip_lines[i].is_source then
      -- This is a source line for a registry module
      -- Add the original source line, but ensure proper double-space formatting
      local source_match = line:match(patterns.source_line)
      if source_match then
        -- Use the original source value but with consistent formatting
        table.insert(new_lines, skip_lines[i].indent .. '  source  = "' .. source_match .. '"')
      else
        -- Fallback if pattern doesn't match
        table.insert(new_lines, line)
      end

      -- Add a new version line with the latest version constraint
      local latest_version, latest_major = get_latest_version_info(skip_lines[i].source_value)
      if latest_version then
        local new_version_constraint = latest_major == 0
            and "~> 0." .. select(2, parse_version(latest_version))
            or "~> " .. latest_major .. ".0"
        table.insert(new_lines, skip_lines[i].indent .. '  version = "' .. new_version_constraint .. '"')

        -- Always add exactly one blank line after version
        table.insert(new_lines, "")
        just_added_blank_line = true

        modified = true
      end
    elseif skip_lines[i] == true then
      -- This is a line that should be skipped (like an old version line or blank line)
      modified = true
    else
      -- This is a regular line to keep

      -- If we just added a blank line and this line is also blank, skip it
      if just_added_blank_line and line:match("^%s*$") then
        just_added_blank_line = false
      else
        table.insert(new_lines, line)
        -- Reset the flag if we hit a non-empty line
        if not line:match("^%s*$") then
          just_added_blank_line = false
        end
      end
    end
  end

  if modified then
    if vim.fn.writefile(new_lines, file_path) == -1 then
      vim.notify("Failed to write file: " .. file_path, vim.log.levels.ERROR)
      return false
    end
    return true
  end

  return false
end

local function process_files_parallel(files_to_process, processor_fn, args)
  local modified_count = 0
  local completed = 0
  local total = #files_to_process

  for _, file in ipairs(files_to_process) do
    vim.schedule(function()
      local success
      if args then
        success = processor_fn(file, args.module_config, args.is_local)
      else
        success = processor_fn(file)
      end

      if success then
        modified_count = modified_count + 1
        vim.notify("Modified " .. file, vim.log.levels.INFO)
      end
      completed = completed + 1

      if completed == total then
        if modified_count > 0 then
          vim.notify(string.format("Modified %d files", modified_count), vim.log.levels.INFO)
        else
          vim.notify("No files were modified", vim.log.levels.WARN)
        end
        vim.cmd('edit')
      end
    end)
  end
end

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
    process_files_parallel(files, process_file, { module_config = module_config, is_local = true })
  end, {})

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
    process_files_parallel(files, process_file, { module_config = module_config, is_local = false })
  end, {})

  vim.api.nvim_create_user_command("BounceModulesToRegistry", function()
    local files = find_terraform_files()
    if #files == 0 then
      vim.notify("No Terraform files found", vim.log.levels.WARN)
      return
    end
    process_files_parallel(files, process_file_for_all_modules)
  end, {})
end

function M.setup(opts)
  opts = opts or {}

  if opts.private_registry then
    if not opts.private_registry.organization then
      error("Private registry configuration requires 'organization'")
    end

    registry_config = {
      is_private = true,
      host = opts.private_registry.host or "app.terraform.io",
      organization = opts.private_registry.organization,
      token_env = string.format("TF_TOKEN_%s",
        string.gsub(opts.private_registry.host or "app_terraform_io", "%.", "_"))
    }
  elseif opts.namespace then
    registry_config = {
      is_private = false,
      namespace = opts.namespace,
      host = "registry.terraform.io"
    }
  else
    error("Either 'namespace' or 'private_registry' configuration is required")
  end

  create_commands()
end

return M

-- local M = {}
--
-- -- Cache for module configurations to avoid repeated git commands
-- local config_cache = {}
-- local registry_config = {}
-- local registry_version_cache = {}
--
-- -- Pre-compile patterns for better performance
-- local patterns = {
--   module_block = '(%s*)module%s*"([^"]*)"',
--   closing_brace = '^%s*}',
--   source_line = '%s*source%s*=%s*"([^"]*)"',
--   version_line = '%s*version%s*=%s*"([^"]*)"',
--   version_constraint = "~>%s*(%d+)%.(%d+)",
-- }
--
-- -- Version parsing and caching
-- local version_cache = {}
-- local function parse_version(version_str)
--   if version_cache[version_str] then
--     return unpack(version_cache[version_str])
--   end
--
--   local major, minor, patch = version_str:match("^(%d+)%.(%d+)%.?(%d*)")
--   major = tonumber(major)
--   minor = tonumber(minor)
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
--   local base_path
--   if registry_config.is_private then
--     base_path = string.format("%s/%s/%s/%s",
--       registry_config.host,
--       registry_config.organization,
--       module_name,
--       provider)
--   else
--     base_path = string.format("%s/%s/%s",
--       registry_config.namespace,
--       module_name,
--       provider)
--   end
--
--   local config = {
--     registry_source = base_path,
--     module_name = module_name,
--     provider = provider,
--     is_private = registry_config.is_private
--   }
--
--   config_cache[cwd] = config
--   return config
-- end
--
-- local function get_registry_token()
--   -- Try environment variable first
--   local token = os.getenv(registry_config.token_env)
--   if token then return token end
--
--   -- Try .terraformrc file
--   local home = os.getenv("HOME")
--   local f = io.open(home .. "/.terraformrc", "r")
--   if not f then return nil end
--
--   local content = f:read("*all")
--   f:close()
--
--   -- Match the multi-line credentials block format
--   local pattern = 'credentials%s*"' .. registry_config.host .. '"%s*{[^}]*token%s*=%s*"([^"]+)"'
--   local token_match = content:match(pattern)
--
--   return token_match
-- end
--
-- local function get_latest_version_info(registry_source)
--   if registry_version_cache[registry_source] then
--     return unpack(registry_version_cache[registry_source])
--   end
--
--   local plenary_http = require("plenary.curl")
--   local source_no_subdir = registry_source:match("^(.-)//") or registry_source
--
--   local registry_url
--   local headers = { accept = "application/json" }
--
--   if registry_config.is_private then
--     local org, name, provider = source_no_subdir:match(string.format("^%s/([^/]+)/([^/]+)/([^/]+)$", registry_config
--     .host))
--     if not (org and name and provider) then
--       vim.notify("Invalid private registry source format: " .. registry_source, vim.log.levels.ERROR)
--       return nil, nil
--     end
--
--     registry_url = string.format(
--       "https://%s/api/registry/v1/modules/%s/%s/%s/versions",
--       registry_config.host, org, name, provider
--     )
--
--     local token = get_registry_token()
--     if token then
--       headers.Authorization = "Bearer " .. token
--     else
--       vim.notify("No authentication token found for private registry", vim.log.levels.ERROR)
--       return nil, nil
--     end
--   else
--     local ns, name, provider = source_no_subdir:match("^([^/]+)/([^/]+)/([^/]+)$")
--     if not (ns and name and provider) then
--       vim.notify("Invalid public registry source format: " .. registry_source, vim.log.levels.ERROR)
--       return nil, nil
--     end
--
--     registry_url = string.format(
--       "https://registry.terraform.io/v1/modules/%s/%s/%s/versions",
--       ns, name, provider
--     )
--   end
--
--   local result = plenary_http.get({
--     url = registry_url,
--     headers = headers,
--     timeout = 5000
--   })
--
--   if result and result.status == 200 and result.body then
--     local ok, data = pcall(vim.fn.json_decode, result.body)
--     if ok and data and data.modules and data.modules[1] and data.modules[1].versions then
--       local latest_version = nil
--       for _, version_info in ipairs(data.modules[1].versions) do
--         if not latest_version or is_version_greater(version_info.version, latest_version) then
--           latest_version = version_info.version
--         end
--       end
--
--       if latest_version then
--         local major_version = tonumber(latest_version:match("^(%d+)"))
--         if major_version then
--           registry_version_cache[registry_source] = { latest_version, major_version }
--           return latest_version, major_version
--         end
--       end
--     end
--   end
--
--   vim.notify(
--     string.format("Failed to fetch latest version for %s: %s",
--       registry_source, (result and tostring(result.status) or "No response")),
--     vim.log.levels.ERROR
--   )
--   return nil, nil
-- end
--
-- local function find_terraform_files()
--   local fd_cmd = "fd -t f main.tf"
--   local files = vim.fn.systemlist(fd_cmd)
--
--   if vim.v.shell_error ~= 0 then
--     local find_cmd = "find . -name main.tf"
--     files = vim.fn.systemlist(find_cmd)
--
--     if vim.v.shell_error ~= 0 then
--       vim.notify("Failed to find Terraform files using both fd and find", vim.log.levels.ERROR)
--       return {}
--     end
--   end
--
--   return files
-- end
--
-- -- Modified process_file that properly handles indentation issues
-- local function process_file(file_path, mod_config, is_local)
--   local lines = vim.fn.readfile(file_path)
--   if not lines then
--     vim.notify("Failed to read file: " .. file_path, vim.log.levels.ERROR)
--     return false
--   end
--
--   -- First pass: analyze the file and track modules
--   local modules = {}
--   local current_module = nil
--   local in_module_block = false
--   local brace_count = 0
--
--   for i, line in ipairs(lines) do
--     -- Check for module block start
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
--         -- Count opening brace if on the same line as the module declaration
--         if line:match("{") then
--           brace_count = brace_count + 1
--         end
--       end
--     else
--       -- Count braces to determine module block boundaries
--       local open_braces = line:gsub("[^{]", ""):len()
--       local close_braces = line:gsub("[^}]", ""):len()
--       brace_count = brace_count + open_braces - close_braces
--
--       -- Check for source and version lines
--       if brace_count > 0 and current_module ~= nil then
--         -- Don't process commented lines
--         if not line:match("^%s*#") then
--           -- Check for source line
--           local source = line:match(patterns.source_line)
--           if source then
--             current_module.source_line = i
--             current_module.source_value = source
--           end
--
--           -- Check for version line
--           local version = line:match(patterns.version_line)
--           if version and current_module ~= nil then
--             table.insert(current_module.version_lines, {
--               line_number = i,
--               value = version,
--               indent = line:match("^(%s*)") -- Capture the line's indentation
--             })
--           end
--         end
--       end
--
--       -- If we're leaving the module block
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
--   -- Second pass: modify the file based on the module analysis
--   local modified = false
--   local new_lines = {}
--   local skip_lines = {} -- Lines to skip
--
--   -- Prepare list of lines to modify/skip
--   for _, module in ipairs(modules) do
--     local expected_source = mod_config.registry_source
--
--     -- Only process modules with matching source or local source
--     if module.source_value == expected_source or module.source_value == "../../" then
--       -- Mark source line for replacement
--       skip_lines[module.source_line] = true
--
--       -- Mark all lines between source and the next attribute for removal (empty lines)
--       if module.source_line then
--         -- Find the next attribute after source and mark empty lines for skipping
--         for i = module.source_line + 1, module.end_line do
--           if not lines[i]:match("^%s*$") and not lines[i]:match("^%s*#") then
--             break
--           else
--             -- Mark empty lines to skip
--             skip_lines[i] = true
--           end
--         end
--       end
--
--       -- Mark all version lines for removal
--       for _, ver_line in ipairs(module.version_lines) do
--         skip_lines[ver_line.line_number] = true
--
--         -- Mark all lines between version and the next attribute for removal (empty lines)
--         local found_next = false
--         for i = ver_line.line_number + 1, module.end_line do
--           if not found_next then
--             if not lines[i]:match("^%s*$") and not lines[i]:match("^%s*#") then
--               found_next = true
--             else
--               -- Mark empty lines to skip
--               skip_lines[i] = true
--             end
--           end
--         end
--       end
--     end
--   end
--
--   -- Process lines
--   for i, line in ipairs(lines) do
--     if skip_lines[i] then
--       -- Find which module this line belongs to
--       for _, module in ipairs(modules) do
--         local expected_source = mod_config.registry_source
--
--         if (module.source_value == expected_source or module.source_value == "../../") and
--             (i == module.source_line) then
--           -- This is a source line we need to modify
--           if is_local then
--             table.insert(new_lines, module.indent .. '  source  = "../../"')
--             -- Add a single blank line after source when switching to local
--             table.insert(new_lines, "")
--           else
--             table.insert(new_lines, module.indent .. '  source  = "' .. mod_config.registry_source .. '"')
--
--             -- Add version line immediately after source when switching to registry
--             local latest_version, latest_major = get_latest_version_info(mod_config.registry_source)
--             if latest_version then
--               local new_version_constraint = latest_major == 0
--                   and "~> 0." .. select(2, parse_version(latest_version))
--                   or "~> " .. latest_major .. ".0"
--               table.insert(new_lines, module.indent .. '  version = "' .. new_version_constraint .. '"')
--               -- Add a single blank line after version
--               table.insert(new_lines, "")
--             end
--           end
--
--           modified = true
--         elseif (module.source_value == expected_source or module.source_value == "../../") then
--           -- Check if this is a version line for a module we're processing
--           local is_version_line = false
--           for _, ver_line in ipairs(module.version_lines) do
--             if i == ver_line.line_number then
--               is_version_line = true
--               break
--             end
--           end
--
--           -- Skip version lines completely (they're handled with the source line)
--           if is_version_line then
--             -- Do nothing, just skip
--             modified = true
--           else
--             -- Not a source or version line, but still in the skip list?
--             -- This is an empty line that should be skipped
--             modified = true
--           end
--         end
--       end
--     else
--       -- Regular line, just add it
--       table.insert(new_lines, line)
--     end
--   end
--
--   if modified then
--     if vim.fn.writefile(new_lines, file_path) == -1 then
--       vim.notify("Failed to write file: " .. file_path, vim.log.levels.ERROR)
--       return false
--     end
--     return true
--   end
--
--   return false
-- end
--
-- -- Improved process_file_for_all_modules function
-- local function process_file_for_all_modules(file_path)
--   local lines = vim.fn.readfile(file_path)
--   if not lines then
--     vim.notify("Failed to read file: " .. file_path, vim.log.levels.ERROR)
--     return false
--   end
--
--   -- First pass: analyze the file and track all modules
--   local modules = {}
--   local current_module = nil
--   local in_module_block = false
--   local brace_count = 0
--
--   for i, line in ipairs(lines) do
--     -- Check for module block start
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
--         -- Count opening brace if on the same line as the module declaration
--         if line:match("{") then
--           brace_count = brace_count + 1
--         end
--       end
--     else
--       -- Count braces to determine module block boundaries
--       local open_braces = line:gsub("[^{]", ""):len()
--       local close_braces = line:gsub("[^}]", ""):len()
--       brace_count = brace_count + open_braces - close_braces
--
--       -- Check for source and version lines
--       if brace_count > 0 and current_module ~= nil then
--         -- Don't process commented lines
--         if not line:match("^%s*#") then
--           -- Check for source line
--           local source = line:match(patterns.source_line)
--           if source then
--             current_module.source_line = i
--             current_module.source_value = source
--           end
--
--           -- Check for version line
--           local version = line:match(patterns.version_line)
--           if version then
--             table.insert(current_module.version_lines, {
--               line_number = i,
--               value = version,
--               indent = line:match("^(%s*)")
--             })
--           end
--         end
--       end
--
--       -- If we're leaving the module block
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
--   -- Second pass: update version lines for registry modules
--   local modified = false
--   local new_lines = {}
--   local skip_lines = {}
--
--   -- Find registry modules and mark lines for modification
--   for _, module in ipairs(modules) do
--     if module.source_value then
--       local source_pattern
--       if registry_config.is_private then
--         source_pattern = "^" .. registry_config.host .. "/" .. registry_config.organization .. "/"
--       else
--         source_pattern = "^" .. registry_config.namespace .. "/"
--       end
--
--       -- Check if this is a registry module
--       if module.source_value:match(source_pattern) then
--         -- Mark all existing version lines for removal
--         for _, ver_line in ipairs(module.version_lines) do
--           skip_lines[ver_line.line_number] = true
--         end
--
--         -- Mark the source line index for adding a version after it
--         skip_lines[module.source_line] = {
--           is_source = true,
--           source_value = module.source_value,
--           indent = module.indent,
--           has_version = #module.version_lines > 0
--         }
--       end
--     end
--   end
--
--   -- Process each line
--   for i, line in ipairs(lines) do
--     if type(skip_lines[i]) == "table" and skip_lines[i].is_source then
--       -- This is a source line for a registry module
--       -- Add the original source line
--       table.insert(new_lines, line)
--
--       -- Add a new version line with the latest version constraint
--       local latest_version, latest_major = get_latest_version_info(skip_lines[i].source_value)
--       if latest_version then
--         local new_version_constraint = latest_major == 0
--             and "~> 0." .. select(2, parse_version(latest_version))
--             or "~> " .. latest_major .. ".0"
--         table.insert(new_lines, skip_lines[i].indent .. '  version = "' .. new_version_constraint .. '"')
--         modified = true
--       end
--     elseif skip_lines[i] == true then
--       -- This is a version line that should be skipped
--       -- Don't add it to new_lines
--       modified = true
--     else
--       -- Regular line, just add it
--       table.insert(new_lines, line)
--     end
--   end
--
--   if modified then
--     if vim.fn.writefile(new_lines, file_path) == -1 then
--       vim.notify("Failed to write file: " .. file_path, vim.log.levels.ERROR)
--       return false
--     end
--     return true
--   end
--
--   return false
-- end
--
-- local function process_files_parallel(files_to_process, processor_fn, args)
--   local modified_count = 0
--   local completed = 0
--   local total = #files_to_process
--
--   for _, file in ipairs(files_to_process) do
--     vim.schedule(function()
--       local success
--       if args then
--         success = processor_fn(file, args.module_config, args.is_local)
--       else
--         success = processor_fn(file)
--       end
--
--       if success then
--         modified_count = modified_count + 1
--         vim.notify("Modified " .. file, vim.log.levels.INFO)
--       end
--       completed = completed + 1
--
--       if completed == total then
--         if modified_count > 0 then
--           vim.notify(string.format("Modified %d files", modified_count), vim.log.levels.INFO)
--         else
--           vim.notify("No files were modified", vim.log.levels.WARN)
--         end
--         vim.cmd('edit')
--       end
--     end)
--   end
-- end
--
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
--     process_files_parallel(files, process_file, { module_config = module_config, is_local = true })
--   end, {})
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
--     process_files_parallel(files, process_file, { module_config = module_config, is_local = false })
--   end, {})
--
--   vim.api.nvim_create_user_command("BounceModulesToRegistry", function()
--     local files = find_terraform_files()
--     if #files == 0 then
--       vim.notify("No Terraform files found", vim.log.levels.WARN)
--       return
--     end
--     process_files_parallel(files, process_file_for_all_modules)
--   end, {})
-- end
--
-- function M.setup(opts)
--   opts = opts or {}
--
--   if opts.private_registry then
--     if not opts.private_registry.organization then
--       error("Private registry configuration requires 'organization'")
--     end
--
--     registry_config = {
--       is_private = true,
--       host = opts.private_registry.host or "app.terraform.io",
--       organization = opts.private_registry.organization,
--       token_env = string.format("TF_TOKEN_%s",
--         string.gsub(opts.private_registry.host or "app_terraform_io", "%.", "_"))
--     }
--   elseif opts.namespace then
--     registry_config = {
--       is_private = false,
--       namespace = opts.namespace,
--       host = "registry.terraform.io"
--     }
--   else
--     error("Either 'namespace' or 'private_registry' configuration is required")
--   end
--
--   create_commands()
-- end
--
-- return M
