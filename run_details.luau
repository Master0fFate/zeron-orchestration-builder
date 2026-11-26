local Text = require("@ds/text")
local Button = require("@ds/button")
local Select = require("@ds/select")
local Tabs = require("@ds/tabs")
local Dialog = require("@ds/dialog").Dialog
local graph = require("./graph")

local page_size = 6
local history_size = 6
local history_query = [[
	SELECT rowid AS position, id, active, status,
		CASE WHEN json_valid(data) THEN
			CASE WHEN json_type(data, '$.graph.name') = 'text' THEN substr(json_extract(data, '$.graph.name'), 1, 100) END
		END AS name,
		CASE WHEN json_valid(data) THEN json_extract(data, '$.phase') END AS phase
	FROM orchestrator_runs
]]
local empty = {}
local legacy_phases = {
	starting = true, routed = true, terminal = true, finished = true,
	dispatching = true, dispatch_unknown = true, waiting = true, queued = true, late_receipt = true,
}

local function fields(value)
	return if type(value) == "table" then value else empty
end

local function text(value)
	return if type(value) == "string" and value ~= "" and utf8.len(value) then value else nil
end

local function array(value)
	if type(value) ~= "table" then return nil end
	local count = 0
	for index in pairs(value) do
		if type(index) ~= "number" or index % 1 ~= 0 or index < 1 then return nil end
		count += 1
	end
	for index = 1, count do
		if value[index] == nil then return nil end
	end
	return value
end

local function excerpt(value)
	if #value <= 768 then return value end
	local limit = utf8.offset(value, 0, 769)
	return if limit then string.sub(value, 1, limit - 1) .. "…" else nil
end

local function caption(value, tone)
	return Text { value, style = "caption", tone = tone or "secondary", wrap = true, w_full = true }
end

local function current_id(state)
	if state.status == "idle" or state.status == "finished" or state.status == "stopped" then return nil end
	return text(state.run_id)
end

local function saved_status(row, phase)
	local status = if phase == "ask_stopped" and row.status == "finished" and row.active == 0 then "stopped" else text(row.status) or "unknown"
	return status .. (if row.active == 1 then " · Locked when read" else "")
end

local function history_stamp(id)
	local timestamp = tonumber(string.match(id, "^(%d%d%d%d%d%d%d%d%d%d)%-%x+%-%x+%-%x+$") or "")
	return if timestamp then os.date("!%Y-%m-%d %H:%M", timestamp) .. " UTC · " .. string.sub(id, -8) else id
end

local function read_history(zeron, anchor, ascending)
	local limit = history_size + 1
	local rows = if not anchor then zeron.db.query(history_query .. "ORDER BY rowid DESC LIMIT ?", { limit }):await()
		elseif ascending then zeron.db.query(history_query .. "WHERE rowid > ? ORDER BY rowid ASC LIMIT ?", { anchor, limit }):await()
		else zeron.db.query(history_query .. "WHERE rowid < ? ORDER BY rowid DESC LIMIT ?", { anchor, limit }):await()
	if not array(rows) or #rows > limit then return nil end
	for _, row in ipairs(rows) do
		if type(row) ~= "table" or not text(row.id) or type(row.position) ~= "number" then return nil end
	end
	local extra = #rows == limit
	local count = math.min(#rows, history_size)
	if extra or (ascending and count > 1) then
		local page = table.create(count)
		for i = 1, count do
			page[i] = rows[if ascending then count - i + 1 else i]
		end
		rows = page
	end
	return {
		rows = rows,
		newer = rows[1] and (if ascending then extra else anchor ~= nil) and rows[1].position,
		older = rows[count] and (if ascending then true else extra) and rows[count].position,
	}
end

local function history_view(history, paginate, inspect)
	local rows = {}
	for _, row in ipairs(history.rows) do
		local id = row.id
		table.insert(rows, ui.row { w_full = true, items = "center", gap = "$space.3",
			ui.column { grow = 1, min_w = 0, gap = "$space.1",
				Text { text(row.name) or "Saved run", style = "label", wrap = true, w_full = true },
				caption(history_stamp(id) .. " · " .. saved_status(row, row.phase)),
			},
			Button { "View run", tone = "secondary", size = "sm", on_click = function() inspect(id) end },
		})
	end
	return ui.column { w_full = true, gap = "$space.3",
		if #rows == 0 then caption("No saved runs found") else nil,
		if history.newer or history.older then ui.row { w_full = true, items = "center", gap = "$space.2",
			Button { "Newer", tone = "secondary", size = "sm", disabled = not history.newer, on_click = function() paginate(history.newer, true) end },
			Button { "Older", tone = "secondary", size = "sm", disabled = not history.older, on_click = function() paginate(history.older, false) end },
		} else nil,
		table.unpack(rows),
	}
end

local function block(frame, id)
	return text(id) and frame.nodes[id] or nil
end

local function block_label(frame, id)
	local node = block(frame, id)
	return (node and node.name) or (if text(id) then "Block " .. id else "Unknown block")
end

local function saved_receipt(visit)
	local receipt = fields(visit.receipt)
	if receipt.status ~= "sent" or not text(receipt.chat) or not string.find(receipt.chat, "%S")
		or not text(receipt.id) or not string.find(receipt.id, "%S") then return nil end
	if visit.kind == "send_message" then
		if receipt.chat ~= visit.chat or (receipt.delivery ~= "run" and receipt.delivery ~= "queue") then return nil end
	elseif receipt.delivery ~= nil and receipt.delivery ~= "run" and receipt.delivery ~= "queue" then
		return nil
	end
	return receipt
end

local function mapped_receipt(frame, visit, receipt)
	local role = block(frame, visit.node)
	return if receipt and role and graph.role(role.kind) and frame.chats[visit.node] == receipt.chat then receipt else nil
end

local function unknown_delivery(phase)
	return phase == "dispatching" or phase == "dispatch_unknown"
end

local function refusal_nonce(data)
	return if data.phase == "dispatch_not_sent" then text(data.nonce) else nil
end

local function verified_refusal(row, frame, nonce)
	local index = frame.visit_indexes[nonce]
	local visit = index and frame.visits[index]
	local saved = (row.active == 1 and row.status == "blocked") or (row.active == 0 and row.status == "abandoned")
	if not saved or row.data.chat ~= nil or frame.invalid or not visit or index ~= #frame.visits
		or visit.node ~= frame.node or visit.kind ~= "send_message" or visit.mode ~= "queue"
		or visit.chat ~= frame.chats[visit.node] or visit.receipt ~= nil or frame.reports[nonce] ~= nil then return false end
	for i = 1, index - 1 do
		local prior = frame.visits[i]
		if prior.node == visit.node and mapped_receipt(frame, prior, saved_receipt(prior)) then return true end
	end
	return false
end

local function snapshot(row)
	local data = fields(row.data)
	local refused_nonce = refusal_nonce(data)
	local legacy = data.children == nil and data.active_frame == nil and fields(data.graph).version == 2
		and legacy_phases[data.phase] == true
	local active_id = if legacy then "root" else text(data.active_frame)
	local frames, options = {}, {}
	local function add(id, frame, team, name)
		local function in_frame(value)
			return value == id or (legacy and value == nil)
		end
		local function uncertain(visit_nonce)
			return id == active_id and visit_nonce == data.nonce and unknown_delivery(data.phase)
		end
		team = fields(team)
		local nodes, visits, reports = array(team.nodes), array(frame.visits), array(frame.reports)
		local scope = { name = text(team.name), node = text(frame.node), item = text(frame.item), nodes = {}, visit_indexes = {},
			visits = visits or empty, reports = {}, handoffs = 0, chats = fields(frame.role_chats), report_count = 0,
			crew = {}, position = #options + 1 }
		scope.invalid = not (scope.name and nodes and visits and reports and type(frame.role_chats) == "table") or (frame.item ~= nil and not scope.item)
		for _, node in ipairs(nodes or empty) do
			if type(node) ~= "table" or not text(node.id) then scope.invalid = true; continue end
			local valid = scope.nodes[node.id] == nil and text(node.name) ~= nil
			scope.nodes[node.id] = if valid then node else false
			if not valid then scope.invalid = true end
		end
		if not scope.node or not scope.nodes[scope.node] then scope.invalid = true end
		for node, chat in pairs(scope.chats) do
			local role = scope.nodes[node]
			if not role or not graph.role(role.kind) or not text(chat) or not string.find(chat, "%S") then scope.invalid = true end
		end
		for _, node in ipairs(nodes or empty) do
			if type(node) ~= "table" or not text(node.id) or scope.nodes[node.id] ~= node or not graph.role(node.kind) then continue end
			local chat = text(scope.chats[node.id])
			if chat and string.find(chat, "%S") then table.insert(scope.crew, { name = node.name, chat = chat }) end
		end
		for index, visit in ipairs(scope.visits) do
			if type(visit) ~= "table" or not text(visit.nonce) then scope.invalid = true; continue end
			local valid = scope.visit_indexes[visit.nonce] == nil and in_frame(visit.frame) and block(scope, visit.node)
				and ((visit.kind == "new_chat" and visit.chat == nil) or (visit.kind == "send_message" and text(visit.chat) ~= nil))
			scope.visit_indexes[visit.nonce] = if valid then index else false
			if not valid then
				scope.invalid = true
			elseif visit.receipt ~= nil then
				local receipt = saved_receipt(visit)
				if not receipt or (not uncertain(visit.nonce) and not mapped_receipt(scope, visit, receipt)) then scope.invalid = true end
			end
		end
		for _, report in ipairs(reports or empty) do
			if type(report) ~= "table" then scope.invalid = true; continue end
			if text(report.nonce) then
				local index = scope.visit_indexes[report.nonce]
				local visit = index and scope.visits[index]
				local body = text(report.report)
				local receipt = visit and report.nonce ~= refused_nonce and not uncertain(report.nonce)
					and mapped_receipt(scope, visit, saved_receipt(visit))
				local valid = receipt and scope.reports[report.nonce] == nil and in_frame(report.frame) and report.node == visit.node
					and report.chat == receipt.chat and body and string.find(body, "%S")
					and (report.verdict == nil or report.verdict == "pass" or report.verdict == "fail")
				if valid then
					scope.reports[report.nonce] = report
					scope.report_count += 1
				else
					scope.reports[report.nonce] = false
					scope.invalid = true
				end
			else
				local handoff = fields(report.handoff)
				if not legacy and report.nonce == nil and report.report == nil and id == "root" and report.frame == id and block(scope, report.node)
					and text(handoff.name) and array(handoff.findings) and type(handoff.omitted) == "number" and handoff.omitted % 1 == 0 and handoff.omitted >= 0 then
					scope.handoffs += 1
				else
					scope.invalid = true
				end
			end
		end
		frames[id] = scope
		table.insert(options, { value = id, label = name })
		return scope
	end
	local root = add("root", data, data.graph, "Root team")
	local children = if legacy then empty else array(data.children)
	local invalid = not children
	local duplicate_frames = {}
	for index, frame in ipairs(children or empty) do
		if type(frame) ~= "table" or not text(frame.id) or frame.id == "root" then invalid = true; continue end
		if frames[frame.id] then
			frames[frame.id].invalid = true
			duplicate_frames[frame.id] = true
			invalid = true
			continue
		end
		local parent = fields(block(root, frame.parent_node))
		local parent_valid = parent.kind == "team" or parent.kind == "foreach"
		local name = text(parent.name) or text(frame.name) or "Saved team"
		local iteration = frame.iteration
		local valid_iteration = type(iteration) == "number" and iteration >= 1 and iteration % 1 == 0
		local child = add(frame.id, frame, if parent_valid then parent.team else nil, index .. ". " .. name .. (if valid_iteration then " · Item " .. iteration else ""))
		child.parent_node = if parent_valid then frame.parent_node else nil
		child.phase = text(frame.phase)
		if not parent_valid or (iteration ~= nil and not valid_iteration) then child.invalid = true end
	end
	local active = active_id and frames[active_id]
	if not active or duplicate_frames[active_id] or (active_id ~= "root" and (not active.parent_node or active.parent_node ~= root.node)) then
		active_id = nil
	end
	if data.phase == "dispatch_not_sent" then
		if not invalid and active_id and refused_nonce
			and (active_id == "root" or (active.phase == data.phase and active.position == #options))
			and verified_refusal(row, active, refused_nonce) then
			active.refused_nonce = refused_nonce
		else
			invalid = true
		end
	end
	return { row = row, frames = frames, options = options, active_id = active_id, invalid = invalid or not active_id }
end

local function chat_link(zeron, open, chat, label, show_status)
	local function session() return fields(zeron.sessions())[chat] end
	local function unavailable() return type(session()) ~= "table" end
	local function summary()
		local entry = session()
		if type(entry) ~= "table" then return label .. chat .. " · Session unavailable" end
		local status = text(entry.status)
		return label .. chat .. " · " .. (if status and #status <= 32 and string.match(status, "^[%w_-]+$")
			then "Session: " .. status else "Session status unknown")
	end
	return ui.row { w_full = true, items = "center", gap = "$space.2",
		Text { if show_status then summary else label .. chat, style = "caption", tone = "secondary", wrap = true, min_w = 0, grow = 1 },
		Button { "Open chat", tone = "ghost", size = "sm", disabled = unavailable, on_click = function()
			if unavailable() then return end
			open:set(false)
			zeron.open({ session = chat })
		end },
	}
end

local function list_pager(current, total, previous, next_label, go)
	if total <= 1 then return nil end
	return ui.row { w_full = true, flex_wrap = true, items = "center", gap = "$space.2",
		Button { previous, tone = "secondary", size = "sm", disabled = current == 1, on_click = function() go(current - 1) end },
		Text { current .. " / " .. total, style = "caption", tone = "secondary" },
		Button { next_label, tone = "secondary", size = "sm", disabled = current == total, on_click = function() go(current + 1) end },
	}
end

local function crew_view(zeron, open, frame, page)
	local count = #frame.crew
	local total = math.max(1, math.ceil(count / page_size))
	local current = math.min(page:peek(), total)
	local rows = {}
	for i = (current - 1) * page_size + 1, math.min(current * page_size, count) do
		local role = frame.crew[i]
		table.insert(rows, ui.column { w_full = true, gap = "$space.1",
			Text { role.name, style = "label", wrap = true, w_full = true },
			chat_link(zeron, open, role.chat, "Chat ", true),
		})
	end
	return ui.column { w_full = true, gap = "$space.2",
		Text { "Role chats", style = "heading" },
		caption(if count == 0 then "No recorded role chats in this frame" else count .. " recorded · Session status is advisory, not run or delivery evidence"),
		list_pager(current, total, "Previous chats", "Next chats", function(next_page) page:set(next_page) end),
		table.unpack(rows),
	}
end

local function visit_row(zeron, open, row, frame, visit, number, active)
	local data = row.data
	local uncertain = active and unknown_delivery(data.phase)
	local refusal = visit.nonce == refusal_nonce(data)
	local receipt = if uncertain or refusal then nil else mapped_receipt(frame, visit, saved_receipt(visit))
	local raw_receipt = fields(visit.receipt)
	local receipt_chat = text(raw_receipt.chat)
	local chat = if receipt then receipt.chat elseif visit.kind == "send_message" then visit.chat else nil
	local report = frame.reports[visit.nonce]
	local report_text = if report then excerpt(report.report) else nil
	local decision = if report and report.verdict == "pass" then " · Pass" elseif report and report.verdict == "fail" then " · Fail" else ""
	local evidence, invalid_evidence
	if report_text then
		evidence = "Report saved" .. decision
	elseif report ~= nil then
		evidence, invalid_evidence = "Invalid saved report", true
	elseif active and receipt and receipt.chat == data.chat and row.submission ~= nil then
		local result = row.submission
		if result == "" or result == "pass" or result == "fail" then
			evidence = (if frame.invalid then "Submission saved; accepted report evidence is incomplete" else "Submission saved; no matching report in this checkpoint")
				.. (if result == "pass" then " · Pass" elseif result == "fail" then " · Fail" else "")
		else
			evidence, invalid_evidence = "Invalid saved submission", true
		end
	elseif active and not refusal and row.submission_unavailable then
		evidence = "Submission lookup unavailable"
	end
	local invalid_receipt = visit.receipt ~= nil and not receipt
	local invalid_refusal = refusal and frame.refused_nonce ~= visit.nonce
	local receipt_details = if invalid_refusal then "Invalid refusal evidence" elseif refusal then "Message not sent"
		elseif receipt then "Receipt: sent" elseif invalid_receipt then (if uncertain then "Unconfirmed receipt" else "Invalid saved receipt") else "No saved receipt"
	if not refusal then
		local delivery, message = text(raw_receipt.delivery), text(raw_receipt.id)
		if delivery then receipt_details ..= " · " .. delivery end
		if message then receipt_details ..= " · Message " .. message end
	end
	return ui.column { w_full = true, gap = "$space.1",
		Text { number .. ". " .. block_label(frame, visit.node), style = "label", wrap = true, w_full = true },
		caption((if active then "Checkpoint visit · " else "")
			.. (if visit.kind == "send_message" then "Repeat visit · " else "New chat · ") .. receipt_details,
			if invalid_receipt or invalid_refusal then "danger" else nil),
		if not refusal and raw_receipt.delivery == "queue" then caption("Queued message may still execute. Do not resend.", "danger") else nil,
		if evidence then caption(evidence, if invalid_evidence then "danger" else nil) else nil,
		if report_text then Text { report_text, wrap = true, w_full = true } else nil,
		if chat then chat_link(zeron, open, chat, if receipt then "Chat " else "Intended chat: ") else nil,
		if receipt_chat and receipt_chat ~= chat then
			chat_link(zeron, open, receipt_chat, if refusal then "Invalid receipt chat: " else "Unconfirmed receipt chat: ") else nil,
	}
end

local function timeline(zeron, open, row, frame, checkpoint_index, page)
	local count = #frame.visits
	local total = math.max(1, math.ceil(count / page_size))
	local current = math.min(page:peek(), total)
	local rows = {}
	local last = count - (current - 1) * page_size
	for i = last, math.max(1, last - page_size + 1), -1 do
		local visit = fields(frame.visits[i])
		local valid = text(visit.nonce) and frame.visit_indexes[visit.nonce] == i
		table.insert(rows, if valid then visit_row(zeron, open, row, frame, visit, i, i == checkpoint_index)
			else caption(i .. ". Invalid saved visit", "danger"))
	end
	return ui.column { w_full = true, gap = "$space.3",
		Text { "Role visits", style = "heading" },
		if frame.invalid then caption("Invalid frame data. Saved evidence may be incomplete.", "danger")
			else caption(count .. " visits · " .. frame.report_count .. " reports" .. (if frame.handoffs > 0 then " · " .. frame.handoffs .. " handoffs" else "")),
		if count > 0 then caption("Newest first in this frame. Reports are agent claims.")
			elseif not frame.invalid then caption("No saved role visits") else nil,
		if total > 1 then ui.row { w_full = true, items = "center", gap = "$space.2",
			Button { "Newer", tone = "secondary", size = "sm", disabled = current == 1, on_click = function() page:set(current - 1) end },
			Text { current .. " / " .. total, style = "caption", tone = "secondary" },
			Button { "Older", tone = "secondary", size = "sm", disabled = current == total, on_click = function() page:set(current + 1) end },
		} else nil,
		table.unpack(rows),
	}
end

local function ask_history(asks, root, page)
	local total = math.ceil(#asks / page_size)
	local current = math.min(page:peek(), total)
	local last = #asks - (current - 1) * page_size
	local rows = {}
	for i = last, math.max(1, last - page_size + 1), -1 do
		local ask = asks[i]
		local decision = if ask.decision == "continue" then "Continue" elseif ask.decision == "stop" then "Stop" else "Unanswered"
		table.insert(rows, ui.column { w_full = true, gap = "$space.1",
			Text { i .. ". " .. block_label(root, ask.node), style = "label", wrap = true, w_full = true },
			caption("Decision: " .. decision),
			Text { ask.question, wrap = true, w_full = true },
		})
	end
	return ui.column { w_full = true, gap = "$space.2",
		Text { "Ask decisions", style = "heading" },
		if total > 1 then ui.row { w_full = true, items = "center", gap = "$space.2",
			Button { "Newer", tone = "secondary", size = "sm", disabled = current == 1, on_click = function() page:set(current - 1) end },
			Text { current .. " / " .. total, style = "caption", tone = "secondary" },
			Button { "Older", tone = "secondary", size = "sm", disabled = current == total, on_click = function() page:set(current + 1) end },
		} else nil,
		table.unpack(rows),
	}
end

local function frame_picker(value, selected, reset_pages)
	local options = value.options
	local total = math.ceil(#options / page_size)
	local function frame_page()
		local frame = value.frames[selected:get()] or value.frames.root
		return math.ceil(frame.position / page_size)
	end
	return ui.presence(frame_page, function()
		local current = frame_page()
		local choices = {}
		for i = (current - 1) * page_size + 1, math.min(current * page_size, #options) do
			table.insert(choices, options[i])
		end
		return ui.column { w_full = true, gap = "$space.2",
			Select { value = selected, options = choices, label = "Run frame", w_full = true, on_change = reset_pages },
			list_pager(current, total, "Previous frames", "Next frames", function(next_page)
				selected:set(options[(next_page - 1) * page_size + 1].value)
				reset_pages()
			end),
		}
	end, { w_full = true })
end

local function journal_view(zeron, open, value, selected, page, ask_page, crew_page)
	local row, frames = value.row, value.frames
	local data = fields(row.data)
	local root = frames.root
	local active_id = value.active_id
	local active = active_id and frames[active_id]
	local nonce = text(data.nonce)
	local checkpoint_index = if active and nonce then active.visit_indexes[nonce] else nil
	local checkpoint = checkpoint_index and active.visits[checkpoint_index]
	if checkpoint and checkpoint.node ~= active.node then checkpoint, checkpoint_index = nil, nil end
	local route = block_label(root, data.node)
	if active and active_id ~= "root" then route ..= " → " .. block_label(active, active.node) end
	local destination = fields(data.destination)
	local session, device, project, cwd = text(destination.session), text(destination.device), text(destination.project), text(destination.cwd)
	local delivery_unknown = unknown_delivery(data.phase)
	local inspect_chats = if session then "Inspect the destination session list."
		elseif project then "Check chats in the saved project on the saved device."
		else "Check chats without a project on the saved device."
	local phase = if data.phase == "dispatch_not_sent" and not (active and active.refused_nonce) then "invalid refusal" else text(data.phase)
	local function reset_pages()
		page:set(1)
		crew_page:set(1)
	end
	local invalid = value.invalid or not text(data.phase) or not device
		or (destination.session ~= nil and not session) or (destination.project ~= nil and not project)
		or (data.chat ~= nil and not text(data.chat)) or (data.last_chat ~= nil and not text(data.last_chat))
		or (data.nonce ~= nil and not nonce) or (delivery_unknown and not checkpoint)
	return ui.column { w_full = true, gap = "$space.4",
		ui.column { w_full = true, gap = "$space.2",
			if delivery_unknown then
				caption("Delivery unknown. Work may still execute. Do not resend. " .. inspect_chats, "danger") else nil,
			Text { root.name or "Saved run", style = "heading", wrap = true, w_full = true },
			caption("Saved run snapshot, not the editable canvas"),
			Text { "Saved status: " .. saved_status(row, data.phase)
				.. (if phase then " · " .. string.gsub(phase, "_", " ") else ""), wrap = true, w_full = true },
			if text(row.reason) then caption(row.reason) else nil,
		},
		ui.column { w_full = true, gap = "$space.1",
			caption("Run " .. row.id),
			if text(data.node) then caption("Saved route: " .. route) else nil,
			if session then caption("Destination session: " .. session) else nil,
			if device then caption("Device: " .. device .. (if project then " · Project: " .. project elseif destination.project == nil then " · No project" else "")) else nil,
			if cwd then caption("Working folder: " .. cwd)
				elseif not session and device and destination.project == nil and destination.cwd == nil then caption("Working folder: Zeron chooses a scratch folder for each role chat") else nil,
			if text(data.last_chat) then caption("Last receipt chat: " .. data.last_chat) else nil,
		},
		if type(row.data) ~= "table" then caption("Saved snapshot is unreadable", "danger") else ui.column { w_full = true, gap = "$space.4",
			if invalid then caption("Invalid checkpoint data. Saved evidence may be incomplete.", "danger") else nil,
			if row.asks_invalid then caption("Invalid saved Ask evidence", "danger")
				elseif row.asks and #row.asks > 0 then ui.presence(function() return ask_page:get() end,
					function() return ask_history(row.asks, root, ask_page) end, { w_full = true }) else nil,
			if #value.options > 1 then frame_picker(value, selected, reset_pages) else nil,
			ui.presence(function() return selected:get() end, function()
				local id = selected:peek()
				if not frames[id] then id = "root" end
				local frame = frames[id]
				local frame_phase = if frame.phase == "dispatch_not_sent" and not frame.refused_nonce then "invalid refusal" else frame.phase
				local context = if id == "root" then "Root frame" elseif frame.parent_node then
					"Child frame · Parent: " .. (root.name or "Root team") .. " → " .. block_label(root, frame.parent_node) .. " (block " .. frame.parent_node .. ")"
					else "Child frame · Parent not verified"
				return ui.column { w_full = true, gap = "$space.3",
					ui.column { w_full = true, gap = "$space.1",
						caption(context .. (if id == active_id then " · Checkpoint frame" else "")),
						if frame.node then caption("Saved block: " .. block_label(frame, frame.node)
							.. (if frame_phase then " · " .. string.gsub(frame_phase, "_", " ") else "")) else nil,
						if frame.item then caption("Item: " .. frame.item) else nil,
					},
					ui.presence(function() return crew_page:get() end,
						function() return crew_view(zeron, open, frame, crew_page) end, { w_full = true }),
					ui.presence(function() return page:get() end,
						function() return timeline(zeron, open, row, frame, if id == active_id then checkpoint_index else nil, page) end, { w_full = true }),
				}
			end, { w_full = true }),
		},
	}
end

return function(zeron, runner)
	local Body = ui.component(function(props)
		local tab = ui.use_state("checkpoint")
		local inspected = ui.use_state(nil)
		local record = ui.use_state(empty)
		local refresh_id = ui.use_state(0)
		local frame = ui.use_state("")
		local visit_page = ui.use_state(1)
		local ask_page = ui.use_state(1)
		local crew_page = ui.use_state(1)
		local history_anchor = ui.use_state(nil)
		local request, loaded_id = 0, nil
		local ascending
		local target = ui.computed(function()
			if not props.open:get() then return "closed" end
			if tab:get() == "history" then
				local id = inspected:get()
				return if id then "saved:" .. id else "history"
			end
			local id = current_id(runner.state:get())
			return if id then "current:" .. id else "latest"
		end)
		local function refresh()
			refresh_id:set(refresh_id:peek() + 1)
		end
		local function paginate(position, newer)
			ascending = newer
			history_anchor:set(position)
			refresh()
		end
		local function visible()
			local value = record:get()
			return if value.target == target:get() and value.refresh == refresh_id:get() then value else empty
		end
		ui.effect(function()
			local key, revision = target:get(), refresh_id:get()
			request += 1
			local serial = request
			record:set(empty)
			if key == "closed" then return end
			local function selected()
				return request == serial and target:peek() == key and refresh_id:peek() == revision
			end
			local position, newer = history_anchor:peek(), ascending
			local task = ui.task(function()
				local result = { serial = serial, target = key, refresh = revision }
				if key == "history" then
					local ok, history = pcall(read_history, zeron, position, newer)
					if not selected() then return end
					result.history = if ok then history else nil
					if not result.history then result.error = "Could not read run history" end
				else
					local id = string.match(key, "^[^:]+:(.+)$")
					local ok, row, reason = pcall(runner.read_journal, id)
					if not selected() then return end
					if not ok or type(row) ~= "table" or not text(row.id) or (id and row.id ~= id) then
						if ok and (reason == "No saved run yet" or reason == "This run has no saved journal entry") then
							result.empty = reason
						else
							result.error = (if ok then text(reason) else nil) or "Could not read run journal"
						end
					else
						local built, value = pcall(snapshot, row)
						if built then
							if loaded_id ~= row.id or not value.frames[frame:peek()] then frame:set(value.active_id or "root") end
							loaded_id = row.id
							visit_page:set(1)
							ask_page:set(1)
							crew_page:set(1)
							result.checkpoint = value
						else
							result.error = "Saved snapshot is unreadable"
						end
					end
				end
				record:set(result)
			end)
			ui.on_cleanup(function() task:cancel() end)
		end)
		return ui.column { w_full = true, gap = "$space.3",
			Tabs { value = tab, label = "Run details", size = "sm", options = {
				{ value = "checkpoint", label = "Checkpoint" }, { value = "history", label = "History" },
			}, trail = Button { "Refresh", tone = "ghost", size = "sm", on_click = refresh } },
			ui.row { w_full = true, items = "center", gap = "$space.2",
				ui.show(function() return tab:get() == "history" and inspected:get() ~= nil end,
					Button { "Back to history", tone = "ghost", size = "sm", on_click = function() inspected:set(nil) end }),
				Text { function()
					local key = target:get()
					if key == "history" then return "Saved runs · Newest first" end
					if string.sub(key, 1, 6) == "saved:" then return "Saved checkpoint" end
					local checkpoint = visible().checkpoint
					if key == "latest" then
						return if checkpoint and checkpoint.row.active == 1 then "Locked checkpoint" else "Latest checkpoint"
					end
					local state = runner.state:get()
					local status = if checkpoint and checkpoint.row.id == current_id(state) then text(state.status) else nil
					return "Current checkpoint" .. (if status then " · Runner here: " .. status:gsub("_", " ") else "")
				end, style = "caption", tone = "secondary", grow = 1, min_w = 0, wrap = true },
				ui.show(function() return target:get() == "history" and history_anchor:get() ~= nil end,
					Button { "Newest", tone = "ghost", size = "sm", on_click = function() paginate(nil, false) end }),
			},
			ui.presence(function() return visible().serial or 0 end, function()
				local value = visible()
				local content = if not value.serial then caption(if target:peek() == "history" then "Reading run history…" else "Reading checkpoint…")
					elseif value.error then caption(value.error, "danger")
					elseif value.empty then caption(value.empty)
					elseif value.history then history_view(value.history, paginate, function(id) inspected:set(id) end)
					else journal_view(zeron, props.open, value.checkpoint, frame, visit_page, ask_page, crew_page)
				return ui.scroll { w_full = true, h = 320, content }
			end, { w_full = true }),
		}
	end)
	return ui.component(function(props)
		return Dialog { open = props.open, title = "Run details", size = "md", cancel = "Close",
			build = function() return Body { open = props.open } end,
		}
	end)
end
