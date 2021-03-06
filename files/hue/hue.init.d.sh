#!/bin/bash

# NOTE: This file is managed by Puppet.
# This file has been modified by the wikimedia/puppet-cdh module.
# It adds a --chuid flag to start-stop-daemon.  See the comment below,
# and https://issues.cloudera.org/browse/HUE-1398 for more info.

#
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.




### BEGIN INIT INFO
# Provides:          hue
# Required-Start:    $network $local_fs
# Required-Stop:
# Should-Start:      $named
# Should-Stop:
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Hue
# Description:       Hue Web Interface
### END INIT INFO

PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

DAEMON=/usr/lib/hue/build/env/bin/supervisor # Introduce the server's location here
NAME=hue              			# Introduce the short server's name here
DESC="Hue for Hadoop"                	# Introduce a short description here
LOGDIR=/var/log/hue  			# Log directory to use

PIDFILE=/var/run/hue/supervisor.pid

test -x $DAEMON || exit 0

. /lib/lsb/init-functions

# Default options, these can be overriden by the information
# at /etc/default/$NAME
DAEMON_OPTS="-p $PIDFILE -d -l $LOGDIR" # Additional options given to the server

DIETIME=10              # Time to wait for the server to die, in seconds
                        # If this value is set too low you might not
                        # let some servers to die gracefully and
                        # 'restart' will not work

STARTTIME=5             # Time to wait for the server to start, in seconds
                        # If this value is set each time the server is
                        # started (on start or restart) the script will
                        # stall to try to determine if it is running
                        # If it is not set and the server takes time
                        # to setup a pid file the log message might
                        # be a false positive (says it did not start
                        # when it actually did)

DAEMONUSER=hue     # Users to run the daemons as. If this value
                        # is set start-stop-daemon will chuid the server

# Include defaults if available
BIGTOP_DEFAULTS_DIR=${BIGTOP_DEFAULTS_DIR-/etc/default}
[ -n "${BIGTOP_DEFAULTS_DIR}" -a -r ${BIGTOP_DEFAULTS_DIR}/$NAME ] && . ${BIGTOP_DEFAULTS_DIR}/$NAME

# Use this if you want the user to explicitly set 'RUN' in
# /etc/default/
#if [ "x$RUN" != "xyes" ] ; then
#    log_failure_msg "$NAME disabled, please adjust the configuration to your needs "
#    log_failure_msg "and then set RUN to 'yes' in /etc/default/$NAME to enable it."
#    exit 1
#fi

# Check that the user exists (if we set a user)
# Does the user exist?
if [ -n "$DAEMONUSER" ] ; then
    if getent passwd | grep -q "^$DAEMONUSER:"; then
        # Obtain the uid and gid
        DAEMONUID=`getent passwd |grep "^$DAEMONUSER:" | awk -F : '{print $3}'`
        DAEMONGID=`getent passwd |grep "^$DAEMONUSER:" | awk -F : '{print $4}'`
    else
        log_failure_msg "The user $DAEMONUSER, required to run $NAME does not exist."
        exit 1
    fi
fi


set -e

running_pid() {
# Check if a given process pid's cmdline matches a given name
    pid=$1
    [ -z "$pid" ] && return 1
    [ ! -d /proc/$pid ] &&  return 1
    cmd=`cat /proc/$pid/cmdline | tr "\000" "\n"|head -n 1 |cut -d : -f 1`
    echo $cmd | grep -q python || return 1
    return 0
}

running() {
# Check if the process is running looking at /proc
# (works for all users)

    # No pidfile, probably no daemon present
    [ ! -f "$PIDFILE" ] && return 1
    pid=`cat $PIDFILE`
    running_pid $pid || return 1
    return 0
}

start_server() {
# Start the process using the wrapper
	export PYTHON_EGG_CACHE='/tmp/.hue-python-eggs'
        mkdir -p /usr/lib/hue/pids/
        mkdir -p ${PYTHON_EGG_CACHE}
        mkdir -p $(dirname $PIDFILE) $LOGDIR
        chown -R $DAEMONUSER $(dirname $PIDFILE) $LOGDIR ${PYTHON_EGG_CACHE}
        # dont setuid, since supervisor will drop privileges on its
        # own
        #PATH=/usr/lib/hue/build/env/bin:$PATH start-stop-daemon --start --quiet --pidfile $PIDFILE \
        #            --exec $DAEMON -- $DAEMON_OPTS

        # ===== wikimedia/puppet-cdh patch =====
        # THIS IS A BUG!  We need to honor $DAEMONUSER here.
        # supervisor.py is smart enough to know what to do.
        # See https://issues.cloudera.org/browse/HUE-1398.
        # This init.d script will be removed when a newer
        # version of hue (hopefully) fixes this.
        PATH=/usr/lib/hue/build/env/bin:$PATH start-stop-daemon --start --quiet --pidfile $PIDFILE \
            --chuid $DAEMONUSER --exec $DAEMON -- $DAEMON_OPTS

        errcode=$?
        return $errcode
}

stop_server() {
# Stop the process using the wrapper
        killproc -p $PIDFILE $DAEMON
        errcode=$?
        return $errcode
}

reload_server() {
    [ ! -f "$PIDFILE" ] && return 1
    pid=pidofproc $PIDFILE # This is the daemon's pid
    # Send a SIGHUP
    kill -1 $pid
    return $?
}

force_stop() {
# Force the process to die killing it manually
    [ ! -e "$PIDFILE" ] && return
    if running ; then
        kill -15 $pid
        # Is it really dead?
        sleep "$DIETIME"s
        if running ; then
            kill -9 $pid
            sleep "$DIETIME"s
            if running ; then
                echo "Cannot kill $NAME (pid=$pid)!"
                exit 1
            fi
        fi
    fi
    rm -f $PIDFILE
}


case "$1" in
  start)
        log_daemon_msg "Starting $DESC " "$NAME"
        # Check if it's running first
        if running ;  then
            log_progress_msg "apparently already running"
            log_end_msg 0
            exit 0
        fi
        if start_server ; then
            # NOTE: Some servers might die some time after they start,
            # this code will detect this issue if STARTTIME is set
            # to a reasonable value
            [ -n "$STARTTIME" ] && sleep $STARTTIME # Wait some time
            if  running ;  then
                # It's ok, the server started and is running
                log_end_msg 0
            else
                # It is not running after we did start
                log_end_msg 1
            fi
        else
            # Either we could not start it
            log_end_msg 1
        fi
        ;;
  stop)
        log_daemon_msg "Stopping $DESC" "$NAME"
        if running ; then
            # Only stop the server if we see it running
            errcode=0
            stop_server || errcode=$?
            log_end_msg $errcode
        else
            # If it's not running don't do anything
            log_progress_msg "apparently not running"
            log_end_msg 0
            exit 0
        fi
        ;;
  force-stop)
        # First try to stop gracefully the program
        $0 stop
        errcode=0
        if running; then
            # If it's still running try to kill it more forcefully
            log_daemon_msg "Stopping (force) $DESC" "$NAME"
            force_stop || errcode=$?
        fi
        # if there are still processes running as hue, just kill them.
        # we only do this if the user is hue, in case it's been changed
        # to nobody - we don't want to go and kill a webserver
        if [ "$DAEMONUSER" -eq hue ] && ps -u hue | grep -q build/env/bin ; then
          killall -9 -u hue
          errcode=$?
        fi
        log_end_msg $errcode
        ;;
  restart|force-reload)
        log_daemon_msg "Restarting $DESC" "$NAME"
        errcode=0
        stop_server || errcode=$?
        # Wait some sensible amount, some server need this
        [ -n "$DIETIME" ] && sleep $DIETIME
        start_server || errcode=$?
        [ -n "$STARTTIME" ] && sleep $STARTTIME
        running || errcode=$?
        log_end_msg $errcode
        ;;
  status)

        log_daemon_msg "Checking status of $DESC" "$NAME"
        if running ;  then
            log_progress_msg "running"
            log_end_msg 0
        else
            log_progress_msg "apparently not running"
            log_end_msg 1
            exit 1
        fi
        ;;
  # Use this if the daemon cannot reload
  reload)
        log_warning_msg "Reloading $NAME daemon: not implemented, as the daemon"
        log_warning_msg "cannot re-read the config file (use restart)."
        ;;

  *)
        N=/etc/init.d/$NAME
        echo "Usage: $N {start|stop|force-stop|restart|force-reload|status}" >&2
        exit 1
        ;;
esac

exit 0