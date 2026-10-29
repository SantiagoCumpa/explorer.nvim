-- Íconos: mini.icons si está configurado, si no nvim-web-devicons, si no unos básicos.

local M = {}

-- Codicons de VSCode (incluidos en las Nerd Fonts)
local fallback_kinds = {
	File = "\u{eb60}", Module = "\u{ea8b}", Namespace = "\u{ea8b}", Package = "\u{ea8b}",
	Class = "\u{eb5b}", Method = "\u{ea8c}", Property = "\u{eb65}", Field = "\u{eb5f}",
	Constructor = "\u{ea8c}", Enum = "\u{ea95}", Interface = "\u{eb61}", Function = "\u{ea8c}",
	Variable = "\u{ea88}", Constant = "\u{eb5d}", String = "\u{eb8d}", Number = "\u{ea90}",
	Boolean = "\u{ea8f}", Array = "\u{ea8a}", Object = "\u{ea8b}", Key = "\u{ea93}",
	Null = "\u{eb63}", EnumMember = "\u{eb5e}", Struct = "\u{ea91}", Event = "\u{ea86}",
	Operator = "\u{eb64}", TypeParameter = "\u{ea92}",
}

---@param path string
---@param is_dir boolean
---@return string icon, string hl
function M.file(path, is_dir)
	local name = vim.fs.basename(path)
	if _G.MiniIcons then
		local ok, icon, hl = pcall(_G.MiniIcons.get, is_dir and "directory" or "file", name)
		if ok then
			return icon, hl
		end
	end
	if is_dir then
		return "\u{ea83}", "ExplorerDirectory"
	end
	local ok, devicons = pcall(require, "nvim-web-devicons")
	if ok then
		local icon, hl = devicons.get_icon(name, vim.fn.fnamemodify(name, ":e"), { default = true })
		return icon, hl
	end
	return "\u{ea7b}", "ExplorerFile"
end

---@param kind string  nombre del SymbolKind de LSP ("Function", "Class"...)
---@return string icon, string hl
function M.kind(kind)
	if _G.MiniIcons then
		local ok, icon, hl = pcall(_G.MiniIcons.get, "lsp", kind:lower())
		if ok then
			return icon, hl
		end
	end
	return fallback_kinds[kind] or "\u{eb63}", "ExplorerOutlineKind"
end

return M
