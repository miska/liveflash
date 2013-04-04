#!/bin/bash

# Ask user to select one option
function ask_for_select() {
   local title="$1"
   shift
   dialog --menu "$title" 0 0 $# $@ 2> /tmp/dialog
   target="`cat /tmp/dialog`"
}

function die() {
   systemException "$1" "reboot"
}

function debug_p() {
   [ -z "${DEBUG}" ] || echo "$1"
   LAST_DEBUG="$1"
}

function debug_r() {
   ret="$?"
   debug_p "${LAST_DEBUG} = ${ret}"
   if [ -z "${DEBUG}" ] && [ "${ret}" \!= 0 ]; then
      die "${LAST_DEBUG}"
   fi
}

function clear_prop() {
   echo "" > "${TMP_CFG}"/"${target}"
}

function set_prop() {
   echo "$1=\"$2\"" >> "${TMP_CFG}"/"${target}"
}

TARGETS=""
DEBUG="yes"
TMP_MNT="/var/run/mnt"
TMP_CFG="/var/run/boot-cfg"
TRG_MNT="/mnt"

# Adds iso file as possible target
function add_iso() {
   target="${2}"
   mkdir -p "${TMP_CFG}"
   debug_p "Adding ISO $1 from drive $2..."
   clear_prop
   set_prop 'trg_type' "iso"
   set_prop 'trg_disk' "$1"
   set_prop 'trg_file' "$2"
   mkdir -p "${TMP_MNT}"/cdrom
   debug_p "Mounting ISO ${target} to investigate..."
   mount -o ro,loop "${TMP_MNT}"/usb/openSUSE-Live/"${target}" "${TMP_MNT}"/cdrom
   debug_r
   label="$(sed -n 's|IMAGE='"'"'/dev/ram1;\(.*\)\.[^.]*;[0-9.]*'"'"'|\1|p' "${TMP_MNT}"/cdrom/config.isoclient | head -n1)"
   umount "${TMP_MNT}"/cdrom
   debug_p "Label is ${label}"
   set_prop 'trg_images' "${label}"
   if [ -n "${label}" ]; then
      label="ISO image ${label}"
      set_prop trg_desc "${label}"
      echo "\"${label}\""  >> "${TMP_CFG}"/.descs
      echo "\"${target}\"" >> "${TMP_CFG}"/.trgs
   else
      die "Not SUSE studio ISO!"
   fi
}

# Adds stacked image as possible target
function add_stacked() {
   local target
   target="${2}"
   clear_prop
   set_prop 'trg_type' "stack"
   set_prop 'trg_disk' "$1"
   set_prop 'trg_file' "$2"
   IMAGES=""
   source "${TMP_MNT}"/usb/openSUSE-Live/"$2"
   set_prop trg_images "${IMAGES}"
   set_prop trg_desc   "${DESCRIPTION}"
}


# Prepare to boot iso file
function boot_iso() {
   target="${1}"
   debug_p "Booting ${target}..."
   debug_p "Mounting disk $trg_disk..."
   mount -t auto -o ro "$trg_disk" "${TMP_MNT}"/usb
   debug_r
   debug_p "Mounting ISO itself..."
   mount -o ro,loop "${TMP_MNT}"/usb/openSUSE-Live/"${target}" "${TMP_MNT}"/cdrom
   debug_r
   debug_p "Mounting clicfs $trg_images..."
   mkdir -p "${TMP_MNT}"/clic
   clicfs "${TMP_MNT}"/cdrom/${trg_images}* "${TMP_MNT}"/clic
   debug_r
   mkdir -p "${TMP_MNT}"/ext
   mount -o ro,loop "${TMP_MNT}"/clic/fsdata.ext4 "${TMP_MNT}"/ext
   debug_p "Adding ext to the aufs..."
   mount -o remount,append:"${TMP_MNT}"/ext=rr /mnt
   debug_r
}


# Prepare to boot stacked image
function boot_stacked() {
   target="${1}"
   debug_p "Mounting disk $trg_disk..."
   mount -t auto -o ro,loop "${trg_disk}" "${TMP_MNT}"/usb
   debug_r
   for i in $trg_images; do
      mkdir -p "${TMP_MNT}"/stack-${i}
      debug_p "Mounting image ${i}..."
      mount -o ro,loop "${TMP_MNT}"/usb/openSUSE-Live/"${i}" "${TMP_MNT}"/stack-${i}
      debug_r
      debug_p "Adding image ${i} to aufs..."
      mount -o remount,append:"${TMP_MNT}"/stack-${i}=rr /mnt
      debug_r
   done
}

# Adds something as possible target
function add_smt() {
   case "$2" in
      *.iso)  add_iso     "$1" "$2" ;;
      *.conf) add_stacked "$1" "$2" ;;
      *) die "Something is broken, tried to add $2!";;
   esac
}

# Boot something
function boot_smt() {
   debug_p "Mounitng rw tmpfs..."
   mkdir -p "${TMP_MNT}"/write
   mount -t tmpfs none "${TMP_MNT}"/write
   debug_r
   debug_p "Mounting first rw branch of aufs..."
   mount -t aufs -o rw,br:"${TMP_MNT}"/write=rw none /mnt
   debug_r

   target="${1}"
   . "${TMP_CFG}"/"${target}"
   case $trg_type in
      iso)   boot_iso     "${target}" ;;
      stack) boot_stacked "${target}" ;;
      *) die "Booting $trg_type not implemented yet!";;
   esac
}

mkdir -p ${TMP_MNT}/usb

# Find device we are booting from
for disk in /dev/sd* /dev/sr* /dev/hd*; do
   mount -t auto -o ro "${disk}" "${TMP_MNT}"/usb
   # It has magic directory
   if [ -d "${TMP_MNT}"/usb/openSUSE-Live ]; then
      # Add everything interesting from there
      cd "${TMP_MNT}/usb/openSUSE-Live"
      for config in *.conf *.iso; do
         [ -f "${config}" ] || continue
         add_smt ${disk} ${config}
         if [ -z "${TARGETS}" ]; then
            TARGETS="${config}"
         else
            TARGETS="${TARGETS}$(echo "")${config}"
         fi

      done
   fi
   cd /
   umount "${TMP_MNT}"/usb
done

[ "${TARGETS}" ] || die "Found nothing to boot..."

mount -o bind /lib/modules /mnt/lib/modules

if [ "${TARGETS}" ] && [ "$(echo "${TARGETS}" | wc -l)" -lt 2 ]; then
   boot_smt "${TARGETS}"
fi

imageName="${trg_desc}"

mkdir -p /mnt/mnt/usb
debug_p "Moving mountpoint ${TMP_MNT}/usb into new root..."
mount --move "${TMP_MNT}"/usb  /mnt/mnt/usb
debug_r
debug_p "Moving mountpoint /tmp into new root..."
mount --move /tmp  /mnt/tmp
debug_r
for i in $(cat /proc/mounts | sed -n 's|[^[:blank:]]\+\ \(${TMP_MNT}/[^[:blank:]]*\)\ .*|\1|p'); do
   mkdir -p /mnt/${i}
   debug_p "Moving mountpoint ${TMP_MNT}/${i} into new root..."
   mount --move ${i} /mnt/${i}
   debug_r
done

haveClicFS="yes"

sleep 3

