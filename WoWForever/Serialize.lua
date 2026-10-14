local addon = WoWForever

-- Minimal dependency-free serializer for plain data tables (string/number keys;
-- string/number/boolean/table values). Strings are length-prefixed so no
-- escaping is needed. Deserialize is defensive because its input comes from
-- other players: it never executes anything and enforces size/depth limits.
--
--   s<len>:<bytes>   string
--   n<number>;       number
--   T / F            boolean
--   { k v k v ... }  table

local MAX_DEPTH = 8
local MAX_NODES = 50000

local function SerializeValue(value, out)
	local valueType = type(value)
	if valueType == "string" then
		out[#out + 1] = "s" .. #value .. ":" .. value
	elseif valueType == "number" then
		out[#out + 1] = "n" .. tostring(value) .. ";"
	elseif valueType == "boolean" then
		out[#out + 1] = value and "T" or "F"
	elseif valueType == "table" then
		out[#out + 1] = "{"
		for key, inner in pairs(value) do
			local keyType, innerType = type(key), type(inner)
			if (keyType == "string" or keyType == "number")
				and (innerType == "string" or innerType == "number" or innerType == "boolean" or innerType == "table") then
				SerializeValue(key, out)
				SerializeValue(inner, out)
			end
		end
		out[#out + 1] = "}"
	end
end

function addon.Serialize(value)
	local out = {}
	SerializeValue(value, out)
	return table.concat(out)
end

-- Returns the decoded value, or nil if the input is malformed or too large.
function addon.Deserialize(str)
	if type(str) ~= "string" then
		return nil
	end
	local pos, len, nodes = 1, #str, 0

	local ReadValue
	ReadValue = function(depth)
		nodes = nodes + 1
		if nodes > MAX_NODES or depth > MAX_DEPTH then
			error("limit")
		end
		local tag = str:sub(pos, pos)
		pos = pos + 1
		if tag == "s" then
			local colon = str:find(":", pos, true)
			local size = colon and tonumber(str:sub(pos, colon - 1))
			if not size or size < 0 or size % 1 ~= 0 or colon + size > len then
				error("bad string")
			end
			pos = colon + size + 1
			return str:sub(colon + 1, colon + size)
		elseif tag == "n" then
			local semi = str:find(";", pos, true)
			local number = semi and tonumber(str:sub(pos, semi - 1))
			if not number or number ~= number then
				error("bad number")
			end
			pos = semi + 1
			return number
		elseif tag == "T" then
			return true
		elseif tag == "F" then
			return false
		elseif tag == "{" then
			local result = {}
			while true do
				if pos > len then
					error("unterminated table")
				end
				if str:sub(pos, pos) == "}" then
					pos = pos + 1
					return result
				end
				local key = ReadValue(depth + 1)
				if type(key) ~= "string" and type(key) ~= "number" then
					error("bad key")
				end
				result[key] = ReadValue(depth + 1)
			end
		end
		error("bad tag")
	end

	local ok, result = pcall(ReadValue, 1)
	if not ok or pos ~= len + 1 then
		return nil
	end
	return result
end
