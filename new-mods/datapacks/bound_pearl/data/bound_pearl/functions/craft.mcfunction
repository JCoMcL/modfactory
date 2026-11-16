advancement revoke @s only bound_pearl:craft
clear @s minecraft:ender_pearl 1
execute at @s run summon minecraft:item ~ ~1 ~ {Tags:["bp_new"],PickupDelay:0,Item:{id:"minecraft:ender_pearl",Count:1b,tag:{bound_pearl:1b,display:{Name:'{"text":"Bound Pearl","italic":false}',Lore:['{"text":"Bound to its crafter","color":"gray","italic":false}']},Enchantments:[{id:"minecraft:unbreaking",lvl:1s}],HideFlags:1b}}}
execute at @s run data modify entity @e[type=minecraft:item,tag=bp_new,limit=1,sort=nearest] Item.tag.bound_owner set from entity @s UUID
execute at @s run tag @e[type=minecraft:item,tag=bp_new,limit=1,sort=nearest] remove bp_new
