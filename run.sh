#!/usr/bin/env bash
set -Eeuo pipefail
#set -x #debug
__TMP="/tmp/strimzi-backup" && mkdir -p $__TMP
__HOME="" && pushd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" >/dev/null \
    && { __HOME=$PWD; popd >/dev/null; }

SOURCE_NS="kafka"
TARGET_NS="kafka"
CLUSTER_NAME="my-cluster"
BACKUP_NAME="$SOURCE_NS-$(date +%Y%m%d)"
BACKUP_HOME="/tmp"

ZOO_REPLICAS="3"
# PVC size must match with the corresponding CR value
ZOO_PVC_SIZE="1Gi"
ZOO_PVC_CLASS="gp2"
KAFKA_REPLICAS="3"
KAFKA_PVC_SIZE="10Gi"
KAFKA_PVC_CLASS="gp2"
# number of JBOD volumes or zero if you are not using it
KAFKA_JBOD="2"

# custom configmap names
# i.e. external logging configuration (log4j)
CUSTOM_CMS=(
    "log4j-properties"
    "custom-test"
)

# custom secret names
# i.e. listener's certificate, image registry authentication
CUSTOM_SECRETS=(
    "external-listener-cert"
    "registry-secret"
    "custom-test"
)

__error() {
    local message="$1"
    echo "$message"
    exit 1
}

__confirm() {
    local ns="$1"
    local proc="${FUNCNAME[1]}"
    local user=$(oc whoami)
    if [[ -n $ns && -n $user ]]; then
        read -p "Confirm $proc of $ns namespace as $user (y/n) " reply
        if [[ ! $reply =~ ^[Yy]$ ]]; then
            exit 0
        fi
    else
        __error "Context not ready"
    fi
}

__export() {
    local name="$1"
    local label="${2-}"
    if [[ -n $name ]]; then
        local crs=$(oc get $name -o name -l "$label")
        if [[ -n $crs ]]; then
            echo "Exporting $name"
            # delete runtime metadata expression
            local exp="del(.metadata.namespace, .items[].metadata.namespace, \
                .metadata.resourceVersion, .items[].metadata.resourceVersion, \
                .metadata.selfLink, .items[].metadata.selfLink, \
                .metadata.uid, .items[].metadata.uid, \
                .status, .items[].status)"
            local id=$(printf $name | sed 's/\//-/g;s/ //g')
            oc get $crs -o yaml | yq eval "$exp" - > $__TMP/resources/$SOURCE_NS-$id.yaml
        fi
    fi
}

__create_pvc() {
    local pvc="$1"
    local class="$2"
    local size="$3"
    if [[ -n $pvc && -n $class && -n $size ]]; then
        echo "Creating pvc $pvc of size $size and class $class"
        sed "s/\$pvc/$pvc/g; s/\$class/$class/g; s/\$size/$size/g" \
            $__HOME/pvc.yaml | oc create -f -
    else
        __error "Missing required parameters"
    fi
}

__rsync() {
    local pvc="$1"
    local from="$2"
    local to="$3"
    if [[ -n $pvc && -n $from && -n $to ]]; then
        local patch=$(sed "s/\$pvc/$pvc/g" $__HOME/patch.json)
        oc run maintenance --image="dummy" --restart="Never" --overrides="$patch"
        oc wait --for condition="ready" pod maintenance --timeout="300s"
        oc rsync --no-perms --delete --progress $from $to
        oc delete pod maintenance
    else
        __error "Missing required parameters"
    fi
}

__compress() {
    if [[ -n $BACKUP_NAME && -n $BACKUP_HOME ]]; then
        echo "Compressing"
        local current_dir=$(pwd)
        cd $__TMP
        zip -qr $BACKUP_NAME.zip *
        mv $BACKUP_NAME.zip $BACKUP_HOME
        cd $current_dir
    fi
}

__uncompress() {
    if [[ -n $BACKUP_NAME && -n $BACKUP_HOME ]]; then
        echo "Uncompressing"
        rm -rf $__TMP
        unzip -qo $BACKUP_HOME/$BACKUP_NAME.zip -d $__TMP
    fi
}

backup() {
    __confirm $SOURCE_NS
    mkdir -p $__TMP/resources $__TMP/data
    oc new-project $SOURCE_NS 2>/dev/null || oc project $SOURCE_NS
    oc delete pod maintenance 2>/dev/null ||true

    # export operator version
    OPERATOR_POD="$(oc get pods | grep strimzi-cluster-operator | grep Running | cut -d " " -f1)"
    oc exec -it $OPERATOR_POD -- env | grep "STRIMZI_VERSION" > $__TMP/README

    # export resources
    __export "kafkas"
    __export "kafkatopics"
    __export "kafkausers"
    __export "kafkabridges"
    __export "kafkaconnectors"
    __export "kafkaconnects"
    __export "kafkaconnects2is"
    __export "kafkamirrormaker2s"
    __export "kafkamirrormakers"
    __export "kafkarebalances"
    # internal certificates and user secrets
    __export "secrets" "strimzi.io/name=strimzi"
    # custom configmap and secrets
    for name in "${CUSTOM_CMS[@]}"; do
        __export "cm/$name"
    done
    for name in "${CUSTOM_SECRETS[@]}"; do
        __export "secret/$name"
    done

    # stop operator and statefulsets
    oc scale deployment strimzi-cluster-operator --replicas 0
    oc scale statefulset $CLUSTER_NAME-kafka --replicas 0
    oc scale statefulset $CLUSTER_NAME-zookeeper --replicas 0
    sleep 120

    # for each PVC, rsync data from PV to backup
    for (( i = 0; i < $ZOO_REPLICAS; i++ )); do
        local pvc="data-$CLUSTER_NAME-zookeeper-$i"
        local local_path="$__TMP/data/$pvc"
        mkdir -p $local_path
        __rsync $pvc maintenance:/data/. $local_path
    done
    for (( i = 0; i < $KAFKA_REPLICAS; i++ )); do
        if [ $KAFKA_JBOD -gt 0 ]; then
            for (( j = 0; j < $KAFKA_JBOD; j++ )); do
                local pvc="data-$j-$CLUSTER_NAME-kafka-$i"
                local local_path="$__TMP/data/$pvc"
                mkdir -p $local_path
                __rsync $pvc maintenance:/data/. $__TMP/data/$pvc
            done
        else
            local pvc="data-$CLUSTER_NAME-kafka-$i"
            local local_path="$__TMP/data/$pvc"
            mkdir -p $local_path
            __rsync $pvc maintenance:/data/. $__TMP/data/$pvc
        fi
    done

    # start statefulsets and operator
    oc scale statefulset $CLUSTER_NAME-zookeeper --replicas $ZOO_REPLICAS
    oc scale statefulset $CLUSTER_NAME-kafka --replicas $KAFKA_REPLICAS
    oc scale deployment strimzi-cluster-operator --replicas 1

    __compress
    echo "DONE"
}

restore() {
    __confirm $TARGET_NS
    oc new-project $TARGET_NS 2>/dev/null || oc project $TARGET_NS
    oc delete pod maintenance 2>/dev/null ||true
    __uncompress

    # for each PVC, create it and rsync data from backup to PV
    # this must be done *before* deploying the cluster
    for (( i = 0; i < $ZOO_REPLICAS; i++ )); do
        local pvc="data-$CLUSTER_NAME-zookeeper-$i"
        __create_pvc $pvc $ZOO_PVC_CLASS $ZOO_PVC_SIZE
        __rsync $pvc $__TMP/data/$pvc/. maintenance:/data
    done
    for (( i = 0; i < $KAFKA_REPLICAS; i++ )); do
        if [ $KAFKA_JBOD -gt 0 ]; then
            for (( j = 0; j < $KAFKA_JBOD; j++ )); do
                local pvc="data-$j-$CLUSTER_NAME-kafka-$i"
                __create_pvc $pvc $KAFKA_PVC_CLASS $KAFKA_PVC_SIZE
                __rsync $pvc $__TMP/data/$pvc/. maintenance:/data
            done
        else
            local pvc="data-$CLUSTER_NAME-kafka-$i"
            __create_pvc $pvc $KAFKA_PVC_CLASS $KAFKA_PVC_SIZE
            __rsync $pvc $__TMP/data/$pvc/. maintenance:/data
        fi
    done

    # import resources
    # KafkaTopic resources must be created *before*
    # deploying the Topic Operator or it will delete them
    oc apply -f $__TMP/resources 2>/dev/null ||true

    echo "DONE"
}

USAGE="Usage: $(basename "$0") [options]

Options:
  backup    Run backup procedure
  restore   Run restore procedure"
case "${1-}" in
    backup)
        backup
        ;;
    restore)
        restore
        ;;
    *)
        __error "$USAGE"
        ;;
esac
