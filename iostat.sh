#!/bin/bash

usage() {
    echo ""
    echo "usage: $0 [-i nrdisks] [-a nrdata] [-c nrcoding] [-p port] [-t test-dir] [-s hyperiod-dir] [-j injector-bin] [-f payload-file]"
    echo "    -i number of disks"
    echo "    -a number of data parts"
    echo "    -c number of coding parts"
    echo "    -p hyperiod port number"
    echo "    -t test directory, example: '/tmp/test-hyperiod'"
    echo "    -s hyperdrive server directory, example '/home/user/hyperdrive'"
    echo "    -j injector binary, /home/user/golang/hd_bench/src/injector"
    echo "    -f payload file, '/tmp/10Mo'"
    echo "    -n number of worker(s) in injector"
    echo "    -k number of keys by injector"
    echo ""
    exit 1
}

while getopts 'i:a:c:p:t:s:j:f:n:k:' OPTION; do
  case "$OPTION" in
    i) NR_DISKS=$OPTARG;;
    a) NR_DATA="$OPTARG";;
    c) NR_CODING=$OPTARG;;
    p) PORT=$OPTARG;;
    t) TEST_DIR=$OPTARG;;
    s) HYPERIOD_DIR=$OPTARG;;
    j) INJECTOR_BIN=$OPTARG;;
    f) PAYLOAD=$OPTARG;;
    n) INJECTOR_WORKERS=$OPTARG;;
    k) INJECTOR_KEYS=$OPTARG;;
    ?) usage;;
  esac
done
shift "$((OPTIND -1))"

([ -z "$NR_DISKS" ] || [ -z "$NR_DATA" ] || [ -z "$INJECTOR_WORKERS" ] || \
[ -z "$NR_CODING" ] || [ -z "$PORT" ] || [ -z "$INJECTOR_KEYS" ] || \
[ -z "$TEST_DIR" ] || [ -z "$HYPERIOD_DIR" ] || \
[ -z "$INJECTOR_BIN" ] || [ -z "$PAYLOAD" ]) && { usage; }

clean_all() {
    local port=$1
    local root_dir=$2

    current_root=${root_dir}/${port}

    proc=$(cat "${current_root}/hyperiod_${port}.pid")
    if [ ! -z "${proc}" ]
    then
        echo "kill -9 ${proc}"
        kill -9 "${proc}"
    fi

    echo "remove ${root_dir}/${port}"
    rm -rf "${root_dir:?}/${port}"
}

launch_server() {
    local nr_disks=$1
    local nr_data=$2
    local nr_coding=$3
    local port=$4
    local root_dir=$5

    current_root=${root_dir}/${port}

    mkdir -p "${current_root}"

    args_dir=""

    index=${root_dir}/${port}/index
    index_bak=${root_dir}/${port}/index.bak

    disks=$(disk_select "$nr_disks")

    echo "disks: $disks"

    for disk in $disks
    do
        args_dir="${args_dir} -D ${disk} "
    done

    cmd="
    ${HYPERIOD_DIR}/build/src/hyperiod/hyperiod-dev \
    -H 127.0.0.1:${port} \
    -wdl \
    -o group.nrdata=${nr_data} -o group.nrcoding=${nr_coding} \
    -o global.log=http:info,debug \
    -o dev.extent_total_size=268435456 \
    -o group.percentage_closing=95 \
    -o group.nrfail_closing=5 \
    -o group.reloc_percent_threshold=75 \
    -c ${HYPERIOD_DIR}/config/hyperdrive.conf \
    ${args_dir} \
    --pid-file ${current_root}/hyperiod_${port}.pid \
    -o global.dbname_path=${index} \
    -o global.dbname_backup_path=${index_bak} \
    -W ${current_root}/hyperiod.log
    "
    $cmd
    echo "$cmd"

}


plot_histo() {
local datafile=$1
local outputfile=$2

gnuplot <<- EOF
reset
n=100 #number of intervals
max=110. #max value
min=0. #min value
width=(max-min)/n #interval width
#function used to map a value to the intervals
hist(x,width)=width*floor(x/width)+width/2.0
set term png #output terminal and file
set output "$outputfile"
set xrange [min:max]
set yrange [0:1000]
#to put an empty boundary around the
#data inside an autoscaled graph.
set offset graph 0.05,0.05,0.05,0.0
set xtics min,(max-min)/5,max
set boxwidth width*0.9
set style fill solid 0.5 #fillstyle
set tics out nomirror
set xlabel "%util"
set ylabel "nr occurrences"
#count and plot
plot "$datafile" u (hist(\$1,width)):(1.0) smooth freq w boxes lc rgb"blue" notitle
EOF
}

plot_multi_disks(){
local nr_disks=$1
gnuplot <<- EOF
reset
set term png size 1920,1080

# puts x-label and y-label manually
set label 1 'seconds' at screen 0.49,0.02
set label 2 '% util' at screen 0.5,0.5 rotate by 90

set yrange [0:110]

set output "multi_${NR_DISKS}disks_${NR_DATA}+${NR_CODING}.png"
set multiplot layout $nr_disks,1 title "$2" font ",12"
do for [i=1:$nr_disks] {
plot 'disk'.i.'.csv' with linespoints linestyle 1 title 'Disk '.i
}
EOF
}

disk_select() {
local N=$1
disk_list=""
disk_alpha="abcdefghijklmnopqrstu"
for i in $(seq 1 "$N")
do
   disk_list="$disk_list /scality/sd${disk_alpha:$i:1}"
   [ "$i" -eq "$N" ] && break
done

echo "$disk_list"
}

# Globals
DISKS=$(disk_select "$NR_DISKS")
LOG_FILE=/tmp/iostat_${NR_DISKS}disks_${NR_DATA}+${NR_CODING}_PUT.log
CSV_FILE="iostat_${NR_DISKS}disks_${NR_DATA}+${NR_CODING}_PUT.csv"
IMG_FILE=histo_${NR_DISKS}disks_${NR_DATA}+${NR_CODING}_$(basename "$PAYLOAD").png

main() {
killall iostat
clean_all "$PORT" "${TEST_DIR}"
launch_server "${NR_DISKS}" "${NR_DATA}" "${NR_CODING}" "${PORT}" "${TEST_DIR}" 2>&1 | tee server.log &

netstat -laputen |grep -q "${PORT}.*LISTEN"
ret=$?
while [ $ret -ne 0 ]
do
    echo "Wait for HD server to be in LISTEN mode, port: $PORT"
    sleep 0.1
    $(netstat -laputen |grep -q "${PORT}.*LISTEN")
    ret=$?
done

iostat -x 1 2>&1 |tee "${LOG_FILE}" &
${INJECTOR_BIN} -hd-type=client -nrkeys="$INJECTOR_KEYS" -w "$INJECTOR_WORKERS" -payload-file="$PAYLOAD" -port="${PORT}" -nrinstances=1 -operations="put"

killall iostat

# Compute iostat into a csv file
rm "${CSV_FILE}"
i=1
for disk in ${DISKS[*]}
do
grep -r "$(basename "${disk}")" "$LOG_FILE" | awk '{print $14}' |sed s/,/./g  >> "${CSV_FILE}"
grep -r "$(basename "${disk}")" "$LOG_FILE" | awk '{print $14}' |sed s/,/./g > disk${i}.csv
i=$((i + 1))
done

echo "Report here ${CSV_FILE}"

# Gnuplot
echo "Plot histogram $IMG_FILE"
plot_histo "${CSV_FILE}" "${IMG_FILE}"

plot_multi_disks "${NR_DISKS}"
}

main
