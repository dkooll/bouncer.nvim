local M = {}

-- Function to get the module name from the registry source
local function get_module_name(registry_source)
  local module_name = registry_source:match("^[^/]+/([^/]+)/")
  if not module_name then
    error("Invalid registry source format: " .. registry_source)
  end
  return {
    module_name:lower(),
    module_name:sub(1, 1):upper() .. module_name:sub(2),
  }
end

-- Function to get the latest major version from the registry
local function get_latest_major_version(registry_source)
  local plenary_http = require("plenary.curl")

  local namespace, name, provider = registry_source:match("^([^/]+)/([^/]+)/([^/]+)$")
  if not (namespace and name and provider) then
    vim.notify("Invalid registry source format: " .. registry_source, vim.log.levels.ERROR)
    return nil
  end

  local registry_url = string.format("https://registry.terraform.io/v1/modules/%s/%s/%s/versions", namespace, name,
    provider)
  local result = plenary_http.get({ url = registry_url, accept = "application/json" })

  if result and result.status == 200 and result.body then
    local data = vim.fn.json_decode(result.body)
    if data and data.modules and data.modules[1] and data.modules[1].versions then
      local latest_major_version = nil
      for _, version_info in ipairs(data.modules[1].versions) do
        local major = version_info.version:match("^(%d+)")
        if major then
          major = tonumber(major)
          if not latest_major_version or major > latest_major_version then
            latest_major_version = major
          end
        end
      end
      if latest_major_version then
        return "~> " .. latest_major_version .. ".0"
      end
    else
      vim.notify("Failed to parse JSON or 'modules'/'versions' field not found.", vim.log.levels.ERROR)
    end
  else
    vim.notify("Failed to fetch latest version for " .. registry_source, vim.log.levels.ERROR)
  end
  return nil
end

-- Function to process the main.tf files and update the versions
local function process_file(file_path, module_config, is_local, latest_version_constraint)
  local lines = vim.fn.readfile(file_path)
  if not lines then
    vim.notify("Failed to read file: " .. file_path, vim.log.levels.ERROR)
    return false
  end

  local modified = false
  local in_module_block = false
  local new_lines = {}

  for i, line in ipairs(lines) do
    if not in_module_block then
      table.insert(new_lines, line)
      if line:match('module%s*"[^"]*"%s*{') and lines[i + 1] then
        if lines[i + 1]:match('source%s*=%s*"' .. module_config.registry_source .. '"') then
          in_module_block = true
        end
      end
    elseif line:match('^%s*}') then
      in_module_block = false
      table.insert(new_lines, line)
    else
      if line:match('%s*source%s*=') then
        table.insert(new_lines, string.format('  source  = "%s"', module_config.registry_source))
        modified = true
      elseif not is_local and line:match('%s*version%s*=') then
        table.insert(new_lines, string.format('  version = "%s"', latest_version_constraint or get_latest_major_version(module_config.registry_source)))
        modified = true
      else
        table.insert(new_lines, line)
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

-- Function to create the BounceAllToLatest command
local function create_all_to_latest_command()
  vim.api.nvim_create_user_command("BounceAllToLatest", function()
    local find_cmd = "find . -name main.tf"
    local files = vim.fn.systemlist(find_cmd)

    local modified_count = 0
    for _, file in ipairs(files) do
      for _, module_config in pairs(_G.bouncer_configs or {}) do
        local latest_version = get_latest_major_version(module_config.registry_source)
        if latest_version and process_file(file, module_config, false, latest_version) then
          modified_count = modified_count + 1
          vim.notify("Updated " .. file .. " to latest version", vim.log.levels.INFO)
        end
      end
    end

    if modified_count > 0 then
      vim.notify(string.format("Updated %d files to latest versions", modified_count), vim.log.levels.INFO)
    else
      vim.notify("No files were modified", vim.log.levels.WARN)
    end
    vim.cmd('edit')
  end, {})
end

local function create_module_commands(_, module_config)
  local module_names = get_module_name(module_config.registry_source)

  for _, name in ipairs(module_names) do
    vim.api.nvim_create_user_command("Bounce" .. name .. "ToLocal", function()
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

    vim.api.nvim_create_user_command("Bounce" .. name .. "ToRegistry", function()
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
  end
end

function M.setup(opts)
  _G.bouncer_configs = opts
  create_all_to_latest_command()

  for _, module_config in pairs(opts) do
    create_module_commands(_, module_config)
  end
end

return M


--local M = {}

--local function get_module_name(registry_source)
  --local module_name = registry_source:match("^[^/]+/([^/]+)/")
  --if not module_name then
    --error("Invalid registry source format: " .. registry_source)
  --end
  --return {
    --module_name:lower(),
    --module_name:sub(1, 1):upper() .. module_name:sub(2),
  --}
--end


--local function get_latest_major_version(registry_source)
  --local plenary_http = require("plenary.curl")

  --local namespace, name, provider = registry_source:match("^([^/]+)/([^/]+)/([^/]+)$")
  --if not (namespace and name and provider) then
    --vim.notify("Invalid registry source format: " .. registry_source, vim.log.levels.ERROR)
    --return nil
  --end

  --local registry_url = string.format("https://registry.terraform.io/v1/modules/%s/%s/%s/versions", namespace, name,
    --provider)
  --local result = plenary_http.get({ url = registry_url, accept = "application/json" })

  --if result and result.status == 200 and result.body then
    --local data = vim.fn.json_decode(result.body)
    --if data and data.modules and data.modules[1] and data.modules[1].versions then
      ---- Find the highest major version available
      --local latest_major_version = nil
      --for _, version_info in ipairs(data.modules[1].versions) do
        --local major = version_info.version:match("^(%d+)") -- Extract the major version
        --if major then
          --major = tonumber(major)
          --if not latest_major_version or major > latest_major_version then
            --latest_major_version = major
          --end
        --end
      --end

      --if latest_major_version then
        --return "~> " .. latest_major_version .. ".0" -- Format the version constraint as "~> X.0"
      --end
    --else
      --vim.notify("Failed to parse JSON or 'modules'/'versions' field not found.", vim.log.levels.ERROR)
    --end
  --else
    --vim.notify(
      --"Failed to fetch latest version for " .. registry_source .. ": " .. (result and result.status or "No response"),
      --vim.log.levels.ERROR)
  --end

  --return nil -- Return nil if no version found or an error occurred
--end

---- Function to process file content
--local function process_file(file_path, module_config, is_local)
  --local lines = vim.fn.readfile(file_path)
  --if not lines then
    --vim.notify("Failed to read file: " .. file_path, vim.log.levels.ERROR)
    --return false
  --end

  --local modified = false
  --local in_module_block = false
  --local new_lines = {}

  --for i, line in ipairs(lines) do
    --if not in_module_block then
      --table.insert(new_lines, line)
      ---- Detect start of module block
      --if line:match('module%s*"[^"]*"%s*{') and lines[i + 1] then
        --if lines[i + 1]:match('source%s*=%s*"' .. module_config.registry_source .. '"') or
            --lines[i + 1]:match('source%s*=%s*"../../"') then
          --in_module_block = true
        --end
      --end
    --elseif line:match('^%s*}') then
      --in_module_block = false
      --table.insert(new_lines, line)
    --else
      ---- Replace source with local or registry source
      --if line:match('%s*source%s*=') then
        --if is_local then
          --table.insert(new_lines, '  source = "../../"')
        --else
          --table.insert(new_lines, string.format('  source  = "%s"', module_config.registry_source))
        --end
        --modified = true

        ---- Handle version line based on local or registry setting
      --elseif line:match('%s*version%s*=') then
        --if is_local then
          ---- Remove version line if switching to local
          --modified = true
        --else
          ---- Always update version to the latest major version constraint from the registry
          --local latest_version_constraint = get_latest_major_version(module_config.registry_source)
          --if latest_version_constraint then
            --table.insert(new_lines, string.format('  version = "%s"', latest_version_constraint))
          --end
          --modified = true
        --end

        ---- If no version line is present and switching to registry, add version constraint
      --elseif not is_local and not line:match('%s*version%s*=') and lines[i - 1]:match('%s*source%s*=') then
        --local latest_version_constraint = get_latest_major_version(module_config.registry_source)
        --if latest_version_constraint then
          --table.insert(new_lines, string.format('  version = "%s"', latest_version_constraint))
        --end
        --table.insert(new_lines, line)
        --modified = true
      --else
        --table.insert(new_lines, line)
      --end
    --end
  --end

  ---- Write back modified lines if there were changes
  --if modified then
    --if vim.fn.writefile(new_lines, file_path) == -1 then
      --vim.notify("Failed to write file: " .. file_path, vim.log.levels.ERROR)
      --return false
    --end
    --return true
  --end

  --return false
--end

--local function create_module_commands(_, module_config)
  --local module_names = get_module_name(module_config.registry_source)

  --for _, name in ipairs(module_names) do
    --vim.api.nvim_create_user_command("Bounce" .. name .. "ToLocal", function()
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

    --vim.api.nvim_create_user_command("Bounce" .. name .. "ToRegistry", function()
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
--end

--function M.setup(opts)
  --for _, module_config in pairs(opts) do
    --create_module_commands(_, module_config)
  --end
--end

--return M
