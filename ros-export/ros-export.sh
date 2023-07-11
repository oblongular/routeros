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
        -d)
            discover_only=true
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

[ "$ssh_identity" -o "$ssh_password" -o -S "$SSH_AUTH_SOCK" ] ||
    exit_with_error 1 "must supply either SSH identity, or password, or run ssh-agent" 

tmpdir=/tmp/ros-export-$$
mkdir $tmpdir || exit 2
trap "rm -fr $tmpdir" EXIT

export_dir="../ros-exports"
[ "$1" ] && export_dir="$1"
[ -d "$export_dir" ] || mkdir "$export_dir" || exit 2

#
#  collect neighbour detail from one origin device
#  convert neighbour detail into one file per device
#
ros_ssh_cmd $ip \
    "/ip/neighbor/print detail" > $tmpdir/n_detail
#cat $tmpdir/n_detail
awk -v RS='\r\n' '
    /^ *[0-9][0-9]  */  { printf "%s", $0 }
    /^ *  */            { printf "%s", $0 }
    /^$/                { printf "\n" }
' $tmpdir/n_detail > $tmpdir/n_detail_byline
#cat $tmpdir/n_detail_byline
n_dir=$tmpdir/n_dir
mkdir $n_dir
while read n params
do
    echo "$params" |
    sed \
        -e 's,^\s*[0-9][0-9]*\s*,,' \
        -e 's,\s\s*\([^= ][^= ]*=\),\n\1,g' \
    > $n_dir/$n
done < $tmpdir/n_detail_byline

neighbours=$tmpdir/neighbours
# first, fake out a neighbour entry for the origin device
n_ip4=$ip
n_ident=$(
    ros_ssh_cmd $n_ip4 \
        ":put [/system/identity/get name]" |
    tr -d '\r'
)
echo "$n_ip4 $n_ident" > $neighbours
# pattern match discovered devices
egrep -cri 'RouterOS|MikroTik|discovered-by=.*mndp' $n_dir |
awk -F: '$2 != 0 { print $1 }' |
while read f
do
    n_ip4=`sed -ne 's,^address4=,,p' $f`
    n_ident=`sed -ne 's,^identity="\(.*\)",\1,p' $f`
    if [ "$n_ip4" ]
    then
        echo "$n_ip4 $n_ident" >> $neighbours
        echo "$n_ident" >> $tmpdir/n_has_ip4
    else
        echo "$n_ident" >> $tmpdir/n_hasno_ip4
    fi
done
# warn about discovered devices we won't export from ...
sort -u $tmpdir/n_hasno_ip4 |
while read ident
do
    has_ip4=""
    while read i4
    do
        [ "$i4" = "$ident" ] && has_ip4=true
    done < $tmpdir/n_has_ip4
    if [ "$has_ip4" ]
    then
        : all good, nothing to see here
    else
        warn "will not export device with no IP address: $ident"
    fi
done

if [ "$discover_only" = true ]
then
    sort -k 2 $neighbours
    exit
fi

sort -k 2 $neighbours |
while read ip identity
do
    case "$ip" in

        [0-9]*.[0-9]*.[0-9]*.[0-9]*)

            device_serial=$(
                ros_ssh_cmd 2>/dev/null $ip ':put [/system/routerboard/get serial-number]' |
                tr -d '\r'
            )

            # map identity to a workable file name
            set -- $identity
            fname="$1"
            shift
            while [ "$1" ]
            do
                fname="${fname}_$1"
                shift
            done
            fname="${fname}_${device_serial}.rsc"

            echo >&2 "Exporting |$ip|$identity|$device_serial| ==> $export_dir/$fname"
            ros_ssh_cmd $ip /export |
            tr -d '\r' > "$tmpdir/$fname"

            if [ -s "$tmpdir/$fname" ]
            then
                mv "$tmpdir/$fname" "$export_dir/$fname"
            else
                echo >&2 "Warning: zero sized export: $export_dir/$fname"
            fi
            ;;

        *)
            echo == Skipping "$ip|$identity"
            ;;
    esac
done
