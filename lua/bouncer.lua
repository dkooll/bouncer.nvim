local M = {}

-- Cache for module configurations to avoid repeated git commands
local config_cache = {}
local namespace

-- Pre-compile patterns for better performance
local patterns = {
  module_block = '(%s*)module%s*"[^"]*"%s*{',
  source_line = 'source%s*=%s*"(.-)"',
  version_line = 'version%s*=%s*"(.-)"',
  version_constraint = "~>%s*(%d+)%.(%d+)",
}

-- Memoized version parsing
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

  if major1 ~= major2 then return major1 > major2
  elseif minor1 ~= minor2 then return minor1 > minor2
  else return patch1 > patch2 end
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

  local config = {
    registry_source = string.format("%s/%s/%s", namespace, module_name, provider),
    module_name = module_name,
    provider = provider,
    namespace = namespace
  }

  config_cache[cwd] = config
  return config
end

-- Registry version cache
local registry_version_cache = {}
local function get_latest_version_info(registry_source)
  if registry_version_cache[registry_source] then
    return unpack(registry_version_cache[registry_source])
  end

  local plenary_http = require("plenary.curl")
  local source_no_subdir = registry_source:match("^(.-)//") or registry_source
  local ns, module_name, provider = source_no_subdir:match("^([^/]+)/([^/]+)/([^/]+)$")

  if not (ns and module_name and provider) then
    vim.notify("Invalid registry source format: " .. registry_source, vim.log.levels.ERROR)
    return nil, nil
  end

  local registry_url = string.format(
    "https://registry.terraform.io/v1/modules/%s/%s/%s/versions",
    ns, module_name, provider
  )

  local result = plenary_http.get({
    url = registry_url,
    accept = "application/json",
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

local function process_file(file_path, module_config, is_local)
  local lines = vim.fn.readfile(file_path)
  if not lines then
    vim.notify("Failed to read file: " .. file_path, vim.log.levels.ERROR)
    return false
  end

  local modified = false
  local in_module_block = false
  local new_lines = {}
  local block_indent = ""
  local source_added = false

  for i, line in ipairs(lines) do
    -- Check for module block start
    if not in_module_block then
      table.insert(new_lines, line)
      local module_match = line:match(patterns.module_block)
      if module_match and lines[i + 1] then
        if lines[i + 1]:match('source%s*=%s*"' .. module_config.registry_source .. '"') or
           lines[i + 1]:match('source%s*=%s*"../../"') then
          in_module_block = true
          block_indent = module_match
          source_added = false
        end
      end
      goto continue
    end

    -- Check for module block end
    if line:match('^' .. block_indent .. '}') then
      in_module_block = false
      table.insert(new_lines, line)
      goto continue
    end

    -- Process module block content
    local line_indent = line:match('^(%s*)')
    if line_indent ~= block_indent .. '  ' then
      table.insert(new_lines, line)
      goto continue
    end

    -- Handle source lines
    if line:match('%s*source%s*=') then
      if not source_added then
        if is_local then
          table.insert(new_lines, block_indent .. '  source = "../../"')
        else
          table.insert(new_lines, string.format('%s  source  = "%s"', block_indent, module_config.registry_source))
          local latest_version, latest_major = get_latest_version_info(module_config.registry_source)
          if latest_version then
            local new_version_constraint = latest_major == 0
              and "~> 0." .. select(2, parse_version(latest_version))
              or "~> " .. latest_major .. ".0"
            table.insert(new_lines, string.format('%s  version = "%s"', block_indent, new_version_constraint))
          end
        end
        source_added = true
        modified = true
      end
      goto continue
    end

    -- Skip version lines as they're handled with source
    if line:match('%s*version%s*=') then
      goto continue
    end

    -- Keep all other lines
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
    -- Check for module block start
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

    -- Check for module block end
    if line:match('^' .. block_indent .. '}') then
      in_module_block = false
      table.insert(new_lines, line)
      goto continue
    end

    -- Process module block content
    local line_indent = line:match('^(%s*)')
    if line_indent ~= block_indent .. '  ' then
      table.insert(new_lines, line)
      goto continue
    end

    -- Handle source lines
    if line:match('%s*source%s*=') and not line:match('^%s*#') then
      local source = line:match('source%s*=%s*"([^"]+)"')
      if source then
        active_source = source
        table.insert(new_lines, line)

        if source:match("^" .. namespace .. "/") then
          local latest_version, latest_major = get_latest_version_info(source)
          if latest_version then
            local new_version_constraint = latest_major == 0
              and "~> 0." .. select(2, parse_version(latest_version))
              or "~> " .. latest_major .. ".0"

            table.insert(new_lines, string.format('%s  version = "%s"', block_indent, new_version_constraint))
            modified = true
          end
        end
      else
        table.insert(new_lines, line)
      end
      goto continue
    end

    -- Handle version lines
    if line:match('%s*version%s*=') and not line:match('^%s*#') then
      if not active_source or not active_source:match("^" .. namespace .. "/") then
        table.insert(new_lines, line)
      end
      goto continue
    end

    -- Keep all other lines
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

local function process_files_parallel(files, processor_fn, args)
  local modified_count = 0
  local completed = 0
  local total = #files

  for _, file in ipairs(files) do
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
  local commands = {
    BounceModuleToLocal = function()
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
    end,

    BounceModuleToRegistry = function()
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
    end,

    BounceModulesToRegistry = function()
      local files = find_terraform_files()
      if #files == 0 then
        vim.notify("No Terraform files found", vim.log.levels.WARN)
        return
      end
      process_files_parallel(files, process_file_for_all_modules)
    end
  }

  for name, fn in pairs(commands) do
    vim.api.nvim_create_user_command(name, fn, {})
  end
end

function M.setup(opts)
  opts = opts or {}
  if not opts.namespace then
    error("Namespace is required. Please provide a namespace in the setup configuration.")
  end

  namespace = opts.namespace
  create_commands()
end

return M
