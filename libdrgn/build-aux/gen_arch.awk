# Copyright (c) Facebook, Inc. and its affiliates.
# SPDX-License-Identifier: GPL-3.0-or-later

# This script generates drgn architecture definition code ("arch_foo.inc") from
# an input definition file ("arch_foo.defs").
#
# The definition file comprises a list of register definitions which have the
# following syntax:
#
#   register-definition ::= register-names (":" identifier)? "\n"
#   register-names ::= string ("," string)*
#   identifier ::= [a-zA-Z_][a-zA-Z0-9_]*
#   string ::= '"' [^"]* '"'
#
# Whitespace other than newlines is not significant. Lines starting with "#"
# and lines consisting only of whitespace are ignored.
#
# A register definition denotes that the given names map to the register with
# the given identifier (defined by DRGN_ARCH_REGISTER_LAYOUT in "arch_foo.c").
# If the identifier is omitted, then it is assumed to be the same as the first
# name with non-alphanumeric characters replaced by "_" and prepended with "_"
# if the first character is numeric.
#
# Registers should be defined in the architecture's logical order.
#
# The generated file includes "arch_register_layout.h" and defines three
# things:
#
# 1. An array of register definitions:
#    static const struct drgn_register registers[];
#
# 2. A name lookup function:
#    static const struct drgn_register *register_by_name(const char *name);
#
# 3. A macro containing initializers for the "register_layout",
#    "dwarf_regno_to_internal", "registers", "num_registers", and
#    "register_by_name" members of "struct drgn_architecture_info":
#    #define DRGN_ARCHITECTURE_REGISTERS ...
#
# P.S. This is defined and generated separately from "arch_foo.c" because
# register_by_name() is implemented as a trie using nested switch statements,
# which can't easily be generated by the C preprocessor.

BEGIN {
	split("", registers)
	split("", registers_by_name)
}

function error(column, msg) {
	_error = 1
	print FILENAME ":" FNR ":" column ": error: " msg > "/dev/stderr"
	exit 1
}

/^\s*#/ {
	next
}

/\S/ {
	line = $0
	columns = length(line)
	sub(/^\s+/, "", line)

	idx = length(registers)
	num_names = 0

	while (1) {
		if (!match(line, /^"([^"]*)"\s*/, group))
			error(columns - length(line) + 1, "expected register name")
		if (group[1] in registers_by_name)
			error(columns - length(line) + 1, "duplicate register name")
		registers[idx]["names"][num_names++] = group[1]
		registers_by_name[group[1]] = idx
		line = substr(line, RSTART + RLENGTH)
		if (!sub(/^,\s*/, "", line))
			break
	}

	if (line == "") {
		id = registers[idx]["names"][0]
		gsub(/[^a-zA-Z0-9_]/, "_", id)
		if (!match(id, /^[a-zA-Z_]/))
			id = "_" id
		registers[idx]["id"] = id
	} else {
		if (!sub(/^:\s*/, "", line))
			error(columns - length(line) + 1, "expected \",\", \":\", or EOL")
		if (!match(line, /^([a-zA-Z_][a-zA-Z0-9_]*)\s*/, group))
			error(columns - length(line) + 1, "expected register identifier")
		registers[idx]["id"] = group[1]
		line = substr(line, RSTART + RLENGTH)
		if (line != "")
			error(columns - length(line) + 1, "expected EOL")
	}
}

function add_to_trie(node, s, value,     char) {
	if (length(s) == 0) {
		node[""] = value
	} else {
		char = substr(s, 1, 1)
		if (!(char in node)) {
			# Force node[char] to be an array.
			node[char][""] = ""
			delete node[char][""]
		}
		add_to_trie(node[char], substr(s, 2), value)
	}
}

function trie_to_switch(node, indent,     char) {
	print indent "switch (*(p++)) {"
	PROCINFO["sorted_in"] = "@ind_str_asc"
	for (char in node) {
		if (length(char) == 0) {
			print indent "case '\\0':"
			print indent "\treturn &registers[" node[""] "];"
		} else {
			print indent "case '" char "':"
			trie_to_switch(node[char], "\t" indent)
		}
	}
	print indent "default:"
	print indent "\treturn NULL;"
	print indent "}"
}

END {
	if (_error)
		exit 1

	num_registers = length(registers)

	print "/* Generated by libdrgn/build-aux/gen_arch.awk. */"
	print ""
	print "#include \"arch_register_layout.h\" // IWYU pragma: export"

	print ""
	print "static const struct drgn_register registers[] = {"
	for (i = 0; i < num_registers; i++) {
		print "\t{"
		print "\t\t.names = (const char * const []){"
		num_names = length(registers[i]["names"])
		for (j = 0; j < num_names; j++)
			print "\t\t\t\"" registers[i]["names"][j] "\","
		print "\t\t},"
		print "\t\t.num_names = " num_names ","
		print "\t\t.regno = DRGN_REGISTER_NUMBER(" registers[i]["id"] "),"
		print "\t},"
	}
	print "};"

	split("", trie)
	for (name in registers_by_name)
		add_to_trie(trie, name, registers_by_name[name])
	print ""
	print "static const struct drgn_register *register_by_name(const char *p)"
	print "{"
	trie_to_switch(trie, "\t")
	print "}"

	print ""
	print "#define DRGN_ARCHITECTURE_REGISTERS \\"
	print "\t.register_layout = register_layout, \\"
	print "\t.dwarf_regno_to_internal = dwarf_regno_to_internal, \\"
	print "\t.registers = registers, \\"
	print "\t.num_registers = " num_registers ", \\"
	print "\t.register_by_name = register_by_name"
}
