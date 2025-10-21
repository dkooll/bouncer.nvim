local M = {}

local config_cache = {}
local registry_config = {}
local registry_version_cache = {}
local version_cache = {}

local DEFAULT_REGISTRY_HOST = "registry.terraform.io"

local function normalize_host(host)
  if not host or host == "" then
    return DEFAULT_REGISTRY_HOST
  end

  local cleaned = host:gsub("^https?://", "")
  cleaned = cleaned:gsub("/+$", "")

  if cleaned == "" then
    return DEFAULT_REGISTRY_HOST
  end

  return cleaned
end

local patterns = {
  module_start = '^(%s*)module%s+"([^"]*)"[^{]*{%s*$',
  source_line = '^%s*source%s*=%s*"([^"]*)"',
  version_line = '^%s*version%s*=%s*"([^"]*)"',
  commented_source = '^%s*[/#]+%s*source%s*=%s*"([^"]*)"',
  commented_version = '^%s*[/#]+%s*version%s*=%s*"([^"]*)"',
  comment_line = "^%s*[/#]",
  empty_line = "^%s*$",
}

local function normalize_registry_base(base)
  if not base then
    return nil
  end
  return base:gsub("/+$", "")
end

local function registry_base_matches(base, expected_base)
  base = normalize_registry_base(base)
  expected_base = normalize_registry_base(expected_base)

  if not base or not expected_base then
    return false
  end

  if base == expected_base then
    return true
  end

  local default_pattern = "^" .. vim.pesc(DEFAULT_REGISTRY_HOST) .. "/"
  local base_without_default = base:gsub(default_pattern, "")
  local expected_without_default = expected_base:gsub(default_pattern, "")

  if base_without_default == expected_base then
    return true
  end

  if base == expected_without_default then
    return true
  end

  if base_without_default == expected_without_default then
    return true
  end

  return false
end

local function split_registry_source(source)
  if not source then
    return nil, nil
  end

  local base, subdir = source:match("^(.-)//(.+)$")
  if not base then
    base = source
  end

  base = normalize_registry_base(base)

  if subdir then
    subdir = subdir:gsub("^/+", "")
    subdir = subdir:gsub("/+$", "")
  end

  return base, subdir
end

local function split_local_source(source)
  if not source then
    return nil
  end

  local remainder = source:match("^%.%./%.%./?(.*)$")
  if remainder == nil then
    return nil
  end

  remainder = remainder:gsub("/+$", "")
  if remainder == "" then
    return nil
  end

  return remainder
end

local function get_source_metadata(source)
  if not source then
    return nil
  end

  local local_subdir = split_local_source(source)
  if local_subdir or source:match("^%.%./%.%./?$") then
    return {
      type = "local",
      subdir = local_subdir
    }
  end

  local base, subdir = split_registry_source(source)
  if base then
    return {
      type = "registry",
      base = base,
      subdir = subdir
    }
  end

  return nil
end

local function build_local_source(subdir)
  if subdir and subdir ~= "" then
    subdir = subdir:gsub("^/+", "")
    subdir = subdir:gsub("/+$", "")
    return string.format("../../%s/", subdir)
  end

  return "../../"
end

local function build_registry_source(base, subdir)
  base = normalize_registry_base(base)
  if subdir and subdir ~= "" then
    subdir = subdir:gsub("^/+", "")
    subdir = subdir:gsub("/+$", "")
    return string.format("%s//%s", base, subdir)
  end

  return base
end

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

local function get_module_config()
  local cwd = vim.fn.getcwd()
  local current_host = normalize_host(registry_config.host)
  local cached = config_cache[cwd]
  if cached
      and cached.namespace == registry_config.namespace
      and cached.host == current_host then
    return cached
  end

  local output = vim.fn.system("basename `git rev-parse --show-toplevel`")
  if vim.v.shell_error ~= 0 then
    error("Failed to execute git command to get repository name")
  end

  local repo_name = output:gsub("%s+", "")
  local provider, module_name = repo_name:match("^terraform%-([^%-]+)%-(.+)$")

  if not (provider and module_name) then
    error("Could not extract provider and module from repository name: " .. repo_name)
  end

  local host = current_host
  local base_path = string.format("%s/%s/%s",
    registry_config.namespace,
    module_name,
    provider)

  if host ~= DEFAULT_REGISTRY_HOST then
    base_path = string.format("%s/%s", host, base_path)
  end

  local config = {
    registry_source = base_path,
    module_name = module_name,
    provider = provider,
    namespace = registry_config.namespace,
    host = host
  }

  config_cache[cwd] = config
  return config
end

local function get_latest_version_info(registry_source)
  local base = split_registry_source(registry_source)
  if not base then
    return nil, nil
  end

  if registry_version_cache[base] then
    return unpack(registry_version_cache[base])
  end

  local ok, plenary_http = pcall(require, "plenary.curl")
  if not ok then
    vim.notify("plenary.curl is required but not available", vim.log.levels.ERROR)
    return nil, nil
  end

  local segments = vim.split(base, "/", { trimempty = true })
  local host, ns, name, provider

  if #segments == 4 then
    host, ns, name, provider = unpack(segments)
  elseif #segments == 3 then
    ns, name, provider = unpack(segments)
    host = DEFAULT_REGISTRY_HOST
  else
    vim.notify("Invalid registry source format: " .. registry_source, vim.log.levels.ERROR)
    return nil, nil
  end

  host = normalize_host(host ~= "" and host or DEFAULT_REGISTRY_HOST)

  local base_url = host
  if not base_url:match("^https?://") then
    base_url = "https://" .. base_url
  end

  local registry_url = string.format(
    "%s/v1/modules/%s/%s/%s/versions",
    base_url, ns, name, provider
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

  registry_version_cache[base] = { latest_version, major_version }
  return latest_version, major_version
end

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

      local brace_count = 1
      while i <= #lines and brace_count > 0 do
        local current_line = lines[i]

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

        local source = current_line:match(patterns.source_line)
        if source then
          module.source_value = source
        else
          local commented_source = current_line:match(patterns.commented_source)
          if commented_source then
            module.source_value = commented_source
          end
        end

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

local function fix_content_indentation(content_lines, base_indent)
  local fixed_lines = {}
  local current_depth = 0

  for _, line in ipairs(content_lines) do
    if line:match(patterns.empty_line) then
      table.insert(fixed_lines, "")
    elseif line:match(patterns.comment_line) then
      local content = line:gsub("^%s*", "")
      table.insert(fixed_lines, base_indent .. string.rep("  ", current_depth) .. content)
    else
      local content = line:gsub("^%s*", "")

      local starts_with_close = content:match("^[}%]]")

      if starts_with_close then
        current_depth = math.max(0, current_depth - 1)
      end

      table.insert(fixed_lines, base_indent .. string.rep("  ", current_depth) .. content)

      local net_depth_change = 0
      for char in content:gmatch("[{}%[%]]") do
        if char == "{" or char == "[" then
          net_depth_change = net_depth_change + 1
        elseif char == "}" or char == "]" then
          net_depth_change = net_depth_change - 1
        end
      end

      if starts_with_close then
        current_depth = math.max(0, current_depth + net_depth_change + 1)
      else
        current_depth = math.max(0, current_depth + net_depth_change)
      end
    end
  end

  return fixed_lines
end

local function generate_module_block(module, new_source, version_constraint)
  local lines = {}
  local base_indent = module.indent .. "  "

  table.insert(lines, module.indent .. 'module "' .. module.name .. '" {')

  table.insert(lines, base_indent .. 'source  = "' .. new_source .. '"')

  if version_constraint then
    table.insert(lines, base_indent .. 'version = "' .. version_constraint .. '"')
  end

  local other_content = {}
  for _, line in ipairs(module.content_lines) do
    table.insert(other_content, line)
  end

  while #other_content > 0 and other_content[1]:match(patterns.empty_line) do
    table.remove(other_content, 1)
  end

  local fixed_content = fix_content_indentation(other_content, base_indent)
  if #fixed_content > 0 then
    table.insert(lines, "")
    for _, line in ipairs(fixed_content) do
      table.insert(lines, line)
    end
  end

  table.insert(lines, module.indent .. "}")

  return lines
end

local function generate_version_constraint(latest_version, latest_major)
  if not latest_version or not latest_major then
    return nil
  end

  return latest_major == 0
      and "~> 0." .. select(2, parse_version(latest_version))
      or "~> " .. latest_major .. ".0"
end

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
    local metadata = module.source_value and get_source_metadata(module.source_value) or nil
    local matches_registry = metadata
        and metadata.type == "registry"
        and registry_base_matches(metadata.base, mod_config.registry_source)
    local matches_local = metadata and metadata.type == "local"
    local should_process

    if is_local then
      should_process = matches_registry or matches_local
    else
      should_process = matches_registry or matches_local or not module.source_value
    end

    while current_line < module.start_line do
      table.insert(new_lines, lines[current_line])
      current_line = current_line + 1
    end

    if should_process then
      local new_source, version_constraint
      local subdir = metadata and metadata.subdir or nil

      if is_local then
        new_source = build_local_source(subdir)
        version_constraint = nil
      else
        new_source = build_registry_source(mod_config.registry_source, subdir)
        local latest_version, latest_major = get_latest_version_info(mod_config.registry_source)
        if latest_version then
          version_constraint = generate_version_constraint(latest_version, latest_major)
        end
      end

      local module_lines = generate_module_block(module, new_source, version_constraint)
      for _, line in ipairs(module_lines) do
        table.insert(new_lines, line)
      end

      modified = true
    else
      while current_line <= module.end_line do
        table.insert(new_lines, lines[current_line])
        current_line = current_line + 1
      end
    end

    current_line = module.end_line + 1
  end

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
    local is_registry_module = false
    if module.source_value then
      local prefixes = {
        registry_config.namespace .. "/",
        normalize_host(registry_config.host) .. "/" .. registry_config.namespace .. "/"
      }

      for _, prefix in ipairs(prefixes) do
        if module.source_value:match("^" .. vim.pesc(prefix)) then
          is_registry_module = true
          break
        end
      end
    end

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
        while current_line <= module.end_line do
          table.insert(new_lines, lines[current_line])
          current_line = current_line + 1
        end
      end
    else
      while current_line <= module.end_line do
        table.insert(new_lines, lines[current_line])
        current_line = current_line + 1
      end
    end

    current_line = module.end_line + 1
  end

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

  if #errors > 0 then
    for _, error_msg in ipairs(errors) do
      vim.notify(error_msg, vim.log.levels.ERROR)
    end
  end

  if modified_count > 0 then
    vim.cmd('checktime')
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
      return
    end

    process_files(files, process_file, { module_config = module_config, is_local = false })
  end, { desc = "Switch module source to registry with latest version" })

  vim.api.nvim_create_user_command("BounceModulesToRegistry", function()
    local files = find_terraform_files()
    if #files == 0 then
      return
    end

    process_files(files, process_file_for_all_modules)
  end, { desc = "Update all registry modules to latest versions" })
end

function M.setup(opts)
  opts = opts or {}

  if not opts.namespace then
    error("The 'namespace' configuration is required")
  end

  registry_config = {
    namespace = opts.namespace,
    host = normalize_host(opts.host)
  }

  create_commands()
end

return M
