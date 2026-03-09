.PHONY: list lint

list:
	@echo "Available scripts:" && ls -1 scripts

lint:
	@echo "Shell syntax check" && bash -n scripts/*.sh
