#!/bin/bash
set -o xtrace
PATH=/opt/smartdc/manatee/build/node/bin:/opt/local/bin:/usr/sbin/:/usr/bin:/usr/sbin:/usr/bin:/opt/smartdc/registrar/build/node/bin:/opt/smartdc/registrar/node_modules/.bin:/opt/smartdc/manatee/lib/tools:/opt/smartdc/manatee/lib/pg_dump/

#XXX need to pickup manta_url from mdata-get
MANTA_URL="http://manta.coal.joyent.us"
MANTA_USER="poseidon"
MANTA_KEY_PATH="/root/.ssh/"

function fatal
{
  echo "$(basename $0): fatal error: $*"
  rm -rf $dump_dir
  exit 1
}

my_ip=$(mdata-get sdc:nics.0.ip)
[[ $? -eq 0 ]] || fatal "Unable to retrieve our own IP address"
svc_name=$(mdata-get service_name)
[[ $? -eq 0 ]] || fatal "Unable to retrieve service name"
zk_ip=$(mdata-get nameservers | cut -d ' ' -f1)
[[ $? -eq 0 ]] || fatal "Unable to retrieve nameservers from metadata"
dump_dir=/tmp/`uuid`
mkdir dump_dir
[[ $? -eq 0 ]] || fatal "Unable to make temp dir"

function backup
{
        echo "making backup dir $manta_dir_prefix$svc_name"
        time=$(date +%F-%H-%M-%S)
        mmkdir.js -u $MANTA_URL -a $MANTA_USER -k $MANTA_KEY_PATH $manta_dir_prefix
        [[ $? -eq 0 ]] || fatal "unable to create backup dir"
        mmkdir.js -u $MANTA_URL -a $MANTA_USER -k $MANTA_KEY_PATH $manta_dir_prefix/$svc_name
        [[ $? -eq 0 ]] || fatal "unable to create backup dir"
        mmkdir.js -u $MANTA_URL -a $MANTA_USER -k $MANTA_KEY_PATH $manta_dir_prefix/$svc_name/$time
        [[ $? -eq 0 ]] || fatal "unable to create backup dir"

        echo "getting db tables"
        schema=$dump_dir/schema
        sudo -u postgres psql moray -c '\dt' > $schema
        for i in `sed 'N;$!P;$!D;$d' /tmp/yunong |tr -d ' '| cut -d '|' -f2`
        do
                local dump_file=$dump_dir/$i
                sudo -u postgres pg_dump moray -a -t $i | sqlToJson.js | bzip2 > $dump_file
                [[ $? -eq 0 ]] || fatal "Unable to dump table $i"
                echo "uploading dump $i to manta"
                mput.js -u $MANTA_URL -a $MANTA_USER -k $MANTA_KEY_PATH -f $dump_file $manta_dir_prefix/$svc_name/$time/$i.bzip
                [[ $? -eq 0 ]] || fatal "unable to upload dump $i"
                echo "removeing dump $dump_file"
                rm $dump_file
        done
        echo "finished backup, removing backup dir $dump_dir"
        rm -rf $dump_dir
}

# s/./\./ to 1.moray.us.... for json
read -r svc_name_delim< <(echo $svc_name | gsed -e 's|\.|\\.|g')

# figure out if we are the peer that should perform backups.
shard_info=$(manatee_stat.js -z $zk_ip:2181 -s $svc_name)
[[ $? -eq 0 ]] || fatal "Unable to retrieve shardinfo from zookeeper"

async=$(echo $shard_info | json $svc_name_delim.async.url)
[[ $? -eq 0 ]] || fatal "unable to parse async peer"
sync=$(echo $shard_info | json $svc_name_delim.sync.url)
[[ $? -eq 0 ]] || fatal "unable to parse sync peer"
primary=$(echo $shard_info | json $svc_name_delim.primary.url)
[[ $? -eq 0 ]] || fatal "unable to parse primary peer"

continue_backup=0
if [ "$async" = "$my_ip" ]
then
        continue_backup=1
fi

if [ -z "$async" ] && [ "$sync" = "$my_ip" ]
then
        continue_backup=1
fi

if [ -z "$sync" ] && [ -z "$async" ] && [ "$primary" = "$my_ip" ]
then
        continue_backup=1
else
        if [ -z "$sync" ] && [ -z "$async" ]
        then
                fatal "not primary but async/sync dne, exiting 1"
        fi
fi

if [ $continue_backup = '1' ]
then
        backup
else
        echo "not performing backup, not lowest peer in shard"
        exit 0
fi