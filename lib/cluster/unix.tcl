##################
## Module Name     --  cluster::unix
## Original Author --  Emmanuel Frecon - emmanuel@sics.se
## Description:
##
##      This module contains high(er)-level interfaces to a number of
##      unix/linux command-line tools and parameters.  Most of the
##      time, the commands are named similarily to the tools, even
##      though their output is meant to be easily crunched by Tcl
##      callers.
##
##################

package require cluster::environment
package require cluster::tooling
package require cluster::utils

namespace eval ::cluster::unix {
    namespace eval vars {
        # Path of docker daemon init script
        variable -daemon    "/etc/init.d"
        # Path where PID files are stored
        variable -run       "/var/run"
        # ssh command to use towards host
        variable -ssh       ""
    }
    namespace export {[a-z]*}
    namespace path [namespace parent]
    namespace ensemble create -command ::unix
    namespace import [namespace parent]::utils::log
}


# ::cluster::unix::release -- OS Identification
#
#      Read the os-release file as specified by
#      https://www.freedesktop.org/software/systemd/man/os-release.html and
#      either return its whole content or search for the value of a given key.
#
# Arguments:
#      vm       Dictionary description of virtual machine
#      search   Key to search for (case insensitive), empty for entire content
#
# Results:
#      Return either the value for the key (or an empty string) when the key to
#      search for is non-empty, either the entire content of the OS
#      identification file as a dictionary.
#
# Side Effects:
#      Read /etc/os-release on remote machine.
proc ::cluster::unix::release { vm { search "" } } {
    set nm [dict get $vm -name]
    log DEBUG "Getting OS information from $nm..."
    set nfo [dict create]
    foreach l [tooling relatively -- [file dirname [storage $vm]] \
                    tooling machine -return -stderr -- -s [storage $vm] ssh $nm "cat /etc/os-release"] {
        environment line nfo $l
    }
    
    if { $search eq "" } {
        return $nfo
    } else {
        if { [dict exists $nfo [string toupper $search]] } {
            return [dict get $nfo [string toupper $search]]
        }
    }
    return "";  # Failsafe for all errors.
}


# ::cluster::unix::ps -- Return list of processes running on VM
#
#       Query a machine for the list of processes that are currently
#       running and return their description.  The description is a
#       list of length a multiple of three, where you will find, in
#       order: the PID of the process, the main command of the process
#       and the complete command with arguments that started the
#       process
#
# Arguments:
#	nm	    Name of virtual machine
#	filter	Glob-style filter for main process name filter.
#
# Results:
#       List of processes as descibed above.
#
# Side Effects:
#       None.
proc ::cluster::unix::ps { vm {filter *}} {
    set nm [dict get $vm -name]
    log DEBUG "Getting list of processes on $nm..."
    set processes {}
    set skip 1
    foreach l [tooling relatively -- [file dirname [storage $vm]] \
                    tooling machine -return -- -s [storage $vm] ssh $nm "sudo ps -e -o pid,comm,args"] {
        if { $skip } {
            # Skip header!
            set skip 0
        } else {
            set l [string trim $l]
            set pid [lindex $l 0]
            set cmd [lindex $l 1]
            set args [lrange $l 2 end]
            if { [string match $filter $cmd] } {
                lappend processes $pid $cmd $args
            }
        }
    }
    return $processes
}


# ::cluster::unix::daemon -- daemons interfacing
#
#       This procedure provides two sub-commands.  One called `pid`
#       will actively return the PID of an init.d daemon, returning
#       the identifier only if the daemon is running.  The second
#       called `up` (but `start` can also be used) will make sure the
#       daemon is actually running and will start it if not.
#
# Arguments:
#	nm	    Name of the virtual machine
#	daemon	Name of the daemon (docker anyone?)
#	cmd	    Sub-command to execute
#	args	Possible sub-commands arguments.
#
# Results:
#       The PID of the daemon on the remote machine, empty string on
#       errors.
#
# Side Effects:
#       None.
proc ::cluster::unix::daemon { vm daemon cmd args } {
    switch -nocase -- $cmd {
        "pid" {
            return [eval [linsert $args 0 \
                    [namespace current]::DaemonPID $vm $daemon]]
        }
        "up" -
        "start" {
            return [eval [linsert $args 0 \
                    [namespace current]::DaemonUp $vm $daemon]]
        }
        default {
            return -code error "$cmd is not a known sub-command!"
        }
    }
}


# ::cluster::unix::mounts -- Return the list of mount points on remote machine
#
#       Actively poll a remote machine for its active mount points and
#       return a description of these.  This is basically an interface
#       to the UNIX command "mount" (sans arguments!).  This returns a
#       list where the mounts are described with: first the device,
#       then the directory where it is mounted, then its type, and
#       finally a list of the mount options.
#
# Arguments:
#	nm	Name of the virtual machine
#
# Results:
#       Return a list of the mount points.
#
# Side Effects:
#       None.
proc ::cluster::unix::mounts { vm } {
    set nm [dict get $vm -name]
    log DEBUG "Detecting mounts on $nm..."
    set mounts {};
    # Parse the output of the 'mount' command line by line, we do this
    # by looking for specific keywords in the string, but we might be
    # better off using regular expressions?
    foreach l [tooling relatively -- [file dirname [storage $vm]] \
                    tooling machine -return -- -s [storage $vm] ssh $nm mount] {
        # Advance to word "on" and isolate the device specification
        # that should be placed before.
        set on [string first " on " $l]
        if { $on >= 0 } {
            set dev [string trim [string range $l 0 $on]]
            # Advance to the keyword "type" and isolate the path that
            # should be between "on" and "type".
            set type [string first " type " $l $on]
            if { $type >= 0 } {
                set dst [string trim [string range $l [expr {$on+4}] $type]]
                # Advance to the parenthesis, this is where the
                # options will begin.  The type is between the keyword
                # type and the parenthesis (or the end of the
                # string/line).
                set paren [string first " (" $l $type]
                if { $paren >= 0 } {
                    set type [string trim \
                            [string range $l [expr {$type+6}] $paren]]
                    set optstr [string trim \
                            [string range $l [expr {$paren+2}] end]]
                    # Remove leading and trailing parenthesis, there
                    # are the options, separated by coma signs.
                    set optstr [string trim $optstr "()"]
                    set opts [split $optstr ","]
                } else {
                    set type [string trim \
                            [string range $l [expr {$type+6}] end]]
                    set opts {}
                }
                lappend mounts $dev $dst $type $opts
            } else {
                log WARN "Cannot find 'type' in output"
            }
        } else {
            log WARN "Cannot find 'on' in output"
        }
    }
    return $mounts
}


# ::cluster::unix::scp -- Copy local file into machine.
#
#       Copy a local file into a virtual machine.  The scp command is
#       dynamically generated out of the ssh command that is used by
#       docker-machine to enter the VM.  We detect that by putting
#       docker-machine in debug mode and try running a command in the
#       machine using docker-machine ssh.
#
# Arguments:
#       vm        Name of the virtual machine
#       src_fname Full path to source.
#       dst_fname Full path to destination (empty to same as source)
#
# Results:
#       None.
#
# Side Effects:
#       None.
proc ::cluster::unix::scp { vm src_fname { dst_fname "" } { recurse 1 } } {
    # Make destination identical to source if necessary.
    if { $dst_fname eq "" } {
        set dst_fname $src_fname
    }
    
    set nm [dict get $vm -name]
    log NOTICE "Copying local $src_fname to ${nm}:$dst_fname"
    
    # Construct an scp command out of the ssh command!  This converts
    # the arguments between the ssh and scp namespaces, which are not
    # exactly the same.
    if { ${vars::-ssh} eq "" } {
        set cmd [remote $vm]
    } else {
        set cmd ${vars::-ssh}
    }
    
    set cmd [regsub ^ssh $cmd scp];  # Need to improve this!
    set cmd [regsub -- -p $cmd -P]
    # Extract username and hostname in uname and hname using the
    # various ways they can appear in ssh commands (i.e. -l option or
    # user@host specification at end).
    if { [regexp -- {-l\s+(\w+)} $cmd - uname] } {
        set cmd [regsub -- {-l\s+(\w+)} $cmd ""];  # Remove -l from command
        set hname [lindex $cmd end]
    } else {
        if { ![regexp -- {(\w+)@([\w.]+)} [lindex $cmd end] - uname hname] } {
            log WARN "Cannot find user and host names in $cmd!"
            return 0
        }
    }
    set scp [lrange $cmd 0 end-1]
    log DEBUG "Constructed command $scp, destination: ${uname}@${hname}"
    
    # Finalise the scp command by adding file paths information and
    # execute it.
    if { [string is true $recurse] } {
        lappend scp -r $src_fname ${uname}@${hname}:$dst_fname
    } else {
        lappend scp $src_fname ${uname}@${hname}:$dst_fname
    }
    eval [linsert $scp 0 Run]
    return 1
}


# ::cluster::unix::remote -- Detect ssh command to machine
#
#      Actively detect the entire ssh command that docker machine uses to gain
#      access to the remote machine. The implementation relies on the --debug
#      command-line option of docker machine and introspection of the result
#      when executing a noop command.
#
# Arguments:
#      vm       Dictionary description of the virtual machine
#
# Results:
#      ssh command into remote machine
#
# Side Effects:
#      Will execute an empty command at the remote machine
proc ::cluster::unix::remote { vm } {
    set nm [dict get $vm -name]
    log DEBUG "Detecting SSH command into $nm"
    
    # Start looking starting from last lines as newer versions output
    # more when debug is on...
    foreach l [lreverse [tooling relatively -- [file dirname [storage $vm]] \
                            tooling machine -return -stderr -- -s [storage $vm] --debug ssh $nm echo ""]] {
        foreach bin [list "/usr/bin/ssh" "ssh"] {
            if { [string first $bin $l] >= 0 } {
                set sshinfo $l
                set ssh [string last $bin $sshinfo];  # Lookup the string 'ssh': START
                set echo [string last echo $sshinfo]; # Lookup the string 'echo': END
                set cmd [string trim [string range $sshinfo $ssh [expr {$echo-1}]]]
                
                # Replace options setting arguments to use = to make it easier for
                # callers.
                foreach { m k v } [regexp -all -inline -- {-o\s+(\w*)\s+(\w*)} $cmd] {
                    set cmd [string map [list $m "-o ${k}=${v}"] $cmd]
                }
                
                log DEBUG "SSH command into $nm is '$cmd'"
                return $cmd
            }
        }
    }
}

# ::cluster::unix::id -- Interface to user id information
#
#       Return a dictionary that will contain user and group
#       information for a given user.
#
# Arguments:
#	nm	Name of the virtual machine
#	mode	"alpha" for textual values (e.g. username), "numeric" for ids.
#	uname	Name of user to get info for, empty for current
#
# Results:
#       Return a dictionary with three keys: uid, gid and groups where
#       uid and gid are the user and group identifier and groups is
#       the list of additional groups that the user belongs to.
#
# Side Effects:
#       None.
proc ::cluster::unix::id { vm { mode "alpha" } {uname ""}} {
    set nm [dict get $vm -name]
    if { $uname eq "" } {
        set idinfo [string map [list "=" " "] \
                [lindex [tooling relatively -- [file dirname [storage $vm]] \
                            tooling machine -return -- -s [storage $vm] ssh $nm id] 0]]
    } else {
        set idinfo [string map [list "=" " "] \
                [lindex [tooling relatively -- [file dirname [storage $vm]] \
                            tooling machine -return -- -s [storage $vm] ssh $nm "id $uname"] 0]]
    }
    
    set response [dict create]
    switch -nocase -glob -- $mode {
        "alpha*" {
            dict for {k v} $idinfo {
                switch -nocase $k {
                    uid -
                    gid {
                        if { [regexp {\((\w+)\)} $v - name] } {
                            dict set response $k $name
                        }
                    }
                    groups {
                        foreach g [split $v ","] {
                            if { [regexp {\((\w+)\)} $g - name] } {
                                dict lappend response $k $name
                            }
                        }
                    }
                }
            }
        }
        "numeric*" -
        "id*" {
            dict for {k v} $idinfo {
                switch -nocase $k {
                    uid -
                    gid {
                        if { [regexp {\d+} $v id] } {
                            dict set response $k $id
                        }
                    }
                    groups {
                        foreach g [split $v ","] {
                            if { [regexp {\d+} $g id] } {
                                dict lappend response $k $id
                            }
                        }
                    }
                }
            }
        }
    }
    
    return $response
}


# ::cluster::unix::mount -- Mount a share/device
#
#       Mount a device onto a directory in a virtual machine.  This
#       procedure will arrange for creating the directory of the
#       mountpoint if necessary.  The procedure will check that the
#       device was properly mounted and is able to try a number of
#       times if necessary.
#
# Arguments:
#	nm	Name of the virtual machine
#	dev	Path to device (or share) to mount).
#	path	Path where to mount the device (the mountpoint).
#	uid	UID of user owning the mountpoint and for the mount operation
#	type	Type of the filesystem
#	sleep	Number of seconds to wait between retries.
#	retries	Max number of retries.
#
# Results:
#       None.
#
# Side Effects:
#       None.
proc ::cluster::unix::mount { vm dev path { uid "" } {type "vboxsf"} {sleep 1} {retries 3}} {
    set nm [dict get $vm -name]
    while { $retries > 0 } {
        log INFO "Mounting $dev onto ${nm}:${path} (UID:$uid)"
        foreach cmd [mnt.sh $dev $path $uid $type] {
            tooling relatively -- [file dirname [storage $vm]] \
                tooling machine -- -s [storage $vm] ssh $nm "sudo $cmd"
        }
        
        # Test that we managed to mount properly.
        foreach { dv dst t opts } [mounts $vm] {
            if { $dst eq $path && $type eq $t } {
                set retries 0;    # We'll get off the loop
                return 1
            }
        }
        incr retries -1;   # ALWAYS! On purpose...
        if { $retries > 0 } {
            log NOTICE "Could not find $path in mount points on $nm,\
                    retrying..."
            after [expr {int($sleep*1000)}]
        }
    }
    return 0
}

# ::cluster::unix::resolve -- DNS resolver
#
#      Resolve a hostname to its IP address. This performs resolution at the
#      client and will try to rely on getent when it exists, otherwise on the
#      DNS implementation of tcllib.
#
# Arguments:
#      hostname Host name to resolve to an IP address.
#
# Results:
#      Return the IPv4 address of the host.
#
# Side Effects:
#      None.
proc ::cluster::unix::resolve { hostname } {
    if { [regexp {\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}} $hostname] } {
        return $hostname
    }
    
    # This forces back IPv4 addresses, perhaps not a good idea?
    if { [catch {tooling run -return -- getent ahostsv4 $hostname} result] == 0 } {
        foreach l [tooling run -return -- getent ahostsv4 $hostname] {
            set entries [split $l]
            if { [lindex $entries end] eq $hostname } {
                return [lindex $entries 0]
            }
        }
    } elseif { [catch {package require dns} ver] == 0 } {
        set token [::dns::resolve $hostname]
        set addr [::dns::address $token]
        ::dns::cleanup $token
        return $addr
    } else {
        log ERROR "Cannot resolve $hostname: tried getent and internal resolver"
    }
    return ""
}


# ::cluster::unix::mnt.sh -- Mount commands
#
#      Return a set of commands to mount an existing device onto a path. These
#      commands will typically be executed within the remote host.
#
# Arguments:
#      dev      Device to mount
#      path     Path to mount on (will be created)
#      uid      User identifier as which to mount (empty to ignore)
#      type     Type of filesystem, defaults to vboxsf (for virtual box)
#
# Results:
#      List of commands to ensure a successful mounts (these are NOT executed,
#      this is just a helper procedure to list out these commands)
#
# Side Effects:
#      None.
proc ::cluster::unix::mnt.sh { dev path { uid "" } { type "vboxsf" } } {
    set commands {}
    if { $uid eq "" } {
        lappend commands "mkdir -p $path"
        lappend commands "mount -t $type -v $dev $path"
    } else {
        lappend commands "mkdir -p $path"
        lappend commands "chown $uid $path"
        lappend commands "mount -t $type -v -o uid=$uid $dev $path"
    }
    return $commands
}


# ::cluster::unix::ifs -- Gather network interfaces
#
#       Collects address information for all relevant network
#       interfaces of a virtual machine.  This is basically a wrapper
#       around ifconfig.
#
# Arguments:
#        nm        Name of virtual machine
#
# Results:
#       Return a list of dictionaries.  Each dictionary should have a
#       key called interface with the name of the interface
#       (e.g. eth1, docker0, etc.).  There might also be a key called
#       inet and another called inet6 (self-explanatory).
#
# Side Effects:
#       Will call ifconfig on the target machine
proc ::cluster::unix::ifs { vm } {
    set nm [dict get $vm -name]
    log DEBUG "Detecting network interfaces of $nm..."
    set interfaces {};   # List of interface dictionaries.
    set ifs {};          # List of interface names, for logging.
    set iface ""
    foreach l [tooling relatively -- [file dirname [storage $vm]] \
                    tooling machine -return -- -s [storage $vm] ssh $nm ifconfig] {
        # The output of ifconfig is formatted so that each new
        # interface is described with a line without leading
        # whitespaces, while extra information for that interface
        # happens on lines starting with whitespaces.  The code below
        # uses this fact to segragate between interfaces.
        if { [string match -nocase "*Host*not*exist*" $l] } {
            break
        } elseif { [string index $l 0] ni [list " " "\t"] } {
            if { $iface ne "" && ![string match "v*" $iface] } {
                # We skip interfaces which name starts with v (for
                # virtual).
                lappend interfaces [dict create \
                        interface $iface \
                        inet $inet \
                        inet6 $inet6]
                lappend ifs $iface
            }
            set iface [lindex $l 0];  # Assumes we can form a proper list!
            set inet ""
            set inet6 ""
        } elseif { [string first "addr" $l] >= 0 } {
            # Try to be slightly intelligent when collecting the
            # address, but this might break.
            foreach {k v} [InterfaceLine $l] {
                if { [string equal -nocase "inet6 addr" $k] } {
                    set inet6 $v
                }
                if { [string equal -nocase "inet addr" $k] } {
                    set inet $v
                }
            }
        }
    }
    # Don't forget the last one!
    if { $iface ne "" && ![string match "v*" $iface] } {
        # We skip interfaces which name starts with v (for virtual).
        lappend interfaces [dict create \
                interface $iface \
                inet $inet \
                inet6 $inet6]
        lappend ifs $iface
    }
    
    # Report back
    if { [llength $ifs] > 0 } {
        log INFO "Detected network addresses for [join $ifs {, }]"
    }
    return $interfaces
}



####################################################################
#
# Procedures below are internal to the implementation, they shouldn't
# be changed unless you wish to help...
#
####################################################################

# ::cluster::unix::DaemonUp -- Make sure a UNIX daemon is up and running
#
#       Check that a remote daemon is actually up and running and
#       attempt (a finite number of times) to start it if it was not.
#       When starting up the daemon, this assumes that there is an
#       init.d script available.
#
# Arguments:
#	nm	Name of virtual machine
#	daemon	Name of daemon to check and possibly start
#	cmd	(sub)command to give to init.d script
#	force	Force sending the sub-command, even if daemon was running.
#	sleep	Number of seconds to sleep after we've started
#	retries	Number of times to try
#
# Results:
#       1 if docker daemon is running remotely, 0 otherwise.
#
# Side Effects:
#       None.
proc ::cluster::unix::DaemonUp { vm daemon {cmd "start"} {force 0} {sleep 1} {retries 5} } {
    set nm [dict get $vm -name]
    while { $retries > 0 } {
        set pid [DaemonPID $vm $daemon]
        if { $pid < 0 || [string is true $force] } {
            log INFO "Daemon $daemon not running on $nm, trying to $cmd..."
            set dctrl [file join ${vars::-daemon} $daemon]
            tooling relatively -- [file dirname [storage $vm]] \
                tooling machine -- -s [storage $vm] ssh $nm "sudo $dctrl $cmd"
            after [expr {int($sleep*1000)}]
            set force 0;  # Now let's do it the normal way for the next retries
        } else {
            log NOTICE "Daemon $daemon properly running at $nm, pid: $pid"
            return 1
        }
        incr retries -1
    }
    log WARN "Gave up starting daemon $daemon on $nm!"
    return 0
}


# ::cluster::unix::DaemonPID -- Process identifier of remote docker daemon
#
#       Actively fetch and verify the process identifier of a remote
#       daemon in one of the cluster machines.  This will look in the
#       /var/run directory and check that there really is a running
#       process for the PID that existed in /var/run.
#
# Arguments:
#	nm	Name of virtual machine
#
# Results:
#       Return the PID of the remote daemon, -1 on errors (not found)
#
# Side Effects:
#       None.
proc ::cluster::unix::DaemonPID { vm daemon } {
    set nm [dict get $vm -name]
    # Look for pid file in /var/run
    set rundir [string trimright ${vars::-run} "/"]
    set pidfile ""
    foreach l [tooling relatively -- [file dirname [storage $vm]] \
                    tooling machine -return -- -s [storage $vm] ssh $nm "ls -1 ${rundir}/*.pid"] {
        if { [string match "${rundir}/${daemon}*" $l] } {
            log DEBUG "Found PIDfile for $daemon at $l"
            set pidfile $l
        }
    }
    
    # If we have a PID file, make sure there is a process that is
    # running at that PID (should we check it's really the daemon?)
    if { $pidfile ne "" } {
        set dpid [lindex [tooling relatively -- [file dirname [storage $vm]] \
                                tooling machine -return -- -s [storage $vm] ssh $nm "cat $pidfile"] 0]
        log DEBUG "Checking that there is a running process with id: $dpid"
        foreach {pid cmd args} [ps $vm] {
            if { $pid == $dpid } {
                return $pid
            }
        }
    }
    
    return -1
}


# ::cluster::unix::InterfaceLine -- Parse ifconfig details
#
#       Details lines as output from ifconfig have a formatting that
#       isn't perfect for automated reading.  Keys are separted from
#       their values using a : sign, but spaces are allowed in keys
#       and before and/or after the colon sign.  This procedure
#       attempts to parse in a robust way and will return a dictionary
#       of key and values with what was extracted from the line.
#
# Arguments:
#        l        Line to parse
#
# Results:
#       A dictionary of keys and value with line information.
#
# Side Effects:
#       None.
proc ::cluster::unix::InterfaceLine { l } {
    # Initiate with an empty dictionary and the fact that we now
    # expect a key to start.
    set dict [dict create]
    set k ""
    set v ""
    set key 1
    # Parse the line character by character, this is going to be slow,
    # but allows us to cover all corner cases.
    foreach c [split [string trim $l] ""] {
        if { $key } {
            # We are parsing the key, wait for the : to mark the end
            # of the key (and the start of the value).
            if { $c eq ":" } {
                set key 0
            } else {
                if { $k eq "" } {
                    # skip whitespaces that might occur before a key
                    # starts
                    if { ![string is space $c] } {
                        append k $c
                    }
                } else {
                    # As soon as we've started to find a key, copy all
                    # characters (which includes whitespaces!).
                    append k $c
                }
            }
        } else {
            # We are parsing the value, wait for a space which will
            # mark the end of the value, but also wait for the value
            # to start in the first place since there might be spaces
            # after the : sign and before the content of the value.
            if { [string is space $c] } {
                if { $v ne "" } {
                    # We have parse a value, add to dictionary and
                    # reinitialise to start parsing next key.
                    dict set dict $k $v
                    set key 1
                    set k ""
                    set v ""
                }
            } else {
                # Add character to current value.
                append v $c
            }
        }
    }
    # Don't forget the last pair of key/value!
    if { $v ne "" } {
        dict set dict $k $v
    }
    
    # Done!
    return $dict
}

package provide cluster::unix 0.3
