#!/bin/sh

netserver
iperf -u -s &
iperf -s &
fortio server


