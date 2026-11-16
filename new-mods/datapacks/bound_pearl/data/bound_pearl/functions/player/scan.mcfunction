tag @s add bp_thrower
execute at @s as @e[type=minecraft:ender_pearl,tag=!bp_claimed,nbt={Age:0s},distance=..4,sort=nearest,limit=1] if data entity @s Owner run function bound_pearl:projectile/claim
tag @s remove bp_thrower
