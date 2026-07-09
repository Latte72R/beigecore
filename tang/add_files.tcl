set file_list [open "../core.f" r]
while {[gets $file_list line] != -1} {
    # skip blank or comment line
    if {[string trim $line] eq "" || [string index $line 0] eq "#"} {
        continue
    }
    # add file to project
    add_file $line
}
close $file_list
