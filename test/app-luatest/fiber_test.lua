local fiber = require('fiber')
local t = require('luatest')
local server = require('luatest.server')

local g = t.group('fiber')

g.before_all(function(cg)
    cg.server = server:new()
    cg.server:start()
end)

g.after_all(function(cg)
    if cg.server ~= nil then
        cg.server:drop()
    end
end)

-- Test __serialize metamethod of the fiber.
g.test_serialize = function()
    local f = fiber.new(function() end)
    local fid = f:id()
    f:name('test fiber')

    -- Serialize a ready fiber.
    t.assert_equals(f:__serialize(),
                    { id = fid, name = 'test fiber', status = 'suspended' })

    -- gh-4265: Serializing a finished fiber should not raise an error.
    fiber.yield()
    t.assert_equals(f:__serialize(), { id = fid, status = 'dead' })

    -- Serialize a running fiber.
    t.assert_equals(fiber.self():__serialize(),
                    { id = fiber.self():id(),
                      name = 'luatest',
                      status = 'running' })
end

-- Test __tostring metamethod of the fiber.
g.test_tostring = function()
    local f = fiber.new(function() end)
    local fid = f:id()

    t.assert_equals(tostring(f), "fiber: " .. fid)

    -- gh-4265: Printing a finished fiber should not raise an error.
    fiber.yield()
    t.assert_equals(tostring(f), "fiber: " .. fid .. " (dead)")
end

g.test_gh_9406_shutdown_with_lingering_fiber_join = function()
    local script = [[
        local fiber = require('fiber')

        local f = nil
        fiber.create(function()
            while f == nil do
                fiber.sleep(0.1)
            end
            fiber.join(f)
        end)
        f = fiber.new(function()
            fiber.sleep(1000)
        end)
        f:set_joinable(true)
        fiber.sleep(0.2)
        os.exit()
    ]]
    local tarantool_bin = arg[-1]
    local cmd = string.format('%s -e "%s"', tarantool_bin, script)
    t.assert(os.execute(cmd) == 0)
end

g.test_gh_10187_no_memory_leak_on_dead_fiber_search = function()
    local f = fiber.new(function() end)
    f:set_joinable(true)
    f:wakeup()
    fiber.yield()
    local x = fiber.find(f:id())
    -- Check found the fiber object is the same as the one created after the
    -- fiber became dead.
    t.assert_equals(x, f)
    -- Check we cannot access dead fiber storage.
    t.assert_error_covers({
        type = 'IllegalParams',
        message = 'the fiber is dead',
    }, x.__index, x, 'storage')
    -- Check fiber object is GC after fiber is joined.
    local weak_table = setmetatable({}, {__mode = 'v'})
    weak_table.fiber = f
    x:join()
    f = nil -- luacheck: no unused
    x = nil -- luacheck: no unused
    collectgarbage()
    t.assert_equals(weak_table.fiber, nil)
end

g.test_gh_10196_no_hang_on_self_join = function()
    local f = fiber.new(function()
        fiber.self():join()
    end)
    f:set_joinable(true)
    f:wakeup()
    fiber.yield()
    local ok, res = f:join()
    t.assert_not(ok)
    t.assert_covers(res:unpack(), {
        type = 'IllegalParams',
        message = 'cannot join itself',
    })
end

g.test_fiber_set_system = function()
    local f = fiber.create(function()
        while true do
            fiber.yield()
        end
    end)
    fiber._internal.set_system(f, true)
    -- This one should be ignored.
    f:cancel()
    fiber.yield()
    t.assert_not_equals(f:status(), 'dead')
    fiber._internal.set_system(f, false)
    -- This one should work.
    f:cancel()
    fiber.yield()
    t.assert_equals(f:status(), 'dead')
end

g.test_fiber_stall_is_cancellable = function()
    local f = fiber.create(function()
        while true do
            fiber._internal.stall()
        end
    end)
    t.assert_not_equals(f:status(), 'dead')
    f:cancel()
    fiber.yield()
    t.assert_equals(f:status(), 'dead')
end

g.test_worker_fiber_shutdown = function(cg)
    cg.server:exec(function()
        local fiber = require('fiber')

        t.assert_equals(fiber._internal.is_shutdown, false)
        local executed = {}
        local ch = fiber.channel()
        fiber._internal.schedule_task(function()
            t:assert(ch:get(30))
            table.insert(executed, 1)
        end)
        fiber._internal.schedule_task(function()
            table.insert(executed, 2)
        end)
        fiber._internal.schedule_task(function()
            fiber._internal.schedule_task(function()
                table.insert(executed, 4)
            end)
            table.insert(executed, 3)
        end)
        fiber.yield()
        t.assert(ch:put(true, 30))
        fiber._internal.worker_shutdown()
        -- Make sure all tasks are executed. Tasks scheduled before shutdown
        -- are executed in order. Tasks scheduled during shutdown are executed
        -- out of order.
        t.assert_equals(executed, {1, 2, 4, 3})
        t.assert_equals(fiber._internal.is_shutdown, true)
    end)
end
