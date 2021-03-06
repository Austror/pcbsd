#!/bin/sh

# Enable loading the virtualbox kernel modules
grep '^vboxdrv_load="YES"' /boot/loader.conf >/dev/null 2>/dev/null
if [ $? -ne 0 ] ; then
        echo 'vboxdrv_load="YES"' >>/boot/loader.conf
fi

# Enable loading the vboxnet drivers
grep '^vboxnet_enable="YES"' /etc/rc.conf >/dev/null 2>/dev/null
if [ $? -ne 0 ] ; then
        echo 'vboxnet_enable="YES"' >>/etc/rc.conf
fi

# Load the kernel module
kldload vboxdrv

# Load the vbox net service
service vboxnet start

# Rebuild grub config so that module gets loaded at start
grub-mkconfig -o /boot/grub/grub.cfg

exit 0
