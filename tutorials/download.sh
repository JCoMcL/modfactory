#!/usr/bin/env sh

cd "$(dirname "$(which $0)")"

while read URL
	do curl "$URL?action=raw" > ${URL##*/w/}.wikitext
done << EOF
https://minecraft.wiki/w/Function_(Java_Edition)
https://minecraft.wiki/w/Tutorial:Command_blocks_and_functions
https://minecraft.wiki/w/Tutorial:Useful_commands
https://minecraft.wiki/w/Tutorial:Command_NBT_tags
https://minecraft.wiki/w/Tutorial:Adding_a_new_dimension
https://minecraft.wiki/w/Tutorial:Adding_custom_enchantments
https://minecraft.wiki/w/Tutorial:Adding_custom_paintings
https://minecraft.wiki/w/Tutorial:Adding_custom_trims
https://minecraft.wiki/w/Tutorial:Repairing_a_world_corrupted_by_a_data_pack
https://minecraft.wiki/w/Tutorial:Importing_a_data_pack
https://minecraft.wiki/w/Tutorial:Custom_structures
https://minecraft.wiki/w/Tutorial:Creating_a_data_pack
EOF
