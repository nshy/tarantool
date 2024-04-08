local config = require('config')
local checks = require('checks')
local netbox = require('net.box')

local connections = {}

local function is_connection_valid(conn, opts)
    if conn == nil or conn.state == 'error' or conn.state == 'closed' then
        return false
    end
    assert(type(opts) == 'table')
    local conn_opts = conn.opts or {}
    if opts.fetch_schema ~= false and conn_opts.fetch_schema == false then
        return false
    end
    return true
end

local function connect(instance_name, opts)
    checks('string', {
        connect_timeout = '?number',
        wait_connected = '?boolean',
        fetch_schema = '?boolean',
    })
    opts = opts or {}

    local conn = connections[instance_name]
    if not is_connection_valid(conn, opts) then
        local uri = config:instance_uri('peer', {instance = instance_name})
        if uri == nil then
            local err = 'No suitable URI provided for instance %q'
            error(err:format(instance_name), 0)
        end

        local conn_opts = {
            connect_timeout = opts.connect_timeout,
            wait_connected = false,
            fetch_schema = opts.fetch_schema,
        }
        local ok, res = pcall(netbox.connect, uri, conn_opts)
        if not ok then
            local msg = 'Unable to connect to instance %q: %s'
            error(msg:format(instance_name, res.message), 0)
        end
        conn = res
        connections[instance_name] = conn
    end

    -- If opts.wait_connected is not false we wait until the connection is
    -- established or an error occurs (including a timeout error).
    if opts.wait_connected ~= false and conn:wait_connected() == false then
        local msg = 'Unable to connect to instance %q: connection timeout'
        error(msg:format(instance_name), 0)
    end
    return conn
end

local function is_roles_match(expected_roles, present_roles)
    if expected_roles == nil or next(expected_roles) == nil then
        return true
    end
    if present_roles == nil or next(present_roles) == nil then
        return false
    end

    local roles = {}
    for _, present_role_name in pairs(present_roles) do
        roles[present_role_name] = true
    end
    for _, expected_role_name in pairs(expected_roles) do
        if roles[expected_role_name] == nil then
            return false
        end
    end
    return true
end

local function is_labels_match(expected_labels, present_labels)
    if expected_labels == nil or next(expected_labels) == nil then
        return true
    end
    if present_labels == nil or next(present_labels) == nil then
        return false
    end

    for label, value in pairs(expected_labels) do
        if present_labels[label] ~= value then
            return false
        end
    end
    return true
end

local function is_candidate_match(instance_name, opts)
    assert(opts ~= nil and type(opts) == 'table')
    local get_opts = {instance = instance_name}
    return is_roles_match(opts.roles, config:get('roles', get_opts)) and
           is_labels_match(opts.labels, config:get('labels', get_opts))
end

local function filter(opts)
    checks({
        labels = '?table',
        roles = '?table',
    })
    local candidates = {}
    for instance_name in pairs(config:instances()) do
        if is_candidate_match(instance_name, opts or {}) then
            table.insert(candidates, instance_name)
        end
    end
    return candidates
end

local function get_connection(all_candidates, prefer_local)
    local candidates = table.copy(all_candidates)
    if prefer_local ~= false then
        local candidate_idx = nil
        for n, candidate in ipairs(candidates) do
            if candidate == box.info.name then
                candidate_idx = n
                local conn = connect(box.info.name, {wait_connected = false})
                if conn:wait_connected() then
                    return conn
                end
                break
            end
        end
        if candidate_idx ~= nil then
            table.remove(candidates, candidate_idx)
        end
    end

    while #candidates > 0 do
        local n = math.random(#candidates)
        local instance_name = table.remove(candidates, n)
        local conn = connect(instance_name, {wait_connected = false})
        if conn:wait_connected() then
            return conn
        end
    end
    return nil
end

local function call(func_name, args, opts)
    checks('string', '?table', {
        labels = '?table',
        roles = '?table',
        prefer_local = '?boolean',
        -- The following options passed directly to net.box.call().
        timeout = '?',
        buffer = '?',
        on_push = '?function',
        on_push_ctx = '?',
        is_async = '?boolean',
    })
    opts = opts or {}

    local candidates_opts = {
        labels = opts.labels,
        roles = opts.roles,
    }
    local candidates = filter(candidates_opts)
    if next(candidates) == nil then
        local msg = "Couldn't execute function %s: no candidates are " ..
                    "available with these conditions"
        error(msg:format(func_name), 0)
    end

    local conn = get_connection(candidates, opts.prefer_local)
    if conn == nil then
        local msg = "Couldn't execute function %s: connection to " ..
                    "candidates failed"
        error(msg:format(func_name), 0)
    end

    local net_box_call_opts = {
        timeout = opts.timeout,
        buffer = opts.buffer,
        on_push = opts.on_push,
        on_push_ctx = opts.on_push_ctx,
        is_async = opts.is_async,
    }
    return conn:call(func_name, args, net_box_call_opts)
end

return {
    connect = connect,
    filter = filter,
    call = call,
}