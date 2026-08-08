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

local function read_index()
    local low = read_nibble()
    local high = read_nibble()
    return bit32.bor(low, bit32.lshift(high, 4))
end

-- Execution Stack & Registers
local stack = {}
local locals = {}

local env = setmetatable({}, {
    __index = getfenv()
})

local function pop_stack()
    if #stack == 0 then
        return nil
    end
    return table.remove(stack)
end

-- 3. Execute Instructions
while cursor < len or nibble_buffer ~= nil do
    local op = read_nibble()

    if op == 0x0 then -- PUSH_GLOBAL
        local idx = read_byte()
        local global_name = constants[idx]
        if global_name == "" then
            table.insert(stack, nil)
        else
            table.insert(stack, env[global_name] or _G[global_name])
        end

    elseif op == 0x1 then -- PUSH_CONST
        local idx = read_byte()
        table.insert(stack, constants[idx])

    elseif op == 0x2 then -- PUSH_SMALL_INT
        local val = read_nibble()
        table.insert(stack, val)

    elseif op == 0x3 then -- GET_FIELD
        local idx = read_byte()
        local field_name = constants[idx]
        local parent = pop_stack()
        if parent ~= nil then
            table.insert(stack, parent[field_name])
        else
            table.insert(stack, nil)
        end

    elseif op == 0x4 then -- SET_FIELD
        local idx = read_byte()
        local field_name = constants[idx]
        local val = pop_stack()    -- Value popped first
        local parent = pop_stack() -- Parent popped second
        if parent ~= nil then
            parent[field_name] = val
        end

    elseif op == 0x6 then -- CALL
        local arg_count = read_nibble()
        local args = {}
        for i = arg_count, 1, -1 do
            args[i] = pop_stack()
        end
        local func = pop_stack()
        
        if type(func) == "function" then
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
            args[i] = pop_stack()
        end

        local obj = pop_stack()
        if obj ~= nil then
            local method = obj[method_name]
            if type(method) == "function" then
                local results = { method(obj, unpack(args)) }
                for i = 1, #results do
                    table.insert(stack, results[i])
                end
            end
        end

    elseif op == 0xA then -- POP_LOCAL
        local slot = read_index()
        locals[slot] = pop_stack()

    elseif op == 0xB then -- PUSH_LOCAL
        local slot = read_index()
        table.insert(stack, locals[slot])
    end
end
