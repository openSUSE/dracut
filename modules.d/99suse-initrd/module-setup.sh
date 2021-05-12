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
    ls /etc/modprobe.d/*.conf /run/modules.d/*.conf /lib/modules.d/*.conf \
       2>/dev/null
    return 0
}

# called by dracut
installkernel() {
    local line mod reqs all_mods=
    local BUILT_IN_PATH="/lib/modules/$(uname -r)/modules.builtin"

    while read -r line; do
        mod="${line##*SUSE INITRD: }"
        mod="${mod%% REQUIRES*}"
        reqs="${line##*REQUIRES }"
        if [[ ! $hostonly ]] || grep -q "^$mod\$" "$DRACUT_KERNEL_MODALIASES"
        then
            for module in $reqs
            do
                if ! grep -q "/$module.ko" $BUILT_IN_PATH
                then
                    # The module is not built-in, so we can safely add it
                    all_mods="$all_mods $module"
                fi
            done
        fi
    done <<< "$(grep -h "^# SUSE INITRD: " $(get_modprobe_conf_files))"

    # strip whitespace
    all_mods="$(echo $all_mods)"
    if [[ "$all_mods" ]]; then
        dracut_instmods $all_mods
    fi
}
