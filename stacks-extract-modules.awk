/^module[[:space:]]+"[^"]+"[[:space:]]*\{/ {
    module_name = $2
    inside_block = 1
}

inside_block && /source[[:space:]]*=[[:space:]]*"[^"]+"/ {
    # Extract the source path between the double quotes
    split($0, parts, "\"")
    src = parts[2]

    # 2. Replace stacks_root with root ./
    gsub(/\$\{var\.stacks_root\}/, ".", src);

    # Output the reconstructed module line
    print "module " module_name " { source = \"" src "\" }"
    inside_block = 0
}
