#!/bin/sh

if [ "`id -u`" = "0" ] ; then return ; 
elif [ "${PCDM_SESSION}" = "LUMINA" ]; then return ; #don't need this on Lumina DE
fi

#Startup the mixer tray
(sleep 69 ; pc-mixer ) &

