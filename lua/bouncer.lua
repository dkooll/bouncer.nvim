local M = {}

-- Cache for module configurations to avoid repeated git commands
local config_cache = {}
local registry_config = {}
local registry_version_cache = {}

-- Pre-compile patterns for better performance
local patterns = {
  -- More flexible module block pattern that captures the module name
  module_block = '(%s*)module%s*"([^"]*)"',
  -- Pattern for closing braces that will match regardless of indentation
  closing_brace = '^%s*}',
  -- Patterns for source and version lines that will match regardless of indentation
  source_line = '%s*source%s*=%s*"([^"]*)"',
  source_line_exact = '^%s*source%s*=%s*"([^"]*)"',
  version_line = '%s*version%s*=%s*"([^"]*)"',
  version_line_exact = '^%s*version%s*=%s*"([^"]*)"',
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

-- Improved process_file that handles inconsistent indentation
local function process_file(file_path, mod_config, is_local)
  local lines = vim.fn.readfile(file_path)
  if not lines then
    vim.notify("Failed to read file: " .. file_path, vim.log.levels.ERROR)
    return false
  end

  local modified = false
  local in_module_block = false
  -- No need to track module name
  local new_lines = {}
  local block_indent = ""
  local source_line_index = nil
  local in_appropriate_module = false
  local brace_count = 0

  for i, line in ipairs(lines) do
    -- Check for module block start
    if not in_module_block then
      local indent, module_name = line:match(patterns.module_block)
      if indent and module_name then
        in_module_block = true
        block_indent = indent
        -- Module name not needed for processing
        brace_count = 1

        -- Add the current line to new_lines
        table.insert(new_lines, line)

        -- Look ahead for opening brace if not on this line
        if not line:match("{") then
          local j = i + 1
          while j <= #lines and not lines[j]:match("{") do
            table.insert(new_lines, lines[j])
            j = j + 1
          end
          if j <= #lines then
            table.insert(new_lines, lines[j])
            brace_count = 1
          else
            -- No opening brace found, reset module block state
            in_module_block = false
          end
        end

        goto continue
      end

      -- If not in a module block, just add the line
      table.insert(new_lines, line)
      goto continue
    end

    -- Track brace count to properly detect module block boundaries
    local open_braces = select(2, line:gsub("{", ""))
    local close_braces = select(2, line:gsub("}", ""))
    brace_count = brace_count + open_braces - close_braces

    -- Check if we're leaving the module block
    if brace_count == 0 then
      in_module_block = false
      in_appropriate_module = false

      -- If we're at the end of a module block and need to modify it
      if in_appropriate_module and source_line_index then
        local start_idx = source_line_index
        local end_idx = #new_lines

        -- Find all version lines to remove (regardless of indentation)
        local version_indices = {}
        for j = start_idx, end_idx do
          local check_line = new_lines[j]
          if check_line and check_line:match(patterns.version_line) then
            table.insert(version_indices, j)
          end
        end

        -- Remove all version lines (starting from the end to avoid index shifting)
        for j = #version_indices, 1, -1 do
          table.remove(new_lines, version_indices[j])
        end

        -- Remove the source line (index might have changed if version lines were removed)
        for j = start_idx, #new_lines do
          local check_line = new_lines[j]
          if check_line and check_line:match(patterns.source_line) then
            table.remove(new_lines, j)
            source_line_index = j
            break
          end
        end

        -- Insert new source line with correct indentation
        if is_local then
          table.insert(new_lines, source_line_index, block_indent .. '  source = "../../"')
          -- No version line for local sources
        else
          table.insert(new_lines, source_line_index, string.format('%s  source = "%s"',
            block_indent, mod_config.registry_source))

          -- Add version constraint for registry source
          local latest_version, latest_major = get_latest_version_info(mod_config.registry_source)
          if latest_version then
            local new_version_constraint = latest_major == 0
                and "~> 0." .. select(2, parse_version(latest_version))
                or "~> " .. latest_major .. ".0"
            table.insert(new_lines, source_line_index + 1,
              string.format('%s  version = "%s"', block_indent, new_version_constraint))
          end
        end

        modified = true
      end

      -- Add the closing brace line
      table.insert(new_lines, line)
      goto continue
    end

    -- Check if this is a source line (be more lenient with pattern matching)
    local source_match = line:match(patterns.source_line)
    if source_match and not line:match("^%s*#") then
      local current_source = source_match

      -- Check if this is the module we're looking for
      local expected_source = mod_config.registry_source
      if current_source == expected_source or current_source == "../../" then
        in_appropriate_module = true
        source_line_index = #new_lines + 1 -- Position where the source line would be added
      end
    end

    -- Add the current line to new_lines
    table.insert(new_lines, line)

    ::continue::
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

-- Improved process_file_for_all_modules that handles inconsistent indentation
local function process_file_for_all_modules(file_path)
  local lines = vim.fn.readfile(file_path)
  if not lines then
    vim.notify("Failed to read file: " .. file_path, vim.log.levels.ERROR)
    return false
  end

  local modified = false
  local in_module_block = false
  local new_lines = {}
  local block_indent = ""
  local brace_count = 0

  -- Variables to track source and version lines within a module
  local module_sources = {}
  local module_versions = {}
  local current_module_index = 0

  for _, line in ipairs(lines) do
    -- Check for module block start
    if not in_module_block then
      local indent, module_name = line:match(patterns.module_block)
      if indent and module_name then
        in_module_block = true
        block_indent = indent
        brace_count = 1
        current_module_index = #new_lines + 1

        -- Initialize tracking for this module
        module_sources[current_module_index] = nil
        module_versions[current_module_index] = nil
      end
    else
      -- Track brace count
      local open_braces = select(2, line:gsub("{", ""))
      local close_braces = select(2, line:gsub("}", ""))
      brace_count = brace_count + open_braces - close_braces

      -- Check if we're leaving the module block
      if brace_count == 0 then
        in_module_block = false

        -- If we found a registry source but no version, add the version
        if module_sources[current_module_index] and not module_versions[current_module_index] then
          local source = module_sources[current_module_index].source
          local source_index = module_sources[current_module_index].index

          local source_pattern
          if registry_config.is_private then
            source_pattern = "^" .. registry_config.host .. "/" .. registry_config.organization .. "/"
          else
            source_pattern = "^" .. registry_config.namespace .. "/"
          end

          if source:match(source_pattern) then
            local latest_version, latest_major = get_latest_version_info(source)
            if latest_version then
              local new_version_constraint = latest_major == 0
                  and "~> 0." .. select(2, parse_version(latest_version))
                  or "~> " .. latest_major .. ".0"

              -- Insert the version line after the source line
              table.insert(new_lines, source_index + 1,
                string.format('%s  version = "%s"', block_indent, new_version_constraint))

              -- Adjust line indices for subsequent insertions
              for k, v in pairs(module_sources) do
                if v.index > source_index then
                  module_sources[k].index = v.index + 1
                end
              end
              for k, v in pairs(module_versions) do
                if v > source_index then
                  module_versions[k] = v + 1
                end
              end

              modified = true
            end
          end
        end
      end

      -- Track source and version lines
      if in_module_block then
        -- Check if line is a source definition and not commented out
        if line:match(patterns.source_line_exact) and not line:match('^%s*#') then
          local source = line:match(patterns.source_line)
          if source then
            module_sources[current_module_index] = {
              source = source,
              index = #new_lines + 1
            }
          end
        end

        -- Check if line is a version definition and not commented out
        if line:match(patterns.version_line_exact) and not line:match('^%s*#') then
          module_versions[current_module_index] = #new_lines + 1

          -- Check if we need to update an existing version line
          if module_sources[current_module_index] then
            local source = module_sources[current_module_index].source

            local source_pattern
            if registry_config.is_private then
              source_pattern = "^" .. registry_config.host .. "/" .. registry_config.organization .. "/"
            else
              source_pattern = "^" .. registry_config.namespace .. "/"
            end

            if source:match(source_pattern) then
              local latest_version, latest_major = get_latest_version_info(source)
              if latest_version then
                local new_version_constraint = latest_major == 0
                    and "~> 0." .. select(2, parse_version(latest_version))
                    or "~> " .. latest_major .. ".0"

                -- Replace the existing version line
                line = string.format('%s  version = "%s"', block_indent, new_version_constraint)
                modified = true
              end
            end
          end
        end
      end
    end

    -- Add the current line to new_lines
    table.insert(new_lines, line)
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
-- local registry_version_cache = {} -- Added this declaration
--
--
-- -- Pre-compile patterns for better performance
-- local patterns = {
--   module_block = '(%s*)module%s*"[^"]*"%s*{',
--   source_line = 'source%s*=%s*"(.-)"',
--   version_line = 'version%s*=%s*"(.-)"',
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
--       .host))
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
-- local function process_file(file_path, mod_config, is_local)
--   local lines = vim.fn.readfile(file_path)
--   if not lines then
--     vim.notify("Failed to read file: " .. file_path, vim.log.levels.ERROR)
--     return false
--   end
--
--   local modified = false
--   local in_module_block = false
--   local new_lines = {}
--   local block_indent = ""
--   local source_added = false
--
--   for i, line in ipairs(lines) do
--     if not in_module_block then
--       table.insert(new_lines, line)
--       local module_match = line:match(patterns.module_block)
--       if module_match and lines[i + 1] then
--         local expected_source = mod_config.is_private
--             and ('source%s*=%s*"' .. mod_config.registry_source .. '"')
--             or ('source%s*=%s*"' .. mod_config.registry_source .. '"')
--         if lines[i + 1]:match(expected_source) or
--             lines[i + 1]:match('source%s*=%s*"../../"') then
--           in_module_block = true
--           block_indent = module_match
--           source_added = false
--         end
--       end
--       goto continue
--     end
--
--     if line:match('^' .. block_indent .. '}') then
--       in_module_block = false
--       table.insert(new_lines, line)
--       goto continue
--     end
--
--     local line_indent = line:match('^(%s*)')
--     if line_indent ~= block_indent .. '  ' then
--       table.insert(new_lines, line)
--       goto continue
--     end
--
--     if line:match('%s*source%s*=') then
--       if not source_added then
--         if is_local then
--           table.insert(new_lines, block_indent .. '  source = "../../"')
--         else
--           table.insert(new_lines, string.format('%s  source  = "%s"',
--             block_indent, mod_config.registry_source))
--
--           local latest_version, latest_major = get_latest_version_info(mod_config.registry_source)
--           if latest_version then
--             local new_version_constraint = latest_major == 0
--                 and "~> 0." .. select(2, parse_version(latest_version))
--                 or "~> " .. latest_major .. ".0"
--             table.insert(new_lines, string.format('%s  version = "%s"',
--               block_indent, new_version_constraint))
--           end
--         end
--         source_added = true
--         modified = true
--       end
--       goto continue
--     end
--
--     if line:match('%s*version%s*=') then
--       goto continue
--     end
--
--     table.insert(new_lines, line)
--
--     ::continue::
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
-- local function process_file_for_all_modules(file_path)
--   local lines = vim.fn.readfile(file_path)
--   if not lines then
--     vim.notify("Failed to read file: " .. file_path, vim.log.levels.ERROR)
--     return false
--   end
--
--   local modified = false
--   local in_module_block = false
--   local new_lines = {}
--   local block_indent = ""
--   local active_source = nil
--
--   for _, line in ipairs(lines) do
--     if not in_module_block then
--       table.insert(new_lines, line)
--       local module_match = line:match(patterns.module_block)
--       if module_match then
--         in_module_block = true
--         block_indent = module_match
--         active_source = nil
--       end
--       goto continue
--     end
--
--     if line:match('^' .. block_indent .. '}') then
--       in_module_block = false
--       table.insert(new_lines, line)
--       goto continue
--     end
--
--     local line_indent = line:match('^(%s*)')
--     if line_indent ~= block_indent .. '  ' then
--       table.insert(new_lines, line)
--       goto continue
--     end
--
--     if line:match('%s*source%s*=') and not line:match('^%s*#') then
--       local source = line:match('source%s*=%s*"([^"]+)"')
--       if source then
--         active_source = source
--         table.insert(new_lines, line)
--
--         local source_pattern
--         if registry_config.is_private then
--           source_pattern = "^" .. registry_config.host .. "/" .. registry_config.organization .. "/"
--         else
--           source_pattern = "^" .. registry_config.namespace .. "/"
--         end
--
--         if source:match(source_pattern) then
--           local latest_version, latest_major = get_latest_version_info(source)
--           if latest_version then
--             local new_version_constraint = latest_major == 0
--                 and "~> 0." .. select(2, parse_version(latest_version))
--                 or "~> " .. latest_major .. ".0"
--
--             table.insert(new_lines, string.format('%s  version = "%s"', block_indent, new_version_constraint))
--             modified = true
--           end
--         end
--       else
--         table.insert(new_lines, line)
--       end
--       goto continue
--     end
--
--     if line:match('%s*version%s*=') and not line:match('^%s*#') then
--       local source_pattern
--       if registry_config.is_private then
--         source_pattern = "^" .. registry_config.host .. "/" .. registry_config.organization .. "/"
--       else
--         source_pattern = "^" .. registry_config.namespace .. "/"
--       end
--
--       if not active_source or not active_source:match(source_pattern) then
--         table.insert(new_lines, line)
--       end
--       goto continue
--     end
--
--     table.insert(new_lines, line)
--
--     ::continue::
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
