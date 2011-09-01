local jit = require("jit")
local bc = require("jit.bc")
local vmdef = require("jit.vmdef")


-- Utilities -------------------------------------------------------------------

-- Stolen from dump.lua
local function fmtfunc(func, pc)
  local fi = jit.util.funcinfo(func, pc)
  if fi.loc then
    return fi.loc
  elseif fi.ffid then
    return vmdef.ffnames[fi.ffid]
  elseif fi.addr then
    return ("C:%x"):format(fi.addr)
  else
    return "(?)"
  end
end


-- Format trace error message.  Stolen from dump.lua
local function fmterr(err, info)
  if type(err) == "number" then
    if type(info) == "function" then info = fmtfunc(info) end
    err = vmdef.traceerr[err]:format(info)
  end
  return err
end


-- Tracing ---------------------------------------------------------------------

local traces = {}

local trace_callbacks = {}

function trace_callbacks.start(tr, func, pc, otr, oex)
  if not traces[tr] then traces[tr] = {} end
  local t = { number=tr, start = jit.util.funcinfo(func, pc), bytecode={} }
  traces[tr][#traces[tr]+1] = t
end


function trace_callbacks.stop(tr)
  local t = traces[tr][#traces[tr]]
  t.status = true
  if t.bytecode[1] then
    t.stop = t.bytecode[#t.bytecode].info
  else
    t.stop = t.start
  end
end


function trace_callbacks.abort(tr, func, pc, code, reason)
  local t = traces[tr][#traces[tr]]
  local reason=fmterr(code, reason)
  reason = reason:gsub("bytecode (%d+)", function(c)
    c = tonumber(c) * 6
    return "bytecode "..vmdef.bcnames:sub(c, c+6):gsub(" ", "")
    end)
  t.abort = { info=jit.util.funcinfo(func, pc), code=code, reason=reason }
  t.stop = t.abort.info
end


local function annotate_trace(what, ...)
  local cb = trace_callbacks[what]
  if cb then cb(...) end
end


-- Somewhat stolen from dump.lua
local function annotate_record(tr, func, pc, depth)
  local prefix = (" ."):rep(depth)
  local t = traces[tr][#traces[tr]]
  local l
  if pc >= 0 then
    l = bc.line(func, pc, prefix):sub(1, -2)
  else
    l = "0000 "..prefix.." FUNCC "..(" "):rep(math.max(5-#prefix, 0))
  end
  if pc <= 0 then
    l = l.."         ; "..fmtfunc(func)
  end
  t.bytecode[#t.bytecode+1] = { pc=pc, bc=l, depth=depth, info=jit.util.funcinfo(func, pc) }
  if pc >= 0 and bit.band(jit.util.funcbc(func, pc), 0xff) < 16 then -- ORDER BC
    t.bytecode[#t.bytecode+1] = { pc=pc, bc=bc.line(func, pc+1, recprefix):sub(1,-2), depth=depth, info=jit.util.funcinfo(func, pc) }
  end
end


-- Reporting functions ---------------------------------------------------------

local function remove_duplicate_traces(traces)
  local trace_map = {}
  local new_traces = {}

  for i, t in ipairs(traces) do
    for j, tr in ipairs(t) do
      -- Our first guess is if the start and end lines are different, then it's
      -- a different trace.
      local name = ("%s:%d-%s:%d"):
        format(tr.start.source, tr.start.currentline, tr.stop.source, tr.stop.currentline)
      tr.name = name
      if not trace_map[name] then
        tr.attempts = 1
        trace_map[name] = { tr }
        new_traces[#new_traces+1] = tr
      else
        -- BUT it might be possible that two traces that start and end in the
        -- same place have different bytecodes if they specialise on different
        -- types, so we have to compare bytecodes
        local same_as_any = false
        for _, tr2 in ipairs(trace_map[name]) do
          local same = #tr.bytecode == #tr2.bytecode
          if #tr.bytecode == #tr2.bytecode then
            for i, b in ipairs(tr.bytecode) do
              if b.bc ~= tr2.bytecode[i].bc then
                same = false
                break
              end
            end
          end
          if same then
            tr2.attempts = tr2.attempts + 1
            same_as_any = true
            break
          end
        end
        if not same_as_any then
          trace_map[name][#trace_map[name]+1] = tr
          new_traces[#new_traces+1] = tr
          tr.attempts = 1
        end
      end
    end
  end

  return new_traces
end


local function load_source_files(traces)
  local source_map = {}

  for i, tr in ipairs(traces) do
    source_map[tr.start.source] = true
    source_map[tr.stop.source] = true
    for k, b in ipairs(tr.bytecode) do
      if b.info.source then
        source_map[b.info.source] = true
      end
    end
  end
  for source in pairs(source_map) do
    filename = source:sub(2,-1)
    local f = io.open(filename, "r")
    if f then
      local lines = {}
      local lc = 0
      for l in f:lines() do
        lc = lc + 1
        lines[lc] = l
      end
      source_map[source] = lines
    else
      source_map[source] = nil
    end
  end
  
  return source_map
end


local function count_trace_results(traces, status_func)
  -- Run through all the traces counting bytecodes and lines by result
  local results, result_map = {}, {}
  for i, tr in ipairs(traces) do
    local linecount, lines = 0, {}
    for k, b in ipairs(tr.bytecode) do
      if b.info.source then
        local l = b.info.source..":"..b.info.currentline
        if not lines[l] then
          linecount = linecount + 1
          lines[l] = true
        end
      end
    end
    local status = status_func(tr)
    if not result_map[status] then
      local r = { status=status, traces=0, bytecodes=0, lines=0 }
      result_map[status] = r
      results[#results+1] = r
    end
    local r = result_map[status]
    r.traces = r.traces + 1
    r.bytecodes = r.bytecodes + #tr.bytecode
    r.lines = r.lines + linecount
    tr.linecount = linecount
  end

  table.sort(results, function(a, b) return a.bytecodes > b.bytecodes end)

  -- Add up the totals
  local total = { traces=0, bytecodes=0, lines=0 }
  for k, r in ipairs(results) do
    total.traces = total.traces + r.traces
    total.bytecodes = total.bytecodes + r.bytecodes
    total.lines = total.lines + r.lines
  end

  return results, result_map, total
end


local function report_summary(file, results, result_map, total)
  local status_length = 0
  for _, r in ipairs(results) do
    status_length = math.max(status_length, #r.status)
  end

  local header_format = "%-"..status_length.."s\t%15s\t%15s\t%15s\n"
  local line_format = "%-"..status_length.."s\t%8d (%3d%%)\t%8d (%3d%%)\t%8d (%3d%%)\n"

  file:write(header_format:format("Trace Status", "Traces", "Bytecodes", "Lines"))
  file:write(header_format:format("------------", "------", "---------", "-----"))
  local function rline1(...)
    file:write(line_format:format(...))
  end
  local function rline2(k, a, b, c)
    rline1(k, a, a / total.traces * 100, b, b / total.bytecodes * 100, c, c / total.lines * 100)
  end
  local function rline3(k)
    local r = result_map[k]
    rline2(k, r.traces, r.bytecodes, r.lines)
  end
  rline3("Success")
  for i, r in ipairs(results) do
    if r.status ~= "Success" then rline3(r.status) end
  end
  local D = "-"
  file:write(header_format:format(D:rep(status_length), D:rep(15), D:rep(15), D:rep(15)))
  rline2("Total", total.traces, total.bytecodes, total.lines)
  D = "="
  file:write(header_format:format(D:rep(status_length), D:rep(15), D:rep(15), D:rep(15)))
  file:write("\n")
end


-- Reporting -------------------------------------------------------------------

local reported, active

local function annotate_report()
  if reported then return end
  reported = true

  -- Turn our callbacks off, otherwise we collect information on annotate_report!
  if active then
    jit.attach(annotate_trace)
    jit.attach(annotate_record)
  end

  traces = remove_duplicate_traces(traces)
  local source_map = load_source_files(traces)

  io.stdout:write("\nTRACE SUMMARY\n=============\n")
  -- Report first by abort reason
  local results, result_map, total = count_trace_results(traces,
      function(tr) return tr.status and "Success" or tr.abort.reason end)
  report_summary(io.stdout, results, result_map, total)

  -- And then by abort line
  local results, result_map, total = count_trace_results(traces,
      function(tr)
        if tr.status then
          return "Success"
        else
          return ("%s:%d (%s)"):format(tr.abort.info.source, tr.abort.info.currentline, tr.abort.reason)
        end
      end)
  report_summary(io.stdout, results, result_map, total)

  -- Organise the traces into blocks
  for i, tr in ipairs(traces) do
    local current_function
    local blocks = {}
    for _, b in ipairs(tr.bytecode) do
      if b.info.source then
        local function_name = ("%s:%d-%d"):format(b.info.source, b.info.linedefined, b.info.lastlinedefined)
        if function_name ~= current_function then
          blocks[#blocks+1] = { source = b.info.source, first_line=math.huge, last_line=-math.huge,
            linedefined=b.info.linedefined, lastlinedefined=b.info.lastlinedefined, line_map={}, lines={} }
          current_function = function_name
        end
      end
      local bl = blocks[#blocks]
      local l
      if b.info.source then
        local currentline = b.info.currentline
        bl.first_line = math.min(bl.first_line, currentline)
        bl.last_line = math.max(bl.last_line, currentline)
        if not bl.line_map[currentline] then
          local l = { number=currentline, bytecode={} }
          bl.line_map[currentline] = l
          bl.lines[#bl.lines+1] = l
        end
        l = bl.line_map[currentline]
      else
        l = bl.lines[#bl.lines]
      end
      l.bytecode[#l.bytecode+1] = b.bc
    end
    tr.blocks = blocks
  end

  for i, tr in ipairs(traces) do
    for j, bl in ipairs(tr.blocks) do
      table.sort(bl.lines, function(a, b) return a.number < b.number end)
    end
  end

  -- How long is the longest bytecode line?
  local bclen = 0
  for i, tr in ipairs(traces) do
    for k, b in ipairs(tr.bytecode) do
      if #b.bc > bclen then bclen = #b.bc end
    end
  end
  local bc_format = ("%%-%ds"):format(bclen)

  io.stdout:write("TRACES\n======\n")
  for i, tr in ipairs(traces) do
    io.stdout:write("\n")
    if tr.status then
      io.stdout:write(("Trace #%d"):format(tr.number))
    else
      io.stdout:write(("Aborted trace - %s"):format(tostring(tr.abort.reason)))
    end
    io.stdout:write((" (%d lines, %d bytecodes, %d attempts)"):format(tr.linecount, #tr.bytecode, tr.attempts))
    io.stdout:write("\n")
    for j, bl in ipairs(tr.blocks) do
      io.stdout:write(bc_format:format(" "), " | ", ("%s:%d-%d\n"):format(bl.source:sub(2,-1), bl.first_line, bl.last_line))
      if j == 1 and bl.linedefined >= bl.first_line - 5 then
        for k = bl.linedefined, bl.first_line - 1 do
          io.stdout:write(bc_format:format(" "))
          io.stdout:write((" | %4d"):format(k))
          io.stdout:write((" | %s\n"):format(source_map[bl.source][k]))
        end
      end
      for k, line in ipairs(bl.lines) do
        for l, b in ipairs(line.bytecode) do
          io.stdout:write(bc_format:format(b))
          if l == 1 then
            io.stdout:write((" | %4d"):format(line.number))
            io.stdout:write((" | %s\n"):format(source_map[bl.source][line.number]))
          else
            io.stdout:write(" |    . |\n")
          end
        end
      end
      if j == #tr.blocks and bl.lastlinedefined <= bl.last_line + 5 then
        for k = bl.last_line + 1, bl.lastlinedefined do
          io.stdout:write(bc_format:format(" "))
          io.stdout:write((" | %4d"):format(k))
          io.stdout:write((" | %s\n"):format(source_map[bl.source][k]))
        end
      end
    end
    if not tr.status then
      io.stdout:write("Aborted - ", tr.abort.reason, "\n")
    end
    io.stdout:write(("-"):rep(100), "\n")
  end

  if active then
    jit.attach(annotate_trace, "trace")
    jit.attach(annotate_record, "record")
  end
end


-- Control ---------------------------------------------------------------------

local function annotate_off()
  active = false

  jit.attach(annotate_trace)
  jit.attach(annotate_record)
end

local function annotate_on(opt, outfile)
  active, reported = true, false

  jit.attach(annotate_trace, "trace")
  jit.attach(annotate_record, "record")

  if not jit_annotate_shutdown then
    jit_annotate_shutdown = newproxy(true)
    getmetatable(jit_annotate_shutdown).__gc = annotate_report
  end
end

-- Public module functions.
module(...)

on = annotate_on
off = annotate_off
start = annotate_on -- For -j command line option.
report = annotate_report


-- EOF -------------------------------------------------------------------------

