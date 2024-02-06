local server = require('luatest.server')
local utils = require('luatest.utils')
local fiber = require('fiber')
local fio = require('fio')
local popen = require('popen')
local t = require('luatest')

local g = t.group()

local delay_shutdown
local delay_shutdown_cond = fiber.cond()

g.before_each(function(cg)
    cg.server = server:new()
    cg.server:start()
    cg.server:exec(function()
        local fiber = require('fiber')
        local socket = require('socket')
        rawset(_G, 'delay_shutdown', true)
        rawset(_G, 'delay_shutdown_cond', fiber.cond())
        rawset(_G, 'delay_shutdown', function()
            while _G.delay_shutdown do
                _G.delay_shutdown_cond:wait()
            end
        end)
        -- Wait until we refuse to connect which means iproto shutdown trigger
        -- is finished and new connections should not be possible.
        rawset(_G, 'wait_iproto_shutdown', function()
            t.helpers.retrying({}, function()
                local sock, err = socket.tcp_connect(box.cfg.listen)
                if err == nil then
                    sock:close()
                    error('still ok')
                end
            end)
        end)
    end)
end)

g.after_each(function(cg)
    if cg.server ~= nil then
        cg.server:exec(function()
            _G.delay_shutdown = false
            _G.delay_shutdown_cond:signal()
        end)
        delay_shutdown = false
        delay_shutdown_cond:signal()
        cg.server:drop()
    end
end)

-- Delay shutdown of connection to server so that we can continue to send
-- commands to server after server shutdown started.
local function delay_server_connection_shutdown(server)
    delay_shutdown = true
    server.net_box:on_shutdown(function()
        while delay_shutdown do
            delay_shutdown_cond:wait()
        end
    end)
end

-- Test changing iproto listen after iproto shutdown is started.
g.test_iproto_listen_after_shutdown_started = function(cg)
    delay_server_connection_shutdown(cg.server)
    cg.server:exec(function()
        local fiber = require('fiber')
        local net = require('net.box')
        local fio = require('fio')
        box.ctl.set_on_shutdown_timeout(10000)
        box.ctl.on_shutdown(_G.delay_shutdown)
        fiber.new(function()
            os.exit()
        end)
        _G.wait_iproto_shutdown()
        local path = fio.pathjoin(fio.cwd(), 'another.sock')
        box.cfg{listen = path}
        -- Server will listen on given URL but will not accept new connection
        -- and will not send greeting etc.
        local conn = net.connect(box.cfg.listen, {connect_timeout = 3})
        t.assert_equals(conn.state, 'error')
        t.assert_str_contains(conn.error, 'timed out')
        conn:close()
    end)
end

-- Test creating new session after iproto shutdown is started.
g.test_box_session_new_after_shutdown_started = function(cg)
    delay_server_connection_shutdown(cg.server)
    cg.server:exec(function()
        local fiber = require('fiber')
        local net = require('net.box')
        local fio = require('fio')
        local socket = require('socket')
        box.ctl.set_on_shutdown_timeout(10000)
        box.ctl.on_shutdown(_G.delay_shutdown)
        fiber.new(function()
            os.exit()
        end)
        _G.wait_iproto_shutdown()
        local path = fio.pathjoin(fio.cwd(), 'some.sock')
        local session_ret, session_err
        local function handler(sock)
            session_ret, session_err = pcall(box.session.new, {fd = sock:fd()})
            if session_ret then
                sock:detach()
            else
                sock:close()
            end
        end
        local server = socket.tcp_server('unix/', path, handler)
        local conn = net.connect(path)
        t.assert_equals(conn.state, 'error')
        t.assert_str_contains(conn.error,
                              'unexpected EOF when reading from socket')
        t.assert_equals(session_ret, false)
        t.assert_str_contains(session_err:unpack().type, 'ClientError')
        t.assert_str_contains(session_err:unpack().message,
                              'Server is shutting down')
        conn:close()
        server:close()
    end)
end

local g_snap = t.group('snapshot')

g_snap.before_each(function(cg)
    cg.server = server:new()
    cg.server:start()
end)

g_snap.after_each(function(cg)
    if cg.server ~= nil then
        cg.server:drop()
    end
end)

local function test_no_hang_on_shutdown(server)
    local channel = fiber.channel()
    fiber.create(function()
        server:stop()
        channel:put('finished')
    end)
    t.assert(channel:get(60) ~= nil)
end

-- Test shutdown does not hang due to memtx space snapshot in progress.
g_snap.test_shutdown_during_memtx_snapshot = function(cg)
    t.tarantool.skip_if_not_debug()
    cg.server:exec(function()
        local fiber = require('fiber')
        box.schema.create_space('test')
        box.space.test:create_index('pk')
        box.begin()
        for i=1,10000 do
            box.space.test:insert{i}
        end
        box.commit()
        box.error.injection.set('ERRINJ_SNAP_WRITE_TIMEOUT', 0.01)
        fiber.create(function()
            box.snapshot()
        end)
    end)
    t.helpers.retrying({}, function()
        t.assert(cg.server:grep_log('saving snapshot'))
    end)
    -- Make random delay to check we are able to shutdown
    -- with snapshot in progress at any time.
    fiber.sleep(math.random() * 3)
    test_no_hang_on_shutdown(cg.server)
end

local g_standby = t.group('hot standby')

g_standby.before_each(function(cg)
    cg.main = server:new()
    cg.main:start()
    cg.standby = server:new({
        workdir = cg.main.workdir,
        box_cfg = {hot_standby = true},
    })
    cg.standby:start({wait_until_ready = false})
end)

g_standby.after_each(function(cg)
    if cg.main ~= nil then
        cg.main:drop()
    end
    if cg.standby ~= nil then
        cg.standby:drop()
    end
end)

-- Test shutdown does not hang if server is in hot standby mode.
g_standby.test_shutdown_during_hot_standby = function(cg)
    local log = fio.pathjoin(cg.standby.workdir, cg.standby.alias .. '.log')
    t.helpers.retrying({}, function()
        local standby_msg = 'Entering hot standby mode'
        -- Cannot query log path as server is not listen in hot standby mode.
        t.assert(cg.standby:grep_log(standby_msg, nil, {filename = log}))
    end)
    test_no_hang_on_shutdown(cg.standby)
end

local g_vinyl = t.group('vinyl')

g_vinyl.before_each(function(cg)
    cg.server = server:new()
    cg.server:start()
end)

g_vinyl.after_each(function(cg)
    if cg.server ~= nil then
        cg.server:drop()
    end
end)

-- Test we interrupt wait on vinyl dump caused by index creation.
-- Case 1. No snapshot is in progress.
g_vinyl.test_shutdown_vinyl_dump = function(cg)
    t.tarantool.skip_if_not_debug()
    cg.server:exec(function()
        local fiber = require('fiber')
        box.schema.create_space('test', {engine = 'vinyl'})
        box.space.test:create_index('pk')
        box.begin()
        for i=1,10000 do
            box.space.test:insert{i, i}
        end
        box.commit()
        box.error.injection.set('ERRINJ_VY_RUN_WRITE_STMT_TIMEOUT', 0.01)
        fiber.new(function()
            box.space.test:create_index('sk', {parts = {2}})
        end)
    end)
    -- There are other yields before dump on vinyl index creation.
    t.helpers.retrying({}, function()
        t.assert(cg.server:grep_log('dump started'))
    end)
    test_no_hang_on_shutdown(cg.server)
end

-- Test we interrupt wait on vinyl dump caused by index creation.
-- Case 2. Snapshot is in progress.
g_vinyl.test_shutdown_vinyl_dump_during_snapshot = function(cg)
    t.tarantool.skip_if_not_debug()
    cg.server:exec(function()
        local fiber = require('fiber')
        box.schema.create_space('test', {engine = 'vinyl'})
        box.space.test:create_index('pk')
        box.begin()
        for i=1,10000 do
            box.space.test:insert{i, i}
        end
        box.commit()
        box.error.injection.set('ERRINJ_VY_RUN_WRITE_STMT_TIMEOUT', 0.01)
        fiber.new(function()
            box.snapshot()
        end)
    end)
    t.helpers.retrying({}, function()
        t.assert(cg.server:grep_log('vinyl checkpoint started'))
    end)
    cg.server:exec(function()
        local fiber = require('fiber')
        fiber.new(function()
            box.space.test:create_index('sk', {parts = {2}})
        end)
    end)
    -- Sleep to pass building index and reach sleep in dump on waiting
    -- checkpoint to finish. If we fail to pass index code we will
    -- be able to pass the test as index building loop is cancellable.
    -- Yet this test is not aimed to test the cancellability of index
    -- building loop.
    fiber.sleep(3)
    test_no_hang_on_shutdown(cg.server)
end

-- Test we interrupt loop on vinyl index creation.
g_vinyl.test_shutdown_vinyl_index_build = function(cg)
    t.tarantool.skip_if_not_debug()
    cg.server:exec(function()
        local fiber = require('fiber')
        box.schema.create_space('test', {engine = 'vinyl'})
        box.space.test:create_index('pk')
        box.begin()
        for i=1,10000 do
            box.space.test:insert{i, i}
        end
        box.commit()
        box.error.injection.set('ERRINJ_BUILD_INDEX_TIMEOUT', 0.01)
        fiber.new(function()
            box.space.test:create_index('sk', {parts = {2}})
        end)
    end)
    test_no_hang_on_shutdown(cg.server)
end

-- Luatest server currently does not allow to check process exit code.
local g_crash = t.group('crash')

g_crash.before_each(function(cg)
    local id = ('%s-%s'):format('server', utils.generate_id())
    cg.workdir = fio.pathjoin(server.vardir, id)
    fio.mkdir(cg.workdir)
end)

g_crash.after_each(function(cg)
    if cg.handle ~= nil then
        cg.handle:close()
    end
    cg.handle = nil
end)

local tarantool = arg[-1]

-- Test shutdown does not hang due to memtx space snapshot in progress.
g_crash.test_shutdown_during_snapshot_on_signal = function(cg)
    t.tarantool.skip_if_not_debug()
    local script = [[
        local fiber = require('fiber')
        local fio = require('fio')

        local workdir = os.getenv('TARANTOOL_WORKDIR')
        fio.chdir(workdir)
        local log = fio.pathjoin(workdir, 'server.log')
        box.cfg{log = log}
        box.schema.create_space('test')
        box.space.test:create_index('pk')
        box.begin()
        for i=1,10000 do
            box.space.test:insert{i}
        end
        box.commit()
        box.error.injection.set('ERRINJ_SNAP_WRITE_TIMEOUT', 0.01)
        print('ready')
        io.stdout:flush()
    ]]
    local handle, err = popen.new({tarantool, '-e', script},
                                   {stdin = popen.opts.DEVNULL,
                                    stdout = popen.opts.PIPE,
                                    stderr = popen.opts.DEVNULL,
                                    env = {TARANTOOL_WORKDIR = cg.workdir}})
    assert(handle, err)
    cg.handle = handle
    local output, err = handle:read({timeout = 3})
    assert(output, err)
    t.assert_equals(output, "ready\n")
    local log = fio.pathjoin(cg.workdir, 'server.log')
    -- To drop first 'saving snapshot' entry.
    assert(fio.truncate(log))
    -- Start snapshot using signal.
    assert(handle:signal(popen.signal.SIGUSR1))
    t.helpers.retrying({}, function()
        t.assert(server.grep_log(nil, 'saving snapshot', nil, {filename = log}))
    end)
    assert(handle:signal(popen.signal.SIGTERM))
    local status = handle:wait()
    t.assert_equals(status.state, 'exited')
    t.assert_equals(status.exit_code, 0)
end
