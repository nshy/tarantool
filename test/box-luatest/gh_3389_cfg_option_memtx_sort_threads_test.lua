local server = require('luatest.server')
local t = require('luatest')

local g = t.group()

g.before_all(function(cg)
    -- test setting memtx_sort_threads to non default value
    cg.server = server:new{box_cfg = {memtx_sort_threads = 3}}
    cg.server:start()
end)

g.after_all(function(cg)
    cg.server:drop()
end)

g.test_memtx_index = function(cg)
    cg.server:exec(function()
        t.assert_error_msg_equals(
            "Can't set option 'memtx_sort_threads' dynamically",
            box.cfg, {memtx_sort_threads = 5})
    end)
end
