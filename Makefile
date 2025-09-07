.PHONY: all clean test

.ONESHELL:
SHELL := bash
.SHELLFLAGS := -euo pipefail -c

new:
	f=./content/$$(date -I)-untitled.md
	{
# leading - in an EOF block is always discarded
		echo ---
		cat <<EOF
			title:
			description:
			date:
			taxonomies:
			tags: []
		EOF
		echo ---
	} > $$f
	if [ -t 1 ] ; then ${EDITOR} $$f ; fi
