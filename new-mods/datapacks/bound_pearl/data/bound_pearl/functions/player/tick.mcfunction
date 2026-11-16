scoreboard players operation @s bp_prev = @s bp_hold
scoreboard players set @s bp_hold 0
execute store result score @s bp_u0 run data get entity @s UUID[0] 1
execute store result score @s bp_u1 run data get entity @s UUID[1] 1
execute store result score @s bp_u2 run data get entity @s UUID[2] 1
execute store result score @s bp_u3 run data get entity @s UUID[3] 1
execute if data entity @s SelectedItem.tag.bound_pearl run function bound_pearl:player/cache
execute if score @s bp_prev matches 1 run function bound_pearl:player/scan
