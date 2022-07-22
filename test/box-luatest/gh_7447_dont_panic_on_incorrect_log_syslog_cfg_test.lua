local log = require('log')
local t = require('luatest')

local g = t.group()

g.test_dont_panic_on_incorrect_log_syslog_cfg = function()
    t.assert_error_msg_contains("Incorrect value for option 'log'",
                                log.cfg, {log='syslog:xxx'})
end
