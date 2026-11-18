local changes = {}

local MAX_FILES = 512
local MAX_PATH = 512
local MAX_OUTPUT = 64 * 1024
local MAX_MANUAL = 16 * 1024

local function trim(value)
	return (string.gsub(value, "^%s*(.-)%s*$", "%1"))
end

local function valid_text(value, limit)
	return type(value) == "string" and #value > 0 and #value <= limit
		and not string.find(value, "%c") and utf8.len(value) ~= nil
end

local function oid(value)
	if type(value) == "string" and (#value == 40 or #value == 64)
		and string.match(value, "^[0-9a-fA-F]+$") and string.find(value, "[1-9a-fA-F]") then
		return string.lower(value)
	end
	return nil
end

local function valid_ref(value)
	if type(value) ~= "string" or #value > 255 or not string.match(value, "^[A-Za-z0-9][A-Za-z0-9._/-]*$")
		or string.find(value, "..", 1, true) or string.find(value, "//", 1, true)
		or string.sub(value, -1) == "/" then
		return false
	end
	for part in string.gmatch(value, "[^/]+") do
		if string.sub(part, 1, 1) == "." or string.sub(part, -1) == "." or string.sub(part, -5) == ".lock" then
			return false
		end
	end
	return true
end

local function valid_path(value)
	if not valid_text(value, MAX_PATH) or string.find(value, "\\", 1, true)
		or string.find(value, "\u{FFFD}", 1, true) or string.find(value, "//", 1, true) or string.match(value, "^[A-Za-z]:")
		or string.sub(value, 1, 1) == "/" or string.sub(value, -1) == "/" then
		return false
	end
	for part in string.gmatch(value, "[^/]+") do
		if part == "." or part == ".." then
			return false
		end
	end
	return true
end

local function file_list()
	local files, seen = {}, {}
	local count, size = 0, 0
	local function add(path)
		if not valid_path(path) then
			error("Changed files contain an unsupported path")
		end
		count += 1
		size += #path + 1
		if count > MAX_FILES or size > MAX_OUTPUT then
			error("Too many changed files or too much path data")
		end
		if not seen[path] then
			seen[path] = true
			table.insert(files, path)
		end
	end
	return files, add
end

local function git(zeron, cwd, args, failure)
	local argv = { "--no-replace-objects", table.unpack(args) }
	local result = zeron.run("git", argv, {
		cwd = cwd,
		timeout = 10,
		env = { GIT_TERMINAL_PROMPT = "0", GIT_OPTIONAL_LOCKS = "0" },
	}):await()
	if type(result) ~= "table" or result.status ~= 0 or type(result.stdout) ~= "string" then
		error(failure)
	end
	if #result.stdout > MAX_OUTPUT then
		error("Git returned too much output")
	end
	return result.stdout
end

local function resolve(zeron, cwd, ref)
	local out = git(zeron, cwd, { "rev-parse", "--verify", "--end-of-options", ref .. "^{commit}" }, "Could not resolve a Git commit in the selected checkout")
	local revision = oid(string.match(out, "^([0-9a-fA-F]+)\r?\n$"))
	if not revision then
		error("Git did not return a full commit ID")
	end
	return revision
end

function changes.local_device(zeron)
	for _, device in zeron.devices():peek() do
		if device.here == true then return device.id end
	end
	return nil
end

local function first_parent(zeron, cwd, revision)
	local out = git(zeron, cwd, { "cat-file", "commit", revision }, "Could not read the selected commit")
	local tree, next_line = string.match(out, "^tree ([0-9a-fA-F]+)\n([^\n]+)\n")
	if oid(tree) and #tree == #revision then
		local parent = oid(string.match(next_line, "^parent ([0-9a-fA-F]+)$"))
		if parent and #parent == #revision then
			return parent
		elseif string.sub(next_line, 1, 7) == "author " then
			return nil
		end
	end
	error("Git returned invalid commit headers")
end

local function read_git(zeron, destination, source)
	local device = changes.local_device(zeron)
	if not valid_text(device, 256) or destination.device ~= device then
		error("Git sources require a session on this device")
	end
	local cwd = destination.cwd
	if not valid_text(cwd, 4096) or not (string.sub(cwd, 1, 1) == "/" or string.match(cwd, "^[A-Za-z]:[/\\]")) then
		error("A trusted local checkout path is required")
	end
	local ref = if source.kind == "commit" then source.ref else source.head
	if not valid_ref(ref) or (source.kind == "compare" and not valid_ref(source.base)) then
		error("Enter simple Git refs or commit IDs; revision expressions are not supported")
	end
	local revision = resolve(zeron, cwd, ref)
	local base
	if source.kind == "compare" then
		base = if source.base == ref then revision else resolve(zeron, cwd, source.base)
	else
		base = first_parent(zeron, cwd, revision)
	end
	local function diff(...)
		local args = { "--no-pager", "diff-tree", "--no-commit-id", "-r", "--no-renames", "--no-ext-diff", "--no-textconv", "--no-color", "--no-relative", "--ignore-submodules=none", ... }
		table.insert(args, base or "--root")
		table.insert(args, revision)
		table.insert(args, "--")
		return git(zeron, cwd, args, "Could not read the change in the selected checkout")
	end
	local out = diff("--name-only", "-z")
	local files, add = file_list()
	local pos = 1
	while pos <= #out do
		local stop = string.find(out, "\0", pos, true)
		if not stop then
			error("Git returned an incomplete changed file list")
		end
		add(string.sub(out, pos, stop - 1))
		pos = stop + 1
	end
	table.sort(files)
	local ok, patch = pcall(diff, "--patch", "--unified=0", "--src-prefix=a/", "--dst-prefix=b/")
	local lines = {}
	if ok then
		local paths = {}
		for _, file in files do paths[file] = true end
		local file, header, count = nil, false, 0
		for line in string.gmatch(patch, "[^\n]+") do
			if string.sub(line, 1, 11) == "diff --git " then
				file, header = nil, true
			elseif header and string.sub(line, 1, 6) == "+++ b/" then
				local path = string.match(string.sub(line, 7), "^[^\t]+")
				if path and paths[path] then file = path end
				header = false
			elseif file and string.sub(line, 1, 3) == "@@ " then
				local start, length = string.match(line, "^@@ %-%d+,?%d* %+(%d+),?(%d*) @@")
				local first, size = tonumber(start), if length == "" then 1 else tonumber(length)
				if first and size and first > 0 and size > 0 then
					count += 1
					if count > 256 then lines = {}; break end
					lines[file] = lines[file] or {}
					table.insert(lines[file], { first, first + size - 1 })
				end
			end
		end
	end
	return { revision = revision, base = base, files = files, ci = "unknown", lines = lines }
end

local function pr_url(url)
	if type(url) ~= "string" or #url > 200 then
		return nil
	end
	local owner, repo, number = string.match(url, "^https://github%.com/([A-Za-z0-9][A-Za-z0-9-]*)/([A-Za-z0-9_.-]+)/pull/([1-9][0-9]*)$")
	if not owner or #owner > 39 or string.sub(owner, -1) == "-" or string.find(owner, "--", 1, true)
		or #repo > 100 or repo == "." or repo == ".." or #number > 10 then
		return nil
	end
	return url
end

local function read_pr(zeron, destination, source)
	local url = pr_url(source.url)
	if not url then
		error("Enter an HTTPS GitHub pull request URL")
	end
	local pr = zeron.github.at(destination.session, destination.project).pr(url, true):await()
	if type(pr) ~= "table" or type(pr.files) ~= "table" then
		error("Pull request details or changed files are unavailable")
	end
	local revision, base = oid(pr.headRefOid), oid(pr.baseRefOid)
	if not revision or not base or #revision ~= #base then
		error("Pull request commit IDs are unavailable")
	end
	local files, add = file_list()
	local count = 0
	for index, file in pairs(pr.files) do
		if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > #pr.files or type(file) ~= "table" then
			error("GitHub returned an invalid changed file list")
		end
		add(file.path)
		count += 1
	end
	if count ~= #pr.files then
		error("GitHub returned an incomplete changed file list")
	end
	table.sort(files)
	local state = type(pr.ci) == "table" and pr.ci.state
	local ci = if state == "passed" then "pass" elseif state == "failed" then "fail" elseif state == "pending" then "pending" else "unknown"
	local title = if valid_text(pr.title, 512) then pr.title else nil
	return { revision = revision, base = base, files = files, title = title, ci = ci }
end

function changes.read(zeron, destination)
	if type(destination) ~= "table" or not valid_text(destination.session, 256)
		or (destination.project ~= nil and not valid_text(destination.project, 256)) then
		error("Select a session before reading changes")
	end
	local source = destination.source
	if type(source) ~= "table" then
		error("Select a change source")
	end
	if source.kind == "commit" or source.kind == "compare" then
		return read_git(zeron, destination, source)
	elseif source.kind == "pr" then
		return read_pr(zeron, destination, source)
	end
	error("Unsupported change source")
end

local function docs_path(path)
	local lower = string.lower(path)
	return string.sub(lower, 1, 5) == "docs/" or string.match(lower, "%.md$") ~= nil
		or string.match(lower, "%.mdx$") ~= nil or string.match(lower, "%.rst$") ~= nil
end

function changes.check(change, predicate)
	if type(change) ~= "table" then
		return nil, "No change was captured"
	end
	if predicate == "ci" then
		if change.ci == "pass" then
			return true
		elseif change.ci == "fail" then
			return false
		elseif change.ci == "pending" then
			return nil, "CI is still pending"
		end
		return nil, "CI status is unavailable"
	elseif predicate == "files" or predicate == "docs" then
		if type(change.files) ~= "table" then
			return nil, "Changed files are unavailable"
		end
		if predicate == "files" or #change.files == 0 then
			return #change.files > 0
		end
		for _, path in ipairs(change.files) do
			if not valid_path(path) then
				return nil, "Changed files contain an unsupported path"
			end
			if docs_path(path) then return true end
		end
		return false
	end
	return nil, "Unsupported change predicate"
end

function changes.items(change, manual, limit)
	if type(limit) ~= "number" or limit < 1 or limit > MAX_FILES or limit % 1 ~= 0 then
		return nil, "Invalid item limit"
	end
	if manual ~= nil and (type(manual) ~= "string" or #manual > MAX_MANUAL) then
		return nil, "Manual items exceed the input limit or are not text"
	end
	local items, seen = {}, {}
	local function add(item)
		if seen[item] then
			return true
		end
		if #items >= limit then
			return false
		end
		seen[item] = true
		table.insert(items, item)
		return true
	end
	if manual and manual ~= "" then
		for raw in string.gmatch(manual, "[^\n]+") do
			local item = trim(raw)
			if item ~= "" then
				if not valid_text(item, MAX_PATH) then
					return nil, "A manual item is too long or contains unsupported characters"
				end
				if not add(item) then
					return nil, "Manual items exceed the item limit"
				end
			end
		end
	else
		local files = type(change) == "table" and change.files
		if type(files) ~= "table" or #files > MAX_FILES then
			return nil, "Changed files are unavailable or exceed the file limit"
		end
		local root, literal_root = false, false
		for _, path in ipairs(files) do
			if not valid_path(path) then
				return nil, "Changed files contain an unsupported path"
			end
			local dir = string.match(path, "^([^/]+)/")
			root = root or dir == nil
			literal_root = literal_root or dir == "(root)"
			if root and literal_root then
				return nil, "The directory (root) conflicts with the label for root files"
			end
			if not add(dir or "(root)") then
				return nil, "Top-level directories exceed the item limit"
			end
		end
		table.sort(items)
	end
	if #items == 0 then
		return nil, "No items found"
	end
	return items
end

function changes.validate_line(change, path, line)
	if type(change) ~= "table" or type(change.lines) ~= "table" or not valid_path(path)
		or type(line) ~= "number" or line < 1 or line % 1 ~= 0 then return false end
	for _, range in change.lines[path] or {} do
		if line >= range[1] and line <= range[2] then return true end
	end
	return false
end

return changes
