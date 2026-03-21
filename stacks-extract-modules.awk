/^module[[:space:]]+"[^"]+"[[:space:]]*\{/ {
    module_name = $2
    inside_block = 1
    src = ""
    version = ""
    next
}

inside_block {
    if (/source[[:space:]]*=[[:space:]]*"[^"]+"/) {
        # Extract the source path between the double quotes
        split($0, parts, "\"")
        src = parts[2]

        # Replace stacks_root with root ./
        gsub(/\$\{var\.stacks_root\}/, ".", src);
    }

    if (/version[[:space:]]*=[[:space:]]*"[^"]+"/) {
        split($0, parts, "\"")
        version = parts[2]
    }

    if (/^\}/) {
        # Output the reconstructed module line
        output = "module " module_name " {\n  source = \"" src "\""
        if (version != "") {
            output = output "\n  version = \"" version "\""
        }
        output = output "\n}"
        if (!seen[output]++) {
            print output
        }
        inside_block = 0
    }
}
