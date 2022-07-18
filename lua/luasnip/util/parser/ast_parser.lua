local ast_utils = require("luasnip.util.parser.ast_utils")
local tNode = require("luasnip.nodes.textNode")
local iNode = require("luasnip.nodes.insertNode")
local fNode = require("luasnip.nodes.functionNode")
local cNode = require("luasnip.nodes.choiceNode")
local dNode = require("luasnip.nodes.dynamicNode")
local sNode = require("luasnip.nodes.snippet")
local functions = require("luasnip.util.functions")
local Environ = require("luasnip.util.environ")
local session = require("luasnip.session")
local util = require("luasnip.util.util")

local M = {}

local _split = function(s)
	return vim.split(s, "\n", { plain = true })
end

local types = ast_utils.types

local _to_node

local function fix_node_indices(nodes)
	local used_nodes = {}
	for _, node in ipairs(nodes) do
		if node.pos and node.pos > 0 then
			used_nodes[node.pos] = node
		end
	end

	for _, v, i in util.key_sorted_pairs(used_nodes) do
		v.pos = i
	end
	return nodes
end

local function to_nodes(ast_nodes, state)
	local nodes = {}
	for i, ast_node in ipairs(ast_nodes) do
		nodes[i] = _to_node(ast_node, state)
	end

	return fix_node_indices(nodes)
end

local function var_func(varname, variable)
	local transform_func
	if variable.transform then
		transform_func = ast_utils.apply_transform(variable.transform)
	else
		transform_func = util.id
	end
	return function(_, parent)
		local v = parent.snippet.env[varname]
		local lines
		if type(v) == "table" then
			-- Avoid issues with empty vars
			if #v > 0 then
				lines = v
			else
				lines = { "" }
			end
		else
			lines = { v }
		end
		return transform_func(lines)
	end
end

local function copy_func(tabstop)
	local transform_func
	if tabstop.transform then
		transform_func = ast_utils.apply_transform(tabstop.transform)
	else
		transform_func = util.id
	end
	return function(args)
		return transform_func(args[1])
	end
end
-- these actually create nodes from any AST.
local to_node_funcs = {
	-- careful! this only returns a list of nodes, not a full snippet!
	-- The table can be passed to the regular snippet-constructors.
	[types.SNIPPET] = function(ast, state)
		return to_nodes(ast.children, state)
	end,
	[types.TEXT] = function(ast, state)
		local text = _split(ast.esc)
		-- store text for `VARIABLE`, might be needed for indentation.
		state.last_text = text
		return tNode.T(text)
	end,
	[types.CHOICE] = function(ast)
		local choices = {}
		for i, choice in ipairs(ast.items) do
			choices[i] = tNode.T(_split(choice))
		end

		return cNode.C(ast.tabstop, choices)
	end,
	[types.TABSTOP] = function(ast, state)
		local existing_tabstop = state.tabstops[ast.tabstop]
		if existing_tabstop then
			-- this tabstop is a mirror of an already-parsed tabstop/placeholder.
			return fNode.F(copy_func(ast), { existing_tabstop })
		end

		-- tabstops don't have placeholder-text.
		local node = iNode.I(ast.tabstop)
		state.tabstops[ast.tabstop] = node

		return node
	end,
	[types.PLACEHOLDER] = function(ast, state)
		-- check from TABSTOP.
		local existing_tabstop = state.tabstops[ast.tabstop]
		if existing_tabstop then
			return fNode.F(functions.copy, { existing_tabstop })
		end

		local node

		if #ast.children == 1 and ast.children[1].type == types.TEXT then
			-- placeholder only contains text, like `"${1:adsf}"`.
			-- `"${1}"` are parsed as tabstops.
			node = iNode.I(ast.tabstop, ast.children[1].esc)
		else
			local snip = sNode.SN(ast.tabstop, to_nodes(ast.children, state))
			if not snip:is_interactive() then
				-- this placeholder only contains text or (transformed)
				-- variables, so an insertNode can be generated from its
				-- contents on expansion.
				node = dNode.D(ast.tabstop, function(_, parent)
					-- create new snippet that only contains the parsed
					-- snippetNode.
					-- The children have to be copied to prevent every
					-- expansion getting the same object.
					local snippet = sNode.S("", snip:copy())

					-- get active env from snippet.
					snippet:fake_expand({ env = parent.snippet.env })
					local iText = snippet:get_static_text()

					-- no need to un-escape iText, that was already done.
					return sNode.SN(nil, iNode.I(1, iText))
				end, {})
			else
				node = session.config.parser_nested_assembler(ast.tabstop, snip)
			end
		end

		state.tabstops[ast.tabstop] = node
		return node
	end,
	[types.VARIABLE] = function(ast, state)
		local var = ast.name
		local fn
		if Environ.is_valid_var(var) then
			fn = var_func(var, ast)
		elseif state.var_functions[var] then
			fn = state.var_functions[var]
		else
			-- if the variable is unknown, just insert an empty text-snippet.
			-- maybe put this into `state.last_text`? otoh, this won't be visible.
			-- Don't for now.
			return tNode.T({ "" })
		end

		local f = fNode.F(fn, {})

		-- if the variable is preceded by \n<indent>, the indent is applied to
		-- all lines of the variable (important for eg. TM_SELECTED_TEXT).
		if state.last_text ~= nil and #state.last_text > 1 then
			local last_line_indent = state.last_text[#state.last_text]:match(
				"^%s+$"
			)
			if last_line_indent then
				-- TM_SELECTED_TEXT contains the indent of the selected
				-- snippets, which leads to correct indentation if the
				-- snippet is expanded at the position the text was removed
				-- from.
				-- This seems pretty stupid, but TM_SELECTED_TEXT is
				-- desigend to be compatible with vscode.
				-- Use SELECT_DEDENT insted.
				-- stylua: ignore
				local indentstring = var ~= "TM_SELECTED_TEXT"
					and "$PARENT_INDENT" .. last_line_indent
					or last_line_indent

				f = sNode.ISN(nil, { f }, indentstring)
			end
		end

		return f
	end,
}

--- Converts any ast into usable nodes.
--- Snippets return a table of nodes, those can be used like `fmt`.
---@param ast table: AST, as generated by `require("vim.lsp._snippet").parse`
---@param state table:
--- - `tabstops`: maps tabstop-position to already-parsed tabstops.
--- - `last_text`: stores last text, VARIABLE might have to be indented with
---   its contents (`"\n\t$SOMEVAR"`, all lines of $SOMEVAR have to be indented
---   with "\t").
--- - `var_functions`: table, maps varname to custom function for that variable.
---   For now, only used when parsing snipmate-snippets.
--- This should most likely be `{}`.
---@return table: node corresponding to `ast`.
function to_node(ast, state)
	if not Ast.is_node(ast) then
		-- ast is not an ast (probably a luasnip-node), return it as-is.
		return ast
	end
	return to_node_funcs[ast.type](ast, state)
end

function M.to_node(ast, opts)
	return _to_node(
		ast,
		vim.tbl_extend("keep", opts or {}, {
			tabstops = {},
			var_functions = {},
			last_text = nil,
		})
	)
end

return M
