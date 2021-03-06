--[[
Iptables file dumper for Alpine Wall
Copyright (C) 2012-2020 Kaarle Ritvanen
See LICENSE file for license details
]]--


local class = require('awall.class')
local ACTIVE = require('awall.family').ACTIVE
local raise = require('awall.uerror').raise

local util = require('awall.util')
local printmsg = util.printmsg
local sortedkeys = util.sortedkeys


local lpc = require('lpc')
local posix = require('posix')
local stringy = require('stringy')


local M = {}

local families = {
   inet={
      cmd='iptables', file='rules-save', procfile='/proc/net/ip_tables_names'
   },
   inet6={
      cmd='ip6tables',
      file='rules6-save',
      procfile='/proc/net/ip6_tables_names'
   }
}

local builtin = {
   filter={'FORWARD', 'INPUT', 'OUTPUT'},
   mangle={'FORWARD', 'INPUT', 'OUTPUT', 'POSTROUTING', 'PREROUTING'},
   nat={'INPUT', 'OUTPUT', 'POSTROUTING', 'PREROUTING'},
   raw={'OUTPUT', 'PREROUTING'},
   security={'FORWARD', 'INPUT', 'OUTPUT'}
}

local backupdir = '/var/run/awall'


local _actfamilies
local function actfamilies()
   if _actfamilies then return _actfamilies end
   _actfamilies = {}
   for _, family in ipairs(ACTIVE) do
      if posix.stat(families[family].procfile) then
	 table.insert(_actfamilies, family)
      else printmsg('Warning: firewall not enabled for '..family) end
   end
   return _actfamilies
end

function M.isenabled() return #actfamilies() > 0 end

function M.isbuiltin(tbl, chain) return util.contains(builtin[tbl], chain) end


local BaseIPTables = class()

function BaseIPTables:print()
   for _, family in sortedkeys(families) do
      self:dumpfile(family, io.output())
      io.write('\n')
   end
end

function BaseIPTables:dump(dir)
   for family, tbls in pairs(families) do
      local file = io.open(dir..'/'..families[family].file, 'w')
      self:dumpfile(family, file)
      file:close()
   end
end

function BaseIPTables:restorecmd(family, test)
   local cmd = {families[family].cmd..'-restore'}
   if test then table.insert(cmd, '-t') end
   return table.unpack(cmd)
end

function BaseIPTables:restore(test)
   for _, family in ipairs(actfamilies()) do
      local pid, stdin, stdout = lpc.run(self:restorecmd(family, test))
      stdout:close()
      self:dumpfile(family, stdin)
      stdin:close()
      assert(lpc.wait(pid) == 0)
   end
end

function BaseIPTables:activate()
   self:flush()
   self:restore(false)
end

function BaseIPTables:test() self:restore(true) end

function BaseIPTables:flush() M.flush() end


M.IPTables = class(BaseIPTables)

function M.IPTables:init()
   local function nestedtable(levels)
      return levels > 0 and setmetatable(
	 {},
	 {
	    __index=function(t, k)
	       t[k] = nestedtable(getmetatable(t).levels - 1)
	       return t[k]
	    end,
	    levels=levels
	 }
      ) or {}
   end
   self.config = nestedtable(3)
end

function M.IPTables:dumpfile(family, iptfile)
   iptfile:write('# '..families[family].file..' generated by awall\n')
   local tables = self.config[family]
   for _, tbl in sortedkeys(tables) do
      iptfile:write('*'..tbl..'\n')
      local chains = tables[tbl]
      for _, chain in sortedkeys(chains) do
	 local policy = '-'
	 if M.isbuiltin(tbl, chain) then
	    policy = tbl == 'filter' and 'DROP' or 'ACCEPT'
	 end
	 iptfile:write(':'..chain..' '..policy..' [0:0]\n')
      end
      for _, chain in sortedkeys(chains) do
	 for _, rule in ipairs(chains[chain]) do
	    iptfile:write('-A '..chain..' '..rule..'\n')
	 end
      end
      iptfile:write('COMMIT\n')
   end
end


M.PartialIPTables = class(M.IPTables)

function M.PartialIPTables:restorecmd(family, test)
   local cmd = {M.PartialIPTables.super(self):restorecmd(family, test)}
   table.insert(cmd, '-n')
   return table.unpack(cmd)
end

function M.PartialIPTables:dumpfile(family, iptfile)
   local tables = self.config[family]
   for tbl, chains in pairs(tables) do
      local builtins = {}
      for chain, _ in pairs(chains) do
	 if stringy.startswith(chain, 'awall-') then
	    local base = chain:sub(7, -1)
	    if M.isbuiltin(tbl, base) then table.insert(builtins, base) end
	 end
      end
      for _, chain in ipairs(builtins) do
	 chains[chain] = {'-j awall-'..chain}
      end
   end
   M.PartialIPTables.super(self):dumpfile(family, iptfile)
end

function M.PartialIPTables:flush()
   for _, family in ipairs(actfamilies()) do
      local cmd = families[family].cmd
      for tbl in io.lines(families[family].procfile) do
	 if builtin[tbl] then
	    local pid, stdin, stdout = lpc.run(cmd, '-t', tbl, '-S')
	    stdin:close()
	    local chains = {}
	    local rules = {}
	    for line in stdout:lines() do
	       if stringy.startswith(line, '-N awall-') then
		  table.insert(chains, line:sub(4, -1))
	       else
		  local chain, target = line:match('^%-A (%u+) %-j (awall%-%u+)$')
		  if chain then table.insert(rules, {chain, '-j', target}) end
	       end
	    end
	    stdout:close()
	    assert(lpc.wait(pid) == 0)

	    local function exec(...)
	       assert(util.execute(cmd, '-t', tbl, table.unpack{...}) == 0)
	    end
	    for _, rule in ipairs(rules) do exec('-D', table.unpack(rule)) end
	    for _, opt in ipairs{'-F', '-X'} do
	       for _, chain in ipairs(chains) do exec(opt, chain) end
	    end
	 end
      end
   end
end


local Current = class(BaseIPTables)

function Current:dumpfile(family, iptfile)
   local pid, stdin, stdout = lpc.run(families[family].cmd..'-save')
   stdin:close()
   for line in stdout:lines() do iptfile:write(line..'\n') end
   stdout:close()
   assert(lpc.wait(pid) == 0)
end


local Backup = class(BaseIPTables)

function Backup:dumpfile(family, iptfile)
   for line in io.lines(backupdir..'/'..families[family].file) do
      iptfile:write(line..'\n')
   end
end


function M.backup()
   posix.mkdir(backupdir)
   Current():dump(backupdir)
end

function M.revert() Backup():activate() end

function M.flush()
   local empty = M.IPTables()
   for _, family in pairs(actfamilies()) do
      for tbl in io.lines(families[family].procfile) do
	 if builtin[tbl] then
	    for _, chain in ipairs(builtin[tbl]) do
	       empty.config[family][tbl][chain] = {}
	    end
	 else printmsg('Warning: not flushing unknown table: '..tbl) end
      end
   end
   empty:restore(false)
end

return M
