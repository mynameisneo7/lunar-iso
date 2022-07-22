#!/bin/bash
#############################################################
#                                                           #
# portions Copyright 2001 by Kyle Sallee                    #
# portions Copyright 2002 by Kagan Kongar                   #
# portions Copyright 2002 by rodzilla                       #
# portions Copyright 2003-2004 by tchan, kc8apf             #
# portions Copyright 2004-2007 by Auke Kok                  #
# portions Copyright 2008-2017 by Stefan Wold               #
#                                                           #
#############################################################
#                                                           #
# This file in released under the GPLv2                     #
#                                                           #
#############################################################

pkg_avail()
{
  grep -q "^$1:" $PACKAGES_LIST
}


msgbox()
{
  LINES=$(( ${#1} / 55 + 7 ))
  $DIALOG --cr-wrap --msgbox "$1" $LINES 60
}


inputbox()
{
  $DIALOG --nocancel --inputbox "$1" 0 0 "$2"
}


confirm()
{
  if [ "$CONFIRM" == "off" ]; then
    if [ -n "$2" ]; then
      false
    else
      true
    fi
  else
    $DIALOG $2 --yesno "$1" 9 60
  fi
}


chroot_run()
{
  local RESULT
  mount --bind /proc $TARGET/proc
  mount --bind /dev $TARGET/dev
  mount --bind /tmp $TARGET/tmp
  mount --bind /sys $TARGET/sys
  mount --bind /run $TARGET/run
  if mountpoint -q /sys/firmware/efi/efivars; then
    mount --bind /sys/firmware/efi/efivars $TARGET/sys/firmware/efi/efivars
  fi
  if [ -n "$USE_SWAP" ]; then
    chroot $TARGET swapon -a
  fi
  if [ -n "$USE_CLEAR" ]; then
      clear
  fi
  chroot $TARGET "$@"
  RESULT=$?
  if [ -n "$USE_SWAP" ]; then
    chroot $TARGET swapoff -a
  fi
  umount $TARGET/run
  if mountpoint -q $TARGET/sys/firmware/efi/efivars; then
    umount $TARGET/sys/firmware/efi/efivars
  fi
  umount $TARGET/sys
  umount $TARGET/tmp
  umount $TARGET/dev
  umount $TARGET/proc

  # debug the problem in case there is one
  if [ $RESULT == 1 ] ; then
    (
    echo ""
    echo "ERROR: An error occurred while executing a command. The command was:"
    echo "ERROR: \"$@\""
    echo "ERROR: "
    echo "ERROR: You should inspect any output above and retry the command with"
    echo "ERROR: different input or parameters. Please report the problem if"
    echo "ERROR: you think this error is displayed by mistake."
    echo ""
    echo "Press ENTER to continue"
    read JUNK
    ) >&2
  fi
  return $RESULT
}


goodbye()
{
  PROMPT="Reboot now?"
  if confirm "$PROMPT" "--defaultno"; then
    kill `jobs -p` &> /dev/null
    shutdown -r now
    exit 0
  else
    # bump the init level so we can exit safely!
    systemctl isolate multi-user.target
    exit 0
  fi
}


introduction()
{
  $DIALOG --textbox /README 0 0
  I_OK="\\Z2"
  if (( STEP == 1 )); then
    (( STEP++ ))
  fi
  DEFAULT=C
}


show_modules()
{
  if [ "$(pwd)" != "/lib/modules" ]; then
    echo ".."
    echo "Directory"
  fi
  for ITEM in *; do
    case $ITEM in
      modules.*) continue ;;
    esac
    /bin/echo "$ITEM"
    if [ -d "$ITEM" ]; then
      /bin/echo "Directory"
    else
      /bin/echo "Module"
    fi
  done
}


load_module()
{
  (
  MODULES_ROOT="/lib/modules"
  cd $MODULES_ROOT/$(uname -r)/kernel/drivers
  TITLE="Module Menu"
  HELP="Select a module to load or enter a subdirectory (pwd = $(pwd))"
  CHOICE=""

  while true; do
    MODULES=$(show_modules $(pwd))
    CHOICE=$($DIALOG --title "$TITLE" --cancel-label "Exit" --menu "$HELP" 0 0 0 $MODULES)
    if [ $? != 0 ]; then
      return
    fi
    if [ -f "$CHOICE" ]; then
      MODULE=$(basename $CHOICE | sed "s/\.o$//;s/\.ko$//")
      PARAMETERS=$(inputbox "Enter module parameters (optional)") &&
      modprobe $MODULE $PARAMETERS
      sleep 1
      if ! grep -qw $MODULE /proc/modules ; then
        msgbox "The module failed to load!"
      else
        block_devices init
      fi
    elif [ -d "$CHOICE" ]; then
      cd "$CHOICE"
    fi
  done
  )
}


nice_size()
{
  echo $1 | sed -e 's/\(.*[0-9]\)\([0-9]\)\([0-9]\)\([0-9]$\)/\1.\2KB/' -e 's/\(.*[0-9]\)\([0-9]\)\([0-9]\)\([0-9]\)\(\.[0-9]KB$\)/\1.\2MB/' -e 's/\(.*[0-9]\)\([0-9]\)\([0-9]\)\([0-9]\)\(\.[0-9]MB$\)/\1.\2GB/'
}


block_devices()
{
  local N DEVICE
  # superfunction to maintain, list, edit partitions and discs
  case $1 in
    init)
      # do we really need to re-do this? it's slow...
      if [ "$(md5sum /proc/partitions)" != "$PROC_PARTITIONS_MD5" ]; then
        # remove all old disc/part devices
        unset DEVICES
        # fill the list with devices
        for DEVICE in $(list_block_devices); do
          block_devices add $DEVICE
        done
        # and store the checsum for later
        PROC_PARTITIONS_MD5="$(md5sum /proc/partitions)"
      fi
      ;;
    add)
      DEVICES=( ${DEVICES[@]} $2 )
      # add a device to the list
      ;;
    use)
      # tag a device as used
      for (( N=0; N<${#DEVICES[@]} ; N++ )); do
        if [ "$2" == "$(echo ${DEVICES[$N]} | cut -d: -f1)" ]; then
          DEVICES[$N]="$(echo ${DEVICES[$N]} | cut -d: -f1,2):used"
        fi
      done
      ;;
    free)
      # untag a previously used device as used
      for (( N=0; N<${#DEVICES[@]} ; N++ )); do
        if [ "$2" == "$(echo ${DEVICES[$N]} | cut -d: -f1)" ]; then
          DEVICES[$N]="$(echo ${DEVICES[$N]} | cut -d: -f1,2)"
        fi
      done
      ;;
    list)
      # list all unused devices of type $2
      for (( N=0; N<${#DEVICES[@]} ; N++ )); do
        if [ "$2" == "$(echo ${DEVICES[$N]} | cut -d: -f2)" ] &&
            [ -z "$(echo ${DEVICES[$N]} | cut -d: -f3)" ]; then
          echo ${DEVICES[$N]} | cut -d: -f1
        fi
      done
      ;;
    listall)
      # list all devices of type $2
      for (( N=0; N<${#DEVICES[@]} ; N++ )); do
        if [ "$2" == "$(echo ${DEVICES[$N]} | cut -d: -f2)" ]; then
          echo ${DEVICES[$N]} | cut -d: -f1
        fi
      done
      ;;
  esac
}


list_block_devices()
{(
  local DEVICE TYPE
  export IFS=$' \t\n'

  lsblk -o NAME,TYPE -p -n --raw -I 3,8,9 | while read DEVICE TYPE; do
    if [[ "$TYPE" == "disk" || "$TYPE" == "part" ]]; then
      echo $DEVICE:$TYPE
    else
      echo $DEVICE:other
    fi
  done
  export IFS=$'\t\n'
)}


menu_list_devices()
{
  local DEVICE
  for DEVICE in $(block_devices list part; block_devices list disk; block_devices list other); do
    echo $DEVICE
    echo "Block device"
  done
}

menu_list_targets()
{
  local DEVICE FBLKS FSIZE PTYPE FSTYPE MNTPNT N
  for DEVICE in $(block_devices listall part; block_devices listall other); do
    if [ -e $DEVICE ]; then
      FBLKS=$(sfdisk -s $DEVICE)
      if (( FBLKS <= 10 )) ; then
        # this prevents listing EXTENDED partitions
        continue
      fi
      FSIZE=$(nice_size `fdisk -l $DEVICE 2>&1 | grep ^Disk | grep bytes | awk '{print $5}'`)
      echo $DEVICE

      PTYPE=$(file -Ls $DEVICE 2>&1 | cat)
      case $PTYPE in
        *ext4*) PTYPE="(ext4)" ;;
        *ext3*) PTYPE="(ext3)" ;;
        *ext2*) PTYPE="(ext2)" ;;
        *XFS*) PTYPE="(XFS)" ;;
        *Minix*) PTYPE="(minix)" ;;
        *BTRFS*) PTYPE="(btrfs)" ;;
        *FAT*) PTYPE="(FAT/FAT32)" ;;
        *) PTYPE="(unknown)" ;;
      esac

      for (( N=0 ; N<${#PARTITIONS[@]} ; N++ )); do
        if [ "$(echo ${PARTITIONS[$N]} | cut -d: -f1)" == "$DEVICE" ]; then
          FSTYPE=$(echo ${PARTITIONS[$N]} | cut -d: -f3)
          MNTPNT=$(echo ${PARTITIONS[$N]} | cut -d: -f2)
          FSTYPE=${FSTYPE/none/swap}
          echo "$MNTPNT partition, size $FSIZE, [$FSTYPE]"
          continue 2
        fi
      done
      echo "unassigned, size $FSIZE, $PTYPE"
    fi
  done
}


menu_select_device()
{
  local TITLE HELP DEVICE
  TITLE="Device Selection Menu"
  HELP="Please select a block device"
  DEVICE=$($DIALOG --title "$TITLE" --cancel-label "Exit" --menu "$HELP" 0 0 0 `menu_list_devices` "New" "Add an unlisted device to this list...")
  if [ "$DEVICE" == "New" ]; then
    DEVICE=$(inputbox "Enter special device node" "/dev/")
    if [ ! -b $(readlink -f $DEVICE) ]; then
      msgbox "Device $DEVICE does not exist or is not a valid device node. Perhaps you need to load a kernel module or start a subsystem first?"
      unset DEVICE
    elif echo ${SPECIAL_DEVICES[@]} | grep -qw $DEVICE ; then
      msgbox "Device $DEVICE was already added!"
      unset DEVICE
    else
      block_devices add "$DEVICE:other"
    fi
  fi
  echo $DEVICE
}


menu_get_partition()
{
  local TITLE HELP PART
  TITLE="Partition Selection Menu"
  HELP="Please select a partition"
  PART=$($DIALOG --title "$TITLE" --ok-label "Edit" --cancel-label "Done" --menu "$HELP" 0 0 0 `menu_list_targets` "New" "Add an unlisted device to this list...")
  if [ $? != 0 ]; then
    return 1
  fi
  if [ "$PART" == "New" ]; then
    PART=$(inputbox "Enter special device node" "/dev/")
    if [ ! -b $(readlink -f $PART) ]; then
      msgbox "Device $PART does not exist or is not a valid device node. Perhaps you need to load a kernel module or start a subsystem first?"
      unset PART
    elif echo ${SPECIAL_DEVICES[@]} | grep -qw $PART ; then
      msgbox "Device $PART was already added!"
      unset PART
    else
      block_devices add "$PART:other"
    fi
  fi
  echo $PART
}


menu_list_discs()
{
  for DISC in $(block_devices listall disk); do
    echo $DISC
    echo "disk"
  done
}


menu_get_disc()
{
  TITLE="Disk Selection Menu"
  HELP="Please select a disk"
  $DIALOG --title "$TITLE" --menu "$HELP" 0 0 0 $(menu_list_discs)
}


menu_get_filesystem()
{
  TITLE="Filesystem Selection Menu"
  HELP="Please select a filesystem. A '*' means that this is a journalling filesystem, which provides better data security against system crashes etc."

  EXT4="Fourth Extended file system (*)"
  BTRFS="BTree file system (*)"
  EXT3="Third Extended file system (*)"
  EXT2="Second Extended file system"
  REISER="Reiserfs file system (*)"
  XFS="XFS file system (*)"
  JFS="JFS file system (*)"
  VFAT="FAT32 file system"
  SWAP="Swap (Virtual memory or paging filesystem)"

  $DIALOG --title "$TITLE" --default-item "ext4" --menu "$HELP" 0 0 0 \
    "ext4"      "$EXT4"    \
    "btrfs"     "$BTRFS"   \
    "ext3"      "$EXT3"    \
    "ext2"      "$EXT2"    \
    "xfs"       "$XFS"     \
    "vfat"      "$VFAT"    \
    "swap"      "$SWAP"
}


show_keymaps()
{
  KEYDIR="/usr/share/kbd/keymaps/i386"

  azerty="$(ls $KEYDIR/azerty)"
  colemak="$(ls $KEYDIR/colemak)"
  dvorak="$(ls $KEYDIR/dvorak)"
  fgGIod="$(ls $KEYDIR/fgGIod)"
  olpc="$(ls $KEYDIR/olpc)"
  qwerty="$(ls $KEYDIR/qwerty)"
  qwertz="$(ls $KEYDIR/qwertz)"

  MAP_FILES=$(echo -e "$azerty\n$colemak\n$dvorak\n$fgGIod\n$olpc\n$qwerty\n$qwertz" | sort | sed "s/\.kmap\.gz//")

  for MAP in $MAP_FILES; do
    echo ${MAP%.map.gz}
    echo keymap
  done
}


keymap_menu()
{
  TITLE="Keymap Selection Menu"
  HELP="Please select your preferred keymapping."
  KEYMAPS=$(show_keymaps)
  DEFAULT=${KEYMAP:-defkeymap}
  KEYMAP=`$DIALOG --title "$TITLE" --default-item "$DEFAULT" --menu "$HELP" 0 0 0 $KEYMAPS`
  if [ -n "$KEYMAP" ]; then
    loadkeys $KEYMAP
  fi
  C_OK=\\Z2
  DEFAULT=D
}

show_timezones()
{
    for ITEM in `LANG=C ls --hide=[a-z]* $LOCALTIME/$1`; do
        echo "$ITEM"
        if [ -d $LOCALTIME/$1/$ITEM ]; then
            echo "Directory"
        else
            echo "Timezone"
        fi
    done
}

timezone_menu()
{
    LOCALTIME=/usr/share/zoneinfo
    TITLE="Time Zone Selection Menu"
    HELP="Select timezone or directory"
    ZONE=""

    local ZDIR

    while
      TIMEZONES=`show_timezones ${ZDIR:-$ZONE}`  &&
      if [ -n "$ZDIR" ]; then
        T="$TITLE - $ZDIR"
      fi
      ZONE=`$DIALOG  --title  "${T:-$TITLE}"  \
                     --menu             \
                     "$HELP"            \
                     0 0 0              \
                     $TIMEZONES`        &&
      [[ -d $LOCALTIME/$ZDIR/$ZONE || -d $LOCALTIME/$ZONE ]] &&
      ZDIR+="$ZONE/"
      do
        true
    done

    if [ -n "$ZDIR" ]; then
      ZONE="$ZDIR$ZONE"
    fi

    if [ -f "$LOCALTIME/$ZONE" ]; then
      TZ=$ZONE
    fi

    A_OK=\\Z2
    DEFAULT=J
}

partition_discs()
{
  CFDISK="Curses based disk partition table manipulator"
  FDISK="Partition table manipulator"
  PARTED="Create, destroy, resize, and copy partitions"
  HELP="Please create a boot and root partition."
  TITLE="Partitioning Menu"

  DISC=$(menu_get_disc) &&
  PROG=`$DIALOG --title "$TITLE" --menu "$HELP" 0 0 0  \
          "cfdisk"  "$CFDISK"                          \
          "fdisk"   "$FDISK"                           \
          "parted"  "$PARTED"` &&
  PROMPT="Are you certain that you want to run $PROG on $DISC? (This will erase any partition selection you might have already performed)" &&
  if confirm "$PROMPT"; then
    unset PARTITIONS
    $PROG $DISC
    # regenerate list of block devices
    block_devices init
    if (( STEP == 3 )); then
      (( STEP++ ))
    fi
    P_OK=\\Z2
  fi
}


check_partition()
{
  PROMPT="Check for errors?"
  case $1 in
    ext2|ext3|ext4|swap)
      if confirm "$PROMPT" "--defaultno"; then
        echo "-c";
      fi
      ;;
    *)
      true
      ;;
  esac
}


select_swap_file()
{
  LOCATION_PROMPT="Please enter the location for the swapfile."
  SIZE_PROMPT="Enter the size (in MB) of the swapfile you want to generate. It is recommended make it twice the amount of physical RAM. TMPFS users will need more swap (typically 1000MB)."

  SWAPFILE=$(inputbox "$LOCATION_PROMPT" "/swapfile") &&
  if [ -n "$SWAPFILE" ]; then

    # strange calc. but it ends up being ~ 2xRAM rounded up to 256MB blocks
    SWAPSIZE=$(grep MemTotal: /proc/meminfo | awk '{print $2}' | sed 's/[0-9][0-9][0-9]$//') &&
    (( SWAPSIZE = ( ( SWAPSIZE / 128 ) + 1 ) * 256 )) &&

    SWAPSIZE=$(inputbox "$SIZE_PROMPT" "$SWAPSIZE")
    if [ -n "$SWAPSIZE" ]; then
      S_OK=\\Z2
    else
      unset SWAPFILE SWAPSIZE
    fi
  fi
  if (( STEP == 5 )); then
    (( STEP++ ))
  fi
}


determine_mount_opts()
{
  # Check for TRIM support
  if hdparm -I $1 | grep -q TRIM; then
    if [ "$2" == "swap" ]; then
      echo "defaults,discard"
    else
      if [[ "$2" =~ (ext4|btrfs|xfs) ]]; then
        echo "defaults,noatime,discard"
      else
        echo "defaults,noatime"
      fi
    fi
  else
    echo "defaults"
  fi
}

determine_fsck_pass()
{
  if [ "$1" == "swap" ]; then
    echo "0"
  else
    if [ "$2" == "/" ]; then
      echo "1"
    else
      echo "2"
    fi
  fi
}


get_mount_point()
{
  local POINT ROOT_H BOOT_H HOME_H USR_H VAR_H SRV_H OPT_H LOCAL_H C_H

  ROOT_H="The root file system"
  BOOT_H="Kernels and static files for the boot loader"
  HOME_H="User home directories"
  USR_H="Static data"
  VAR_H="Variable data (logs, tarball cache etc)"
  SRV_H="Data for services"
  OPT_H="Add-on application software packages (legacy)"
  LOCAL_H="Local hierarchy"
  C_H="Enter mount point manually"

  if [ "$1" == "swap" ]; then
    echo "swap"
  else
    POINT=$($DIALOG --title "Select a mount point" --menu "" 0 0 0 \
      "/"          "$ROOT_H" \
      "/boot"      "$BOOT_H" \
      "/home"      "$HOME_H" \
      "/usr"       "$USR_H" \
      "/var"       "$VAR_H" \
      "/srv"       "$SRV_H" \
      "/opt"       "$OPT_H" \
      "/usr/local" "$LOCAL_H" \
      "C"          "$C_H")
    if [ "$POINT" = "C" ]; then
      POINT=$(inputbox "Please enter a mount point" "")
    fi
    if [ -z "$POINT" -a -z "$ROOT" ]; then
      echo "/"
    else
      echo "$POINT"
    fi
  fi
}


get_raid_level()
{
  LEVEL=`$DIALOG --menu "Select a raid level" 0 0 0 \
      "linear" "append discs to make one large device" \
      "0" "Striping - increase performance" \
      "1" "Mirrorring - 100% redundancy" \
      "5" "Large and safe - high performance and redundancy" \
      "6" "Extends 5 - adds more overhead but more redundancy too"`
  echo $LEVEL
}


enum_discs()
{
  for DISC in $(echo $1 | sed 's/,/\t/g') ; do
    echo $DISC
    echo $2
  done
}


list_raid_arrays()
{
  for RAIDARRAY in ${RAIDARRAYS[@]}; do
    echo $RAIDARRAY | cut -d: -f1
    echo "level $(echo $RAIDARRAY | cut -d: -f2) raid array"
  done

}


raid_setup()
{
  # raid array record looks like:
  # device:level:device,device,device:sparedevice,sparedevice,chunksize
  # device = { md0 md1 md2 ... }
  # level = { lineair 0 1 4 5 }
  # device = { hda1, hdb, loop/0 md0 ... }
  # sparedevice = { ^^device^^ }
  # chunksize = n (kb)
  # attempt to setup raid arrays
  while true; do
    RCHOICE=`$DIALOG --cancel-label "Exit" --menu "Select an option" 0 0 0 \
      $(list_raid_arrays) \
      "Create" "Create a new RAID array"`
    if [ $? != 0 ] ; then
      break
    fi
    case $RCHOICE in
      md*)
        # don't edit started arrays anymore
        if grep -qw $RCHOICE /proc/mdstat; then
          msgbox "RAID Array $RCHOICE is already started. You cannot edit the array anymore after starting it."
          continue
        fi
        # edit the array
        while true ;do
          for (( N=0 ; N<${#RAIDARRAYS[@]} ; N++ )); do
            if [ "$RCHOICE" == "$(echo ${RAIDARRAYS[$N]} | cut -d: -f1)" ]; then
              break
            fi
          done
          RAIDARRAY=${RAIDARRAYS[$N]}
          ARRAYNAME=$(echo $RAIDARRAY | cut -d: -f1)
          LEVEL=$(echo $RAIDARRAY | cut -d: -f2)
          DISCS=$(echo $RAIDARRAY | cut -d: -f3)
          SPARE=$(echo $RAIDARRAY | cut -d: -f4)
          RRCHOICE=`$DIALOG --cancel-label "Exit" --menu "Select an option" 0 0 0 \
            "Add disc" "Add a disk to the array" \
            "Add spare" "Add a spare disk to the array" \
            $([ -n "$DISCS" ] && enum_discs $DISCS "RAID array member") \
            $([ -n "$SPARE" ] && enum_discs $SPARE "Spare disc") \
            "start" "Initialize and start the array" \
            `
          if [ $? != 0 ]; then
            break
          fi
          if [ "$RRCHOICE" == "Add disc" -o "$RRCHOICE" == "Add spare" ] ; then
            NEW=$(menu_select_device)
            if [ -n "$NEW" ]; then
              if [ "$RRCHOICE" == "Add disc" ] ; then
                DISCS=$(echo "$DISCS,$NEW" | sed -e 's/^,//')
              else # if [ "$RRCHOICE" == "Add spare" ] ; then
                SPARE=$(echo "$SPARE,$NEW" | sed -e 's/^,//')
              fi
              block_devices use $NEW
              if [ "$(fdisk -l ${NEW/[0-9]*/} | sed 's/\*/ /' | grep "^$NEW" | awk '{print $5}')" != "fd" ]; then
                msgbox "The partition type of this device is not 0xFD (Linux RAID Autodetect). You should correct this in the partition table with a partitioning tool, otherwise linux will not automatically enable this RAID array at boot."
              fi
            fi
          elif [ "$RRCHOICE" == "start" ] ; then
            # Ask for metadata version
            METADATA=$($DIALOG --title " Choose metadata version " --menu "" 0 0 0 \
                       "0.90" "Use with LILO bootloader" \
                       "1.0" "Use with SYSLINUX bootloader" \
                       "1.2" "Use with GRUB bootloader")
            # udev might fail to create these devices
            if [ ! -b /dev/md/${ARRAYNAME/md/} ]; then
              mkdir -p /dev/md
              mknod -m 660 /dev/md/${ARRAYNAME/md/} b 9 ${ARRAYNAME/md/}
              chgrp disc /dev/md/${ARRAYNAME/md/}
              ln -s md/${ARRAYNAME/md/} /dev/$ARRAYNAME
            fi
            # create and start the array here in a single step
            DISCS_A=( $(for DISC in $(echo $DISCS | sed 's/,/\t/g') ; do echo $DISC ; done) )
            SPARE_A=( $(for DISC in $(echo $SPARE | sed 's/,/\t/g') ; do echo $DISC ; done) )
            # note we do not force creation here
            mdadm --create --metadata=$METADATA --level $LEVEL -n ${#DISCS_A[@]} -x ${#SPARE_A[@]} /dev/$ARRAYNAME ${DISCS_A[@]} ${SPARE_A[@]}
            sleep 2
            if ! grep -qw "^$ARRAYNAME" /proc/mdstat ; then
              sleep 5
              msgbox "Initialization and starting of the RAID array failed. You should inspect the output for errors and try manually to start the array before using it."
            else
              msgbox "Initialization of $ARRAYNAME succeeded. You can now use this device as a normal, unformatted partition."
              block_devices free $ARRAYNAME
              break
            fi
          else
            # remove disc from the raid array
            DISCS=$(echo $DISCS | sed -e "s:\\(^\\|,\\)$RRCHOICE\\(,\\|$\\):,:;s:^,::;s:,$::")
            SPARE=$(echo $SPARE | sed -e "s:\\(^\\|,\\)$RRCHOICE\\(,\\|$\\):,:;s:^,::;s:,$::")
            msgbox "Deleted $RRCHOICE from this RAID array."
            block_devices free $RRCHOICE
          fi
          # recombine the array options
          RAIDARRAYS[$N]="$ARRAYNAME:$LEVEL:$DISCS:$SPARE"
        done
        ;;
      Create)
        ARRAY="md${#RAIDARRAYS[@]}"
        LEVEL=$(get_raid_level)
        if [ -n "$LEVEL" ]; then
          RAIDARRAYS[${#RAIDARRAYS[@]}]="$ARRAY:$LEVEL::"
          block_devices add "/dev/$ARRAY:other:used"
        fi
        ;;
    esac
  done
  DEFAULT=M
}


menu_select_partitions()
{
  local PART N MNTPNT FSYS MNT_OPTS FSCK_PASS CHECK FORCE FORMAT
  while true; do
    PART=$(menu_get_partition)
    # Exit pressed - leave the menu and go back up a level
    if [ $? != 0 ]; then
      break
    elif [ "$PART" == "" ]; then
      continue
    fi
    # scan if we are re-assigning a partition
    for (( N=0 ; N<${#PARTITIONS[@]} ; N++ )); do
      if [ "$(echo ${PARTITIONS[$N]} | cut -d: -f1)" == "$PART" ]; then
        msgbox "Unassigned partition $PART. You can now change the parameters for this partition if you wish."
        block_devices free $PART
        unset PARTITIONS[$N]
        continue 2
      fi
    done
    FSYS=$(menu_get_filesystem)
    if [ -z "$FSYS" ]; then
      continue
    fi &&

    case "$FSYS" in
      btrfs)
        msgbox "Selecting btrfs as /boot is only supported with grub2, you will need to create a /boot partition and format it as ext2, ext3 or ext4 in order to use different bootloaders."
        ;;
      swap)
        SWAP_ENABLED=1
        ;;
    esac

    MNTPNT=$(get_mount_point $FSYS) &&

    PROMPT="$PART might already be formatted with the $FSYS filesystem and may contain data. Formatting it will destroy all the information on this partition. Are you sure you want to format it?"
    if confirm "$PROMPT" "--defaultno"; then
      FORMAT=yes
      CHECK=$(check_partition $FSYS)
    else
      FORMAT=no
    fi
    MNT_OPTS=$(determine_mount_opts $PART $FSYS) &&
    if [ "$MNT_PNT" != "/" ]; then
      MNT_PNT=${MNT_PNT%%/}
    fi
    FSCK_PASS=$(determine_fsck_pass $FSYS $MNTPNT) &&
    if [ "$FSYS" == "xfs" ]; then
      FORCE="-f"
    elif [[ "$FSYS" =~ ext[234] ]]; then
      FORCE="-F"
    elif [[ "$FSYS" == "btrfs" ]]; then
      FORCE="-f"
    elif [[ "$FSYS" == "vfat" ]]; then  # Enforce creation of 32-bit filesystem
      FORCE="-F 32"
    else
      unset FORCE
    fi

    PARTITIONS[${#PARTITIONS[@]}]="$PART:$MNTPNT:$FSYS:$MNT_OPTS:$FSCK_PASS:$CHECK:$FORCE:$FORMAT"

    if [ "$MNTPNT" == "/" ]; then
      ROOT=$PART
      # make sure BOOT is set to ROOT ... ->
      if [ -z "$BOOT" ]; then
        BOOT=$ROOT
      fi
    fi
    if [ "$MNTPNT" == "/boot" ]; then
      # ... -> except when this is a /boot partition
      BOOT=$PART
    fi
    block_devices use $PART
  done
}


select_partitions()
{
  if [ -z "$DONE_PARTITIONING" ]; then
    if confirm "Are you done making partitions?"; then
      DONE_PARTITIONING=1
      case $ARCH in
        "alpha")
          msgbox \
            "The partition on which the kernel is located must
be formatted with the ext2 filesystem. Normally this
means that your root or boot filesystem should be ext2."
          ;;
      esac
      menu_select_partitions
    fi
  else
    menu_select_partitions
  fi

  if [ -n "$ROOT" ]; then
    if (( STEP <= 4 )) ; then
      # Skip swapfile step if swap partition was set
      if [ -n "$SWAP_ENABLED" ]; then
        S_OK=\\Z2
        STEP=6
      else
        S_OK=
        STEP=5
      fi
    fi
    T_OK=
    L_OK=
  fi
}


make_lilo_conf()
{
  local UUID DISC

  if ! pkg_avail lilo ; then
    return
  fi
  if [ -e $TARGET/etc/lilo.conf ]; then
    return
  fi

  UUID=$(blkid -s UUID -o value $ROOT)

  DISC=$(echo $ROOT | sed 's/[0-9]*$//')
  (
    echo "lba32"
    echo "prompt"
    echo "compact"
    echo "delay=100"
    echo "timeout=100"
    echo "install=menu"
    echo "append=\"loglevel=3\""
    echo "read-only"
    echo ""
    if [[ "$BOOT" =~ ^/dev/md ]]; then
      echo "boot=$BOOT"
      BOOTDISCS=$(mdadm --detail $BOOT | tail -n2 | awk '{print $7}')
      echo "raid-extra-boot=$(echo $BOOTDISCS | sed -e 's@[0-9]@@g' -e 's@\ @,@g')"
    else
      echo "boot=$DISC"
    fi
    echo "root=\"UUID=$UUID\""
    if [[ "$DISC" =~ ^/dev/vd ]]; then
      echo -e "disk=$DISC\n    bios=0x80\n    max-partitions=7"
    fi
    echo ""
  ) > $TARGET/etc/lilo.conf
}


install_grub2()
{
  local DISC

  if ! pkg_avail grub2 ; then
    return
  fi

  if [[ ! -v MBR ]]
  then
    DISC=$(echo $ROOT | sed 's/[0-9]*$//')
    MBR=$($DIALOG --title "grub2 MBR install" --menu "" 0 0 0 \
      "$DISC" "Install grub2 MBR on this device" \
      "C"     "Change grub2 MBR install device")
    if [ "$MBR" = "C" ]; then
      MBR=$(inputbox "Please enter a device where to install the grub2 MBR" "")
    fi
  fi

  if [[ -d /sys/firmware/efi ]]
  then
    if grep '/mnt/boot vfat' /proc/mounts > /dev/null 2>&1
    then
      chroot_run grub-install --efi-directory=/boot $MBR
    else
      msgbox "Grub2 installation failed.  This is an EFI system, but no VFAT boot partition has been detected.  You need to create a VFAT /boot partition large enough for the EFI data, your kernels and the initramfs."
      return 1
    fi
  else
    chroot_run grub-install $MBR
  fi
}


make_grub_conf()
{
  if ! pkg_avail grub ; then
    return
  fi
  if [ -e $TARGET/boot/grub/menu.lst ] ; then
    return
  fi

  mkdir -p $TARGET/boot/grub
  (
    echo "# uncomment the following 2 lines to enable serial console booting"
    echo "#serial --unit=0 --speed=38400 --word=8 --parity=no --stop=1"
    echo "#terminal serial"
    echo ""
    echo "timeout 30"
    echo "default 0"
    echo "fallback 1"
    echo "color light-gray/blue black/light-gray"
    echo ""
  ) > $TARGET/boot/grub/menu.lst
}


install_grub()
{
  if ! pkg_avail grub ; then
    return
  fi
  # grub lives on the "/" partition unless we have a separate
  # "/boot" partition. Hence we use $BOOT to determine the grub location.
  GRUB_PART=$(lsh map_device_to_grub $BOOT)
  # and we go straight to the MBR
  GRUB_MBR=$(echo $GRUB_PART | cut -d, -f1)

  (
    echo "root ($GRUB_PART)"
    echo "setup ($GRUB_MBR)"
    echo "quit"
  ) | grub --no-curses
  sleep 2

  # setup details needed for frub later:
  if [ "$BOOT" == "$ROOT" ]; then
    GRUB_BOOT=/boot
  else
    GRUB_BOOT=""
  fi
  GRUB_ROOT="($(lsh map_device_to_grub $ROOT))"
  export GRUB_ROOT GRUB_BOOT

  echo ""
  echo "grub should use the following parameters from now on:"
  echo "  root   $GRUB_ROOT"
  echo "  kernel $GRUB_BOOT/\${ image name }"
  echo ""

  echo "grub was installed on the MBR of $GRUB_MBR"
  sleep 4
}


transfer_package()
{
  cd $TARGET &&
  LINE=$(grep "^$1:" $PACKAGES_LIST)
  MOD=$(echo $LINE | cut -d: -f1)
  VER=$(echo $LINE | cut -d: -f4)
  cp /var/cache/lunar/$MOD-$VER-*.tar.xz $TARGET/var/cache/lunar/
  tar xJf $TARGET/var/cache/lunar/$MOD-$VER-*.tar.xz 2> /dev/null
  echo $LINE >> $TARGET/var/state/lunar/packages
  cp $TARGET/var/state/lunar/packages $TARGET/var/state/lunar/packages.backup
}


percent_msg()
{
  echo XXX
  echo $(( CNT * 100 / NUM ))
  echo "\n$((CNT+1)): $1\n"
  echo XXX
  (( CNT++ ))
}


transfer()
{
  msgbox "You should now be ready to install Lunar Linux to your system. Lunar Linux will now create filesystems if needed, make a swapfile if it was selected, and install all Lunar Linux packages to the newly setup system. Make sure you are done with partitioning and filesystem selection."
  if confirm "Are you ready to install lunar?" ;  then
    clear

    ORDER=$(for (( N=0 ; N<${#PARTITIONS[@]} ; N++ )); do echo ${PARTITIONS[$N]} | cut -d: -f2 ; done | sort)

    for MOUNTPOINT in $ORDER; do
      for (( N=0 ; N<${#PARTITIONS[@]} ; N++ )); do
        M=$(echo ${PARTITIONS[$N]} | cut -d: -f2)
        if [ "$M" == "$MOUNTPOINT" ]; then
          PART=$(echo ${PARTITIONS[$N]} | cut -d: -f1)
          FSYS=$(echo ${PARTITIONS[$N]} | cut -d: -f3)
          MNT_OPTS=$(echo ${PARTITIONS[$N]} | cut -d: -f4)
          FSCK_PASS=$(echo ${PARTITIONS[$N]} | cut -d: -f5)
          CHECK=$(echo ${PARTITIONS[$N]} | cut -d: -f6)
          FORCE=$(echo ${PARTITIONS[$N]} | cut -d: -f7)
          FORMAT=$(echo ${PARTITIONS[$N]} | cut -d: -f8)

          # handle swap
          if [ "$FSYS" == "swap" ]; then
            echo "Setting up swap on $PART..."
            if ! mkswap $PART ; then
              sleep 3
              msgbox "Problem creating swap on $PART. Installation will continue."
            fi
            # create the filesystems if needed for every partition
          elif [ "$FORMAT" == "yes" ]; then
            echo "Formatting $PART as $FSYS..."
            if ! mkfs.$FSYS $FORCE $PART $CHECK ; then
              sleep 3
              msgbox "Problem creating $FSYS filesystem on $PART. Installation will continue."
            fi
          fi
          # again, weed out swap first
          if [ "$FSYS" == "swap" ]; then
            # We need to check that the swap device wasn't added already
            # or we end up with double entries in fstab if more than one
            # swap device was added
            if ! echo $FSTAB | grep -q $PART; then
              LABEL=$(fstab_style $PART $FSYS $MOUNTPOINT)
              if swapon $PART; then
                FSTAB="$FSTAB\n$LABEL\t$MOUNTPOINT\t$FSYS\t$MNT_OPTS\t\t0 $FSCK_PASS"
                swapoff $PART
              else
                sleep 3
                msgbox "Problem mounting swap on $PART. Installation will continue."
              fi
            fi
            # then try to mount normal FS's
          else
            if [ ! -d $TARGET$MOUNTPOINT ] ; then
              mkdir -p $TARGET$MOUNTPOINT
            fi
            if [ "$MNT_OPTS" != "defaults" ]; then
              MNTOPTARGS="-e $MNT_OPTS"
            else
              MNTOPTARGS=""
            fi
            echo "Mounting $PART as $FSYS"
            LABEL=$(fstab_style $PART $FSYS $MOUNTPOINT)
            if mount -n $PART $TARGET$MOUNTPOINT -t $FSYS $MNTOPTSARGS ; then
              FSTAB="$FSTAB\n$LABEL\t$MOUNTPOINT\t$FSYS\t$MNT_OPTS\t0 $FSCK_PASS"
              if [ "$FSYS" == "swap" ]; then
                umount -n $PART
              fi
            else
              sleep 3
              msgbox "Problem mounting $FSYS filesystem on $PART. Installation will continue."
            fi
          fi
        fi
      done
    done

    # last we create the swapfile on the target
    if [ -n "$SWAPFILE" ]; then
      mkdir -p $TARGET$(dirname $SWAPFILE) &&
      echo "Creating a swapfile of $SWAPSIZE MB at \"$SWAPFILE\"..." &&
      if dd if=/dev/zero of=$TARGET$SWAPFILE bs=1M count=$SWAPSIZE &&
        mkswap $TARGET$SWAPFILE &&
        chmod 000 $TARGET$SWAPFILE
      then
        FSTAB="$FSTAB\n$SWAPFILE\tswap\tswap\tdefaults\t\t0 0"
      else
        sleep 3
        msgbox "Problem creating swapfile. Installation will continue."
      fi
    fi

    # calculate the total so we can display progress
    NUM=$(wc -l $PACKAGES_LIST | awk '{print $1}')
    # add the number of times we call percent_msg, subtract 2 for lilo/grub
    (( NUM = NUM + 10 - 2 ))

    cd $TARGET

    (
      percent_msg "Creating base LSB directories"
      mkdir -p bin boot dev etc home lib mnt media
      mkdir -p proc root sbin srv tmp usr var opt
      mkdir -p sys
      if [ `arch` == "x86_64" ]; then
        ln -sf lib lib64
        ln -sf lib usr/lib64
      fi
      mkdir -p usr/{bin,games,include,lib,libexec,local,sbin,share,src}
      mkdir -p usr/share/{dict,doc,info,locale,man,misc,terminfo,zoneinfo}
      mkdir -p usr/share/man/man{1,2,3,4,5,6,7,8}
      ln -sf share/doc usr/doc
      ln -sf share/man usr/man
      ln -sf share/info usr/info
      mkdir -p etc/lunar/local/depends
      mkdir -p run/lock
      ln -sf ../run var/run
      ln -sf ../run/lock var/lock
      mkdir -p var/log/lunar/{install,md5sum,compile,queue}
      mkdir -p var/{cache,empty,lib,log,spool,state,tmp}
      mkdir -p var/{cache,lib,log,spool,state}/lunar
      mkdir -p var/state/discover
      mkdir -p var/spool/mail
      mkdir -p media/{cdrom0,cdrom1,floppy0,floppy1,mem0,mem1}
      chmod 0700 root
      chmod 1777 tmp var/tmp

      if [ -f /var/cache/lunar/aaa_base.tar.xz ]; then
        percent_msg "Installing aaa_base: base directories and files"
        tar xJf /var/cache/lunar/aaa_base.tar.xz 2> /dev/null
      fi
      if [ -f /var/cache/lunar/aaa_dev.tar.xz ]; then
        percent_msg "Installing aaa_dev: device nodes"
        tar xJf /var/cache/lunar/aaa_dev.tar.xz 2> /dev/null
      fi

      for LINE in $(cat $PACKAGES_LIST | grep -v -e '^lilo:' -e '^grub:' -e '^grub2:') ; do
        MOD=$(echo $LINE | cut -d: -f1)
        VER=$(echo $LINE | cut -d: -f4)
        SIZ=$(echo $LINE | cut -d: -f5)
        percent_msg "Installing $MOD-$VER ($SIZ)\n\n($(basename /var/cache/lunar/$MOD-$VER-*.tar.xz))"
        transfer_package $MOD
      done

      percent_msg "Installing moonbase"
      (
        cd $TARGET/var/lib/lunar
        tar xjf $MOONBASE_TAR 2> /dev/null
        tar j --list -f $MOONBASE_TAR | sed 's:^:/var/lib/lunar/:g' > $TARGET/var/log/lunar/install/moonbase-%DATE%
        mkdir -p moonbase/zlocal
      )

      # transfer sources
      #percent_msg "Copying sources"
      #cp /var/spool/lunar/* $TARGET/var/spool/lunar/

      # setup list of installed packages etc.
      percent_msg "Updating administrative files"
      echo "moonbase:%DATE%:installed:%DATE%:37000KB" >> $TARGET/var/state/lunar/packages
      cp $TARGET/var/state/lunar/packages $TARGET/var/state/lunar/packages.backup
      cp /var/state/lunar/depends        $TARGET/var/state/lunar/
      cp /var/state/lunar/depends.backup $TARGET/var/state/lunar/
      chroot_run lsh create_module_index
      chroot_run lsh create_depends_cache

      # more moonbase related stuff
      percent_msg "Updating moonbase plugins"
      chroot_run lsh update_plugins

      # just to make sure
      percent_msg "Running ldconfig"
      chroot_run ldconfig

      # pass through some of the configuration at this point:
      percent_msg "Finishing up installation"
      chroot_run systemd-machine-id-setup 2> /dev/null
      chroot_run systemctl preset-all 2>/dev/null
      echo -e "KEYMAP=$KEYMAP\nFONT=$CONSOLEFONT" > $TARGET/etc/vconsole.conf
      echo -e "LANG=${LANG:-en_US.utf8}\nLC_ALL=${LANG:-en_US.utf8}" > $TARGET/etc/locale.conf
      [ -z "$EDITOR" ] || echo "export EDITOR=\"$EDITOR\"" > $TARGET/etc/profile.d/editor.rc

      if [[ $TZ != UTC ]]
      then
        ln -fs /usr/share/zoneinfo/$TZ etc/localtime
      fi

      # post-first-boot message:
      cp /README $TARGET/root/README
      cp $MOTD_FILE $TARGET/etc/motd

      # save proxies
      if [ -n "$HPROXY" -o -n "$FPROXY" -o -n "$NPROXY" ]; then
      (
        echo "# these proxy settings apply to wget only"
        [ -z "$HPROXY" ] || echo "export http_proxy=\"$HPROXY\""
        [ -z "$FPROXY" ] || echo "export ftp_proxy=\"$FPROXY\""
        [ -z "$NPROXY" ] || echo "export no_proxy=\"$NPROXY\""
      ) > $TARGET/etc/profile.d/proxy.rc
      fi

      if [ -e etc/fstab ]; then
        cp etc/fstab etc/fstab-
      fi

      echo -e "$FSTAB" >> etc/fstab
      make_lilo_conf
      make_grub_conf

      # some more missing files:
      cp /etc/lsb-release $TARGET/etc/
      cp /etc/os-release $TARGET/etc/
      cp /etc/issue{,.net} $TARGET/etc/

      # Some sane defaults
      GCCVER=$(chroot_run lvu installed gcc | awk -F\. '{ print $1"_"$2 }')

      cat <<EOF> $TARGET/etc/lunar/local/config
  LUNAR_COMPILER="GCC_$GCCVER"
    LUNAR_MODULE="lunar"
LUNAR_ALIAS_UDEV="systemd"
LUNAR_ALIAS_KMOD="kmod"
LUNAR_ALIAS_KERNEL_HEADERS="kernel-headers"
LUNAR_ALIAS_SSL="openssl"
LUNAR_ALIAS_OSSL="openssl"
EOF

      # Disable services (user can choose to enable them using services menu)
      rm -f $TARGET/etc/systemd/system/network.target.wants/wpa_supplicant.service
      rm -f $TARGET/etc/systemd/system/sockets.target.wants/sshd.socket

      # root user skel files
      find $TARGET/etc/skel ! -type d | xargs -i cp '{}' $TARGET/root

      # initialize the new machine:
      touch $TARGET/var/log/{btmp,utmp,wtmp,lastlog}
      chmod 0644 $TARGET/var/log/{utmp,wtmp,lastlog}
      chmod 0600 $TARGET/var/log/btmp

      # Tell dracut to auto enable md devices if used during install
      if [ -e /proc/mdstat ]; then
        if egrep -q ^md[0-9]+ /proc/mdstat; then
          mdadm --examine --scan > $TARGET/etc/mdadm.conf
          cat <<EOF> $TARGET/etc/dracut.conf.d/02-raid.conf
# Enable software raid automatically using dracut.
# --  AUTO-GENERATED FILE DO NOT MODIFY --
kernel_cmdline+=" rd.auto=1"
mdadmconf="yes"
EOF
        fi
      fi

    # really we are done now ;^)
    ) | $DIALOG --title " Installing Lunar Linux " --gauge "" 10 70 0

    cd /

    if (( STEP == 7 )); then
      (( STEP++ ))
    fi
    T_OK=\\Z2
    O_OK=

    install_bootloader &&
    install_kernels
  fi
}


shell()
{
  echo "Press CTRL-D or type exit to return to the installer"
  (
    cd
    SHELL=/bin/bash HOME=/root /bin/bash -ls
  )
}


configure_proxy()
{
  HTTP_PROMPT="Please enter the HTTP proxy server\nExample: http://192.168.1.1:8080/"
  FTP_PROMPT="Please enter the FTP proxy server\nExample: http://192.168.1.1:8080/"
  NO_PROMPT="Please enter all domains/ip addresses (comma-seperated) proxy should NOT be used for:\nExample: .mit.edu,mysite.com"
  HPROXY=`inputbox "$HTTP_PROMPT"`           &&
  FPROXY=`inputbox "$FTP_PROMPT" "$HPROXY"`  &&
  NPROXY=`inputbox "$NO_PROMPT"`
}


confirm_proxy_settings()
{
  FINISHED=NO
  while [ "$FINISHED" != "YES" ]; do
    PROMPT="Are these settings correct?"
    PROMPT="$PROMPT\nHTTP Proxy:  $HPROXY"
    PROMPT="$PROMPT\n FTP Proxy:  $FPROXY"
    PROMPT="$PROMPT\n  No Proxy:  $NPROXY"

    if confirm "$PROMPT" "--cr-wrap"; then
      FINISHED=YES
    else
      configure_proxy
      FINISHED=NO
    fi
  done
}


proxy_exit_message()
{
  msgbox \
    "Your proxy configuration has been saved.

Please note that these proxy settings will only be used by Lunar Linux
(specifically, wget) and possibly some other command-line utilities.

You will still have to configure proxy settings in your favorite
web browser, etc..."

}


toggle()
{
  if [ `eval echo \\$$1` == "on" ]; then
    eval $1=off
  else
    eval $1=on
  fi
}

fstab_style_menu()
{
    local TITLE HELP DEFAULT STYLE FSTAB_OPTIONS

    TITLE="Fstab Style Menu"
    HELP="Please select preferred fstab mount style"
    FSTAB_STYLE=`$DIALOG --title "$TITLE" --default-item "$FSTAB_STYLE" --cr-wrap --menu "$HELP" 0 0 0 \
                 "DEV" "Device name style" \
                 "LABEL" "LABEL style" \
                 "UUID" "UUID style"`
    FSTAB_STYLE=${FSTAB_STYLE:-UUID}
}

##
# fstab_style partition fstype mountpoint
#
fstab_style()
{
  local PART PTYPE MNTPT UUID

  PART=$1
  PTYPE=$2
  MNTPT=$3

  case "$FSTAB_STYLE" in
    DEV)
      # Do nothing
      echo $PART
      ;;
    LABEL)
      set_fs_label $PART $PTYPE $MNTPT
      if [ "$PTYPE" == "swap" ]; then
        echo "LABEL=swap${PART##*/}"
      else
        echo "LABEL=$MNTPT"
      fi
      ;;
    UUID)
      UUID=$(blkid -s UUID -o value $PART)
      echo "UUID=$UUID"
      ;;
  esac
}

##
# set_fs_label partition fstype label
#
set_fs_label() {
  local PART PTYPE LABEL

  PART=$1
  PTYPE=$2
  LABEL=$3

  case "$PTYPE" in
    ext*)
      tune2fs -L $LABEL $PART &> /dev/null
      ;;
    btrfs)
      btrfs filesystem label $PART $LABEL &> /dev/null
      ;;
    xfs)
      xfs_admin -L $LABEL $PART &> /dev/null
      ;;
    swap)
      mkswap -L swap${PART##*/} $PART &> /dev/null
      ;;
  esac
}

show_consolefonts()
{
  FONTDIR="/usr/share/kbd/consolefonts"
  cd $FONTDIR
  FONTS=`ls *.{psf,psfu}.gz | sed -r "s/\.psfu?\.gz//"`

  for FONT in $FONTS; do
    echo $FONT
    echo font
  done
}


font_menu()
{
  TITLE="Console Font Selection Menu"
  HELP="Please select your preferred console fonts."
  FONTS=`show_consolefonts`
  CONSOLEFONT=${CONSOLEFONT:-default8x16}
  CONSOLEFONT=`$DIALOG --title "$TITLE" --default-item "$CONSOLEFONT" --menu "$HELP" 0 0 0 $FONTS`
  if [ $? == 0 ]; then
    setfont $CONSOLEFONT
    D_OK=\\Z2
  fi
  DEFAULT=E
}


show_languages()
{
  while read locale language; do
    echo "$locale"
    echo "$language"
  done < $LOCALE_LIST
}


lang_menu()
{
  TITLE="Language Selection Menu"
  HELP="While Lunar Linux is entirely in English
it is possible to change the languages of many other programs.
Please select your preferred langauge.

This process will ONLY set the LANG environment variable. Do
not expect any changes till you finish and reboot."

  LANG=${LANG:-en_US.utf8}
  LANG=$($DIALOG --title "Language Selection Menu" --default-item "$LANG" --menu "$HELP" 0 0 0 `show_languages`)
  if [ $? == 0 ]; then
    export LANG
    E_OK=\\Z2
  fi
  DEFAULT=A
}


editor_menu()
{
  EDITOR=${EDITOR:-vi}
  EDITOR=`$DIALOG --title "Editor Selection Menu" --default-item "$EDITOR" --item-help --cr-wrap \
      --menu "Not all of these editors are available right away. Some require that you compile them yourself (like emacs) or are only available on the target installation, and possibly emulated through another editor" 0 0 0 \
      "e3"    "fully available" \
          "an emacs, vim, pico emulator" \
      "emacs" "emulated on this install media by e3, not installed" \
          "Richard Stallmans editor" \
      "joe"   "fully available" \
          "WS compatible editor" \
      "nano"  "fully available" \
          "a pico clone" \
      "vi"    "fully available" \
          "vim - good old vi" \
      "zile"  "fully available" \
          "an emacs clone"`

  export EDITOR
  J_OK=\\Z2
  DEFAULT=F
}


install_kernels()
{
  list_precompiled_kernels()
  {
    local LINE
    while read LINE; do
      echo $LINE | cut -d: -f1
      echo $LINE | cut -d: -f3-
      # same text below - more space for longer description
      echo $LINE | cut -d: -f3-
    done < $KERNEL_LIST
  }

  list_kernel_modules()
  {
    local LINE
    while read LINE; do
      (
        unset MISSING
        MODULE=$(echo $LINE | cut -d: -f2)
        for SOURCE in $(chroot_run lvu sources $MODULE) ; do
          if [ ! -e $TARGET/var/spool/lunar/$SOURCE ]; then
            MISSING=yes
          fi
        done
        if [ -z "$MISSING" ]; then
          echo $LINE | cut -d: -f1
          echo $MODULE
          echo $LINE | cut -d: -f3-
        fi
      )
    done < $KMOD_LIST
  }

  while true ; do
    # Lets shortcut here, if we only have one kernel we just install it without a dialog
    KERNELS_AVAIL=$(wc -l $KERNEL_LIST | cut -d' ' -f1)
    if [[ $KERNELS_AVAIL == 1 ]]; then
      KCOMMAND="P"
    else
      KCOMMAND=`$DIALOG --title "Kernel selection menu" --cancel-label "Exit" --default-item "P" --item-help --menu "In order to succesfully run linux you need to install the linux kernel, the heart of the operating system. You can choose between compiling one yourself or select a precompiled modular kernel." 0 0 0 \
      "P" "Install a precompiled kernel" "Fast and safe: these kernels should work on almost all machines" \
      "C" "Compile a kernel" "Custom configure and compile one of the linux kernels"`
    fi

    if [ $? != 0 ]; then
      return
    fi

    case $KCOMMAND in
      C)
        msgbox "This option is not available from the installer."
      ;;
      P)
        # Lets shortcut here, if we only have one kernel we just install it without a dialog
        if [[ $KERNELS_AVAIL == 1 ]]; then
          CCOMMAND=$(cut -d: -f1 $KERNEL_LIST)
        else
          CCOMMAND=`$DIALOG --title "Kernel selection menu" --cancel-label "Exit" --item-help --menu "" 0 0 0 \
            $(list_precompiled_kernels)`
        fi
        if [ -f "/var/cache/lunar/$CCOMMAND.tar.xz" ]; then
          $DIALOG --infobox "\nInstalling kernel $CCOMMAND, please wait..." 5 70
          cd $TARGET && tar xf /var/cache/lunar/$CCOMMAND.tar.xz &> /dev/null
          chroot_run cp /usr/src/linux/.config /etc/lunar/local/.config.current

          KVER=$(grep "^$CCOMMAND:" $KERNEL_LIST | cut -d: -f2)
          KVER_PATCH=$(echo $KVER | cut -d . -f 3)
          KVER_FULL=$(echo $KVER | cut -d . -f 1,2).${KVER_PATCH:-0}

          # Register the kernel module as installed
          if ! grep -q "^linux:" $TARGET/var/state/lunar/packages; then
            echo "linux:%DATE%:installed:$KVER:101500KB" >> $TARGET/var/state/lunar/packages
          fi

          # Generate kernel install log
          #tar -tf /var/cache/lunar/$CCOMMAND.tar.xz | sed '/^usr\/src/d;s:^:/:g' >> $TARGET/var/log/lunar/install/linux-${CCOMMAND} 2> /dev/null

          # Generate kernel md5sum log
          #cat $TARGET/var/log/lunar/install/linux-${CCOMMAND} | xargs -i md5sum {} >> $TARGET/var/log/lunar/md5sum/linux-${CCOMMAND} 2> /dev/null

          # let the plugin code handle the hard work
          chroot_run depmod
          chroot_run lsh update_bootloader $KVER_FULL $KVER

          if (( STEP == 7 )); then
            (( STEP++ ))
          fi
          K_OK=\\Z2
          R_OK=
          U_OK=
          H_OK=
          V_OK=
          G_OK=
          A_OK=
          break
        fi
      ;;
    esac
  done
}

select_bootloader() {
  while true
  do
    BCOMMAND=`$DIALOG --title "Boot loader menu" \
                      --default-item "G" \
                      --item-help \
                      --menu "You will need a boot loader to start linux automatically when your computer boots. You can chose not to install a boot loader now, or pick one of the available boot loaders and options below. You can always change to the other boot loader later." \
                      0 0 0 \
                      $(if pkg_avail systemd && [ -d /sys/firmware/efi ]; then echo "S" ; echo "systemd (UEFI only))" ; echo "Install systemd-boot as boot loader (UEFI)"; fi) \
                      $(if pkg_avail grub2 ; then echo "G" ; echo "grub2" ; echo "Install grub2 as boot loader (BIOS)"; fi) \
                      $(if pkg_avail grub ; then echo "B" ; echo "grub" ; echo "Install grub as boot loader (BIOS)"; fi) \
                      $(if pkg_avail lilo ; then echo "L" ; echo "lilo" ; echo "Install lilo as boot loader (BIOS)"; fi) \
                      "N" "none" "Do not install a boot loader"`

    if [ $? != 0 ] ; then
      continue
    fi

    case $BCOMMAND in
        S) BOOTLOADER=systemd ;;
        L) BOOTLOADER=lilo    ;;
        G) BOOTLOADER=grub2   ;;
        B) BOOTLOADER=grub    ;;
        N) BOOTLOADER=none    ;;
    esac

    case $BOOTLOADER in
        grub2) 
          DISC=$(echo $ROOT | sed 's/[0-9]*$//')
          MBR=$($DIALOG --title "grub2 MBR install" --menu "" 0 0 0 \
            "$DISC" "Install grub2 MBR on this device" \
            "C"     "Change grub2 MBR install device")
          if [ "$MBR" = "C" ]; then
            MBR=$(inputbox "Please enter a device where to install the grub2 MBR" "")
          fi
        ;;
    esac
    if (( STEP == 6 )); then
      (( STEP++ ))
    fi
    L_OK=\\Z2
    T_OK=
    return
  done
}

install_bootloader() {
  if [[ ! -v BOOTLOADER ]]
  then
    select_bootloader
  fi

  case ${BOOTLOADER:-none} in
    systemd)
      chroot_run lsh update_plugin $BOOTLOADER "install"
      chroot_run bootctl install
      ;;
    lilo)
      transfer_package $BOOTLOADER
      chroot_run lsh update_plugin $BOOTLOADER "install"
      ;;
    grub2)
      transfer_package $BOOTLOADER
      chroot_run lsh update_plugin $BOOTLOADER "install"
      install_grub2
      ;;
    grub)
      transfer_package $BOOTLOADER
      chroot_run lsh update_plugin $BOOTLOADER "install"
      install_grub
      ;;
    none)
      msgbox "Not installing a boot loader might require you to create a boot floppy, or configure your bootloader manually using another installed operating system. Lunar Linux also did not install lilo or grub on the hard disc."
      ;;
  esac

  K_OK=
  return
}


install_menu()
{
  if [ -z "$STEPS" ]; then
    # the total number of steps in the installer:
    STEPS=8

    SH[1]="Please read the introduction if you are new to Lunar Linux.
If you want to know more about the installation procedure
and recent changes please visit http://lunar-linux.org/
before proceeding."
    SH[2]="You can now set various system defaults that
are not vital but make your linux system more friendly
to your users."
    SH[3]="You need to create partitions if you are installing on
a new disc or in free space. If you want to delete other
operating systems you will also need to partition your disc."
    SH[4]="You need to mount a filesystem so that Lunar Linux can be
transferred to it. Usually you make 3 to 5 separate
partitions like /boot, /var and /usr. After mounting
them the Lunar Linux packages can be transferred to them."
    SH[5]="Swap is like temporary memory. It improves your
systems performance. You can create a swapfile or
even whole swap partitions."
    SH[6]="To be able to boot linux on reboot, you need to have
a boot loader that loads the kernel when you power on
your computer. Without it linux does not run."
    SH[7]="During the transfer all programs and files that you
need to run Lunar Linux will be copied to your system."
    SH[8]="You can make some final preparations here before you begin
using your new Lunar Linux system. Setting a root password is strongly
recommended now, but the rest of these operations can also be done after
you've rebooted into your new system."

    B_LABEL="One step back"
    B_HELP="Go back one step in the installation procedure"
    F_LABEL="One step forward"
    F_HELP="Go forward one step in the installation procedure"

    I_LABEL="Introduction into Lunar Linux"
    I_HELP="Read about the advantages of using Lunar Linux"

    C_LABEL="Select a keyboard map"
    C_HELP="Select keyboard map"
    D_LABEL="Select a console font"
    D_HELP="Select a console font"
    E_LABEL="Set global language"
    E_HELP="Set global language"
    A_LABEL="Select a timezone"
    A_HELP="Select a timezone"
    J_LABEL="Select a default editor"
    J_HELP="Select a default editor"

    P_LABEL="Partition discs"
    P_HELP="Use fdisk or cfdisk to prepare hard drive partitions"
    W_LABEL="Setup Linux Software RAID"
    W_HELP="Linux software RAID can increase redundancy or speed of hard discs"
    M_LABEL="Select target partitions"
    L_LABEL="Select boot loader"
    L_HELP="Select a boot loader to boot into Lunar"
    L_OK="\\Z1"
    M_HELP="Select target partitions for installation"
    S_LABEL="Select a swapfile"
    S_HELP="You don't need to setup a separate swap partition but can use a swapfile"
    S_OK="\\Z1"
    T_LABEL="Install lunar"
    T_HELP="Create filesystems, swapfile and install all packages onto the target system NOW"
    T_OK="\\Z1"
    O_LABEL="Configure compiler optimizations"
    O_HELP="Select architecture and optimizations"
    O_OK="\\Z1"
    K_LABEL="Install kernel(s)"
    K_HELP="Install kernel(s) on the new installation"
    K_OK="\\Z1"

    R_LABEL="Set root password"
    R_HELP="Set root password needed to access this system (the default password is empty)"
    R_OK="\\Z1"
    U_LABEL="Setup user accounts"
    U_HELP="Create, edit, delete users and group accounts on the system (\"luser\" after reboot)"
    U_OK="\\Z1"
    H_LABEL="Setup hostname and networking"
    H_HELP="Configure your network devices and hostname settings (\"lnet\" after reboot)"
    H_OK="\\Z1"
    V_LABEL="Administrate services"
    V_HELP="Configure services to start automatically at boot time (\"lservices\" after reboot)"
    V_OK="\\Z1"

    X_LABEL="Exit into rescue shell or reboot"
    X_HELP="This launches a a rescue shell or reboots your system"
    Z_LABEL="Finished installing!"
    Z_HELP="You're done! Now go reboot and use Lunar Linux!"
    Z_OK="\\Z0"

    STEP=1
  fi

  choices()
  {
    (
    export IFS=$' \t\n'
    for CHOICE in $@; do
      echo $CHOICE
      eval echo \$${CHOICE}_OK\$${CHOICE}_LABEL\\\\Z0
      eval echo \$${CHOICE}_HELP
    done
    export IFS=$'\t\n'
    )
  }

  if [ "$GUIDE" == "off" ]; then
    CHOICES="X I C D E J P W M S T O L R U H V A Z"
    STEPHELP="Step $STEP of $STEPS:"
  else
    case $STEP in
    1)  DEFAULT=I ; CHOICES="X I F" ;;
    2)              CHOICES="B C D E A J F" ;;
    3)  DEFAULT=P ; CHOICES="B P W M F" ;;
    4)  DEFAULT=M ; CHOICES="B P W M F" ;;
    5)  DEFAULT=S ; CHOICES="B P W M S L T F" ;;
    6)  DEFAULT=L ; CHOICES="B P W M S L T F" ;;
    7)  DEFAULT=T ; CHOICES="B P W M S L T F" ;;
    8)              CHOICES="B R O U H V Z" ;;
    esac
  fi
  COMMAND=`$DIALOG --title "Lunar Linux install menu" --nocancel --default-item "$DEFAULT" --item-help --extra-button --extra-label "Settings" --colors --menu "Step $STEP of $STEPS - \n\n${SH[$STEP]}" 0 0 0 $(choices $CHOICES)`

  case $? in
    3)
      COMMAND=S
      while true; do
        DEFAULT=$COMMAND
        COMMAND=`$DIALOG --title "Settings / Special actions" \
          --default-item "$DEFAULT" \
          --cancel-label "Exit" \
          --menu "Installer settings and misc. options" 0 0 0 \
          "G" "Toggle guided menus on/off                     [$GUIDE]" \
          "C" "Toggle asking of confirmations on/off          [$CONFIRM]" \
          "D" "Toggle disabling the ability to perform steps  [$DISABLE]" \
                                        "F" "Configure fstab mount style                    [$FSTAB_STYLE]" \
          "M" "Load more kernel modules" \
          "S" "Temporarily run a shell" \
          "Q" "Quit the installer"`
        if [ $? != 0 ]; then
          return
        fi
        case $COMMAND in
          G) toggle GUIDE ;;
          C) toggle CONFIRM ;;
          D) toggle DISABLE ;;
          F) fstab_style_menu ;;
          S) shell ;;
          M) load_module ;;
          Q) goodbye ;;
        esac
      done
    ;;
  esac

  eval "TEST=\$${COMMAND}_OK"
  if [ "$DISABLE" == "on" -a "$TEST" == "\\Z1" ]; then
    $DIALOG --title "Cannot perform this step yet" --colors --msgbox "This action cannot be performed yet. You need to complete one of the earlier steps succesfully first before you can try this action. Please go a step back and perform all the necessary actions before trying this item again. As a guide, the actions that you have performed are \Z2colored green\Z0. The ones that you cannot perform yet are \Z1colored red\Z0." 15 65
    return
  fi

  case $COMMAND in
    F)  if (( STEP < $STEPS )); then (( STEP++ )) ; fi ;;
    B)  if (( STEP > 0 )); then (( STEP-- )) ; fi ;;

    X)  goodbye                ;;
    I)  introduction           ;;

    C)  keymap_menu            ;;
    D)  font_menu              ;;
    E)  lang_menu              ;;
    A)  timezone_menu          ;;
    J)  editor_menu            ;;

    P)  partition_discs        ;;
    W)  raid_setup             ;;
    M)  select_partitions      ;;
    L)  select_bootloader      ;;
    S)  select_swap_file       ;;
    T)  transfer               ;;

    R)  USE_CLEAR=1 chroot_run passwd    ; R_OK=\\Z2; DEFAULT=O ;;
    O)  chroot_run lunar optimize        ; O_OK=\\Z2; DEFAULT=U ;;
    U)  chroot_run luser                 ; U_OK=\\Z2; DEFAULT=H ;;
    H)  chroot_run lnet                  ; H_OK=\\Z2; DEFAULT=V ;;
    V)  chroot_run lservices             ; V_OK=\\Z2; DEFAULT=Z ;;

    Z)  goodbye                ;;
  esac
}


main()
{
  export PATH="/bin:/usr/bin:/sbin:/usr/sbin:/usr/local/bin"
  # setting this var is supposed to prevent the enviro_check code now!
  export LUNAR_INSTALL=1

  unset EDITOR

  TARGET="/mnt"
  CONFIRM=on
  GUIDE=on
  DISABLE=on
  FSTAB_STYLE="UUID"

  block_devices init

  while true; do
    install_menu
  done
}

