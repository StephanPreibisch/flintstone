#!/bin/bash

SPARK_DEPLOY_CMD="/usr/local/python-2.7.6/bin/python /usr/local/spark-versions/bin/spark-deploy.py"

USAGE="usage:
[TERMINATE=1] [RUNTIME=<hh:mm:ss>] [TMPDIR=<tmp>] $0 <MASTER_JOB_ID|N_NODES> <JAR> <CLASS> <ARGV>

If job with \${MASTER_JOB_ID} does not exist, value will be interpreted as number of 
nodes (N_NODES), and a new Spark master will be started with N_NODES workers using

${SPARK_DEPLOY_CMD} -w \${N_NODES}

If master exists but no workers are present, this script will just exit with a non-zero return 
value."

FAILURE_CODE=1
RUNTIME="${RUNTIME:-default}"

if [ "$#" -lt "3" ]; then
    echo -e "Not enough arguments!" 1>&2
    echo -e "$USAGE" 1>&2
    exit $FAILURE_CODE
else
    ((++FAILURE_CODE))
fi


MASTER_JOB_ID=$1;     shift
JAR=`readlink -f $1`; shift
CLASS=$1;             shift

ARGV="$@"
MASTER_GREP=`qstat | grep -E  "^ +${MASTER_JOB_ID} [0-9.]+ master"`
EXIT_CODE=$?

if [ "$EXIT_CODE" -ne "0" ]; then
    echo -e "Master not present. Starting master with ${MASTER_JOB_ID} node(s)."
    echo -e "Not all workers are guaranteed to be present at the start of the job."
    echo -e "In order to make sure to have all workers present, start a Spark cluster"
    echo -e "and run this script with the appropriate master job id once all workers"
    echo -e "are running."
    echo -e
    echo -e "Start Spark server:"
    echo -e "${SPARK_DEPLOY_CMD} -w \${N_NODES}"
    if [ "${MASTER_JOB_ID}" -gt "120" ]; then
        echo -e "It doesn't make sense to use ${MASTER_JOB_ID} nodes!"
        echo -e "${USAGE}"
        exit $FAILURE_CODE
    else
        ((++FAILURE_CODE))
    fi
    SUBMISSION=`qsub -jc sparkflex.default`
    N_NODES=${MASTER_JOB_ID}
    MASTER_JOB_ID=`echo $SUBMISSION | sed -r -e 's/Your job ([0-9]+) .*/\\1/'`
    MASTER_GREP=`qstat | grep -E  "^ +${MASTER_JOB_ID} [0-9.]+ master"`
    # MASTER_GREP=`qstat | grep -E  "${MASTER_JOB_ID} [0-9.]+ master"`
    ${SPARK_DEPLOY_CMD} -j $MASTER_JOB_ID -w ${N_NODES} -t ${RUNTIME}
fi


N_NODES=`qstat | grep "W${MASTER_JOB_ID}" | wc -l`

if [ "$N_NODES" -lt "1" ]; then
    echo -e "No workers present for master ${MASTER_JOB_ID}!"
    echo -e "${USAGE}"
    exit $FAILURE_CODE
else
    ((++FAILURE_CODE))
fi

while [ -n "$(echo $MASTER_GREP | grep qw)" ] ; do
    echo "Master node not ready yet (qw) - try again in five seconds..."
    sleep 5s
    MASTER_GREP=`qstat | grep -E  "^ +${MASTER_JOB_ID} [0-9.]+ master"`
    # MASTER_GREP=`qstat | grep -E  "${MASTER_JOB_ID} [0-9.]+ master"`
done
HOST=`echo $MASTER_GREP | sed -r -e 's/.* hadoop[A-Za-z0-9.]+@([A-Za-z0-9.]+) .*/\\1/'`
N_CORES_PER_MACHINE=16

# --tmpdir uses $TMPDIR if set else /tmp
TMP_FILE=`mktemp --tmpdir`
# need this first line in tmp file
# http://llama.mshri.on.ca/faq-llama.html#tty
# or run qsub -S /bin/bash 
echo "#$ -S /bin/bash" >> $TMP_FILE
chmod +x $TMP_FILE
echo >> $TMP_FILE

export SPARK_HOME="${SPARK_HOME:-/usr/local/spark-current}"
export PATH="$SPARK_HOME:$SPARK_HOME/bin:$SPARK_HOME/sbin:$PATH"
export PARALLELISM="$(($N_NODES * $N_CORES_PER_MACHINE * 3))"
export MASTER="spark://${HOST}:7077"

echo "export SPARK_HOME=${SPARK_HOME}" >> $TMP_FILE
echo "export PATH=$PATH" >> $TMP_FILE
echo "export PARALLELISM=$PARALLELISM" >> $TMP_FILE
echo "export MASTER=$MASTER" >> $TMP_FILE

echo -e
echo -e Environment:
echo -e "SPARK_HOME       $SPARK_HOME"
echo -e "PATH             ${PATH//:/\n                 }"
echo -e "PARALLELISM      $PARALLELISM"
echo -e "HOST             $HOST"
echo -e "MASTER           $MASTER"
echo -e "JOB_FILE         $TMP_FILE"
echo -e "JOB_NAME         $CLASS"

mkdir -p ~/.sparklogs

echo TIME_CMD="\"time \$SPARK_HOME/bin/spark-submit\"" >> $TMP_FILE
echo \$TIME_CMD --verbose \
          --conf spark.default.parallelism=$PARALLELISM \
          --conf spark.eventLog.enabled=true \
          --class $CLASS \
          $JAR \
          $ARGV >> $TMP_FILE

if [ -n "${TERMINATE}" ]; then
    echo "${SPARK_DEPLOY_CMD} -s -j ${MASTER_JOB_ID} -f"  >> $TMP_FILE
fi



JOB_MESSAGE=`qsub -pe batch 16 -N "$CLASS" -j y -o ~/.sparklogs/ $TMP_FILE`
JOB_ID=`echo ${JOB_MESSAGE} | sed -r 's/Your job ([0-9]+) .*/\1/'`
echo -e "JOB_ID           $JOB_ID"

echo
echo -e $JOB_MESSAGE


