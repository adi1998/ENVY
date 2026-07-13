---@meta _
---@diagnostic disable

local locals, auto, setup, exports_private, exports

do

	local getmetatable, setmetatable, type, traceback, getupvalue, setupvalue, upvaluejoin, getinfo, pack, unpack, error, pcall, xpcall, rawget, rawset, rawlen, tostring, pairs, ipairs, table
		= getmetatable, setmetatable, type, debug.traceback, debug.getupvalue, debug.setupvalue, debug.upvaluejoin, debug.getinfo, table.pack, table.unpack, error, pcall, xpcall, rawget, rawset, rawlen, tostring, pairs, ipairs, table

	local globals = _ENV or _G
	do
		local meta = getmetatable(globals)
		globals = meta and meta.__index or _G
	end

	local binders = setmetatable({},{__mode = "k"})

	local function getinternal( self, name )
		local binder = binders[ self ]
		local idx = 0
		repeat
			idx = idx + 1
			local n, value = getupvalue( binder, idx )
			if n == name then
				return value
			end
		until not n
	end
	local function setinternal( self, name, value )
		local binder = binders[ self ]
		local idx = name and 0 or -1
		repeat
			idx = idx + 1
			local n = getupvalue( binder, idx )
			if n == name then
				setupvalue( binder, idx, value )
				return
			end
		until not n
	end
	local function nextinternal( self, name )
		local binder = binders[ self ]
		local idx = name and 0 or -1
		repeat
			idx = idx + 1
			local n = getupvalue( binder, idx )
			if n == name then
				local value
				repeat
					idx = idx + 1
					n, value = getupvalue( binder, idx )
					if n then
						return n, value
					end
				until not n
			end
		until not n
	end

	local internal = {
		__index = getinternal,
		__newindex = setinternal,
		__next = nextinternal,
		__pairs = function( self )
			return nextinternal, self
		end
	}

	local function export( binder )
		if type( binder ) ~= "function" then
			binder = getinfo( ( binder or 1 ) + 1, "f" ).func
		end
		local bound = { }
		binders[ bound ] = binder
		return setmetatable( bound, internal )
	end

	local function import(env,file,fenv,level,...)
		local level = (level or 1) + 1
		local fenv = fenv or env
		if type(file) == "string" then
			-- assume file is a name or path
			local path = file
			if env and env._PLUGIN then
				--print('Plugin:',env._PLUGIN.guid .. '/' .. file)
				path = env._PLUGIN.plugins_mod_folder_path .. '/' .. file
			else
				--print('File:',path)
			end
			local func, msg = loadfile(path, "t", fenv)
			if func == nil then error(msg, level) end
			file = func
		elseif type(file) == "userdata" then
			-- assume file is a FILE* handle from the io module
			local valid, data = pcall(file.read, file,"*a")
			if valid then
				local func, msg = load(data, nil, "t", fenv)
				if func == nil then error(msg, level) end
				file = func
			end
		elseif type(file) == "table" then
			-- assume this is a table to import
			return file
		end
		local ret = pack(xpcall(file, traceback, ...))
		local status, msg = ret[1],ret[2]
		if not status then error(msg,level) end
		return unpack(ret, 2, ret.n)
		
	end

	local function import_all(env,mod,fenv,level,...)
		local level = (level or 1) + 1
		if type(mod) ~= "table" then
			mod = import(env,mod,fenv,level,...)
		end

		for k,v in pairs(mod) do
			rawset(env,k,v)
		end
	end

	local fallbacks = setmetatable({},{__mode = "k"})
	local shared = setmetatable({},{__mode = "k"})

	local function import_as_fallback(env,mod,fenv,level,...)
		local level = (level or 1) + 1
		if type(mod) ~= "table" then
			mod = import(env,mod,fenv,level,...)
		end
		
		fallbacks[env] = fallbacks[env] or setmetatable({},{__mode = "k"})
		if fallbacks[env][mod] then return end
		
		local meta = getmetatable(env)
		local _index = meta.__index
		if type(_index) == "table" then
			meta.__index = function(s,k)
				local v = mod[k]
				if v ~= nil then return v end
				return _index[k]
			end
		elseif type(_index) == "function" then
			meta.__index = function(s,k)
				local v = mod[k]
				if v ~= nil then return v end
				return _index(s,k)
			end
		end
		
		fallbacks[env][mod] = true
	end

	local function import_as_shared(env,mod,fenv,level,...)
		local level = (level or 1) + 1
		if type(mod) ~= "table" then
			mod = import(env,mod,fenv,level,...)
		end

		shared[env] = shared[env] or setmetatable({},{__mode = "k"})
		if shared[env][mod] then return end

		local meta = getmetatable(env)
		local _index = meta.__index
		if type(_index) == "table" then
			meta.__index = function(s,k)
				local v = mod[k]
				if v ~= nil then return v end
				return _index[k]
			end
		elseif type(_index) == "function" then
			meta.__index = function(s,k)
				local v = mod[k]
				if v ~= nil then return v end
				return _index(s,k)
			end
		end
		local _newindex = meta.__newindex
		if type(_newindex) == "table" then
			meta.__newindex = function(s,k,v)
				local u = mod[k]
				if u ~= nil then 
					mod[k] = v
				else
					_newindex[k] = v
				end
			end
		elseif type(_newindex) == "function" then
			meta.__newindex = function(s,k,v)
				local u = mod[k]
				if u ~= nil then 
					mod[k] = v
				else
					_newindex(s,k,v)
				end
			end
		end
		
		shared[env][mod] = true
	end

	local private = setmetatable({},{__mode = 'k'})
	local public = setmetatable({},{__mode = 'v'})
	local extra = setmetatable({},{__mode = 'kv'})

	local function extras(env,mod)
		local extras = {}
		for k,v in pairs(exports) do
			extras[k] = v
		end
		local binds = {
			import = function(file,fenv,...) return import(mod,file,fenv,2,...) end;
			import_all = function(file,fenv,...) return import_all(mod,file,fenv,2,...) end;
			import_as_shared = function(file,fenv,...) return import_as_shared(mod,file,fenv,2,...) end;
			import_as_fallback = function(file,fenv,...) return import_as_fallback(mod,file,fenv,2,...) end;
			private = mod;
			public = env;
		}
		for k,v in pairs(binds) do
			extras[k] = v
		end
		return extras
	end

	function setup(env)
		local mod = private[env]
		if mod ~= nil then return mod end
		mod = setmetatable({},{__index = env})
		private[env] = mod
		private[mod] = mod
		public[mod] = env
		public[env] = env
		local ext = extras(env,mod)
		extra[env] = ext
		extra[mod] = ext
		return mod, ext
	end

	local getfenv = getfenv
	if getfenv == nil then
		function getfenv( fn )
			if type( fn ) ~= "function" then
				fn = debug.getinfo( ( fn or 1 ) + 1, "f" ).func
			end
			local i = 0
			repeat
				i = i + 1
				local name, val = debug.getupvalue( fn, i )
				if name == "_ENV" then
					return val
				end
			until not name
		end
	end

	local setfenv = setfenv
	if setfenv == nil then
		function setfenv( fn, env )
			if type( fn ) ~= "function" then
				fn = debug.getinfo( ( fn or 1 ) + 1, "f" ).func
			end
			local i = 0
			repeat
				i = i + 1
				local name = debug.getupvalue( fn, i )
				if name == "_ENV" then
					debug.upvaluejoin( fn, i, ( function( )
						return env
					end ), 1 )
					return env
				end
			until not name
		end
	end

	local function getname( )
		return debug.getinfo( 2, "n" ).name  or "?"
	end

	local function pusherror( f, ... )
		local ret = table.pack( pcall( f, ... ) )
		if ret[ 1 ] then return unpack( ret, 2, ret.n ) end
		error( ret[ 2 ], 3 )
	end

	-- doesn't invoke __index
	local rawnext = next

	-- invokes __next
	local function next( t, k )
		local m = debug.getmetatable( t )
		local f = m and rawget(m,'__next') or rawnext
		return pusherror( f, t, k )
	end

	-- truly raw pairs, ignores __next and __pairs
	local function rawpairs( t )
		return rawnext, t
	end

	-- quasi-raw pairs, invokes __next but ignores __pairs
	local function qrawpairs( t )
		return next, t
	end

	-- doesn't invoke __index just like rawnext
	local function rawinext( t, i )

		if type( t ) ~= "table" then
			error( "bad argument #1 to '" .. getname( ) .. "'(table expected got " .. type( i ) ..")", 2 )
		end

		if i == nil then
			i = 0
		elseif type( i ) ~= "number" then
			error( "bad argument #2 to '" .. getname( ) .. "'(number expected got " .. type( i ) ..")", 2 )
		elseif i < 0 then
			error( "bad argument #2 to '" .. getname( ) .. "'(index out of bounds, too low)", 2 )
		end

		i = i + 1
		local v = rawget( t, i )
		if v ~= nil then
			return i, v
		end
	end

	local rawinext = rawinext

	-- invokes __inext
	local function inext( t, i )
		local m = debug.getmetatable( t )
		local f = m and rawget(m,'__inext') or rawinext
		return pusherror( f, t, i )
	end

	-- truly raw ipairs, ignores __inext and __ipairs
	local function rawipairs( t )
		return function( self, key )
			return rawinext( self, key )
		end, t, nil
	end

	-- quasi-raw ipairs, invokes __inext but ignores __ipairs
	local function qrawipairs( t )
		return function( self, key )
			return inext( self, key )
		end, t, nil
	end

	-- ignore __tostring (not thread safe?)
	local function rawtostring(t)
		-- https://stackoverflow.com/a/43286713
		local m = getmetatable( t )
		local f
		if m then
			f = m.__tostring
			m.__tostring = nil
		end
		local s = tostring( t )
		if m then
			m.__tostring = f
		end
		return s
	end

	local rawtable = table
	table = { }
	for k,v in pairs( rawtable ) do
		table[k] = v
	end

	table.rawinsert = table.insert
	local rawinsert = table.rawinsert
	-- table.insert that respects metamethods
	function table.insert( list, pos, value )
		if type(list) ~= "table" then
			error( "bad argument #1 to '" .. getname( ) .. "' (expected type 'table', received type '" .. type(list) .."')", 2 )
		end
		local last = #list
		if value == nil then
			value = pos
			pos = last + 1
		end
		if pos < 1 or pos > last + 1 then
			error( "bad argument #2 to '" .. getname( ) .. "' (position out of bounds)", 2 )
		end
		if pos <= last then
			local i = last
			repeat
				list[ i + 1 ] = list[ i ]
				i = i - 1
			until i < pos
		end
		list[ pos ] = value
	end

	table.rawremove = table.remove
	-- table.remove that respects metamethods
	function table.remove( list, pos )
		if type(list) ~= "table" then
			error( "bad argument #1 to '" .. getname( ) .. "' (expected type 'table', received type '" .. type(list) .."')", 2 )
		end
		local last = #list
		if pos == nil then
			pos = last
		end
		if pos < 0 or pos > last + 1 then
			error( "bad argument #2 to '" .. getname( ) .. "' (position out of bounds)", 2 )
		end
		local value = list[ pos ]
		if pos <= last then
			local i = pos
			repeat
				list[ i ] = list[ i + 1 ]
				i = i + 1
			until i > last
		end
		return value
	end

	table.rawunpack = unpack
	-- table.unpack that respects metamethods
	do
		local function _unpack( t, m, i, ... )
			if i < m then return ... end
			return _unpack( t, m, i - 1, t[ i ], ... )
		end
		
		---@type fun( list, i?, j? ): any
		---@diagnostic disable-next-line: duplicate-set-field
		function table.unpack( list, i, j )
			return _unpack( list, i or 1, j or list.n or #list or 1 )
		end
	end

	local rawconcat = table.concat
	table.rawconcat = rawconcat
	-- table.concat that respects metamethods and includes more values
	do
		local wt = setmetatable( { }, { __mode = 'v' } )
		function table.concat( tbl, sep, i, j )
			i = i or 1
			j = j or tbl.n or #tbl
			if i > j then return "" end
			sep = sep or ""
			for k = i, j, 1 do
				rawset( wt, k, tostring( tbl[ k ] ) )
			end
			return rawconcat( wt, sep, i, j )
		end
	end

	--[[
		NOTE: Other table functions that need to get updated to respect metamethods
		- table.sort
	--]]

	function auto(level)
		level = (level or 1) + 1
		local env = getfenv(level)
		local mod, ext = setup(env)
		setfenv(level, mod)
		if ext == nil then return end
		env._G = env
		mod._G = mod
		import_all(mod, ext)
		return ext
	end

	locals = export(function()
		-- environment
		return _ENV, -- note that in some versions _ENV is not an upvalue so will not be exported
		-- binds
		getmetatable, setmetatable, type, traceback, getupvalue, setupvalue, upvaluejoin, getinfo, pack, unpack, error, pcall, xpcall, rawget, rawset, rawlen, tostring, pairs, ipairs, table,
		rawtable,
		-- tables
		binders, fallbacks, shared, 
		internal, private, public, extra,
		locals, exports_private, exports,
		-- functions
		getinternal, setinternal, nextinternal, endow,
		globals, export, import, import_all, import_as_fallback, import_as_shared, setup, auto, getfenv, setfenv
	end)

	exports = export(function()
		return globals, export, import, import_all, import_as_fallback, import_as_shared, getfenv, setfenv,
		-- global extensions
		table, next, rawnext, inext, rawinext, rawtostring, rawpairs, rawipairs, qrawpairs, qrawipairs
	end)

end

-- extending itself

---@module 'LuaENVY-ENVY-auto'
auto()

for k,v in pairs(exports) do
	public[k] = v
end

public.locals = locals
public.setup = setup
public.auto = auto