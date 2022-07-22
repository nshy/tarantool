-- log.lua
--
local ffi = require('ffi')
local trigger = require('internal.trigger')

ffi.cdef[[
    typedef void (*sayfunc_t)(int level, const char *filename, int line,
               const char *error, const char *format, ...);

    enum say_logger_type {
        SAY_LOGGER_BOOT,
        SAY_LOGGER_STDERR,
        SAY_LOGGER_FILE,
        SAY_LOGGER_PIPE,
        SAY_LOGGER_SYSLOG
    };

    enum say_logger_type
    log_type();

    void
    say_set_log_level(int new_level);

    void
    say_set_log_format(enum say_format format);

    extern void
    say_logger_init(const char *init_str, int level, int nonblock,
                    const char *format, int background);

    extern bool
    say_logger_initialized(void);

    extern sayfunc_t _say;
    extern struct ev_loop;
    extern struct ev_signal;

    extern void
    say_logrotate(struct ev_loop *, struct ev_signal *, int);

    enum say_level {
        S_FATAL,
        S_SYSERROR,
        S_ERROR,
        S_CRIT,
        S_WARN,
        S_INFO,
        S_VERBOSE,
        S_DEBUG
    };

    enum say_format {
        SF_PLAIN,
        SF_JSON
    };
    pid_t log_pid;
    extern int log_level;
    extern int log_format;
]]

local log
local on_update = trigger.new('on_update')

local S_CRIT = ffi.C.S_CRIT
local S_WARN = ffi.C.S_WARN
local S_INFO = ffi.C.S_INFO
local S_VERBOSE = ffi.C.S_VERBOSE
local S_DEBUG = ffi.C.S_DEBUG
local S_ERROR = ffi.C.S_ERROR

local json = require("json").new()
json.cfg{
    encode_invalid_numbers = true,
    encode_load_metatables = true,
    encode_use_tostring    = true,
    encode_invalid_as_nil  = true,
}

local special_fields = {
    "file",
    "level",
    "pid",
    "line",
    "cord_name",
    "fiber_name",
    "fiber_id",
    "error_msg"
}

-- Map format number to string.
local fmt_num2str = {
    [ffi.C.SF_PLAIN]    = "plain",
    [ffi.C.SF_JSON]     = "json",
}

-- Map format string to number.
local fmt_str2num = {
    ["plain"]           = ffi.C.SF_PLAIN,
    ["json"]            = ffi.C.SF_JSON,
}

local function fmt_list()
    local keyset = {}
    for k in pairs(fmt_str2num) do
        keyset[#keyset + 1] = k
    end
    return table.concat(keyset, ',')
end

-- Logging levels symbolic representation.
local log_level_keys = {
    ['fatal']       = ffi.C.S_FATAL,
    ['syserror']    = ffi.C.S_SYSERROR,
    ['error']       = ffi.C.S_ERROR,
    ['crit']        = ffi.C.S_CRIT,
    ['warn']        = ffi.C.S_WARN,
    ['info']        = ffi.C.S_INFO,
    ['verbose']     = ffi.C.S_VERBOSE,
    ['debug']       = ffi.C.S_DEBUG,
}

local function log_level_list()
    local keyset = {}
    for k in pairs(log_level_keys) do
        keyset[#keyset + 1] = k
    end
    return table.concat(keyset, ',')
end

-- Default options. The keys are part of
-- user API , so change with caution.
local log_cfg = {
    log             = nil,
    nonblock        = nil,
    level           = S_INFO,
    format          = fmt_num2str[ffi.C.SF_PLAIN],
}

local LOG_OPTIONS = {
    'log',
    'format',
    'level',
    'nonblock',
}

local function check_format(format)
    if fmt_str2num[format] == nil then
        box.error(box.error.CFG, 'log format',
                  ("should be one of '%s'"):format(fmt_list()))
    end
end

local function check_level(level)
    if type(level) == 'string' then
        level = log_level_keys[level]
        if level == nil then
            box.error(box.error.CFG, 'log level',
                      ("should be one of '%s'"):format(log_level_list()))
        end
    elseif type(level) ~= 'number' then
        box.error(box.error.CFG, 'log level', 'must be a number or a string')
    end

    -- a number may be any for backward compatibility
    return level
end

-- Main routine which pass data to C logging code.
local function say(level, fmt, ...)
    if ffi.C.log_level < level then
        -- don't waste cycles on debug.getinfo()
        return
    end
    local type_fmt = type(fmt)
    local format = "%s"
    if select('#', ...) ~= 0 then
        local stat
        stat, fmt = pcall(string.format, fmt, ...)
        if not stat then
            error(fmt, 3)
        end
    elseif type_fmt == 'table' then
        -- ignore internal keys
        for _, field in ipairs(special_fields) do
            fmt[field] = nil
        end
        fmt = json.encode(fmt)
        if ffi.C.log_format == ffi.C.SF_JSON then
            -- indicate that message is already encoded in JSON
            format = fmt_num2str[ffi.C.SF_JSON]
        end
    elseif type_fmt ~= 'string' then
        fmt = tostring(fmt)
    end

    local debug = require('debug')
    local frame = debug.getinfo(3, "Sl")
    local line, file = 0, 'eval'
    if type(frame) == 'table' then
        line = frame.currentline or 0
        file = frame.short_src or frame.src or 'eval'
    end

    ffi.C._say(level, file, line, nil, format, fmt)
end

-- Just a syntactic sugar over say routine.
local function say_closure(lvl)
    return function (fmt, ...)
        say(lvl, fmt, ...)
    end
end

-- Rotate log (basically reopen the log file and
-- start writting into it).
local function log_rotate()
    ffi.C.say_logrotate(nil, nil, 0)
end

local function log_level(level)
    level = check_level(level)

    ffi.C.say_set_log_level(level)
    log_cfg.level = level
    on_update:run('level')

    log.debug(('log: level set to %s'):format(level))
end

local function log_format(format)
    check_format(format)

    if ffi.C.log_type() == ffi.C.SAY_LOGGER_SYSLOG and format == 'json' then
        box.error(box.error.CFG, 'log format',
                  "'json' can't be used with syslog logger")
    end

    local cformat = format == 'json' and ffi.C.SF_JSON or ffi.C.SF_PLAIN
    ffi.C.say_set_log_format(cformat)
    log_cfg.format = format
    on_update:run('format')

    log.debug(("log: format set to '%s'"):format(format))
end

-- Returns pid of a pipe process.
local function log_pid()
    return tonumber(ffi.C.log_pid)
end

local ratelimit_enabled = true

local function ratelimit_enable()
    ratelimit_enabled = true
end

local function ratelimit_disable()
    ratelimit_enabled = false
end

local Ratelimit = {
    interval = 60,
    burst = 10,
    emitted = 0,
    suppressed = 0,
    start = 0,
}

local function ratelimit_new(object)
    return Ratelimit:new(object)
end

function Ratelimit:new(object)
    object = object or {}
    setmetatable(object, self)
    self.__index = self
    return object
end

function Ratelimit:check()
    if not ratelimit_enabled then
        return 0, true
    end

    local clock = require('clock')
    local now = clock.monotonic()
    local saved_suppressed = 0
    if now > self.start + self.interval then
        saved_suppressed = self.suppressed
        self.suppressed = 0
        self.emitted = 0
        self.start = now
    end

    if self.emitted < self.burst then
        self.emitted = self.emitted + 1
        return saved_suppressed, true
    end
    self.suppressed = self.suppressed + 1
    return saved_suppressed, false
end

function Ratelimit:log_check(lvl)
    local suppressed, ok = self:check()
    if lvl >= S_WARN and suppressed > 0 then
        say(S_WARN, '%d messages suppressed due to rate limiting', suppressed)
    end
    return ok
end

function Ratelimit:log(lvl, fmt, ...)
    if self:log_check(lvl) then
        say(lvl, fmt, ...)
    end
end

local function log_ratelimited_closure(lvl)
    return function(self, fmt, ...)
        self:log(lvl, fmt, ...)
    end
end

Ratelimit.log_crit = log_ratelimited_closure(S_CRIT)

-- Reload dynamic options.
local function reload_cfg(cfg)
    if cfg.level ~= nil then
        ffi.C.say_set_log_level(cfg.level)
        log_cfg.level = cfg.level
    end

    if cfg.format ~= nil then
        local format = cfg.format == 'json' and ffi.C.SF_JSON or ffi.C.SF_PLAIN
        ffi.C.say_set_log_format(format)
        log_cfg.format = cfg.format
    end

    on_update:run()
end

-- Checks that @cfg is correct. It also makes conversions to be used
-- in load_cfg() call.
local function check_cfg(cfg)
    if ffi.C.say_logger_initialized() == true then
        for _, k in ipairs{'log', 'nonblock'} do
            if cfg[k] ~= nil and log_cfg[k] ~= cfg[k] then
                box.error(box.error.RELOAD_CFG, k)
            end
        end
    end

    if cfg.log ~= nil then
        if type(cfg.log) == 'string' then
            if cfg.log == '' then
                cfg.log = nil
            end
        else
            box.error(box.error.cfg, 'log', "should be string")
        end
    end

    if cfg.format ~= nil then
        check_format(cfg.format)
    end

    if cfg.level ~= nil then
        cfg.level = check_level(cfg.level)
    end

    if cfg.nonblock ~= nil then
        if type(cfg.nonblock) ~= 'boolean' then
            box.error(box.error.cfg, 'log nonblock', "must be 'true' or 'false'")
        end
    end

    for _, o in ipairs(LOG_OPTIONS) do
        if cfg[o] == nil then
            cfg[o] = log_cfg[o]
        end
    end

    require('box.internal').log_check(cfg)
end

-- Load or reload configuration via log.cfg({}) call.
local function load_cfg(self, cfg)
    cfg = cfg or {}

    check_cfg(cfg)

    if ffi.C.say_logger_initialized() == true then
        return reload_cfg(cfg)
    end

    ffi.C.say_logger_init(cfg.log, cfg.level,
                          cfg.nonblock and 1 or 0,
                          cfg.format, 0)

    for _, o in ipairs(LOG_OPTIONS) do
        log_cfg[o] = cfg[o]
    end

    log.debug(("log.cfg({log=%s, level=%s,nonblock=%s, format='%s'})"):
              format(cfg.log, cfg.level, cfg.nonblock, cfg.format))
end

local compat_warning_said = false
local compat_v16 = {
    logger_pid = function()
        if not compat_warning_said then
            compat_warning_said = true
            say(S_WARN, 'logger_pid() is deprecated, please use pid() instead')
        end
        return log_pid()
    end;
}

log = {
    warn = say_closure(S_WARN),
    info = say_closure(S_INFO),
    verbose = say_closure(S_VERBOSE),
    debug = say_closure(S_DEBUG),
    error = say_closure(S_ERROR),
    rotate = log_rotate,
    pid = log_pid,
    level = log_level,
    log_format = log_format,
    cfg = setmetatable(log_cfg, {
        __call = load_cfg,
    }),
    internal = {
        ratelimit = {
            new = ratelimit_new,
            enable = ratelimit_enable,
            disable = ratelimit_disable,
        },
        check_cfg = check_cfg,
        on_update = on_update,
    }
}

setmetatable(log, {
    __serialize = function(self)
        local res = table.copy(self)
        return setmetatable(res, {})
    end,
    __index = compat_v16;
})

return log
