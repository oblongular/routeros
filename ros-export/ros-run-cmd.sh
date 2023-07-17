#!/bin/bash

usage_msg()
{
    cat 1>&2 <<EOM-usage

Usage: $0 [-u username] [-p|-i identity.pem] neighbour-file cli-string
  -u username - the admin username, defaults to "admin"
  -p read password from stdin
  -i use ssh private key
  neighbour-file: file continaing IP addresses and identities
  cli-string: RouterOS CLI command string

EOM-usage

    exit 1
}

exit_with_error()
{
    local exit_code=$1
    local exit_message="$2"

    echo >&2 "$0: Error: $exit_message"
    exit $exit_code
}

warn()
{
    local warn_message="$1"
    echo >&2 "$0: Warning: $warn_message"
}

ssh_user=admin
ssh_password=
ssh_identity=
ssh_options="-o ConnectTimeout=20 -o StrictHostKeyChecking=accept-new"

ros_ssh_cmd()
{
    local ip_addr="$1"
    local ros_cmd="$2"

    if [ "$ssh_identity" ]
    then
        ssh -n -i ${ssh_identity} \
            ${ssh_options} ${ssh_user}@${ip_addr} "${ros_cmd}"
        return $?
    fi
    if [ "$ssh_password" ]
    then
        echo $ssh_password |
        sshpass ssh \
            ${ssh_options} ${ssh_user}@${ip_addr} "${ros_cmd}"
        return $?
    fi
    if [ -S "$SSH_AUTH_SOCK" ]
    then
        ssh -n \
            ${ssh_options} ${ssh_user}@${ip_addr} "${ros_cmd}"
        return $?
    fi
}

ros_scp_cmdfile()
{
    local ip_addr="$1"
    local ros_cmdfile="$2"
    local ros_remotename="$3"

    if [ "$ssh_identity" ]
    then
        scp -q -i ${ssh_identity} \
            ${ssh_options} "${ros_cmdfile}" "${ssh_user}@${ip_addr}:${ros_remotename}"
        return $?
    fi
    if [ "$ssh_password" ]
    then
        echo $ssh_password |
        sshpass scp \
            ${ssh_options} "${ros_cmdfile}" "${ssh_user}@${ip_addr}:${ros_remotename}"
        return $?
    fi
    if [ -S "$SSH_AUTH_SOCK" ]
    then
        scp -q \
            ${ssh_options} "${ros_cmdfile}" "${ssh_user}@${ip_addr}:${ros_remotename}"
        return $?
    fi
}


check_for_sshpass()
{
    sshpass 2>&1 |
    grep -q '^Usage: sshpass ' ||
    exit_with_error 2 "password requested, sshpass not installed or not in path"
}

while [ "$1" ]
do
    case "$1" in
        -u)
            shift
            ssh_user="$1"
            shift
            continue
            ;;
        -p)
            read ssh_password
            shift
            check_for_sshpass
            continue
            ;;
        -i)
            shift
            ssh_identity="$1"
            shift
            [ -s "$ssh_identity" ] ||
                exit_with_error 1 "SSH identify file \"${ssh_identity}\" cannot be opened, or is empty"
            continue
            ;;
        -x)
            set -x
            shift
            continue
            ;;
        *)
            break
            ;;
    esac
done

neighbour_file="$1"
[ "$neighbour_file" ] ||
    usage_msg
[ -s "$neighbour_file" ] ||
    exit_with_error 1 "neighbour-file $neighbour_file cannot be opened"
shift

cli_string="$1"
[ "$cli_string" ] ||
    exit_with_error 1 "must supply a cli-string argument"
shift

[ "$ssh_identity" -o "$ssh_password" -o -S "$SSH_AUTH_SOCK" ] ||
    exit_with_error 1 "must supply either SSH identity, or password, or run ssh-agent"

tmpdir=/tmp/ros-run-cmd-$$
mkdir $tmpdir || exit 2
trap "rm -fr $tmpdir" EXIT

ros_remotename=__ros_run_cmd_$$_$(hostname)

sort -k 2 $neighbour_file |
while read ip identity
do
    case "$ip" in
        [0-9]*.[0-9]*.[0-9]*.[0-9]*)
            echo >&2 "---> |$ip|$identity| ..."
            if [ -s "$cli_string" ]
            then
                ros_scp_cmdfile $ip "$cli_string" $ros_remotename &&
                ros_ssh_cmd $ip \
"{                                          ;\
    :local c 0                              ;\
    :local notfound true                    ;\
    :do {                                   ;\
        :set notfound ([:len [/file/find name=$ros_remotename]] = 0) ;\
        :set c (\$c+1)                      ;\
        :put \".. uploading script - \$c\"  ;\
        :delay 1s                           ;\
    } while (\$c < 20 && \$notfound)        ;\
    :if (\$notfound) do={                   ;\
        :put \"script file did not appear!\";\
    } else={                                ;\
        :local mycode [:parse [/file/get $ros_remotename contents]]             ;\
        :do { \$mycode } on-error={:put \"WARNING: *** script error ***\"}      ;\
        :execute {:delay 5; /file remove numbers=[find name=$ros_remotename]}   ;\
    } ;\
}"

            else
                ros_ssh_cmd $ip "$cli_string"
            fi
            ;;
        *)
            warn "'$ip' is not an IP address!"
            ;;
    esac
done
