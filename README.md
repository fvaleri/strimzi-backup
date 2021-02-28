# Strimzi backup
Script for cold/offline backups of namespaced `Strimzi` clusters on `Kubernetes/OpenShift`.

If you think you do not need a backup strategy for Kafka as it has embedded data replication,
then try to immagine a misconfiguration/bug/security-breach deleting all your data. For hot/online
backups, you should look at `MirrorMaker2` to sync with a remote cluster, but this comes with
additional complexities and required resources.

To run the script you must be logged in as `cluster-admin` user. Each backup archive contains
an `env` file reporting the operator's version that you need to deploy after restore. In order to
be consistent, the backup shuts down the cluster and restarts it when the procedure has terminated.
Only local file system is supported, consumer group offsets are included, but not KafkaConnect
custom images, that are usually hosted on an external registry.

## Requirements
- Bash 5.1.4(1)-release (GNU)
- kubectl v1.20.4 (Kubernetes)
- tar 1.33 (GNU)
- yq 4.5.1 (YAML processor)
- zip 3.0 (Info-ZIP)
- unzip 6.00 (Info-ZIP)
- enough disk space

## Test procedure
```sh
STRIMZI_VERSION="0.21.1"
OPERATOR_URL="https://github.com/strimzi/strimzi-kafka-operator\
/releases/download/$STRIMZI_VERSION/strimzi-cluster-operator-$STRIMZI_VERSION.yaml"
SOURCE_NS="test"
TARGET_NS="test"

### SETUP ###
# deploy a test cluster
kubectl create namespace $SOURCE_NS
kubectl config set-context --current --namespace=$SOURCE_NS
curl -L $OPERATOR_URL | sed "s/namespace: .*/namespace: $SOURCE_NS/g" | kubectl apply -f -
kubectl apply -f ./tests/test-$STRIMZI_VERSION.yaml
kubectl create cm custom-test --from-literal=foo=bar
kubectl create secret generic custom-test --from-literal=foo=bar

### EXERCISE ###
# send 100000 messages
kubectl run kafka-producer-perf-test -it \
    --image="quay.io/strimzi/kafka:latest-kafka-2.6.0" \
    --rm="true" --restart="Never" -- bin/kafka-producer-perf-test.sh \
    --topic my-topic --record-size 1000 --num-records 100000 --throughput -1 \
    --producer-props acks=1 bootstrap.servers=my-cluster-kafka-bootstrap:9092

# consume them
kubectl exec -it my-cluster-kafka-0 -c kafka -- \
    bin/kafka-console-consumer.sh --bootstrap-server :9092 \
    --topic my-topic --group my-group --from-beginning --timeout-ms 15000

# save consumer group offsets
kubectl exec -it my-cluster-kafka-0 -c kafka -- \
    bin/kafka-consumer-groups.sh --bootstrap-server :9092 \
    --group my-group --describe > /tmp/offsets.txt

# send additional 12345 messages
kubectl run kafka-producer-perf-test -it \
    --image="quay.io/strimzi/kafka:latest-kafka-2.6.0" \
    --rm="true" --restart="Never" -- bin/kafka-producer-perf-test.sh \
    --topic my-topic --record-size 1000 --num-records 12345 --throughput -1 \
    --producer-props acks=1 bootstrap.servers=my-cluster-kafka-bootstrap:9092

# run backup procedure
./run.sh --backup $SOURCE_NS my-cluster /tmp/backups

# delete namespace and restore
kubectl delete ns $SOURCE_NS
kubectl create ns $TARGET_NS
./run.sh --restore $TARGET_NS my-cluster /tmp/backups/my-cluster-20210228111235.zip

### VERIFY ###
# deploy the operator and wait for provisioning
curl -L $OPERATOR_URL | sed "s/namespace: .*/namespace: $TARGET_NS/g" | kubectl apply -f -

# check consumer group offsets
kubectl exec -it my-cluster-kafka-0 -c kafka -- \
    bin/kafka-consumer-groups.sh --bootstrap-server :9092 \
    --group my-group --describe

# check consumer group recovery (expected: 12345)
kubectl exec -it my-cluster-kafka-0 -c kafka -- \
    bin/kafka-console-consumer.sh --bootstrap-server :9092 \
    --topic my-topic --group my-group --from-beginning --timeout-ms 15000

# check total number of messages with a new consumer group (expected: 112345)
kubectl exec -it my-cluster-kafka-0 -c kafka -- \
    bin/kafka-console-consumer.sh --bootstrap-server :9092 \
    --topic my-topic --group my-group-new --from-beginning --timeout-ms 15000
```
