scoreboard players set @s bp_hold 1
execute store result score @s bp_b0 run data get entity @s SelectedItem.tag.bound_owner[0] 1
execute store result score @s bp_b1 run data get entity @s SelectedItem.tag.bound_owner[1] 1
execute store result score @s bp_b2 run data get entity @s SelectedItem.tag.bound_owner[2] 1
execute store result score @s bp_b3 run data get entity @s SelectedItem.tag.bound_owner[3] 1
