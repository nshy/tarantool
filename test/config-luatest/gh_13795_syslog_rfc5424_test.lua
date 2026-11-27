local fio = require('fio')
local socket = require('socket')
local t = require('luatest')
local cbuilder = require('luatest.cbuilder')
local cluster = require('luatest.cluster')

-- Verify the syslog configuration options of the declarative
-- configuration: log.syslog.format and log.syslog.timezone
-- (gh-13795).

local VARDIR = fio.abspath(os.getenv('VARDIR') or 'test/var')
local SOCK_PATH = fio.pathjoin(VARDIR, 'gh_13795_syslog.sock')

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

local function log_pattern_5424(timezone, identity, pid, message)
    local tz_pattern = timezone == 'utc' and 'Z' or '%+%d%d:%d%d'
    local datetime_pattern = '%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d%.%d%d%d'
    return string.format('^<%d>1 %s%s %s %s %s %%- %%- main/.* %%a> %s$',
                         PRIORITY_WARN, datetime_pattern, tz_pattern,
                         box.info.hostname, identity, pid or '%d+', message)
end

local function log_pattern_3164(identity, pid, message)
    local datetime_pattern = '%a+ %d%d %d%d:%d%d:%d%d'
    return string.format('^<%d>%s %s%%[%s%%]: main/.* %%a> %s$',
                         PRIORITY_WARN, datetime_pattern, identity,
                         pid or '%d+', message)
end

local function check_log(sock, format, timezone, identity, message)
    local log = read_log(sock)
    if format == 'rfc5424' then
        local pattern = log_pattern_5424(timezone, identity, nil, message)
        t.assert_str_matches(log, pattern)
    else
        assert(format == 'rfc3164')
        local pattern = log_pattern_3164(identity, nil, message)
        t.assert_str_matches(log, pattern)
    end
end

local function make_config(params)
    local builder = cbuilder:new()
        :add_instance('i-001', {})
        :set_global_option('log.to', 'syslog')
        :set_global_option('log.syslog.server', ('unix:%s'):format(SOCK_PATH))
        :set_global_option('log.syslog.identity', 'tt')
        :set_global_option('log.level', 'warn')
    if params.format ~= nil then
        builder = builder:set_global_option('log.syslog.format',
                                            params.format)
    end
    if params.timezone ~= nil then
        builder = builder:set_global_option('log.syslog.timezone',
                                            params.timezone)
    end
    return builder:config()
end

local g1 = t.group('initial_cfg', {
    {},
    {format = 'rfc3164'},
    {format = 'rfc5424'},
    {format = 'rfc5424', timezone = 'utc'},
    {format = 'rfc5424', timezone = 'local'},
})

g1.before_all(function(cg)
    cg.sock = bind_socket()
    cg.cluster = cluster:new(make_config(cg.params))
    cg.cluster:start()
end)

g1.after_all(function(cg)
    cg.cluster:drop()
    cg.sock:close()
    fio.unlink(SOCK_PATH)
end)

g1.test_log = function(cg)
    local format = cg.params.format or 'rfc3164'
    local timezone = cg.params.timezone or 'utc'
    cg.cluster['i-001']:exec(function(format, timezone)
        local config = require('config')
        t.assert_equals(config:get('log.syslog.format'), format)
        t.assert_equals(config:get('log.syslog.timezone'), timezone)
    end, {format, timezone})

    cg.cluster['i-001']:exec(function()
        require('log').warn('xxx')
    end)
    check_log(cg.sock, format, timezone, 'tt', 'xxx')
end

local g2 = t.group('reload')

g2.before_all(function(cg)
    cg.sock = bind_socket()
    cg.cluster = cluster:new(make_config({}))
    cg.cluster:start()
end)

g2.after_all(function(cg)
    cg.cluster:drop()
    cg.sock:close()
    fio.unlink(SOCK_PATH)
end)

g2.test_log = function(cg)
    local function check(params)
        cg.cluster:reload(make_config(params))
        local cfg = cg.cluster['i-001']:exec(function()
            require('log').warn('xxx')
            return require('config'):get('log.syslog')
        end)
        check_log(cg.sock, cfg.format, cfg.timezone, 'tt', 'xxx')
    end

    check({format = 'rfc5424'})
    check({format = 'rfc3164'})
    check({format = 'rfc5424'})

    check({timezone = 'local'})
    check({timezone = 'utc'})
    check({timezone = 'local'})
end
