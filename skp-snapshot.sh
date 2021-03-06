#!/bin/bash
VERSION="0.3"

export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8
export LANGUAGE=en_US.UTF-8

echo " "

if [ ! -f ../skelpy-node/app.js ]; then
  echo "Error: No skp installation detected. Exiting."
  exit 1
fi

if [ "\$USER" == "root" ]; then
  echo "Error: SKELPY should not be run be as root. Exiting."
  exit 1
fi

DB_NAME="skp_mainnet"
DB_USER=$USER
DB_PASS="password"
SNAPSHOT_COUNTER=snapshot/counter.json
SNAPSHOT_LOG=snapshot/snapshot.log


if [ ! -f "snapshot/counter.json" ]; then
  mkdir -p snapshot
  sudo chmod a+x skp-snapshot.sh
  echo "0" > $SNAPSHOT_COUNTER
  sudo chown postgres:${USER:=$(/usr/bin/id -run)} snapshot
  sudo chmod -R 777 snapshot
fi
SNAPSHOT_DIRECTORY="snapshot/"

# Find parent PID
function top_level_parent_pid {
        # Look up the parent of the given PID.
        pid=${1:-$$}
        if [ "$pid" != "0" ]; then
                stat=($(</proc/${pid}/stat))
                ppid=${stat[3]}

                # /sbin/init always has a PID of 1, so if you reach that, the current PID is
                # the top-level parent. Otherwise, keep looking.
                if [[ ${ppid} -eq 1 ]] ; then
                        echo ${pid}
                else
                        top_level_parent_pid ${ppid}
                fi
        else
                pid=0
        fi
}

function proc_vars {
        node=`pgrep -a "node" | grep skelpy-node | awk '{print $1}'`
        if [ "$node" == "" ] ; then
                node=0
        fi

        # Is Postgres running
        pgres=`pgrep -a "postgres" | awk '{print $1}'`

        # Find if forever process manager is runing
        frvr=`pgrep -a "node" | grep forever | awk '{print $1}'`

        # Find the top level process of node
        top_lvl=$(top_level_parent_pid $node)

        # Looking for skelpy-node installations and performing actions
        skpdir=`locate -b skelpy-node`

        # Getting the parent of the install path
        parent=`dirname $skpdir 2>&1`

        # Forever Process ID
        forever_process=`forever --plain list | grep $node | sed -nr 's/.*\[(.*)\].*/\1/p'`

        # Node process work directory
        nwd=`pwdx $node 2>/dev/null | awk '{print $2}'`
}

NOW=$(date +"%d-%m-%Y - %T")
################################################################################

create_snapshot() {
  export PGPASSWORD=$DB_PASS
  echo  "       Instance of SKELPY Node found with:"
  echo  "       System PID: $node, Forever PID $forever_process"
  echo  "            Stopping SKELPY Node..."
  forever stop $forever_process >&- 2>&-
  echo " + Creating snapshot"
  echo "--------------------------------------------------"
  echo "..."
  
  SnapshotFilename=$SNAPSHOT_DIRECTORY'skp_db.snapshot.tar'
  pg_dump -O "$DB_NAME" -Fc -Z6 > "$SnapshotFilename"

  #sudo su postgres -c "pg_dump -Ft $DB_NAME > $SNAPSHOT_DIRECTORY'skp_db.snapshot.tar'"
  blockHeight=`psql -d $DB_NAME -U $DB_USER -h localhost -p 5432 -t -c "select height from blocks order by height desc limit 1;"`
  dbSize=`psql -d $DB_NAME -U $DB_USER -h localhost -p 5432 -t -c "select pg_size_pretty(pg_database_size('$DB_NAME'));"`

  if [ $? != 0 ]; then
    echo "X Failed to create snapshot." | tee -a $SNAPSHOT_LOG
    exit 1
  else
    SNAPSHOT_FILE=`ls -t snapshot/skp_db* | head  -1`

    echo "$NOW -- OK snapshot created successfully at block$blockHeight ($dbSize)." | tee -a $SNAPSHOT_LOG
  fi

  echo "            Starting SKELPY Node..."
  cd $skpdir
  forever start app.js -c ./config.mainnet.json -g ./genesisBlock.mainnet.json >&- 2>&-
  #forever start app.js --genesis genesisBlock.mainnet.json --config config.mainnet.json >&- 2>&-
  echo "    ✔ SKELPY Node was successfully started"


}

restore_snapshot(){
  echo  "       Instance of SKELPY Node found with:"
  echo  "       System PID: $node, Forever PID $forever_process"
  echo  "            Stopping SKELPY Node..."
  forever stop $forever_process >&- 2>&-
  echo " + Restoring snapshot"
  echo "--------------------------------------------------"
  SNAPSHOT_FILE=`ls -t snapshot/skp_db* | head  -1`
  if [ -z "$SNAPSHOT_FILE" ]; then
    echo "****** No snapshot to restore, please consider create it first"
    echo " "
    exit 1
  fi

    
    #snapshot restoring..
    export PGPASSWORD=$DB_PASS
   
    pg_restore -O -j 8 -d skp_mainnet  $SNAPSHOT_FILE 2>/dev/null
    #pg_restore -d $DB_NAME "$SNAPSHOT_FILE" -U $DB_USER -h localhost -c -n public

    echo "OK snapshot restored successfully."

  

  cd $skpdir
  forever start app.js -c ./config.mainnet.json -g ./genesisBlock.mainnet.json >&- 2>&-
  #forever start app.js --genesis genesisBlock.mainnet.json --config config.mainnet.json >&- 2>&-
  echo "    ✔ SKELPY Node was successfully started"
}

show_log(){
  echo " + Snapshot Log"
  echo "--------------------------------------------------"
  cat snapshot/snapshot.log
  echo "--------------------------------------------------END"
}


schedule_cron(){
        echo "All your crontab settings will be overwritten."

        read -p "Do you want to continue (y/n)?" -n 1 -r
        if [[  $REPLY =~ ^[Yy]$ ]]
           then
        echo " "
        case $1 in
        "hourly")
                echo "0 * * * * cd $(pwd) && bash $(pwd)/skp-snapshot.sh create >> $(pwd)/cron.log" > schedule
                sudo crontab schedule
                echo "The snapshot has been scheduled every hour";
        ;;
        "daily")
                echo "0 0 * * * cd $(pwd) && bash $(pwd)/skp-snapshot.sh create >> $(pwd)/cron.log" > schedule
                sudo crontab schedule
                echo "The snapshot has been scheduled once a day";
        ;;
        "weekly")
                echo "0 0 * * 0 cd $(pwd) && bash $(pwd)/skp-snapshot.sh create >> $(pwd)/cron.log" > schedule
                sudo crontab schedule
                echo "The snapshot has been scheduled once a week";
        ;;
        "monthly")
                echo "0 0 1 * * cd $(pwd) && bash $(pwd)/skp-snapshot.sh create >> $(pwd)/cron.log" > schedule
                sudo crontab schedule
                echo "The snapshot has been scheduled once a month";
        ;;
        *)
        echo "Error: Wrong parameter for cron option."
        ;;
        esac

        rm schedule

        fi
}


################################################################################
proc_vars

case $1 in
"create")
  create_snapshot
  ;;
"restore")
  restore_snapshot
  ;;
"log")
  show_log
  ;;
"schedule")
  schedule_cron $2
  ;;
"hello")
  echo "Hello my friend - $NOW"
  ;;
"help")
  echo "Available commands are: "
  echo "  create   - Create new snapshot"
  echo "  restore  - Restore the last snapshot available in folder snapshot/"
  echo "  log      - Display log"
  echo "  schedule - Schedule snapshot creation periodically, available parameters:"
  echo "                - hourly"
  echo "                - daily"
  echo "                - weekly"
  echo "                - monthly"
  echo "                Example $ bash skp-snapshot.sh schedule daily"
  ;;
*)
  echo "Error: Unrecognized command."
  echo ""
  echo "Available commands are: create, restore, log, cron, help"
  echo "Try: bash skp-snapshot.sh help"
  ;;
esac
