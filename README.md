# Strimzi backup
Script to create cold/offline incremental backups of `Strimzi` namespaces on `Kubernetes/OpenShift`.

If you think you do not need a backup strategy for Kafka as it has embedded replication, then try
to immagine a misconfiguration, or a bug, or a security-breach deleting all your data. If you prefer
hot/online backup strategies, then you should look at `MirrorMaker2` to copy the data to a backup
cluster in a different data center.

To run the script you need to be logged it as `cluster-admin` user. Each backup archive contains
a `README` file reporting the Operator's version that you need to deploy after the restore procedure
has completed. It only supports local file system. Consumer group offsets are included, but not
KafkaConnect custom images that are usually hosted on an external image registry.

This is a work in progress, contributions are welcomed.

## Requirements
- Bash 5
- oc 4 (OpenShift CLI)
- yq 4 (YAML processor)
- zip/unzip tools
- enough disk space

## Test procedure
```sh
STRIMZI_VERSION="0.21.1"
OPERATOR_URL="https://github.com/strimzi/strimzi-kafka-operator\
/releases/download/$STRIMZI_VERSION/strimzi-cluster-operator-$STRIMZI_VERSION.yaml"
SOURCE_NS="kafka"
TARGET_NS="kafka"

# SETUP
# deploy a test cluster
oc new-project $SOURCE_NS
curl -L $OPERATOR_URL | sed "s/namespace: .*/namespace: $SOURCE_NS/g" | oc apply -f -
oc apply -f ./tests/test-$STRIMZI_VERSION.yaml
oc create cm custom-test --from-literal=foo=bar
oc create secret generic custom-test --from-literal=foo=bar

# EXERCISE
# send 100000 messages
oc run kafka-producer-perf-test -it \
    --image="quay.io/strimzi/kafka:latest-kafka-2.6.0" \
    --rm="true" --restart="Never" -- bin/kafka-producer-perf-test.sh \
    --topic my-topic --record-size 1000 --num-records 100000 --throughput -1 \
    --producer-props acks=1 bootstrap.servers=my-cluster-kafka-bootstrap:9092

# consume them
oc exec -it my-cluster-kafka-0 -c kafka -- \
    bin/kafka-console-consumer.sh --bootstrap-server :9092 \
    --topic my-topic --group my-group --from-beginning --timeout-ms 15000

# save consumer group offsets
oc exec -it my-cluster-kafka-0 -c kafka -- \
    bin/kafka-consumer-groups.sh --bootstrap-server :9092 \
    --group my-group --describe > /tmp/offsets.txt

# send additional 12345 messages
oc run kafka-producer-perf-test -it \
    --image="quay.io/strimzi/kafka:latest-kafka-2.6.0" \
    --rm="true" --restart="Never" -- bin/kafka-producer-perf-test.sh \
    --topic my-topic --record-size 1000 --num-records 12345 --throughput -1 \
    --producer-props acks=1 bootstrap.servers=my-cluster-kafka-bootstrap:9092

# set script parameters and backup
./run.sh backup

# delete the test cluster
oc delete ns $SOURCE_NS

# set script parameters and restore
./run.sh restore

# VERIFY
# deploy the operator and wait for provisioning
curl -L $OPERATOR_URL | sed "s/namespace: .*/namespace: $TARGET_NS/g" | oc apply -f -

# check consumer group offsets
oc exec -it my-cluster-kafka-0 -c kafka -- \
    bin/kafka-consumer-groups.sh --bootstrap-server :9092 \
    --group my-group --describe

# check consumer group recovery
oc exec -it my-cluster-kafka-0 -c kafka -- \
    bin/kafka-console-consumer.sh --bootstrap-server :9092 \
    --topic my-topic --group my-group --from-beginning --timeout-ms 15000

# check total number of messages with a new consumer group
oc exec -it my-cluster-kafka-0 -c kafka -- \
    bin/kafka-console-consumer.sh --bootstrap-server :9092 \
    --topic my-topic --group my-group-new --from-beginning --timeout-ms 15000
```
