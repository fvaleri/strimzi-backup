# Strimzi backup
Script to create cold/offline incremental backups of `Strimzi` namespaces on `Kubernetes/OpenShift`.

If you think you do not need a backup strategy for Kafka as it has embedded replication, then try to
immagine a misconfiguration, or a bug, or a security-breach deleting all your data. If you prefer
hot/online backup strategies, then you should look at `MirrorMaker2` to copy the data to a backup
cluster in a different data center.

To run the script you need to be logged it as `cluster-admin` user. The backup procedure also creates
a `README` file containing the Operator's version that you need to deploy after the restore procedure
has completed. In addition to this, you may also need to backup custom KafkaConnect image.

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
TARGET_NS="kafka-new"

# create a new namespace and deploy a cluster
oc new-project $SOURCE_NS
curl -L $OPERATOR_URL | sed "s/namespace: .*/namespace: $SOURCE_NS/g" | oc apply -f -
oc apply -f ./tests/test-$STRIMZI_VERSION.yaml
oc create cm custom-test --from-literal=foo=bar
oc create secret generic custom-test --from-literal=foo=bar

# send some messages to the cluster
oc exec -it my-cluster-kafka-0 -c kafka -- \
    bin/kafka-console-producer.sh --broker-list :9092 --topic my-topic

# set script parameters and create a backup
./run.sh backup

# set script parameters and restore
./run.sh restore

# deploy the operator and wait for provisioning
curl -L $OPERATOR_URL | sed "s/namespace: .*/namespace: $TARGET_NS/g" | oc apply -f -

# check if messages are still there
oc exec -it my-cluster-kafka-0 -c kafka -- \
    bin/kafka-console-consumer.sh --bootstrap-server :9092 --topic my-topic --from-beginning
```
