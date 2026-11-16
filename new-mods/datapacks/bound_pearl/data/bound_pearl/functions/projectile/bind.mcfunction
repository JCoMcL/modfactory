tag @s add bp_claimed
execute store result entity @s Owner[0] int 1 run scoreboard players get @a[tag=bp_thrower,limit=1] bp_b0
execute store result entity @s Owner[1] int 1 run scoreboard players get @a[tag=bp_thrower,limit=1] bp_b1
execute store result entity @s Owner[2] int 1 run scoreboard players get @a[tag=bp_thrower,limit=1] bp_b2
execute store result entity @s Owner[3] int 1 run scoreboard players get @a[tag=bp_thrower,limit=1] bp_b3
