#!/bin/sh

get_vmname() {
    local _vmname

    case "$(uname -m)" in
    s390|s390x)
        _vmname=image
        ;;
    ppc*)
        _vmname=vmlinux
        ;;
    aarch64)
        _vmname=Image
        ;;
    armv*)
        _vmname=zImage
        ;;
    *)
        _vmname=vmlinuz
        ;;
    esac

    echo "$_vmname"
}
