-- luau-golf Runtime VM Interpreter
local payload = ...

if not payload then
    return
end

local buf = buffer.fromstring(payload)
local len = buffer.len(buf)
local cursor = 0

-- 1. Read Constant Pool Size
local const_count = buffer.readu8(buf, cursor)
cursor = cursor + 1

local constants = {}
for i = 0, const_count - 1 do
    local ctype = buffer.readu8(buf, cursor)
    cursor = cursor + 1
    if ctype == 1 then -- String Constant
        local str_len = buffer.readu8(buf, cursor)
        cursor = cursor + 1
        local str = buffer.readstring(buf, cursor, str_len)
        cursor = cursor + str_len
        constants[i] = str
    elseif ctype == 2 then -- Number Constant
        local num = buffer.readf64(buf, cursor)
        cursor = cursor + 8
        constants[i] = num
    end
end

-- 2. Bit-packed Bytecode Reader
local nibble_buffer = nil
local function read_nibble()
    if nibble_buffer then
        local n = nibble_buffer
        nibble_buffer = nil
        return n
    else
        local b = buffer.readu8(buf, cursor)
        cursor = cursor + 1
        nibble_buffer = bit32.band(b, 0x0F)
        return bit32.rshift(b, 4)
    end
end

local function read_byte()
    nibble_buffer = nil
    local b = buffer.readu8(buf, cursor)
    cursor = cursor + 1
    return b
end

-- Execution Stack & Registers
local stack = {}
local locals = {}

local env = setmetatable({}, {
    __index = getfenv()
})

-- 3. Execute Instructions
while cursor < len or nibble_buffer ~= nil do
    local op = read_nibble()

    if op == 0x0 then -- PUSH_GLOBAL
        local idx = read_byte()
        local global_name = constants[idx]
        table.insert(stack, env[global_name] or _G[global_name])

    elseif op == 0x1 then -- PUSH_CONST
        local idx = read_byte()
        table.insert(stack, constants[idx])

    elseif op == 0x2 then -- PUSH_SMALL_INT
        local val = read_nibble()
        table.insert(stack, val)

    elseif op == 0x3 then -- GET_FIELD
        local idx = read_byte()
        local field_name = constants[idx]
        local parent = table.remove(stack)
        table.insert(stack, parent[field_name])

    elseif op == 0x4 then -- SET_FIELD
        local idx = read_byte()
        local field_name = constants[idx]
        local parent = table.remove(stack)
        local val = table.remove(stack)
        parent[field_name] = val

    elseif op == 0x6 then -- CALL
        local arg_count = read_nibble()
        local args = {}
        for i = arg_count, 1, -1 do
            args[i] = table.remove(stack)
        end
        local func = table.remove(stack)
        
        if func then
            local results = { func(unpack(args)) }
            for i = 1, #results do
                table.insert(stack, results[i])
            end
        end

    elseif op == 0x7 then -- INVOKE_METHOD
        local method_idx = read_byte()
        local arg_count = read_nibble()
        local method_name = constants[method_idx]

        local args = {}
        for i = arg_count, 1, -1 do
            args[i] = table.remove(stack)
        end

        local obj = table.remove(stack)
        if obj and obj[method_name] then
            local method = obj[method_name]
            local results = { method(obj, unpack(args)) }
            for i = 1, #results do
                table.insert(stack, results[i])
            end
        end

    elseif op == 0xA then -- POP_LOCAL
        local slot = read_nibble()
        locals[slot] = table.remove(stack)

    elseif op == 0xB then -- PUSH_LOCAL
        local slot = read_nibble()
        table.insert(stack, locals[slot])
    end
end
