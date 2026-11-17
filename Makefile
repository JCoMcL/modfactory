all: vineflower-1.12.0.jar AGENTS.md CLAUDE.md
	tutorials/download.sh

vineflower-1.12.0.jar:
	wget https://github.com/Vineflower/vineflower/releases/download/1.12.0/vineflower-1.12.0.jar

AGENTS.md: CLANKERS.md
	ln -sfr $< $@

CLAUDE.md: CLANKERS.md
	ln -sfr $< $@

.PHONY: clean
clean:
	cd servers/template && rm -rf defaultconfigs logs world banned-ips.json banned-players.json ops.json usercache.json whitelist.json
