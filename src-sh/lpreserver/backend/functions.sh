#!/bin/sh
# Functions / variables for lpreserver
######################################################################
# DO NOT EDIT 

# Source external functions
. /usr/local/share/pcbsd/scripts/functions.sh

# Installation directory
PROGDIR="/usr/local/share/lpreserver"

# Location of settings 
DBDIR="/var/db/lpreserver"
if [ ! -d "$DBDIR" ] ; then mkdir -p ${DBDIR} ; fi

CMDLOG="${DBDIR}/lp-lastcmdout"
CMDLOG2="${DBDIR}/lp-lastcmdout2"
REPCONF="${DBDIR}/replication"
LOGDIR="/var/log/lpreserver"
REPLOGSEND="${LOGDIR}/lastrep-send-log"
REPLOGRECV="${LOGDIR}/lastrep-recv-log"
MSGQUEUE="${DBDIR}/.lpreserver.msg.$$"
export DBDIR LOGDIR PROGDIR CMDLOG REPCONF REPLOGSEND REPLOGRECV MSGQUEUE

# Create the logdir
if [ ! -d "$LOGDIR" ] ; then mkdir -p ${LOGDIR} ; fi

#Set our Options
setOpts() {
  if [ -e "${DBDIR}/recursive-off" ] ; then
    export RECURMODE="OFF"
  else
    export RECURMODE="ON"
  fi

  if [ -e "${DBDIR}/emaillevel" ] ; then
    export EMAILMODE="`cat ${DBDIR}/emaillevel`"
  fi

  if [ -e "${DBDIR}/duwarn" ] ; then
    export DUWARN="`cat ${DBDIR}/duwarn`"
  else
    export DUWARN=85
  fi

  case $EMAILMODE in
      ALL|WARN|ERROR) ;;
	*) export EMAILMODE="WARN";;
  esac

  if [ -e "${DBDIR}/emails" ] ; then
    export EMAILADDY="`cat ${DBDIR}/emails`"
  fi

}
setOpts


# Check if a directory is mounted
isDirMounted() {
  mount | grep -q "on $1 ("
  return $?
}

mkZFSSnap() {
  if [ "$RECURMODE" = "ON" ] ; then
     flags="-r"
  else
     flags="-r"
  fi
  zdate=`date +%Y-%m-%d-%H-%M-%S`
  zfs snapshot $flags ${1}@$2${zdate} >${CMDLOG} 2>${CMDLOG}
  return $?
}

listZFSSnap() {
  zfs list -t snapshot | grep -e "^NAME" -e "^${1}@"
}

rmZFSSnap() {
  `zfs list -t snapshot | grep -q "^$1@$2 "` || exit_err "No such snapshot!"
  if [ "$RECURMODE" = "ON" ] ; then
     flags="-r"
  else
     flags="-r"
  fi
  zfs destroy -r ${1}@${2} >${CMDLOG} 2>${CMDLOG}
  return $?
}

revertZFSSnap() {
  # Make sure this is a valid snapshot
  `zfs list -t snapshot | grep -q "^$1@$2 "` || exit_err "No such snapshot!"

  # Rollback the snapshot
  zfs rollback -R -f ${1}@$2
}

enable_cron()
{
   cronscript="${PROGDIR}/backend/runsnap.sh"

   # Make sure we remove any old entries for this dataset
   cat /etc/crontab | grep -v " $cronscript $1" > /etc/crontab.new
   mv /etc/crontab.new /etc/crontab
   if [ "$2" = "OFF" ] ; then
      return 
   fi

   case $2 in
       daily) cLine="0       $4      *       *       *" ;;
      hourly) cLine="0       *       *       *       *" ;;
       30min) cLine="0,30    *       *       *       *" ;;
       10min) cLine="*/10    *       *       *       *" ;;
   5min|auto) cLine="*/5     *       *       *       *" ;;
           *) exit_err "Invalid time specified" ;;
   esac 

   echo -e "$cLine\troot    ${cronscript} $1 $3" >> /etc/crontab
}

enable_watcher()
{
   cronscript="${PROGDIR}/backend/zfsmon.sh"

   # Check if the zfs monitor is already enabled
   grep -q " $cronscript" /etc/crontab
   if [ $? -eq 0 ] ; then return; fi

   cLine="*/30    *       *       *       *"

   echo -e "$cLine\troot    ${cronscript}" >> /etc/crontab
}

snaplist() {
  zfs list -t snapshot | grep "^${1}@" | cut -d '@' -f 2 | awk '{print $1}'
}

echo_log() {
   echo "`date`: $@" >> ${LOGDIR}/lpreserver.log 
}

# E-Mail a message to the set addresses
# 1 = subject tag
# 2 = Message
email_msg() {
   if [ -z "$EMAILADDY" ] ; then return ; fi
   echo -e "$2"  | mail -s "$1 - `hostname`" $EMAILADDY
}

queue_msg() {
  echo -e "$1" >> ${MSGQUEUE}
  if [ -n "$2" ] ; then
    cat $2 >> ${MSGQUEUE}
  fi
}

echo_queue_msg() {
  if [ ! -e "$MSGQUEUE" ] ; then return ; fi
  cat ${MSGQUEUE}
  rm ${MSGQUEUE}
}

add_rep_task() {
  # add freenas.8343 backupuser 22 tank1/usr/home/kris tankbackup/backups sync
  HOST=$1
  USER=$2
  PORT=$3
  LDATA=$4
  RDATA=$5
  TIME=$6

  case $TIME in
     [0-9][0-9]|sync)  ;;
     *) exit_err "Invalid time: $TIME"
  esac
 
  echo "Adding replication task for local dataset $LDATA"
  echo "----------------------------------------------------------"
  echo "   Remote Host: $HOST" 
  echo "   Remote User: $USER" 
  echo "   Remote Port: $PORT" 
  echo "Remote Dataset: $RDATA" 
  echo "          Time: $TIME" 
  echo "----------------------------------------------------------"
  echo "Don't forget to ensure that this user / dataset exists on the remote host"
  echo "with the correct permissions!"

  rem_rep_task "$LDATA"
  echo "$LDATA:$TIME:$HOST:$USER:$PORT:$RDATA" >> ${REPCONF}

  if [ "$TIME" != "sync" ] ; then
    cronscript="${PROGDIR}/backend/runrep.sh"
    cLine="0    $TIME       *       *       *"
    echo -e "$cLine\troot    ${cronscript} ${LDATA}" >> /etc/crontab
  fi
}

rem_rep_task() {
  if [ ! -e "$REPCONF" ] ; then return ; fi
  cat ${REPCONF} | grep -v "^${1}:" > ${REPCONF}.tmp
  mv ${REPCONF}.tmp ${REPCONF}

  # Make sure we remove any old replication entries for this dataset
  cronscript="${PROGDIR}/backend/runrep.sh"
  cat /etc/crontab | grep -v " $cronscript $1" > /etc/crontab.new
  mv /etc/crontab.new /etc/crontab
}

list_rep_task() {
  if [ ! -e "$REPCONF" ] ; then return ; fi

  echo "Scheduled replications:"
  echo "---------------------------------"

  while read line
  do
     LDATA=`echo $line | cut -d ':' -f 1`
     TIME=`echo $line | cut -d ':' -f 2`
     HOST=`echo $line | cut -d ':' -f 3`
     USER=`echo $line | cut -d ':' -f 4`
     PORT=`echo $line | cut -d ':' -f 5`
     RDATA=`echo $line | cut -d ':' -f 6`

     echo "$LDATA -> $USER@$HOST[$PORT]:$RDATA Time: $TIME"

  done < ${REPCONF}
}

check_rep_task() {
  export DIDREP=0
  if [ ! -e "$REPCONF" ] ; then return 0; fi

  repLine=`cat ${REPCONF} | grep "^${1}:"`
  if [ -z "$repLine" ] ; then return 0; fi

  # We have a replication task for this dataset, lets check if we need to do it now
  LDATA="$1"
  REPTIME=`echo $repLine | cut -d ':' -f 2`

  # Export the replication variables we will be using
  export REPHOST=`echo $repLine | cut -d ':' -f 3`
  export REPUSER=`echo $repLine | cut -d ':' -f 4`
  export REPPORT=`echo $repLine | cut -d ':' -f 5`
  export REPRDATA=`echo $repLine | cut -d ':' -f 6`

  if [ "$2" = "force" ] ; then
     # Ready to do a forced replication
     export DIDREP=1
     echo_log "Starting replication MANUAL task on ${DATASET}: ${REPLOGSEND}"
     queue_msg "`date`: Starting replication MANUAL task on ${DATASET}\n"
     start_rep_task "$LDATA"
     return $?
  fi

  # If we are checking for a sync task, and the rep isn't marked as sync we can return
  if [ "$2" = "sync" -a "$REPTIME" != "sync" ] ; then return 0; fi

  # Doing a replication task, check if one is in progress
  export pidFile="${DBDIR}/.reptask-`echo ${LDATA} | sed 's|/|-|g'`"
  if [ -e "${pidFile}" ] ; then
     pgrep -F ${pidFile} >/dev/null 2>/dev/null
     if [ $? -eq 0 ] ; then
        echo_log "Skipped replication on $LDATA, previous replication is still running."
        return 0
     else
        rm ${pidFile}
     fi
  fi

  # Save this PID
  echo "$$" > ${pidFile}

  # Is this a sync-task we do at the time of a snapshot?
  if [ "$2" = "sync" -a "$REPTIME" = "sync" ] ; then
     export DIDREP=1
     echo_log "Starting replication SYNC task on ${DATASET}: ${REPLOGSEND}"
     queue_msg "`date`: Starting replication SYNC task on ${DATASET}\n"
     start_rep_task "$LDATA"
     return $?
  else
     # Ready to do a scheduled replication
     export DIDREP=1
     echo_log "Starting replication SCHEDULED task on ${DATASET}: ${REPLOGSEND}"
     queue_msg "`date`: Starting replication SCHEDULED task on ${DATASET}\n"
     start_rep_task "$LDATA"
     return $?
  fi
}

start_rep_task() {
  LDATA="$1"
  hName=`hostname`

  # Check for the last snapshot marked as replicated already
  lastSEND=`zfs get -r backup:lpreserver ${LDATA} | grep LATEST | awk '{$1=$1}1' OFS=" " | tail -1 | cut -d '@' -f 2 | cut -d ' ' -f 1`

  # Lets get the last snapshot for this dataset
  lastSNAP=`zfs list -t snapshot -d 1 -H ${LDATA} | tail -1 | awk '{$1=$1}1' OFS=" " | cut -d '@' -f 2 | cut -d ' ' -f 1`
 
  if [ "$lastSEND" = "$lastSNAP" ] ; then
     queue_msg "`date`: Last snapshot $lastSNAP is already marked as replicated!"
     rm ${pidFile}
     return 1
  fi

  # Starting replication, first lets check if we can do an incremental send
  if [ -n "$lastSEND" ] ; then
     zFLAGS="-Rv -I $lastSEND $LDATA@$lastSNAP"
  else
     zFLAGS="-Rv $LDATA@$lastSNAP"

     # This is a first-time replication, lets create the new target dataset
     ssh -p ${REPPORT} ${REPUSER}@${REPHOST} zfs create ${REPRDATA}/${hName} >${CMDLOG} 2>${CMDLOG}
  fi

  zSEND="zfs send $zFLAGS"
  zRCV="ssh -p ${REPPORT} ${REPUSER}@${REPHOST} zfs receive -dvuF ${REPRDATA}/${hName}"

  queue_msg "Using ZFS send command:\n$zSEND | $zRCV\n\n"

  # Start up our process
  $zSEND 2>${REPLOGSEND} | $zRCV >${REPLOGRECV} 2>${REPLOGRECV}
  zStatus=$?
  queue_msg "ZFS SEND LOG:\n--------------\n" "${REPLOGSEND}"
  queue_msg "ZFS RCV LOG:\n--------------\n" "${REPLOGRECV}"

  if [ $zStatus -eq 0 ] ; then
     # SUCCESS!
     # Lets mark our new latest snapshot and unmark the last one
     if [ -n "$lastSEND" ] ; then
       zfs set backup:lpreserver=' ' ${LDATA}@$lastSEND
     fi
     zfs set backup:lpreserver=LATEST ${LDATA}@$lastSNAP
     echo_log "Finished replication task on ${DATASET}"
     save_rep_props
     zStatus=$?
  else
     # FAILED :-(
     # Lets save the output for us to look at later
     FLOG=${LOGDIR}/lpreserver_failed.log
     echo "Failed with command:\n$zSEND | $zRCV\n" > ${FLOG}
     echo "\nSending log:\n" >> ${FLOG}
     cat ${REPLOGSEND} >> ${FLOG}
     echo "\nRecv log:\n" >> ${FLOG}
     cat ${REPLOGRECV} >> ${FLOG}
     echo_log "FAILED replication task on ${DATASET}: LOGFILE: $FLOG"
  fi

  rm ${pidFile}
  return $zStatus
}

save_rep_props() {
  # If we are not doing a recursive backup / complete dataset we can skip this
  if [ "$RECURMODE" != "ON" ] ; then return 0; fi
  if [ "`basename $DATASET`" != "$DATASET" ] ; then return 0; fi
  hName="`hostname`"

  echo_log "Saving dataset properties for: ${DATASET}"
  queue_msg "`date`: Saving dataset properties for: ${DATASET}\n"

  # Lets start by building a list of props to keep
  rProp=".lp-props-`echo ${REPRDATA}/${hName} | sed 's|/|#|g'`"

  zfs get -r all $DATASET | grep ' local$' | awk '{$1=$1}1' OFS=" " | sed 's| local$||g' \
	| ssh -p ${REPPORT} ${REPUSER}@${REPHOST} "cat > \"$rProp\""
  if [ $? -eq 0 ] ; then
    echo_log "Successful save of dataset properties for: ${DATASET}"
    queue_msg "`date`: Successful save of dataset properties for: ${DATASET}\n"
    return 0
  else
    echo_log "Failed saving dataset properties for: ${DATASET}"
    queue_msg "`date`: Failed saving dataset properties for: ${DATASET}\n"
    return 1
  fi
}

listStatus() {

  for i in `grep "${PROGDIR}/backend/runsnap.sh" /etc/crontab | awk '{print $8}'`
  do
    echo -e "DATASET - SNAPSHOT - REPLICATION"
    echo "------------------------------------------"

    lastSEND=`zfs get -r backup:lpreserver ${i} | grep LATEST | awk '{$1=$1}1' OFS=" " | tail -1 | cut -d '@' -f 2 | cut -d ' ' -f 1`
    lastSNAP=`zfs list -t snapshot -d 1 -H ${i} | tail -1 | awk '{$1=$1}1' OFS=" " | cut -d '@' -f 2 | cut -d ' ' -f 1`

    if [ -z "$lastSEND" ] ; then lastSEND="NONE"; fi
    if [ -z "$lastSNAP" ] ; then lastSNAP="NONE"; fi

    echo "$i - $lastSNAP - $lastSEND"
  done
}

add_zpool_disk() {
   pool="$1"
   disk="$2"
   disk="`echo $disk | sed 's|/dev/||g'`"

   if [ -z "$pool" ] ; then
      exit_err "No pool specified"
      exit 0
   fi

   if [ -z "$disk" ] ; then
      exit_err "No disk specified"
      exit 0
   fi

   if [ ! -e "/dev/$disk" ] ; then
      exit_err "No such device: $disk"
      exit 0
   fi

   zpool list -H -v | awk '{print $1}' | grep -q "^$disk"
   if [ $? -eq 0 ] ; then
      exit_err "Error: This disk is already apart of a zpool!"
   fi

   # Check if pool exists
   zpool status $pool >/dev/null 2>/dev/null
   if [ $? -ne 0 ] ; then exit_err "Invalid pool: $pool"; fi

   # Cleanup the target disk
   echo "Deleting all partitions on: $disk"
   rc_nohalt "gpart destroy -F $disk" >/dev/null 2>/dev/null
   rc_nohalt "dd if=/dev/zero of=/dev/${disk} bs=1m count=1" >/dev/null 2>/dev/null
   rc_nohalt "dd if=/dev/zero of=/dev/${disk} bs=1m oseek=`diskinfo /dev/${disk} | awk '{print int($3 / (1024*1024)) - 4;}'`" >/dev/null 2>/dev/null

   # Grab the first disk in the pool
   mDisk=`zpool list -H -v | grep -v "^$pool" | awk '{print $1}' | grep -v "^mirror" | grep -v "^raidz" | head -n 1`

   # Is this MBR or GPT?
   echo $mDisk | grep -q 's[0-4][a-z]$'
   if [ $? -eq 0 ] ; then
      # MBR
      type="MBR"
      # Strip off the "a-z"
      rDiskDev=`echo $mDisk | rev | cut -c 2- | rev`
   else
      # GPT
      type="GPT"
      # Strip off the "p[1-9]"
      rDiskDev=`echo $mDisk | rev | cut -c 3- | rev`
   fi

   # Make sure this disk has a layout we can read
   gpart show $rDiskDev >/dev/null 2>/dev/null
   if [ $? -ne 0 ] ; then 
      exit_err "failed to get disk device layout $rDiskDev"
   fi

   # Get the size of "freebsd-zfs & freebsd-swap"
   sSize=`gpart show ${rDiskDev} | grep freebsd-swap | cut -d "(" -f 2 | cut -d ")" -f 1`
   zSize=`gpart show ${rDiskDev} | grep freebsd-zfs | cut -d "(" -f 2 | cut -d ")" -f 1`
   
   echo "Creating new partitions on $disk"
   if [ "$type" = "MBR" ] ; then
      # Create the new MBR layout
      rc_halt_s "gpart create -s MBR -f active $disk"
      rc_halt_s "gpart add -a 4k -t freebsd $disk"	
      rc_halt_s "gpart set -a active -i 1 $disk"
      rc_halt_s "gpart create -s BSD ${disk}s1"
      rc_halt_s "gpart add -t freebsd-zfs -s $zSize ${disk}s1"
      if [ -n "$sSize" ] ; then
        rc_halt_s "gpart add -t freebsd-swap -s $sSize ${disk}s1"
      fi
      aDev="${disk}s1a"
   else
      # Creating a GPT disk
      rc_halt_s "gpart create -s GPT $disk"
      rc_halt_s "gpart add -b 34 -s 1M -t bios-boot $disk"
      rc_halt_s "gpart add -t freebsd-zfs -s $zSize ${disk}"
      if [ -n "$sSize" ] ; then
        rc_halt_s "gpart add -t freebsd-swap -s $sSize ${disk}"
      fi
      aDev="${disk}p2"
   fi

   # Now we can insert the target disk
   echo "Attaching to zpool: $aDev"
   rc_halt_s "zpool attach $pool $mDisk $aDev"

   # Lastly we need to stamp GRUB
   echo "Stamping GRUB on: $disk"
   rc_halt_s "grub-install --force /dev/${disk}"

   echo "Added $disk ($aDev) to zpool $pool. Resilver will begin automatically."
   exit 0
}

list_zpool_disks() {
   pool="$1"

   if [ -z "$pool" ] ; then
      exit_err "No pool specified"
      exit 0
   fi

   # Check if pool exists
   zpool status $pool >/dev/null 2>/dev/null
   if [ $? -ne 0 ] ; then exit_err "Invalid pool: $pool"; fi

   zpool list -H -v $pool
}

rem_zpool_disk() {
   pool="$1"
   disk="$2"

   if [ -z "$pool" ] ; then
      exit_err "No pool specified"
      exit 0
   fi

   if [ -z "$disk" ] ; then
      exit_err "No disk specified"
      exit 0
   fi

   # Check if pool exists
   zpool status $pool >/dev/null 2>/dev/null
   if [ $? -ne 0 ] ; then exit_err "Invalid pool: $pool"; fi

   zpool detach $pool $disk
   if [ $? -ne 0 ] ; then
      exit_err "Failed detaching $disk"
   fi 
   echo "$disk was detached successfully!"
   exit 0
}

offline_zpool_disk() {
   pool="$1"
   disk="$2"

   if [ -z "$pool" ] ; then
      exit_err "No pool specified"
      exit 0
   fi

   if [ -z "$disk" ] ; then
      exit_err "No disk specified"
      exit 0
   fi

   # Check if pool exists
   zpool status $pool >/dev/null 2>/dev/null
   if [ $? -ne 0 ] ; then exit_err "Invalid pool: $pool"; fi

   zpool offline $pool $disk
   exit $?
}

online_zpool_disk() {
   pool="$1"
   disk="$2"

   if [ -z "$pool" ] ; then
      exit_err "No pool specified"
      exit 0
   fi

   if [ -z "$disk" ] ; then
      exit_err "No disk specified"
      exit 0
   fi

   # Check if pool exists
   zpool status $pool >/dev/null 2>/dev/null
   if [ $? -ne 0 ] ; then exit_err "Invalid pool: $pool"; fi

   zpool online $pool $disk
   exit $?
}

init_rep_task() {

  LDATA="$1"

  repLine=`cat ${REPCONF} | grep "^${LDATA}:"`
  if [ -z "$repLine" ] ; then return 0; fi
 
  # We have a replication task for this set, get some vars
  hName=`hostname`
  REPHOST=`echo $repLine | cut -d ':' -f 3`
  REPUSER=`echo $repLine | cut -d ':' -f 4`
  REPPORT=`echo $repLine | cut -d ':' -f 5`
  REPRDATA=`echo $repLine | cut -d ':' -f 6`

  # First check if we even have a dataset on the remote
  ssh -p ${REPPORT} ${REPUSER}@${REPHOST} zfs list ${REPRDATA}/${hName} 2>/dev/null >/dev/null
  if [ $? -eq 0 ] ; then
     # Lets cleanup the remote side
     echo "Removing remote dataset: ${REPRDATA}/${hName}"
     ssh -p ${REPPORT} ${REPUSER}@${REPHOST} zfs destroy -r ${REPRDATA}/${hName}
     if [ $? -ne 0 ] ; then
        echo "Warning: Could not delete remote dataset ${REPRDATA}/${hName}"
     fi
  fi

  # Now lets mark none of our datasets as replicated
  lastSEND=`zfs get -r backup:lpreserver ${LDATA} | grep LATEST | awk '{$1=$1}1' OFS=" " | tail -1 | cut -d '@' -f 2 | cut -d ' ' -f 1`
  if [ -n "$lastSEND" ] ; then
     zfs set backup:lpreserver=' ' ${LDATA}@$lastSEND
  fi

}

## Function to remove the oldest life-preserver snapshot on the target
## zpool, used by zfsmon.sh when the disk space gets low
do_pool_cleanup()
{
  # Is this zpool managed by life-preserver?
  grep -q "${PROGDIR}/backend/runsnap.sh ${1} " /etc/crontab
  if [ $? -ne 0 ] ; then return ; fi

  # Before we start pruning, check if any replication is running
  local pidFile="${DBDIR}/.reptask-`echo ${1} | sed 's|/|-|g'`"
  if [ -e "${pidFile}" ] ; then
     pgrep -F ${pidFile} >/dev/null 2>/dev/null
     if [ $? -eq 0 ] ; then return; fi
  fi

  # Get the list of snapshots for this zpool
  snapList=$(snaplist "${1}")

  # Do any pruning
  for snap in $snapList
  do
     # Only remove snapshots which are auto-created by life-preserver
     cur="`echo $snap | cut -d '-' -f 1`"
     if [ "$cur" != "auto" ] ; then continue; fi

     echo_log "Pruning old snapshot: $snap"
     rmZFSSnap "${1}" "$snap"
     if [ $? -ne 0 ] ; then
       haveMsg=1
       echo_log "ERROR: (Low Disk Space) Failed pruning snapshot $snap on ${1}"
       queue_msg "ERROR: (Low Disk Space) Failed pruning snapshot $snap on ${1} @ `date` \n\r`cat $CMDLOG`"
     else
       queue_msg "(Low Disk Space) Auto-pruned snapshot: $snap on ${1} @ `date`\n\r`cat $CMDLOG`"
       haveMsg=1
     fi

     # We only prune a single snapshot at this time, so lets end
     break
  done

  return 0
}
