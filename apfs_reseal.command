#!/bin/sh -e

while true; do
    case $1 in
        --clean)
            clean=1
            shift
            ;;
        --debug)
            set -x
            debug=1
            shift
            ;;
        --erase)
            echo '[!] WARNING: You have requested to erase the device.' >&2
            echo '[!] THIS WILL IRRECOVERABLY DELETE ALL YOUR DATA.'
            echo '[!] Do not do this unless you know what you are doing.' >&2
            echo '[!] Make sure you have a backup if you have any important data on the device.' >&2
            echo '[!] Please type "Yes, I am sure" (without quotes) if you want to continue.' >&2
            echo
            printf '> ' >&2
            read -r
            echo
            if [ "$REPLY" != 'Yes, I am sure' ]; then
                echo 'Aborting.'
                exit 1
            fi
            erase=1
            shift
            ;;
        --*)
            echo "[-] Unrecognized option: $1" >&2
            exit 1
            ;;
        *)
            break
    esac
done

uname=$(uname)

remote_cmd() {
    echo "[*] Running command: $1" >&2
    sshpass -p alpine ssh -q -o ProxyCommand='inetcat 22' -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@ "$1"
}

remote_cp() {
    echo "[*] Transferring file: $1 -> $2" >&2

    if scp -O /dev/null /dev/zero 2>/dev/null; then
        scp='scp -O'
    else
        scp='scp'
    fi

    expect -c 'set timeout -1' \
           -c "spawn $scp -o \"ProxyCommand=inetcat 22\" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -r \"$1\" \"root@:$2\"" \
           -c 'expect "assword:"' \
           -c 'send "alpine\n"' \
           -c 'expect eof'
}

plist2json() {
    python3 -c "import base64, json, plistlib, sys; print(json.dumps(plistlib.loads(sys.stdin.buffer.read()), default=lambda x: base64.b64encode(x).decode() if isinstance(x, bytes) else x))"
}

do_remotezip() {
    delay=5
    for i in $(seq 1 5); do
        if remotezip "$@"; then
            return 0
        else
            echo "[!] remotezip failed, retrying in $delay seconds"
            sleep "$delay"
            delay=$(( delay * 2 ))
        fi
    done
    # If we got here, it failed
    return 1
}

if [ "$uname" = Darwin ]; then
    trap 'killall -CONT AMPDevicesAgent AMPDeviceDiscoveryAgent iTunesHelper MobileDeviceUpdater' EXIT
fi

for bin in awk expect ideviceenterrecovery irecovery jq palera1n pyimg4 python3 remotezip scp ssh sshpass; do
    if ! [ -x "$(command -v "$bin")" ]; then
        echo "[!] $bin not found. Please install it and try again." >&2
        exit 1
    fi
done

version=$1
if [ -z "$version" ]; then
    printf 'Enter your EXACT iOS version (including beta/RC): ' >&2
    read -r version
    echo
fi

if [ "$uname" = Darwin ]; then
    killall -STOP AMPDevicesAgent AMPDeviceDiscoveryAgent iTunesHelper MobileDeviceUpdater
fi

case $version in
    14.[2-8]*|14.[2-8].*)
        echo '[!] WARNING: You appear to be using iOS 14.'
        echo '[!] This script is not really needed on that version and it is untested.' >&2
        echo '[!] Please type "Yes, I am sure" (without quotes) if you want to continue.' >&2
        echo
        printf '> ' >&2
        read -r
        echo
        if [ "$REPLY" != 'Yes, I am sure' ]; then
            echo 'Aborting.'
            exit 1
        fi

        ramdisk_ver=14.8
        ;;
    15.*)
        ramdisk_ver=15.6
        ;;
    16.[0-3]|16.[0-3].*)
        ramdisk_ver=16.0.3
        ;;
    *)
        echo '[-] This script only supports iOS 14.2-16.3.1.' >&2
        exit 1
        ;;
esac

echo '[*] Waiting for device'
while true; do
    if [ "$uname" = Darwin ]; then
        devices=$(system_profiler SPUSBDataType | grep -B1 'Vendor ID: 0x05ac')
        serials=$(system_profiler SPUSBDataType | grep 'Serial Number')
    else
        devices=$(lsusb | grep '05ac:')
        serials=$(cat /sys/bus/usb/devices/*/serial)
    fi

    case $serials in
        *SSHRD_Script*)  # ramdisk
            device=$(remote_cmd "/usr/bin/mgask ProductType | tail -1")
            boardconfig=$(remote_cmd "/usr/bin/mgask HWModelStr | tail -1" | tr '[:upper:]' '[:lower:]')

            echo "Detected $device ($boardconfig)"

            remote_cmd "/usr/sbin/nvram auto-boot=false"

            break
            ;;
    esac

    case $devices in
        *12a[8ab]*)  # normal
            ideviceenterrecovery "$(idevice_id -l)"
            while ! irecovery -q >/dev/null 2>/dev/null; do
                sleep 0.1
            done
            ;;
        *1281*)  # recovery
            palera1n --dfuhelper
            ;;
        *1227*)  # DFU
            while ! irecovery -q >/dev/null 2>/dev/null; do
                sleep 0.1
            done

            device=$(irecovery -q | awk -F ': ' '$1 == "PRODUCT" { print $2 }')
            boardconfig=$(irecovery -q | awk -F ': ' '$1 == "MODEL" { print $2 }')

            echo "Detected $device ($boardconfig)"

            irecovery -c 'setenv auto-boot false'
            irecovery -c 'saveenv'

            if ! [ -e sshrd-script ]; then
                git clone https://github.com/0xallie/sshrd-script
            fi
            cd sshrd-script
            git fetch
            git reset --hard origin/main
            git submodule update --init --force
            if [ "$debug" = 1 ]; then
                bash -x ./sshrd.sh clean
                bash -x ./sshrd.sh "$ramdisk_ver"
                bash -x ./sshrd.sh boot
            else
                ./sshrd.sh clean
                ./sshrd.sh "$ramdisk_ver"
                ./sshrd.sh boot
            fi
            cd "$OLDPWD"

            break
            ;;
    esac

    sleep 1
done

case $version in
    1[45].*)
        container=/dev/disk0s1
        ;;
    16.*)
        container=/dev/disk1
        ;;
esac
rootfs=${container}s1

if [ "$clean" = 1 ]; then
    rm -rf -- *.dmg apfs_invert_asr_img Firmware manifest_and_db* sshrd-script
    if remote_cmd "test -e $rootfs"; then
        remote_cmd "/sbin/umount -f /mnt1" || true
        remote_cmd "/sbin/mount_apfs $rootfs /mnt1"
        remote_cmd "/bin/rm -f /mnt1/apfs_invert_asr_img"
        remote_cmd "/sbin/umount -f /mnt1"
    fi
    echo '[*] Cleaned temporary files'
    exit
fi

ipsw_url=$(curl -s https://api.appledb.dev/main.json | jq --arg device "$device" --arg version "$version" -r '[.ios[] | select(.version == $version and (.deviceMap | index($device)))][0] | .devices[$device].ipsw')
if [ -z "$ipsw_url" ] || [ "$ipsw_url" = null ]; then
    echo "[-] Failed to get IPSW URL for $device on $version" >&2
    exit 1
fi

rootfs_dmg=$(curl -s "${ipsw_url%/*}/BuildManifest.plist" | sed 's,<data>,<string>,g; s,</data>,</string>,g' | plist2json | jq -r --arg boardconfig "$boardconfig" '[.BuildIdentities[] | select(.Info.DeviceClass == $boardconfig)][0].Manifest.OS.Info.Path')

if ! [ -e "$rootfs_dmg" ] && ! [ -e apfs_invert_asr_img ]; then
    do_remotezip "$ipsw_url" "$rootfs_dmg"
fi
if ! [ -e "Firmware/$rootfs_dmg.mtree" ] && ! [ -e manifest_and_db ]; then
    do_remotezip "$ipsw_url" "Firmware/$rootfs_dmg.mtree"
fi
if ! [ -e "Firmware/$rootfs_dmg.root_hash" ]; then
    do_remotezip "$ipsw_url" "Firmware/$rootfs_dmg.root_hash"
fi

if [ ! -e manifest_and_db/digest.db ] || [ ! -e manifest_and_db/mtree.txt ]; then
    pyimg4 im4p extract -i "Firmware/$rootfs_dmg.mtree" -o manifest_and_db.aar
    mkdir -p manifest_and_db
    cd manifest_and_db
    if [ -x "$(command -v aa)" ]; then
        aa extract -i ../manifest_and_db.aar
    elif [ -x "$(command -v yaa)" ]; then
        yaa extract -i ../manifest_and_db.aar
    else
        echo '[-] aa or yaa not found, cannot extract archive.'
        exit 1
    fi
    cd "$OLDPWD"
fi

if ! [ -e apfs_invert_asr_img ]; then
    asr -source "$rootfs_dmg" -target apfs_invert_asr_img --embed -erase -noprompt --chunkchecksum
fi
rm -f "$rootfs_dmg"

echo '[*] Waiting for device to connect'
while ! remote_cmd "echo connected" >/dev/null 2>&1; do
    sleep 0.1
done
echo '[*] Connected'
remote_cmd "/sbin/umount -f /mnt*" || true
if remote_cmd "test -e $rootfs"; then
    remote_cmd "/sbin/mount_apfs $rootfs /mnt1"
    if ! remote_cmd "test -e /mnt1/apfs_invert_asr_img"; then
        remote_cmd "/sbin/umount -f /mnt1"
        remote_cmd "/sbin/apfs_deletefs $rootfs"
        remote_cmd "/sbin/newfs_apfs -o role=s -A -v System $container"
        remote_cmd "/sbin/mount_apfs $rootfs /mnt1"
    fi
else
    remote_cmd "/sbin/newfs_apfs -o role=s -A -v System $container"
    remote_cmd "/sbin/mount_apfs $rootfs /mnt1"
fi
if ! remote_cmd "test -e /mnt1/apfs_invert_asr_img"; then
    remote_cp apfs_invert_asr_img /mnt1/apfs_invert_asr_img
fi
remote_cmd "/sbin/umount -f /mnt1"
remote_cmd "/System/Library/Filesystems/apfs.fs/apfs_invert -d $container -s 1 -n apfs_invert_asr_img"
remote_cmd "/sbin/mount_tmpfs /mnt9"
remote_cp manifest_and_db /mnt9/manifest_and_db
remote_cp "Firmware/$rootfs_dmg.root_hash" /mnt9/root_hash
for i in $(seq 3 7); do
    fs=${container}s$i
    if [ "$(remote_cmd "/System/Library/Filesystems/apfs.fs/apfs.util -p $fs")" = "Preboot" ]; then
        remote_cmd "/sbin/mount_apfs $fs /mnt6"
        found_preboot=1
        break
    fi
done
if [ "$found_preboot" != 1 ]; then
    echo '[-] Unable to find Preboot volume'
    exit 1
fi
active=$(remote_cmd "/bin/cat /mnt6/active")
remote_cmd "/sbin/umount -f /mnt6"
remote_cmd "/sbin/mount_apfs $rootfs /mnt1"
remote_cmd "/usr/sbin/mtree -p /mnt1 -m /mnt9/mtree_remap.xml -f /mnt9/manifest_and_db/mtree.txt -r"
remote_cmd "/sbin/umount -f /mnt1"
remote_cmd "/System/Library/Filesystems/apfs.fs/apfs_sealvolume -P -R /mnt9/mtree_remap.xml -I /mnt9/root_hash -u /mnt9/manifest_and_db/digest.db -p -s com.apple.os.update-$active $rootfs"
remote_cmd "/sbin/mount_apfs $rootfs /mnt1"
remote_cmd "/sbin/umount -f /mnt9"
remote_cmd "/bin/sync"
if [ "$erase" = 1 ]; then
    remote_cmd "/usr/sbin/nvram oblit-inprogress=5"
fi
remote_cmd "/usr/sbin/nvram auto-boot=true"
remote_cmd "/sbin/reboot"
case $version in
    1[45].*)
        echo '[*] Done! Your device should now boot up in normal mode.'
        ;;
    16.*)
        echo '[*] Done! Please force reboot your device, then it should boot up in normal mode.'
        ;;
esac
echo '[*] Press Enter to exit'
read -r
