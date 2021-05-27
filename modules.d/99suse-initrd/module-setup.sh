#!/bin/bash

# Parse SUSE kernel module dependencies
#
# Kernel modules using "request_module" function may not show up in modprobe
# To worka round this, add depedencies in the following form:
# # SUSE_INITRD: module_name REQUIRES module1 module2 ...
# to /etc/modprobe.d/*.conf

# called by dracut
check() {
    # Skip the module if no SUSE INITRD is used
    grep -q "^# SUSE INITRD: " $(get_modprobe_conf_files)
}

get_modprobe_conf_files() {
    ls /etc/modprobe.d/*.conf /run/modprobe.d/*.conf \
       /lib/modprobe.d/*.conf /usr/lib/modprobe.d/*.conf \
       2>/dev/null
    return 0
}

# called by dracut
installkernel() {
    local line mod reqs all_mods=

    while read -r line; do
        mod="${line##*SUSE INITRD: }"
        mod="${mod%% REQUIRES*}"
        reqs="${line##*REQUIRES }"
        if [[ ! $hostonly ]] || grep -q "^$mod\$" "$DRACUT_KERNEL_MODALIASES"
        then
            all_mods="$all_mods $reqs"
        fi
    done <<< "$(grep -h "^# SUSE INITRD: " $(get_modprobe_conf_files))"

    # strip whitespace
    all_mods="$(echo $all_mods)"
    if [[ "$all_mods" ]]; then
        dracut_instmods $all_mods
    fi
}
