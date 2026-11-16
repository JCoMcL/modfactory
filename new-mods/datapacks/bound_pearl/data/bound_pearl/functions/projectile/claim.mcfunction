execute store result score @s bp_u0 run data get entity @s Owner[0] 1
execute store result score @s bp_u1 run data get entity @s Owner[1] 1
execute store result score @s bp_u2 run data get entity @s Owner[2] 1
execute store result score @s bp_u3 run data get entity @s Owner[3] 1
execute if score @s bp_u0 = @a[tag=bp_thrower,limit=1] bp_u0 if score @s bp_u1 = @a[tag=bp_thrower,limit=1] bp_u1 if score @s bp_u2 = @a[tag=bp_thrower,limit=1] bp_u2 if score @s bp_u3 = @a[tag=bp_thrower,limit=1] bp_u3 run function bound_pearl:projectile/bind
