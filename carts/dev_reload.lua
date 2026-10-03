-- Optional native bridge. No filesystem/compiler access in ordinary runs.
dev_reload={frames=0}

function dev_reload.init()
 dev_reload.frames=0
 dev_reload.pending=nil
 dev_reload.last_error=nil
 dev_reload.revision=nil
 if dev_read_changed then
  local source,revision,err=dev_read_changed("game.lua")
  dev_reload.revision=revision
  if err then
   printh("[hot-reload] Rejected change: "..err)
   dev_reload.last_error=err
  end
 end
end

function dev_reload.poll()
 if not dev_read_changed then return end
 dev_reload.frames=(dev_reload.frames+1)%12
 if dev_reload.frames~=0 then return end
 local source,revision,err=dev_read_changed("game.lua",dev_reload.revision)
 if err then
  if err~=dev_reload.last_error then
   printh("[hot-reload] Rejected change: "..err)
  end
  dev_reload.last_error=err
  dev_reload.pending=nil
  return
 end
 dev_reload.last_error=nil
 if not source then
  dev_reload.pending=nil
  return
 end
 -- Require identical content on two polls, including atomic editor saves.
 if revision~=dev_reload.pending then
  dev_reload.pending=revision
  return
 end
 dev_reload.pending=nil
 dev_reload.revision=revision
 local chunk,compile_error=dev_compile(source)
 if not chunk then
  printh("[hot-reload] Rejected change: "..tostr(compile_error))
  return
 end
 local ok,replacement=dev_pcall(chunk)
 if not ok then
  printh("[hot-reload] Rejected change: "..tostr(replacement))
  return
 end
 if type(replacement)~="table" then
  printh("[hot-reload] Rejected change: game.lua must return a table")
  return
 end
 if type(rawget(replacement,"update"))~="function" or
    type(rawget(replacement,"draw"))~="function" then
  printh("[hot-reload] Rejected change: returned table needs update and draw functions")
  return
 end
 game=replacement
 printh("[hot-reload] Replaced game functions; cartridge state preserved")
end
