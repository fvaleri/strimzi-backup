#!/usr/bin/env bash
set -Eeuo pipefail
#set -x #debug
__TMP="/tmp/strimzi-backup" && mkdir -p $__TMP
__HOME="" && pushd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" >/dev/null \
    && { __HOME=$PWD; popd >/dev/null; }

SOURCE_NS="strimzi"
TARGET_NS="strimzi"
CLUSTER_NAME="my-cluster"
BACKUP_NAME="$SOURCE_NS-$(date +%Y%m%d)"
BACKUP_HOME="/tmp"

# PVC size must match with the corresponding CR value
# PVC class must be empty when not available
# specify number of JBOD volumes or zero
ZOO_REPLICAS="3"
ZOO_PVC_SIZE="5Gi"
ZOO_PVC_CLASS=""
KAFKA_REPLICAS="3"
KAFKA_PVC_SIZE="10Gi"
KAFKA_PVC_CLASS=""
NUM_OF_JBOD_VOLUMES="2"

# custom configmap names
# i.e. external logging configuration (log4j)
CUSTOM_CMS=(
    "log4j-properties"
    "custom-test"
)

# custom secret names
# i.e. listener's certificate, image registry authentication
CUSTOM_SECRETS=(
    "ext-listener-crt"
    "registry-authn"
    "custom-test"
)

__error() {
    local message="$1"
    echo "$message"
    exit 1
}

__whoami() {
    printf $(kubectl config current-context | cut -d "/" -f3)
}

__confirm() {
    local message="$1"
    if [[ -n $message ]]; then
        read -p "$message (y/n) " reply
        if [[ ! $reply =~ ^[Yy]$ ]]; then
            exit 0
        fi
    fi
}

__select_ns() {
    local ns="$1"
    if [[ -n $ns ]]; then
        kubectl config set-context --current --namespace=$ns
    fi
}

__create_or_select_ns() {
    local ns="$1"
    if [[ -n $ns ]]; then
        kubectl create namespace $ns 2>/dev/null \
            || __select_ns $ns
    fi
}

__export() {
    local name="$1"
    local label="${2-}"
    if [[ -n $name ]]; then
        local crs=$(kubectl get $name -o name -l "$label")
        if [[ -n $crs ]]; then
            echo "Exporting $name"
            # delete runtime metadata expression
            local exp="del(.metadata.namespace, .items[].metadata.namespace, \
                .metadata.resourceVersion, .items[].metadata.resourceVersion, \
                .metadata.selfLink, .items[].metadata.selfLink, \
                .metadata.uid, .items[].metadata.uid, \
                .status, .items[].status)"
            local id=$(printf $name | sed 's/\//-/g;s/ //g')
            kubectl get $crs -o yaml | yq eval "$exp" - > $__TMP/resources/$SOURCE_NS-$id.yaml
        fi
    fi
}

__create_pvc() {
    local pvc="$1"
    local size="$2"
    local class="${3-}"
    if [[ -n $pvc && -n $size ]]; then
        local exp="s/\$pvc/$pvc/g; s/\$size/$size/g; /storageClassName/d"
        if [[ -n $class ]]; then
            exp="s/\$pvc/$pvc/g; s/\$size/$size/g; s/\$class/$class/g"
        fi
        echo "Creating pvc $pvc of size $size"
        sed "$exp" $__HOME/pvc.yaml | kubectl create -f -
    else
        __error "Missing required parameters"
    fi
}

__rsync() {
    local source="$1"
    local target="$2"
    if [[ -n $source && -n $target ]]; then
        echo "Rsync from $source to $target"
        local pod_name="backup"
        local patch=$(sed "s/\$pvc/$pvc/g" $__HOME/patch.json)
        kubectl run $pod_name --image="dummy" --restart="Never" --overrides="$patch"
        kubectl wait --for condition="ready" pod $pod_name --timeout="300s"
        if [[ $source == *"$__TMP"* ]]; then
            # upload from local to pod
            tar -C $source -c . | kubectl exec -i $pod_name -- sh -c "tar -C /data -xv"
        else
            # incremental download from pod to local
            local flags="-c --no-check-device --no-acls --no-xattrs --totals \
                --listed-incremental /data/backup.snar --exclude=./backup.snar"
            if [ -z "$(ls -A $__TMP/data)" ]; then
                # fallback to full download
                flags="$flags --level=0"
            fi
            kubectl exec -i $pod_name -- sh -c "tar $flags -C /data ." | tar -C $target -xv -f -
        fi
        kubectl delete pod $pod_name
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
    else
        __error "Missing required parameters"
    fi
}

__uncompress() {
    if [[ -n $BACKUP_NAME && -n $BACKUP_HOME ]]; then
        echo "Uncompressing"
        rm -rf $__TMP
        unzip -qo $BACKUP_HOME/$BACKUP_NAME.zip -d $__TMP
        chmod -R o+rw $__TMP
    else
        __error "Missing required parameters"
    fi
}

backup() {
    __confirm "Start backup of $SOURCE_NS/$CLUSTER_NAME as $(__whoami) (cluster will be unavailable)"
    mkdir -p $__TMP/resources $__TMP/data
    __select_ns $SOURCE_NS

    # export operator version
    local op_pod="$(kubectl get pods | grep strimzi-cluster-operator | grep Running | cut -d " " -f1)"
    kubectl exec -it $op_pod -- env | grep "VERSION" > $__TMP/env ||true

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
    kubectl scale deployment strimzi-cluster-operator --replicas 0
    kubectl scale statefulset $CLUSTER_NAME-kafka --replicas 0
    kubectl scale statefulset $CLUSTER_NAME-zookeeper --replicas 0
    sleep 120

    # for each PVC, rsync data from PV to backup
    for (( i = 0; i < $ZOO_REPLICAS; i++ )); do
        local pvc="data-$CLUSTER_NAME-zookeeper-$i"
        local local_path="$__TMP/data/$pvc"
        mkdir -p $local_path
        __rsync $pvc $local_path
    done
    for (( i = 0; i < $KAFKA_REPLICAS; i++ )); do
        if [ $NUM_OF_JBOD_VOLUMES -gt 0 ]; then
            for (( j = 0; j < $NUM_OF_JBOD_VOLUMES; j++ )); do
                local pvc="data-$j-$CLUSTER_NAME-kafka-$i"
                local local_path="$__TMP/data/$pvc"
                mkdir -p $local_path
                __rsync $pvc $local_path
            done
        else
            local pvc="data-$CLUSTER_NAME-kafka-$i"
            local local_path="$__TMP/data/$pvc"
            mkdir -p $local_path
            __rsync $pvc $local_path
        fi
    done

    # start statefulsets and operator
    kubectl scale statefulset $CLUSTER_NAME-zookeeper --replicas $ZOO_REPLICAS
    kubectl scale statefulset $CLUSTER_NAME-kafka --replicas $KAFKA_REPLICAS
    kubectl scale deployment strimzi-cluster-operator --replicas 1

    __compress
    echo "DONE"
}

restore() {
    __confirm "Start restore of $TARGET_NS/$CLUSTER_NAME as $(__whoami)"
    __create_or_select_ns $TARGET_NS
    __uncompress

    # for each PVC, create it and rsync data from backup to PV
    # this must be done *before* deploying the cluster
    for (( i = 0; i < $ZOO_REPLICAS; i++ )); do
        local pvc="data-$CLUSTER_NAME-zookeeper-$i"
        __create_pvc $pvc $ZOO_PVC_SIZE $ZOO_PVC_CLASS
        __rsync $__TMP/data/$pvc/. $pvc
    done
    for (( i = 0; i < $KAFKA_REPLICAS; i++ )); do
        if [ $NUM_OF_JBOD_VOLUMES -gt 0 ]; then
            for (( j = 0; j < $NUM_OF_JBOD_VOLUMES; j++ )); do
                local pvc="data-$j-$CLUSTER_NAME-kafka-$i"
                __create_pvc $pvc $KAFKA_PVC_SIZE $KAFKA_PVC_CLASS
                __rsync $__TMP/data/$pvc/. $pvc
            done
        else
            local pvc="data-$CLUSTER_NAME-kafka-$i"
            __create_pvc $pvc $KAFKA_PVC_SIZE $KAFKA_PVC_CLASS
            __rsync $__TMP/data/$pvc/. $pvc
        fi
    done

    # import resources
    # KafkaTopic resources must be created *before*
    # deploying the Topic Operator or it will delete them
    kubectl apply -f $__TMP/resources 2>/dev/null ||true

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
esac
