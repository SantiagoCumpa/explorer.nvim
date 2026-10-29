if vim.g.loaded_explorer_nvim then
	return
end
vim.g.loaded_explorer_nvim = true

-- Global `Explorer` (como `Snacks`): el módulo se carga recién al usarlo
if _G.Explorer == nil then
	_G.Explorer = setmetatable({}, {
		__index = function(_, key)
			return require("explorer")[key]
		end,
	})
end
