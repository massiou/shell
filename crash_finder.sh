#!/bin/bash

NRKEYS=100
NRDATA=5
NRCODING=1
SCRIPT_DIR=$(dirname $(readlink -f $0))
INJECTOR_BINARY="${SCRIPT_DIR}/../../tools/injector/injector"
HD_BINARY="${SCRIPT_DIR}/../../build/src/hyperiod/hyperiod-dev"
HD_CONF="${SCRIPT_DIR}/../../config/hyperdrive.conf"
HD_PORT="4250"
HD_ROOTDIR="/scality/sdb/hyperiod-test/${HD_PORT}"
HD_MOUNTPOINT="/scality/"
DISKS="sdo sdp sdq sdr sds sdt sdu"
LOGFILE="${HD_ROOTDIR}/hyperiod_${HD_PORT}.log"
OUTPUT="${HD_ROOTDIR}/restart_bench.log"
INJECTOR_LOG="$HD_ROOTDIR/injector.log"

show_help()
{
  echo "$0 -m [-HD_MOUNTPOINT] -r [HD_ROOTDIR] -p [HD_PORT] -d [DISKS] -w [WORKERS] -k [NRKEYS]"
}

OPTIND=1 # Reset in case getopts has been used previously in the shell.

while getopts "h?d:m:p:r:w:" opt; do
    case "$opt" in
    h|\?)
        show_help
        exit 0
        ;;
    d)  DISKS=$OPTARG
        NRDISKS=$(echo $DISKS |wc -w)
        # Cast string into an array
        DISKS=(`echo ${DISKS}`)
        ;;
    k)  NRKEYS=$OPTARG
        ;;
    p)  HD_PORT=$OPTARG
        ;;
    m)  HD_MOUNTPOINT=$OPTARG
        ;;
    r)  HD_ROOTDIR=$OPTARG
        ;;
    w)  WORKERS=$OPTARG
        ;;
    esac
done

shift $((OPTIND-1))

[ "${1:-}" = "--" ] && shift

HD_ROOTDIR=${HD_ROOTDIR}/${HD_PORT}


test_file_exists()
{
  local file=$1
  test ! -f ${file} && echo "${file} does not exist" && exit 1
}

test_dir_exists()
{
  test ! -d ${file} && echo "${file} does not exist" && exit 1
}

test_dir_exists ${HD_MOUNTPOINT}
test_dir_exists ${HD_ROOTDIR}
test_file_exists ${INJECTOR_BINARY}
test_file_exists ${HD_BINARY}

get_extents()
{   n=0
    for disk in "${DISKS[@]}"
    do
      nr_ext=$(find ${HD_MOUNTPOINT}/${disk} -type f -regex "${HD_MOUNTPOINT}/${disk}/[A-F0-9][A-F0-9]/[A-F0-9]*" |wc -l)
      n=$((n + nr_ext))
    done
    echo $n
}

wait_str_in_log()
{
   n=0
   grep --quiet "$1" ${LOGFILE}
   r=$?
   local number=$2
   [ -z "$number" ] && number=1
   while :
   do
       N=$(grep ."$1" ${LOGFILE} | wc -l)
       [ $N -eq $number ] && break
       sleep 0.1
       n=$((n + 1))
       [ ${n} -eq 30000 ] && echo "$1: too long..." && cat $LOGFILE > log && exit 1
   done
}

fuzz_random_extent()
{
  r=$((RANDOM % NRDISKS + 1))
  disk=${DISKS[$r]}
  ext=$(find ${HD_MOUNTPOINT}/${disk} -type f -perm -400 |head -n 1)
  curl -v -H "Accept: application/x-scality-storage-data" -GET "http://localhost:$HD_PORT/debug/extent/fuzz?path=${ext}&operation=read"
}

start_hyperiod()
{
  disks_cmd=""
  for disk in "${DISKS[@]}"
  do
      disks_cmd=$disks_cmd"-D ${HD_MOUNTPOINT}/${disk} "
  done

   cmd="${HD_BINARY} \
   -H 127.0.0.1:${HD_PORT} -wdl \
   -o group.nrdata=${NRDATA} \
   -o group.nrcoding=${NRCODING} \
   -o global.extent_total_size=268435456 \
   -o group.percentage_closing=95 \
   -o group.nrfail_closing=5 \
   -o group.reloc_percent_threshold=75 \
   -c ${HD_CONF} \
   $disks_cmd \
   -o global.dbname_path=${HD_ROOTDIR}/index \
   -o global.dbname_backup_path=${HD_ROOTDIR}/index.bak \
   -W $LOGFILE"

   $cmd &

   n=0
   while [ ! -f ${LOGFILE} ]
   do
       sleep 0.1
       n=$((n + 1))
       [ ${n} -eq 100 ] && echo "start hyperiod too long..." && cat $LOGFILE && exit 1
   done
}

remove_all_extents()
{
  for disk in "${DISKS[@]}"
  do 
      find ${HD_MOUNTPOINT}/$disk -type f -regex "${HD_MOUNTPOINT}/${disk}/[A-F0-9][A-F0-9]/[A-F0-9]*" -delete
  done
}

main() 
{
  # Clean
  killall hyperiod-dev
  rm -f ${OUTPUT}
  remove_all_extents
  rm -rf ${HD_ROOTDIR}/index/*
  rm -f ${LOGFILE}
  rm -f ${INJECTOR_LOG}

  echo "Start test" > $OUTPUT

  index=0
  while true
  do
    # Wait for hyperiod to start
    start_hyperiod
    wait_str_in_log "started hyperiod"
    
    [ "${index}" != "0" ] && fuzz_random_extent

    # Launch injector
    ${INJECTOR_BINARY} \
    -w ${WORKERS} \
    -hd-type server \
    -nrkeys $NRKEYS \
    -payload-files '/tmp/10Mo /tmp/1Mo /tmp/1Ko /tmp/100Ko' \
    -operations 'put get del' \
    -port ${HD_PORT} \
    -nrinstances=1 2>&1 | tee -a ${INJECTOR_LOG}

    $cmd
    sleep 1
    [ $? != 0 ] && echo "Injector failed, see ${INJECTOR_LOG}" && exit 1
    
    nr_ext=$(get_extents) 
    echo "@@ nr keys: $NRKEYS" >> $OUTPUT
    echo "@@ nr ext: $nr_ext" >> $OUTPUT

    kill -15 $(pgrep hyperiod)
    wait_str_in_log "exiting process"

    mv ${LOGFILE} ${LOGFILE}_${index}
    index=$((index + 1))

  done

}

main
