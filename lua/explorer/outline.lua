-- Outline: símbolos del archivo actual (funciones, clases, variables...) según el LSP.

local config = require("explorer.config")
local icons = require("explorer.icons")

local uv = vim.uv or vim.loop

local M = {}

local ns = vim.api.nvim_create_namespace("explorer.outline")
local chevron_open, chevron_closed = "\u{eab4}", "\u{eab6}"

---@class explorer.Symbol
---@field name string
---@field kind string
---@field detail? string
---@field range lsp.Range
---@field selection lsp.Range
---@field children explorer.Symbol[]
---@field key string  identificador estable para recordar si está colapsado

local S = {
	buf = nil, ---@type integer?
	source = nil, ---@type integer?  buffer del editor del que se muestran los símbolos
	symbols = {}, ---@type explorer.Symbol[]
	encoding = "utf-16",
	message = nil, ---@type string?
	collapsed = {}, ---@type table<string, boolean>  símbolos con estado distinto al de `expand`
	lines = {}, ---@type explorer.Symbol[]  símbolo de cada línea
	request = 0,
	timer = nil, ---@type uv.uv_timer_t?
}

local function layout()
	return require("explorer.layout")
end

local function opts()
	return config.options.outline
end

-- `toggled` guarda los símbolos que difieren del estado por defecto (`expand`)
local function is_collapsed(key)
	local default = not opts().expand
	if S.collapsed[key] then
		return not default
	end
	return default
end

local function set_collapsed(key, value)
	S.collapsed[key] = (value ~= not opts().expand) or nil
end

--- Buffer del outline (se crea una sola vez).
function M.buf()
	if S.buf and vim.api.nvim_buf_is_valid(S.buf) then
		return S.buf
	end
	local buf = vim.api.nvim_create_buf(false, true)
	S.buf = buf
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].filetype = "explorer_outline"
	vim.bo[buf].modifiable = false
	M._set_mappings(buf)
	return buf
end

-- Símbolos ----------------------------------------------------------------------

-- SymbolKind de la especificación de LSP. No se usa vim.lsp.protocol.SymbolKind
-- porque otros plugins lo modifican (p. ej. MiniIcons.tweak_lsp_kind() le
-- antepone íconos a los nombres)
local kinds = {
	"File", "Module", "Namespace", "Package", "Class", "Method", "Property", "Field", "Constructor",
	"Enum", "Interface", "Function", "Variable", "Constant", "String", "Number", "Boolean", "Array",
	"Object", "Key", "Null", "EnumMember", "Struct", "Event", "Operator", "TypeParameter",
}

local function kind_name(kind)
	return kinds[kind] or "Null"
end

local function contains(outer, inner)
	local s, e = outer.start, outer["end"]
	local is, ie = inner.start, inner["end"]
	local after_start = is.line > s.line or (is.line == s.line and is.character >= s.character)
	local before_end = ie.line < e.line or (ie.line == e.line and ie.character <= e.character)
	return after_start and before_end
end

--- DocumentSymbol[] (jerárquico) o SymbolInformation[] (plano) -> árbol.
local function convert(result)
	if not result or #result == 0 then
		return {}
	end
	if result[1].location then
		-- Plano: armar la jerarquía por rangos
		local items = {}
		for _, s in ipairs(result) do
			table.insert(items, {
				name = s.name,
				kind = kind_name(s.kind),
				range = s.location.range,
				selection = s.location.range,
				children = {},
			})
		end
		table.sort(items, function(a, b)
			local x, y = a.range.start, b.range.start
			return x.line < y.line or (x.line == y.line and x.character < y.character)
		end)
		local roots, stack = {}, {}
		for _, item in ipairs(items) do
			while #stack > 0 and not contains(stack[#stack].range, item.range) do
				table.remove(stack)
			end
			table.insert(#stack > 0 and stack[#stack].children or roots, item)
			table.insert(stack, item)
		end
		return roots
	end
	local function walk(list)
		local out = {}
		for _, s in ipairs(list or {}) do
			table.insert(out, {
				name = s.name,
				kind = kind_name(s.kind),
				detail = s.detail,
				range = s.range,
				selection = s.selectionRange or s.range,
				children = walk(s.children),
			})
		end
		table.sort(out, function(a, b)
			local x, y = a.range.start, b.range.start
			return x.line < y.line or (x.line == y.line and x.character < y.character)
		end)
		return out
	end
	return walk(result)
end

local function assign_keys(list, prefix)
	for _, s in ipairs(list) do
		s.key = prefix .. "/" .. s.kind .. ":" .. s.name
		assign_keys(s.children, s.key)
	end
end

-- Dibujo ------------------------------------------------------------------------

function M.render()
	local buf = M.buf()
	local lines, items, marks = {}, {}, {}

	if S.message then
		lines = { "  " .. S.message }
		table.insert(marks, { 0, 0, #lines[1], "ExplorerOutlineMessage" })
	else
		local function walk(list, depth)
			for _, s in ipairs(list) do
				local has_children = #s.children > 0
				local expanded = has_children and not is_collapsed(s.key)
				local chevron = has_children and (expanded and chevron_open or chevron_closed) or " "
				local icon, icon_hl = icons.kind(s.kind)
				local indent = string.rep(" ", depth * 2)
				local line = indent .. chevron .. " " .. icon .. " " .. s.name
				local row = #lines
				local col = #indent
				table.insert(marks, { row, col, col + #chevron, "ExplorerChevron" })
				col = col + #chevron + 1
				table.insert(marks, { row, col, col + #icon, icon_hl })
				col = col + #icon + 1
				table.insert(marks, { row, col, #line, "ExplorerOutlineName" })
				if s.detail and s.detail ~= "" then
					table.insert(marks, { row, nil, nil, nil, s.detail })
				end
				table.insert(lines, line)
				table.insert(items, s)
				if expanded then
					walk(s.children, depth + 1)
				end
			end
		end
		walk(S.symbols, 0)
		if #lines == 0 then
			lines = { "  No hay símbolos" }
			table.insert(marks, { 0, 0, #lines[1], "ExplorerOutlineMessage" })
		end
	end

	S.lines = items
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
	for _, m in ipairs(marks) do
		if m[5] then
			vim.api.nvim_buf_set_extmark(buf, ns, m[1], 0, {
				virt_text = { { " " .. m[5]:gsub("\n", " "), "ExplorerOutlineDetail" } },
				virt_text_pos = "eol",
			})
		else
			vim.api.nvim_buf_set_extmark(buf, ns, m[1], m[2], { end_col = m[3], hl_group = m[4] })
		end
	end
	M.follow()
end

-- Pedido al LSP -------------------------------------------------------------------

local method = "textDocument/documentSymbol"

--- Vuelve a pedir los símbolos del buffer del editor.
---@param buf? integer
function M.refresh(buf)
	buf = buf or S.source
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		S.message, S.symbols = "Sin archivo", {}
		return M.render()
	end
	S.source = buf
	local client = vim.lsp.get_clients({ bufnr = buf, method = method })[1]
	if not client then
		S.message, S.symbols = "Sin LSP para este archivo", {}
		return M.render()
	end
	S.request = S.request + 1
	local request = S.request
	local params = { textDocument = vim.lsp.util.make_text_document_params(buf) }
	client:request(method, params, function(err, result)
		if request ~= S.request or buf ~= S.source then
			return -- llegó tarde: ya se pidió otro
		end
		if err then
			S.message, S.symbols = "Error del LSP: " .. (err.message or "?"), {}
		else
			S.message = nil
			S.encoding = client.offset_encoding or "utf-16"
			S.symbols = convert(result)
			assign_keys(S.symbols, "")
		end
		if layout().outline_win() then
			M.render()
		end
	end, buf)
end

--- Pedido diferido (mientras se escribe).
function M.schedule_refresh()
	if S.timer then
		S.timer:stop()
	else
		S.timer = uv.new_timer()
	end
	S.timer:start(
		400,
		0,
		vim.schedule_wrap(function()
			if layout().outline_win() then
				M.refresh()
			end
		end)
	)
end

--- Cambia el buffer del que se muestran los símbolos.
---@param buf integer
function M.set_source(buf)
	if buf == S.source then
		return
	end
	S.source = buf
	S.symbols, S.message = {}, nil
	if layout().outline_win() then
		M.refresh(buf)
	end
end

function M.source()
	return S.source
end

-- Seguir el cursor ----------------------------------------------------------------

--- Resalta el símbolo donde está el cursor del editor.
function M.follow()
	local win = layout().outline_win()
	if not win or not opts().follow_cursor or win == vim.api.nvim_get_current_win() then
		return
	end
	local editor
	for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if vim.api.nvim_win_get_buf(w) == S.source then
			editor = w
			break
		end
	end
	if not editor then
		return
	end
	local row, col = unpack(vim.api.nvim_win_get_cursor(editor))
	local pos = { line = row - 1, character = col }
	local best
	for i, s in ipairs(S.lines) do
		if contains(s.range, { start = pos, ["end"] = pos }) then
			best = i -- el último que contiene el cursor es el más interno
		end
	end
	if best then
		pcall(vim.api.nvim_win_set_cursor, win, { best, 0 })
	end
end

-- Acciones -----------------------------------------------------------------------

local function symbol_at_cursor()
	local win = layout().outline_win()
	return win and S.lines[vim.api.nvim_win_get_cursor(win)[1]]
end

---@param focus_editor boolean
local function jump(focus_editor)
	local s = symbol_at_cursor()
	if not s or not S.source then
		return
	end
	local outline = layout().outline_win()
	local win = layout().editor_win(true)
	if vim.api.nvim_win_get_buf(win) ~= S.source then
		vim.api.nvim_win_set_buf(win, S.source)
	end
	local pos = s.selection.start
	local line = vim.api.nvim_buf_get_lines(S.source, pos.line, pos.line + 1, false)[1] or ""
	local ok, col = pcall(vim.str_byteindex, line, S.encoding, pos.character, false)
	vim.api.nvim_win_set_cursor(win, { pos.line + 1, ok and col or 0 })
	vim.api.nvim_win_call(win, function()
		vim.cmd("normal! zv")
	end)
	if focus_editor then
		vim.api.nvim_set_current_win(win)
	elseif outline then
		vim.api.nvim_set_current_win(outline)
	end
end

--- `<CR>`: salta al símbolo y pasa al editor.
function M.jump()
	jump(true)
end

--- `l`: expande el símbolo, o salta a él sin dejar el outline.
function M.go_in()
	local s = symbol_at_cursor()
	if not s then
		return
	end
	if #s.children > 0 and is_collapsed(s.key) then
		set_collapsed(s.key, false)
		return M.render()
	end
	jump(false)
end

--- `h`: colapsa el símbolo, o vuelve al símbolo padre.
function M.go_out()
	local win = layout().outline_win()
	local s = symbol_at_cursor()
	if not s or not win then
		return
	end
	if #s.children > 0 and not is_collapsed(s.key) then
		set_collapsed(s.key, true)
		return M.render()
	end
	local parent_key = s.key:match("^(.*)/[^/]*$")
	for i, item in ipairs(S.lines) do
		if item.key == parent_key then
			set_collapsed(parent_key, true)
			M.render()
			return vim.api.nvim_win_set_cursor(win, { i, 0 })
		end
	end
end

--- `H`: colapsa todos los símbolos.
function M.collapse_all()
	local function walk(list)
		for _, s in ipairs(list) do
			if #s.children > 0 then
				set_collapsed(s.key, true)
				walk(s.children)
			end
		end
	end
	walk(S.symbols)
	M.render()
end

local descriptions = {
	jump = "Ir al símbolo",
	go_in = "Expandir / ir al símbolo (sin dejar el outline)",
	jump_focus = "Ir al símbolo",
	go_out = "Colapsar / ir al símbolo padre",
	collapse_all = "Colapsar todo",
	close = "Cerrar",
	show_help = "Ayuda",
}

local actions = {
	jump = M.jump,
	jump_focus = M.jump,
	go_in = M.go_in,
	go_out = M.go_out,
	collapse_all = M.collapse_all,
	close = function()
		layout().close()
	end,
	show_help = function()
		local lines = { " Outline", "" }
		for action, lhs in pairs(opts().mappings) do
			if lhs and lhs ~= "" then
				table.insert(lines, (" %-6s %s"):format(lhs, descriptions[action] or action))
			end
		end
		layout().help(lines)
	end,
}

function M._set_mappings(buf)
	for action, lhs in pairs(opts().mappings) do
		if lhs and lhs ~= "" and actions[action] then
			vim.keymap.set("n", lhs, actions[action], { buffer = buf, nowait = true, desc = descriptions[action] })
		end
	end
end

return M
