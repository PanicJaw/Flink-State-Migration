#!/usr/bin/env bash
################################################################################
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
################################################################################
set -o pipefail

source "$(dirname "$0")"/common.sh

FLINK_TARBALL_DIR=$TEST_DATA_DIR
FLINK_TARBALL=flink.tar.gz
FLINK_DIRNAME=$(basename $FLINK_DIR)

MAX_RETRY_SECONDS=120
CLUSTER_SETUP_RETRIES=3

echo "Flink Tarball directory $FLINK_TARBALL_DIR"
echo "Flink tarball filename $FLINK_TARBALL"
echo "Flink distribution directory name $FLINK_DIRNAME"
echo "End-to-end directory $END_TO_END_DIR"
docker --version
docker-compose --version

# make sure we stop our cluster at the end
function cluster_shutdown {
  # don't call ourselves again for another signal interruption
  trap "exit -1" INT
  # don't call ourselves again for normal exit
  trap "" EXIT

  docker-compose -f $END_TO_END_DIR/test-scripts/docker-hadoop-secure-cluster/docker-compose.yml down
  rm $FLINK_TARBALL_DIR/$FLINK_TARBALL
}
trap cluster_shutdown INT
trap cluster_shutdown EXIT

function start_hadoop_cluster() {
    echo "Starting Hadoop cluster"
    docker-compose -f $END_TO_END_DIR/test-scripts/docker-hadoop-secure-cluster/docker-compose.yml up -d

    # wait for kerberos to be set up
    start_time=$(date +%s)
    until docker logs master 2>&1 | grep -q "Finished master initialization"; do
        current_time=$(date +%s)
        time_diff=$((current_time - start_time))

        if [ $time_diff -ge $MAX_RETRY_SECONDS ]; then
            return 1
        else
            echo "Waiting for hadoop cluster to come up. We have been trying for $time_diff seconds, retrying ..."
            sleep 5
        fi
    done

    # perform health checks
    if ! { [ $(docker inspect -f '{{.State.Running}}' master 2>&1) = 'true' ] &&
           [ $(docker inspect -f '{{.State.Running}}' slave1 2>&1) = 'true' ] &&
           [ $(docker inspect -f '{{.State.Running}}' slave2 2>&1) = 'true' ] &&
           [ $(docker inspect -f '{{.State.Running}}' kdc 2>&1) = 'true' ]; };
    then
        return 1
    fi

    # try and see if NodeManagers are up, otherwise the Flink job will not have enough resources
    # to run
    nm_running="0"
    start_time=$(date +%s)
    while [ "$nm_running" -lt "2" ]; do
        current_time=$(date +%s)
        time_diff=$((current_time - start_time))

        if [ $time_diff -ge $MAX_RETRY_SECONDS ]; then
            return 1
        else
            echo "We only have $nm_running NodeManagers up. We have been trying for $time_diff seconds, retrying ..."
            sleep 1
        fi

        docker exec -it master bash -c "kinit -kt /home/hadoop-user/hadoop-user.keytab hadoop-user"
        nm_running=`docker exec -it master bash -c "yarn node -list" | grep RUNNING | wc -l`
        docker exec -it master bash -c "kdestroy"
    done

    return 0
}

mkdir -p $FLINK_TARBALL_DIR
tar czf $FLINK_TARBALL_DIR/$FLINK_TARBALL -C $(dirname $FLINK_DIR) .

echo "Building Hadoop Docker container"
until docker build --build-arg HADOOP_VERSION=2.8.4 \
    -f $END_TO_END_DIR/test-scripts/docker-hadoop-secure-cluster/Dockerfile \
    -t flink/docker-hadoop-secure-cluster:latest \
    $END_TO_END_DIR/test-scripts/docker-hadoop-secure-cluster/;
do
    # with all the downloading and ubuntu updating a lot of flakiness can happen, make sure
    # we don't immediately fail
    echo "Something went wrong while building the Docker image, retrying ..."
    sleep 2
done

CLUSTER_STARTED=1
for (( i = 0; i < $CLUSTER_SETUP_RETRIES; i++ ))
do
    if start_hadoop_cluster; then
       echo "Cluster started successfully."
       CLUSTER_STARTED=0
       break #continue test, cluster set up succeeded
    fi

    echo "ERROR: Could not start hadoop cluster. Retrying..."
    docker-compose -f $END_TO_END_DIR/test-scripts/docker-hadoop-secure-cluster/docker-compose.yml down
done

if [[ ${CLUSTER_STARTED} -ne 0 ]]; then
    echo "ERROR: Could not start hadoop cluster. Aborting..."
    exit 1
fi

docker cp $FLINK_TARBALL_DIR/$FLINK_TARBALL master:/home/hadoop-user/

# now, at least the container is ready
docker exec -it master bash -c "tar xzf /home/hadoop-user/$FLINK_TARBALL --directory /home/hadoop-user/"

# minimal Flink config, bebe
docker exec -it master bash -c "echo \"security.kerberos.login.keytab: /home/hadoop-user/hadoop-user.keytab\" > /home/hadoop-user/$FLINK_DIRNAME/conf/flink-conf.yaml"
docker exec -it master bash -c "echo \"security.kerberos.login.principal: hadoop-user\" >> /home/hadoop-user/$FLINK_DIRNAME/conf/flink-conf.yaml"
docker exec -it master bash -c "echo \"slot.request.timeout: 120000\" >> /home/hadoop-user/$FLINK_DIRNAME/conf/flink-conf.yaml"
docker exec -it master bash -c "echo \"containerized.heap-cutoff-min: 100\" >> /home/hadoop-user/$FLINK_DIRNAME/conf/flink-conf.yaml"

echo "Flink config:"
docker exec -it master bash -c "cat /home/hadoop-user/$FLINK_DIRNAME/conf/flink-conf.yaml"

# make the output path random, just in case it already exists, for example if we
# had cached docker containers
OUTPUT_PATH=hdfs:///user/hadoop-user/wc-out-$RANDOM

start_time=$(date +%s)
# it's important to run this with higher parallelism, otherwise we might risk that
# JM and TM are on the same YARN node and that we therefore don't test the keytab shipping
if docker exec -it master bash -c "export HADOOP_CLASSPATH=\`hadoop classpath\` && \
   /home/hadoop-user/$FLINK_DIRNAME/bin/flink run -m yarn-cluster -yn 3 -ys 1 -ytm 1000 -yjm 1000 \
   -p 3 /home/hadoop-user/$FLINK_DIRNAME/examples/streaming/WordCount.jar --output $OUTPUT_PATH";
then
    docker exec -it master bash -c "kinit -kt /home/hadoop-user/hadoop-user.keytab hadoop-user"
    docker exec -it master bash -c "hdfs dfs -ls $OUTPUT_PATH"
    OUTPUT=$(docker exec -it master bash -c "hdfs dfs -cat $OUTPUT_PATH/*")
    docker exec -it master bash -c "kdestroy"
    echo "$OUTPUT"
else
    echo "Running the job failed."
    mkdir -p $TEST_DATA_DIR/logs
    echo "Hadoop logs:"
    docker cp master:/var/log/hadoop/* $TEST_DATA_DIR/logs/
    for f in $TEST_DATA_DIR/logs/*; do
        echo "$f:"
        cat $f
    done
    echo "Docker logs:"
    docker logs master
    exit 1

    echo "Flink logs:"
    docker exec -it master bash -c "kinit -kt /home/hadoop-user/hadoop-user.keytab hadoop-user"
    application_id=`docker exec -it master bash -c "yarn application -list -appStates ALL" | grep "Flink session cluster" | awk '{print \$1}'`
    echo "Application ID: $application_id"
    docker exec -it master bash -c "yarn logs -applicationId $application_id"
    docker exec -it master bash -c "kdestroy"
fi

if [[ ! "$OUTPUT" =~ "consummation,1" ]]; then
    echo "Output does not contain (consummation, 1) as required"
    mkdir -p $TEST_DATA_DIR/logs
    echo "Hadoop logs:"
    docker cp master:/var/log/hadoop/* $TEST_DATA_DIR/logs/
    for f in $TEST_DATA_DIR/logs/*; do
        echo "$f:"
        cat $f
    done
    echo "Docker logs:"
    docker logs master
    exit 1
fi

if [[ ! "$OUTPUT" =~ "of,14" ]]; then
    echo "Output does not contain (of, 14) as required"
    exit 1
fi

if [[ ! "$OUTPUT" =~ "calamity,1" ]]; then
    echo "Output does not contain (calamity, 1) as required"
    exit 1
fi

echo "Running Job without configured keytab, the exception you see below is expected"
docker exec -it master bash -c "echo \"\" > /home/hadoop-user/$FLINK_DIRNAME/conf/flink-conf.yaml"
# verify that it doesn't work if we don't configure a keytab
OUTPUT=$(docker exec -it master bash -c "export HADOOP_CLASSPATH=\`hadoop classpath\` && \
    /home/hadoop-user/$FLINK_DIRNAME/bin/flink run \
    -m yarn-cluster -yn 3 -ys 1 -ytm 1000 -yjm 1000 -p 3 \
    /home/hadoop-user/$FLINK_DIRNAME/examples/streaming/WordCount.jar --output $OUTPUT_PATH")
echo "$OUTPUT"

if [[ ! "$OUTPUT" =~ "Hadoop security with Kerberos is enabled but the login user does not have Kerberos credentials" ]]; then
    echo "Output does not contain the Kerberos error message as required"
    exit 1
fi
