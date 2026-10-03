pico-8 cartridge // http://www.pico-8.com
version 42
__lua__
-- crownfall: a trebuchet siege
-- arrows/wasd: aim and ammo, space: fire

#include dev_reload.lua

function build_game()
 #include game.lua
end

game=build_game()

function _init()
 state={}
 game.reset(state)
 dev_reload.init()
end

function _update60()
 dev_reload.poll()
 game.update(state)
end

function _draw()
 game.draw(state)
end
