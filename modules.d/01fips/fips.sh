#!/bin/bash

command -v getarg > /dev/null || . /lib/dracut-lib.sh
command -v get_vmname > /dev/null || . /lib/fips-lib.sh

# find fipscheck, prefer kernel-based version
fipscheck()
{
    FIPSCHECK=/usr/libexec/libkcapi/fipscheck
    if [ ! -f $FIPSCHECK ]; then
        FIPSCHECK=/usr/lib64/libkcapi/fipscheck
    fi
    if [ ! -f $FIPSCHECK ]; then
        FIPSCHECK=/usr/lib/libkcapi/fipscheck
    fi
    if [ ! -f $FIPSCHECK ]; then
        FIPSCHECK=/usr/bin/fipscheck
    fi
    echo $FIPSCHECK
}

# systemd lets stdout go to journal only, but the system
# has to halt when the integrity check fails to satisfy FIPS.
if [ -z "$DRACUT_SYSTEMD" ]; then
    fips_info() {
        info "$*"
    }
else
    fips_info() {
        echo "$*" >&2
    }
fi

mount_boot() {
    boot=$(getarg boot=)

    if [ -n "$boot" ]; then
        if [ -d /boot ] && ismounted /boot; then
            boot_dev=
            if command -v findmnt > /dev/null; then
                boot_dev=$(findmnt -n -o SOURCE /boot)
            fi
            fips_info "Ignoring 'boot=$boot' as /boot is already mounted ${boot_dev:+"from '$boot_dev'"}"
            return 0
        fi

        case "$boot" in
            LABEL=* | UUID=* | PARTUUID=* | PARTLABEL=*)
                boot="$(label_uuid_to_dev "$boot")"
                ;;
            /dev/*) ;;

            *)
                die "You have to specify boot=<boot device> as a boot option for fips=1"
                ;;
        esac

        if ! [ -e "$boot" ]; then
            udevadm trigger --action=add > /dev/null 2>&1

            i=0
            while ! [ -e "$boot" ]; do
                udevadm settle --exit-if-exists="$boot"
                [ -e "$boot" ] && break
                sleep 0.5
                i=$((i + 1))
                [ $i -gt 40 ] && break
            done
        fi

        [ -e "$boot" ] || return 1

        mkdir -p /boot
        fips_info "Mounting $boot as /boot"
        mount -oro "$boot" /boot || return 1
        FIPS_MOUNTED_BOOT=1
    elif ! ismounted /boot && [ -d "$NEWROOT/boot" ]; then
        # shellcheck disable=SC2114
        rm -fr -- /boot
        ln -sf "$NEWROOT/boot" /boot
    else
        die "You have to specify boot=<boot device> as a boot option for fips=1"
    fi
}

mount_zipl() {
    boot=$(getarg rd.zipl=)

    if [ -d /boot/zipl ] && ismounted /boot/zipl; then
        fips_info "Nothing to do, /boot/zipl is already mounted..."
        return 0
    fi
    if [ -z "$boot" ]; then
        die "You have to specify rd.zipl=<boot device> as a boot option for fips=1"
    fi
    case "$boot" in
        LABEL=* | UUID=* | PARTUUID=* | PARTLABEL=*)
            boot="$(label_uuid_to_dev "$boot")"
            ;;
        /dev/*) ;;

        *)
            die "You have to specify rd.zipl=<boot device> as a boot option for fips=1"
            ;;
    esac
    if ! [ -e "$boot" ]; then
        udevadm trigger --action=add > /dev/null 2>&1

        i=0
        while ! [ -e "$boot" ]; do
            udevadm settle --exit-if-exists="$boot"
            [ -e "$boot" ] && break
            sleep 0.5
            i=$((i + 1))
            [ $i -gt 40 ] && break
        done
    fi

    [ -e "$boot" ] || die "$boot: no such device"

    mkdir -p /boot/zipl || die "Couldn't create mount point for /boot/zipl"
    fips_info "Mounting $boot as /boot/zipl"
    mount -oro "$boot" /boot/zipl || die "Couldn't mount $boot"
    FIPS_MOUNTED_ZIPL=1
}

do_rhevh_check() {
    KERNEL=$(uname -r)
    kpath=${1}

    # If we're on RHEV-H, the kernel is in /run/initramfs/live/vmlinuz0
    HMAC_SUM_ORIG=$(while read -r a _ || [ -n "$a" ]; do printf "%s\n" "$a"; done < "$NEWROOT/boot/.vmlinuz-${KERNEL}.hmac")
    HMAC_SUM_CALC=$(sha512hmac "$kpath" | while read -r a _ || [ -n "$a" ]; do printf "%s\n" "$a"; done || return 1)
    if [ -z "$HMAC_SUM_ORIG" ] || [ -z "$HMAC_SUM_CALC" ] || [ "${HMAC_SUM_ORIG}" != "${HMAC_SUM_CALC}" ]; then
        warn "HMAC sum mismatch"
        return 1
    fi
    fips_info "rhevh_check OK"
    return 0
}

nonfatal_modprobe() {
    modprobe "$1" 2>&1 > /dev/stdout \
        | while read -r line || [ -n "$line" ]; do
            echo "${line#modprobe: FATAL: }" >&2
        done
}

fips_load_crypto() {
    local _k
    local _v
    local _module
    local _found

    read -d '' -r FIPSMODULES < /etc/fipsmodules

    fips_info "Loading and integrity checking all crypto modules"
    for _module in $FIPSMODULES; do
        if [ "$_module" != "tcrypt" ]; then
            if ! nonfatal_modprobe "${_module}" 2> /tmp/fips.modprobe_err; then
                # check if kernel provides generic algo
                _found=0
                while read -r _k _ _v || [ -n "$_k" ]; do
                    [ "$_k" != "name" -a "$_k" != "driver" ] && continue
                    [ "$_v" != "$_module" ] && continue
                    _found=1
                    break
                done < /proc/crypto
                # If we find some hardware specific modules and cannot load them
                # it is not a problem, proceed.
                if [ "$_found" = "0" ]; then
                    # shellcheck disable=SC2055
                    if [    "$_module" != "${_module%intel}"    \
                        -o  "$_module" != "${_module%ssse3}"    \
                        -o  "$_module" != "${_module%x86_64}"   \
                        -o  "$_module" != "${_module%z90}"      \
                        -o  "$_module" != "${_module%s390}"     \
                        -o  "$_module" == "twofish_x86_64_3way" \
                        -o  "$_module" == "ablk_helper"         \
                        -o  "$_module" == "glue_helper"         \
                        -o  "$_module" == "sha1-mb"             \
                        -o  "$_module" == "sha256-mb"           \
                        -o  "$_module" == "sha512-mb"           \
                    ]; then
                        _found=1
                    fi
                fi
                [ "$_found" = "0" ] && cat /tmp/fips.modprobe_err >&2 && return 1
            fi
        fi
    done
    if [ -f /etc/fips.conf ]; then
        mkdir -p /run/modprobe.d
        cp /etc/fips.conf /run/modprobe.d/fips.conf
    fi

    fips_info "Self testing crypto algorithms"
    modprobe tcrypt || return 1
    rmmod tcrypt
}

do_fips() {
    KERNEL=$(uname -r)
    #FIXME: "lib64" might be wrong, but (for now) it's vital only for s390x => good enough
    # (and a symlink from "lib" exists)
    FIPSCHECKDIR=/usr/lib64/fipscheck

    if ! getarg rd.fips.skipkernel > /dev/null; then

        fips_info "Checking integrity of kernel"
        if [ -e "/run/initramfs/live/vmlinuz0" ]; then
            do_rhevh_check /run/initramfs/live/vmlinuz0 || return 1
        elif [ -e "/run/initramfs/live/isolinux/vmlinuz0" ]; then
            do_rhevh_check /run/initramfs/live/isolinux/vmlinuz0 || return 1
        elif [ -e "/run/install/repo/images/pxeboot/vmlinuz" ]; then
            # This is a boot.iso with the .hmac inside the install.img
            do_rhevh_check /run/install/repo/images/pxeboot/vmlinuz || return 1
        else
            BOOT_IMAGE="$(getarg BOOT_IMAGE)"

            # Trim off any leading GRUB boot device (e.g. ($root) )
            # shellcheck disable=SC2001
            BOOT_IMAGE="$(echo "${BOOT_IMAGE}" | sed 's/^(.*)//')"

            BOOT_IMAGE_NAME="${BOOT_IMAGE##*/}"
            BOOT_IMAGE_PATH="${BOOT_IMAGE%"${BOOT_IMAGE_NAME}"}"

            local _vmname
            _vmname=$(get_vmname)

            if [ -z "$BOOT_IMAGE_NAME" ]; then
                BOOT_IMAGE_NAME="${_vmname}-${KERNEL}"
                if getargbool 0 initgrub; then
                    # only needed for zipl booted first stage
                   mount_zipl
                   BOOT_IMAGE_PATH=zipl/
                fi
            elif ! [ -e "/boot/${BOOT_IMAGE_PATH}/${BOOT_IMAGE}" ]; then
                #if /boot is not a separate partition BOOT_IMAGE might start with /boot
                BOOT_IMAGE_PATH=${BOOT_IMAGE_PATH#"/boot"}
                #on some achitectures BOOT_IMAGE does not contain path to kernel
                #so if we can't find anything, let's treat it in the same way as if it was empty
                if ! [ -e "/boot/${BOOT_IMAGE_PATH}/${BOOT_IMAGE_NAME}" ]; then
                    BOOT_IMAGE_NAME="${_vmname}-${KERNEL}"
                    BOOT_IMAGE_PATH=""
                fi
            fi

            BOOT_IMAGE_HMAC="/boot/${BOOT_IMAGE_PATH}.${BOOT_IMAGE_NAME}.hmac"
            if ! [ -e "${BOOT_IMAGE_HMAC}" ]; then
                FCDBIH="${FIPSCHECKDIR}/${_vmname}-${KERNEL}.hmac"
                if [ -r "${FCDBIH}" ]; then
                    BOOT_IMAGE_HMAC="${FCDBIH}"
                else
                    warn "${BOOT_IMAGE_HMAC} does not exist"
                    return 1
                fi
            fi

            BOOT_IMAGE_KERNEL="/boot/${BOOT_IMAGE_PATH}${BOOT_IMAGE_NAME}"
            if ! [ -e "${BOOT_IMAGE_KERNEL}" ]; then
                warn "${BOOT_IMAGE_KERNEL} does not exist"
                return 1
            fi

            # kernel-based fipscheck doesn't respect it's man-page...
            ln -s  "${BOOT_IMAGE_KERNEL}" "/${_vmname}-${KERNEL}"
            ln -sf "${BOOT_IMAGE_HMAC}"   "/.${_vmname}-${KERNEL}.hmac"
            # so base the checks on sym-links in /
            BOOT_IMAGE_KERNEL="/${_vmname}-${KERNEL}"

            if [ -n "$(fipscheck)" ]; then
                $(fipscheck) "${BOOT_IMAGE_KERNEL}" || return 1
            else
                warn "Could not find fipscheck to verify MACs"
                return 1
            fi
        fi
    fi

    fips_info "All initrd crypto checks done"

    : > /tmp/fipsdone

    if [ "$FIPS_MOUNTED_BOOT" = 1 ]; then
        fips_info "Unmounting /boot"
        umount /boot > /dev/null 2>&1
    else
        fips_info "Not unmounting /boot"
    fi
    if [ "$FIPS_MOUNTED_ZIPL" = 1 ]; then
        fips_info "Unmounting /boot/zipl"
        umount /boot/zipl > /dev/null 2>&1
    fi

    return 0
}
