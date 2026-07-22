#!/bin/sh
(trap '' HUP TERM; sleep 2) &
trap 'exit 0' TERM INT
while :; do
    :
done
