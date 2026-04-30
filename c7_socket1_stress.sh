#!/bin/bash

num_proc=$(($(nproc)-1))
echo "offline $num_proc CPUs"
for i in `seq 1 $num_proc`; do
        echo 0 > /sys/devices/system/cpu/cpu${i}/online &
done
wait
echo "online $num_proc CPUs"
for i in `seq 1 $num_proc`; do
        echo 1 > /sys/devices/system/cpu/cpu${i}/online &
done
wait

