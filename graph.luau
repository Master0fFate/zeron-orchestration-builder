local M = {}

local templates = {
	planner = { name = "Planner", instructions = "Inspect the task and relevant context. Identify acceptance criteria, dependencies and risks. Produce a concise, ordered plan. Ask for clarification when blocked. Do not make changes." },
	worker = { name = "Worker", instructions = "Carry out the assigned work. Inspect the relevant context first, stay in scope and preserve existing changes. Run appropriate existing checks. Report what changed, evidence and blockers." },
	validator = { name = "Validator", instructions = "Independently review the work against the task and acceptance criteria. Check correctness, regressions and verification evidence. Address QA feedback on return, and provide QA with specific findings and missing checks. On an Always route, pass when the review is complete even if it found defects; fail only if blocked or unable to complete it." },
	auditor = { name = "Auditor", instructions = "Examine the assigned work for correctness, security and operational risks. Ground each finding in evidence, assess its impact and suggest a focused fix. Report uncertainty and do not make changes." },
	qa = { name = "QA", instructions = "Review the work and Validator's findings using available checks and real workflows. Inspect failure and edge cases where practical. On conditional routes, pass or fail according to the review outcome; fail can return feedback to Validator. On an Always route, pass when the review is complete even if it found defects; fail only if blocked or unable to complete it. Give specific feedback, what was checked and any gaps; do not claim unrun checks." },
	researcher = { name = "Researcher", instructions = "Investigate the assigned question using relevant primary sources and project context. Separate facts from assumptions, cite sources and report concise findings and uncertainty." },
	finish = { name = "Finish", instructions = "" },
}

local blocks = {
	team = { name = "Team", version = 3, child = true },
	changes = { name = "Changes", version = 4 },
	check = { name = "Check", version = 4 },
	draft = { name = "Draft", version = 4 },
	foreach = { name = "For each", version = 4, child = true },
	collect = { name = "Collect", version = 4 },
}
local predicates = { docs = true, files = true, ci = true }
local default_predicate, default_limit = "docs", 4

M.options = {}
for _, kind in { "planner", "worker", "validator", "auditor", "qa", "researcher", "changes", "check", "draft", "collect", "finish" } do
	table.insert(M.options, { value = kind, label = (templates[kind] or blocks[kind]).name })
end

function M.role(kind)
	return templates[kind] ~= nil and kind ~= "finish"
end

function M.instructions(kind)
	return if templates[kind] then templates[kind].instructions else ""
end

function M.copy(value)
	if type(value) ~= "table" then return value end
	local result = {}
	for key, item in value do result[key] = M.copy(item) end
	return result
end

function M.valid_icon(text)
	if type(text) ~= "string" or #text > 16384 then return false end
	if text == "" then return true end
	local lower = string.lower(text)
	return string.find(lower, "<svg", 1, true) ~= nil and string.find(lower, "</svg", 1, true) ~= nil
		and not string.find(lower, "<!", 1, true) and not string.find(lower, "<script", 1, true)
		and not string.find(lower, "<image", 1, true) and not string.find(lower, "<foreignobject", 1, true)
		and not string.find(lower, "href%s*=") and not string.find(lower, "url%s*%(")
end

local function edge_settings_error(edge, kind)
	if edge.condition ~= nil and edge.condition ~= "always" and edge.condition ~= "pass" and edge.condition ~= "fail" then
		return "A connection has an invalid condition"
	end
	if kind == "check" then
		if edge.condition ~= "pass" and edge.condition ~= "fail" then return "Check needs pass and fail exits" end
		if edge.max_retries ~= nil then return "Check exits cannot have retry limits" end
	elseif blocks[kind] and edge.condition ~= nil and edge.condition ~= "always" then
		return blocks[kind].name .. " can only have one Always exit"
	end
	if edge.max_retries ~= nil and (edge.condition ~= "fail" or type(edge.max_retries) ~= "number"
		or edge.max_retries ~= math.floor(edge.max_retries) or edge.max_retries < 1 or edge.max_retries > 10) then
		return "A retry limit must be an integer from 1 to 10 on a fail connection"
	end
	return nil
end

local settings = { "instructions", "harness", "provider", "model", "icon", "icon_name" }
local validate_routes

local function valid_position(x, y)
	return type(x) == "number" and type(y) == "number" and math.abs(x) <= 1000000 and math.abs(y) <= 1000000
end

local function inspect(value, embedded)
	if type(value) ~= "table" or (value.version ~= 2 and (embedded or (value.version ~= 3 and value.version ~= 4))) then
		return nil, if embedded then "Embedded teams require a version 2 team without nested blocks" else "Expected a version 2, 3 or 4 team JSON file"
	end
	if type(value.name) ~= "string" or #value.name > 256 or not string.find(value.name, "%S")
		or type(value.nodes) ~= "table" or type(value.edges) ~= "table" then
		return nil, "Invalid team name, blocks or connections"
	end
	local ids, max_id, count, chief = {}, 1, 0, false
	for index, node in value.nodes do
		count += 1
		if type(index) ~= "number" or index ~= count or count > 32 or type(node) ~= "table" then return nil, "A team must have 1–32 blocks" end
		local id = if type(node.id) == "string" and string.match(node.id, "^[1-9]%d*$") then tonumber(node.id) else nil
		if not id or id > 1000000000 or ids[node.id] then return nil, "Block IDs must be unique positive integers" end
		local block = blocks[node.kind]
		if block then
			if embedded or value.version < block.version then
				return nil, block.name .. " blocks require a version " .. tostring(block.version) .. " or later parent"
			end
		elseif node.kind ~= "chief" and not templates[node.kind] then
			return nil, "Unknown block type"
		end
		if node.team ~= nil and not (block and block.child) then return nil, "Only Team and For each blocks may embed a team" end
		if node.kind == "chief" then
			if node.id ~= "1" or chief then return nil, "A team needs one Chief with ID 1" end
			chief = true
		end
		if type(node.name) ~= "string" or #node.name > 256 or not valid_position(node.x, node.y) then
			return nil, "A block has an invalid name or position"
		end
		for _, field in settings do
			if node[field] ~= nil and (type(node[field]) ~= "string" or #node[field] > 100000) then return nil, "A block has invalid settings" end
		end
		if not M.valid_icon(node.icon or "") then return nil, "A block has an invalid custom icon" end
		if node.kind == "check" and node.predicate ~= nil and not predicates[node.predicate] then
			return nil, "Check predicate must be docs, files or ci"
		end
		if node.kind == "foreach" then
			local limit = node.limit
			if limit ~= nil and (type(limit) ~= "number" or limit ~= math.floor(limit) or limit < 1 or limit > 8) then
				return nil, "For each limit must be an integer from 1 to 8"
			end
			if node.items ~= nil and (type(node.items) ~= "string" or #node.items > 4096) then
				return nil, "For each manual items must be newline-separated text (up to 4096 bytes)"
			end
		end
		if block and block.child then
			local child, err = inspect(node.team, true)
			if not child then return nil, node.name .. ": " .. err end
		end
		ids[node.id], max_id = node.kind, math.max(max_id, id)
	end
	if not chief then return nil, "A team needs one Chief with ID 1" end
	local edges, block_exits, edge_count = {}, {}, 0
	for index, edge in value.edges do
		edge_count += 1
		if type(index) ~= "number" or index ~= edge_count or edge_count > 1024 or type(edge) ~= "table"
			or type(edge.from) ~= "string" or type(edge.to) ~= "string" or not ids[edge.from] or not ids[edge.to]
			or edge.from == edge.to or ids[edge.from] == "finish" or ids[edge.to] == "chief" then
			return nil, "A connection has invalid endpoints"
		end
		local kind = ids[edge.from]
		local settings_error = edge_settings_error(edge, kind)
		if settings_error then return nil, settings_error end
		local key = edge.from .. ":" .. edge.to
		if edges[key] then return nil, "Duplicate connection" end
		edges[key] = true
		if blocks[kind] then
			local exit_key = edge.from .. ":" .. (edge.condition or "always")
			if block_exits[exit_key] then
				return nil, if kind == "check" then "Check can only have one pass and one fail exit" else blocks[kind].name .. " can only have one Always exit"
			end
			block_exits[exit_key] = true
		end
	end
	if embedded then
		local issues = validate_routes(value)
		if issues[1] then return nil, issues[1].message end
	end
	return max_id
end

local function next_block_id(value, max_id)
	local next_id = value.next_id
	if type(next_id) ~= "number" or next_id ~= math.floor(next_id) or next_id <= max_id or next_id > 1000000001 then
		return max_id + 1
	end
	return next_id
end

local function snapshot(value, max_id)
	local result = { version = value.version, name = value.name, next_id = next_block_id(value, max_id), nodes = {}, edges = {} }
	for _, node in value.nodes do
		local imported = { id = node.id, kind = node.kind, name = node.name, x = node.x, y = node.y }
		for _, field in settings do imported[field] = node[field] or "" end
		if node.kind == "check" then imported.predicate = node.predicate or default_predicate end
		if node.kind == "foreach" then
			imported.limit = node.limit or default_limit
			imported.items = node.items
		end
		local block = blocks[node.kind]
		if block and block.child then
			local child_max = 1
			for _, child_node in node.team.nodes do child_max = math.max(child_max, tonumber(child_node.id)) end
			imported.team = snapshot(node.team, child_max)
		end
		table.insert(result.nodes, imported)
	end
	for _, edge in value.edges do
		table.insert(result.edges, { from = edge.from, to = edge.to, condition = edge.condition, max_retries = edge.max_retries })
	end
	return result
end

function M.import(value)
	local max_id, err = inspect(value, false)
	if not max_id then return nil, err end
	return snapshot(value, max_id)
end

function M.initial()
	return {
		version = 2,
		name = "Plan, build, review",
		next_id = 7,
		nodes = {
			{ id = "1", kind = "chief", name = "Chief", x = 300, y = 48, instructions = "", harness = "", model = "" },
			{ id = "2", kind = "planner", name = "Planner", x = 300, y = 228, instructions = templates.planner.instructions, harness = "", model = "" },
			{ id = "3", kind = "worker", name = "Worker", x = 300, y = 408, instructions = templates.worker.instructions, harness = "", model = "" },
			{ id = "4", kind = "validator", name = "Validator", x = 300, y = 588, instructions = templates.validator.instructions, harness = "", model = "" },
			{ id = "5", kind = "finish", name = "Finish", x = 300, y = 768, instructions = "", harness = "", model = "" },
			{ id = "6", kind = "qa", name = "QA", x = 600, y = 768, instructions = templates.qa.instructions, harness = "", model = "" },
		},
		edges = {
			{ from = "1", to = "2", condition = "always" },
			{ from = "2", to = "3", condition = "always" },
			{ from = "3", to = "4", condition = "always" },
			{ from = "4", to = "6", condition = "always" },
			{ from = "6", to = "4", condition = "fail", max_retries = 3 },
			{ from = "6", to = "5", condition = "pass" },
		},
	}
end

function M.node(team, id)
	for _, node in team.nodes do if node.id == id then return node end end
	return nil
end

function M.add(team, kind, x, y)
	local block = blocks[kind]
	local template = templates[kind] or block
	if not template or (block and block.child) or #team.nodes >= 32 or team.next_id > 1000000000 then return nil end
	local node = { id = tostring(team.next_id), kind = kind, name = template.name, x = x, y = y, instructions = template.instructions or "", harness = "", model = "" }
	if kind == "check" then node.predicate = default_predicate end
	if block then team.version = math.max(team.version, block.version) end
	team.next_id += 1
	table.insert(team.nodes, node)
	return node
end

function M.add_team(parent, source, x, y, kind)
	if kind == nil then kind = "team" end
	local block = blocks[kind]
	if not block or not block.child then return nil, "Expected a Team or For each block" end
	local max_id, err = inspect(parent, false)
	if not max_id then return nil, err end
	if #parent.nodes >= 32 then return nil, "A team must have 1–32 blocks" end
	if not valid_position(x, y) then return nil, "Invalid " .. block.name .. " block position" end
	local next_id = next_block_id(parent, max_id)
	if next_id > 1000000000 then return nil, "No block IDs remain" end
	local source_max, source_err = inspect(source, true)
	if not source_max then return nil, source_err end
	local node = { id = tostring(next_id), kind = kind, name = source.name, x = x, y = y, instructions = "", harness = "", model = "", team = snapshot(source, source_max) }
	if kind == "foreach" then node.limit = default_limit end
	parent.version, parent.next_id = math.max(parent.version, block.version), next_id + 1
	table.insert(parent.nodes, node)
	return node
end

function M.connect(team, from, to)
	local source, target = M.node(team, from), M.node(team, to)
	if not source or not target or from == to or source.kind == "finish" or target.kind == "chief" then return false end
	if (target.kind == "collect") ~= (source.kind == "foreach") then return false end
	local pass, fail = false, false
	for _, edge in team.edges do
		if edge.from == from then
			if edge.to == to or (blocks[source.kind] and source.kind ~= "check") then return false end
			if edge.condition == "pass" then pass = true elseif edge.condition == "fail" then fail = true end
		end
	end
	if source.kind == "check" and pass and fail then return false end
	local condition = if source.kind ~= "check" then "always" elseif pass then "fail" else "pass"
	table.insert(team.edges, { from = from, to = to, condition = condition })
	return true
end

function M.remove(team, id)
	local node = M.node(team, id)
	if not node or node.kind == "chief" then return end
	for i = #team.nodes, 1, -1 do if team.nodes[i].id == id then table.remove(team.nodes, i) end end
	for i = #team.edges, 1, -1 do
		local edge = team.edges[i]
		if edge.from == id or edge.to == id then table.remove(team.edges, i) end
	end
	if blocks[node.kind] then
		local version = 2
		for _, remaining in team.nodes do
			local block = blocks[remaining.kind]
			if block then version = math.max(version, block.version) end
		end
		team.version = version
	end
end

validate_routes = function(team)
	local issues, incoming, outgoing, nodes, edges = {}, {}, {}, {}, {}
	local function issue(id, message) table.insert(issues, { id = id, message = message }) end
	local chief
	for _, node in team.nodes do
		if nodes[node.id] then issue(node.id, "Block IDs must be unique") end
		nodes[node.id], incoming[node.id], outgoing[node.id] = node, 0, {}
		if node.kind == "chief" then
			if chief then issue(node.id, "A team needs one Chief") else chief = node end
		end
	end
	for _, edge in team.edges do
		if type(edge) ~= "table" or type(edge.from) ~= "string" or type(edge.to) ~= "string"
			or not nodes[edge.from] or not nodes[edge.to] then
			issue(nil, "A connection points to a missing block")
		else
			local key = edge.from .. ":" .. edge.to
			if edges[key] then issue(edge.from, "Duplicate connection") end
			edges[key] = true
			if edge.from == edge.to or nodes[edge.from].kind == "finish" or nodes[edge.to].kind == "chief" then
				issue(edge.from, "A connection has invalid endpoints")
			end
			local from_kind, to_kind = nodes[edge.from].kind, nodes[edge.to].kind
			local settings_error = edge_settings_error(edge, from_kind)
			if settings_error then issue(edge.from, settings_error) end
			if edge.condition == "fail" and to_kind == "finish" and from_kind ~= "check" then
				issue(edge.from, "A fail connection cannot lead to Finish")
			end
			if to_kind == "collect" and from_kind ~= "foreach" then
				issue(edge.to, "Collect must directly follow For each")
			elseif from_kind == "foreach" and to_kind ~= "collect" then
				issue(edge.from, "For each must connect directly to Collect")
			end
			table.insert(outgoing[edge.from], edge)
			incoming[edge.to] += 1
		end
	end
	local function reaches(start, target, excluded)
		local seen = {}
		local function visit(id)
			if id == target then return true end
			if seen[id] then return false end
			seen[id] = true
			for _, edge in outgoing[id] do
				if edge ~= excluded and visit(edge.to) then return true end
			end
			return false
		end
		return visit(start)
	end
	for _, list in outgoing do
		for _, edge in list do
			if edge.condition == "fail" and nodes[edge.from].kind ~= "check" then
				local is_return = reaches(edge.to, edge.from, edge)
				if is_return and edge.max_retries == nil then
					issue(edge.from, "A failure return needs a retry limit")
				elseif edge.max_retries ~= nil and not is_return then
					issue(edge.from, "A limited failure must return to a preceding block")
				end
			end
		end
	end
	local reachable = {}
	local function mark(id)
		if reachable[id] then return end
		reachable[id] = true
		for _, edge in outgoing[id] do mark(edge.to) end
	end
	if chief then mark(chief.id) else issue(nil, "Add a Chief") end
	local visited, visiting = {}, {}
	local function walk(id)
		if visiting[id] then issue(id, "Loop has no retry limit on every route") return end
		if visited[id] then return end
		visiting[id], visited[id] = true, true
		for _, edge in outgoing[id] do
			if not (edge.condition == "fail" and edge.max_retries ~= nil and not edge_settings_error(edge, nodes[id].kind)) then walk(edge.to) end
		end
		visiting[id] = nil
	end
	for _, node in team.nodes do if not visited[node.id] then walk(node.id) end end
	local finish = false
	for _, node in team.nodes do
		if not string.find(node.name or "", "%S") then issue(node.id, "Add a name") end
		if node.kind ~= "chief" and incoming[node.id] == 0 then issue(node.id, "Connect an input") end
		local routes = outgoing[node.id]
		if node.kind == "check" then
			if #routes ~= 2 then issue(node.id, "Connect both Check exits (pass and fail)") end
		elseif node.kind ~= "finish" then
			if #routes == 0 then
				issue(node.id, "Connect an output")
			elseif #routes == 1 then
				if routes[1].condition ~= nil and routes[1].condition ~= "always" then issue(node.id, "Use one always connection or one pass and one fail connection") end
			else
				local pass, fail = 0, 0
				for _, edge in routes do
					if edge.condition == "pass" then pass += 1 elseif edge.condition == "fail" then fail += 1 end
				end
				if node.kind == "chief" or #routes ~= 2 or pass ~= 1 or fail ~= 1 then
					issue(node.id, "Use one always connection or one pass and one fail connection on a role")
				end
			end
		end
		if not reachable[node.id] then issue(node.id, "Connect this block to the Chief") end
		if not blocks[node.kind] then
			if M.role(node.kind) and not string.find(node.instructions or "", "%S") then issue(node.id, "Add role instructions") end
			if (node.model or "") ~= "" and (node.harness or "") == "" then issue(node.id, "Choose an agent for this model") end
			if (node.provider or "") ~= "" and (node.model or "") == "" then issue(node.id, "Choose a model for this provider") end
		end
		if node.kind == "finish" and reachable[node.id] then finish = true end
	end
	if not finish then issue(nil, "Connect a Finish block to the Chief") end
	return issues
end

function M.validate(team)
	local valid, err = inspect(team, false)
	if not valid then return { { message = err } } end
	return validate_routes(team)
end

return M
