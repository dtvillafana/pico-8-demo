-- Crownfall. Campaign state survives live code reloads.
local game={}
local ammo={
 {name="stone",color=6,damage=28,radius=7,speed=1},
 {name="heavy",color=5,damage=60,radius=12,speed=0.9},
 {name="fire",color=9,damage=20,radius=22,speed=1},
 {name="grapeshot",color=6,damage=14,radius=4,speed=1.05}
}
local names={"the outpost","wooden watch","twin towers",
 "stone keep","royal fortress","the iron crown"}

function game.level(s)
 s.blocks={} s.guards={} s.particles={}
 s.ball=nil s.balls={} s.phase="aim" s.angle=47/360 s.ammo=1
 s.aim_direction=0 s.aim_frames=0
 s.shots=7-flr((s.level-1)/2)
 if s.level==3 then s.shots=8 end
 s.timer=0 s.shake=0 s.reward=0
 s.destroyed=false s.explosion_frame=0
 s.launch_frame=nil s.launch_angle=nil s.launch_kind=nil
 s.start_money=s.money s.start_stock={unpack(s.stock)}
 local floors=2+flr(s.level/2)
 local towers=1+flr((s.level-1)/2)
 for tower=1,towers do
  -- Rightmost beam ends at screen x=120, leaving seven pixels for rubble.
  local x=324-towers*30+(tower-1)*30
  for floor=1,floors do
   local y=115-(floor-1)*18
   local stone=s.level>=4 and floor<=s.level-3
   local hp=stone and 48 or 24
   for side=0,1 do
    add(s.blocks,{x=x+side*22,y=y-7,w=5,h=14,
     hp=hp,maxhp=hp,stone=stone,vx=0,vy=0,fire=0})
   end
   add(s.blocks,{x=x+11,y=y-16,w=30,h=4,
    hp=hp,maxhp=hp,stone=stone,vx=0,vy=0,fire=0})
   add(s.guards,{x=x+11,y=y-23,w=5,h=10,vy=0,hp=30,alive=true})
  end
 end
 s.total=#s.guards s.alive=s.total
end

function game.reset(s)
 s.level=1 s.money=0 s.score=0 s.power=0
 s.stock={0,0,0,0} s.tick=0 s.selection=1 s.notice=0
 game.level(s)
 s.phase="title"
end

function game.flash_menu(s)
 if s.rapid_flash==nil then s.rapid_flash=true end
 menuitem(1,"rapid flash: "..(s.rapid_flash and "on" or "off"),function()
  s.rapid_flash=not s.rapid_flash
  game.flash_menu(s)
 end)
 s.flash_menu_ready=true
end

local function keyboard(s)
 poke(0x5f2d,1)
 s.keys={}
 while stat(30) do
  local key=stat(31)
  local button=({a=0,d=1,w=2,s=3,A=0,D=1,W=2,S=3,[" "]=4})[key]
  if button then s.keys[button]=true end
 end
end

local function direction(s,i)
 return btnp(i) or s.keys[i]
end

local function action(s)
 return btnp(4) or s.keys[4]
end

local function burst(s,x,y,col,n)
 for i=1,n do
  add(s.particles,{x=x,y=y,vx=rnd(3)-1.5,
   vy=-rnd(2),life=20+rnd(20),col=col})
 end
 while #s.particles>100 do del(s.particles,s.particles[1]) end
end

local function move_particles(s)
 for p in all(s.particles) do
  p.x+=p.vx p.y+=p.vy p.vy+=0.05 p.life-=1
  if p.life<=0 then del(s.particles,p) end
 end
end

local function release_position(angle)
 local radial=angle+0.25
 return 25+cos(radial)*28,91+sin(radial)*28
end

local function launch_speed(s,kind,angle)
 if kind~=2 then return (6.4+s.power*0.55)*ammo[kind].speed end
 -- Calibrate a 60-degree arc to land just inside the nearest castle edge.
 -- Use the original layout, not scattered rubble, to keep the power stable.
 local towers=1+flr((s.level-1)/2)
 local target=324-towers*30-4+8
 local reference=1/6
 local origin_x,origin_y=release_position(reference)
 local distance=target-origin_x
 local horizontal=cos(reference)
 local rise=-sin(reference)/horizontal
 local speed=sqrt(0.06*distance*distance/
  (horizontal*horizontal*(111-origin_y+rise*distance)))
 -- Heavy rounds need a lofted release; shallow shots lose launch energy.
 local elevation=flr(angle*360+0.5)%360
 local loft=mid(0,(elevation-35)/25,1)
 if elevation>90 then loft=0 end
 return speed*(0.55+0.45*loft)*(1+s.power*0.03)
end

local function launch_pose(s)
 local angle=s.launch_frame and s.launch_angle or s.angle
 local radial=angle+0.5
 local lag=0.035
 local frame=s.launch_frame
 if frame then
  if frame<=6 then
   radial+=0.025*frame/6
  elseif frame<=20 then
   local t=(frame-6)/14
   radial+=0.025-0.275*t*t
   lag*=1-t
  elseif frame<=34 then
   local t=(frame-20)/14
   radial=angle+0.25-0.1*(2*t-t*t)
   lag=-0.06*t
  else
   local t=(frame-34)/20
   local eased=t*t*(3-2*t)
   radial=angle+0.15+0.35*eased
   lag=-0.06+0.095*eased
  end
 end
 local tip_x=25+cos(radial)*18
 local tip_y=91+sin(radial)*18
 return radial,tip_x,tip_y,
  tip_x+cos(radial+lag)*10,tip_y+sin(radial+lag)*10
end

local function segment_hit(p,ax,ay,bx,by)
 -- Reject distant shots before squaring to avoid fixed-point overflow.
 if p.x<min(ax,bx)-3 or p.x>max(ax,bx)+3 or
  p.y<min(ay,by)-3 or p.y>max(ay,by)+3 then return false end
 local dx,dy=bx-ax,by-ay
 local t=mid(0,((p.x-ax)*dx+(p.y-ay)*dy)/(dx*dx+dy*dy),1)
 return (p.x-ax-t*dx)^2+(p.y-ay-t*dy)^2<=9
end

local function self_hit(s,p)
 local _,tip_x,tip_y=launch_pose(s)
 return segment_hit(p,16,115,25,88) or
  segment_hit(p,34,115,25,88) or
  segment_hit(p,15,115,35,115) or
   segment_hit(p,25,91,tip_x,tip_y)
end

local function wreck(s)
 s.destroyed=true s.ball=nil s.balls={} s.phase="explode" s.explosion_frame=0
 s.shake=12
 for i=1,100 do
  local color=(i-1)%15+1
  add(s.particles,{x=25,y=98,vx=rnd(6)-3,vy=-rnd(5),
   life=120,col=color})
 end
 while #s.particles>100 do del(s.particles,s.particles[1]) end
end

local function hurt(s,b,damage)
 if b.hp<=0 then return end
 b.hp-=damage
 if b.hp<=0 then
  s.money+=5 s.score+=5 s.reward+=5
  burst(s,b.x,b.y,b.stone and 6 or 4,7)
 end
end

local function kill(s,g)
 if not g.alive then return end
 g.alive=false
 s.money+=50 s.score+=50 s.reward+=50
 burst(s,g.x,g.y,8,10)
end

local function blast(s,p,hit_block)
 local a=ammo[p.kind]
 s.shake=p.kind==4 and 2 or 8
  burst(s,p.x,p.y,a.color,p.kind==4 and 5 or 18)
 if p.kind==2 and hit_block then
  local count=rnd(1)<0.3 and 3 or 2
  local broken={}
  for i=1,count do
   local target=i==1 and hit_block or nil
   local nearest=32767
   if not target then
    for b in all(s.blocks) do
     if b.hp>0 then
      for previous in all(broken) do
       if abs(b.x-previous.x)<=(b.w+previous.w)/2+0.8 and
        abs(b.y-previous.y)<=(b.h+previous.h)/2+0.8 then
        local distance=((b.x-p.x)/4)^2+((b.y-p.y)/4)^2
        if distance<nearest then target=b nearest=distance end
        break
       end
      end
     end
    end
   end
   if not target then break end
   add(broken,target)
   hurt(s,target,target.hp)
  end
 end
 if p.kind==3 and hit_block then
  -- Ignite two or three touching neighbors, without chain spread.
  hit_block.fire=240
  local remaining=2+flr(rnd(2))
  for other in all(s.blocks) do
   if other~=hit_block and other.hp>0 and other.fire<=0 and
    abs(other.x-hit_block.x)<=(other.w+hit_block.w)/2+0.5 and
    abs(other.y-hit_block.y)<=(other.h+hit_block.h)/2+0.5 then
     other.fire=240
     remaining-=1
     if remaining==0 then break end
   end
  end
 end
 for b in all(s.blocks) do
  local d=sqrt(((b.x-p.x)/4)^2+((b.y-p.y)/4)^2)*4
  local contact=abs(b.x-p.x)<b.w/2+3 and abs(b.y-p.y)<b.h/2+3
    if ((p.kind==3 or p.kind==4) and b==hit_block) or
      (p.kind==1 and contact) then
   hurt(s,b,a.damage*max(0.25,1-d/(a.radius+20)))
    b.vx+=(b.x>=p.x and 1 or -1)*(p.kind==4 and 0.35 or 0.8)
    b.vy-=p.kind==4 and 0.3 or 1
  end
 end
  for g in all(s.guards) do
   local radius=p.kind==4 and 1 or 3
   local direct=abs(g.x-p.x)<g.w/2+radius and abs(g.y-p.y)<g.h/2+radius
   if g.alive and direct then
    if p.kind==4 then
     g.hp=(g.hp or 30)-a.damage
     if g.hp<=0 then kill(s,g) end
    else
     kill(s,g)
    end
   end
 end
 del(s.balls,p)
end

function game.launch(s)
 if s.phase~="aim" then return end
 if s.ammo>1 and s.stock[s.ammo]<=0 then s.notice=60 return end
 if s.ammo>1 then s.stock[s.ammo]-=1 end
  s.launch_frame=0 s.launch_angle=s.angle s.launch_kind=s.ammo
  s.shots-=1 s.phase="windup"
end

local function physics(s)
 -- Bottom-to-top order settles stacked beams and pillars.
 for b in all(s.blocks) do
  if b.hp>0 then
   local old=b.y+b.h/2
    b.vy+=0.12 b.x+=b.vx b.y+=b.vy b.vx*=0.96
    local base=115
    local support_left=b.x-b.w/2
    local support_right=b.x+b.w/2
    for other in all(s.blocks) do
    if other~=b and other.hp>0 and
     abs(b.x-other.x)<(b.w+other.w)/2-0.5 then
     local top=other.y-other.h/2
      if old<=top+0.8 and b.y+b.h/2>=top and top<=base then
       local left=max(b.x-b.w/2,other.x-other.w/2)
       local right=min(b.x+b.w/2,other.x+other.w/2)
       if top<base then
        base=top support_left=left support_right=right
       else
        support_left=min(support_left,left)
        support_right=max(support_right,right)
       end
      end
    end
   end
   if b.y+b.h/2>=base then
    if b.vy>1.5 then hurt(s,b,b.vy*6) end
     b.y=base-b.h/2 b.vy=0
     -- Support must bracket the center of mass. One-sided contact
     -- makes the piece slide off instead of hovering on a corner.
     local slide=0
     if b.x<support_left-0.25 then slide=-1 end
     if b.x>support_right+0.25 then slide=1 end
     if slide~=0 then
      b.vx+=slide*min(0.2,0.06+0.04*b.h/b.w)
     else
      b.vx*=0.8
     end
   end
   -- Resolve sideways block contacts: debris pushes other blocks instead
   -- of passing through them. Gravity handles their vertical contacts.
   for other in all(s.blocks) do
    if other~=b and other.hp>0 and abs(b.vx)>0.08 and
     abs(b.y-other.y)<(b.h+other.h)/2-1 then
     local penetration=(b.w+other.w)/2-abs(b.x-other.x)
     if penetration>0 and penetration<4 then
      local direction=b.x<other.x and -1 or 1
      local impact=abs(b.vx-other.vx)
      b.x+=direction*penetration/2
      other.x-=direction*penetration/2
      other.vx=b.vx*0.6 b.vx*=0.3
      if impact>1 then hurt(s,b,impact*4) hurt(s,other,impact*4) end
     end
    end
   end
   if b.fire>0 then
    b.fire-=1 hurt(s,b,b.stone and 0.04 or 0.22)
    if s.tick%12==0 then
     burst(s,b.x,b.y,9,1)
    end
   end
  end
 end
 for g in all(s.guards) do
  if g.alive then
   g.hp=g.hp or 30
   local old=g.y+g.h/2
   g.vy+=0.12 g.y+=g.vy
   local base=115
   for b in all(s.blocks) do
    if b.hp>0 and abs(g.x-b.x)<(g.w+b.w)/2 then
     local top=b.y-b.h/2
     if old<=top+0.8 and g.y+g.h/2>=top then
      base=min(base,top)
      g.x+=b.vx
     end
     -- A supporting floor sliding slightly is not a lethal impact.
     -- Crushing requires a falling block above the guard, or fast debris.
     if abs(g.y-b.y)<(g.h+b.h)/2 then
      if (b.y<g.y and b.vy>0.8) or abs(b.vx)>1.2 then
       g.hp-=max(b.vy,abs(b.vx))*8
      end
      if b.fire>0 then g.hp-=0.3 end
      if g.hp<=0 then kill(s,g) end
     end
    end
   end
   if g.y+g.h/2>=base then
    if g.vy>1.2 then g.hp-=g.vy*14 end
    if g.hp<=0 then kill(s,g) end
    g.y=base-g.h/2 g.vy=0
   end
  end
 end
end

local function price(s,item)
 if item==1 then return 100+s.power*75 end
 return ({30,45,70})[item-1]
end

function game.buy(s)
 local i=s.selection
 local cost=price(s,i)
 if i==1 and s.power>=5 then return end
 if s.money<cost then s.notice=60 return end
 s.money-=cost
 if i==1 then s.power+=1 else s.stock[i]+=3 end
end

function game.update(s)
 if not s.blocks then game.reset(s) end
 s.balls=s.balls or {}
 -- Adopt a projectile already in flight when this module is hot-reloaded.
 if s.ball then add(s.balls,s.ball) s.ball=nil end
 if s.rapid_flash==nil then s.rapid_flash=true s.flash_menu_ready=false end
 if not s.flash_menu_ready then game.flash_menu(s) end
 keyboard(s)
 s.tick+=1 s.shake=max(0,s.shake-1) s.notice=max(0,s.notice-1)
 if s.phase=="explode" then
  s.explosion_frame+=1
  move_particles(s)
  if s.explosion_frame>=120 then s.phase="lost" end
  return
 end
 if s.phase=="title" then
  if action(s) or btnp(5) then s.phase="aim" end
  return
 end
 if s.phase=="shop" then
  if direction(s,2) then s.selection=max(1,s.selection-1) end
  if direction(s,3) then s.selection=min(4,s.selection+1) end
  if action(s) then game.buy(s) end
  if btnp(5) then s.level+=1 game.level(s) end
  return
 end
 if s.phase=="lost" then
  if action(s) then
   s.money=s.start_money s.score-=s.reward
   s.stock={unpack(s.start_stock)} game.level(s)
  end
  return
 end
 if s.phase=="won" then
  if action(s) then s.phase=s.level==6 and "victory" or "shop" end
  return
 end
 if s.phase=="victory" then
  if action(s) then game.reset(s) end
  return
 end
 if s.phase=="aim" then
   -- Raw keyboard state avoids the text-input repeat delay for W/S.
   local up=btn(2) or stat(28,26)
   local down=btn(3) or stat(28,22)
   local aim=(up and 1 or 0)-(down and 1 or 0)
   if aim~=s.aim_direction then
    s.aim_direction=aim s.aim_frames=0
   else
    s.aim_frames=(s.aim_frames or 0)+1
   end
   if aim~=0 and s.aim_frames%3==0 then
    local degrees=flr(s.angle*360+0.5)
    s.angle=((degrees+aim)%360)/360
   end
   if direction(s,0) then s.ammo=(s.ammo+2)%4+1 end
   if direction(s,1) then s.ammo=s.ammo%4+1 end
   if s.keys[4] then game.launch(s) end
  end
 local released=false
 if s.launch_frame then
  s.launch_frame+=1
  if s.launch_frame==20 and s.phase=="windup" then
   local angle=s.launch_angle
   local speed=launch_speed(s,s.launch_kind,angle)
   local x,y=release_position(angle)
   local count=s.launch_kind==4 and 5 or 1
   for i=1,count do
    local spread=(i-(count+1)/2)*0.012
    add(s.balls,{x=x,y=y,vx=cos(angle+spread)*speed,
     vy=sin(angle+spread)*speed,kind=s.launch_kind,age=0})
   end
   s.phase="flight" released=true
   burst(s,25,115,6,4)
  elseif s.launch_frame>=54 then
   s.launch_frame=nil
  end
 end
 physics(s)
 if not released then
  for p in all(s.balls) do
   -- Substeps prevent stones tunneling through thin pillars.
   local radius=p.kind==4 and 1 or 2
   for step=1,3 do
    p.vy+=0.04 p.x+=p.vx/3 p.y+=p.vy/3
    -- Ignore the launcher until the shot has flown for 0.2 seconds.
    if p.age>=12 and self_hit(s,p) then wreck(s) return end
    local solid=p.kind~=3
    local ground=115-radius
    local hit=not solid and p.y>=ground
    local hit_block=nil
    for b in all(s.blocks) do
     if b.hp>0 and abs(p.x-b.x)<b.w/2+radius and
      abs(p.y-b.y)<b.h/2+radius then
      hit=true hit_block=b break
     end
    end
    for g in all(s.guards) do
     if g.alive and abs(p.x-g.x)<g.w/2+radius and
      abs(p.y-g.y)<g.h/2+radius then hit=true end
    end
    if hit then blast(s,p,hit_block) break end
    if solid and p.y>=ground then
     p.y=ground p.ground_hit=true
     if p.vy>0.6 then
      p.vy=-p.vy*(p.kind==2 and 0.3 or 0.55)
      p.vx*=p.kind==2 and 0.94 or 0.9
      burst(s,p.x,115,6,3)
     else
       p.vy=0 p.vx*=p.kind==2 and 0.97 or 0.996
      if abs(p.vx)<0.2 then del(s.balls,p) break end
     end
    end
   end
   p.age+=1
   local lifetime=p.ground_hit and 600 or 240
   if p.x>340 or p.x< -40 or p.y>128 or p.age>lifetime then
    del(s.balls,p)
   end
  end
 end
 if s.phase=="flight" and #s.balls==0 then
  s.phase="settle" s.timer=0
 end
 move_particles(s)
 local alive=0
 for g in all(s.guards) do if g.alive then alive+=1 end end
 s.alive=alive
 if alive==0 then
  local bonus=100+s.level*25+s.shots*20
  s.money+=bonus s.score+=bonus s.reward+=bonus
   s.phase="won" s.ball=nil s.balls={}
 elseif s.phase=="settle" then
  s.timer+=1
   if s.timer>120 then s.phase=s.shots>0 and "aim" or "lost" end
 end
end

local function project(s,x,y)
 return 5+x*0.36,41+(y-10)*0.65,0.36
end

local function trebuchet(s)
 local x,y,k=project(s,25,106)
 if s.destroyed then
  line(x-9*k,y+9*k,x-3*k,y+7*k,4)
  line(x+9*k,y+9*k,x+2*k,y+8*k,15)
  circfill(x-5*k,y+7*k,3*k,5)
  return
 end
 line(x-9*k,y+9*k,x,y-18*k,4)
 line(x+9*k,y+9*k,x,y-18*k,4)
 line(x-10*k,y+9*k,x+10*k,y+9*k,15)
  -- A single throwing arm, flexible sling, and hanging counterweight.
  local radial,tip_x,tip_y,pouch_x,pouch_y=launch_pose(s)
  local pivot_x,pivot_y=project(s,25,91)
  local rear_x,rear_y=project(s,tip_x,tip_y)
  local sling_x,sling_y=project(s,pouch_x,pouch_y)
  line(pivot_x,pivot_y,rear_x,rear_y,15)
  line(rear_x,rear_y,sling_x,sling_y,6)
  local weight_x,weight_y=project(s,25-cos(radial)*6,97-sin(radial)*6)
  line(pivot_x,pivot_y,weight_x,weight_y,6)
  rectfill(weight_x-1,weight_y-1,weight_x+1,weight_y+2,5)
  if s.phase=="aim" or s.phase=="windup" then
   local kind=s.phase=="windup" and s.launch_kind or s.ammo
   circfill(sling_x,sling_y,2,ammo[kind].color)
   pset(sling_x-1,sling_y-1,7)
  end
end

local function world(s)
 cls(1) rectfill(0,34,127,96,12) circfill(107,44,9,10)
 for i=0,5 do
  local x=i*27
  line(x,82,x+14,69,13) line(x+14,69,x+28,82,13)
 end
 rectfill(0,97,127,127,3)
 local _,gy=project(s,0,115)
 rectfill(0,gy,127,127,3) line(0,gy,127,gy,11)
 for i=#s.blocks,1,-1 do
  local b=s.blocks[i]
  if b.hp>0 then
   local x,y,k=project(s,b.x,b.y)
   local w=max(1,b.w*k/2) local h=max(1,b.h*k/2)
   rectfill(x-w,y-h,x+w,y+h,b.stone and 6 or 4)
   line(x-w,y-h,x+w,y-h,b.stone and 7 or 15)
   if b.hp<b.maxhp*0.6 then line(x,y-h,x-1,y+h,0) end
   if b.fire>0 then circfill(x,y-h,2,9) pset(x,y-h-3,10) end
  end
 end
 for g in all(s.guards) do
  if g.alive then
   local x,y,k=project(s,g.x,g.y)
   rectfill(x-2*k,y-2*k,x+2*k,y+4*k,8)
   circfill(x,y-4*k,max(1,2*k),15) pset(x,y-5*k,7)
  end
 end
 trebuchet(s)
  if s.phase=="aim" then
   local speed=launch_speed(s,s.ammo,s.angle)
   local origin_x,origin_y=release_position(s.angle)
   for t=4,24,4 do
    local x,y=project(s,origin_x+cos(s.angle)*speed*t,
     origin_y+sin(s.angle)*speed*t+0.06*t*t)
   pset(x,y,7)
  end
 end
  for p in all(s.balls or {}) do
   local x,y,k=project(s,p.x,p.y)
   circfill(x,y,p.kind==4 and 1 or max(2,3*k),ammo[p.kind].color)
   pset(x-1,y-1,7)
 end
 for p in all(s.particles) do
  local x,y=project(s,p.x,p.y) pset(x,y,p.col)
 end
end

local function panel(title)
 rectfill(7,35,120,105,1) rect(7,35,120,105,6)
 print(title,14,42,10)
end

function game.draw(s)
 if not s.blocks then game.reset(s) end
 pal()
 camera(s.shake>0 and rnd(3)-1 or 0,0) world(s) camera()
 rectfill(0,0,127,30,0)
 print("crownfall  "..s.level.."/6",3,2,10)
 print("gold "..s.money.."  power "..s.power,3,10,7)
 print("shots "..s.shots.."  guards "..s.alive,3,18,7)
 print(names[s.level],3,26,13)
 rectfill(0,115,127,127,0)
 if s.phase=="title" then
  panel("crownfall")
  print("a trebuchet siege",14,54,7)
  print("topple every red guard",14,65,6)
  print("6 castles. earn upgrades.",14,76,6)
  print("space: begin siege",14,92,11)
 elseif s.phase=="shop" then
  panel("siege workshop")
  local items={"power +1","heavy x3","fire x3","grapeshot x3"}
  for i=1,4 do
   local text=items[i].." $"..price(s,i)
   if i==1 and s.power>=5 then text="power maxed" end
   print((i==s.selection and ">" or " ")..text,12,48+i*10,
    i==s.selection and 10 or 6)
  end
  print(s.notice>0 and "not enough gold" or "up/down: select",12,98,8)
  print("z:buy   x:next castle",3,119,7)
 elseif s.phase=="won" then
  panel("castle crushed!")
  print(names[s.level],14,57,7)
  print("earned "..s.reward.." gold",14,70,10)
  print("z: "..(s.level==6 and "claim the crown" or "visit workshop"),14,90,11)
 elseif s.phase=="lost" then
  panel(s.destroyed and "trebuchet destroyed!" or "siege repelled")
  print("guards remain: "..s.alive,14,58,7)
  print(s.destroyed and "don't shoot yourself!" or "try a higher/lower arc",14,72,6)
  print("z:retry, ammo restored",14,90,11)
 elseif s.phase=="victory" then
  panel("the crown is yours!")
  print("all six castles fell",14,58,7)
  print("final score: "..s.score,14,72,10)
  print("z: new campaign",14,90,11)
 else
  local count=s.ammo==1 and "inf" or tostr(s.stock[s.ammo])
  print(s.notice>0 and "out of ammo" or
    ammo[s.ammo].name.." "..count.." angle "..flr(s.angle*360+0.5)%360,3,106,10)
  print("ws/ud:aim ad/lr:ammo",3,116,7)
  print("space:fire",3,123,7)
 end
 if s.phase=="explode" then
  if s.rapid_flash then
   -- 100 color steps in 120 updates (two seconds at 60 Hz).
   local step=min(99,flr(s.explosion_frame*100/120))
   local color=step%32
   pal(0,color<16 and color or color+112,1)
   cls(0)
  else
   print("trebuchet exploded!",26,44,10)
  end
 end
end

return game
