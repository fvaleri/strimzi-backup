#!/usr/bin/env bash
set -Eeuo pipefail
#set -x #debug
__TMP="/tmp/strimzi-backup" && mkdir -p $__TMP
__HOME="" && pushd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" >/dev/null \
    && { __HOME=$PWD; popd >/dev/null; }

__error() {
    local message="$1"
    echo "$message"
    exit 1
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

__whoami() {
    printf $(kubectl config current-context | cut -d "/" -f3)
}

__select_ns() {
    local ns="$1"
    if [[ -n $ns ]]; then
        kubectl config set-context --current --namespace="$ns"
    fi
}

__wait_for() {
    local resource="$1"
    local condition="$2"
    local selector="$3"
    if [[ -n $resource && -n $condition && -n $selector ]]; then
        kubectl wait "$resource" --for="$condition" --selector="$selector" --timeout="300s"
    else
        __error "Missing required parameters"
    fi
}

__export_env() {
    local op_pod="$(kubectl get pods | grep strimzi-cluster-operator | grep Running | cut -d " " -f1)"
    kubectl exec -i $op_pod -- env | grep "VERSION" | sed -e "s/^/declare -- /" > "$__TMP/env"
    local filter="data-$CLUSTER_NAME-zookeeper"
    ZOO_REPLICAS=$(kubectl get kafka $CLUSTER_NAME -o yaml | yq eval ".spec.zookeeper.replicas" -)
    ZOO_PVC_SIZE=$(kubectl get pvc $filter-0 -o yaml | yq eval ".spec.resources.requests.storage" -)
    ZOO_PVC_CLASS=$(kubectl get pvc $filter-0 -o yaml | yq eval ".spec.storageClassName" -)
    JBOD_VOL_NUM=$(kubectl get pvc | grep $CLUSTER_NAME-kafka-0 | wc -l)
    if ((JBOD_VOL_NUM > 1)); then
        filter="data-0-$CLUSTER_NAME-kafka"
    else
        filter="data-$CLUSTER_NAME-kafka"
    fi
    KAFKA_REPLICAS=$(kubectl get kafka $CLUSTER_NAME -o yaml | yq eval ".spec.kafka.replicas" -)
    KAFKA_PVC_SIZE=$(kubectl get pvc $filter-0 -o yaml | yq eval ".spec.resources.requests.storage" -)
    KAFKA_PVC_CLASS=$(kubectl get pvc $filter-0 -o yaml | yq eval ".spec.storageClassName" -)
    declare -px ZOO_REPLICAS ZOO_PVC_SIZE ZOO_PVC_CLASS JBOD_VOL_NUM \
        KAFKA_REPLICAS KAFKA_PVC_SIZE KAFKA_PVC_CLASS >> "$__TMP/env"
}

__export_res() {
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
            kubectl get $crs -o yaml | yq eval "$exp" - > $__TMP/resources/$NAMESPACE-$id.yaml
        fi
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
        __wait_for pod condition=ready run=backup
        local flags="--no-check-device --no-acls --no-xattrs --no-same-owner --no-overwrite-dir"
        if [[ $source == *"$__TMP"* ]]; then
            # upload from local to pod
            tar $flags -C $source -c . | kubectl exec -i $pod_name -- sh -c "tar $flags -C /data -xv -f -"
        else
            # incremental sync from pod to local
            flags="$flags --listed-incremental /data/backup.snar \
                --exclude=backup.snar --exclude=data/version-2/{currentEpoch,acceptedEpoch}"
            if [ -z "$(ls -A $__TMP/data)" ]; then
                # fallback to full sync
                flags="$flags --level=0"
            fi
            kubectl exec -i $pod_name -- sh -c "tar $flags -C /data -c ." | tar $flags -C $target -xv -f -
        fi
        kubectl delete pod $pod_name
    else
        __error "Missing required parameters"
    fi
}

__create_pvc() {
    local pvc="$1"
    local size="$2"
    local class="${3-}"
    if [[ -n $pvc && -n $size ]]; then
        local exp="s/\$pvc/$pvc/g; s/\$size/$size/g; /storageClassName/d"
        if [ "$class" != "null" ]; then
            exp="s/\$pvc/$pvc/g; s/\$size/$size/g; s/\$class/$class/g"
        fi
        echo "Creating pvc $pvc of size $size"
        sed "$exp" $__HOME/pvc.yaml | kubectl create -f -
    else
        __error "Missing required parameters"
    fi
}

__compress() {
    local source_dir="$1"
    local target_file="$2"
    if [[ -n $source_dir && -n $target_file ]]; then
        echo "Compressing $source_dir to $target_file"
        local current_dir=$(pwd)
        cd $source_dir
        zip -FSqr $target_file *
        cd $current_dir
    else
        __error "Missing required parameters"
    fi
}

__uncompress() {
    local source_file="$1"
    local target_dir="$2"
    if [[ -n $source_file && -n $target_dir ]]; then
        echo "Uncompressing $source_file to $target_dir"
        rm -rf $target_dir
        unzip -qo $source_file -d $target_dir
        chmod -R ugo+rwx $target_dir
    else
        __error "Missing required parameters"
    fi
}

backup() {
    if [ $# -lt 3 ]; then
        __error "Missing required arguments"
    else
        SOURCE_NS="$1"
        CLUSTER_NAME="$2"
        TARGET_FILE="$3"
    fi

    # context init
    __select_ns $NAMESPACE
    __TMP="$__TMP/$NAMESPACE/$CLUSTER_NAME"
    if [ $CONFIRM = true ]; then
        __confirm "Backup $NAMESPACE/$CLUSTER_NAME as $(__whoami); the cluster will be unavailable"
    fi
    if [ $INCREMENTAL = true ]; then
        echo "Starting incremental backup"
    else
        echo "Starting full backup"
        rm -rf $__TMP
    fi
    mkdir -p $__TMP/resources $__TMP/data
    __export_env

    # export resources
    __export_res "kafkas"
    __export_res "kafkatopics"
    __export_res "kafkausers"
    __export_res "kafkabridges"
    __export_res "kafkaconnectors"
    __export_res "kafkaconnects"
    __export_res "kafkaconnects2is"
    __export_res "kafkamirrormaker2s"
    __export_res "kafkamirrormakers"
    __export_res "kafkarebalances"
    # internal certificates and user secrets
    __export_res "secrets" "strimzi.io/name=strimzi"
    # custom configmap and secrets
    if [[ -n $CUSTOM_CM ]]; then
        for name in $(printf $CUSTOM_CM | sed "s/,/ /g"); do
            __export_res "cm/$name"
        done
    fi
    if [[ -n $CUSTOM_SE ]]; then
        for name in $(printf $CUSTOM_SE | sed "s/,/ /g"); do
            __export_res "secret/$name"
        done
    fi

    # stop operator and statefulsets
    local op_deploy="$(oc get deploy strimzi-cluster-operator -o name)"
    if [[ -n $op_deploy ]]; then
        kubectl scale $op_deploy --replicas 0
        __wait_for pod delete name=strimzi-cluster-operator
    fi
    kubectl scale statefulset $CLUSTER_NAME-kafka --replicas 0
    __wait_for pod delete strimzi.io/name=$CLUSTER_NAME-kafka
    kubectl scale statefulset $CLUSTER_NAME-zookeeper --replicas 0
    __wait_for pod delete strimzi.io/name=$CLUSTER_NAME-zookeeper

    # for each PVC, rsync data from PV to backup
    for ((i = 0; i < $ZOO_REPLICAS; i++)); do
        local pvc="data-$CLUSTER_NAME-zookeeper-$i"
        local local_path="$__TMP/data/$pvc"
        mkdir -p $local_path
        __rsync $pvc $local_path
    done
    for ((i = 0; i < $KAFKA_REPLICAS; i++)); do
        if ((JBOD_VOL_NUM > 1)); then
            for ((j = 0; j < $JBOD_VOL_NUM; j++)); do
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

    # create the archive
    __compress $__TMP $TARGET_FILE

    # start statefulsets and operator
    kubectl scale statefulset $CLUSTER_NAME-zookeeper --replicas $ZOO_REPLICAS
    __wait_for pod condition=ready strimzi.io/name=$CLUSTER_NAME-zookeeper
    kubectl scale statefulset $CLUSTER_NAME-kafka --replicas $KAFKA_REPLICAS
    __wait_for pod condition=ready strimzi.io/name=$CLUSTER_NAME-kafka
    if [[ -n $op_deploy ]]; then
        kubectl scale $op_deploy --replicas 1
        __wait_for pod condition=ready name=strimzi-cluster-operator
    fi

    echo "DONE"
}

restore() {
    if [ $# -lt 3 ]; then
        __error "Missing required arguments"
    else
        TARGET_NS="$1"
        CLUSTER_NAME="$2"
        SOURCE_FILE="$3"
    fi

    # context init
    __select_ns $NAMESPACE
    __TMP="$__TMP/$NAMESPACE/$CLUSTER_NAME"
    if [ $CONFIRM = true ]; then
        __confirm "Restore $NAMESPACE/$CLUSTER_NAME as $(__whoami)"
    fi
    __uncompress $SOURCE_FILE $__TMP
    source $__TMP/env

    # for each PVC, create it and rsync data from backup to PV
    # this must be done *before* deploying the cluster
    for ((i = 0; i < $ZOO_REPLICAS; i++)); do
        local pvc="data-$CLUSTER_NAME-zookeeper-$i"
        __create_pvc $pvc $ZOO_PVC_SIZE $ZOO_PVC_CLASS
        __rsync $__TMP/data/$pvc/. $pvc
    done
    for ((i = 0; i < $KAFKA_REPLICAS; i++)); do
        if ((JBOD_VOL_NUM > 1)); then
            for (( j = 0; j < $JBOD_VOL_NUM; j++ )); do
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

BACKUP=false
RESTORE=false
INCREMENTAL=false
CONFIRM=true
NAMESPACE=""
CLUSTER_NAME=""
TARGET_FILE=""
SOURCE_FILE=""
CUSTOM_CM=""
CUSTOM_SE=""

USAGE="Usage: $0 [options]

Options:
  -b  Cluster backup
  -r  Cluster restore
  -i  Enable incremental backup (-bi)
  -y  Skip confirmation step (-by or -ry)
  -n  Source/target namespace
  -c  Kafka cluster name
  -t  Target backup file path
  -s  Source backup file path
  -m  Custom configmaps (-m cm0,cm1,cm2)
  -x  Custom secrets (-x se0,se1,se2)

Examples:
  # backup
  $0 -b -n test -c my-cluster \\
    -t /tmp/my-cluster.zip \\
    -m log4j-properties,custom-test \\
    -x ext-listener-crt,custom-test
  # restore
  $0 -r -n test-new -c my-cluster \\
    -s /tmp/my-cluster.zip"

while getopts ":briyn:c:t:s:m:x:" opt; do
    case "${opt-}" in
        b)
            BACKUP=true
            ;;
        r)
            RESTORE=true
            ;;
        i)
            INCREMENTAL=true
            ;;
        y)
            CONFIRM=false
            ;;
        n)
            NAMESPACE=${OPTARG-}
            ;;
        c)
            CLUSTER_NAME=${OPTARG-}
            ;;
        t)
            TARGET_FILE=${OPTARG-}
            ;;
        s)
            SOURCE_FILE=${OPTARG-}
            ;;
        m)
            CUSTOM_CM=${OPTARG-}
            ;;
        x)
            CUSTOM_SE=${OPTARG-}
            ;;
        *)
            __error "$USAGE"
            ;;
    esac
done
shift $((OPTIND-1))

if [[ $BACKUP = false && $RESTORE = false ]] \
    || [[ $BACKUP = true && $RESTORE = true ]]; then
    __error "$USAGE"
fi

if [ $BACKUP = true ]; then
    if [[ -n $NAMESPACE && -n $CLUSTER_NAME && -n $TARGET_FILE ]]; then
        BACKUP_DIR="$(dirname $TARGET_FILE)"
        if [ -d $BACKUP_DIR ]; then
            backup $NAMESPACE $CLUSTER_NAME $TARGET_FILE
        else
            __error "$BACKUP_DIR not found"
        fi
    else
        __error "Required parameters: namespace, cluster name and target file"
    fi
fi

if [ $RESTORE = true ]; then
    if  [[ -n $NAMESPACE && -n $CLUSTER_NAME && -f $SOURCE_FILE ]]; then
        if [ -f $SOURCE_FILE ]; then
            restore $NAMESPACE $CLUSTER_NAME $SOURCE_FILE
        else
            __error "$SOURCE_FILE file not found"
        fi
    else
        __error "Required parameters: namespace, cluster name and source file"
    fi
fi
