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

M.options = {}
for _, kind in { "planner", "worker", "validator", "auditor", "qa", "researcher", "finish" } do
	table.insert(M.options, { value = kind, label = templates[kind].name })
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

local function edge_settings_error(edge)
	if edge.condition ~= nil and edge.condition ~= "always" and edge.condition ~= "pass" and edge.condition ~= "fail" then
		return "A connection has an invalid condition"
	end
	if edge.max_retries ~= nil and (edge.condition ~= "fail" or type(edge.max_retries) ~= "number"
		or edge.max_retries ~= math.floor(edge.max_retries) or edge.max_retries < 1 or edge.max_retries > 10) then
		return "A retry limit must be an integer from 1 to 10 on a fail connection"
	end
	return nil
end

function M.import(value)
	if type(value) ~= "table" or value.version ~= 2 or type(value.name) ~= "string" or #value.name > 256
		or not string.find(value.name, "%S") or type(value.nodes) ~= "table" or type(value.edges) ~= "table" then
		return nil, "Expected a version 2 team JSON file"
	end
	local result = M.copy(value)
	result.nodes, result.edges = {}, {}
	local ids, max_id, count, chief = {}, 1, 0, false
	for index, node in value.nodes do
		count += 1
		if type(index) ~= "number" or index ~= count or count > 32 or type(node) ~= "table" then return nil, "A team must have 1–32 blocks" end
		local id = if type(node.id) == "string" and string.match(node.id, "^[1-9]%d*$") then tonumber(node.id) else nil
		if not id or id > 1000000000 or ids[node.id] then return nil, "Block IDs must be unique positive integers" end
		if node.kind ~= "chief" and not templates[node.kind] then return nil, "Unknown block type" end
		if node.kind == "chief" then
			if node.id ~= "1" or chief then return nil, "A team needs one Chief with ID 1" end
			chief = true
		end
		if type(node.name) ~= "string" or #node.name > 256 or type(node.x) ~= "number" or type(node.y) ~= "number"
			or node.x ~= node.x or node.y ~= node.y or math.abs(node.x) > 1000000 or math.abs(node.y) > 1000000 then
			return nil, "A block has an invalid name or position"
		end
		for _, field in { "instructions", "harness", "provider", "model", "icon", "icon_name" } do
			if node[field] ~= nil and (type(node[field]) ~= "string" or #node[field] > 100000) then return nil, "A block has invalid settings" end
		end
		if not M.valid_icon(node.icon or "") then return nil, "A block has an invalid custom icon" end
		ids[node.id], max_id = node.kind, math.max(max_id, id)
		local imported = M.copy(node)
		for _, field in { "instructions", "harness", "provider", "model", "icon", "icon_name" } do
			if imported[field] == nil then imported[field] = "" end
		end
		table.insert(result.nodes, imported)
	end
	if not chief then return nil, "A team needs one Chief with ID 1" end
	local edges, edge_count = {}, 0
	for index, edge in value.edges do
		edge_count += 1
		if type(index) ~= "number" or index ~= edge_count or edge_count > 1024 or type(edge) ~= "table"
			or type(edge.from) ~= "string" or type(edge.to) ~= "string" or not ids[edge.from] or not ids[edge.to]
			or edge.from == edge.to or ids[edge.from] == "finish" or ids[edge.to] == "chief" then
			return nil, "A connection has invalid endpoints"
		end
		local settings_error = edge_settings_error(edge)
		if settings_error then return nil, settings_error end
		local key = edge.from .. ":" .. edge.to
		if edges[key] then return nil, "Duplicate connection" end
		edges[key] = true
		table.insert(result.edges, M.copy(edge))
	end
	if type(result.next_id) ~= "number" or result.next_id ~= math.floor(result.next_id)
		or result.next_id <= max_id or result.next_id > 1000000001 then
		result.next_id = max_id + 1
	end
	return result
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
	local template = templates[kind]
	if not template or #team.nodes >= 32 then return nil end
	local node = { id = tostring(team.next_id), kind = kind, name = template.name, x = x, y = y, instructions = template.instructions, harness = "", model = "" }
	team.next_id += 1
	table.insert(team.nodes, node)
	return node
end

function M.connect(team, from, to)
	local source, target = M.node(team, from), M.node(team, to)
	if not source or not target or from == to or source.kind == "finish" or target.kind == "chief" then return false end
	for _, edge in team.edges do if edge.from == from and edge.to == to then return false end end
	table.insert(team.edges, { from = from, to = to, condition = "always" })
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
end

function M.validate(team)
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
			local settings_error = edge_settings_error(edge)
			if settings_error then issue(edge.from, settings_error) end
			if edge.condition == "fail" and nodes[edge.to].kind == "finish" then
				issue(edge.from, "A fail connection cannot lead to Finish")
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
			if edge.condition == "fail" then
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
			if not (edge.condition == "fail" and edge.max_retries ~= nil and not edge_settings_error(edge)) then walk(edge.to) end
		end
		visiting[id] = nil
	end
	for _, node in team.nodes do if not visited[node.id] then walk(node.id) end end
	local finish = false
	for _, node in team.nodes do
		if not string.find(node.name or "", "%S") then issue(node.id, "Add a name") end
		if node.kind ~= "chief" and incoming[node.id] == 0 then issue(node.id, "Connect an input") end
		local routes = outgoing[node.id]
		if node.kind ~= "finish" then
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
		if node.kind ~= "chief" and node.kind ~= "finish" and not string.find(node.instructions or "", "%S") then issue(node.id, "Add role instructions") end
		if node.model ~= "" and node.harness == "" then issue(node.id, "Choose an agent for this model") end
		if node.provider and node.provider ~= "" and node.model == "" then issue(node.id, "Choose a model for this provider") end
		if node.kind == "finish" and reachable[node.id] then finish = true end
	end
	if not finish then issue(nil, "Connect a Finish block to the Chief") end
	return issues
end

return M
