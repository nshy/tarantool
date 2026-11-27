local socket = require('socket')
local fio = require('fio')
local json = require('json')
local treegen = require('luatest.treegen')
local justrun = require('luatest.justrun')
local server = require('luatest.server')
local t = require('luatest')

local g1 = t.group('initial_box_cfg')

local VARDIR = fio.abspath(os.getenv('VARDIR') or 'test/var')
local SOCK_PATH = fio.pathjoin(VARDIR, 'syslog.sock')

-- The priority is composed of the default facility (local7)
-- and the warn level.
local PRIORITY_WARN = 188

local function bind_socket()
    local sock = socket('AF_UNIX', 'SOCK_DGRAM', 0)
    t.assert(sock)
    fio.unlink(SOCK_PATH)
    t.assert(sock:bind('unix/', SOCK_PATH))
    return sock
end

local function read_log(sock)
    return sock:recv(16 * 1024)
end

local function log_pattern_5424(priority, syslog_timezone, identity, pid,
                                message)
    local tz_pattern = syslog_timezone == 'utc' and 'Z' or '%+%d%d:%d%d'
    local datetime_pattern = '%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d%.%d%d%d'
    return string.format('^<%d>1 %s%s %s %s %s %%- %%- main/.* %%a> %s$',
                priority, datetime_pattern, tz_pattern, box.info.hostname,
                identity, pid or '%d+', message)
end

local function log_pattern_3164 (priority, identity, pid, message)
    local datetime_pattern = '%a+ %d%d %d%d:%d%d:%d%d'
    return string.format('^<%d>%s %s%%[%s%%]: main/.* W> %s$',
                         priority, datetime_pattern, identity, pid or '%d+',
                         message)
end

g1.before_all(function(cg)
    cg.sock = bind_socket()
end)

g1.after_all(function(cg)
    cg.sock:close()
    fio.unlink(SOCK_PATH)
end)

g1.test_initial_cfg_invalid = function()
    treegen.add_template('^box_cfg_invalid%.lua$', [[
        local json = require('json')
        box.cfg(json.decode('<cfg>'))
        os.exit(0)
    ]])
    treegen.add_template('^log_cfg_invalid%.lua$', [[
        local log = require('log')
        local json = require('json')
        log.cfg(json.decode('<cfg>'))
        os.exit(0)
    ]])

    local function check(template, params)
        local dir = treegen.prepare_directory(
                        {template}, {cfg = json.encode(params.cfg)})
        local result = justrun.tarantool(dir, {}, {template},
                                         {nojson = true, stderr = true})
        t.assert_not_equals(result.exit_code, 0)
        t.assert_str_contains(result.stderr, params.error_msg)
    end

    local function check_template(template)
        check(template, {
            cfg = {syslog_format = 0},
            error_msg = "Incorrect value for option 'syslog_format': " ..
                        "should be of type string",
        })
        check(template, {
            cfg = {syslog_format = 'foo'},
            error_msg = "Incorrect value for option 'syslog_format': " ..
                        "expected rfc5424,rfc3164",
        })
        check(template, {
            cfg = {syslog_timezone = 0},
            error_msg = "Incorrect value for option 'syslog_timezone': " ..
                        "should be of type string",
        })
        check(template, {
            cfg = {syslog_timezone = 'bar'},
            error_msg = "Incorrect value for option 'syslog_timezone': " ..
                        "expected utc,local",
        })
    end

    check_template('box_cfg_invalid.lua')
    check_template('log_cfg_invalid.lua')
end


g1.test_initial_cfg = function(cg)
    treegen.add_template('^log_cfg%.lua$', [[
        local log = require('log')
        local json = require('json')

        local cfg = json.decode('<cfg>')
        log.cfg(cfg)

        print(json.encode(log.cfg))
        log.warn('xxx')

        os.exit(0)
    ]])
    treegen.add_template('^box_cfg%.lua$', [[
        local log = require('log')
        local json = require('json')

        local cfg = json.decode('<cfg>')
        box.cfg(cfg)

        print(json.encode(box.cfg))
        log.warn('xxx')

        os.exit(0)
    ]])

    local function check(template, cfg)
        local cfg = {
            log = string.format('syslog:server=unix:%s,identity=tt', SOCK_PATH),
            syslog_format = cfg.syslog_format,
            syslog_timezone = cfg.syslog_timezone,
        }
        cfg[template == 'box_cfg.lua' and 'log_level' or 'level'] = 'warn'
        local dir = treegen.prepare_directory({template},
                                              {cfg = json.encode(cfg)})
        local result = justrun.tarantool(dir, {}, {template}, {stderr = true})
        t.assert_equals(result.exit_code, 0, result.stderr)

        local syslog_format = cfg.syslog_format or 'rfc3164'
        local syslog_timezone = cfg.syslog_timezone or 'utc'
        t.assert_covers(result.stdout, {{
            syslog_format = syslog_format,
            syslog_timezone = syslog_timezone,
        }})
        if syslog_format == 'rfc5424' then
            local pattern = log_pattern_5424(PRIORITY_WARN, syslog_timezone,
                                             'tt', nil, 'xxx')
            t.assert_str_matches(read_log(cg.sock), pattern)
        else
            t.assert_equals(syslog_format, 'rfc3164')
            local pattern = log_pattern_3164(PRIORITY_WARN, 'tt', nil, 'xxx')
            t.assert_str_matches(read_log(cg.sock), pattern)
        end
    end

    local function check_template(template)
        check(template, {})
        check(template, {syslog_format = 'rfc3164'})
        check(template, {syslog_format = 'rfc5424'})
        check(template, {syslog_format = 'rfc5424', syslog_timezone = 'utc'})
        check(template, {syslog_format = 'rfc5424', syslog_timezone = 'local'})
    end

    check_template('box_cfg.lua')
    check_template('log_cfg.lua')
end

local g2 = t.group('indentity', {{}, {identity = 'my_identity'}})

g2.before_all(function(cg)
    cg.sock = bind_socket()
    local log = string.format('syslog:server=unix:%s', SOCK_PATH)
    if cg.params.identity then
        log = log .. string.format(',identity=%s', cg.params.identity)
    end
    cg.server = server:new({
        box_cfg = {
            log = log,
            log_level = 'warn',
            syslog_format = 'rfc5424',
        },
    })
    cg.server:start()
end)

g2.after_all(function(cg)
    cg.server:drop()
    cg.sock:close()
    fio.unlink(SOCK_PATH)
end)

g2.test_identity = function(cg)
    cg.server:exec(function()
        require('log').warn('xxx')
    end)
    local identity = cg.params.identity or 'tarantool'
    local pattern = log_pattern_5424(PRIORITY_WARN, 'utc', identity,
                                     cg.server.process.pid, 'xxx')
    t.assert_str_matches(read_log(cg.sock), pattern)
    cg.server:exec(function()
        box.cfg{instance_name = 'my_name'}
    end)
    cg.server:exec(function()
        require('log').warn('xxx')
    end)
    local identity = cg.params.identity or 'my_name'
    local pattern = log_pattern_5424(PRIORITY_WARN, 'utc', identity,
                                     cg.server.process.pid, 'xxx')
end

local g3 = t.group('priority', {{}, {facility = 'daemon'}})

g3.before_all(function(cg)
    cg.sock = bind_socket()
    local log = string.format('syslog:server=unix:%s', SOCK_PATH)
    if cg.params.facility then
        log = log .. string.format(',facility=%s', cg.params.facility)
    end
    cg.server = server:new({
        box_cfg = {
            log = log,
            log_level = 'warn',
            syslog_format = 'rfc5424',
        },
    })
    cg.server:start()
end)

g3.after_all(function(cg)
    cg.server:drop()
    cg.sock:close()
    fio.unlink(SOCK_PATH)
end)

g3.test_priority = function(cg)
    cg.server:exec(function()
        require('log').warn('xxx')
    end)
    local priority = cg.params.facility and 28 or PRIORITY_WARN
    local pattern = log_pattern_5424(priority, 'utc', 'tarantool',
                                     cg.server.process.pid, 'xxx')
    t.assert_str_matches(read_log(cg.sock), pattern)
    cg.server:exec(function()
        require('log').error('xxx')
    end)
    local priority = cg.params.facility and 27 or 187
    local pattern = log_pattern_5424(priority, 'utc', 'tarantool',
                                     cg.server.process.pid, 'xxx')
    t.assert_str_matches(read_log(cg.sock), pattern)
end

local g4 = t.group('dynamic')

g4.before_all(function(cg)
    cg.sock = bind_socket()
    cg.server = server:new({
        box_cfg = {
            log = string.format('syslog:server=unix:%s,identity=tt', SOCK_PATH),
            log_level = 'warn',
        },
    })
    cg.server:start()
end)

g4.after_all(function(cg)
    cg.server:drop()
    cg.sock:close()
    fio.unlink(SOCK_PATH)
end)

g4.test_test_cfg_dynamic = function(cg)
    local function check_configure(cfg, options)
        cfg = cg.server:exec(function(cfg, options)
            local log = require('log')

            if options.box_cfg then
                box.cfg(cfg)
            end
            if options.log_cfg then
                log.cfg(cfg)
            end

            t.assert_covers(box.cfg, cfg)
            t.assert_covers(log.cfg, cfg)

            log.warn('xxx')
            return box.cfg
        end, {cfg, options})
        if cfg.syslog_format == 'rfc5424' then
            local pattern = log_pattern_5424(PRIORITY_WARN, cfg.syslog_timezone,
                                             'tt', nil, 'xxx')
            t.assert_str_matches(read_log(cg.sock), pattern)
        else
            t.assert_equals(cfg.syslog_format, 'rfc3164')
            local pattern = log_pattern_3164(PRIORITY_WARN, 'tt', nil, 'xxx')
            t.assert_str_matches(read_log(cg.sock), pattern)
        end
    end

    local function check(options)
        check_configure({syslog_format = 'rfc5424'}, options)
        check_configure({syslog_format = 'rfc3164'}, options)
        check_configure({syslog_format = 'rfc5424'}, options)

        check_configure({syslog_timezone = 'local'}, options)
        check_configure({syslog_timezone = 'utc'}, options)
        check_configure({syslog_timezone = 'local'}, options)
    end

    check({box_cfg = true})
    check({log_cfg = true})
end
