#!/bin/bash 
BDEV=$1
INTERVAL=$2
echo "nvcap/B,dfcap/KB"
while [ 1 ] 
do
  sleep ${INTERVAL}
  nvcap=`nvme list --output-format=json | grep -A 8 ${BDEV} | grep UsedBytes | awk -F : '{print $2}' | awk -F , '{print $1}'`
  dfcap=`df -k | grep ${BDEV} | awk '{print $3}'`
  echo "${nvcap},${dfcap}"
done

