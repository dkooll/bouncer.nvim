local M = {}

local namespace -- Namespace will be set via setup function

local function get_module_config()
  if not namespace then
    error("Namespace is not set. Please provide a namespace in the setup configuration.")
  end

  local handle = io.popen("basename `git rev-parse --show-toplevel`")
  if not handle then
    error("Failed to execute git command to get repository name")
  end

  local repo_name = handle:read("*a")
  handle:close()
  if not repo_name then
    error("Failed to read repository name from git command")
  end

  repo_name = repo_name:gsub("%s+", "") -- Remove any whitespace

  -- Assuming repo_name is in the format "terraform-<provider>-<module>"
  local provider, module_name = repo_name:match("^terraform%-(.+)%-(.+)$")
  if not (provider and module_name) then
    error("Could not extract provider and module from repository name: " .. repo_name)
  end

  local registry_source = namespace .. "/" .. module_name .. "/" .. provider

  return {
    registry_source = registry_source,
    module_name = module_name,
    provider = provider,
    namespace = namespace
  }
end

-- Function to parse version strings into numeric components
local function parse_version(version_str)
  local major, minor, patch = version_str:match("^(%d+)%.(%d+)%.?(%d*)")
  major = tonumber(major)
  minor = tonumber(minor)
  patch = tonumber(patch) or 0
  return major, minor, patch
end

-- Function to compare two versions numerically
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

local function get_latest_version_info(registry_source)
  local plenary_http = require("plenary.curl")

  -- Remove any subdirectory from the registry_source
  local source_no_subdir = registry_source:match("^(.-)//") or registry_source

  local ns, module_name, provider = source_no_subdir:match("^([^/]+)/([^/]+)/([^/]+)$")
  if not (ns and module_name and provider) then
    vim.notify("Invalid registry source format: " .. registry_source, vim.log.levels.ERROR)
    return nil, nil
  end

  local registry_url = string.format(
    "https://registry.terraform.io/v1/modules/%s/%s/%s/versions",
    ns,
    module_name,
    provider
  )

  local result = plenary_http.get({ url = registry_url, accept = "application/json" })

  if result and result.status == 200 and result.body then
    local data = vim.fn.json_decode(result.body)
    if data and data.modules and data.modules[1] and data.modules[1].versions then
      -- Find the latest version numerically
      local latest_version = nil
      for _, version_info in ipairs(data.modules[1].versions) do
        if not latest_version or is_version_greater(version_info.version, latest_version) then
          latest_version = version_info.version
        end
      end

      if latest_version then
        -- Return the latest version and the major version number
        local major_version = latest_version:match("^(%d+)")
        if major_version then
          major_version = tonumber(major_version)
          return latest_version, major_version
        end
      end
    end
  else
    vim.notify(
      "Failed to fetch latest version for " .. registry_source .. ": " .. (result and result.status or "No response"),
      vim.log.levels.ERROR
    )
  end

  return nil, nil
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

  for i, line in ipairs(lines) do
    if not in_module_block then
      table.insert(new_lines, line)
      local module_match = line:match('(%s*)module%s*"[^"]*"%s*{')
      if module_match and lines[i + 1] then
        block_indent = module_match
        local next_line = lines[i + 1]
        if next_line:match('source%s*=%s*"' .. module_config.registry_source .. '"') or
           next_line:match('source%s*=%s*"../../"') then
          in_module_block = true
        end
      end
    else
      if line:match('^' .. block_indent .. '}') then
        in_module_block = false
        table.insert(new_lines, line)
      else
        local line_indent = line:match('^(%s*)')
        if line_indent == block_indent .. '  ' then
          if line:match('%s*source%s*=') then
            if is_local then
              table.insert(new_lines, block_indent .. '  source = "../../"')
            else
              table.insert(new_lines, string.format('%s  source  = "%s"', block_indent, module_config.registry_source))
              local latest_version, latest_major = get_latest_version_info(module_config.registry_source)
              if latest_version then
                local new_version_constraint
                if latest_major == 0 then
                  -- For major version 0, include minor version in constraint
                  local _, latest_minor = parse_version(latest_version)
                  new_version_constraint = "~> 0." .. latest_minor
                else
                  new_version_constraint = "~> " .. latest_major .. ".0"
                end
                table.insert(new_lines, string.format('%s  version = "%s"', block_indent, new_version_constraint))
              end
            end
            modified = true
          elseif line:match('%s*version%s*=') then
            -- Skip the version line when switching modes
            modified = true
          else
            table.insert(new_lines, line)
          end
        else
          table.insert(new_lines, line)
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
  local current_module_name = ""
  local source_line_index = nil
  local version_line_index = nil
  local source_line = nil
  local version_line = nil

  for _, line in ipairs(lines) do
    table.insert(new_lines, line)

    if not in_module_block then
      local module_match = line:match('(%s*)module%s*"[^"]*"%s*{')
      if module_match then
        in_module_block = true
        block_indent = module_match
        current_module_name = line:match('module%s*"([^"]+)"')
        source_line_index = nil
        version_line_index = nil
        source_line = nil
        version_line = nil
      end
    else
      if line:match('^' .. block_indent .. '}') then
        in_module_block = false

        if source_line_index and source_line then
          local source_value = source_line:match('source%s*=%s*"(.-)"')
          if source_value then
            local registry_source = source_value
            if registry_source and (registry_source:match("^%./") or registry_source:match("^%.%./")) then
              -- Skip local modules
              goto continue
            end
            local latest_version, latest_major = get_latest_version_info(registry_source)
            if latest_version then
              -- Parse existing version constraint
              local existing_version = nil
              if version_line and version_line:match('version%s*=%s*"(.-)"') then
                existing_version = version_line:match('version%s*=%s*"(.-)"')
              end

              local update_version = true
              if existing_version then
                local existing_major, existing_minor = existing_version:match("~>%s*(%d+)%.(%d+)")
                existing_major = tonumber(existing_major)
                existing_minor = tonumber(existing_minor)
                local latest_major_version, latest_minor_version = parse_version(latest_version)

                if existing_major == latest_major_version then
                  if latest_major_version == 0 then
                    -- For major version 0, compare minor versions
                    if existing_minor and latest_minor_version and existing_minor >= latest_minor_version then
                      update_version = false
                    end
                  else
                    -- For major versions > 0, no need to update if majors are equal
                    update_version = false
                  end
                elseif existing_major > latest_major_version then
                  -- Existing major version is higher, do not update
                  update_version = false
                end
              end

              if update_version then
                local new_version_constraint
                if latest_major == 0 then
                  -- For major version 0, include minor version in constraint
                  local _, latest_minor = parse_version(latest_version)
                  new_version_constraint = "~> 0." .. latest_minor
                else
                  new_version_constraint = "~> " .. latest_major .. ".0"
                end

                if version_line_index then
                  -- Update existing version line
                  new_lines[version_line_index] = string.format('%s  version = "%s"', block_indent, new_version_constraint)
                else
                  -- Add version line after source line
                  table.insert(new_lines, source_line_index + 1, string.format('%s  version = "%s"', block_indent, new_version_constraint))
                end
                modified = true
              end
            else
              vim.notify("Could not fetch latest version for module '" .. current_module_name .. "'", vim.log.levels.WARN)
            end
          end
        end
      else
        -- Inside module block
        local line_indent = line:match('^(%s*)')
        if line_indent == block_indent .. '  ' then
          if line:match('%s*source%s*=') then
            source_line_index = #new_lines
            source_line = line
          elseif line:match('%s*version%s*=') then
            version_line_index = #new_lines
            version_line = line
          end
        end
      end
    end
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

local function create_commands()
  vim.api.nvim_create_user_command("BounceModuleToLocal", function()
    local module_config = get_module_config()
    local find_cmd = "find . -name main.tf"
    local files = vim.fn.systemlist(find_cmd)

    local modified_count = 0
    for _, file in ipairs(files) do
      if process_file(file, module_config, true) then
        modified_count = modified_count + 1
        vim.notify("Modified " .. file, vim.log.levels.INFO)
      end
    end

    if modified_count > 0 then
      vim.notify(string.format("Modified %d files", modified_count), vim.log.levels.INFO)
    else
      vim.notify("No files were modified", vim.log.levels.WARN)
    end
    vim.cmd('edit')
  end, {})

  vim.api.nvim_create_user_command("BounceModuleToRegistry", function()
    local module_config = get_module_config()
    local find_cmd = "find . -name main.tf"
    local files = vim.fn.systemlist(find_cmd)

    local modified_count = 0
    for _, file in ipairs(files) do
      if process_file(file, module_config, false) then
        modified_count = modified_count + 1
        vim.notify("Modified " .. file, vim.log.levels.INFO)
      end
    end

    if modified_count > 0 then
      vim.notify(string.format("Modified %d files", modified_count), vim.log.levels.INFO)
    else
      vim.notify("No files were modified", vim.log.levels.WARN)
    end
    vim.cmd('edit')
  end, {})

  vim.api.nvim_create_user_command("BounceModulesToRegistry", function()
    local find_cmd = "find . -name main.tf"
    local files = vim.fn.systemlist(find_cmd)

    local modified_count = 0
    for _, file in ipairs(files) do
      if process_file_for_all_modules(file) then
        modified_count = modified_count + 1
        vim.notify("Modified " .. file, vim.log.levels.INFO)
      end
    end

    if modified_count > 0 then
      vim.notify(string.format("Modified %d files", modified_count), vim.log.levels.INFO)
    else
      vim.notify("No files were modified", vim.log.levels.WARN)
    end
    vim.cmd('edit')
  end, {})
end

function M.setup(opts)
  opts = opts or {}
  if opts.namespace then
    namespace = opts.namespace
  else
    error("Namespace is required. Please provide a namespace in the setup configuration.")
  end
  create_commands()
end

return M

--local M = {}

--local namespace

--local function get_module_config()
--if not namespace then
--error("Namespace is not set. Please provide a namespace in the setup configuration.")
--end

--local handle = io.popen("basename `git rev-parse --show-toplevel`")
--if not handle then
--error("Failed to execute git command to get repository name")
--end

--local repo_name = handle:read("*a")
--handle:close()
--if not repo_name then
--error("Failed to read repository name from git command")
--end

--repo_name = repo_name:gsub("%s+", "") -- Remove any whitespace

---- Assuming repo_name is in the format "terraform-<provider>-<module>"
--local provider, module_name = repo_name:match("^terraform%-(.+)%-(.+)$")
--if not (provider and module_name) then
--error("Could not extract provider and module from repository name: " .. repo_name)
--end

--local registry_source = namespace .. "/" .. module_name .. "/" .. provider

--return {
--registry_source = registry_source,
--module_name = module_name,
--provider = provider,
--namespace = namespace
--}
--end

--local function get_latest_major_version(registry_source)
--local plenary_http = require("plenary.curl")

---- Renamed 'namespace' to 'ns' to avoid scope conflict
--local ns, module_name, provider = registry_source:match("^([^/]+)/([^/]+)/([^/]+)$")
--if not (ns and module_name and provider) then
--vim.notify("Invalid registry source format: " .. registry_source, vim.log.levels.ERROR)
--return nil
--end

--local registry_url = string.format(
--"https://registry.terraform.io/v1/modules/%s/%s/%s/versions",
--ns,
--module_name,
--provider
--)

--local result = plenary_http.get({ url = registry_url, accept = "application/json" })

--if result and result.status == 200 and result.body then
--local data = vim.fn.json_decode(result.body)
--if data and data.modules and data.modules[1] and data.modules[1].versions then
--local latest_major_version = nil
--for _, version_info in ipairs(data.modules[1].versions) do
--local major = version_info.version:match("^(%d+)")
--if major then
--major = tonumber(major)
--if not latest_major_version or major > latest_major_version then
--latest_major_version = major
--end
--end
--end

--if latest_major_version then
--return "~> " .. latest_major_version .. ".0"
--end
--end
--else
--vim.notify(
--"Failed to fetch latest version for " .. registry_source .. ": " .. (result and result.status or "No response"),
--vim.log.levels.ERROR
--)
--end

--return nil
--end

--local function process_file(file_path, module_config, is_local)
--local lines = vim.fn.readfile(file_path)
--if not lines then
--vim.notify("Failed to read file: " .. file_path, vim.log.levels.ERROR)
--return false
--end

--local modified = false
--local in_module_block = false
--local new_lines = {}
--local block_indent = ""

--for i, line in ipairs(lines) do
--if not in_module_block then
--table.insert(new_lines, line)
--local module_match = line:match('(%s*)module%s*"[^"]*"%s*{')
--if module_match and lines[i + 1] then
--block_indent = module_match
--local next_line = lines[i + 1]
--if next_line:match('source%s*=%s*"' .. module_config.registry_source .. '"') or
--next_line:match('source%s*=%s*"../../"') then
--in_module_block = true
--end
--end
--else
--if line:match('^' .. block_indent .. '}') then
--in_module_block = false
--table.insert(new_lines, line)
--else
--local line_indent = line:match('^(%s*)')
--if line_indent == block_indent .. '  ' then
--if line:match('%s*source%s*=') then
--if is_local then
--table.insert(new_lines, block_indent .. '  source = "../../"')
--else
--table.insert(new_lines, string.format('%s  source  = "%s"', block_indent, module_config.registry_source))
--local latest_version_constraint = get_latest_major_version(module_config.registry_source)
--if latest_version_constraint then
--table.insert(new_lines, string.format('%s  version = "%s"', block_indent, latest_version_constraint))
--end
--end
--modified = true
--elseif line:match('%s*version%s*=') then
---- Skip the version line when switching modes
--modified = true
--else
--table.insert(new_lines, line)
--end
--else
--table.insert(new_lines, line)
--end
--end
--end
--end

--if modified then
--if vim.fn.writefile(new_lines, file_path) == -1 then
--vim.notify("Failed to write file: " .. file_path, vim.log.levels.ERROR)
--return false
--end
--return true
--end

--return false
--end

--local function create_commands()
--vim.api.nvim_create_user_command("BounceModuleToLocal", function()
--local module_config = get_module_config()
--local find_cmd = "find . -name main.tf"
--local files = vim.fn.systemlist(find_cmd)

--local modified_count = 0
--for _, file in ipairs(files) do
--if process_file(file, module_config, true) then
--modified_count = modified_count + 1
--vim.notify("Modified " .. file, vim.log.levels.INFO)
--end
--end

--if modified_count > 0 then
--vim.notify(string.format("Modified %d files", modified_count), vim.log.levels.INFO)
--else
--vim.notify("No files were modified", vim.log.levels.WARN)
--end
--vim.cmd('edit')
--end, {})

--vim.api.nvim_create_user_command("BounceModuleToRegistry", function()
--local module_config = get_module_config()
--local find_cmd = "find . -name main.tf"
--local files = vim.fn.systemlist(find_cmd)

--local modified_count = 0
--for _, file in ipairs(files) do
--if process_file(file, module_config, false) then
--modified_count = modified_count + 1
--vim.notify("Modified " .. file, vim.log.levels.INFO)
--end
--end

--if modified_count > 0 then
--vim.notify(string.format("Modified %d files", modified_count), vim.log.levels.INFO)
--else
--vim.notify("No files were modified", vim.log.levels.WARN)
--end
--vim.cmd('edit')
--end, {})
--end

--function M.setup(opts)
--opts = opts or {}
--if opts.namespace then
--namespace = opts.namespace
--else
--error("Namespace is required. Please provide a namespace in the setup configuration.")
--end
--create_commands()
--end

--return M
