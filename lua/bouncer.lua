local M = {}

-- Cache for module configurations to avoid repeated git commands
local config_cache = {}
local registry_config = {}
local registry_version_cache = {} -- Added this declaration

-- Pre-compile patterns for better performance
local patterns = {
  module_block = '(%s*)module%s*"[^"]*"%s*{',
  source_line = 'source%s*=%s*"(.-)"',
  version_line = 'version%s*=%s*"(.-)"',
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
    local org, name, provider = source_no_subdir:match(
      string.format("^%s/([^/]+)/([^/]+)/([^/]+)$", registry_config.host)
    )
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

--------------------------------------------------------------------------------
-- Helper to reorder source/version lines at the top of a module block.
--------------------------------------------------------------------------------
local function reorder_module_lines(block_lines, block_indent, is_local, mod_config)
  -- We'll gather any 'source' and 'version' lines, remove them from block_lines,
  -- then re-insert them at the top in the correct order.
  local out = {}
  local source_line = nil
  local version_line = nil

  -- Extract existing source/version lines, keep other lines in `rest`.
  local rest = {}
  for _, line in ipairs(block_lines) do
    local trimmed = line:match("^%s*(.-)$") or ""
    if trimmed:match("^source%s*=") then
      source_line = line
    elseif trimmed:match("^version%s*=") then
      version_line = line
    else
      table.insert(rest, line)
    end
  end

  if is_local then
    if not source_line then
      source_line = block_indent .. '  source = "' .. (mod_config.registry_source or "../../") .. '"'
    end
    version_line = block_indent .. '  version = "../../"'

  else
    -- Bouncing to registry:
    -- => Force 'source_line' to use mod_config.registry_source
    local registry_src = mod_config.registry_source or "???"
    source_line = block_indent .. '  source  = "' .. registry_src .. '"'

    -- If a version line existed, keep it unchanged.
    -- If none existed, we add a new one from the "latest version" logic.
    if not version_line then
      local latest_version, latest_major = get_latest_version_info(registry_src)
      if latest_version then
        local _, minor = parse_version(latest_version)
        if latest_major == 0 then
          version_line = block_indent .. '  version = "~> 0.' .. minor .. '"'
        else
          version_line = block_indent .. '  version = "~> ' .. latest_major .. '.0"'
        end
      end
    end
  end

  -- Now place them at the top if they exist
  if source_line then
    table.insert(out, source_line)
  end
  if version_line then
    table.insert(out, version_line)
  end

  -- Then append the rest of the lines
  vim.list_extend(out, rest)

  return out
end

--------------------------------------------------------------------------------
-- process_file
--------------------------------------------------------------------------------
local function process_file(file_path, mod_config, is_local)
  local lines = vim.fn.readfile(file_path)
  if not lines then
    vim.notify("Failed to read file: " .. file_path, vim.log.levels.ERROR)
    return false
  end

  local modified = false
  local in_module_block = false
  local new_lines = {}
  local block_indent = ""
  local module_block_lines = {} -- Temporarily store lines inside one module block

  for _, line in ipairs(lines) do
    if not in_module_block then
      -- Check if this line starts a module block
      local module_match = line:match(patterns.module_block)
      if module_match then
        -- Start collecting lines inside this block
        in_module_block = true
        block_indent = module_match -- e.g. the leading spaces
        table.insert(new_lines, line) -- keep the 'module "..." {' line
        module_block_lines = {}
      else
        table.insert(new_lines, line)
      end
    else
      -- We are inside a module block
      -- Check for end of module block
      local closing = '^' .. block_indent .. '}%s*$'
      if line:match(closing) then
        -- reorder module_block_lines with source/version at top
        local reordered = reorder_module_lines(module_block_lines, block_indent, is_local, mod_config)

        -- If anything changed from the original set, we'll consider it "modified".
        if #reordered ~= #module_block_lines then
          modified = true
        else
          for idx, val in ipairs(reordered) do
            if val ~= module_block_lines[idx] then
              modified = true
              break
            end
          end
        end

        -- Add the reordered lines + the closing brace
        vim.list_extend(new_lines, reordered)
        table.insert(new_lines, line) -- '}' line

        -- Done with this module block
        in_module_block = false
      else
        -- Still inside the module block, just collect the line
        table.insert(module_block_lines, line)
      end
    end
  end

  if modified then
    local ok = vim.fn.writefile(new_lines, file_path)
    if ok == -1 then
      vim.notify("Failed to write file: " .. file_path, vim.log.levels.ERROR)
      return false
    end
    return true
  end

  return false
end

--------------------------------------------------------------------------------
-- The multi-module bounce is unchanged.
--------------------------------------------------------------------------------
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
  local active_source = nil

  for _, line in ipairs(lines) do
    if not in_module_block then
      table.insert(new_lines, line)
      local module_match = line:match(patterns.module_block)
      if module_match then
        in_module_block = true
        block_indent = module_match
        active_source = nil
      end
      goto continue
    end

    if line:match('^' .. block_indent .. '}') then
      in_module_block = false
      table.insert(new_lines, line)
      goto continue
    end

    if line:match('%s*source%s*=') and not line:match('^%s*#') then
      local source = line:match('source%s*=%s*"([^"]+)"')
      if source then
        active_source = source
        table.insert(new_lines, line)

        local source_pattern
        if registry_config.is_private then
          source_pattern = "^" .. registry_config.host .. "/" .. registry_config.organization .. "/"
        else
          source_pattern = "^" .. registry_config.namespace .. "/"
        end

        if source:match(source_pattern) then
          local latest_version, latest_major = get_latest_version_info(source)
          if latest_version then
            local _, minor = parse_version(latest_version)
            local new_version_constraint
            if latest_major == 0 then
              new_version_constraint = "~> 0." .. minor
            else
              new_version_constraint = "~> " .. latest_major .. ".0"
            end
            table.insert(new_lines,
              string.format('%s  version = "%s"', block_indent, new_version_constraint))
            modified = true
          end
        end
      else
        table.insert(new_lines, line)
      end
      goto continue
    end

    if line:match('%s*version%s*=') and not line:match('^%s*#') then
      local source_pattern
      if registry_config.is_private then
        source_pattern = "^" .. registry_config.host .. "/" .. registry_config.organization .. "/"
      else
        source_pattern = "^" .. registry_config.namespace .. "/"
      end

      if not active_source or not active_source:match(source_pattern) then
        table.insert(new_lines, line)
      end
      goto continue
    end

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

--------------------------------------------------------------------------------
-- process_files_parallel (unchanged)
--------------------------------------------------------------------------------
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

--------------------------------------------------------------------------------
-- create_commands
--------------------------------------------------------------------------------
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

--------------------------------------------------------------------------------
-- M.setup
--------------------------------------------------------------------------------
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
      token_env = string.format(
        "TF_TOKEN_%s",
        string.gsub(opts.private_registry.host or "app_terraform_io", "%.", "_")
      )
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
