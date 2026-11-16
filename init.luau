local zeron = require("./zeron")("orchestrator-builder")
local graph = require("./graph")
local runner = require("./runner").create(zeron, graph)
local Text = require("@ds/text")
local Button = require("@ds/button")
local TextField = require("@ds/text_field")
local TextArea = require("@ds/text_area")
local Select = require("@ds/select")
local Glass = require("@ds/glass")
local Dialog = require("@ds/dialog").Dialog
local Icon = require("@ds/icon")
local IconButton = require("@ds/icon_button").IconButton
local Mark = require("@ds/mark")

local kept = zeron.store("team-v2", graph.initial())
local teams_kept = zeron.store("teams-v1", nil)
local grid_kept = zeron.store("canvas-grid", true)
local plugin_store = ui.shared("plugin.orchestrator-builder.store", {})
local agents = {
	{ value = "", label = "Default agent" },
	{ value = "pi", label = "Pi" },
	{ value = "opencode", label = "OpenCode" },
	{ value = "codex", label = "Codex" },
	{ value = "claude-code", label = "Claude Code" },
	{ value = "cursor", label = "Cursor" },
	{ value = "devin", label = "Devin" },
	{ value = "grok", label = "Grok" },
	{ value = "hermes", label = "Hermes" },
	{ value = "fx", label = "Fx" },
	{ value = "antigravity", label = "Antigravity" },
	{ value = "muse", label = "Muse" },
	{ value = "__custom", label = "Other agent" },
}

local function agent_choice(id)
	for _, agent in agents do if agent.value == id then return id end end
	return if id == "" then "" else "__custom"
end

local add_options = { { value = "", label = "Add block" } }
for _, option in graph.options do table.insert(add_options, option) end

local Builder = ui.component(function()
	local previous = kept:peek() or graph.initial()
	local saved_teams = teams_kept:peek()
	local initial_teams = if type(saved_teams) == "table" and type(saved_teams.teams) == "table" then saved_teams else { active = "1", next_id = 2, teams = { { id = "1", team = previous } } }
	local active_initial = previous
	for _, entry in initial_teams.teams do if entry.id == initial_teams.active then active_initial = entry.team; break end end
	local library = ui.use_state(graph.copy(initial_teams))
	local active_team = ui.use_state(initial_teams.active)
	local team = ui.use_state(graph.copy(active_initial))
	local add_choice = ui.use_state("")
	local grid = ui.use_state(grid_kept:peek() ~= false)
	local selected = ui.use_state("1")
	local selected_edge = ui.use_state(0)
	local edit_open = ui.use_state(false)
	local team_open = ui.use_state(false)
	local run_open = ui.use_state(false)
	local recovery_open = ui.use_state(false)
	local recovery_id = nil
	local task_text = ui.use_state("")
	local destination_session = ui.use_state("")
	local selected_destination = nil
	local run_error = ui.use_state("")
	local edge_condition = ui.use_state("always")
	local edge_retries = ui.use_state("")
	local transfer_status = ui.use_state("")
	local initial = graph.node(team:peek(), "1") or {}
	local name = ui.use_state(initial.name or "Chief")
	local instructions = ui.use_state(initial.instructions or "")
	local icon_svg = ui.use_state(initial.icon or "")
	local icon_name = ui.use_state(initial.icon_name or "")
	local icon_error = ui.use_state("")
	local harness = ui.use_state(initial.harness or "")
	local agent = ui.use_state(agent_choice(initial.harness or ""))
	local model = ui.use_state(initial.model or "")
	local model_provider = ui.use_state(initial.provider or string.match(initial.model or "", "^([^/]+)/") or "")
	local catalog = ui.use_state({})
	local catalog_status = ui.use_state("")
	local catalog_loading = ui.use_state(false)
	local catalogs = {}
	local catalog_request = 0
	local team_name = ui.use_state(team:peek().name)
	local zoom = ui.use_state(0.85)
	local pan_x = ui.use_state(0)
	local pan_y = ui.use_state(0)
	local notice = ui.use_state("")
	local canvas = ui.ref()
	local drag = nil
	local wire = ui.use_state(nil)
	local width, height = 224, 116

	local function node_height(node)
		return if node.kind == "finish" then 72 else height
	end

	local function persist(next_library, value)
		local contents = graph.copy(plugin_store:peek() or {})
		contents["team-v2"] = value
		contents["teams-v1"] = next_library
		if #ui.json.encode(contents) > 950000 then
			notice:set("Storage is full. Remove custom icons before saving")
			return false
		end
		library:set(next_library)
		team:set(value)
		teams_kept:set(next_library)
		kept:set(value)
		return true
	end

	local function save(value)
		local next_library = graph.copy(library:peek())
		for _, entry in next_library.teams do
			if entry.id == next_library.active then entry.team = graph.copy(value); break end
		end
		return persist(next_library, value)
	end

	local function load_models(id)
		catalog_request += 1
		local request = catalog_request
		catalog:set({})
		catalog_status:set("")
		catalog_loading:set(false)
		if id == "" then return end
		if catalogs[id] then catalog:set(catalogs[id]); return end
		catalog_loading:set(true)
		zeron.models(id, {}):after(function(items)
			if request ~= catalog_request then return end
			catalog_loading:set(false)
			if type(items) ~= "table" then catalog_status:set("Model catalog unavailable"); return end
			local options = {}
			for _, item in items do
				if type(item.id) == "string" then table.insert(options, { value = item.id, label = item.label or item.id, provider = string.match(item.id, "^([^/]+)/") or "" }) end
			end
			catalogs[id] = options
			catalog:set(options)
			if #options == 0 then catalog_status:set("No models returned for this agent") end
		end, function(err)
			if request ~= catalog_request then return end
			catalog_loading:set(false)
			catalog_status:set("Could not load models: " .. tostring(err))
		end)
	end

	local function destination_of(session, projects)
		if type(session) ~= "table" then return nil end
		local device, project = session.device, session.project
		if device == ui.null then device = nil end
		if project == ui.null then project = nil end
		if device ~= nil and (type(device) ~= "string" or not string.find(device, "%S")) then return nil end
		if project ~= nil then
			if type(project) ~= "string" or not string.find(project, "%S") then return nil end
			local entry = projects[project]
			if type(entry) ~= "table" or type(entry.device) ~= "string" or not string.find(entry.device, "%S") then return nil end
			if device and device ~= entry.device then return nil end
			device = entry.device
		end
		if not device then return nil end
		return { device = device, project = project }
	end

	local function destination_options()
		local options = { { value = "", label = "Select session" } }
		local projects = zeron.projects()
		for id, session in zeron.sessions() do
			local destination = destination_of(session, projects)
			if type(id) == "string" and string.find(id, "%S") and destination then
				local title = if type(session.title) == "string" and string.find(session.title, "%S") then session.title else "Untitled"
				local label = title .. " · " .. id .. " · device " .. destination.device
				if destination.project then label ..= " · project " .. destination.project end
				table.insert(options, { value = id, label = label })
			end
		end
		table.sort(options, function(a, b)
			if a.value == "" then return b.value ~= "" end
			if b.value == "" then return false end
			return a.label < b.label
		end)
		return options
	end

	local function select_node(id)
		local node = graph.node(team:peek(), id)
		if not node then return end
		selected:set(id)
		selected_edge:set(0)
		name:set(node.name or "")
		instructions:set(node.instructions or "")
		icon_svg:set(node.icon or "")
		icon_name:set(node.icon_name or "")
		icon_error:set("")
		harness:set(node.harness or "")
		agent:set(agent_choice(node.harness or ""))
		model:set(node.model or "")
		model_provider:set(node.provider or string.match(node.model or "", "^([^/]+)/") or "")
		load_models(node.harness or "")
	end

	local function provider_options()
		local options, seen = { { value = "", label = "All providers" } }, {}
		for _, option in catalog:get() do
			if option.provider ~= "" and not seen[option.provider] then
				seen[option.provider] = true
				table.insert(options, { value = option.provider, label = option.provider })
			end
		end
		local current = model_provider:get()
		if current ~= "" and not seen[current] then table.insert(options, { value = current, label = current }) end
		return options
	end

	local function model_options()
		local options = { { value = "", label = "Default model" } }
		local current, provider, found = model:get(), model_provider:get(), false
		for _, option in catalog:get() do
			if option.value == current then found = true end
			if provider == "" or option.provider == provider then table.insert(options, { value = option.value, label = option.label }) end
		end
		if current ~= "" and not found then table.insert(options, { value = current, label = current .. " (saved)" }) end
		return options
	end

	local function add(kind)
		local value = graph.copy(team:peek())
		local index = #value.nodes
		local node = graph.add(value, kind, 100 + (index % 3) * 240, 120 + math.floor(index / 3) * 160)
		if node then
			if save(value) then select_node(node.id) end
		else
			notice:set("A team can have up to 32 blocks")
		end
	end

	local edge_curves

	local function fit()
		local value = team:peek()
		local left, top, right, bottom = math.huge, math.huge, -math.huge, -math.huge
		for _, node in value.nodes do
			left, top = math.min(left, node.x), math.min(top, node.y)
			right, bottom = math.max(right, node.x + width), math.max(bottom, node.y + node_height(node))
		end
		for _, p in edge_curves(value) do
			left, top = math.min(left, p[3], p[5]), math.min(top, p[4], p[6])
			right, bottom = math.max(right, p[3], p[5]), math.max(bottom, p[4], p[6])
		end
		local w, h = canvas.width or 640, canvas.height or 500
		local z = math.clamp(math.min((w - 96) / math.max(right - left, 1), (h - 96) / math.max(bottom - top, 1)), 0.35, 1.6)
		zoom:set(z)
		pan_x:set((w - (right - left) * z) / 2 - left * z)
		pan_y:set((h - (bottom - top) * z) / 2 - top * z)
	end

	local function team_options()
		local options = {}
		for _, entry in library:get().teams do table.insert(options, { value = entry.id, label = entry.team.name }) end
		return options
	end

	local function open_team(id)
		local next_library = graph.copy(library:peek())
		local value
		for _, entry in next_library.teams do if entry.id == id then value = graph.copy(entry.team); break end end
		if not value then active_team:set(next_library.active); return end
		next_library.active = id
		if not persist(next_library, value) then active_team:set(library:peek().active); return end
		active_team:set(id)
		team_name:set(value.name)
		select_node("1")
		team_open:set(false)
		ui.after(0, fit)
	end

	local function new_team()
		local next_library = graph.copy(library:peek())
		local id, value = tostring(next_library.next_id), graph.initial()
		next_library.next_id += 1
		next_library.active = id
		table.insert(next_library.teams, { id = id, team = graph.copy(value) })
		if not persist(next_library, value) then return end
		active_team:set(id)
		team_name:set(value.name)
		select_node("1")
		team_open:set(false)
		ui.after(0, fit)
		notice:set("New team created")
	end

	local function import_team()
		transfer_status:set("")
		ui.open_files({ title = "Import team", filters = { { "JSON", { "json" } } } }):after(function(files)
			local file = files and files[1]
			if not file then return end
			if (file.size or 0) > 500000 then transfer_status:set("Choose a JSON file under 500 KB"); return end
			ui.read_file(file):after(function(text)
				if #text > 500000 then transfer_status:set("Choose a JSON file under 500 KB"); return end
				local ok, decoded = pcall(ui.json.decode, text)
				if not ok then transfer_status:set("Invalid JSON file"); return end
				local value, err = graph.import(decoded)
				if not value then transfer_status:set(err); return end
				local next_library = graph.copy(library:peek())
				local id = tostring(next_library.next_id)
				next_library.next_id += 1
				next_library.active = id
				table.insert(next_library.teams, { id = id, team = graph.copy(value) })
				if not persist(next_library, value) then transfer_status:set("Not enough storage to import this team"); return end
				active_team:set(id)
				team_name:set(value.name)
				select_node("1")
				team_open:set(false)
				ui.after(0, fit)
				notice:set("Team imported")
			end, function(err) transfer_status:set("Could not read file: " .. tostring(err)) end)
		end, function(err) transfer_status:set("Could not choose file: " .. tostring(err)) end)
	end

	local function export_team()
		transfer_status:set("")
		local value = graph.copy(team:peek())
		local filename = string.gsub(value.name, '[<>:"/\\|%?%*%c]', "_")
		ui.save_file({ title = "Export team", name = filename .. ".json", filters = { { "JSON", { "json" } } } }):after(function(file)
			if not file then return end
			ui.write_file(file, ui.json.encode(value, { pretty = true })):after(function()
				transfer_status:set("Team exported")
			end, function(err) transfer_status:set("Could not save file: " .. tostring(err)) end)
		end, function(err) transfer_status:set("Could not choose location: " .. tostring(err)) end)
	end

	local function zoom_at(value, x, y)
		local old = zoom:peek()
		local next_zoom = math.clamp(value, 0.35, 2)
		if next_zoom == old then return end
		pan_x:set(x - (x - pan_x:peek()) * next_zoom / old)
		pan_y:set(y - (y - pan_y:peek()) * next_zoom / old)
		zoom:set(next_zoom)
	end

	local function wheel(e)
		if e.dy ~= 0 then
			local delta = math.clamp(e.dy, -120, 120)
			zoom_at(zoom:peek() * math.exp(-delta * 0.002), e.local_x or (canvas.width or 0) / 2, e.local_y or (canvas.height or 0) / 2)
		end
		return true
	end

	local function point(e)
		return ((e.local_x or 0) - pan_x:peek()) / zoom:peek(), ((e.local_y or 0) - pan_y:peek()) / zoom:peek()
	end

	local function near(x, y, a, b, radius)
		return (x - a) ^ 2 + (y - b) ^ 2 <= radius ^ 2
	end

	edge_curves = function(value)
		local curves, lanes, nodes = {}, {}, {}
		for _, node in value.nodes do nodes[node.id] = node end
		for i, edge in value.edges do
			local a, b = nodes[edge.from], nodes[edge.to]
			if a and b then
				local x1, y1, x2, y2 = a.x + width / 2, a.y + height, b.x + width / 2, b.y
				local key = if x1 == x2 then "vertical:" .. tostring(x1) else table.concat({ x1, y1, x2, y2 }, ":")
				local lane = lanes[key] or 0
				lanes[key] = lane + 1
				local reach = math.max(48, math.abs(y2 - y1) * 0.48)
				local offset = if y2 <= y1 then 110 + i * 24 else lane * 44
				curves[i] = { x1, y1, x1 + offset, y1 + reach, x2 + offset, y2 - reach, x2, y2 }
			end
		end
		return curves
	end

	local function curve(p, t)
		local s = 1 - t
		return s ^ 3 * p[1] + 3 * s ^ 2 * t * p[3] + 3 * s * t ^ 2 * p[5] + t ^ 3 * p[7],
			s ^ 3 * p[2] + 3 * s ^ 2 * t * p[4] + 3 * s * t ^ 2 * p[6] + t ^ 3 * p[8]
	end

	local function edge_distance(x, y, p)
		local nearest = math.huge
		local ax, ay = p[1], p[2]
		for i = 1, 48 do
			local bx, by = curve(p, i / 48)
			local dx, dy = bx - ax, by - ay
			local length = dx * dx + dy * dy
			local t = if length == 0 then 0 else math.clamp(((x - ax) * dx + (y - ay) * dy) / length, 0, 1)
			nearest = math.min(nearest, math.sqrt((x - ax - t * dx) ^ 2 + (y - ay - t * dy) ^ 2))
			ax, ay = bx, by
		end
		return nearest
	end

	local function press(e)
		local x, y = point(e)
		local value = team:peek()
		for i = #value.nodes, 1, -1 do
			local node = value.nodes[i]
			if node.kind ~= "finish" and near(x, y, node.x + width / 2, node.y + height, 14) then
				select_node(node.id)
				drag = { kind = "wire", from = node.id }
				wire:set({ from = node.id, x = x, y = y })
				return
			end
			if x >= node.x and x <= node.x + width and y >= node.y and y <= node.y + node_height(node) then
				select_node(node.id)
				drag = { kind = "node", id = node.id, x = x, y = y, nx = node.x, ny = node.y }
				return
			end
		end
		local closest, distance = 0, 8 / zoom:peek()
		local curves = edge_curves(value)
		for i, edge in value.edges do
			local p = curves[i]
			local d = if p then edge_distance(x, y, p) else math.huge
			if d < distance then closest, distance = i, d end
		end
		if closest > 0 then
			local edge = value.edges[closest]
			selected:set("")
			selected_edge:set(closest)
			edge_condition:set(edge.condition or "always")
			edge_retries:set(if edge.max_retries then tostring(edge.max_retries) else "")
			edit_open:set(true)
			return
		end
		selected:set("")
		selected_edge:set(0)
		drag = { kind = "pan", x = e.local_x or 0, y = e.local_y or 0, px = pan_x:peek(), py = pan_y:peek() }
	end

	local function move(e)
		if not drag then return end
		if drag.kind == "pan" then
			pan_x:set(drag.px + (e.local_x or 0) - drag.x)
			pan_y:set(drag.py + (e.local_y or 0) - drag.y)
		elseif drag.kind == "wire" then
			local x, y = point(e)
			wire:set({ from = drag.from, x = x, y = y })
		elseif drag.kind == "node" then
			local x, y = point(e)
			local value = graph.copy(team:peek())
			local node = graph.node(value, drag.id)
			if node then node.x = drag.nx + x - drag.x; node.y = drag.ny + y - drag.y; team:set(value) end
		end
	end

	local function release(e)
		if not drag then return end
		if drag.kind == "wire" then
			local x, y = point(e)
			local value = graph.copy(team:peek())
			local connected = false
			for _, node in value.nodes do
				if node.kind ~= "chief" and near(x, y, node.x + width / 2, node.y, 18) then
					connected = graph.connect(value, drag.from, node.id)
					break
				end
			end
			if connected then
				if save(value) then notice:set("Connection added") end
			else
				notice:set("Drag from an output to another block’s input")
			end
			wire:set(nil)
		elseif drag.kind == "node" then
			if not save(team:peek()) then
				local value = graph.copy(library:peek())
				for _, entry in value.teams do if entry.id == value.active then team:set(entry.team); break end end
			end
		end
		drag = nil
	end

	local function draw_grid(c, w, h)
		if not grid:get() then return end
		local step = 32 * zoom:get()
		while step < 20 do step *= 2 end
		local x0, y0 = pan_x:get() % step, pan_y:get() % step
		for x = x0, w, step do
			for y = y0, h, step do c:circle(x, y, 1, "$border.strong") end
		end
	end

	local function draw_edges(c)
		local value, z, px, py = team:get(), zoom:get(), pan_x:get(), pan_y:get()
		local edge_index, pending = selected_edge:get(), wire:get()
		local function sx(x) return px + x * z end
		local function sy(y) return py + y * z end
		local function line(p, color, label)
			local path = ui.path():move(sx(p[1]), sy(p[2])):cubic(sx(p[3]), sy(p[4]), sx(p[5]), sy(p[6]), sx(p[7]), sy(p[8]))
			c:stroke(path, "$background", 5 * z, { cap = "round" })
			c:stroke(path, color, 1.8 * z, { cap = "round" })
			local ax, ay = curve(p, 0.66)
			local bx, by = curve(p, 0.7)
			local angle = math.atan2(by - ay, bx - ax)
			local tipx, tipy = sx(bx), sy(by)
			local size = 7 * z
			local arrow = ui.path():move(tipx - size * math.cos(angle - 0.55), tipy - size * math.sin(angle - 0.55)):line(tipx, tipy):line(tipx - size * math.cos(angle + 0.55), tipy - size * math.sin(angle + 0.55))
			c:stroke(arrow, color, 2 * z, { cap = "round", join = "round" })
			if label then
				local x, y = curve(p, 0.5)
				local size = 11 * z
				local text_width = c:measure_text(label, { size = size })
				c:rect(sx(x) - 4 * z, sy(y) - 10 * z, text_width + 8 * z, 20 * z, "$background", 4 * z)
				c:text(label, sx(x), sy(y), { size = size, color = color, baseline = "middle" })
			end
		end
		local curves = edge_curves(value)
		for i, edge in value.edges do
			local p = curves[i]
			local label = if edge.condition == "pass" then "Pass" elseif edge.condition == "fail" then (if edge.max_retries then "Fail · retry " .. tostring(edge.max_retries) else "Fail") else nil
			if p then line(p, if i == edge_index then "$accent" else "$text.secondary", label) end
		end
		if pending then
			local node = graph.node(value, pending.from)
			if node then
				local x, y = node.x + width / 2, node.y + height
				local reach = math.max(48, math.abs(pending.y - y) * 0.48)
				line({ x, y, x, y + reach, pending.x, pending.y - reach, pending.x, pending.y }, "$accent")
			end
		end
	end

	local function draw_nodes(c)
		local value, z, px, py = team:get(), zoom:get(), pan_x:get(), pan_y:get()
		local function port(x, y)
			c:circle(x, y, 7 * z, "$text.secondary")
			c:circle(x, y, 5 * z, "$zeron.menu.solid")
			c:circle(x, y, 2 * z, "$text.primary")
		end
		local function fit_text(text, max_width, size)
			if c:measure_text(text, { size = size }) <= max_width then return text end
			local length = utf8.len(text) or 0
			while length > 0 do
				local last = utf8.offset(text, length + 1)
				local short = string.sub(text, 1, if last then last - 1 else #text) .. "…"
				if c:measure_text(short, { size = size }) <= max_width then return short end
				length -= 1
			end
			return "…"
		end
		for _, node in value.nodes do
			local x, y = px + node.x * z, py + node.y * z
			c:text(fit_text(node.name, 140 * z, 14 * z), x + 44 * z, y + 24 * z, { size = 14 * z, color = "$text.primary", baseline = "middle" })
			if node.kind ~= "finish" then
				local provider = if node.provider and node.provider ~= "" then node.provider else string.match(node.model or "", "^([^/]+)/") or ""
				local model_name = if node.model ~= "" then string.match(node.model, "^[^/]+/(.+)$") or node.model else "Default model"
				local detail = if provider ~= "" then provider .. " / " .. model_name else model_name
				c:text(fit_text(detail, 172 * z, 11 * z), x + 36 * z, y + 51 * z, { size = 11 * z, color = "$text.secondary", baseline = "middle" })
				c:rect(x + 12 * z, y + 70 * z, (width - 24) * z, 32 * z, "$zeron.secondary.bg", 6 * z)
				c:circle(x + 24 * z, y + 86 * z, 3 * z, "$text.tertiary")
				c:text(if node.kind == "chief" then "Entry point" else "Configured role", x + 34 * z, y + 86 * z, { size = 11 * z, color = "$text.secondary", baseline = "middle" })
			else
				c:text("End of team", x + 16 * z, y + 52 * z, { size = 11 * z, color = "$text.secondary", baseline = "middle" })
			end
			if node.kind ~= "chief" then port(x + width * z / 2, y) end
			if node.kind ~= "finish" then port(x + width * z / 2, y + height * z) end
		end
	end

	local node_ids = ui.computed(function()
		local ids = {}
		for _, node in team:get().nodes do table.insert(ids, node.id) end
		return ids
	end)

	local function glass_card(id)
		local function node() return graph.node(team:get(), id) end
		local props = Glass.style({
			absolute = true,
			left = function() local n = node(); return pan_x:get() + (if n then n.x else 0) * zoom:get() end,
			top = function() local n = node(); return pan_y:get() + (if n then n.y else 0) * zoom:get() end,
			w = function() return width * zoom:get() end,
			h = function() local n = node(); return (if n then node_height(n) else height) * zoom:get() end,
			rounded = function() return 12 * zoom:get() end,
			pointer_events = "none",
		}, "island")
		props.border_color = function() return if selected:get() == id then "$accent" else "$border.strong" end
		table.insert(props, ui.div { absolute = true, left = 1, right = 1, top = 1, bottom = 1, rounded = function() return 11 * zoom:get() end, bg = "$zeron.secondary.bg", pointer_events = "none" })
		return ui.div(props)
	end

	local function choose_icon()
		local id = selected:peek()
		icon_error:set("")
		ui.open_files({ title = "Choose agent icon", filters = { { "SVG", { "svg" } } } }):after(function(files)
			local file = files and files[1]
			if not file or id ~= selected:peek() or not edit_open:peek() then return end
			if (file.size or 0) > 16384 then icon_error:set("Choose an SVG under 16 KB"); return end
			ui.read_file(file):after(function(text)
				if id ~= selected:peek() or not edit_open:peek() then return end
				if text == "" or not graph.valid_icon(text) then
					icon_error:set("Choose a self-contained SVG under 16 KB")
					return
				end
				icon_svg:set(text)
				icon_name:set(file.name or "Custom icon")
			end, function(err) icon_error:set("Could not read icon: " .. tostring(err)) end)
		end, function(err) icon_error:set("Could not choose icon: " .. tostring(err)) end)
	end

	local provider_marks = {
		["openai"] = "provider-openai", ["openai-codex"] = "provider-openai",
		["anthropic"] = "provider-anthropic", ["openrouter"] = "provider-openrouter",
		["google"] = "provider-gemini", ["gemini"] = "provider-gemini",
		["xai"] = "provider-xai", ["deepseek"] = "provider-deepseek", ["opencode"] = "opencode",
	}

	local function node_controls(id)
		local function node() return graph.node(team:get(), id) end
		local function left(offset)
			local n = node()
			return pan_x:get() + ((if n then n.x else 0) + offset) * zoom:get()
		end
		local function top(offset)
			local n = node()
			return pan_y:get() + ((if n then n.y else 0) + offset) * zoom:get()
		end
		return ui.div { w_full = true, h_full = true, absolute = true, left = 0, top = 0, pointer_events = "none",
			ui.div { absolute = true, left = function() return left(14) end, top = function() return top(14) end, color = "$text.secondary", pointer_events = "none",
				ui.presence(function() local n = node(); return (if n then n.icon or "" else "") .. ":" .. tostring(zoom:get()) end, function()
					local n, size = node(), 20 * zoom:peek()
					if n and n.icon and n.icon ~= "" then return ui.svg { code = n.icon, w = size, h = size, tint = if string.find(n.icon, "currentColor", 1, true) then "currentColor" else nil, aria_hidden = true } end
					return Icon { name = "bot", size = size }
				end),
			},
			ui.div { absolute = true, left = function() return left(14) end, top = function() return top(44) end, color = "$text.secondary", pointer_events = "none",
				ui.presence(function() local n = node(); return (if n then n.provider or "" else "") .. ":" .. (if n then n.model or "" else "") .. ":" .. tostring(zoom:get()) end, function()
					local n, size = node(), 14 * zoom:peek()
					if not n or n.kind == "finish" then return ui.div {} end
					local provider = if n.provider and n.provider ~= "" then n.provider else string.match(n.model or "", "^([^/]+)/") or ""
					local mark = provider_marks[provider]
					if mark then return Mark { name = mark, size = size, bare = true } end
					return Icon { name = "global", size = size }
				end),
			},
			IconButton { icon = "settings-minimalistic", label = "Edit block", size = "sm", absolute = true,
				left = function() return left(width - 34) end, top = function() return top(10) end,
				on_click = function() select_node(id); edit_open:set(true) end,
			},
		}
	end

	local function save_settings()
		local value = graph.copy(team:peek())
		local node = graph.node(value, selected:peek())
		if not node then return end
		node.name, node.instructions, node.harness, node.provider, node.model = name:peek(), instructions:peek(), harness:peek(), model_provider:peek(), model:peek()
		node.icon, node.icon_name = icon_svg:peek(), icon_name:peek()
		if save(value) then
			edit_open:set(false)
			notice:set("Block saved")
		end
	end

	local function inspector()
		local node = graph.node(team:peek(), selected:peek())
		if not node then
			if selected_edge:peek() > 0 then
				local edge = team:peek().edges[selected_edge:peek()]
				if not edge then return ui.column {} end
				local from, to = graph.node(team:peek(), edge.from), graph.node(team:peek(), edge.to)
				local retry_options = { { value = "", label = "None" } }
				for i = 1, 10 do table.insert(retry_options, { value = tostring(i), label = tostring(i) }) end
				return ui.column { w_full = true, gap = "$space.3",
					Text { (if from then from.name else edge.from) .. " → " .. (if to then to.name else edge.to), tone = "secondary", wrap = true },
					Select { value = edge_condition, label = "Condition", w_full = true, options = {
						{ value = "always", label = "Always" }, { value = "pass", label = "Pass" }, { value = "fail", label = "Fail" },
					} },
					ui.show(function() return edge_condition:get() == "fail" end, ui.column { w_full = true, gap = "$space.2",
						Select { value = edge_retries, label = "Retry limit", options = retry_options, w_full = true },
						Text { "Required on failure returns. Limit applies to the whole run.", style = "caption", tone = "secondary", wrap = true },
					}),
					Button { "Remove connection", tone = "ghost", on_click = function()
						local index = selected_edge:peek()
						local value = graph.copy(team:peek())
						if not value.edges[index] then return end
						table.remove(value.edges, index)
						if save(value) then selected_edge:set(0); edit_open:set(false); notice:set("Connection removed") end
					end },
				}
			end
			return ui.column { gap = "$space.2", Text { "Settings", style = "heading" }, Text { "Select a block or connection", tone = "secondary", wrap = true } }
		end
		local fields = { TextField { value = name, label = "Name", w_full = true },
			ui.row { w_full = true, items = "center", gap = "$space.2",
				Button { "Choose icon", tone = "secondary", size = "sm", on_click = choose_icon },
				ui.show(function() return icon_svg:get() ~= "" end, Button { "Remove icon", tone = "ghost", size = "sm", on_click = function() icon_svg:set(""); icon_name:set("") end }),
			},
			ui.show(function() return icon_name:get() ~= "" end, Text { function() return icon_name:get() end, style = "caption", tone = "secondary", wrap = true }),
			ui.show(function() return icon_error:get() ~= "" end, Text { function() return icon_error:get() end, style = "caption", tone = "danger", wrap = true }),
		}
		if node.kind ~= "finish" then
			table.insert(fields, Select { value = agent, options = agents, label = "Runtime", w_full = true, on_change = function(value)
				local next_harness = if value == "__custom" then "" else value
				if harness:peek() ~= next_harness then model:set(""); model_provider:set("") end
				harness:set(next_harness)
				load_models(next_harness)
			end })
			table.insert(fields, ui.show(function() return agent:get() == "__custom" end, ui.column { w_full = true, gap = "$space.2",
				TextField { value = harness, label = "Agent ID", placeholder = "acp.agent", w_full = true },
				Button { "Load models", tone = "secondary", size = "sm", on_click = function() model:set(""); model_provider:set(""); load_models(harness:peek()) end },
			}))
			table.insert(fields, Select { value = model_provider, options = provider_options, label = "Provider", w_full = true,
				disabled = function() return #catalog:get() == 0 end,
				on_change = function() model:set("") end,
			})
			table.insert(fields, Select { value = model, options = model_options, label = "Model", w_full = true,
				disabled = function() return catalog_loading:get() or (#catalog:get() == 0 and model:get() == "") end,
			})
			table.insert(fields, ui.show(function() return catalog_loading:get() or catalog_status:get() ~= "" end,
				Text { function() return if catalog_loading:get() then "Loading models" else catalog_status:get() end, style = "caption", tone = "secondary", wrap = true }))
			table.insert(fields, ui.show(function() return catalog_status:get() ~= "" end,
				TextField { value = model, label = "Model ID", placeholder = "Enter model ID", w_full = true }))
			if node.kind ~= "chief" then
				table.insert(fields, TextArea { value = instructions, label = "Role instructions", rows = 3, max_rows = 6, w_full = true })
				table.insert(fields, Button { "Restore default", tone = "ghost", size = "sm", on_click = function() instructions:set(graph.instructions(node.kind)) end })
				table.insert(fields, Text { "Custom instructions replace the default. They are task text, not a system prompt", style = "caption", tone = "secondary", wrap = true })
			else
				table.insert(fields, Text { "Chief is an entry point only. Its settings are not used for runs; the active chat is not linked.", style = "caption", tone = "secondary", wrap = true })
			end
		end
		if node.kind ~= "chief" then table.insert(fields, Button { "Remove block", tone = "ghost", on_click = function()
			local value = graph.copy(team:peek())
			graph.remove(value, selected:peek())
			if save(value) then
				selected:set("")
				edit_open:set(false)
			end
		end }) end
		return ui.column { w_full = true, gap = "$space.3", table.unpack(fields) }
	end

	local function checks()
		local rows = {}
		local issues = graph.validate(team:peek())
		if #issues == 0 then table.insert(rows, Text { "No structural issues", style = "caption", tone = "secondary" }) end
		for _, issue in issues do
			local node = if issue.id then graph.node(team:peek(), issue.id) else nil
			table.insert(rows, Text { (if node then node.name .. ": " else "") .. issue.message, style = "caption", tone = "secondary", wrap = true })
		end
		return ui.column { w_full = true, gap = "$space.2", table.unpack(rows) }
	end

	return ui.column { w_full = true, h_full = true, p = "$space.4", gap = "$space.3",
		ui.row { w_full = true, items = "center", gap = "$space.2",
			Text { "Orchestrator Builder", style = "caption", tone = "secondary" },
			Text { function() return team:get().name end, style = "heading", max_w = 360, min_w = 0, shrink = 1, truncate = true },
			IconButton { icon = "pen", label = "Edit team", size = "sm", on_click = function() team_open:set(true) end },
			ui.div { grow = 1 },
			Text { function() return "Run: " .. runner.state:get().status end, style = "caption", tone = "secondary" },
		},
		ui.row { w_full = true, gap = "$space.2", items = "center",
			Select { value = add_choice, options = add_options, size = "sm", w = 144, name = "Add block", on_change = function(kind)
				if kind ~= "" then add(kind); add_choice:set("") end
			end },
			Button { "Team", tone = "secondary", size = "sm", on_click = function() team_open:set(true) end },
			Button { function() return if grid:get() then "Hide grid" else "Show grid" end, tone = "secondary", size = "sm", on_click = function()
				local value = not grid:peek()
				grid:set(value)
				grid_kept:set(value)
			end },
			ui.div { grow = 1 },
			Button { "−", tone = "secondary", size = "sm", on_click = function() zoom_at(zoom:peek() / 1.15, (canvas.width or 0) / 2, (canvas.height or 0) / 2) end },
			Button { "+", tone = "secondary", size = "sm", on_click = function() zoom_at(zoom:peek() * 1.15, (canvas.width or 0) / 2, (canvas.height or 0) / 2) end },
			Button { "Fit", tone = "secondary", size = "sm", on_click = fit },
		},
		ui.column { w_full = true, gap = "$space.2",
			ui.row { w_full = true, items = "center", gap = "$space.2",
				Button { "Start", size = "sm", disabled = function() local status = runner.state:get().status; return status ~= "idle" and status ~= "finished" end, on_click = function() run_error:set(""); destination_session:set(""); selected_destination = nil; run_open:set(true) end },
				Button { "Open chat", tone = "secondary", size = "sm", disabled = function() return runner.state:get().chat == nil end, on_click = function()
					local ok, reason = runner.open_chat()
					if not ok then run_error:set(reason) end
				end },
				Button { "Stop", tone = "secondary", size = "sm", disabled = function() local status = runner.state:get().status; return status ~= "starting" and status ~= "running" end, on_click = function()
					local ok, reason = runner.stop()
					if not ok then run_error:set(reason) end
				end },
				ui.show(function() local status = runner.state:get().status; return status == "blocked" or status == "interrupted" end,
					Button { "Review / abandon", tone = "secondary", size = "sm", on_click = function()
						recovery_id = runner.state:peek().run_id
						run_error:set("")
						recovery_open:set(true)
					end }),
				Text { function() local route = runner.state:get().route; return if route then "Route block ID: " .. tostring(route) else "" end, style = "caption", tone = "secondary" },
			},
			Text { function() return runner.state:get().reason or "" end, style = "caption", tone = "secondary", wrap = true },
			ui.show(function() local status = runner.state:get().status; return status == "blocked" or status == "interrupted" end,
				Text { function()
					local state = runner.state:get()
					if state.abandoning then return "Abandonment pending" end
					if state.pending_chat then return "Chat creation pending" end
					if state.pending_receipt then return "Saving chat receipt" end
					if state.pending_claim then return "Journal claim pending" end
					if not state.can_abandon then return "Review journal manually" end
					return "Review required"
				end, style = "caption", tone = "danger", wrap = true }),
			ui.show(function() return run_error:get() ~= "" end, Text { function() return run_error:get() end, style = "caption", tone = "danger", wrap = true }),
		},
		ui.row { w_full = true, grow = 1, min_h = 0, gap = "$space.4", items = "stretch",
			ui.div { ref = canvas, grow = 1, h_full = true, relative = true, rounded = "$radius.lg", overflow = "hidden", on_mount = function() ui.after(100, fit); load_models(harness:peek()) end,
				ui.canvas { absolute = true, left = 0, top = 0, w_full = true, h_full = true, draw = draw_grid, pointer_events = "none" },
				ui.canvas { absolute = true, left = 0, top = 0, w_full = true, h_full = true, draw = draw_edges, pointer_events = "none" },
				ui.div { absolute = true, left = 0, right = 0, top = 0, bottom = 0, pointer_events = "none",
					ui.each(node_ids, glass_card, { key = function(id) return id end, w_full = true, h_full = true, relative = true }),
				},
				ui.canvas { absolute = true, left = 0, top = 0, w_full = true, h_full = true, draw = draw_nodes, on_press = press, on_pointer_move = move, on_release = release, on_wheel = wheel },
				ui.div { absolute = true, left = 0, right = 0, top = 0, bottom = 0, pointer_events = "none",
					ui.each(node_ids, node_controls, { key = function(id) return id end, w_full = true, h_full = true, relative = true }),
				},
			},
		},
		Text { function() return notice:get() end, style = "caption", tone = "secondary", wrap = true },
		Dialog { open = run_open, title = "Start run", size = "md", cancel = "Close",
			confirm = { label = "Start", on_click = function()
				local id = destination_session:peek()
				local destination = if id ~= "" then destination_of(zeron.sessions()[id], zeron.projects()) else nil
				if not destination or not selected_destination or destination.device ~= selected_destination.device or destination.project ~= selected_destination.project then
					run_error:set("Select a valid destination session; reselect it if its destination changed")
					return
				end
				local ok, reason = runner.start(graph.copy(team:peek()), task_text:peek(), selected_destination)
				if ok then run_error:set(""); run_open:set(false) else run_error:set(reason) end
			end },
			build = function()
				return ui.column { w_full = true, gap = "$space.3",
					TextArea { value = task_text, label = "Task", rows = 4, max_rows = 8, w_full = true },
					Select { value = destination_session, options = destination_options, label = "Destination", w_full = true, on_change = function(id)
						selected_destination = if id ~= "" then destination_of(zeron.sessions()[id], zeron.projects()) else nil
					end },
					ui.show(function() return #destination_options() == 1 end, Text { "No valid destination sessions available. Create a session on the intended device or project first.", style = "caption", tone = "danger", wrap = true }),
					Text { "Roles start new chats on the session’s device and project; the selected session receives no messages. Team and destination are copied at start.", style = "caption", tone = "secondary", wrap = true },
					ui.show(function() return run_error:get() ~= "" end, Text { function() return run_error:get() end, style = "caption", tone = "danger", wrap = true }),
				}
			end,
		},
		Dialog { open = recovery_open, title = "Review / abandon", size = "md", cancel = "Cancel",
			confirm = { label = "Abandon run", on_click = function()
				local state = runner.state:peek()
				if state.run_id ~= recovery_id or (state.status ~= "blocked" and state.status ~= "interrupted") then
					run_error:set("Run changed. Close and review the current run.")
					return
				end
				local ok, reason = runner.abandon(true)
				if ok then run_error:set(""); recovery_open:set(false) else run_error:set(reason) end
			end },
			build = function()
				return ui.column { w_full = true, gap = "$space.3",
					Text { "Abandoning does not stop agents or queued messages. Inspect the chat and stop any pending work first. Open chat may show an earlier block or be unavailable.", tone = "danger", wrap = true },
					Text { "This only requests journal abandonment. It does not retry the run automatically.", tone = "secondary", wrap = true },
					ui.show(function() return run_error:get() ~= "" end, Text { function() return run_error:get() end, style = "caption", tone = "danger", wrap = true }),
				}
			end,
		},
		Dialog { open = edit_open, title = function() return if selected_edge:get() > 0 then "Connection" else "Edit block" end, size = "md", cancel = "Close",
			confirm = { label = function() return if selected_edge:get() > 0 then "Save connection" else "Save block" end, on_click = function()
				if selected_edge:peek() > 0 then
					local value = graph.copy(team:peek())
					local edge = value.edges[selected_edge:peek()]
					if not edge then return end
					edge.condition = edge_condition:peek()
					edge.max_retries = if edge.condition == "fail" then tonumber(edge_retries:peek()) else nil
					if save(value) then edit_open:set(false); notice:set("Connection saved") end
				else
					save_settings()
				end
			end },
			build = function()
				return ui.scroll { w_full = true, h = if selected_edge:peek() > 0 then 300 else 420,
					ui.presence(function() return selected:get() .. ":" .. tostring(selected_edge:get()) end, inspector, { w_full = true }),
				}
			end,
		},
		Dialog { open = team_open, title = "Team", size = "md", cancel = "Close",
			build = function()
				return ui.scroll { w_full = true, h = 320,
					ui.column { w_full = true, gap = "$space.4",
						Select { value = active_team, options = team_options, label = "Teams", w_full = true, on_change = open_team },
						TextField { value = team_name, label = "Team name", w_full = true },
						ui.row { gap = "$space.2",
							Button { "Save name", tone = "secondary", size = "sm", on_click = function()
								if not string.find(team_name:peek(), "%S") then notice:set("Enter a team name"); return end
								local value = graph.copy(team:peek())
								value.name = team_name:peek()
								if save(value) then notice:set("Team name saved") end
							end },
							Button { "New team", tone = "secondary", size = "sm", on_click = new_team },
						},
						ui.row { gap = "$space.2",
							Button { "Import JSON", tone = "secondary", size = "sm", on_click = import_team },
							Button { "Export JSON", tone = "secondary", size = "sm", on_click = export_team },
						},
						Text { function() return transfer_status:get() end, style = "caption", tone = "secondary" },
						Text { "Team checks", style = "heading" },
						ui.presence(function() return team:get() end, checks, { w_full = true }),
					},
				}
			end,
		},
	}
end)

zeron.page { id = "builder", title = "Orchestrator Builder", icon = "git-branch", build = function() return Builder {} end }
