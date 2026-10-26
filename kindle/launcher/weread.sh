#!/bin/sh
# Name: 微信读书
# Author: weread-kindle
# DontUseFBInk

# 第一次运行（比如用 USB 拷贝安装）时在本机生成 run.sh
[ -x /mnt/us/weread/run.sh ] || sh /mnt/us/weread/launcher/make-run.sh
/mnt/us/weread/run.sh
