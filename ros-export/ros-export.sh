#!/bin/bash

usage_msg()
{
    cat 1>&2 <<EOM-usage

Usage: ros-export.sh [-u username] [-p|-i identity.pem] ip-address [export-dir]
  -u username - the admin username, defaults to "admin"
  -p read password from stdin
  -i use ssh private key
  export-dir: where to write exported config (default is "../ros-exports")

EOM-usage
}

exit_with_error()
{
    local exit_code=$1
    local exit_message="$2"

    echo >&2 "$0: Error: $exit_message"
    exit $exit_code
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
            ${ssh_options} ${ssh_user}@${ip_addr} ${ros_cmd}
    else
        echo $ssh_password |
        sshpass ssh \
            ${ssh_options} ${ssh_user}@${ip_addr} ${ros_cmd}
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

ip="$1"
case "$ip" in
    [0-9]*.[0-9]*.[0-9]*.[0-9]*)
        : all good
        ;;
	*)
        usage_msg
        exit 1
        ;;
esac
shift

[ "$ssh_identity" -o "$ssh_password" ] ||
    exit_with_error 1 "must supply either SSH identity, or password"

tmpdir=/tmp/ros-export-$$
mkdir $tmpdir || exit 2
trap "rm -fr $tmpdir" EXIT

export_dir="../ros-exports"
[ "$1" ] && export_dir="$1"
[ -d "$export_dir" ] || mkdir "$export_dir" || exit 2

ros_ssh_cmd $ip \
    "/ip/neighbor/print proplist=address,software-id,identity" |
tr -d '\r' > $tmpdir/neighbours

while read n ip soft_id identity
do
    # Assumption: having a software-id field means "RouterOS" (vs SwitchOS)
    case "$n,$soft_id" in
        [1-9]*,????-????)

            # map identity to a workable file name
            set -- $identity
            fname="$1"
            shift
            while [ "$1" ]
            do
                fname="${fname}_$1"
                shift
            done
            fname="${fname}.rsc"

            echo >&2 "Exporting |$ip|$soft_id|$identity| ==> $export_dir/$fname"
            ros_ssh_cmd $ip /export > "$tmpdir/$fname"

            if [ -s "$tmpdir/$fname" ]
            then
                mv "$tmpdir/$fname" "$export_dir/$fname"
            else
                echo >&2 "Warning: zero sized export: $export_dir/$fname"
            fi
            ;;
    esac
done < $tmpdir/neighbours
